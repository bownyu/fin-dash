import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/ui/design.dart';
import 'package:fin_dash/ui/agent_actions_page.dart';
import 'package:fin_dash/ui/payment_notifications_page.dart';
import 'package:fin_dash/ui/ai_pages.dart';
import 'package:fin_dash/ui/preferences.dart';
import 'helpers.dart';

Widget harness(WalletStore store, AiService ai, Widget page) => AppScope(
  store: store,
  ai: ai,
  child: MaterialApp(
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: walletTheme(Brightness.light),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(1.3)),
      child: child!,
    ),
    home: page,
  ),
);

void main() {
  testWidgets('custom settings and expanded agent events fit a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = await configuredAiStore();
    final ai = AiService(store, TestVault());
    await tester.pumpWidget(harness(store, ai, const AiSettingsPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('edit-provider:custom')));
    await tester.pumpAndSettle();
    expect(find.text('接口协议'), findsOneWidget);
    expect(find.text('智谱 AI'), findsNothing);
    expect(find.text('NVIDIA NIM'), findsNothing);
    await tester.tap(find.text('Chat Completions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Responses').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('高级选项'));
    await tester.tap(find.text('高级选项'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('请求思考摘要'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), null);
    Navigator.of(tester.element(find.byType(AiConfigurationEditor))).pop();
    await tester.pumpAndSettle();
    await store.change(
      (d) => d.chats.add({
        'id': 'streamed',
        'role': 'assistant',
        'content': '预算为零。',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'status': 'complete',
        'blocks': [
          {'type': 'reasoning', 'text': '先查询预算'},
          {
            'type': 'tool',
            'name': 'get_app_settings',
            'arguments': '{}',
            'result': '{"budgetCents":0}',
            'status': 'complete',
          },
          {'type': 'text', 'text': '预算为零。'},
        ],
      }),
    );
    await tester.pumpWidget(harness(store, ai, const ChatPage()));
    await tester.pumpAndSettle();
    expect(find.text('思考 / 摘要'), findsNothing);
    await tester.tap(find.text('1 次工具调用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('思考 / 摘要'));
    await tester.pumpAndSettle();
    expect(find.text('先查询预算'), findsOneWidget);
    await tester.tap(find.text('读取分类与预算'));
    await tester.pumpAndSettle();
    expect(find.text('调用参数'), findsOneWidget);
    expect(find.text('工具结果'), findsOneWidget);
    expect(tester.takeException(), null);
  });
  const channel = MethodChannel('findash/payment_notifications');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => switch (call.method) {
            'peek' => <dynamic>[],
            'status' => {
              'enabled': false,
              'granted': false,
              'connected': false,
              'queued': 0,
              'lastReceived': 0,
            },
            _ => null,
          },
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  testWidgets(
    'transaction preview identifies unchanged accounts and balance effects',
    (tester) async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveAccount(cash);
      await store.saveTx(tx(type: TxType.transfer, from: 'bank', to: 'cash'));
      final ai = AiService(store, TestVault());
      await ai.actions.propose('transaction', {'id': 'tx', 'amountCents': 300});
      await tester.pumpWidget(harness(store, ai, const AgentActionsPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看详情'));
      await tester.pumpAndSettle();
      expect(find.text('转出账户：银行卡'), findsOneWidget);
      expect(find.text('转入账户：现金'), findsOneWidget);
      expect(find.text('银行卡余额影响：-¥ 1.50'), findsOneWidget);
      expect(find.text('现金余额影响：+¥ 1.50'), findsOneWidget);
      expect(store.balance(bank), 99850);
    },
  );

  testWidgets(
    'proposal review shows a real diff and only applies after button tap',
    (tester) async {
      tester.view.physicalSize = const Size(320, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await emptyStore();
      await store.saveAccount(bank);
      final ai = AiService(store, TestVault());
      await ai.actions.propose('account', {'id': 'bank', 'name': '工资卡'});
      await tester.pumpWidget(harness(store, ai, const AgentActionsPage()));
      await tester.pumpAndSettle();
      expect(find.text('账户名称：银行卡 → 工资卡'), findsOneWidget);
      expect(store.account('bank')!.name, '银行卡');
      await tester.ensureVisible(find.text('确认执行'));
      await tester.tap(find.text('确认执行'));
      await tester.pumpAndSettle();
      expect(store.account('bank')!.name, '工资卡');
      await tester.tap(find.text('操作历史'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('撤销本次操作'));
      await tester.tap(find.text('撤销本次操作'));
      await tester.pumpAndSettle();
      expect(store.account('bank')!.name, '银行卡');
      expect(tester.takeException(), null);
    },
  );

  testWidgets('chat and notification pages fit narrow Android layouts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = await emptyStore();
    final ai = AiService(store, TestVault());
    for (final page in [const ChatPage(), const PaymentNotificationsPage()]) {
      await tester.pumpWidget(harness(store, ai, page));
      await tester.pumpAndSettle();
      expect(tester.takeException(), null);
    }
  });
}
