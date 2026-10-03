import '../app_version.dart';

const otaManifestUrl = String.fromEnvironment(
  'OTA_MANIFEST_URL',
  defaultValue:
      'https://github.com/bownyu/fin-dash/releases/latest/download/ota-manifest.json',
);
const otaApplicationId = 'com.findash.fin_dash';

class OtaManifest {
  final String version, sha256, notes;
  final int buildNumber, sizeBytes;
  final Uri downloadUrl;
  const OtaManifest({
    required this.version,
    required this.buildNumber,
    required this.sizeBytes,
    required this.sha256,
    required this.downloadUrl,
    required this.notes,
  });
  bool get newer => buildNumber > appBuildNumber;

  static Uri source(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.hasPort && uri.port != 443 ||
        !RegExp(
          r'^/[^/]+/[^/]+/releases/latest/download/ota-manifest\.json$',
        ).hasMatch(uri.path)) {
      throw const FormatException('更新来源须为 GitHub Release 的 HTTPS 更新文件');
    }
    return uri;
  }

  factory OtaManifest.parse(Map<String, dynamic> data, Uri source) {
    final version = data['version'],
        build = data['buildNumber'],
        size = data['sizeBytes'];
    final hash = data['sha256'], notes = data['notes'] ?? '';
    final download = data['downloadUrl'] is String
        ? Uri.tryParse(data['downloadUrl'])
        : null;
    final parts = source.pathSegments;
    if (data['schemaVersion'] != 1 ||
        data['applicationId'] != otaApplicationId ||
        version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        build is! int ||
        build < 1 ||
        build > 2100000000 ||
        size is! int ||
        size < 1 ||
        size > 1024 * 1024 * 1024 ||
        hash is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash) ||
        notes is! String ||
        notes.length > 12000 ||
        download == null ||
        download.scheme != 'https' ||
        download.host != 'github.com' ||
        download.userInfo.isNotEmpty ||
        download.hasQuery ||
        download.hasFragment ||
        download.hasPort && download.port != 443 ||
        parts.length < 2 ||
        download.pathSegments.length != 6 ||
        download.pathSegments[0] != parts[0] ||
        download.pathSegments[1] != parts[1] ||
        download.pathSegments[2] != 'releases' ||
        download.pathSegments[3] != 'download' ||
        download.pathSegments[4] != 'v$version' ||
        download.pathSegments[5] != 'FinDash-$version+$build-arm64.apk') {
      throw const FormatException('更新文件无效或安装包不属于当前更新来源');
    }
    return OtaManifest(
      version: version,
      buildNumber: build,
      sizeBytes: size,
      sha256: hash.toLowerCase(),
      downloadUrl: download,
      notes: notes,
    );
  }
}

bool otaRedirectAllowed(Uri uri) =>
    uri.scheme == 'https' &&
    uri.userInfo.isEmpty &&
    (!uri.hasPort || uri.port == 443) &&
    [
      'github.com',
      'release-assets.githubusercontent.com',
      'objects.githubusercontent.com',
    ].contains(uri.host);
