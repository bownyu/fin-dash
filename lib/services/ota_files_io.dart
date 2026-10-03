import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'ota_files_base.dart';

OtaFileStorage createOtaFileStorage() => _PrivateOtaStorage();

class _PrivateOtaStorage implements OtaFileStorage {
  @override
  Future<OtaFileWriter> create(int buildNumber) async {
    final directory = Directory(
      '${(await getTemporaryDirectory()).path}/findash-updates',
    );
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}/FinDash-$buildNumber-${DateTime.now().microsecondsSinceEpoch}.apk.part',
    );
    return _PrivateOtaWriter(file, file.openWrite());
  }
}

class _PrivateOtaWriter implements OtaFileWriter {
  final File file;
  final IOSink sink;
  bool closed = false;
  int buffered = 0;
  _PrivateOtaWriter(this.file, this.sink);
  @override
  Future<void> add(List<int> bytes) async {
    sink.add(bytes);
    buffered += bytes.length;
    if (buffered >= 512 * 1024) {
      await sink.flush();
      buffered = 0;
    }
  }

  @override
  Future<String> commit() async {
    await sink.close();
    closed = true;
    final target = File(file.path.substring(0, file.path.length - 5));
    if (await target.exists()) await target.delete();
    return (await file.rename(target.path)).path;
  }

  @override
  Future<void> discard() async {
    try {
      if (!closed) {
        await sink.close();
        closed = true;
      }
    } finally {
      if (await file.exists()) await file.delete();
    }
  }
}
