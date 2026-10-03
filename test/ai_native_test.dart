import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/application/ledger_commands.dart';
import 'package:fin_dash/application/ledger_queries.dart';
import 'package:fin_dash/agent/query_recipe.dart';
import 'package:fin_dash/agent/task_runtime.dart';
import 'package:fin_dash/data/storage_sqlite.dart';
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/domain/query_contracts.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/services/agent_actions.dart';
import 'package:fin_dash/services/voice_bookkeeping.dart';
import 'package:fin_dash/ui/design.dart';
import 'package:fin_dash/ui/tasks_page.dart';
import 'package:fin_dash/ui/finance_pages.dart';
import 'package:fin_dash/agent/model_queue.dart';
import 'helpers.dart';

Json recipe() => {
  'languageVersion': 1,
  'name': 'monthly_food',
  'description': '工作日餐饮',
  'parameters': {
    'range': {'type': 'TimeRange', 'required': true},
  },
  'steps': [
    {
      'id': 'rows',
      'op': 'scan',
      'dataset': 'ledger.transactions',
      'fields': ['occurredAt', 'amountCents'],
      'where': {
        'and': [
          {
            'field': 'type',
            'eq': {'literal': 'expense'},
          },
          {
            'field': 'occurredAt',
            'inRange': {'param': 'range'},
          },
        ],
      },
    },
    {
      'id': 'dates',
      'op': 'calendar',
      'from': 'rows',
      'field': 'occurredAt',
      'timezone': {'literal': 'local'},
      'components': ['weekday', 'month'],
    },
    {
      'id': 'weekdays',
      'op': 'filter',
      'from': 'dates',
      'where': {
        'field': 'weekday',
        'in': {
          'literal': [1, 2, 3, 4, 5],
        },
      },
    },
    {
      'id': 'monthly',
      'op': 'group',
      'from': 'weekdays',
      'keys': ['month'],
      'aggregates': {
        'totalCents': {'sumCents': 'amountCents'},
        'count': {'count': '*'},
      },
    },
    {
      'id': 'ordered',
      'op': 'sort',
      'from': 'monthly',
      'by': [
        {'field': 'month', 'direction': 'asc'},
      ],
    },
  ],
  'output': {
    'from': 'ordered',
    'fields': ['month', 'totalCents', 'count'],
  },
};
Json range() => {
  'range': {'startInclusive': '2026-10-01', 'endExclusive': '2026-11-01'},
};

class GateStorage extends MemoryStorage {
  Completer<void>? gate;
  @override
  Future<void> save(String data) async {
    if (gate != null) await gate!.future;
    await super.save(data);
  }
}

void main() {
  test(
    'manual, AI and voice reject the same invalid category without writes',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final invalid = LedgerTx.fromJson({...tx().toJson(), 'category': '不存在'}),
          before = store.data;
      await expectLater(store.saveTx(invalid), throwsFormatException);
      expect(
        () => AgentActions.prepareTransaction(
          store.data,
          {...invalid.toJson()}..remove('id'),
        ),
        throwsFormatException,
      );
      expect(
        () => VoiceDraft(
          'voice',
          {...invalid.toJson()}..remove('id'),
        ).validate(store.data),
        throwsFormatException,
      );
      expect(store.data, same(before));
    },
  );
  test(
    'queued lock blocks manual and previously reviewed batch, unlock remains available',
    () async {
      final storage = GateStorage(), store = await emptyStore(storage);
      await store.saveAccount(bank);
      final actions = AgentActions(store);
      await actions.proposeMany(
        [
          {
            'kind': 'budget',
            'input': {'amountCents': 3000},
          },
        ],
        batchId: 'plan',
        title: '预算',
        sessionId: 'legacy',
      );
      await actions.setGeneration('plan', 'ready');
      final review = actions.review('plan');
      storage.gate = Completer<void>();
      final lock = store.setLocked(true);
      final save = store.saveTx(tx());
      final apply = actions.applyBatch('plan', review.token, review.suggested);
      final saveCheck = expectLater(save, throwsFormatException),
          applyCheck = expectLater(apply, throwsFormatException);
      storage.gate!.complete();
      await lock;
      await saveCheck;
      await applyCheck;
      expect(store.data.transactions, isEmpty);
      expect(store.data.settings['budget'], 0);
      await store.setLocked(false);
      await store.saveTx(tx());
    },
  );
  test(
    'stable command retry checks payload, record version and durable receipt',
    () async {
      final storage = MemoryStorage(), store = await emptyStore(storage);
      await store.saveAccount(bank);
      final commands = LedgerCommands(store), epoch = store.ledgerEpoch;
      final first = await commands.saveTransaction(
        tx(),
        operationId: 'save',
        ledgerEpoch: epoch,
      );
      final duplicate = await commands.saveTransaction(
        tx(),
        operationId: 'save',
        ledgerEpoch: epoch,
      );
      expect(duplicate, first);
      expect(store.data.transactions.length, 1);
      await expectLater(
        commands.saveTransaction(
          tx(amount: 200),
          operationId: 'save',
          ledgerEpoch: epoch,
        ),
        throwsFormatException,
      );
      await store.saveTx(tx(amount: 250));
      await expectLater(
        commands.saveTransaction(
          tx(amount: 300),
          operationId: 'edit',
          ledgerEpoch: epoch,
          expected: tx(),
        ),
        throwsFormatException,
      );
      final reopened = await emptyStore(storage);
      expect(
        (reopened.data.extras['operationReceipts'] as List).single['id'],
        first['id'],
      );
    },
  );
  test('committed lists, nested JSON and assignment are immutable', () async {
    final store = await emptyStore();
    await store.saveAccount(bank);
    expect(() => store.data.accounts.clear(), throwsUnsupportedError);
    expect(() => store.data.agent['tags'].add('x'), throwsUnsupportedError);
    expect(() => store.data.settings = {}, throwsStateError);
  });
  test(
    'query full aggregate excludes transfers, pagination expires after change',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveAccount(cash);
      await store.saveTx(tx(id: 'expense', amount: 10000));
      await store.saveTx(tx(id: 'refund', type: TxType.income, amount: 3000));
      await store.saveTx(
        tx(
          id: 'transfer',
          type: TxType.transfer,
          from: 'bank',
          to: 'cash',
          amount: 1000,
        ),
      );
      final queries = LedgerQueries(store),
          summary = queries.query({}, aggregate: true);
      expect(summary.data['expenseCents'], 10000);
      expect(summary.data['incomeCents'], 3000);
      final first = queries.query({'limit': 1});
      expect(first.status, 'partial');
      expect(first.matchedRows, 3);
      expect(first.returnedRows, 1);
      await store.saveTx(tx(id: 'new'));
      expect(
        () => LedgerQueries(
          store,
        ).query({'limit': 1, 'cursor': first.nextCursor}),
        throwsA(isA<ErrorEnvelope>()),
      );
    },
  );
  test(
    'new composed query returns exact cents and stable month grouping',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveTx(
        tx(id: 'thu', amount: 1250, date: DateTime(2026, 10, 1, 12)),
      );
      await store.saveTx(
        tx(id: 'sat', amount: 9999, date: DateTime(2026, 10, 3, 12)),
      );
      final result = await QueryRecipe.parse(
        recipe(),
      ).run(LedgerQueries(store), range());
      expect(result.data, [
        {'month': '2026-10', 'totalCents': 1250, 'count': 1},
      ]);
      expect(result.toJson()['coverage']['status'], 'complete');
    },
  );
  for (final mutation in [
    'unknownField',
    'cycle',
    'write',
    'private',
    'tooManySteps',
  ]) {
    test('recipe rejects $mutation before execution', () {
      final input = recipe();
      final steps = input['steps'] as List;
      switch (mutation) {
        case 'unknownField':
          steps[0]['fields'] = ['apiKey'];
        case 'cycle':
          steps[1]['from'] = 'ordered';
        case 'write':
          steps[0]['op'] = 'executeSql';
        case 'private':
          steps[0]['dataset'] = 'providerConfigs';
        case 'tooManySteps':
          input['steps'] = List.generate(25, (_) => steps.first);
      }
      expect(() => QueryRecipe.parse(input), throwsA(isA<ErrorEnvelope>()));
    });
  }
  test('recipe cancellation and scan budget fail explicitly', () async {
    final store = await emptyStore();
    await store.saveAccount(bank);
    await expectLater(
      QueryRecipe.parse(
        recipe(),
      ).run(LedgerQueries(store), range(), cancelled: () => true),
      throwsA(isA<ErrorEnvelope>()),
    );
    await store.change(
      (d) =>
          d.transactions.addAll([for (var i = 0; i < 50001; i++) tx(id: '$i')]),
    );
    await expectLater(
      QueryRecipe.parse(recipe()).run(
        LedgerQueries(store),
        range(),
        timeBudget: const Duration(seconds: 20),
      ),
      throwsA(isA<ErrorEnvelope>()),
    );
  });
  test(
    'task clarification persists, rejects stale response and preserves known fields',
    () async {
      final storage = MemoryStorage(), store = await emptyStore(storage);
      await store.saveAccount(bank);
      final runtime = TaskRuntime(store),
          id = await TaskRuntime(store).start('午餐20元', source: 'import');
      final output = await runtime.request(id, {
        'title': '选择扣款账户',
        'fields': [
          {'key': 'accountId', 'type': 'accountChoice', 'required': true},
        ],
        'knownFields': {'amountCents': 2000, 'title': '午餐'},
      });
      final interaction = output['interaction'];
      final reopened = TaskRuntime(await emptyStore(storage));
      expect(reopened.get(id)['state'], 'needsInput');
      final answer = await reopened.respond(
        id,
        interaction['interactionId'],
        interaction['revision'],
        {'accountId': 'bank'},
      );
      expect(answer['amountCents'], 2000);
      await expectLater(
        reopened.respond(
          id,
          interaction['interactionId'],
          interaction['revision'],
          {'accountId': 'bank'},
        ),
        throwsA(isA<ErrorEnvelope>()),
      );
    },
  );
  test(
    'memory requires review, atomic failure keeps proposal, undo is conditional',
    () async {
      final storage = MemoryStorage(),
          store = await emptyStore(storage),
          ai = AiService(await emptyStore(), TestVault());
      final local = AiService(store, TestVault());
      final prepared = await local.executeTool('add_memory', {
        'fact': '喜欢简短回答',
      });
      expect(store.data.agent['memories'], isEmpty);
      storage.failWrites = true;
      await expectLater(
        local.tasks.applyPreference(prepared['taskId'], prepared['reviewId']),
        throwsStateError,
      );
      expect(store.data.agent['memories'], isEmpty);
      storage.failWrites = false;
      await local.tasks.applyPreference(
        prepared['taskId'],
        prepared['reviewId'],
      );
      expect(store.data.agent['memories'].single['fact'], '喜欢简短回答');
      await local.tasks.undoPreference(
        prepared['taskId'],
        prepared['reviewId'],
      );
      expect(store.data.agent['memories'], isEmpty);
      expect(
        (await ai.executeTool('ledger_commit', {'approved': true}))['ok'],
        false,
      );
      await expectLater(
        local.executeTool('ledger_query', {'unknown': true}),
        throwsFormatException,
      );
    },
  );
  test(
    '10000-row ledger chat save scans no financial rows; one edit has bounded payload',
    () async {
      final dir = await Directory.systemTemp.createTemp('findash-native-');
      addTearDown(() => dir.delete(recursive: true));
      final backend = LocalWalletStorage(directory: dir),
          store = WalletStore(LocalWalletStorage(directory: dir));
      await store.initialize();
      await store.saveAccount(bank);
      await store.change(
        (d) => d.transactions.addAll([
          for (var i = 0; i < 10000; i++) tx(id: '$i'),
        ]),
      );
      final ai = AiService(store, TestVault());
      await ai.newConversation();
      final stats = store.storage as LocalWalletStorage;
      expect(stats.lastScannedRows, lessThan(500));
      await store.saveTx(tx(id: '5000', amount: 200));
      expect(stats.lastScannedRows, lessThan(500));
      expect(
        (await backend.loadSnapshot())!.transactions
            .firstWhere((t) => t.id == '5000')
            .amount,
        200,
      );
    },
  );
  testWidgets(
    'clarification card fits 320px with large text and persists after reopen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await emptyStore();
      await store.saveAccount(bank);
      final ai = AiService(store, TestVault());
      final id = await ai.tasks.start('午餐20元');
      await ai.tasks.request(id, {
        'title': '从哪个账户扣款？',
        'fields': [
          {'key': 'accountId', 'label': '扣款账户', 'type': 'accountChoice'},
        ],
      });
      await tester.pumpWidget(
        AppScope(
          store: store,
          ai: ai,
          child: MaterialApp(
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(
                c,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: const TasksPage(),
          ),
        ),
      );
      expect(find.text('从哪个账户扣款？'), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );
  test(
    'native indexed query matches memory including exact date boundaries',
    () async {
      final dir = await Directory.systemTemp.createTemp('findash-query-');
      addTearDown(() => dir.delete(recursive: true));
      final store = WalletStore(LocalWalletStorage(directory: dir));
      await store.initialize();
      await store.saveAccount(bank);
      for (var i = 0; i < 15; i++) {
        await store.saveTx(
          tx(id: 'sql-$i', date: DateTime(2026, 10, i + 1), amount: 101 + i),
        );
      }
      final q = LedgerQueries(store);
      final args = <String, dynamic>{
        'startInclusive': '2026-10-03',
        'endExclusive': '2026-10-09',
        'limit': 2,
      };
      expect(
        (await q.queryAsync(args, aggregate: true)).data,
        q.query(args, aggregate: true).data,
      );
      final sql = await q.queryAsync(args), memory = q.query(args);
      expect(sql.data, memory.data);
      expect(sql.matchedRows, 6);
      expect(sql.nextCursor, memory.nextCursor);
    },
  );
  test(
    'waiting voice keeps the ledger queue free and cancels only its own request',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      store.setAiStatus('聊天处理中');
      final queue = ModelQueue(store);
      var ran = false;
      final pending = queue.run('voice-1', () async {
        ran = true;
        return 1;
      });
      final rejected = expectLater(pending, throwsFormatException);
      await store.saveTx(tx());
      expect(store.data.transactions.length, 1);
      expect(ran, false);
      queue.cancel('voice-1');
      await rejected;
      expect(store.aiStatus, '聊天处理中');
      store.setAiStatus(null);
    },
  );
  testWidgets(
    'AI busy, log, tokens and chat writes never rebuild financial page',
    (tester) async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final ai = AiService(store, TestVault());
      await tester.pumpWidget(
        AppScope(
          store: store,
          ai: ai,
          child: MaterialApp(
            theme: walletTheme(Brightness.light),
            home: const Scaffold(body: BillsPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      var builds = 0;
      final old = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        old?.call(element, builtOnce);
        if (element.widget is BillsPage) builds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = old);
      store.setAiStatus('生成中');
      await tester.pump();
      store.log('info', '测试');
      await tester.pump();
      ai.liveUpdates.value++;
      await tester.pump();
      await store.changeMetadata(
        (d) => d.chats.add({'id': 'chat', 'role': 'user', 'content': '你好'}),
      );
      await tester.pump();
      expect(builds, 0);
      await store.saveTx(tx());
      await tester.pump();
      expect(builds, 1);
      store.setAiStatus(null);
    },
  );
  test('query type checker rejects unit mismatch even on empty ledgers', () {
    final input = recipe();
    input['steps'][0]['where'] = {
      'field': 'amountCents',
      'eq': {'literal': '100'},
    };
    expect(() => QueryRecipe.parse(input), throwsA(isA<ErrorEnvelope>()));
  });
  test(
    'three invalid program repairs exhaust task budget and tools cannot forge authority',
    () async {
      final store = await emptyStore(),
          ai = AiService(await emptyStore(), TestVault());
      for (var i = 0; i < 3; i++) {
        final response = await ai.executeTool('recipes_validate', {
          'recipe': {'languageVersion': 99},
        });
        expect(response['ok'], false);
      }
      final denied = await ai.executeTool('recipes_validate', {
        'recipe': recipe(),
      });
      expect(denied['code'], 'LIMIT_EXCEEDED');
      final local = AiService(store, TestVault());
      await store.setLocked(true);
      expect((await local.executeTool('ledger_query', {}))['code'], 'LOCKED');
    },
  );
}
