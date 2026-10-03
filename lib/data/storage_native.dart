import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'storage_base.dart';
export 'storage_base.dart';

class LocalWalletStorage implements WalletStorage {
  final Directory? directory;
  LocalWalletStorage({this.directory});
  Future<File> get _file async => File(
    '${(directory ?? await getApplicationSupportDirectory()).path}/findash_ledger.json',
  );
  @override
  Future<String?> load() async {
    final file = await _file;
    return compute(_loadFile, file.path, debugLabel: 'wallet-file-load');
  }

  @override
  Future<void> save(String data) async {
    final file = await _file;
    await compute(_saveFile, (file.path, data), debugLabel: 'wallet-file-save');
  }
}

// Resolve the platform-specific directory before entering the worker. Workers
// use dart:io only; old/new envelope JSON and SHA-256 never block the UI isolate.
Future<String?> _loadFile(String path) async {
  final file = File(path);
  final backup = File('${file.path}.bak');
  if (!await file.exists() && !await backup.exists()) return null;
  for (final candidate in [file, backup]) {
    try {
      if (await candidate.exists()) {
        return unseal(await candidate.readAsString());
      }
    } catch (_) {
      /* Try the last verified snapshot. Never overwrite corrupt data at startup. */
    }
  }
  throw const FormatException('账本和恢复副本均无法读取，请保留文件并使用备份恢复');
}

Future<void> _saveFile((String, String) request) async {
  final (path, data) = request;
  final file = File(path);
  await file.parent.create(recursive: true);
  if (await file.exists()) {
    final previous = await file.readAsString();
    try {
      unseal(previous);
      await File('${file.path}.bak').writeAsString(previous, flush: true);
    } on FormatException {
      /* Preserve the good backup if recovering from a damaged primary. */
    }
  }
  final pending = File('${file.path}.pending');
  await pending.writeAsString(seal(data), flush: true);
  await pending.rename(file.path);
}
