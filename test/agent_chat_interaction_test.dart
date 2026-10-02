import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/ui/agent_action_card.dart';
import 'package:fin_dash/ui/ai_pages.dart';
import 'package:fin_dash/ui/design.dart';
import 'helpers.dart';

Widget chatHarness(WalletStore store, AiService ai) => AppScope(
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
    home: const ChatPage(),
  ),
);

void main() {
  testWidgets(
    'proposal is confirmed directly in chat with persisted decision and result',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryStorage();
      final store = await emptyStore(storage);
      await store.saveAccount(bank);
      final ai = AiService(store, TestVault());
      final proposal = await ai.actions.propose('account', {
        'id': 'bank',
        'name': '工资卡',
        'reason': '不应默认展示的一长串参数说明',
      });
      await store.change(
        (d) => d.chats.add({
          'id': 'proposal-message',
          'role': 'assistant',
          'content': '请确认账户名称。',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'status': 'complete',
          'blocks': [
            {
              'type': 'tool',
              'name': 'propose_account_change',
              'status': 'complete',
              'result': jsonEncode(proposal),
            },
            {'type': 'text', 'text': '请确认账户名称。'},
          ],
        }),
      );
      await tester.pumpWidget(chatHarness(store, ai));
      await tester.pumpAndSettle();
      expect(find.byType(AgentActionCard), findsOneWidget);
      expect(find.text('账户名称：银行卡 → 工资卡'), findsOneWidget);
      expect(find.text('不应默认展示的一长串参数说明'), findsNothing);
      expect(store.account('bank')!.name, '银行卡');
      await tester.tap(find.text('确认执行'));
      await tester.pumpAndSettle();
      expect(store.account('bank')!.name, '工资卡');
      expect(store.data.chats[1]['role'], 'user');
      expect(store.data.chats[1]['content'], contains('确认执行'));
      expect(store.data.chats.last['content'], contains('已执行并保存到账本'));
      expect(
        find.textContaining('已执行并保存到账本', findRichText: true),
        findsWidgets,
      );
      final reloaded = await emptyStore(storage);
      expect(reloaded.data.chats.last['actionStatus'], 'applied');
      expect(reloaded.account('bank')!.name, '工资卡');
      expect(tester.takeException(), null);
    },
  );

  testWidgets('unlinked pending proposals can be rejected in chat', (
    tester,
  ) async {
    final store = await emptyStore();
    final ai = AiService(store, TestVault());
    await ai.actions.propose('budget', {'amountCents': 20000});
    await tester.pumpWidget(chatHarness(store, ai));
    await tester.pumpAndSettle();
    expect(find.text('月预算：¥ 0.00 → ¥ 200.00'), findsOneWidget);
    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    expect(store.data.settings['budget'], 0);
    expect(ai.actions.items.single['status'], 'rejected');
    expect(store.data.chats.first['role'], 'user');
    expect(store.data.chats.last['content'], contains('本次变更未写入账本'));
    expect(find.textContaining('本次变更未写入账本', findRichText: true), findsWidgets);
  });

  testWidgets(
    'failed confirmation stays pending with an inline error and no success feedback',
    (tester) async {
      final storage = MemoryStorage();
      final store = await emptyStore(storage);
      final ai = AiService(store, TestVault());
      await ai.actions.propose('budget', {'amountCents': 20000});
      await tester.pumpWidget(chatHarness(store, ai));
      await tester.pumpAndSettle();
      storage.failWrites = true;
      await tester.tap(find.text('确认执行'));
      await tester.pumpAndSettle();
      expect(find.text('操作未保存，请重试。'), findsOneWidget);
      expect(ai.actions.items.single['status'], 'pending');
      expect(store.data.settings['budget'], 0);
      expect(store.data.chats, isEmpty);
      storage.failWrites = false;
      await tester.tap(find.text('确认执行'));
      await tester.pumpAndSettle();
      expect(store.data.settings['budget'], 20000);
      expect(store.data.chats.last['content'], contains('已执行并保存到账本'));
      expect(tester.takeException(), null);
    },
  );

  testWidgets('reused proposals appear once and undo produces chat feedback', (
    tester,
  ) async {
    final store = await emptyStore();
    final ai = AiService(store, TestVault());
    final proposal = await ai.actions.propose('budget', {'amountCents': 20000});
    await store.change((d) {
      for (var i = 0; i < 2; i++) {
        d.chats.add({
          'id': 'proposal-$i',
          'role': 'assistant',
          'content': '',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'status': 'complete',
          'blocks': [
            {
              'type': 'tool',
              'name': 'propose_budget',
              'status': 'complete',
              'result': jsonEncode(proposal),
            },
          ],
        });
      }
    });
    await tester.pumpWidget(chatHarness(store, ai));
    await tester.pumpAndSettle();
    expect(find.byType(AgentActionCard), findsOneWidget);
    await tester.tap(find.text('确认执行'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('撤销本次操作'));
    await tester.tap(find.text('撤销本次操作'));
    await tester.pumpAndSettle();
    expect(store.data.settings['budget'], 0);
    expect(ai.actions.items.single['status'], 'undone');
    expect(store.data.chats.last['content'], contains('已撤销，相关数据已恢复'));
    expect(tester.takeException(), null);
  });

  testWidgets(
    'many tool calls and reasoning take one compact row with optional details',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await emptyStore();
      final ai = AiService(store, TestVault());
      await store.change(
        (d) => d.chats.add({
          'id': 'tools',
          'role': 'assistant',
          'content': '预算为零。',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'status': 'complete',
          'usage': [
            {'total_tokens': 100},
          ],
          'blocks': [
            {'type': 'reasoning', 'text': '先查询预算'},
            for (var i = 0; i < 12; i++)
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
      await tester.pumpWidget(chatHarness(store, ai));
      await tester.pumpAndSettle();
      final trace = find.byKey(const ValueKey('tools:processing'));
      expect(trace, findsOneWidget);
      expect(tester.getSize(trace).height, lessThanOrEqualTo(40));
      expect(find.text('12 次工具调用'), findsOneWidget);
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.text('调用参数'), findsNothing);
      expect(find.text('工具结果'), findsNothing);
      expect(find.text('用量与响应信息'), findsNothing);
      await tester.tap(trace);
      await tester.pumpAndSettle();
      await tester.tap(find.text('思考 / 摘要'));
      await tester.pumpAndSettle();
      expect(find.text('先查询预算'), findsOneWidget);
      await tester.tap(find.text('读取分类与预算').first);
      await tester.pumpAndSettle();
      expect(find.text('调用参数'), findsOneWidget);
      expect(find.text('工具结果'), findsOneWidget);
      expect(find.textContaining('budgetCents'), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );

  testWidgets('tool failures stay visible in the compact summary', (
    tester,
  ) async {
    final store = await emptyStore();
    final ai = AiService(store, TestVault());
    await store.change(
      (d) => d.chats.add({
        'id': 'failed-tool',
        'role': 'assistant',
        'content': '查询失败，请重试。',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'status': 'complete',
        'blocks': [
          {
            'type': 'tool',
            'name': 'query_tx',
            'arguments': '{}',
            'result': '{"error":"查询失败"}',
            'status': 'error',
          },
          {'type': 'text', 'text': '查询失败，请重试。'},
        ],
      }),
    );
    await tester.pumpWidget(chatHarness(store, ai));
    await tester.pumpAndSettle();
    expect(find.text('1 次工具调用 · 1 次失败'), findsOneWidget);
    expect(find.text('调用参数'), findsNothing);
    expect(tester.takeException(), null);
  });
}
