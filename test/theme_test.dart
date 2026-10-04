import 'package:fin_dash/data/storage.dart';
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/main.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/ui/design.dart';
import 'package:fin_dash/ui/finance_pages.dart';
import 'package:fin_dash/ui/preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers.dart';

Future<WalletStore> renderApp(
  WidgetTester tester, {
  MemoryStorage? storage,
  String? appearance,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final store = WalletStore(storage ?? MemoryStorage());
  await store.initialize(demo: true);
  if (appearance != null) {
    await store.change((data) => data.settings['theme'] = appearance);
  }
  await tester.pumpWidget(
    FinDashApp(store: store, ai: AiService(store, TestVault())),
  );
  await tester.pumpAndSettle();
  return store;
}

Brightness appearanceOf(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(HomePage))).brightness;

void main() {
  testWidgets(
    'fresh ledgers and demo start with the recommended light appearance',
    (tester) async {
      expect(WalletData().settings['theme'], 'light');
      await renderApp(tester);
      expect(appearanceOf(tester), Brightness.light);
      expect(find.byTooltip('切换外观'), findsOneWidget);
    },
  );

  testWidgets(
    'appearance picker switches immediately and survives reopening the ledger',
    (tester) async {
      final storage = MemoryStorage();
      final store = await renderApp(tester, storage: storage);
      final ledger = store.data;
      final revision = store.ledgerRevision;
      final transactions = store.data.transactions
          .map((tx) => tx.toJson())
          .toList();
      final balances = store.activeAccounts.map(store.balance).toList();
      await tester.tap(find.byKey(const Key('theme-picker')));
      await tester.pumpAndSettle();
      expect(find.text('浅色 · 米白'), findsOneWidget);
      expect(find.text('深色 · 暖灰'), findsOneWidget);
      await tester.tap(find.byKey(const Key('theme-dark')));
      await tester.pump();
      expect(appearanceOf(tester), Brightness.dark);
      await tester.pumpAndSettle();
      expect(appearanceOf(tester), Brightness.dark);
      expect(find.text('选择你的外观'), findsNothing);
      expect(store.data.accounts, same(ledger.accounts));
      expect(store.data.transactions, same(ledger.transactions));
      expect(store.data.categories, same(ledger.categories));
      expect(store.data.quickEntries, same(ledger.quickEntries));
      expect(store.ledgerRevision, revision);
      expect(
        store.data.transactions.map((tx) => tx.toJson()).toList(),
        transactions,
      );
      expect(store.activeAccounts.map(store.balance).toList(), balances);
      final reopened = WalletStore(storage);
      await reopened.initialize();
      expect(reopened.data.settings['theme'], 'dark');
      await tester.pumpWidget(
        FinDashApp(store: reopened, ai: AiService(reopened, TestVault())),
      );
      await tester.pumpAndSettle();
      expect(appearanceOf(tester), Brightness.dark);
      await tester.tap(find.byKey(const Key('theme-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('theme-light')));
      await tester.pumpAndSettle();
      expect(appearanceOf(tester), Brightness.light);
      final restored = WalletStore(storage);
      await restored.initialize();
      expect(restored.data.settings['theme'], 'light');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('theme switching does not rebuild retained pages on each frame', (
    tester,
  ) async {
    final store = await renderApp(tester);
    for (final index in [1, 2, 3, 0]) {
      await tester.tap(find.byKey(Key('nav-$index')));
      await tester.pumpAndSettle();
    }
    final pages = [HomePage, StatsPage, BillsPage, ProfilePage];
    final states = [
      tester.state(find.byType(HomePage)),
      tester.state(find.byType(StatsPage, skipOffstage: false)),
      tester.state(find.byType(BillsPage, skipOffstage: false)),
    ];
    final builds = <Type, int>{};
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      final type = element.widget.runtimeType;
      if (pages.contains(type)) builds[type] = (builds[type] ?? 0) + 1;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    await store.changeMetadata((d) => d.settings['theme'] = 'dark');
    await tester.pump();
    expect(appearanceOf(tester), Brightness.dark);
    final firstFrameBuilds = Map<Type, int>.of(builds);
    expect(firstFrameBuilds.keys, unorderedEquals(pages));
    expect(firstFrameBuilds.values, everyElement(1));
    for (var frame = 0; frame < 16; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(builds, firstFrameBuilds);
    expect(tester.state(find.byType(HomePage)), same(states[0]));
    expect(
      tester.state(find.byType(StatsPage, skipOffstage: false)),
      same(states[1]),
    );
    expect(
      tester.state(find.byType(BillsPage, skipOffstage: false)),
      same(states[2]),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed theme save leaves the previous appearance and picker intact',
    (tester) async {
      final storage = MemoryStorage();
      final store = await renderApp(tester, storage: storage);
      storage.failWrites = true;
      await tester.tap(find.byKey(const Key('theme-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('theme-dark')));
      await tester.pumpAndSettle();
      expect(store.data.settings['theme'], 'light');
      expect(appearanceOf(tester), Brightness.light);
      expect(find.text('选择你的外观'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('asset choices and monthly overview respect hidden amounts', (
    tester,
  ) async {
    final store = await renderApp(tester);
    final overview = find.byType(OverviewGrid);
    await tester.tap(find.byKey(const Key('asset-view-2')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: overview,
        matching: find.text(money(store.liabilities)),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('隐藏金额'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: overview, matching: find.text('¥ ••••••')),
      findsNWidgets(4),
    );
    await tester.tap(find.byKey(const Key('asset-view-1')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: overview, matching: find.text('¥ ••••••')),
      findsNWidgets(4),
    );
    expect(tester.takeException(), isNull);
  });

  for (final theme in ['light', 'dark']) {
    for (final size in [const Size(320, 740), const Size(960, 900)]) {
      testWidgets(
        '$theme layout at ${size.width} with larger text supports all main pages and settings',
        (tester) async {
          await renderApp(
            tester,
            appearance: theme,
            size: size,
            textScale: 1.3,
          );
          expect(tester.takeException(), isNull);
          for (final index in [1, 2, 3, 0]) {
            await tester.tap(find.byKey(Key('nav-$index')));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: 'main page $index');
          }
          final context = tester.element(find.byType(HomePage));
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(
            find.byKey(Key('theme-${theme == 'light' ? 'dark' : 'light'}')),
          );
          await tester.pumpAndSettle();
          expect(
            Theme.of(tester.element(find.byType(SettingsPage))).brightness,
            theme == 'light' ? Brightness.dark : Brightness.light,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
