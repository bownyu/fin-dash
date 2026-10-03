import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../domain/models.dart';
import 'ledger_changes.dart';

abstract class WalletStorage {
  Future<String?> load();
  Future<void> save(String data);
}

/// A user-recoverable snapshot, separate from the corruption recovery mirror.
abstract interface class RestorePointStorage {
  Future<String?> loadRestorePoint();
  Future<void> saveRestorePoint(String data);
}

/// Native stores commit row deltas directly, bypassing full JSON serialization.
abstract interface class IncrementalWalletStorage implements WalletStorage {
  Future<WalletData?> loadSnapshot();
  Future<void> commitSnapshot(WalletData previous, WalletData next);
  Future<void> replaceSnapshot(WalletData next);
}

/// Same durable transaction as a full write, with no financial payload transfer.
abstract interface class MetadataWalletStorage
    implements IncrementalWalletStorage {
  Future<void> commitMetadata(WalletData previous, WalletData next);
}

abstract interface class RecordWalletStorage implements MetadataWalletStorage {
  Future<void> commitChanges(LedgerChangeSet changes);
}

abstract interface class QueryWalletStorage {
  Future<Json> queryRecords(Json request);
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

class MemoryStorage implements WalletStorage, RestorePointStorage {
  String? content;
  bool failWrites = false;
  String? restorePoint;
  @override
  Future<String?> loadRestorePoint() async => restorePoint;
  @override
  Future<void> saveRestorePoint(String data) async {
    if (failWrites) throw StateError('存储不可用');
    restorePoint = data;
  }

  @override
  Future<String?> load() async => content;
  @override
  Future<void> save(String data) async {
    if (failWrites) throw StateError('存储不可用');
    content = data;
  }
}
