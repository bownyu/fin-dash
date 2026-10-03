import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/ui/agent_action_card.dart';
import 'package:fin_dash/ui/agent_batch_card.dart';
import 'package:fin_dash/ui/agent_actions_page.dart';
import 'package:fin_dash/ui/editors.dart';
import 'agent_batches_test.dart' show change, newTx, prepare;
import 'agent_chat_interaction_test.dart' show chatHarness;
import 'agent_ui_test.dart' show harness;
import 'helpers.dart';

void narrow(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_AGENT_UI')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('agent-preview')),
  );
  await tester.runAsync(() async {
    final picture = await boundary.toImage(pixelRatio: 2);
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    await File('build/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    picture.dispose();
  });
}

void main() {
  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_AGENT_UI')) return;
    final font = ByteData.sublistView(
      await File('C:/Windows/Fonts/msyh.ttc').readAsBytes(),
    );
    for (final family in ['SF Pro Display', 'Ahem', 'Roboto']) {
      await (FontLoader(family)..addFont(Future.value(font))).load();
    }
    await (FontLoader('MaterialIcons')..addFont(
          Future(
            () async => ByteData.sublistView(
              await File(
                'D:/PC/ENV/Flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes(),
            ),
          ),
        ))
        .load();
  });
  testWidgets(
    'returning from review preserves the selected scope on the chat card',
    (tester) async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final ai = AiService(store, TestVault());
      await prepare(ai.actions, [
        change('transaction', newTx('午餐')),
        change('transaction', newTx('晚餐')),
      ]);
      await tester.pumpWidget(harness(store, ai, const AgentActionsPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看／调整明细'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('确认选中 1 项'), findsOneWidget);
      expect(store.data.transactions, isEmpty);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    '40 proposals occupy one chat card and confirm with one receipt',
    (tester) async {
      narrow(tester);
      final store = await emptyStore();
      await store.saveAccount(bank);
      final ai = AiService(store, TestVault());
      await prepare(
        ai.actions,
        List.generate(40, (i) => change('transaction', newTx('消费 $i'))),
      );
      await store.change(
        (d) => d.chats.add({
          'id': 'task',
          'role': 'assistant',
          'content': '方案已准备。',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'status': 'complete',
        }),
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('agent-preview'),
          child: chatHarness(store, ai),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AgentBatchCard), findsOneWidget);
      expect(find.byType(AgentActionCard), findsNothing);
      expect(find.text('确认选中 40 项'), findsOneWidget);
      expect(find.textContaining('新增「消费'), findsNothing);
      await capture(tester, 'agent-batch-summary');
      await tester.ensureVisible(find.text('确认选中 40 项'));
      await tester.tap(find.text('确认选中 40 项'));
      await tester.pumpAndSettle();
      expect(store.data.transactions.length, 40);
      expect(store.data.chats.length, 3);
      expect(find.byType(AgentBatchCard), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'uncertain items require explicit selection and clear differences on narrow screens',
    (tester) async {
      narrow(tester);
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveTx(tx());
      final ai = AiService(store, TestVault());
      await prepare(ai.actions, [
        change('transaction', {'id': 'tx', 'category': '购物'}),
        change('transaction', newTx('暂定', uncertain: true)),
      ]);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('agent-preview'),
          child: harness(
            store,
            ai,
            const AgentBatchReviewPage(batchId: 'task'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('分类：餐饮 → 购物'), findsOneWidget);
      expect(find.text('确认选中 1 项'), findsOneWidget);
      final uncertainRow = find.byType(CheckboxListTile).last;
      expect(tester.widget<CheckboxListTile>(uncertainRow).value, false);
      await capture(tester, 'agent-batch-review');
      await tester.tap(uncertainRow);
      await tester.pumpAndSettle();
      expect(find.text('确认选中 2 项'), findsOneWidget);
      expect(store.data.transactions.length, 1);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'draft transaction editor changes proposal without writing ledger',
    (tester) async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final ai = AiService(store, TestVault());
      await prepare(ai.actions, [
        change('transaction', newTx('午餐', uncertain: true)),
      ]);
      await tester.pumpWidget(
        harness(store, ai, const AgentBatchReviewPage(batchId: 'task')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('调整此项'));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionEditor), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('transaction-title')),
        200,
        scrollable: find
            .descendant(
              of: find.byType(TransactionEditor),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.enterText(find.byKey(const Key('transaction-title')), '聚餐');
      await tester.ensureVisible(find.text('更新方案'));
      await tester.tap(find.text('更新方案'));
      await tester.pumpAndSettle();
      expect(store.data.transactions, isEmpty);
      expect(ai.actions.items.single['desired']['title'], '聚餐');
      expect(ai.actions.items.single['needsReview'], false);
      expect(find.text('确认选中 1 项'), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );

  testWidgets('draft account editor and budget editor update only proposals', (
    tester,
  ) async {
    final store = await emptyStore();
    await store.saveAccount(bank);
    final ai = AiService(store, TestVault());
    await prepare(ai.actions, [
      change('account', {'id': 'bank', 'name': '工资卡'}),
      change('budget', {'amountCents': 30000}),
    ]);
    await tester.pumpWidget(
      harness(store, ai, const AgentBatchReviewPage(batchId: 'task')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('调整此项').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '工资卡'), '生活卡');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('更新方案'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(AccountEditor),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新方案'));
    await tester.pumpAndSettle();
    expect(store.account('bank')!.name, '银行卡');
    expect(
      ai.actions.items.firstWhere(
        (a) => a['kind'] == 'account',
      )['desired']['name'],
      '生活卡',
    );
    await tester.tap(find.text('调整此项').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '500.00');
    await tester.tap(find.text('更新方案'));
    await tester.pumpAndSettle();
    expect(store.data.settings['budget'], 0);
    expect(
      ai.actions.items.firstWhere(
        (a) => a['kind'] == 'budget',
      )['desired']['amountCents'],
      50000,
    );
    expect(tester.takeException(), null);
  });

  testWidgets('failed batch save retains selection and produces no success', (
    tester,
  ) async {
    final storage = MemoryStorage(), store = await emptyStore(storage);
    await store.saveAccount(bank);
    final ai = AiService(store, TestVault());
    await prepare(ai.actions, [
      change('transaction', newTx('午餐')),
      change('transaction', newTx('晚餐')),
    ]);
    await tester.pumpWidget(
      harness(store, ai, const AgentBatchReviewPage(batchId: 'task')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile).last);
    await tester.pumpAndSettle();
    storage.failWrites = true;
    await tester.tap(find.byKey(const Key('batch-review-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('操作未保存，请重试。'), findsOneWidget);
    expect(find.text('确认选中 1 项'), findsOneWidget);
    expect(store.data.transactions, isEmpty);
    expect(store.data.chats, isEmpty);
    storage.failWrites = false;
  });

  testWidgets('changing proposal disables stale review until refresh', (
    tester,
  ) async {
    final store = await emptyStore();
    await store.saveAccount(bank);
    final ai = AiService(store, TestVault());
    await prepare(ai.actions, [change('transaction', newTx('午餐'))]);
    await tester.pumpWidget(
      harness(store, ai, const AgentBatchReviewPage(batchId: 'task')),
    );
    await tester.pumpAndSettle();
    await ai.actions.proposeMany(
      [
        change('budget', {'amountCents': 50000}),
      ],
      batchId: 'task',
      title: '整理',
      sessionId: 'legacy',
    );
    await ai.actions.setGeneration('task', 'ready');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('batch-review-confirm')))
          .onPressed,
      null,
    );
    await tester.tap(find.text('刷新方案'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('batch-review-confirm')))
          .onPressed,
      isNotNull,
    );
    expect(find.text('确认选中 1 项'), findsOneWidget);
    expect(tester.takeException(), null);
  });

  testWidgets(
    'interrupted draft shows explicit partial scope and pinned confirmation',
    (tester) async {
      narrow(tester);
      final store = await emptyStore();
      await store.saveAccount(bank);
      final ai = AiService(store, TestVault());
      await prepare(ai.actions, [change('transaction', newTx('午餐'))]);
      await ai.actions.setGeneration('task', 'interrupted');
      await tester.pumpWidget(
        harness(store, ai, const AgentBatchReviewPage(batchId: 'task')),
      );
      await tester.pumpAndSettle();
      final confirm = find.byKey(const Key('batch-review-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, null);
      await tester.tap(find.text('只执行已准备部分，剩余任务尚未完成'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      expect(tester.getBottomRight(confirm).dy, lessThanOrEqualTo(900));
      expect(tester.takeException(), null);
    },
  );

  testWidgets('history uses one batch undo button and long review stays lazy', (
    tester,
  ) async {
    final store = await emptyStore();
    await store.saveAccount(bank);
    final ai = AiService(store, TestVault());
    await prepare(
      ai.actions,
      List.generate(150, (i) => change('transaction', newTx('消费 $i'))),
    );
    await tester.pumpWidget(
      harness(store, ai, const AgentBatchReviewPage(batchId: 'task')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile).evaluate().length, lessThan(20));
    final r = ai.actions.review('task');
    await ai.actions.applyBatch('task', r.token, r.suggested);
    await tester.pumpWidget(harness(store, ai, const AgentActionsPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('操作历史'));
    await tester.pumpAndSettle();
    expect(find.text('撤销本批次 150 项'), findsOneWidget);
    await tester.tap(find.text('撤销本批次 150 项'));
    await tester.pumpAndSettle();
    expect(store.data.transactions, isEmpty);
    expect(tester.takeException(), null);
  });
}
