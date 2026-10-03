import 'package:shared_preferences/shared_preferences.dart';
import 'storage_base.dart';
export 'storage_base.dart';

class LocalWalletStorage implements WalletStorage, RestorePointStorage {
  static const key = 'findash_flutter_ledger_v1';
  @override
  Future<String?> loadRestorePoint() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$key.restore-point');
    return raw == null ? null : unseal(raw);
  }

  @override
  Future<void> saveRestorePoint(String data) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString('$key.restore-point', seal(data))) {
      throw StateError('恢复前快照未保存，当前账本未替换');
    }
  }

  @override
  Future<String?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final candidates = [prefs.getString(key), prefs.getString('$key.backup')];
    if (candidates.every((s) => s == null)) return null;
    for (final raw in candidates) {
      try {
        if (raw != null) return unseal(raw);
      } catch (_) {
        /* Try backup. */
      }
    }
    throw const FormatException('浏览器账本无法读取，请使用备份恢复');
  }

  @override
  Future<void> save(String data) async {
    final prefs = await SharedPreferences.getInstance();
    final old = prefs.getString(key);
    if (old != null) {
      try {
        unseal(old);
        if (!await prefs.setString('$key.backup', old)) {
          throw StateError('备份写入失败');
        }
      } on FormatException {
        /* Preserve last good backup. */
      }
    }
    if (!await prefs.setString(key, seal(data))) throw StateError('账本写入失败');
  }
}
