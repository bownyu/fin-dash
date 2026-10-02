import 'dart:typed_data';
export 'chat_image_storage_web.dart'
    if (dart.library.io) 'chat_image_storage_native.dart';

abstract class ChatImageStorage {
  Future<void> save(String id, Uint8List bytes);
  Future<Uint8List?> read(String id);
}

bool validChatImageId(String id) => RegExp(r'^[a-f0-9]{64}$').hasMatch(id);

class MemoryChatImageStorage implements ChatImageStorage {
  final _images = <String, Uint8List>{};
  @override
  Future<void> save(String id, Uint8List bytes) async =>
      _images[id] = Uint8List.fromList(bytes);
  @override
  Future<Uint8List?> read(String id) async => _images[id];
}
