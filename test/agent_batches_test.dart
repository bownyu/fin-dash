import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/services/agent_actions.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/domain/agent_batch_summary.dart';
import 'helpers.dart';

Json change(String kind, Json input, {String? key}) => {
  'kind': kind,
  'input': input,
  'key': ?key,
};
Json newTx(String title, {String account = 'bank', bool uncertain = false}) => {
  'title': title,
  'type': 'expense',
  'amountCents': 1250,
  'category': '餐饮',
  'date': '2026-10-02T12:00:00',
  'accountId': account,
  if (uncertain) 'needsReview': true,
  if (uncertain) 'reviewNote': '商户用途不明确',
};
Future<void> prepare(
  AgentActions a,
  List<Json> changes, {
  String id = 'task',
  String session = 'legacy',
}) async {
  await a.proposeMany(changes, batchId: id, title: '整理账单', sessionId: session);
  await a.setGeneration(id, 'ready');
}

void main() {
  test(
    'revising legacy proposals adopts all original members without duplicate batches',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveTx(tx());
      final ai = AiService(store, TestVault());
      final p = await ai.actions.propose('transaction', {
        'id': 'tx',
        'category': '购物',
      });
      final q = await ai.actions.propose('budget', {'amountCents': 30000});
      await store.change(
        (d) => d.chats.add({
          'id': 'old',
          'role': 'assistant',
          'status': 'complete',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'blocks': [
            for (final output in [p, q])
              {
                'type': 'tool',
                'name': 'propose_transaction',
                'result': jsonEncode(output),
              },
          ],
        }),
      );
      final b = ai.actions.batches.single;
      final pending = await ai.executeTool('get_pending_actions', {});
      expect(
        (pending['actions'] as List).every((a) => a['batchId'] == b['id']),
        true,
      );
      await ai.executeTool('revise_changes', {
        'batchId': b['id'],
        'changes': [
          change('transaction', {'id': 'tx', 'category': '交通'}),
        ],
      });
      expect(ai.actions.batches.length, 1);
      expect(ai.actions.items.length, 2);
      final r = ai.actions.review(b['id']);
      expect(r.pending.length, 2);
      await ai.actions.applyBatch(b['id'], r.token, r.suggested);
      expect(store.data.transactions.single.category, '交通');
      expect(store.data.settings['budget'], 30000);
    },
  );

  test(
    'invalid preparation is atomic and uncertain dependencies are not implicitly selected',
    () async {
      final store = await emptyStore();
      final a = AgentActions(store);
      await expectLater(
        a.proposeMany(
          [
            change('account', {
              'name': '工资卡',
              'category': 'funds',
              'subType': 'bank_card',
            }, key: 'salary'),
            change('transaction', {
              ...newTx('午餐', account: '@salary'),
              'amountCents': -1,
            }),
          ],
          batchId: 'task',
          title: '整理',
          sessionId: 'legacy',
        ),
        throwsFormatException,
      );
      expect(a.items, isEmpty);
      expect(a.batches, isEmpty);
      expect(store.data.accounts, isEmpty);
      await prepare(a, [
        change('account', {
          'name': '工资卡',
          'category': 'funds',
          'subType': 'bank_card',
          'needsReview': true,
          'reviewNote': '需要核对账户',
        }, key: 'salary'),
        change('transaction', newTx('午餐', account: '@salary')),
      ]);
      expect(a.review('task').suggested, isEmpty);
    },
  );

  test(
    'legacy applied proposals preserve a grouped undo after upgrade',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final a = AgentActions(store);
      final p = await a.propose('transaction', newTx('午餐'));
      final q = await a.propose('budget', {'amountCents': 30000});
      await store.change(
        (d) => d.chats.add({
          'id': 'old',
          'role': 'assistant',
          'status': 'complete',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'blocks': [
            for (final output in [p, q])
              {
                'type': 'tool',
                'name': 'propose_transaction',
                'result': jsonEncode(output),
              },
          ],
        }),
      );
      await a.apply(p['proposalId']);
      await a.apply(q['proposalId']);
      final b = a.batches.single;
      await a.undoBatch(b['id'], b['receipts'].single['id']);
      expect(store.data.transactions, isEmpty);
      expect(store.data.settings['budget'], 0);
      expect(a.items.every((a) => a['status'] == 'undone'), true);
      expect(store.data.chats.length, 7);
    },
  );

  test(
    'many changes commit once with one receipt, idempotence and durable undo',
    () async {
      final storage = MemoryStorage(), store = await emptyStore();
      await store.saveAccount(bank);
      final a = AgentActions(store);
      await prepare(
        a,
        List.generate(50, (i) => change('transaction', newTx('午餐 $i'))),
      );
      final r = a.review('task');
      expect(store.data.transactions, isEmpty);
      expect(await a.applyBatch('task', r.token, r.suggested), 50);
      expect(store.data.transactions.length, 50);
      expect(store.data.chats.length, 2);
      expect(a.batches.single['receipts'].length, 1);
      await a.applyBatch('task', r.token, r.suggested);
      expect(store.data.transactions.length, 50);
      expect(store.data.chats.length, 2);
      final receipt = a.batches.single['receipts'].single['id'];
      await a.undoBatch('task', receipt);
      expect(store.data.transactions, isEmpty);
      expect(store.data.chats.length, 4);
      await a.undoBatch('task', receipt);
      expect(store.data.chats.length, 4);
      await storage.save(jsonEncode(store.data.toJson()));
      final restored = await emptyStore(storage);
      expect(
        AgentActions(restored).batches.single['receipts'].single['status'],
        'undone',
      );
      await expectLater(
        a.applyBatch('task', r.token, r.suggested),
        throwsFormatException,
      );
    },
  );

  test(
    'save failure rolls back all changes, statuses and feedback and can retry',
    () async {
      final storage = MemoryStorage(), store = await emptyStore(storage);
      await store.saveAccount(bank);
      final a = AgentActions(store);
      await prepare(a, [
        change('transaction', newTx('午餐')),
        change('budget', {'amountCents': 30000}),
      ]);
      final r = a.review('task');
      storage.failWrites = true;
      await expectLater(
        a.applyBatch('task', r.token, r.suggested),
        throwsStateError,
      );
      expect(store.data.transactions, isEmpty);
      expect(store.data.settings['budget'], 0);
      expect(a.items.every((a) => a['status'] == 'pending'), true);
      expect(store.data.chats, isEmpty);
      storage.failWrites = false;
      await a.applyBatch('task', r.token, r.suggested);
      final restored = await emptyStore(storage);
      expect(restored.data.transactions.length, 1);
      expect(restored.data.settings['budget'], 30000);
      expect(restored.data.chats.length, 2);
    },
  );

  test(
    'reviewed scope never expands into another task, session, or revision',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final a = AgentActions(store);
      await prepare(a, [change('transaction', newTx('午餐'))]);
      final r = a.review('task');
      await prepare(
        a,
        [change('transaction', newTx('晚餐'))],
        id: 'other',
        session: 'other-session',
      );
      final other = a.review('other');
      await expectLater(
        a.applyBatch('task', r.token, {...r.suggested, ...other.suggested}),
        throwsFormatException,
      );
      await a.proposeMany(
        [
          change('budget', {'amountCents': 50000}),
        ],
        batchId: 'task',
        title: '整理账单',
        sessionId: 'legacy',
      );
      await a.setGeneration('task', 'ready');
      await expectLater(
        a.applyBatch('task', r.token, r.suggested),
        throwsFormatException,
      );
      expect(store.data.transactions, isEmpty);
      final latest = a.review('task');
      await a.applyBatch('task', latest.token, latest.suggested);
      expect(store.data.transactions.single.title, '午餐');
      expect(a.review('other').pending.length, 1);
    },
  );

  test(
    'uncertain items stay unselected and conflict leaves valid items available',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveTx(tx());
      final a = AgentActions(store);
      await prepare(a, [
        change('transaction', {'id': 'tx', 'category': '购物'}),
        change('transaction', newTx('暂定', uncertain: true)),
        change('budget', {'amountCents': 30000}),
      ]);
      expect(a.review('task').suggested.length, 2);
      expect(
        a.items.firstWhere((a) => a['targetId'] == 'tx')['displaySummary'],
        contains('分类：餐饮 → 购物'),
      );
      await store.saveTx(tx(amount: 400));
      final r = a.review('task');
      expect(r.problems.length, 1);
      expect(r.suggested.length, 1);
      await expectLater(
        a.applyBatch(
          'task',
          r.token,
          r.pending.map((a) => a['id'] as String).toSet(),
        ),
        throwsFormatException,
      );
      expect(store.data.settings['budget'], 0);
      await a.applyBatch('task', r.token, r.suggested);
      expect(store.data.settings['budget'], 30000);
      expect(a.review('task').pending.length, 2);
    },
  );

  test(
    'conflicting item can be rebased only against the exact preview',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveTx(tx());
      final a = AgentActions(store);
      await prepare(a, [
        change('transaction', {'id': 'tx', 'category': '购物'}),
      ]);
      await store.saveTx(tx(amount: 400));
      final r = a.review('task'), id = a.items.single['id'];
      final preview = a.refreshedProposal(id);
      expect(preview['desired']['amountCents'], 400);
      await store.saveTx(tx(amount: 500));
      await expectLater(
        a.editProposal(
          'task',
          id,
          r.token,
          {},
          rebase: true,
          expectedBefore: Json.from(preview['before']),
        ),
        throwsFormatException,
      );
      final next = a.refreshedProposal(id);
      await a.editProposal(
        'task',
        id,
        r.token,
        {},
        rebase: true,
        expectedBefore: Json.from(next['before']),
      );
      final latest = a.review('task');
      expect(latest.problems, isEmpty);
      await a.applyBatch('task', latest.token, latest.suggested);
      expect(store.data.transactions.single.amount, 500);
      expect(store.data.transactions.single.category, '购物');
    },
  );

  test(
    'editing draft never writes the ledger and invalidates prior confirmation',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final a = AgentActions(store);
      await prepare(a, [change('transaction', newTx('午餐', uncertain: true))]);
      final r = a.review('task'), id = a.items.single['id'];
      await a.editProposal('task', id, r.token, {
        'category': '购物',
        'amountCents': 3000,
      });
      expect(store.data.transactions, isEmpty);
      expect(a.review('task').suggested.length, 1);
      await expectLater(
        a.applyBatch('task', r.token, {id}),
        throwsFormatException,
      );
      final next = a.review('task');
      await a.applyBatch('task', next.token, {id});
      expect(store.data.transactions.single.amount, 3000);
      expect(store.data.transactions.single.category, '购物');
    },
  );

  test(
    'task can prepare dependent account and transactions in one atomic draft',
    () async {
      final store = await emptyStore();
      final a = AgentActions(store);
      await prepare(a, [
        change('transaction', newTx('午餐', account: '@salary')),
        change('account', {
          'name': '工资卡',
          'category': 'funds',
          'subType': 'bank_card',
          'currentBalanceCents': 100000,
        }, key: 'salary'),
      ]);
      final r = a.review('task');
      expect(r.problems, isEmpty);
      expect(store.data.accounts, isEmpty);
      final transaction = r.items.firstWhere((a) => a['kind'] == 'transaction');
      await expectLater(
        a.applyBatch('task', r.token, {transaction['id']}),
        throwsFormatException,
      );
      expect(store.data.accounts, isEmpty);
      await a.applyBatch('task', r.token, r.suggested);
      expect(store.data.accounts.length, 1);
      expect(store.balance(store.data.accounts.single), 98750);
      await a.undoBatch('task', a.batches.single['receipts'].single['id']);
      expect(store.data.accounts, isEmpty);
      expect(store.data.transactions, isEmpty);
    },
  );

  test(
    'same target edits merge, retry reasons deduplicate, distinct keys preserve identical bills',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveTx(tx());
      final a = AgentActions(store);
      await prepare(a, [
        change('transaction', {'id': 'tx', 'category': '购物'}),
      ]);
      await a.proposeMany(
        [
          change('transaction', {'id': 'tx', 'note': '礼物'}),
        ],
        batchId: 'task',
        title: '整理',
        sessionId: 'legacy',
      );
      expect(a.items.single['desired']['category'], '购物');
      expect(a.items.single['desired']['note'], '礼物');
      await a.proposeMany(
        [
          change('transaction', {...newTx('午餐'), 'reason': '用途'}),
        ],
        batchId: 'task',
        title: '整理',
        sessionId: 'legacy',
      );
      await a.proposeMany(
        [
          change('transaction', {...newTx('午餐'), 'reason': '另一个说明'}),
        ],
        batchId: 'task',
        title: '整理',
        sessionId: 'legacy',
      );
      expect(a.items.length, 2);
      await a.proposeMany(
        [
          change('transaction', newTx('独立消费'), key: 'one'),
          change('transaction', newTx('独立消费'), key: 'two'),
        ],
        batchId: 'task',
        title: '整理',
        sessionId: 'legacy',
      );
      expect(a.items.length, 4);
    },
  );

  test(
    'undo conflict and failed undo leave the entire receipt applied',
    () async {
      final storage = MemoryStorage(), store = await emptyStore(storage);
      await store.saveAccount(bank);
      final a = AgentActions(store);
      await prepare(a, [
        change('transaction', newTx('午餐')),
        change('budget', {'amountCents': 30000}),
      ]);
      final r = a.review('task');
      await a.applyBatch('task', r.token, r.suggested);
      final receipt = a.batches.single['receipts'].single['id'];
      storage.failWrites = true;
      await expectLater(a.undoBatch('task', receipt), throwsStateError);
      expect(store.data.transactions.length, 1);
      expect(store.data.settings['budget'], 30000);
      storage.failWrites = false;
      await store.change((d) => d.settings['budget'] = 40000);
      await expectLater(a.undoBatch('task', receipt), throwsFormatException);
      expect(store.data.transactions.length, 1);
      expect(store.data.chats.length, 2);
    },
  );

  test(
    'interrupted draft requires explicit partial scope and restart recovers preparation',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final a = AgentActions(store);
      await a.proposeMany(
        [change('transaction', newTx('午餐'))],
        batchId: 'task',
        title: '整理',
        sessionId: 'legacy',
      );
      var r = a.review('task');
      await expectLater(
        a.applyBatch('task', r.token, r.suggested, allowPartial: true),
        throwsFormatException,
      );
      await a.recoverInterrupted();
      r = a.review('task');
      expect(r.batch['generation'], 'interrupted');
      await expectLater(
        a.applyBatch('task', r.token, r.suggested),
        throwsFormatException,
      );
      await a.applyBatch('task', r.token, r.suggested, allowPartial: true);
      expect(store.data.transactions.length, 1);
    },
  );

  test(
    'legacy multi-item replies become a single batch, cancel preserves ledger',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final a = AgentActions(store);
      final p = await a.propose('transaction', newTx('午餐'));
      final q = await a.propose('budget', {'amountCents': 30000});
      await store.change(
        (d) => d.chats.add({
          'id': 'old',
          'role': 'assistant',
          'status': 'complete',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'blocks': [
            for (final output in [p, q])
              {
                'type': 'tool',
                'name': 'propose_transaction',
                'result': jsonEncode(output),
              },
          ],
        }),
      );
      final r = a.review(a.batches.single['id']);
      expect(r.pending.length, 2);
      await a.rejectBatch(r.batch['id'], r.token);
      expect(store.data.transactions, isEmpty);
      expect(store.data.settings['budget'], 0);
      expect(a.items.every((a) => a['status'] == 'rejected'), true);
      expect(store.data.chats.length, 3);
    },
  );

  test(
    'pending query paginates, filters sessions and never exposes execute tools',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final ai = AiService(store, TestVault());
      await prepare(
        ai.actions,
        List.generate(110, (i) => change('transaction', newTx('午餐 $i'))),
      );
      await prepare(
        ai.actions,
        [
          change('budget', {'amountCents': 50000}),
        ],
        id: 'other',
        session: 'private',
      );
      final page = await ai.executeTool('get_pending_actions', {
        'offset': 50,
        'limit': 50,
      });
      expect(page['total'], 110);
      expect(page['actions'].length, 50);
      expect(page['nextOffset'], 100);
      expect(page['batches'].length, 1);
      expect(
        (await ai.executeTool('apply_batch', {'batchId': 'task'}))['error'],
        isNotNull,
      );
    },
  );

  test(
    'impact groups show reclassification, changed period, balance and budget',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveTx(tx());
      final a = AgentActions(store);
      await prepare(a, [
        change('transaction', {'id': 'tx', 'category': '购物'}),
      ]);
      var r = a.review('task');
      expect(agentBatchGroups(r.items).keys.single, '分类：餐饮 → 购物');
      expect(agentBatchImpact(r.items, (_) => '银行卡'), ['账户余额不变']);
      await a.editProposal('task', r.items.single['id'], r.token, {
        'date': '2026-09-30T12:00:00',
        'amountCents': 500,
      });
      r = a.review('task');
      expect(
        agentBatchImpact(r.items, (_) => '银行卡').join(),
        contains('月份统计会变化'),
      );
      expect(
        agentBatchImpact(r.items, (_) => '银行卡').join(),
        contains('-¥ 3.50'),
      );
    },
  );
}
