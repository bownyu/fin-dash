import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'agent_batches_test.dart' show change, newTx, prepare;
import 'helpers.dart';

http.Response reply(Json message) => http.Response(
  jsonEncode({
    'choices': [
      {'message': message},
    ],
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Json call(String id, String name, Json args) => {
  'id': id,
  'type': 'function',
  'function': {'name': name, 'arguments': jsonEncode(args)},
};

void main() {
  test(
    'crash before reply save recovers the original user task instead of a later prompt',
    () async {
      final store = await configuredAiStore();
      await store.saveAccount(bank);
      await store.change(
        (d) => d.chats.add({
          'id': 'original-user',
          'role': 'user',
          'content': '整理原账单',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient((request) async {
          final users = (jsonDecode(request.body)['messages'] as List).where(
            (m) => m['role'] == 'user',
          );
          expect(users.last['content'], '整理原账单');
          return reply({'content': '已检查保留的方案。'});
        }),
      );
      await ai.actions.proposeMany(
        [change('transaction', newTx('午餐'))],
        batchId: 'lost-reply',
        title: '整理原账单',
        sessionId: 'legacy',
        sourceMessageId: 'lost-reply',
        sourceUserMessageId: 'original-user',
      );
      await store.change(
        (d) => d.chats.add({
          'id': 'later-user',
          'role': 'user',
          'content': '另一个问题',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      await ai.actions.recoverInterrupted();
      expect(store.data.chats.last['sourceUserMessageId'], 'original-user');
      await ai.retryMessage('lost-reply');
      expect(ai.error, null);
      expect(ai.actions.batches.single['generation'], 'ready');
      expect(ai.actions.items.length, 1);
      expect(store.data.transactions, isEmpty);
    },
  );

  test(
    'several tool calls in one task produce one ready batch and no ledger writes',
    () async {
      final store = await configuredAiStore();
      await store.saveAccount(bank);
      var requests = 0;
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient((request) async {
          final sent = jsonDecode(request.body);
          final names = (sent['tools'] as List)
              .map((t) => t['function']['name'])
              .toList();
          expect(names, containsAll(['propose_changes', 'revise_changes']));
          expect(names, isNot(contains('apply_batch')));
          if (requests++ == 0) {
            return reply({
              'tool_calls': [
                call('one', 'propose_changes', {
                  'changes': [
                    change('transaction', newTx('午餐')),
                    change('transaction', newTx('晚餐')),
                  ],
                }),
                call('two', 'propose_budget', {'amountCents': 40000}),
              ],
            });
          }
          return reply({'content': '请审阅方案并统一确认。'});
        }),
      );
      await ai.send('整理这批账单，我确认执行');
      expect(ai.error, null);
      expect(ai.actions.batches.length, 1);
      final r = ai.actions.review(ai.actions.batches.single['id']);
      expect(r.batch['generation'], 'ready');
      expect(r.pending.length, 3);
      expect(store.data.transactions, isEmpty);
      expect(store.data.settings['budget'], 0);
    },
  );

  test(
    'network interruption retains draft and retry resumes same batch without duplicates',
    () async {
      final store = await configuredAiStore();
      await store.saveAccount(bank);
      var requests = 0;
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient((_) async {
          switch (requests++) {
            case 0:
              return reply({
                'tool_calls': [
                  call('one', 'propose_changes', {
                    'changes': [change('transaction', newTx('午餐'))],
                  }),
                ],
              });
            case 1:
              return http.Response('temporarily unavailable', 503);
            default:
              return reply({'content': '准备完成。'});
          }
        }),
      );
      await ai.send('整理账单');
      expect(ai.error, isNotNull);
      final b = ai.actions.batches.single;
      expect(b['generation'], 'interrupted');
      expect(store.data.transactions, isEmpty);
      await ai.retryMessage(b['sourceMessageId']);
      expect(ai.error, null);
      expect(ai.actions.batches.length, 1);
      expect(ai.actions.items.length, 1);
      expect(ai.actions.batches.single['generation'], 'ready');
    },
  );

  test(
    'follow-up revises original scheme and retry restores revision task association',
    () async {
      final store = await configuredAiStore();
      await store.saveAccount(bank);
      await store.saveTx(tx());
      var requests = 0;
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient((_) async {
          switch (requests++) {
            case 0:
              return reply({
                'tool_calls': [
                  call('revision', 'revise_changes', {
                    'batchId': 'task',
                    'changes': [
                      change('transaction', {'id': 'tx', 'category': '交通'}),
                    ],
                  }),
                ],
              });
            case 1:
              return http.Response('retry later', 503);
            default:
              return reply({'content': '已更新原方案。'});
          }
        }),
      );
      await prepare(ai.actions, [
        change('transaction', {'id': 'tx', 'category': '购物'}),
      ]);
      final original = ai.actions.review('task');
      await ai.send('刚才那笔归为交通，其他不变');
      expect(ai.actions.batches.length, 1);
      expect(ai.actions.items.length, 1);
      expect(ai.actions.items.single['desired']['category'], '交通');
      expect(ai.actions.batches.single['generation'], 'interrupted');
      await ai.retryMessage(ai.actions.batches.single['sourceMessageId']);
      expect(ai.actions.batches.single['generation'], 'ready');
      await expectLater(
        ai.actions.applyBatch('task', original.token, original.suggested),
        throwsFormatException,
      );
      final r = ai.actions.review('task');
      await ai.actions.applyBatch('task', r.token, r.suggested);
      expect(store.data.transactions.single.category, '交通');
    },
  );

  test(
    'failed preparation cannot masquerade as a complete scheme, continuation repairs it',
    () async {
      final store = await configuredAiStore();
      await store.saveAccount(bank);
      var requests = 0;
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient((_) async {
          switch (requests++) {
            case 0:
              return reply({
                'tool_calls': [
                  call('good', 'propose_transaction', newTx('午餐')),
                  call('bad', 'propose_transaction', {
                    ...newTx('晚餐'),
                    'amountCents': -20,
                  }),
                ],
              });
            case 1:
              return reply({'content': '部分准备完成。'});
            case 2:
              return reply({
                'tool_calls': [
                  call('fixed', 'propose_transaction', newTx('晚餐')),
                ],
              });
            default:
              return reply({'content': '准备完成。'});
          }
        }),
      );
      await ai.send('整理两笔账单');
      final b = ai.actions.batches.single;
      expect(b['generation'], 'interrupted');
      expect(b['preparationErrors'], 1);
      await ai.retryMessage(b['sourceMessageId']);
      expect(ai.error, null);
      expect(ai.actions.batches.single['generation'], 'ready');
      expect(ai.actions.items.length, 2);
      expect(store.data.transactions, isEmpty);
    },
  );
}
