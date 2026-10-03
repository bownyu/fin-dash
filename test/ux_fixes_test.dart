import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/data/backup.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/data/storage_sqlite.dart' as sqlite;
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/main.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/services/backup_bundle.dart';
import 'package:fin_dash/services/chat_image_storage.dart';
import 'package:fin_dash/services/payment_notifications.dart';
import 'package:fin_dash/services/voice_widget_runtime.dart';
import 'package:fin_dash/ui/design.dart';
import 'package:fin_dash/ui/editors.dart';
import 'package:fin_dash/ui/finance_pages.dart';
import 'package:fin_dash/ui/interaction.dart';
import 'package:fin_dash/ui/ai_pages.dart';
import 'helpers.dart';
import 'payment_notifications_test.dart' show event;
import 'voice_widget_runtime_test.dart' show widgetRequest;

class DelayedStorage extends MemoryStorage {
  Completer<void>? gate;
  @override
  Future<void> save(String data) async {
    await gate?.future;
    await super.save(data);
  }
}

Future<WalletStore> render(
  WidgetTester tester, {
  MemoryStorage? storage,
  Size size = const Size(390, 844),
  List<WalletAccount> accounts = const [bank, cash],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final store = await emptyStore(storage);
  await store.change((d) {
    d.profile['name'] = '测试用户';
    d.accounts = accounts;
  });
  await tester.pumpWidget(
    FinDashApp(store: store, ai: AiService(store, TestVault())),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets(
    'switching conversations preserves separate unsent drafts and returns to the existing chat',
    (tester) async {
      await render(tester);
      final ai = tester.widget<FinDashApp>(find.byType(FinDashApp)).ai;
      await ai.newConversation();
      final first = ai.activeSessionId;
      openPage<void>(tester.element(find.byType(HomePage)), const ChatPage());
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byType(ChatPage),
        matching: find.byType(TextField),
      );
      await tester.enterText(input, '第一份未发送草稿');
      await ai.newConversation();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, '');
      await tester.enterText(input, '第二份未发送草稿');
      await tester.tap(find.byTooltip('历史对话'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatHistoryPage), findsOneWidget);
      await ai.switchConversation(first);
      Navigator.of(tester.element(find.byType(ChatHistoryPage))).pop();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, '第一份未发送草稿');
      expect(find.byType(ChatPage, skipOffstage: false), findsOneWidget);
      expect(ai.store.data.chats, isEmpty);
    },
  );
  testWidgets(
    'dirty transaction survives close and Android back until explicitly discarded',
    (tester) async {
      final store = await render(tester);
      await tester.tap(find.byTooltip('记一笔'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('amount-input')), '12.50');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('继续编辑'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('amount-input')))
            .controller!
            .text,
        '12.50',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionEditor), findsNothing);
      expect(store.data.transactions, isEmpty);
    },
  );

  testWidgets(
    'system back cannot close a transaction during its durable save',
    (tester) async {
      final storage = DelayedStorage();
      final store = await render(tester, storage: storage);
      await tester.tap(find.byTooltip('记一笔'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('amount-input')), '1.25');
      storage.gate = Completer<void>();
      await tester.tap(find.byKey(const Key('save-transaction')));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(TransactionEditor), findsOneWidget);
      expect(store.data.transactions, isEmpty);
      storage.gate!.complete();
      await tester.pumpAndSettle();
      expect(store.data.transactions.single.amount, 125);
      expect(find.byType(TransactionEditor), findsNothing);
    },
  );

  testWidgets(
    'repayment defaults remain distinct when the credit account is first',
    (tester) async {
      final store = await render(tester, accounts: [credit, bank, cash]);
      openPage<void>(
        tester.element(find.byType(HomePage)),
        const TransactionEditor(
          initialType: TxType.transfer,
          initialAccount: 'credit',
        ),
      );
      await tester.pumpAndSettle();
      final fields = tester
          .widgetList<WalletSelectField<String>>(
            find.byType(WalletSelectField<String>),
          )
          .toList();
      expect(fields.map((f) => f.initialValue), ['bank', 'credit']);
      await tester.tap(find.byType(WalletSelectField<String>).first);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, '信用卡'), findsNothing);
      await tester.tap(find.text('银行卡').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('amount-input')), '10.00');
      await tester.tap(find.byKey(const Key('save-transaction')));
      await tester.pumpAndSettle();
      expect(store.balance(credit), credit.openingBalance + 1000);
      expect(store.balance(bank), bank.openingBalance - 1000);
    },
  );

  testWidgets(
    'category picker is usable on a small phone and does not discard amount',
    (tester) async {
      await render(tester, size: const Size(320, 640));
      await tester.tap(find.byTooltip('记一笔'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('amount-input')), '23.00');
      final category = find.byKey(
        const ValueKey('transaction-category:TxType.expense:餐饮'),
      );
      await tester.ensureVisible(category);
      await tester.tap(category);
      await tester.pumpAndSettle();
      await tester.tap(find.text('交通').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('amount-input')))
            .controller!
            .text,
        '23.00',
      );
      expect(find.text('交通'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('back first exits bill selection, preserving the bills tab', (
    tester,
  ) async {
    final store = await render(tester);
    await store.saveTx(tx());
    await tester.tap(find.byKey(const Key('nav-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择账单'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(BillsPage), findsOneWidget);
    expect(find.text('已选 0 笔'), findsNothing);
  });

  test(
    'month end rules clamp leap/non-leap dates and preserve credit cycles',
    () {
      expect(monthDay(2027, 2, 31), DateTime(2027, 2, 28));
      expect(monthDay(2028, 2, 31), DateTime(2028, 2, 29));
      expect(
        nextRepaymentDate(31, DateTime(2027, 2, 28, 20)),
        DateTime(2027, 2, 28),
      );
      expect(
        nextRepaymentDate(30, DateTime(2027, 3, 31)),
        DateTime(2027, 4, 30),
      );
      final cycle = creditBillingCycle(31, true, DateTime(2027, 2, 28, 12));
      expect(cycle.start, DateTime(2027, 2, 1));
      expect(cycle.end, DateTime(2027, 3, 1));
      final next = creditBillingCycle(31, true, DateTime(2027, 3, 1));
      expect(next.start, DateTime(2027, 3, 1));
      expect(next.end, DateTime(2027, 4, 1));
    },
  );

  test('credit dates through 31 survive backup validation', () {
    final data = WalletData(
      accounts: [
        WalletAccount.fromJson({
          ...credit.toJson(),
          'billingDay': 31,
          'repaymentDay': 30,
        }),
      ],
    );
    expect(
      parseBackup(jsonEncode(data.toJson())).data.accounts.single.billingDay,
      31,
    );
    expect(
      () => parseBackup(
        jsonEncode(
          WalletData(
            accounts: [
              WalletAccount.fromJson({...credit.toJson(), 'billingDay': 32}),
            ],
          ).toJson(),
        ),
      ),
      throwsFormatException,
    );
  });

  test(
    'refund requires original expense, permits partial refund and prevents excess',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveTx(
        tx(id: 'original', amount: 3000, date: DateTime(2026, 9, 30)),
      );
      final service = PaymentNotifications(store);
      await service.ingest([event('a', 'refund'), event('b', 'refund')]);
      final refund = tx(id: 'refund-a', type: TxType.income, amount: 1000);
      await expectLater(
        service.accept('a' * 64, refund),
        throwsFormatException,
      );
      await service.accept(
        'a' * 64,
        refund,
        refundOf: 'original',
        duplicateReviewed: true,
      );
      expect(store.balance(bank), 98000);
      expect(store.data.transactions.last.category, '退款');
      await service.accept(
        'a' * 64,
        refund,
        refundOf: 'original',
        duplicateReviewed: true,
      );
      expect(store.data.transactions.length, 2);
      await expectLater(
        service.accept(
          'b' * 64,
          tx(id: 'refund-b', type: TxType.income, amount: 2500),
          refundOf: 'original',
          duplicateReviewed: true,
        ),
        throwsFormatException,
      );
      expect(store.data.transactions.length, 2);
      expect(service.pending.single['eventId'], 'b' * 64);
    },
  );

  test(
    'ignored notification can return to review without duplicate ingestion',
    () async {
      final store = await emptyStore();
      final service = PaymentNotifications(store);
      await service.ingest([event()]);
      final text = service.pending.single['text'];
      await service.dismiss('a' * 64);
      expect(service.pending, isEmpty);
      await service.restoreIgnored('a' * 64);
      await service.ingest([event()]);
      expect(service.pending.length, 1);
      expect(service.pending.single['text'], text);
    },
  );

  test(
    'failed restore-point write preserves the ledger; successful recovery survives reopening',
    () async {
      final storage = MemoryStorage();
      final store = await emptyStore(storage);
      await store.saveAccount(bank);
      await store.saveTx(tx());
      final incoming = parseBackup(
        jsonEncode(WalletData(accounts: [cash]).toJson()),
      );
      storage.failWrites = true;
      await expectLater(store.restore(incoming), throwsStateError);
      expect(store.data.transactions.single.id, 'tx');
      storage.failWrites = false;
      await store.restore(incoming);
      expect(store.data.accounts.single.id, 'cash');
      final reopened = await emptyStore(storage);
      expect(reopened.hasRestorePoint, true);
      await reopened.restorePrevious();
      expect(reopened.data.transactions.single.id, 'tx');
      expect(reopened.balance(bank), 99850);
    },
  );

  test(
    'SQLite restore point is separate from its mirror and can replace existing points',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'findash-ux-sqlite-',
      );
      addTearDown(() async {
        final root = await Directory.systemTemp.resolveSymbolicLinks();
        final target = await directory.resolveSymbolicLinks();
        if (!target.startsWith(
          '$root${Platform.pathSeparator}findash-ux-sqlite-',
        )) {
          throw StateError('Unsafe temporary directory');
        }
        await directory.delete(recursive: true);
      });
      final store = WalletStore(
        sqlite.LocalWalletStorage(directory: directory),
      );
      await store.initialize();
      await store.saveAccount(bank);
      await store.saveTx(tx());
      await store.restore(
        parseBackup(jsonEncode(WalletData(accounts: [cash]).toJson())),
      );
      final reopened = WalletStore(
        sqlite.LocalWalletStorage(directory: directory),
      );
      await reopened.initialize();
      expect(reopened.hasRestorePoint, true);
      await reopened.restorePrevious();
      expect(reopened.data.transactions.single.id, 'tx');
      await reopened.restorePrevious();
      expect(reopened.data.accounts.single.id, 'cash');
    },
  );

  test(
    'complete backup roundtrips image attachments and rejects corrupted data',
    () async {
      final store = await emptyStore();
      final bytes = await File('assets/brand.png').readAsBytes();
      final id = sha256.convert(bytes).toString();
      final images = MemoryChatImageStorage();
      await images.save(id, bytes);
      await store.change(
        (d) => d.chats.add({
          'id': 'image-message',
          'role': 'user',
          'content': '截图',
          'timestamp': DateTime(2026).toIso8601String(),
          'imageId': id,
        }),
      );
      final raw = await exportBackupBundle(store, images);
      final bundle = parseBackupBundle(raw);
      expect(bundle.images[id], bytes);
      expect(bundle.preview.data.chats.single['imageId'], id);
      final corrupt = Json.from(jsonDecode(raw));
      corrupt['chatImages'] = {
        id: base64Encode([1, 2, 3]),
      };
      expect(
        () => parseBackupBundle(jsonEncode(corrupt)),
        throwsFormatException,
      );
    },
  );

  test(
    'widget changes either transfer side and skips the opposite account',
    () async {
      final store = await emptyStore();
      for (final account in [bank, cash, credit]) {
        await store.saveAccount(account);
      }
      VoiceWidgetRuntime.install(store, AiService(store, TestVault()), () {});
      addTearDown(() => VoiceWidgetRuntime.channel.setMethodCallHandler(null));
      final result = await widgetRequest({
        'operation': 'account',
        'accountField': 'transferFromId',
        'draft': jsonEncode({
          'entryId': 'widget-transfer',
          'fields': {
            'type': 'transfer',
            'title': '还款',
            'amountCents': 1000,
            'date': DateTime(2026, 10, 1).toIso8601String(),
            'transferFromId': 'bank',
            'transferToId': 'credit',
          },
        }),
      });
      expect(result['draft']['fields']['transferFromId'], 'cash');
      expect(result['draft']['fields']['transferToId'], 'credit');
      final second = await widgetRequest({
        'operation': 'account',
        'accountField': 'transferToId',
        'draft': jsonEncode(result['draft']),
      });
      expect(second['draft']['fields']['transferToId'], 'bank');
      expect(second['draft']['fields']['transferFromId'], 'cash');
      expect(store.data.transactions, isEmpty);
    },
  );
}
