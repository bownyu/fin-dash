import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/main.dart';
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/ui/editors.dart';
import 'package:fin_dash/ui/finance_pages.dart';
import 'package:fin_dash/ui/preferences.dart';
import 'helpers.dart';

Future<WalletStore> pumpApp(WidgetTester tester, {bool demo = true}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  final store = await emptyStore();
  if (demo) {
    await store.change((d) {
      final data = demoData();
      d.profile = data.profile;
      d.accounts = data.accounts;
      d.transactions = data.transactions;
      d.quickEntries = data.quickEntries;
    });
  }
  await tester.pumpWidget(
    FinDashApp(store: store, ai: AiService(store, TestVault())),
  );
  await tester.pumpAndSettle();
  return store;
}

void main() {
  testWidgets('four main pages render on a phone without overflow', (
    tester,
  ) async {
    await pumpApp(tester);
    for (final index in [1, 2, 3, 0]) {
      await tester.tap(find.byKey(Key('nav-$index')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), null);
    }
  });
  testWidgets('first-time profile opens the real empty ledger', (tester) async {
    final store = await pumpApp(tester, demo: false);
    await tester.enterText(find.byKey(const Key('welcome-name')), '测试用户');
    await tester.tap(find.text('开始记录'));
    await tester.pumpAndSettle();
    expect(store.data.profile['name'], '测试用户');
    expect(store.data.transactions, isEmpty);
    await tester.scrollUntilVisible(
      find.text('还没有账单'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(HomePage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('还没有账单'), findsOneWidget);
    expect(tester.takeException(), null);
  });
  testWidgets('transaction editor saves exact amount and closes successfully', (
    tester,
  ) async {
    final store = await pumpApp(tester);
    final before = store.balance(store.account('bank')!);
    await tester.tap(find.byTooltip('记一笔'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('amount-input')), '1.50');
    await tester.scrollUntilVisible(
      find.byKey(const Key('save-transaction')),
      200,
      scrollable: find
          .descendant(
            of: find.byType(TransactionEditor),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-transaction')));
    await tester.pumpAndSettle();
    expect(store.balance(store.account('bank')!), before - 150);
    expect(store.query().first.amount, 150);
    expect(tester.takeException(), null);
  });
  testWidgets(
    'transfer form selects distinct accounts and saves a valid transfer',
    (tester) async {
      final store = await pumpApp(tester);
      final length = store.data.transactions.length;
      final context = tester.element(find.byType(HomePage));
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const TransactionEditor(initialType: TxType.transfer),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('amount-input')), '10');
      // Default source and destination differ; domain validation is separately tested.
      await tester.scrollUntilVisible(
        find.byKey(const Key('save-transaction')),
        200,
        scrollable: find
            .descendant(
              of: find.byType(TransactionEditor),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-transaction')));
      await tester.pumpAndSettle();
      expect(store.data.transactions.length, length + 1);
      expect(store.data.transactions.last.type, TxType.transfer);
      expect(tester.takeException(), null);
    },
  );
  testWidgets('account form saves a negative credit balance', (tester) async {
    final store = await pumpApp(tester);
    final context = tester.element(find.byType(HomePage));
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AccountEditor(initial: credit)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('account-name')), '我的信用账户');
    await tester.enterText(find.byKey(const Key('account-balance')), '-123.45');
    await tester.ensureVisible(find.byKey(const Key('save-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-account')));
    await tester.pumpAndSettle();
    expect(store.balance(store.account('credit')!), -12345);
    expect(tester.takeException(), null);
  });
  testWidgets('empty stats retains date navigation and month switching', (
    tester,
  ) async {
    final store = await pumpApp(tester);
    await store.change((d) => d.transactions.clear());
    await tester.tap(find.byKey(const Key('nav-1')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('上一周期'), findsOneWidget);
    await tester.tap(find.byTooltip('上一周期'));
    await tester.pumpAndSettle();
    expect(find.text('这个周期还没有记录，试试切换日期。'), findsOneWidget);
    expect(tester.takeException(), null);
  });
  testWidgets('large text and secondary management pages remain scrollable', (
    tester,
  ) async {
    await pumpApp(tester);
    final context = tester.element(find.byType(HomePage));
    for (final page in [
      const AccountsPage(),
      const CategoriesPage(),
      const GoalsPage(),
      const SettingsPage(),
      const BackupPage(),
    ]) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: page,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), null);
      Navigator.of(tester.element(find.byType(page.runtimeType))).pop();
      await tester.pumpAndSettle();
    }
  });
}
