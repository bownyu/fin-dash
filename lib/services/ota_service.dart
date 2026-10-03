import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import '../app_version.dart';
import '../domain/ota_manifest.dart';
import 'ota_files.dart';
import 'ota_files_base.dart';

abstract class OtaInstaller {
  Future<bool> canInstall();
  Future<void> openPermission();
  Future<void> install(String path, OtaManifest release);
}

class AndroidOtaInstaller implements OtaInstaller {
  static const channel = MethodChannel('findash/ota');
  @override
  Future<bool> canInstall() async =>
      (await channel.invokeMapMethod<String, dynamic>(
        'status',
      ))?['canInstall'] ==
      true;
  @override
  Future<void> openPermission() =>
      channel.invokeMethod<void>('openInstallPermission');
  @override
  Future<void> install(String path, OtaManifest release) =>
      channel.invokeMethod<void>('install', {
        'path': path,
        'sha256': release.sha256,
        'buildNumber': release.buildNumber,
      });
}

enum OtaState {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  permission,
  installing,
  error,
}

class OtaService extends ChangeNotifier {
  final String sourceUrl;
  final http.Client Function() createClient;
  final OtaFileStorage storage;
  final OtaInstaller installer;
  OtaManifest? release;
  OtaState state = OtaState.idle;
  String? error, downloadedPath;
  int received = 0;
  http.Client? _client;
  int _generation = 0;
  bool _disposed = false;
  OtaService({
    this.sourceUrl = otaManifestUrl,
    http.Client Function()? clientFactory,
    OtaFileStorage? fileStorage,
    OtaInstaller? packageInstaller,
  }) : createClient = clientFactory ?? http.Client.new,
       storage = fileStorage ?? createOtaFileStorage(),
       installer = packageInstaller ?? AndroidOtaInstaller();
  bool get busy => [
    OtaState.checking,
    OtaState.downloading,
    OtaState.installing,
  ].contains(state);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _active(int generation) => !_disposed && generation == _generation;

  Future<http.StreamedResponse> _get(http.Client client, Uri uri) async {
    for (var redirects = 0; redirects < 6; redirects++) {
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers['User-Agent'] = 'FinDash/$appVersion';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers['location'];
        if (location == null) throw const FormatException('更新下载地址未返回有效跳转');
        final next = uri.resolve(location);
        if (!otaRedirectAllowed(next)) {
          throw const FormatException('更新文件跳转到了不可信地址');
        }
        // Cancel the redirect body so a large response cannot delay the next request.
        await response.stream.listen((_) {}).cancel();
        uri = next;
        continue;
      }
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        throw FormatException(
          response.statusCode == 404
              ? '尚未发布可下载的更新，请稍后重试'
              : '更新请求失败（HTTP ${response.statusCode}），请重试',
        );
      }
      return response;
    }
    throw const FormatException('更新下载跳转过多，请稍后重试');
  }

  Future<void> check() async {
    if (busy || _disposed) return;
    final generation = ++_generation, client = createClient();
    _client = client;
    state = OtaState.checking;
    error = null;
    release = null;
    downloadedPath = null;
    _notify();
    try {
      final source = OtaManifest.source(sourceUrl);
      final response = await _get(client, source);
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 65536) throw const FormatException('更新说明过大，已停止读取');
      }
      final data = jsonDecode(utf8.decode(bytes));
      if (data is! Map) throw const FormatException('更新文件格式不正确');
      final parsed = OtaManifest.parse(Map<String, dynamic>.from(data), source);
      if (!_active(generation)) return;
      release = parsed;
      state = parsed.newer ? OtaState.available : OtaState.upToDate;
    } catch (e) {
      if (_active(generation)) {
        error = e is FormatException ? e.message : '无法检查更新，请检查网络后重试';
        state = OtaState.error;
      }
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
      _notify();
    }
  }

  Future<void> download() async {
    final target = release;
    if (busy || _disposed || target == null || !target.newer) return;
    final generation = ++_generation, client = createClient();
    _client = client;
    state = OtaState.downloading;
    error = null;
    received = 0;
    _notify();
    OtaFileWriter? writer;
    try {
      writer = await storage.create(target.buildNumber);
      final response = await _get(client, target.downloadUrl);
      if (response.contentLength != null &&
          response.contentLength != target.sizeBytes) {
        throw const FormatException('安装包大小与发布信息不一致，已停止下载');
      }
      final digest = _DigestSink(),
          hash = sha256.startChunkedConversion(digest);
      var lastNotified = DateTime.now();
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 45),
      )) {
        if (!_active(generation)) throw const FormatException('下载已取消');
        received += chunk.length;
        if (received > target.sizeBytes) {
          throw const FormatException('安装包大小超过发布信息，已停止下载');
        }
        hash.add(chunk);
        await writer.add(chunk);
        if (DateTime.now().difference(lastNotified).inMilliseconds >= 120) {
          lastNotified = DateTime.now();
          _notify();
        }
      }
      hash.close();
      if (!_active(generation)) throw const FormatException('下载已取消');
      if (received != target.sizeBytes ||
          digest.value?.toString() != target.sha256) {
        throw const FormatException('安装包校验失败，已删除下载文件，请重新下载');
      }
      final path = await writer.commit();
      writer = null;
      if (!_active(generation)) return;
      downloadedPath = path;
      state = OtaState.ready;
    } catch (e) {
      if (_active(generation)) {
        error = e is FormatException ? e.message : '下载未完成，请检查网络或存储空间后重试';
        state = OtaState.error;
      }
    } finally {
      if (writer != null) {
        try {
          await writer.discard();
        } catch (_) {
          /* Never install partial files. */
        }
      }
      client.close();
      if (identical(_client, client)) _client = null;
      _notify();
    }
  }

  Future<void> install() async {
    if (busy || _disposed || downloadedPath == null || release == null) return;
    state = OtaState.installing;
    error = null;
    _notify();
    try {
      if (!await installer.canInstall()) {
        state = OtaState.permission;
        return;
      }
      await installer.install(downloadedPath!, release!);
      state = OtaState.ready;
    } catch (e) {
      error = e is PlatformException
          ? e.message ?? '无法启动系统安装，请重试'
          : '无法启动系统安装，请重试';
      state = OtaState.error;
    } finally {
      _notify();
    }
  }

  Future<void> openPermission() => installer.openPermission();
  void cancel() {
    _generation++;
    _client?.close();
    _client = null;
    if (state == OtaState.downloading) {
      state = OtaState.available;
      error = null;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
