import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fin_dash/app_version.dart';
import 'package:fin_dash/domain/ota_manifest.dart';
import 'package:fin_dash/services/ota_files_base.dart';
import 'package:fin_dash/services/ota_service.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/ui/ota_page.dart';
import 'agent_ui_test.dart' show harness;
import 'helpers.dart';

final payload = utf8.encode('verified apk test bytes');
Map<String, dynamic> manifest({int? build, String hash = '', Uri? url}) => {
  'schemaVersion': 1,
  'applicationId': otaApplicationId,
  'version': '0.2.2',
  'buildNumber': build ?? appBuildNumber + 1,
  'sizeBytes': payload.length,
  'sha256': hash.isEmpty ? sha256.convert(payload).toString() : hash,
  'downloadUrl':
      (url ??
              Uri.parse(
                'https://github.com/bownyu/fin-dash/releases/download/v0.2.2/FinDash-0.2.2+${build ?? appBuildNumber + 1}-arm64.apk',
              ))
          .toString(),
  'notes': '批量交互改进\n修复问题',
};

class MemoryOtaFile implements OtaFileWriter {
  final bytes = <int>[];
  bool committed = false, discarded = false;
  @override
  Future<void> add(List<int> chunk) async {
    bytes.addAll(chunk);
  }

  @override
  Future<String> commit() async {
    committed = true;
    return '/cache/findash-updates/verified.apk';
  }

  @override
  Future<void> discard() async {
    discarded = true;
    bytes.clear();
  }
}

class MemoryOtaStorage implements OtaFileStorage {
  final files = <MemoryOtaFile>[];
  @override
  Future<OtaFileWriter> create(int buildNumber) async {
    final file = MemoryOtaFile();
    files.add(file);
    return file;
  }
}

class TestInstaller implements OtaInstaller {
  bool allowed = true;
  int installations = 0, permissions = 0;
  @override
  Future<bool> canInstall() async => allowed;
  @override
  Future<void> openPermission() async {
    permissions++;
  }

  @override
  Future<void> install(String path, OtaManifest release) async {
    installations++;
  }
}

OtaService testService({
  Map<String, dynamic>? data,
  List<int>? apk,
  MemoryOtaStorage? storage,
  TestInstaller? installer,
  int status = 200,
}) => OtaService(
  fileStorage: storage ?? MemoryOtaStorage(),
  packageInstaller: installer ?? TestInstaller(),
  clientFactory: () => MockClient(
    (request) async => request.url.path.endsWith('.json')
        ? http.Response(
            jsonEncode(data ?? manifest()),
            status,
            headers: {'content-type': 'application/json; charset=utf-8'},
          )
        : http.Response.bytes(apk ?? payload, 200),
  ),
);

void main() {
  test(
    'release source and artifact remain bound to HTTPS, repository, application and version',
    () {
      final source = OtaManifest.source(otaManifestUrl);
      expect(OtaManifest.parse(manifest(), source).newer, true);
      for (final patch in [
        {'schemaVersion': 2},
        {'applicationId': 'other'},
        {'sha256': 'invalid'},
        {'sizeBytes': -1},
        {'version': 'latest'},
        {'buildNumber': 0},
        {'notes': 'x' * 12001},
        {
          'downloadUrl':
              'https://github.com/other/repo/releases/download/v0.2.2/app.apk',
        },
        {
          'downloadUrl':
              'http://github.com/bownyu/fin-dash/releases/download/v0.2.2/app.apk',
        },
      ]) {
        expect(
          () => OtaManifest.parse({...manifest(), ...patch}, source),
          throwsFormatException,
        );
      }
      expect(
        () => OtaManifest.source('https://attacker.invalid/ota.json'),
        throwsFormatException,
      );
      expect(
        otaRedirectAllowed(
          Uri.parse('https://release-assets.githubusercontent.com/file'),
        ),
        true,
      );
      expect(otaRedirectAllowed(Uri.parse('http://github.com/file')), false);
      expect(
        otaRedirectAllowed(
          Uri.parse(
            'https://release-assets.githubusercontent.com.attacker.invalid/file',
          ),
        ),
        false,
      );
    },
  );
  test(
    'checks send only public updater requests and same build is up to date',
    () async {
      final service = testService(data: manifest(build: appBuildNumber));
      await service.check();
      expect(service.state, OtaState.upToDate);
      service.dispose();
    },
  );
  test(
    'verified download stays private and needs a separate installation tap',
    () async {
      final storage = MemoryOtaStorage(), installer = TestInstaller();
      final service = testService(storage: storage, installer: installer);
      await service.check();
      expect(service.state, OtaState.available);
      await service.download();
      expect(service.state, OtaState.ready);
      expect(storage.files.single.committed, true);
      expect(installer.installations, 0);
      await service.install();
      expect(installer.installations, 1);
      service.dispose();
    },
  );
  test(
    'hash and length mismatch discard partial file and never install',
    () async {
      for (final data in [
        manifest(hash: '0' * 64),
        {...manifest(), 'sizeBytes': payload.length + 1},
      ]) {
        final storage = MemoryOtaStorage(), installer = TestInstaller();
        final service = testService(
          data: data,
          storage: storage,
          installer: installer,
        );
        await service.check();
        await service.download();
        expect(service.state, OtaState.error);
        expect(service.downloadedPath, null);
        expect(storage.files.single.discarded, true);
        expect(installer.installations, 0);
        service.dispose();
      }
    },
  );
  test(
    'unknown sources permission preserves verified download until granted',
    () async {
      final installer = TestInstaller()..allowed = false;
      final service = testService(installer: installer);
      await service.check();
      await service.download();
      await service.install();
      expect(service.state, OtaState.permission);
      expect(installer.installations, 0);
      await service.openPermission();
      expect(installer.permissions, 1);
      installer.allowed = true;
      await service.install();
      expect(installer.installations, 1);
      service.dispose();
    },
  );
  test(
    'manifest failure and malicious redirects produce retryable errors',
    () async {
      final service = testService(status: 404);
      await service.check();
      expect(service.error, contains('尚未发布'));
      service.dispose();
      final redirected = OtaService(
        clientFactory: () => MockClient(
          (_) async => http.Response(
            '',
            302,
            headers: {'location': 'https://attacker.invalid/file'},
          ),
        ),
      );
      await redirected.check();
      expect(redirected.state, OtaState.error);
      expect(redirected.error, contains('不可信'));
      redirected.dispose();
    },
  );
  test('cancelled stream never commits or enables installation', () async {
    final stream = StreamController<List<int>>(), storage = MemoryOtaStorage();
    final started = Completer<void>();
    final service = OtaService(
      fileStorage: storage,
      packageInstaller: TestInstaller(),
      clientFactory: () => MockClient.streaming((request, _) async {
        if (request.url.path.endsWith('.json')) {
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(manifest()))),
            200,
          );
        }
        started.complete();
        return http.StreamedResponse(stream.stream, 200);
      }),
    );
    await service.check();
    final download = service.download();
    await started.future;
    service.cancel();
    stream.add(payload);
    await stream.close();
    await download;
    expect(service.state, OtaState.available);
    expect(storage.files.single.committed, false);
    expect(storage.files.single.discarded, true);
    expect(service.downloadedPath, null);
    service.dispose();
  });
  testWidgets(
    'update page fits narrow font-scaled phone and downloading does not touch ledger',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await emptyStore(), service = testService();
      await tester.runAsync(service.check);
      final ai = AiService(store, TestVault());
      await tester.pumpWidget(harness(store, ai, OtaPage(service: service)));
      await tester.pumpAndSettle();
      expect(find.textContaining('发现新版本'), findsOneWidget);
      expect(find.textContaining('下载更新 ·'), findsOneWidget);
      await tester.runAsync(service.download);
      await tester.pumpAndSettle();
      expect(find.text('安装更新'), findsOneWidget);
      expect(store.data.transactions, isEmpty);
      expect(tester.takeException(), null);
      service.dispose();
    },
  );
}
