import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:fin_dash/data/backup.dart';
import 'package:fin_dash/data/storage_sqlite.dart';
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/domain/models.dart';
import 'helpers.dart';
import 'package:fin_dash/data/wallet_migration.dart';

void main() {
  late Directory dir;
  String path() => '${dir.path}/findash_ledger.sqlite';
  Future<void> damagePrimary() async {
    await File(path()).writeAsString('broken sqlite');
    final wal = File('${path()}-wal');
    if (await wal.exists()) await wal.writeAsString('broken WAL');
  }

  Future<WalletStore> open() async {
    final store = WalletStore(LocalWalletStorage(directory: dir));
    await store.initialize();
    return store;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('findash-sqlite-');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test(
    'large ledger changes only changed rows and preserves order and metadata',
    () async {
      final store = await open();
      expect(store.startupError, null);
      await store.saveAccount(bank);
      await store.change((d) {
        d.transactions.addAll([for (var i = 0; i < 2000; i++) tx(id: 't-$i')]);
        d.settings['quickEntryAccountId'] = 'bank';
        d.chats = [
          {'id': 'm1', 'content': '你好'},
          {'id': 'm2', 'content': '世界'},
        ];
        d.extras['paymentNotifications'] = [
          {'eventId': 'n1', 'status': 'pending'},
          {'eventId': 'n2', 'status': 'pending'},
        ];
        d.extras['misc'] = [
          1,
          {
            'nested': [true, null, '中文😀'],
          },
        ];
      });
      final storage = store.storage as LocalWalletStorage;
      await store.saveTx(tx(id: 'new'));
      expect(storage.lastChangedRows, 2);
      await store.deleteTxs({'t-500'});
      expect(
        storage.lastChangedRows,
        2,
        reason:
            'deletion plus ledger revision must not rewrite remaining ranks',
      );
      await store.change((d) {
        (d.extras['paymentNotifications'] as List)[0]['status'] = 'applied';
      });
      expect(storage.lastChangedRows, 1);
      expect((await open()).data.toJson(), store.data.toJson());
      await store.change((d) {
        d.transactions = d.transactions.reversed.toList();
      });
      expect((await open()).data.toJson(), store.data.toJson());
      await store.change((d) {
        d.chats.insert(1, {'id': 'middle', 'content': '新消息'});
      });
      expect((await open()).data.chats, store.data.chats);
      final ledger = store.data;
      final revision = store.ledgerRevision;
      await store.changeMetadata((d) => d.settings['theme'] = 'dark');
      expect(store.data.transactions, same(ledger.transactions));
      expect(store.data.accounts, same(ledger.accounts));
      expect(store.ledgerRevision, revision);
      expect(storage.lastChangedRows, 1);
      expect(storage.lastScannedRows, lessThan(100));
      expect((await open()).data.toJson(), store.data.toJson());
    },
  );

  test(
    'legacy primary or verified backup migrates once without deleting source',
    () async {
      final data = WalletData(accounts: [bank], transactions: [tx()]);
      final legacy = File('${dir.path}/findash_ledger.json');
      final backup = File('${legacy.path}.bak');
      await legacy.writeAsString('{}');
      final original = seal(jsonEncode(data.toJson()));
      await backup.writeAsString(original);
      final store = await open();
      expect(store.startupError, null);
      final expected = migrateWallet(data);
      expected.extras['ledgerEpoch'] = store.ledgerEpoch;
      expect(store.data.toJson(), expected.toJson());
      await store.saveTx(tx(id: 'new'));
      expect((await open()).data.transactions.length, 2);
      expect(await backup.readAsString(), original);
      expect(await legacy.readAsString(), '{}');
    },
  );

  test(
    'corrupt legacy data never becomes an empty initialized database',
    () async {
      await File('${dir.path}/findash_ledger.json').writeAsString('{}');
      final store = await open();
      expect(store.startupError, isNotNull);
      expect(File(path()).existsSync(), false);
      await store.restore(
        ImportPreview(
          WalletData(accounts: [bank], transactions: [tx()]),
          [],
          false,
        ),
      );
      expect(store.startupError, null);
      expect((await open()).data.transactions.length, 1);
    },
  );

  test(
    'mirror failure keeps committed data and retries successfully',
    () async {
      final store = await open();
      await store.saveAccount(bank);
      await store.flushMirror();
      final before = store.data;
      final saved = File('${path()}.bak.saved');
      await File('${path()}.bak').rename(saved.path);
      final blocked = Directory('${path()}.bak');
      await blocked.create();
      await store.saveTx(tx());
      expect(store.data, isNot(same(before)));
      expect(store.data.transactions.single.id, 'tx');
      await expectLater(
        (store.storage as LocalWalletStorage).flushMirror(),
        throwsA(isA<FileSystemException>()),
      );
      await blocked.delete();
      await saved.rename('${path()}.bak');
      await store.flushMirror();
      expect((await open()).data.transactions.single.id, 'tx');
    },
  );

  test('stale instance cannot overwrite another committed ledger', () async {
    final first = await open();
    await first.saveAccount(bank);
    final second = await open();
    await first.saveTx(tx(id: 'first'));
    await expectLater(second.saveTx(tx(id: 'stale')), throwsFormatException);
    expect((await open()).data.transactions.single.id, 'first');
  });

  test(
    'physical corruption recovers latest committed replica, not old JSON',
    () async {
      final store = await open();
      await store.saveAccount(bank);
      await store.saveTx(tx());
      final expected = store.data.toJson();
      await store.flushMirror();
      await damagePrimary();
      final restored = await open();
      expect(restored.startupError, null);
      expect(restored.data.toJson(), expected);
      expect(dir.listSync().any((f) => f.path.contains('.damaged-')), true);
    },
  );

  test('lagging mirror recovery gives a nonfatal loss notice', () async {
    final store = await open();
    await store.saveAccount(bank);
    await store.flushMirror();
    await store.saveTx(tx());
    await damagePrimary();
    final restored = await open();
    expect(restored.startupError, null);
    expect(restored.data.accounts.single.id, 'bank');
    expect(restored.data.transactions, isEmpty);
    expect(restored.recoveryNotice, contains('副本之后的修改可能丢失'));
  });
  test(
    'recreated empty primary never replaces an initialized mirror',
    () async {
      final store = await open();
      await store.saveAccount(bank);
      await store.saveTx(tx());
      await store.flushMirror();
      final expected = store.data.toJson();
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('${path()}$suffix');
        if (await file.exists()) await file.delete();
      }
      final empty = sqlite3.open(path());
      empty.execute('PRAGMA user_version = 2');
      empty.close();
      final restored = await open();
      expect(restored.startupError, null);
      expect(restored.data.toJson(), expected);
      expect(restored.recoveryNotice, isNotNull);
    },
  );
  test('consistent v1 upgrades in place to WAL schema 2', () async {
    final store = await open();
    await store.saveAccount(bank);
    await store.saveTx(tx());
    await store.flushMirror();
    final expected = store.data.toJson();
    for (final suffix in ['', '.bak']) {
      final db = sqlite3.open('${path()}$suffix');
      db.execute('PRAGMA journal_mode = DELETE');
      db.execute('PRAGMA user_version = 1');
      db.close();
    }
    final upgraded = await open();
    expect(upgraded.startupError, null);
    expect(upgraded.data.toJson(), expected);
    final db = sqlite3.open(path());
    expect(db.select('PRAGMA user_version').first.values.first, 2);
    expect(db.select('PRAGMA journal_mode').first.values.first, 'wal');
    db.close();
    // ignore: avoid_print
    print(
      'Bundled SQLite ${sqlite3.version.libVersion}; VACUUM INTO supported',
    );
  });

  test(
    'explicit restore can replace two damaged databases and survives reopening',
    () async {
      final initial = await open();
      await initial.saveAccount(bank);
      await damagePrimary();
      await File('${path()}.bak').writeAsString('bad');
      final store = await open();
      expect(store.startupError, isNotNull);
      await store.restore(
        ImportPreview(
          WalletData(accounts: [bank], transactions: [tx()]),
          [],
          false,
        ),
      );
      expect(store.startupError, null);
      expect((await open()).data.transactions.single.id, 'tx');
    },
  );

  test('invalid candidate is rejected before any SQL changes', () async {
    final store = await open();
    await store.saveAccount(bank);
    await store.saveTx(tx());
    await expectLater(
      store.change((d) => d.transactions.add(tx())),
      throwsFormatException,
    );
    expect((await open()).data.transactions.length, 1);
    await expectLater(
      store.change((d) => d.accounts.clear()),
      throwsFormatException,
    );
    await expectLater(store.saveTx(tx(amount: -1)), throwsFormatException);
    expect((await open()).data.accounts.single.id, 'bank');
  });

  test(
    'concurrent first opens share one generation and reject stale commits',
    () async {
      final stores = await Future.wait([open(), open()]);
      expect(stores.map((s) => s.startupError), [null, null]);
      await stores.first.saveAccount(bank);
      await expectLater(stores.last.saveAccount(cash), throwsFormatException);
      expect((await open()).data.accounts.single.id, 'bank');
    },
  );

  test('closing an uncommitted WAL transaction discards changes', () async {
    final store = await open();
    await store.saveAccount(bank);
    await store.saveTx(tx());
    final db = sqlite3.open(path());
    expect(db.select('PRAGMA journal_mode').first.values.first, 'wal');
    expect(db.select('PRAGMA synchronous').first.values.first, 2);
    db.execute('BEGIN IMMEDIATE');
    db.execute("DELETE FROM main.wallet_rows WHERE bucket='transactions'");
    db.close();
    expect((await open()).data.transactions.single.id, 'tx');
  });

  test('interrupted migration retries from retained legacy files', () async {
    await open(); // Empty schema, no initialized ledger yet.
    final legacy = File('${dir.path}/findash_ledger.json');
    final original = seal(
      jsonEncode(WalletData(accounts: [bank], transactions: [tx()]).toJson()),
    );
    await legacy.writeAsString(original);
    final db = sqlite3.open(path());
    db.execute(
      "CREATE TRIGGER interrupt_migration BEFORE INSERT ON wallet_rows BEGIN SELECT RAISE(ABORT,'interrupted migration'); END",
    );
    db.close();
    expect((await open()).startupError, isNotNull);
    expect(await legacy.readAsString(), original);
    final fixed = sqlite3.open(path());
    fixed.execute('DROP TRIGGER interrupt_migration');
    fixed.close();
    expect((await open()).data.transactions.single.id, 'tx');
  });

  test(
    'future database schemas are never silently downgraded from replica',
    () async {
      final store = await open();
      await store.saveAccount(bank);
      final db = sqlite3.open(path());
      db.execute('PRAGMA user_version = 3');
      db.close();
      expect((await open()).startupError, contains('请更新应用'));
      final check = sqlite3.open(path());
      expect(check.select('PRAGMA user_version').first.values.first, 3);
      check.close();
    },
  );
}
