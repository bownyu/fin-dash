import 'ota_files_base.dart';

OtaFileStorage createOtaFileStorage() => _Unavailable();

class _Unavailable implements OtaFileStorage {
  @override
  Future<OtaFileWriter> create(int buildNumber) async =>
      throw const FormatException('应用内升级仅支持 Android');
}
