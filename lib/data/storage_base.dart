import 'dart:convert';
import 'package:crypto/crypto.dart';

abstract class WalletStorage {
  Future<String?> load();
  Future<void> save(String data);
}

String seal(String payload) => jsonEncode({
  'payload': payload,
  'checksum': sha256.convert(utf8.encode(payload)).toString(),
});
String unseal(String raw) {
  final envelope = jsonDecode(raw);
  if (envelope is! Map ||
      envelope['payload'] is! String ||
      envelope['checksum'] is! String) {
    throw const FormatException('本地账本格式不正确');
  }
  final payload = envelope['payload'] as String;
  if (envelope['checksum'] != sha256.convert(utf8.encode(payload)).toString()) {
    throw const FormatException('本地账本校验失败');
  }
  return payload;
}

class MemoryStorage implements WalletStorage {
  String? content;
  bool failWrites = false;
  @override
  Future<String?> load() async => content;
  @override
  Future<void> save(String data) async {
    if (failWrites) throw StateError('存储不可用');
    content = data;
  }
}
