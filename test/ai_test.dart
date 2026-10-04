import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'helpers.dart';

http.Response reply(Json message) => http.Response(
  jsonEncode({
    'choices': [
      {'message': message},
    ],
  }),
  200,
  headers: {'content-type': 'application/json'},
);
void main() {
  test(
    'tool calls use real accounts and cognition waits for local review',
    () async {
      final store = await configuredAiStore();
      await store.saveAccount(bank);
      var round = 0;
      final ai = AiService(
        store,
        TestVault('test-key'),
        clientFactory: () => MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer test-key');
          final body = jsonDecode(request.body);
          expect(body['messages'][0]['content'], isNot(contains('test-key')));
          if (round++ == 0) {
            return reply({
              'content': null,
              'tool_calls': [
                {
                  'id': 'a',
                  'type': 'function',
                  'function': {
                    'name': 'get_accounts_overview',
                    'arguments': '{}',
                  },
                },
                {
                  'id': 'b',
                  'type': 'function',
                  'function': {
                    'name': 'update_user_cognition',
                    'arguments': jsonEncode({
                      'add_tags': ['节俭'],
                    }),
                  },
                },
              ],
            });
          }
          expect(store.data.agent['tags'], ['节俭']);
          final result = jsonDecode(
            body['messages'].firstWhere(
              (m) => m['tool_call_id'] == 'a',
            )['content'],
          );
          expect(result['netWorth'], 1000);
          return reply({'content': '已根据真实账户完成分析。'});
        }),
      );
      await ai.send('分析我的资产');
      expect(round, 1);
      expect(store.data.agent['tags'], isEmpty);
      final task = ai.tasks.tasks.single;
      await ai.tasks.applyPreference(
        task['id'],
        task['preferenceReview']['id'],
      );
      expect(store.data.agent['tags'], ['节俭']);
      expect(ai.error, null);
      expect(ai.busy, false);
      expect(store.data.chats.last['role'], 'assistant');
      expect(store.debugLogs.toString(), isNot(contains('test-key')));
    },
  );
  test(
    'briefing stays within budget and commitments are reviewed before follow-up',
    () async {
      final store = await configuredAiStore();
      final long = '很长的资料' * 100;
      await store.changeMetadata((d) {
        d.agent['tone'] = 'encouraging';
        d.agent['customPrompt'] = long * 4;
        d.agent['description'] = long;
        for (final field in ['tags', 'preferences', 'insights', 'focusAreas']) {
          d.agent[field] = [for (var i = 0; i < 30; i++) '$i$long'];
        }
        d.agent['memories'] = [
          for (var i = 0; i < 50; i++)
            {'id': 'm$i', 'fact': '$i$long', 'importance': 'core'},
        ];
        d.goals.addAll([
          for (var i = 0; i < 20; i++)
            {
              'id': 'g$i',
              'description': '旅行基金$long',
              'status': 'active',
              'motivation': long,
            },
        ]);
      });
      final today = dayKey(DateTime.now());
      final prompts = <String>[];
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient((request) async {
          final body = jsonDecode(request.body);
          prompts.add(body['messages'][0]['content']);
          if (prompts.length > 1) return reply({'content': '好的'});
          return reply({
            'content': null,
            'tool_calls': [
              {
                'id': 'c',
                'type': 'function',
                'function': {
                  'name': 'set_commitment',
                  'arguments': jsonEncode({
                    'text': '本周外卖不超过 3 次',
                    'check_date': today,
                  }),
                },
              },
            ],
          });
        }),
      );
      await ai.send('这周想少点外卖');
      expect(ai.error, null);
      expect(prompts.first, allOf(contains('温暖鼓励'), contains('旅行基金')));
      expect(ai.commitments, isEmpty);
      final task = ai.tasks.tasks.single;
      expect(task['preferenceReview']['summary'], contains('约定：本周外卖不超过 3 次'));
      await ai.tasks.applyPreference(
        task['id'],
        task['preferenceReview']['id'],
      );
      final id = ai.dueCommitments.single['id'];
      await ai.send('你好');
      expect(ai.error, null);
      expect(prompts.last, contains('"id":"$id","text":"本周外卖不超过 3 次"'));
      expect(prompts.last, contains('"due":true'));
    },
  );
  test(
    'network error retains user message and retry does not duplicate it',
    () async {
      final store = await configuredAiStore();
      var fail = true;
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient(
          (_) async => fail ? http.Response('', 401) : reply({'content': '成功'}),
        ),
      );
      await ai.send('你好');
      expect(ai.error, contains('密钥'));
      expect(store.data.chats.length, 2);
      expect(store.data.chats.last['status'], 'error');
      fail = false;
      await ai.retryLast();
      expect(store.data.chats.length, 2);
      expect(ai.error, null);
    },
  );
  test(
    'retry after missing key sends the failed prompt rather than a previous conversation',
    () async {
      final store = await configuredAiStore(), vault = TestVault();
      final ai = AiService(
        store,
        vault,
        clientFactory: () => MockClient((request) async {
          expect(jsonDecode(request.body)['messages'].last['content'], '新问题');
          return reply({'content': '回答'});
        }),
      );
      await ai.send('新问题');
      expect(store.data.chats, isEmpty);
      expect(ai.error, contains('填写 API'));
      vault.key = 'key';
      await ai.retryLast();
      expect(store.data.chats.first['content'], '新问题');
    },
  );
  test(
    'cancelled response cannot overwrite a newer request or append stale assistant text',
    () async {
      final store = await configuredAiStore();
      final first = Completer<http.Response>(),
          second = Completer<http.Response>();
      var index = 0;
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () {
          final current = index++;
          return MockClient(
            (_) async => current == 0 ? first.future : second.future,
          );
        },
      );
      final old = ai.send('旧问题');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      ai.cancel();
      final fresh = ai.send('新问题');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      first.complete(reply({'content': '过期回复'}));
      await old;
      expect(ai.busy, true);
      second.complete(reply({'content': '新回复'}));
      await fresh;
      expect(
        store.data.chats
            .where((m) => m['role'] == 'assistant')
            .single['content'],
        '新回复',
      );
      expect(ai.busy, false);
    },
  );
  test('historical analysis cache changes when ledger changes', () async {
    final store = await configuredAiStore();
    await store.saveAccount(bank);
    var requests = 0;
    final ai = AiService(
      store,
      TestVault('key'),
      clientFactory: () => MockClient((_) async {
        requests++;
        return reply({'content': '分析报告'});
      }),
    );
    final range = DateRange.forPeriod(Period.month, DateTime(2026, 10));
    await ai.send('分析', analysisRange: range);
    await ai.send('分析', analysisRange: range);
    expect(requests, 1);
    await store.saveTx(tx());
    await ai.send('分析', analysisRange: range);
    expect(requests, 2);
  });
  test(
    'query date boundaries are explicit and transfer is excluded from income and expense',
    () async {
      final store = await configuredAiStore();
      await store.saveAccount(bank);
      await store.saveAccount(cash);
      await store.saveTx(tx(date: DateTime(2026, 10, 1)));
      await store.saveTx(tx(id: 'end', date: DateTime(2026, 10, 2)));
      await store.saveTx(
        tx(id: 'transfer', type: TxType.transfer, from: 'bank', to: 'cash'),
      );
      final ai = AiService(store, TestVault());
      final result = await ai.executeTool('query_tx', {
        'start_date': '2026-10-01',
        'end_date': '2026-10-02',
      });
      expect(result['count'], 2);
      expect(result['expense'], 1.5);
      expect(result['income'], 0);
      expect(await ai.executeTool('unsupported', {}), contains('error'));
    },
  );
  test(
    'endpoint validation rejects credential forwarding to plain HTTP remote hosts',
    () {
      expect(
        endpoint('https://example.com/v1/').toString(),
        'https://example.com/v1/chat/completions',
      );
      expect(
        endpoint('https://example.com/v1/chat/completions').path,
        '/v1/chat/completions',
      );
      expect(() => endpoint('http://example.com/v1'), throwsFormatException);
      expect(() => endpoint('not-a-url'), throwsFormatException);
    },
  );
}
