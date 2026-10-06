import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/ui/design.dart';
import 'package:fin_dash/ui/finance_pages.dart';
import 'package:fin_dash/ui/voice_entry_sheet.dart';
import 'helpers.dart';
import 'navigation_test.dart' show renderApp;

void main() {
  testWidgets('voice keyboard and continued typing do not rebuild the page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final store = await emptyStore();
    await store.saveAccount(bank);
    await tester.pumpWidget(
      AppScope(
        store: store,
        ai: AiService(store, TestVault()),
        child: MaterialApp(
          theme: walletTheme(Brightness.light),
          home: const VoiceSheetHost(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('voice-transcript'));
    await tester.enterText(input, '午');
    await tester.pumpAndSettle();
    var builds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      if (element.widget is VoiceEntrySheet) builds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    for (final height in [50.0, 150.0, 250.0, 300.0, 200.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: height);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.enterText(input, '午餐十元');
    await tester.pump();
    expect(builds, 0);
    expect(
      find.byKey(const Key('voice-confirm')).hitTestable(),
      findsOneWidget,
    );
    await tester.enterText(input, '');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-confirm')), findsNothing);
    expect(tester.takeException(), null);
  });

  testWidgets('a large same-day ledger builds only visible transaction rows', (
    tester,
  ) async {
    final store = await emptyStore();
    await store.saveAccount(bank);
    // Large snapshot encoding runs in a real isolate rather than FakeAsync.
    await tester.runAsync(
      () => store.change((d) {
        for (var i = 0; i < 800; i++) {
          d.transactions.add(tx(id: 'many-$i'));
        }
      }),
    );
    await tester.pumpWidget(
      AppScope(
        store: store,
        ai: AiService(store, TestVault()),
        child: MaterialApp(
          theme: walletTheme(Brightness.light),
          home: const Scaffold(body: BillsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TransactionRow).evaluate().length, lessThan(30));
    expect(find.text('全部日期 · 800 笔'), findsOneWidget);
    // A burst of edits must trigger one query after typing pauses.
    var builds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      if (element.widget is BillsPage) builds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    for (final text in ['不', '不存', '不存在']) {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(builds, 0);
    await tester.pump(const Duration(milliseconds: 200));
    expect(builds, 1);
    expect(find.text('全部日期 · 0 笔'), findsOneWidget);
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump();
    expect(find.text('全部日期 · 800 笔'), findsOneWidget);
    await tester.pumpWidget(
      AppScope(
        store: store,
        ai: AiService(store, TestVault()),
        child: MaterialApp(
          theme: walletTheme(Brightness.light),
          home: const AccountDetailPage('bank'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TransactionRow).evaluate().length, lessThan(30));
    // Reach later rows without ever mounting all 800 transactions.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(find.byType(TransactionRow).evaluate().length, lessThan(30));
    expect(tester.takeException(), null);
  });

  testWidgets('keyboard frames of a page above leave the retained tabs alone', (
    tester,
  ) async {
    await renderApp(tester);
    addTearDown(tester.view.resetViewInsets);
    for (final index in [1, 2, 3, 0]) {
      await tester.tap(find.byKey(Key('nav-$index')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('AI 顾问').first);
    await tester.pumpAndSettle();
    await tester.showKeyboard(find.byType(TextField));
    await tester.pump();
    var covered = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      if (element.widget is MoneyText || element.widget is TransactionRow) {
        covered++;
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    for (final height in [60.0, 160.0, 260.0, 320.0, 160.0, 0.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: height);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(covered, 0);
    expect(tester.takeException(), null);
  });
}
