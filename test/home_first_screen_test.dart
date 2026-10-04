import 'package:fin_dash/data/storage.dart';
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/main.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/services/payment_notifications.dart';
import 'package:fin_dash/services/voice_input.dart';
import 'package:fin_dash/ui/ai_pages.dart';
import 'package:fin_dash/ui/design.dart';
import 'package:fin_dash/ui/finance_pages.dart';
import 'package:fin_dash/ui/voice_entry_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers.dart';
import 'payment_notifications_test.dart' show event;

Future<WalletStore> renderHome(
  WidgetTester tester, {
  required Size size,
  double textScale = 1,
  String theme = 'light',
  double bottomInset = 34,
  double topInset = 24,
  bool pendingPayment = false,
  bool demo = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding(top: topInset, bottom: bottomInset);
  tester.view.viewPadding = FakeViewPadding(top: topInset, bottom: bottomInset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final store = WalletStore(MemoryStorage());
  await store.initialize(demo: demo);
  await store.change((data) {
    data.settings['theme'] = theme;
    data.profile['name'] = '首屏测试';
  });
  if (pendingPayment) {
    final payments = PaymentNotifications(store);
    await payments.ingest([event()]);
    await payments.markReminderSeen({'a' * 64});
  }
  await tester.pumpWidget(
    RepaintBoundary(
      key: const Key('home-test-capture'),
      child: FinDashApp(store: store, ai: AiService(store, TestVault())),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

void expectCoreEntriesVisible(WidgetTester tester) {
  final navigation = tester.getRect(find.byType(GlassPanel).last);
  final overview = tester.getRect(find.byKey(const Key('home-overview')));
  final actions = tester.getRect(find.byKey(const Key('home-actions')));
  final manual = tester.getRect(find.byKey(const Key('home-manual-actions')));
  final core = tester.getRect(find.byKey(const Key('home-core-actions')));
  expect(
    actions.top - overview.bottom,
    inInclusiveRange(12, 20),
    reason:
        'operations should follow the overview without stretched blank space',
  );
  expect(
    core.top - manual.bottom,
    inInclusiveRange(8, 16),
    reason: 'manual and AI operations should form one coordinated group',
  );
  for (final key in ['home-ai-entry', 'home-voice-entry']) {
    final entry = find.byKey(Key(key));
    final rect = tester.getRect(entry);
    expect(
      rect.top,
      greaterThanOrEqualTo(tester.view.padding.top),
      reason: '$key above safe area',
    );
    expect(
      rect.bottom,
      lessThanOrEqualTo(navigation.top - 12),
      reason: '$key must be fully above the floating navigation',
    );
    expect(rect.width, greaterThanOrEqualTo(48));
    expect(rect.height, greaterThanOrEqualTo(48));
    final touch = find.descendant(of: entry, matching: find.byType(InkWell));
    expect(touch.hitTestable(), findsOneWidget);
    for (final corner in [
      const Alignment(-.8, -.7),
      const Alignment(.8, -.7),
      const Alignment(-.8, .7),
      const Alignment(.8, .7),
    ]) {
      expect(
        touch.hitTestable(at: corner),
        findsOneWidget,
        reason: '$key touch target must remain unobstructed',
      );
    }
  }
  expect(tester.takeException(), isNull);
}

void main() {
  for (final scenario in [
    (const Size(320, 568), 1.3),
    (const Size(390, 844), 1.3),
  ]) {
    testWidgets(
      'pending payments at ${scenario.$1} do not displace the core entries',
      (tester) async {
        await renderHome(
          tester,
          size: scenario.$1,
          textScale: scenario.$2,
          pendingPayment: true,
        );
        expectCoreEntriesVisible(tester);
        await tester.scrollUntilVisible(
          find.byKey(const Key('home-payment-pending')),
          100,
          scrollable: find
              .descendant(
                of: find.byType(HomePage),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('home-payment-pending')), findsOneWidget);
      },
    );
    testWidgets(
      'an empty ledger at ${scenario.$1} keeps the same reachable entry positions',
      (tester) async {
        await renderHome(
          tester,
          size: scenario.$1,
          textScale: scenario.$2,
          demo: false,
        );
        expectCoreEntriesVisible(tester);
      },
    );
  }
  for (final theme in ['light', 'dark']) {
    testWidgets(
      '$theme tall status and system navigation bars still leave both entries visible',
      (tester) async {
        await renderHome(
          tester,
          size: const Size(320, 568),
          textScale: 2,
          theme: theme,
          topInset: 48,
          bottomInset: 48,
        );
        expectCoreEntriesVisible(tester);
      },
    );
    for (final scenario in [
      for (final size in [
        const Size(320, 568),
        const Size(360, 640),
        const Size(390, 844),
        const Size(412, 892),
        const Size(430, 932),
        const Size(600, 960),
      ])
        for (final scale in [1.0, 1.3, 1.6, 2.0]) (size, scale),
    ]) {
      testWidgets(
        '$theme ${scenario.$1} scale ${scenario.$2} keeps core entries visible on the first screen',
        (tester) async {
          await renderHome(
            tester,
            size: scenario.$1,
            textScale: scenario.$2,
            theme: theme,
          );
          expectCoreEntriesVisible(tester);
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
          expect(scroll.pixels, 0);
          await tester.drag(
            find
                .descendant(
                  of: find.byType(HomePage),
                  matching: find.byType(Scrollable),
                )
                .first,
            const Offset(0, -300),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('core entries open directly and move with the scroll content', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          VoiceInput.channel,
          (call) async => throw PlatformException(
            code: 'test-no-microphone',
            message: '测试设备未连接麦克风',
          ),
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(VoiceInput.channel, null),
    );
    await renderHome(tester, size: const Size(360, 640), textScale: 1.3);
    expectCoreEntriesVisible(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('home-ai-entry')),
        matching: find.byType(InkWell),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChatPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(ChatPage))).pop();
    await tester.pumpAndSettle();
    final voice = find.byKey(const Key('home-voice-entry'));
    await tester.tap(
      find.descendant(of: voice, matching: find.byType(InkWell)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(VoiceEntrySheet), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expectCoreEntriesVisible(tester);
    final before = tester.getRect(voice);
    await tester.drag(
      find
          .descendant(
            of: find.byType(HomePage),
            matching: find.byType(Scrollable),
          )
          .first,
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(voice).top, lessThan(before.top - 60));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'three-button navigation and a resized portrait viewport keep entry reachability',
    (tester) async {
      await renderHome(tester, size: const Size(390, 844), bottomInset: 48);
      expectCoreEntriesVisible(tester);
      tester.view.physicalSize = const Size(320, 640);
      await tester.pumpAndSettle();
      expectCoreEntriesVisible(tester);
      await tester.tap(find.byKey(const Key('nav-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-0')));
      await tester.pumpAndSettle();
      expectCoreEntriesVisible(tester);
    },
  );
}
