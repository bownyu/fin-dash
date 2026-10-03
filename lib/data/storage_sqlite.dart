import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import '../domain/models.dart';
import 'backup.dart';
import 'storage_base.dart';
import 'ledger_changes.dart';
export 'storage_base.dart';

typedef _Loaded = ({WalletData? data, int revision, String generation});
typedef _Commit = ({
  String path,
  int revision,
  String generation,
  WalletData previous,
  WalletData next,
  bool replace,
  bool metadataOnly,
});
typedef _CommitStats = ({int changedRows, int scannedRows});

/// All SQLite access, diffing, validation and changed-row encoding happen in a
/// worker. The UI publishes its candidate only after both durable files commit.
class LocalWalletStorage
    implements RecordWalletStorage, QueryWalletStorage, RestorePointStorage {
  final Directory? directory;
  _Loaded? _loaded;
  int lastChangedRows = 0;

  /// Payload rows compared plus SQL position rows read, excluding mirror writes.
  int lastScannedRows = 0;
  LocalWalletStorage({this.directory});
  Future<String> get _path async =>
      '${(directory ?? await getApplicationSupportDirectory()).path}/findash_ledger.sqlite';

  @override
  Future<String?> loadRestorePoint() async {
    final file = File('${await _path}.restore-point');
    return await file.exists() ? unseal(await file.readAsString()) : null;
  }

  @override
  Future<void> saveRestorePoint(String data) async {
    final file = File('${await _path}.restore-point');
    await file.parent.create(recursive: true);
    final pending = File('${file.path}.pending');
    await pending.writeAsString(seal(data), flush: true);
    await pending.rename(file.path);
  }

  @override
  Future<WalletData?> loadSnapshot() async {
    final loaded = await compute(
      _load,
      await _path,
      debugLabel: 'wallet-sqlite-load',
    );
    _loaded = loaded;
    return loaded.data;
  }

  @override
  Future<void> commitSnapshot(WalletData previous, WalletData next) async {
    if (_loaded == null) await loadSnapshot();
    final loaded = _loaded!;
    final result = await compute(_commit, (
      path: await _path,
      revision: loaded.revision,
      generation: loaded.generation,
      previous: previous,
      next: next,
      replace: false,
      metadataOnly: false,
    ), debugLabel: 'wallet-sqlite-commit');
    lastChangedRows = result.changedRows;
    lastScannedRows = result.scannedRows;
    _loaded = (
      data: null,
      revision: loaded.revision + 1,
      generation: loaded.generation,
    );
  }

  @override
  Future<void> commitChanges(LedgerChangeSet changes) async {
    if (_loaded == null) await loadSnapshot();
    final loaded = _loaded!;
    final result = await compute(_commitRecords, (
      await _path,
      loaded.revision,
      loaded.generation,
      changes,
    ), debugLabel: 'wallet-record-commit');
    lastChangedRows = result.changedRows;
    lastScannedRows = result.scannedRows;
    _loaded = (
      data: null,
      revision: loaded.revision + 1,
      generation: loaded.generation,
    );
  }

  @override
  Future<Json> queryRecords(Json request) async {
    if (_loaded == null) await loadSnapshot();
    return compute(_queryRecords, (
      await _path,
      _loaded!.revision,
      _loaded!.generation,
      request,
    ), debugLabel: 'wallet-record-query');
  }

  @override
  Future<void> commitMetadata(WalletData previous, WalletData next) async {
    if (!identical(previous.accounts, next.accounts) ||
        !identical(previous.transactions, next.transactions) ||
        !identical(previous.categories, next.categories) ||
        !identical(previous.quickEntries, next.quickEntries)) {
      throw StateError('元数据提交不能修改财务记录');
    }
    if (_loaded == null) await loadSnapshot();
    final loaded = _loaded!;
    // Bootstrap must include default categories and any initial financial data.
    if (loaded.revision == 0) return commitSnapshot(previous, next);
    final result = await compute(_commit, (
      path: await _path,
      revision: loaded.revision,
      generation: loaded.generation,
      previous: _metadataSnapshot(previous),
      next: _metadataSnapshot(next),
      replace: false,
      metadataOnly: true,
    ), debugLabel: 'wallet-sqlite-metadata');
    lastChangedRows = result.changedRows;
    lastScannedRows = result.scannedRows;
    _loaded = (
      data: null,
      revision: loaded.revision + 1,
      generation: loaded.generation,
    );
  }

  @override
  Future<void> replaceSnapshot(WalletData next) async {
    final path = await _path;
    if (_loaded == null) {
      try {
        await loadSnapshot();
      } catch (_) {
        _loaded = await compute(_restoreDamaged, (
          path,
          next,
        ), debugLabel: 'wallet-sqlite-restore');
        return;
      }
    }
    final loaded = _loaded!;
    final result = await compute(_commit, (
      path: path,
      revision: loaded.revision,
      generation: loaded.generation,
      previous: WalletData(),
      next: next,
      replace: true,
      metadataOnly: false,
    ), debugLabel: 'wallet-sqlite-restore');
    lastChangedRows = result.changedRows;
    lastScannedRows = result.scannedRows;
    _loaded = (
      data: null,
      revision: loaded.revision + 1,
      generation: loaded.generation,
    );
  }

  // Compatibility APIs are only for explicit snapshot import/export.
  @override
  Future<String?> load() async {
    final data = await loadSnapshot();
    return data == null ? null : compute(_export, data);
  }

  @override
  Future<void> save(String data) async =>
      replaceSnapshot(await compute(_import, data));
}

// No financial references enter the isolate message graph on a metadata write.
WalletData _metadataSnapshot(WalletMetadata metadata) => WalletData(
  accounts: [],
  transactions: [],
  categories: [],
  quickEntries: [],
).withMetadata(metadata);

String _export(WalletData data) => jsonEncode(data.toJson());
WalletData _import(String raw) => parseBackup(raw).data;

Database _open(String path) {
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA busy_timeout = 5000');
    final version = db.select('PRAGMA user_version').first.values.first as int;
    if (version > 1) throw UnsupportedError('数据库版本较新，请更新应用');
    db.execute('PRAGMA journal_mode = DELETE');
    db.execute('PRAGMA synchronous = FULL');
    db.execute(
      'CREATE TABLE IF NOT EXISTS wallet_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS wallet_rows ('
      'bucket TEXT NOT NULL, id TEXT NOT NULL, position INTEGER NOT NULL, '
      'kind TEXT NOT NULL, body TEXT NOT NULL, checksum TEXT NOT NULL, '
      'PRIMARY KEY(bucket, id))',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS wallet_order ON wallet_rows(bucket, position)',
    );
    for (final field in [
      'date',
      'type',
      'accountId',
      'transferFromId',
      'transferToId',
      'categoryId',
    ]) {
      db.execute(
        "CREATE INDEX IF NOT EXISTS wallet_tx_$field ON wallet_rows(json_extract(body,'\$.$field')) WHERE bucket='transactions'",
      );
    }
    db.execute('PRAGMA user_version = 1');
    return db;
  } catch (_) {
    db.close();
    rethrow;
  }
}

String? _meta(Database db, String key, [String schema = 'main']) =>
    db.select('SELECT value FROM $schema.wallet_meta WHERE key = ?', [
          key,
        ]).firstOrNull?['value']
        as String?;

void _setMeta(Database db, String key, String value, String schema) =>
    db.execute(
      'INSERT OR REPLACE INTO $schema.wallet_meta(key,value) VALUES (?,?)',
      [key, value],
    );

String _checksum(String bucket, String id, String kind, String body) => sha256
    .convert(utf8.encode(jsonEncode([bucket, id, kind, body])))
    .toString();
String _childBucket(String parent, String key) => jsonEncode([parent, key]);

_Loaded _read(Database db) {
  if (db.select('PRAGMA quick_check').any((r) => r.values.first != 'ok')) {
    throw const FormatException('数据库完整性检查失败');
  }
  final revision = int.parse(_meta(db, 'revision') ?? '0');
  final generation = _meta(db, 'generation') ?? '';
  if (_meta(db, 'initialized') != '1') {
    if (db.select('SELECT 1 FROM wallet_rows LIMIT 1').isNotEmpty) {
      throw const FormatException('数据库初始化未完成');
    }
    return (data: null, revision: revision, generation: generation);
  }
  final buckets = <String, List<Row>>{};
  for (final row in db.select(
    'SELECT * FROM wallet_rows ORDER BY bucket, position',
  )) {
    if (row['checksum'] !=
        _checksum(row['bucket'], row['id'], row['kind'], row['body'])) {
      throw const FormatException('数据库记录校验失败');
    }
    (buckets[row['bucket']] ??= []).add(row);
  }
  dynamic value(Row row) => row['kind'] == 'list'
      ? (buckets[_childBucket(row['bucket'], row['id'])] ?? [])
            .map(value)
            .toList()
      : jsonDecode(row['body']);
  final json = <String, dynamic>{'format': 'findash-flutter', 'schema': 1};
  for (final name in _listFields) {
    json[name] = (buckets[name] ?? []).map(value).toList();
  }
  for (final name in _mapFields) {
    json[name] = {
      for (final row in buckets[name] ?? <Row>[])
        row['id'] as String: value(row),
    };
  }
  final data = WalletData.fromJson(json);
  validateWallet(data);
  return (data: data, revision: revision, generation: generation);
}

_Loaded _readFile(String path) {
  final db = _open(path);
  try {
    return _read(db);
  } finally {
    db.close();
  }
}

// Copy only for migration or physical repair, never for ordinary saves.
void _copyVerified(String source, String destination) {
  final temporary = '$destination.recovering';
  File(source).copySync(temporary);
  _readFile(temporary);
  if (File(destination).existsSync()) {
    File(destination).renameSync(
      '$destination.damaged-${DateTime.now().microsecondsSinceEpoch}',
    );
  }
  File(temporary).renameSync(destination);
}

Future<WalletData?> _legacy(String path) async {
  final base = '${File(path).parent.path}/findash_ledger.json';
  var found = false;
  for (final name in [base, '$base.bak']) {
    if (!File(name).existsSync()) continue;
    found = true;
    try {
      return _import(unseal(await File(name).readAsString()));
    } catch (_) {}
  }
  if (found) throw const FormatException('旧账本和恢复副本均无法读取，原文件已保留');
  return null;
}

_Loaded _initializeEmpty(String path) {
  final mirror = _open('$path.bak');
  mirror.close();
  final db = _open(path);
  try {
    db.execute('ATTACH DATABASE ? AS recovery', ['$path.bak']);
    db.execute('PRAGMA recovery.synchronous = FULL');
    db.execute('BEGIN IMMEDIATE');
    try {
      // Another process may have completed initialization since our first read.
      if (_meta(db, 'initialized') == '1') {
        final current = _read(db);
        db.execute('COMMIT');
        return current;
      }
      if (_meta(db, 'initialized', 'recovery') == '1') {
        throw const FormatException('恢复副本已初始化，请重新打开账本');
      }
      final generation = _meta(db, 'generation') ?? newId();
      for (final schema in ['main', 'recovery']) {
        _setMeta(db, 'generation', generation, schema);
        _setMeta(db, 'revision', '0', schema);
      }
      db.execute('COMMIT');
      return (data: null, revision: 0, generation: generation);
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  } finally {
    db.close();
  }
}

_Loaded _readConsistent(String path) {
  final db = _open(path);
  try {
    db.execute('ATTACH DATABASE ? AS recovery', ['$path.bak']);
    db.execute('BEGIN');
    final loaded = _read(db);
    final futureVersion =
        db.select('PRAGMA recovery.user_version').first.values.first as int;
    if (futureVersion > 1) throw UnsupportedError('数据库版本较新，请更新应用');
    if (db
        .select('PRAGMA recovery.quick_check')
        .any((r) => r.values.first != 'ok')) {
      throw const FormatException('恢复副本完整性检查失败');
    }
    for (final pair in [('main', 'recovery'), ('recovery', 'main')]) {
      if (db
          .select(
            'SELECT bucket,id,position,kind,body,checksum FROM ${pair.$1}.wallet_rows EXCEPT SELECT bucket,id,position,kind,body,checksum FROM ${pair.$2}.wallet_rows LIMIT 1',
          )
          .isNotEmpty) {
        throw const FormatException('账本与恢复副本内容不一致');
      }
    }
    if (_meta(db, 'revision', 'recovery') != '${loaded.revision}' ||
        _meta(db, 'generation', 'recovery') != loaded.generation) {
      throw const FormatException('账本与恢复副本版本不一致，请使用备份恢复');
    }
    db.execute('COMMIT');
    return loaded;
  } finally {
    db.close();
  }
}

Future<_Loaded> _load(String path) async {
  File(path).parent.createSync(recursive: true);
  final mirror = '$path.bak';
  if (File(path).existsSync() && File(mirror).existsSync()) {
    try {
      final fast = _readConsistent(path);
      if (fast.data != null) return fast;
    } catch (error) {
      if (error is UnsupportedError) rethrow;
    }
  }
  if (!File(path).existsSync() && File(mirror).existsSync()) {
    _readFile(mirror);
    _copyVerified(mirror, path);
  }
  _Loaded? loaded;
  if (File(path).existsSync()) {
    try {
      loaded = _readFile(path);
    } catch (error) {
      if (error is UnsupportedError) rethrow;
      if (!File(mirror).existsSync()) rethrow;
      loaded = _readFile(mirror);
      _copyVerified(mirror, path);
    }
  }
  if (loaded == null || loaded.data == null) {
    final old = await _legacy(
      path,
    ); // Validate before publishing any migrated rows.
    loaded = _initializeEmpty(path);
    if (old != null && loaded.data == null) {
      _commit((
        path: path,
        revision: 0,
        generation: loaded.generation,
        previous: WalletData(),
        next: old,
        replace: true,
        metadataOnly: false,
      ));
      loaded = (data: old, revision: 1, generation: loaded.generation);
    }
  } else {
    if (!File(mirror).existsSync()) {
      File(path).copySync(mirror);
    } else {
      try {
        _readFile(mirror);
      } catch (error) {
        if (error is UnsupportedError) rethrow;
        _copyVerified(path, mirror);
      }
      // Recheck revisions in one read transaction below; a writer may have
      // committed between these independently verified file reads.
    }
  }
  return _readConsistent(path);
}

const _listFields = [
  'accounts',
  'transactions',
  'categories',
  'quickEntries',
  'goals',
  'chats',
];
const _mapFields = [
  'profile',
  'settings',
  'agent',
  'providerConfigs',
  'extras',
];
typedef _Key = (String, String);
typedef _Entry = ({Object? value, String kind});

Object? _json(Object? value) => switch (value) {
  WalletAccount v => v.toJson(),
  LedgerTx v => v.toJson(),
  WalletCategory v => v.toJson(),
  QuickEntry v => v.toJson(),
  _ => value,
};

bool _same(Object? a, Object? b) {
  if (identical(a, b)) return true;
  a = _json(a);
  b = _json(b);
  if (a is Map && b is Map) {
    final left = a, right = b;
    return left.length == right.length &&
        left.keys.every(
          (key) => right.containsKey(key) && _same(left[key], right[key]),
        );
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

Map<_Key, _Entry> _rows(WalletData data) {
  final result = <_Key, _Entry>{};
  void list(String bucket, List values) {
    final used = <String>{};
    for (var i = 0; i < values.length; i++) {
      final item = values[i];
      final String? rawId = switch (item) {
        WalletAccount v => v.id,
        LedgerTx v => v.id,
        WalletCategory v => v.id,
        QuickEntry v => v.id,
        Map v =>
          (v['id'] ?? v['eventId']) is String
              ? (v['id'] ?? v['eventId']) as String
              : null,
        _ => null,
      };
      var id = rawId == null ? 'index:$i' : 'id:$rawId';
      if (!used.add(id)) {
        id = 'duplicate:$i';
        used.add(id);
      }
      result[(bucket, id)] = (value: item, kind: 'value');
    }
  }

  list('accounts', data.accounts);
  list('transactions', data.transactions);
  list('categories', data.categories);
  list('quickEntries', data.quickEntries);
  list('goals', data.goals);
  list('chats', data.chats);
  for (final (name, map) in [
    ('profile', data.profile),
    ('settings', data.settings),
    ('agent', data.agent),
    ('providerConfigs', data.providerConfigs),
    ('extras', data.extras),
  ]) {
    for (final entry in map.entries) {
      if (entry.value is List) {
        result[(name, entry.key)] = (value: null, kind: 'list');
        list(_childBucket(name, entry.key), entry.value);
      } else {
        result[(name, entry.key)] = (value: entry.value, kind: 'value');
      }
    }
  }
  return result;
}

void _validateChange(_Commit request) {
  final next = request.next, previous = request.previous;
  if (request.metadataOnly) {
    for (final data in [previous, next]) {
      if (data.accounts.isNotEmpty ||
          data.transactions.isNotEmpty ||
          data.categories.isNotEmpty ||
          data.quickEntries.isNotEmpty ||
          request.replace ||
          request.revision == 0) {
        throw StateError('无效的元数据提交');
      }
    }
    return;
  }
  if (request.replace ||
      request.revision == 0 ||
      !listEquals(previous.accounts, next.accounts)) {
    validateWallet(next);
    return;
  }
  final old = {for (final tx in previous.transactions) tx.id: tx};
  final seen = <String>{};
  final changed = <LedgerTx>[];
  for (final tx in next.transactions) {
    if (tx.id.isEmpty || !seen.add(tx.id)) {
      throw const FormatException('账本包含重复或空的记录 ID');
    }
    if (!identical(old[tx.id], tx)) changed.add(tx);
  }
  // Unchanged immutable transactions were validated on load/last commit.
  // Account changes use a full check above to catch dangling references.
  validateWallet(
    WalletData(
      accounts: next.accounts,
      transactions: changed,
      categories: next.categories,
      quickEntries: next.quickEntries,
    ),
  );
}

_CommitStats _commit(_Commit request) {
  _validateChange(request);
  final db = _open(request.path);
  try {
    db.execute('ATTACH DATABASE ? AS recovery', ['${request.path}.bak']);
    db.execute('PRAGMA recovery.journal_mode = DELETE');
    db.execute('PRAGMA recovery.synchronous = FULL');
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final schema in ['main', 'recovery']) {
        if ((_meta(db, 'revision', schema) ?? '0') != '${request.revision}' ||
            _meta(db, 'generation', schema) != request.generation) {
          throw const FormatException('账本已被其他实例更新，请重新打开后重试');
        }
      }
      final previous = request.revision == 0
          ? <_Key, _Entry>{}
          : _rows(request.replace ? _read(db).data! : request.previous);
      final next = _rows(request.next);
      final positionRows = request.metadataOnly
          ? [
              for (final bucket in {
                ...previous.keys.map((key) => key.$1),
                ...next.keys.map((key) => key.$1),
              })
                ...db.select(
                  'SELECT bucket,id,position FROM wallet_rows WHERE bucket=?',
                  [bucket],
                ),
            ]
          : db.select('SELECT bucket,id,position FROM wallet_rows');
      final positions = <_Key, int>{
        for (final r in positionRows)
          (r['bucket'] as String, r['id'] as String): r['position'] as int,
      };
      final ranks = <_Key, int>{};
      final buckets = <String, List<_Key>>{};
      for (final key in next.keys) {
        (buckets[key.$1] ??= []).add(key);
      }
      for (final keys in buckets.values) {
        var last = -1;
        var maximum = positions.entries
            .where((e) => e.key.$1 == keys.first.$1)
            .fold<int>(-1, (a, e) => a > e.value ? a : e.value);
        var stable = true;
        for (final key in keys) {
          final rank = positions[key];
          if (rank != null) {
            if (rank <= last) {
              stable = false;
              break;
            }
            last = rank;
          } else {
            // Appends preserve old ranks; middle inserts/reorders renumber only positions.
            last = ++maximum;
          }
          ranks[key] = last;
        }
        if (!stable) {
          for (var i = 0; i < keys.length; i++) {
            ranks[keys[i]] = i;
          }
        }
      }
      var changed = 0;
      final remove = db.prepare(
        'DELETE FROM main.wallet_rows WHERE bucket=? AND id=?',
      );
      final removeBackup = db.prepare(
        'DELETE FROM recovery.wallet_rows WHERE bucket=? AND id=?',
      );
      final write = db.prepare(
        'INSERT OR REPLACE INTO main.wallet_rows VALUES (?,?,?,?,?,?)',
      );
      final writeBackup = db.prepare(
        'INSERT OR REPLACE INTO recovery.wallet_rows VALUES (?,?,?,?,?,?)',
      );
      final order = db.prepare(
        'UPDATE main.wallet_rows SET position=? WHERE bucket=? AND id=?',
      );
      final orderBackup = db.prepare(
        'UPDATE recovery.wallet_rows SET position=? WHERE bucket=? AND id=?',
      );
      try {
        for (final key in previous.keys.where(
          (key) => !next.containsKey(key),
        )) {
          remove.execute([key.$1, key.$2]);
          removeBackup.execute([key.$1, key.$2]);
          changed++;
        }
        for (final entry in next.entries) {
          final key = entry.key, value = entry.value;
          final old = previous[key];
          if (old == null ||
              old.kind != value.kind ||
              !_same(old.value, value.value)) {
            final body = jsonEncode(_json(value.value));
            final args = [
              key.$1,
              key.$2,
              ranks[key]!,
              value.kind,
              body,
              _checksum(key.$1, key.$2, value.kind, body),
            ];
            write.execute(args);
            writeBackup.execute(args);
            changed++;
          } else if (positions[key] != ranks[key]) {
            final args = [ranks[key]!, key.$1, key.$2];
            order.execute(args);
            orderBackup.execute(args);
            changed++;
          }
        }
      } finally {
        remove.close();
        removeBackup.close();
        write.close();
        writeBackup.close();
        order.close();
        orderBackup.close();
      }
      for (final schema in ['main', 'recovery']) {
        _setMeta(db, 'revision', '${request.revision + 1}', schema);
        _setMeta(db, 'initialized', '1', schema);
      }
      db.execute('COMMIT');
      return (
        changedRows: changed,
        scannedRows: previous.length + next.length + positions.length,
      );
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  } finally {
    db.close();
  }
}

Json _queryRecords((String, int, String, Json) request) {
  final (path, revision, generation, args) = request;
  final db = _open(path);
  try {
    db.execute('BEGIN');
    if (_meta(db, 'revision') != '$revision' ||
        _meta(db, 'generation') != generation) {
      throw const FormatException('账本已变化，请重新查询');
    }
    final clauses = <String>["bucket='transactions'"], values = <Object?>[];
    for (final pair in [('type', 'type'), ('categoryId', 'categoryId')]) {
      if (args[pair.$1] != null) {
        clauses.add("json_extract(body,'\$.${pair.$2}')=?");
        values.add(args[pair.$1]);
      }
    }
    if (args['accountId'] != null) {
      clauses.add(
        "(json_extract(body,'\$.accountId')=? OR json_extract(body,'\$.transferFromId')=? OR json_extract(body,'\$.transferToId')=?)",
      );
      values.addAll(List.filled(3, args['accountId']));
    }
    if (args['startInclusive'] != null) {
      clauses.add(
        "json_extract(body,'\$.date')>=? AND json_extract(body,'\$.date')<?",
      );
      values.addAll([args['startInclusive'], args['endExclusive']]);
    }
    final where = clauses.join(' AND ');
    final totals = db
        .select(
          "SELECT COUNT(*) AS count, "
          "COALESCE(SUM(CASE WHEN json_extract(body,'\$.type')='expense' THEN json_extract(body,'\$.amountCents') ELSE 0 END),0) AS expense, "
          "COALESCE(SUM(CASE WHEN json_extract(body,'\$.type')='income' THEN json_extract(body,'\$.amountCents') ELSE 0 END),0) AS income "
          'FROM wallet_rows WHERE $where',
          values,
        )
        .single;
    final rows = args['aggregate'] == true
        ? <Row>[]
        : db.select(
            "SELECT body,checksum,id,kind,bucket FROM wallet_rows WHERE $where ORDER BY json_extract(body,'\$.date') DESC,id ASC LIMIT ? OFFSET ?",
            [...values, args['limit'], args['offset']],
          );
    final transactions = <Json>[];
    for (final row in rows) {
      if (row['checksum'] !=
          _checksum(row['bucket'], row['id'], row['kind'], row['body'])) {
        throw const FormatException('数据库记录校验失败');
      }
      transactions.add(Json.from(jsonDecode(row['body'])));
    }
    return {
      'transactions': transactions,
      'expenseCents': totals['expense'],
      'incomeCents': totals['income'],
      'transactionCount': totals['count'],
    };
  } finally {
    db.close();
  }
}

_CommitStats _commitRecords((String, int, String, LedgerChangeSet) request) {
  final (path, revision, generation, changes) = request;
  if (revision == 0) throw StateError('记录提交需要已初始化的账本');
  final previous = _rows(changes.previous), next = _rows(changes.next);
  const financial = {'accounts', 'transactions', 'categories', 'quickEntries'};
  final moved = {
    'accounts': changes.movedAccountIds,
    'transactions': changes.movedTransactionIds,
    'categories': changes.movedCategoryIds,
    'quickEntries': changes.movedQuickIds,
  };
  final db = _open(path);
  var scanned = previous.length + next.length, changed = 0;
  try {
    db.execute('ATTACH DATABASE ? AS recovery', ['$path.bak']);
    db.execute('PRAGMA recovery.journal_mode = DELETE');
    db.execute('PRAGMA recovery.synchronous = FULL');
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final schema in ['main', 'recovery']) {
        if (_meta(db, 'revision', schema) != '$revision' ||
            _meta(db, 'generation', schema) != generation) {
          throw const FormatException('账本已被其他实例更新，请重新打开后重试');
        }
      }
      final positions = <_Key, int>{};
      final maxima = <String, int>{};
      for (final bucket in {
        ...previous.keys.map((k) => k.$1),
        ...next.keys.map((k) => k.$1),
      }) {
        if (financial.contains(bucket)) {
          maxima[bucket] =
              db.select(
                    'SELECT MAX(position) AS maximum FROM wallet_rows WHERE bucket=?',
                    [bucket],
                  ).single['maximum']
                  as int? ??
              -1;
          for (final key in {
            ...previous.keys,
            ...next.keys,
          }.where((k) => k.$1 == bucket)) {
            final row = db.select(
              'SELECT * FROM wallet_rows WHERE bucket=? AND id=?',
              [key.$1, key.$2],
            ).firstOrNull;
            scanned++;
            if (row != null) {
              if (row['checksum'] !=
                  _checksum(
                    row['bucket'],
                    row['id'],
                    row['kind'],
                    row['body'],
                  )) {
                throw const FormatException('数据库记录校验失败');
              }
              positions[key] = row['position'];
              if (!previous.containsKey(key)) {
                throw const FormatException('账本包含重复的记录 ID');
              }
            }
          }
        } else {
          final rows = db.select(
            'SELECT id,position FROM wallet_rows WHERE bucket=?',
            [bucket],
          );
          scanned += rows.length;
          for (final row in rows) {
            positions[(bucket, row['id'] as String)] = row['position'];
          }
        }
      }
      // Validate changed transactions against current accounts inside this transaction.
      final accountRows = <String, WalletAccount>{
        for (final a in changes.next.accounts) a.id: a,
      };
      final removedAccounts = changes.previous.accounts
          .map((a) => a.id)
          .where((id) => !accountRows.containsKey(id))
          .toSet();
      for (final t in changes.next.transactions) {
        for (final id in {t.accountId, t.fromId, t.toId}.whereType<String>()) {
          if (removedAccounts.contains(id)) {
            throw const FormatException('账单关联账户不存在');
          }
          if (!accountRows.containsKey(id)) {
            final row = db.select(
              "SELECT body FROM wallet_rows WHERE bucket='accounts' AND id=?",
              ['id:$id'],
            ).firstOrNull;
            scanned++;
            if (row == null) throw const FormatException('账单关联账户不存在');
            accountRows[id] = WalletAccount.fromJson(
              Json.from(jsonDecode(row['body'])),
            );
          }
        }
      }
      validateWallet(
        WalletData(
          accounts: accountRows.values.toList(),
          transactions: changes.next.transactions,
          categories: changes.next.categories,
          quickEntries: changes.next.quickEntries,
        ),
      );
      for (final id in removedAccounts) {
        final references = db.select(
          "SELECT id,body FROM wallet_rows WHERE bucket='transactions' AND "
          "(json_extract(body,'\$.accountId')=? OR json_extract(body,'\$.transferFromId')=? OR json_extract(body,'\$.transferToId')=?)",
          [id, id, id],
        );
        scanned += references.length;
        for (final row in references) {
          final key = ('transactions', row['id'] as String);
          if (previous.containsKey(key) && !next.containsKey(key)) continue;
          final tx =
              next[key]?.value as LedgerTx? ??
              LedgerTx.fromJson(Json.from(jsonDecode(row['body'])));
          if ([tx.accountId, tx.fromId, tx.toId].contains(id)) {
            throw const FormatException('账户有关联账单，不能删除');
          }
        }
      }
      final ranks = <_Key, int>{};
      for (final bucket in next.keys.map((k) => k.$1).toSet()) {
        final keys = next.keys.where((k) => k.$1 == bucket).toList();
        var maximum =
            maxima[bucket] ??
            positions.entries
                .where((e) => e.key.$1 == bucket)
                .fold<int>(-1, (a, e) => a > e.value ? a : e.value);
        var last = -1, stable = true;
        for (final key in keys) {
          final rank =
              financial.contains(bucket) &&
                  moved[bucket]!.contains(key.$2.substring(3))
              ? ++maximum
              : positions[key] ?? ++maximum;
          if (rank <= last) stable = false;
          ranks[key] = rank;
          last = rank;
        }
        if (!financial.contains(bucket) && !stable) {
          for (var i = 0; i < keys.length; i++) {
            ranks[keys[i]] = i;
          }
        }
      }
      for (final key in previous.keys.where((k) => !next.containsKey(k))) {
        for (final schema in ['main', 'recovery']) {
          db.execute(
            'DELETE FROM $schema.wallet_rows WHERE bucket=? AND id=?',
            [key.$1, key.$2],
          );
        }
        changed++;
      }
      for (final entry in next.entries) {
        final key = entry.key, value = entry.value, old = previous[key];
        if (old != null &&
            old.kind == value.kind &&
            _same(old.value, value.value) &&
            positions[key] == ranks[key]) {
          continue;
        }
        final body = jsonEncode(_json(value.value));
        for (final schema in ['main', 'recovery']) {
          db.execute(
            'INSERT OR REPLACE INTO $schema.wallet_rows VALUES (?,?,?,?,?,?)',
            [
              key.$1,
              key.$2,
              ranks[key],
              value.kind,
              body,
              _checksum(key.$1, key.$2, value.kind, body),
            ],
          );
        }
        changed++;
      }
      for (final schema in ['main', 'recovery']) {
        _setMeta(db, 'revision', '${revision + 1}', schema);
      }
      db.execute('COMMIT');
      return (changedRows: changed, scannedRows: scanned);
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  } finally {
    db.close();
  }
}

Future<_Loaded> _restoreDamaged((String, WalletData) request) async {
  final (path, data) = request;
  validateWallet(data);
  final stage = '$path.restore-${DateTime.now().microsecondsSinceEpoch}';
  final staged = _open(stage);
  final generation = newId();
  try {
    _setMeta(staged, 'generation', generation, 'main');
    _setMeta(staged, 'revision', '0', 'main');
  } finally {
    staged.close();
  }
  File(stage).copySync('$stage.bak');
  final blank = (revision: 0, generation: generation);
  _commit((
    path: stage,
    revision: blank.revision,
    generation: blank.generation,
    previous: WalletData(),
    next: data,
    replace: true,
    metadataOnly: false,
  ));
  final verified = _readFile(stage);
  final moved = <(String, String)>[];
  final installed = <String>[];
  try {
    for (final suffix in ['', '.bak']) {
      final target = '$path$suffix';
      if (File(target).existsSync()) {
        final retained =
            '$target.before-restore-${DateTime.now().microsecondsSinceEpoch}';
        File(target).renameSync(retained);
        moved.add((target, retained));
      }
      File('$stage$suffix').renameSync(target);
      installed.add(target);
    }
  } catch (_) {
    for (final target in installed.reversed) {
      File(target).renameSync(
        '$target.uninstalled-${DateTime.now().microsecondsSinceEpoch}',
      );
    }
    for (final (target, retained) in moved.reversed) {
      File(retained).renameSync(target);
    }
    rethrow;
  }
  return verified;
}
