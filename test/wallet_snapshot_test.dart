import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/data/backup.dart';
import 'package:fin_dash/data/wallet_codec.dart';
import 'package:fin_dash/domain/models.dart';
import 'helpers.dart';

class GatedStorage extends MemoryStorage {
  Completer<void>? gate;
  final started = Completer<void>();
  @override
  Future<void> save(String data) async {
    final pending = gate;
    gate = null;
    if (pending != null) {
      started.complete();
      await pending.future;
      throw StateError('simulated disk failure');
    }
    await super.save(data);
  }
}

WalletData largeWallet() => WalletData(
  accounts: [bank],
  transactions: [for (var i = 0; i < 1500; i++) tx(id: 'large-$i')],
);

void main() {
  test('large restore commits only after a successful durable write', () async {
    final storage = MemoryStorage();
    final store = await emptyStore(storage);
    await store.saveAccount(bank);
    final previous = store.data;
    final preview = ImportPreview(largeWallet(), [], false);
    storage.failWrites = true;
    await expectLater(store.restore(preview), throwsStateError);
    expect(store.data, same(previous));
    storage.failWrites = false;
    await store.restore(preview);
    expect(store.data.transactions.length, 1500);
    preview.data.transactions.clear();
    expect(store.data.transactions.length, 1500);
    expect(
      (await decodeWalletSnapshot(storage.content!)).transactions.length,
      1500,
    );
  });

  test('snapshot shares immutable records but detaches every mutable tree', () {
    Json nested() => {
      'nested': [
        {'value': 'before'},
      ],
    };
    final source = WalletData(
      accounts: [bank],
      transactions: [tx()],
      profile: nested(),
      settings: nested(),
      agent: nested(),
      providerConfigs: nested(),
      extras: nested(),
      goals: [nested()],
      chats: [nested()],
    );
    final before = jsonEncode(source.toJson());
    final copy = source.clone();
    expect(copy.transactions.single, same(source.transactions.single));
    expect(copy.accounts.single, same(source.accounts.single));
    for (final tree in [
      copy.profile,
      copy.settings,
      copy.agent,
      copy.providerConfigs,
      copy.extras,
      copy.goals.single,
      copy.chats.single,
    ]) {
      (tree['nested'] as List).first['value'] = 'changed';
    }
    copy.transactions.clear();
    copy.accounts.clear();
    copy.categories.clear();
    copy.quickEntries.add(
      const QuickEntry(
        id: 'q',
        title: 'q',
        type: TxType.expense,
        category: '其他',
        icon: 'receipt',
      ),
    );
    expect(jsonEncode(source.toJson()), before);
  });

  test('large snapshot round trips with full validation', () async {
    final data = largeWallet();
    final encoded = await encodeWalletSnapshot(data);
    final decoded = await decodeWalletSnapshot(encoded);
    expect(decoded.toJson(), data.toJson());
    data.transactions.add(data.transactions.first);
    await expectLater(encodeWalletSnapshot(data), throwsFormatException);
  });

  test(
    'failed large save never publishes its draft and queued save uses committed data',
    () async {
      final storage = GatedStorage()
        ..content = await encodeWalletSnapshot(largeWallet());
      final store = await emptyStore(storage);
      final committed = store.data;
      var notifications = 0;
      store.addListener(() => notifications++);
      final release = Completer<void>();
      storage.gate = release;
      final failed = store.change((d) {
        d.transactions.add(tx(id: 'failed'));
        d.extras['draftOnly'] = {
          'items': [1],
        };
      });
      final failure = expectLater(failed, throwsStateError);
      await storage.started.future;
      final next = store.saveTx(tx(id: 'after-failure'));
      expect(store.data, same(committed));
      expect(notifications, 0);
      release.complete();
      await failure;
      await next;
      expect(store.data.transactions.length, 1501);
      expect(store.data.transactions.last.id, 'after-failure');
      expect(store.data.extras.containsKey('draftOnly'), false);
      expect(notifications, 1);
      expect(
        (await decodeWalletSnapshot(storage.content!)).toJson(),
        store.data.toJson(),
      );
    },
  );
}
