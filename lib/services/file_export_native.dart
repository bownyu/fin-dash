import 'dart:io';
import 'dart:typed_data';

Future<void> completeFileExport(String? path, Uint8List bytes) async {
  if (path != null && !Platform.isAndroid && !Platform.isIOS) {
    await File(path).writeAsBytes(bytes, flush: true);
  }
}
