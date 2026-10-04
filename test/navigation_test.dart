import 'dart:ui' as ui;
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/main.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/ui/design.dart';
import 'package:fin_dash/ui/editors.dart';
import 'package:fin_dash/ui/finance_pages.dart';
import 'package:fin_dash/ui/preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers.dart';

Future<WalletStore> renderApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final store = await emptyStore();
  await store.change((data) {
    final demo = demoData();
    data.profile = demo.profile;
    data.accounts = demo.accounts;
    data.transactions = demo.transactions;
    data.quickEntries = demo.quickEntries;
  });
  await tester.pumpWidget(
    FinDashApp(store: store, ai: AiService(store, TestVault())),
  );
  await tester.pumpAndSettle();
  return store;
}

Future<bool> markerIsVisible(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('capture')),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final offset = (image.height ~/ 2 * image.width + image.width ~/ 2) * 4;
      return pixels!.getUint8(offset) > 220 &&
          pixels.getUint8(offset + 1) < 30 &&
          pixels.getUint8(offset + 2) > 220;
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  testWidgets('first visits and revisits animate the selected tab', (
    tester,
  ) async {
    await renderApp(tester);
    double opacity() => tester
        .widget<FadeTransition>(find.byKey(const Key('main-tab-transition')))
        .opacity
        .value;
    Offset offset() => tester
        .widget<SlideTransition>(
          find
              .descendant(
                of: find.byKey(const Key('main-tab-transition')),
                matching: find.byType(SlideTransition),
              )
              .first,
        )
        .position
        .value;
    for (final index in [1, 2, 3, 0, 1]) {
      await tester.tap(find.byKey(Key('nav-$index')));
      await tester.pump();
      expect(
        opacity(),
        0,
        reason: 'tab $index must animate on its first frame',
      );
      expect(offset().dy, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 100));
      expect(opacity(), allOf(greaterThan(0), lessThan(1)));
      await tester.pumpAndSettle();
      expect(opacity(), 1);
      expect(offset(), Offset.zero);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid tab changes finish on the last selected page', (
    tester,
  ) async {
    await renderApp(tester);
    final home = tester.state(find.byType(HomePage));
    for (final index in [1, 2, 3, 2, 0]) {
      await tester.tap(find.byKey(Key('nav-$index')));
      await tester.pump(const Duration(milliseconds: 32));
    }
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(HomePage)), same(home));
    expect(find.byType(BillsPage), findsNothing);
    expect(
      tester
          .widget<FadeTransition>(find.byKey(const Key('main-tab-transition')))
          .opacity
          .value,
      1,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion skips the first tab and subpage transitions', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await renderApp(tester);
    await tester.tap(find.byKey(const Key('nav-1')));
    await tester.pump();
    expect(
      tester
          .widget<FadeTransition>(find.byKey(const Key('main-tab-transition')))
          .opacity
          .value,
      1,
    );
    await tester.tap(find.byKey(const Key('nav-0')));
    await tester.pump();
    openPage<void>(tester.element(find.byType(HomePage)), const AccountsPage());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(AccountsPage), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byType(AccountsPage),
        matching: find.byType(SlideTransition),
      ),
      findsNothing,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('first subpage opening moves before it settles', (tester) async {
    await renderApp(tester);
    final result = openPage<void>(
      tester.element(find.byType(HomePage)),
      const AccountsPage(),
    );
    await tester.pump();
    final page = find.byType(AccountsPage);
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getTopLeft(page).dx, allOf(greaterThan(0), lessThan(390)));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(page).dx, 0);
    Navigator.of(tester.element(page)).pop();
    await tester.pumpAndSettle();
    await result;
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tab selection is immediate and skips unvisited intermediate tabs',
    (tester) async {
      await renderApp(tester);
      expect(find.byType(StatsPage, skipOffstage: false), findsNothing);
      expect(find.byType(BillsPage, skipOffstage: false), findsNothing);
      await tester.tap(find.byKey(const Key('nav-3')));
      await tester.pump();
      expect(find.byType(ProfilePage), findsOneWidget);
      expect(find.byType(HomePage), findsNothing);
      expect(find.byType(StatsPage, skipOffstage: false), findsNothing);
      expect(find.byType(BillsPage, skipOffstage: false), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tabs retain statistics selection, bill search and home scroll position',
    (tester) async {
      await renderApp(tester);
      final scroll = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(HomePage),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      scroll.jumpTo(170);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('月'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-2')));
      await tester.pumpAndSettle();
      final search = find.descendant(
        of: find.byType(BillsPage),
        matching: find.byType(TextField),
      );
      await tester.enterText(search, '咖啡');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-1')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SegmentedButton<Period>>(
              find.byType(SegmentedButton<Period>),
            )
            .selected,
        {Period.month},
      );
      await tester.tap(find.byKey(const Key('nav-2')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, '咖啡');
      tester.view.physicalSize = const Size(960, 900);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, '咖啡');
      await tester.tap(find.byKey(const Key('nav-0')));
      await tester.pumpAndSettle();
      expect(scroll.pixels, 170);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rapid repeated navigation does not stack duplicate editors', (
    tester,
  ) async {
    await renderApp(tester);
    final context = tester.element(find.byType(HomePage));
    final first = openPage<bool>(
      context,
      const TransactionEditor(),
      modal: true,
    );
    final repeated = openPage<bool>(
      context,
      const TransactionEditor(),
      modal: true,
    );
    expect(await repeated, isNull);
    await tester.pumpAndSettle();
    expect(find.byType(TransactionEditor, skipOffstage: false), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(await first, isNull);
    expect(find.byType(HomePage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system back returns from another tab to home', (tester) async {
    await renderApp(tester);
    await tester.tap(find.byKey(const Key('nav-2')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(BillsPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'ledger updates rebuild content without recreating the app or navigator',
    (tester) async {
      final store = await renderApp(tester);
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      final before = store.netWorth;
      await store.saveTx(
        tx(id: 'navigation-refresh', amount: 123, account: 'bank'),
      );
      await tester.pumpAndSettle();
      expect(
        identical(tester.widget<MaterialApp>(find.byType(MaterialApp)), app),
        isTrue,
      );
      expect(
        identical(
          tester.state<NavigatorState>(find.byType(Navigator)),
          navigator,
        ),
        isTrue,
      );
      expect(find.text(money(before - 123)), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    for (final modal in [false, true]) {
      testWidgets(
        '${brightness.name} ${modal ? 'modal' : 'page'} backdrop hides underlying content during push and pop',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            RepaintBoundary(
              key: const Key('capture'),
              child: MaterialApp(
                theme: walletTheme(
                  brightness,
                ).copyWith(platform: TargetPlatform.android),
                home: const Scaffold(
                  key: Key('source'),
                  body: Center(
                    child: SizedBox(
                      width: 100,
                      height: 100,
                      child: ColoredBox(color: Color(0xFFFF00FF)),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(await markerIsVisible(tester), isTrue);
          final result = openPage<void>(
            tester.element(find.byKey(const Key('source'))),
            const Scaffold(
              key: Key('target'),
              body: Center(child: Text('目标页面')),
            ),
            modal: modal,
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 80));
          expect(
            await markerIsVisible(tester),
            isFalse,
            reason:
                'The incoming route must cover the old page with its own background.',
          );
          await tester.pumpAndSettle();
          Navigator.of(tester.element(find.byKey(const Key('target')))).pop();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 70));
          expect(
            await markerIsVisible(tester),
            isFalse,
            reason: 'The exiting route must remain opaque while sliding away.',
          );
          await tester.pumpAndSettle();
          await result;
          expect(await markerIsVisible(tester), isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('home sections rise in once and stay put across tab switches', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = await emptyStore();
    await store.change((data) {
      final demo = demoData();
      data.profile = demo.profile;
      data.accounts = demo.accounts;
      data.transactions = demo.transactions;
    });
    await tester.pumpWidget(
      FinDashApp(store: store, ai: AiService(store, TestVault())),
    );
    await tester.pump();
    FadeTransition overviewFade() => tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byType(OverviewGrid),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(overviewFade().opacity.value, lessThan(1));
    await tester.pumpAndSettle();
    expect(overviewFade().opacity.value, 1);
    await tester.tap(find.byKey(const Key('nav-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-0')));
    await tester.pump();
    expect(overviewFade().opacity.value, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a bill saved under a sheet is highlighted only after the sheet closes',
    (tester) async {
      final store = await renderApp(tester);
      await tester.scrollUntilVisible(
        find.text('查看全部账单 →'),
        300,
        scrollable: find
            .descendant(
              of: find.byType(HomePage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      final home = tester.element(find.byType(HomePage));
      showModalBottomSheet<void>(
        context: home,
        builder: (_) => const SizedBox(height: 200),
      );
      await tester.pumpAndSettle();
      await store.change(
        (d) => d.transactions.add(
          LedgerTx(
            id: 'fresh-bill',
            title: '刚记的一笔',
            amount: 100,
            date: DateTime.now(),
            type: TxType.expense,
            category: '餐饮',
            accountId: d.accounts.first.id,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('刚记的一笔'), findsOneWidget);
      // Nothing animates behind the sheet.
      await tester.pump(const Duration(seconds: 2));
      expect(tester.hasRunningAnimations, isFalse);
      Navigator.of(home).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
