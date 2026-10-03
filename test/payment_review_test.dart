import 'package:flutter/material.dart';
import 'package:fin_dash/ui/interaction.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/main.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/services/payment_notifications.dart';
import 'package:fin_dash/ui/finance_pages.dart';
import 'package:fin_dash/ui/payment_review_page.dart';
import 'package:fin_dash/ui/editors.dart';
import 'package:fin_dash/ui/design.dart';
import 'helpers.dart';
import 'payment_notifications_test.dart' show event, FakeBridge;

Json differentEvent(String id, int cents, int minute) => {
  ...event(id),
  'amountCents': cents,
  'postedAt': DateTime(2026, 10, 1, 12, minute).millisecondsSinceEpoch,
};

void leaveApp(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void returnToApp(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void main() {
  testWidgets('review fits a small screen with larger text', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final store = await emptyStore();
    await store.change((d) => d.profile['name'] = '测试用户');
    await store.saveAccount(bank);
    await tester.pumpWidget(
      FinDashApp(
        store: store,
        ai: AiService(store, TestVault()),
        notificationBridge: FakeBridge([event()]),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('payment-confirm-batch')), findsOneWidget);
    expect(tester.takeException(), null);
  });

  testWidgets(
    'reminder supports select all, inline details and direct acceptance with retry',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryStorage();
      final store = await emptyStore(storage);
      await store.change((d) => d.profile['name'] = '测试用户');
      await store.saveAccount(bank);
      await tester.pumpWidget(
        FinDashApp(
          store: store,
          ai: AiService(store, TestVault()),
          notificationBridge: FakeBridge([
            event(),
            differentEvent('b', 200, 10),
          ]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('全选'), findsOneWidget);
      expect(find.text('选择记录后可一起确认'), findsOneWidget);
      await tester.tap(find.byKey(const Key('payment-select-all')));
      await tester.pumpAndSettle();
      final id = 'b' * 64;
      await tester.tap(find.byKey(ValueKey('payment-details:$id')));
      await tester.pumpAndSettle();
      expect(find.text('通知原文'), findsOneWidget);
      expect(find.byType(TransactionEditor), findsNothing);
      await tester.tap(find.byKey(ValueKey('payment-details:$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(WalletSelectField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('银行卡').last);
      await tester.pumpAndSettle();
      storage.failWrites = true;
      await tester.tap(find.byKey(ValueKey('payment-accept:$id')));
      await tester.pumpAndSettle();
      expect(store.data.transactions, isEmpty);
      expect(find.text('确认未保存，记录已保留，请重试'), findsOneWidget);
      storage.failWrites = false;
      await tester.tap(find.byKey(ValueKey('payment-accept:$id')));
      await tester.pumpAndSettle();
      expect(store.data.transactions.single.amount, 200);
      expect(PaymentNotifications(store).pending.length, 1);
      expect(find.byKey(const Key('payment-entry-review')), findsOneWidget);
      expect(find.byType(TransactionEditor), findsNothing);
      await tester.tap(find.byKey(const Key('payment-confirm-batch')));
      await tester.pumpAndSettle();
      expect(store.data.transactions.length, 2);
      expect(find.byKey(const Key('payment-entry-review')), findsNothing);
      expect(tester.takeException(), null);
    },
  );

  testWidgets('reentry reminder waits for an open editor to close', (
    tester,
  ) async {
    final store = await emptyStore();
    await store.change((d) => d.profile['name'] = '测试用户');
    await store.saveAccount(bank);
    final bridge = FakeBridge([]);
    await tester.pumpWidget(
      FinDashApp(
        store: store,
        ai: AiService(store, TestVault()),
        notificationBridge: bridge,
      ),
    );
    await tester.pumpAndSettle();
    final editor = openPage<void>(
      tester.element(find.byType(HomePage)),
      const TransactionEditor(),
    );
    await tester.pumpAndSettle();
    leaveApp(tester);
    bridge.events.add(event());
    returnToApp(tester);
    await tester.pumpAndSettle();
    expect(find.byType(TransactionEditor), findsOneWidget);
    expect(find.byKey(const Key('payment-entry-review')), findsNothing);
    expect(PaymentNotifications(store).pending.length, 1);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await editor;
    expect(find.byKey(const Key('payment-entry-review')), findsOneWidget);
    expect(store.data.transactions, isEmpty);
    expect(tester.takeException(), null);
  });

  test(
    'batch acceptance is atomic, idempotent and preserves notification linkage',
    () async {
      final storage = MemoryStorage();
      final store = await emptyStore(storage);
      await store.saveAccount(bank);
      final service = PaymentNotifications(store);
      await service.ingest([event(), differentEvent('b', 200, 10)]);
      final items = [
        for (final record in service.pending)
          PaymentAcceptance(
            record['eventId'],
            paymentNotificationDraft(record, store.data, accountId: 'bank'),
          ),
      ];
      storage.failWrites = true;
      await expectLater(service.acceptMany(items), throwsStateError);
      expect(service.pending.length, 2);
      expect(store.data.transactions, isEmpty);
      storage.failWrites = false;
      expect(await service.acceptMany(items), 2);
      expect(await service.acceptMany(items), 0);
      expect(store.data.transactions.length, 2);
      expect(store.balance(bank), 99650);
      expect(service.pending, isEmpty);
      final restored = await emptyStore(storage);
      expect(
        PaymentNotifications(
          restored,
        ).records.every((r) => r['transactionId'] != null),
        true,
      );
    },
  );

  test(
    'batch refuses ambiguous, refund, missing-field and duplicate candidates',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final service = PaymentNotifications(store);
      await service.ingest([
        event(),
        event('b'),
        {...event('c', 'refund'), 'amountCents': 200},
        {...event('d'), 'amountCents': null},
        {...differentEvent('e', 300, 20), 'merchant': ''},
        differentEvent('f', 400, 30),
      ]);
      expect(service.batchProblem(service.pending.first), null);
      expect(
        service.pending.where((r) => service.batchProblem(r) == null).length,
        1,
      );
      for (final record in service.pending.where(
        (r) => r['eventId'] != 'f' * 64,
      )) {
        await expectLater(
          service.acceptMany([
            PaymentAcceptance(
              record['eventId'],
              paymentNotificationDraft(record, store.data, accountId: 'bank'),
            ),
          ]),
          throwsFormatException,
        );
      }
      expect(store.data.transactions, isEmpty);
      await store.saveTx(tx(amount: 400, date: DateTime(2026, 10, 1, 12, 30)));
      expect(service.batchProblem(service.pending.first), contains('重复'));
    },
  );

  test(
    'batch rechecks lock, accounts and notification amounts without partial writes',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final service = PaymentNotifications(store);
      await service.ingest([event(), differentEvent('b', 200, 10)]);
      final items = [
        for (final record in service.pending)
          PaymentAcceptance(
            record['eventId'],
            paymentNotificationDraft(record, store.data, accountId: 'bank'),
          ),
      ];
      await store.change((d) => d.settings['locked'] = true);
      await expectLater(service.acceptMany(items), throwsFormatException);
      await store.change((d) {
        d.settings['locked'] = false;
        d.accounts[0] = bank.copyWith(archived: true);
      });
      await expectLater(service.acceptMany(items), throwsFormatException);
      await store.change((d) => d.accounts[0] = bank);
      final changed = LedgerTx.fromJson({
        ...items.last.transaction.toJson(),
        'amountCents': 999,
      });
      await expectLater(
        service.acceptMany([
          items.first,
          PaymentAcceptance(items.last.eventId, changed),
        ]),
        throwsFormatException,
      );
      expect(store.data.transactions, isEmpty);
      expect(service.pending.length, 2);
    },
  );

  testWidgets(
    'entry reminder defers unchanged records and homepage remains accessible after reopening',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryStorage();
      final store = await emptyStore(storage);
      await store.change((d) => d.profile['name'] = '测试用户');
      await store.saveAccount(bank);
      final bridge = FakeBridge([event()]);
      await tester.pumpWidget(
        FinDashApp(
          store: store,
          ai: AiService(store, TestVault()),
          notificationBridge: bridge,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-entry-review')), findsOneWidget);
      expect(store.data.transactions, isEmpty);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('payment-confirm-batch')),
            )
            .onPressed,
        null,
      );
      await tester.tap(find.byTooltip('稍后处理'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-payment-pending')), findsOneWidget);
      expect(PaymentNotifications(store).reminderSeen, {'a' * 64});
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      final reopened = await emptyStore(storage);
      final nextBridge = FakeBridge([]);
      await tester.pumpWidget(
        FinDashApp(
          store: reopened,
          ai: AiService(reopened, TestVault()),
          notificationBridge: nextBridge,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-entry-review')), findsNothing);
      expect(find.byKey(const Key('home-payment-pending')), findsOneWidget);
      await tester.tap(find.text('去核对'));
      await tester.pumpAndSettle();
      expect(find.byType(PaymentReviewPage), findsOneWidget);
      await tester.tap(find.byKey(const Key('payment-select-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(WalletSelectField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('银行卡').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('payment-confirm-batch')));
      await tester.pumpAndSettle();
      expect(reopened.data.transactions.length, 1);
      expect(find.byKey(const Key('home-payment-pending')), findsNothing);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'new records show a reminder on reentry and do not display in the background',
    (tester) async {
      final store = await emptyStore();
      await store.change((d) => d.profile['name'] = '测试用户');
      await store.saveAccount(bank);
      final bridge = FakeBridge([event()]);
      await tester.pumpWidget(
        FinDashApp(
          store: store,
          ai: AiService(store, TestVault()),
          notificationBridge: bridge,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('稍后处理'));
      await tester.pumpAndSettle();
      leaveApp(tester);
      bridge.events.add(differentEvent('b', 200, 10));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-entry-review')), findsNothing);
      returnToApp(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('payment-entry-review')), findsOneWidget);
      expect(PaymentNotifications(store).pending.length, 2);
      expect(store.data.transactions, isEmpty);
      expect(tester.takeException(), null);
    },
  );

  testWidgets('notification prompt waits until unlocked', (tester) async {
    final store = await emptyStore();
    await store.change((d) {
      d.profile['name'] = '测试用户';
      d.settings['locked'] = true;
    });
    final bridge = FakeBridge([event()]);
    await tester.pumpWidget(
      FinDashApp(
        store: store,
        ai: AiService(store, TestVault()),
        notificationBridge: bridge,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsNothing);
    expect(find.byKey(const Key('payment-entry-review')), findsNothing);
    expect(bridge.events.length, 1);
    await store.change((d) => d.settings['locked'] = false);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('payment-entry-review')), findsOneWidget);
    expect(tester.takeException(), null);
  });
}
