import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'chat_image_storage.dart';

class LocalChatImageStorage implements ChatImageStorage {
  final Directory? directory;
  LocalChatImageStorage({this.directory});
  Future<File> _file(String id) async {
    if (!validChatImageId(id)) throw const FormatException('图片引用无效');
    final root = directory ?? await getApplicationSupportDirectory();
    return File('${root.path}/chat_images/$id');
  }

  @override
  Future<void> save(String id, Uint8List bytes) async {
    final file = await _file(id);
    await file.parent.create(recursive: true);
    if (!await file.exists() ||
        sha256.convert(await file.readAsBytes()).toString() != id) {
      final pending = File('${file.path}.pending');
      await pending.writeAsBytes(bytes, flush: true);
      await pending.rename(file.path);
    }
  }

  @override
  Future<Uint8List?> read(String id) async {
    if (!validChatImageId(id)) return null;
    final file = await _file(id);
    return await file.exists() ? file.readAsBytes() : null;
  }
}
