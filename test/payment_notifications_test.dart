import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/services/payment_notifications.dart';
import 'helpers.dart';

Json event([String char = 'a', String kind = 'expense']) => {
  'eventId': char * 64,
  'sourcePackage': 'com.tencent.mm',
  'notificationKey': 'key',
  'postedAt': DateTime(2026, 10, 1, 12).millisecondsSinceEpoch,
  'title': '微信支付',
  'text': '支付￥1.50（午餐）',
  'amountCents': 150,
  'kind': kind,
  'merchant': '午餐',
  'reviewReason': '核对',
  'ruleVersion': 1,
};

class FakeBridge implements NotificationBridge {
  final List<Json> events;
  bool failAck = false;
  int acknowledgements = 0;
  final List<String> calls = [];
  Completer<void>? peekGate;
  final peekStarted = Completer<void>();
  FakeBridge(this.events);
  @override
  bool get supported => true;
  @override
  Future<dynamic> call(String method, [Json? arguments]) async {
    calls.add(method);
    if (method == 'peek') {
      if (!peekStarted.isCompleted) peekStarted.complete();
      await peekGate?.future;
      return events.toList();
    }
    if (method == 'ack') {
      if (failAck) throw StateError('Interrupted after save');
      acknowledgements++;
      events.removeWhere(
        (e) => (arguments!['ids'] as List).contains(e['eventId']),
      );
    }
    return null;
  }
}

void main() {
  test(
    'page clear waits for lifecycle sync and cleared events never replay',
    () async {
      final bridge = FakeBridge([event()])..peekGate = Completer<void>();
      final store = await emptyStore();
      final lifecycle = PaymentNotifications(store, bridge: bridge);
      final page = PaymentNotifications(store, bridge: bridge);
      final syncing = lifecycle.sync();
      await bridge.peekStarted.future;
      final clearing = page.clearPending();
      await Future<void>.delayed(Duration.zero);
      expect(bridge.calls, ['peek']);
      bridge.peekGate!.complete();
      await Future.wait([syncing, clearing]);
      expect(
        bridge.calls.indexOf('ack'),
        lessThan(bridge.calls.indexOf('setEnabled')),
      );
      expect(page.records.single['status'], 'ignored');
      expect(page.records.single['text'], '');
      bridge.events.add(event());
      await lifecycle.sync();
      expect(page.records.length, 1);
      expect(page.records.single['status'], 'ignored');
    },
  );

  test('failed ledger save does not ACK or lose native events', () async {
    final storage = MemoryStorage(), bridge = FakeBridge([event()]);
    final store = await emptyStore(storage);
    final inbox = PaymentNotifications(store, bridge: bridge);
    storage.failWrites = true;
    await expectLater(inbox.sync(), throwsStateError);
    expect(bridge.acknowledgements, 0);
    expect(bridge.events.length, 1);
    expect(inbox.records, isEmpty);
    storage.failWrites = false;
    await inbox.sync();
    expect(inbox.records.length, 1);
    expect(bridge.events, isEmpty);
  });

  test(
    'crash between durable save and ACK replays without duplication',
    () async {
      final storage = MemoryStorage(), bridge = FakeBridge([event()]);
      final store = await emptyStore(storage);
      bridge.failAck = true;
      await expectLater(
        PaymentNotifications(store, bridge: bridge).sync(),
        throwsStateError,
      );
      final reloaded = await emptyStore(storage);
      bridge.failAck = false;
      final inbox = PaymentNotifications(reloaded, bridge: bridge);
      await inbox.sync();
      expect(inbox.records.length, 1);
      expect(bridge.events, isEmpty);
    },
  );

  test(
    'same event dedupes; separate similar events remain for review',
    () async {
      final store = await emptyStore();
      final inbox = PaymentNotifications(store);
      await inbox.ingest([event(), event(), event('b')]);
      expect(inbox.records.length, 2);
      expect(inbox.records.first['possibleDuplicate'], true);
      expect(store.data.transactions, isEmpty);
    },
  );

  test('acceptance is atomic, idempotent, and requires an account', () async {
    final storage = MemoryStorage();
    final store = await emptyStore(storage);
    await store.saveAccount(bank);
    final inbox = PaymentNotifications(store);
    await inbox.ingest([event()]);
    await expectLater(
      inbox.accept('a' * 64, tx(account: null)),
      throwsFormatException,
    );
    storage.failWrites = true;
    await expectLater(inbox.accept('a' * 64, tx()), throwsStateError);
    expect(store.data.transactions, isEmpty);
    expect(inbox.records.single['status'], 'pending');
    storage.failWrites = false;
    await inbox.accept('a' * 64, tx());
    await inbox.accept('a' * 64, tx());
    expect(store.data.transactions.length, 1);
    expect(store.balance(bank), 99850);
    expect(inbox.records.single['transactionId'], 'tx');
  });

  test(
    'refund cannot silently become income; ignored event stays deduplicated',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final inbox = PaymentNotifications(store);
      await inbox.ingest([event('a', 'refund')]);
      await expectLater(
        inbox.accept('a' * 64, tx(type: TxType.income)),
        throwsFormatException,
      );
      await inbox.dismiss('a' * 64);
      await inbox.ingest([event('a', 'refund')]);
      expect(inbox.records.single['status'], 'ignored');
      expect(inbox.records.single['text'], event('a', 'refund')['text']);
    },
  );

  test('similar existing ledger needs an explicit duplicate review', () async {
    final store = await emptyStore();
    await store.saveAccount(bank);
    await store.saveTx(tx());
    final inbox = PaymentNotifications(store);
    await inbox.ingest([event()]);
    await expectLater(
      inbox.accept('a' * 64, tx(id: 'next')),
      throwsFormatException,
    );
    await inbox.accept('a' * 64, tx(id: 'next'), duplicateReviewed: true);
    expect(store.data.transactions.length, 2);
  });

  test(
    'untrusted source and invalid amount cannot enter candidate storage',
    () async {
      final store = await emptyStore();
      final inbox = PaymentNotifications(store);
      await expectLater(
        inbox.ingest([
          {...event(), 'sourcePackage': 'chat.app'},
        ]),
        throwsFormatException,
      );
      await expectLater(
        inbox.ingest([
          {...event(), 'amountCents': 0.1},
        ]),
        throwsFormatException,
      );
      expect(inbox.records, isEmpty);
    },
  );
}
