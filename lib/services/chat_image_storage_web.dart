import 'dart:convert';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';
import 'chat_image_storage.dart';

class LocalChatImageStorage implements ChatImageStorage {
  @override
  Future<void> save(String id, Uint8List bytes) async {
    if (!validChatImageId(id)) throw const FormatException('图片引用无效');
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString('findash_chat_image_$id', base64Encode(bytes))) {
      throw StateError('图片未保存');
    }
  }

  @override
  Future<Uint8List?> read(String id) async {
    if (!validChatImageId(id)) return null;
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString('findash_chat_image_$id');
    if (value == null) return null;
    try {
      return base64Decode(value);
    } catch (_) {
      return null;
    }
  }
}
