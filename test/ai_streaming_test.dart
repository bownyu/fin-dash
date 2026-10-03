import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'helpers.dart';

http.Response jsonResponse(
  String body,
  int status, {
  Map<String, String> headers = const {},
}) => http.Response(
  body,
  status,
  headers: {'content-type': 'application/json; charset=utf-8', ...headers},
);

class StreamingClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  StreamingClient(this.handler);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

String event(Json value) => 'data: ${jsonEncode(value)}\r\n\r\n';
http.StreamedResponse sse(String text, {bool fragment = false}) {
  final bytes = utf8.encode(text);
  return http.StreamedResponse(
    Stream.fromIterable(fragment ? bytes.map((b) => [b]) : [bytes]),
    200,
    headers: {'content-type': 'text/event-stream', 'x-request-id': 'req-test'},
  );
}

Json chunk(Json delta, [String? finish]) => {
  'choices': [
    {'index': 0, 'delta': delta, 'finish_reason': finish},
  ],
};
Json output(String text) => {
  'type': 'message',
  'id': 'msg-1',
  'role': 'assistant',
  'status': 'completed',
  'content': [
    {'type': 'output_text', 'text': text, 'annotations': []},
  ],
};

void main() {
  test(
    'configuration save failure restores the previous key and endpoint',
    () async {
      final storage = MemoryStorage(), vault = TestVault('old-key');
      final store = await emptyStore(storage);
      await store.change(
        (d) => d.providerConfigs['custom'] = {
          'baseURL': 'https://old.example/v1',
          'model': 'old-model',
          'protocol': chatProtocol,
        },
      );
      final ai = AiService(store, vault);
      storage.failWrites = true;
      await expectLater(
        ai.saveConfiguration({
          'baseURL': 'https://new.example/v1',
          'model': 'new-model',
          'protocol': responsesProtocol,
        }, 'new-key'),
        throwsStateError,
      );
      expect(vault.key, 'old-key');
      expect(ai.config['baseURL'], 'https://old.example/v1');
      expect(ai.busy, false);
    },
  );

  test(
    'connection test sends no ledger or memory and does not save a conversation',
    () async {
      final store = await configuredAiStore();
      await store.saveAccount(bank);
      await store.change((d) => d.agent['description'] = 'private-profile');
      final ai = AiService(
        store,
        TestVault('secret-value'),
        clientFactory: () => MockClient((req) async {
          expect(req.body, isNot(contains('private-profile')));
          expect(req.body, isNot(contains('银行卡')));
          expect(jsonDecode(req.body).containsKey('tools'), false);
          return jsonResponse(
            '{"choices":[{"message":{"content":"OK"}}]}',
            200,
          );
        }),
      );
      expect(
        await ai.testConnection(ai.config, 'secret-value'),
        contains('连接成功'),
      );
      expect(store.data.chats, isEmpty);
    },
  );

  test('unfinished tool arguments never execute local tools', () async {
    final store = await configuredAiStore();
    final ai = AiService(
      store,
      TestVault('secret-value'),
      clientFactory: () => StreamingClient(
        (_) async => sse(
          event(
            chunk({
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'a',
                  'function': {
                    'name': 'propose_budget',
                    'arguments': '{"amountCents":10000}',
                  },
                },
              ],
            }),
          ),
        ),
      ),
    );
    await ai.send('设定预算');
    expect(ai.error, contains('提前断开'));
    expect(ai.actions.items, isEmpty);
    expect(store.data.chats.last['blocks'].first['status'], 'pending');
  });
  test(
    'retry resumes completed tools and history tool excludes internal transcripts',
    () async {
      final store = await configuredAiStore();
      var round = 0;
      final ai = AiService(
        store,
        TestVault('secret-value'),
        clientFactory: () => MockClient((request) async {
          if (round++ == 0) {
            return jsonResponse(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'tool_calls': [
                        {
                          'id': 'plan',
                          'type': 'function',
                          'function': {
                            'name': 'get_app_settings',
                            'arguments': '{}',
                          },
                        },
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }
          if (round == 2) {
            return jsonResponse(
              '{"error":{"message":"temporary failure"}}',
              503,
            );
          }
          expect(jsonDecode(request.body)['messages'].last['role'], 'tool');
          expect(store.data.goals.length, 0);
          return jsonResponse(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '已读取设置'},
                },
              ],
            }),
            200,
          );
        }),
      );
      await ai.send('读取预算设置');
      expect(ai.error, contains('503'));
      await ai.retryLast();
      expect(ai.error, null);
      expect(store.data.goals.length, 0);
      expect(store.data.chats.length, 2);
      final history = await ai.executeTool('get_chat_history', {
        'date': dayKey(DateTime.now()),
      });
      expect(jsonEncode(history), isNot(contains('modelMessages')));
      expect(jsonEncode(history), isNot(contains('responseItems')));
    },
  );

  test(
    'live chunks are observable before completion and cancellation retains partial output',
    () async {
      final store = await configuredAiStore();
      final controller = StreamController<List<int>>();
      final started = Completer<void>();
      final ai = AiService(
        store,
        TestVault('secret-value'),
        clientFactory: () => StreamingClient((_) async {
          started.complete();
          return http.StreamedResponse(
            controller.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
      final sending = ai.send('你好');
      await started.future;
      controller.add(
        utf8.encode(
          event(chunk({'reasoning_content': '先想一下', 'content': '部分内容'})),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(ai.liveMessage!['content'], '部分内容');
      expect(ai.busy, true);
      await ai.cancel();
      controller.add(utf8.encode(event(chunk({'content': '不应写入'}, 'stop'))));
      await controller.close();
      await sending;
      expect(ai.busy, false);
      expect(ai.error, null);
      expect(store.data.chats.last['content'], '部分内容');
      expect(store.data.chats.last['status'], 'cancelled');
    },
  );

  test('chat usage following finish_reason is retained', () async {
    final store = await configuredAiStore();
    final ai = AiService(
      store,
      TestVault('secret-value'),
      clientFactory: () => StreamingClient(
        (_) async => sse(
          '${event(chunk({'content': 'OK'}, 'stop'))}'
          '${event({
            'choices': [],
            'usage': {'prompt_tokens': 5, 'completion_tokens': 1},
          })}data: [DONE]\n\n',
        ),
      ),
    );
    await ai.send('hello');
    expect(ai.error, null);
    expect(store.data.chats.last['usage'].single['completion_tokens'], 1);
  });

  test(
    'new setup and editing preserve the legacy configuration identity and endpoint',
    () async {
      final store = await emptyStore(), vault = TestVault('legacy-key');
      final ai = AiService(store, vault);
      expect(ai.provider, 'custom');
      expect(ai.config['model'], '');
      await store.change((d) {
        d.settings['provider'] = 'nvidia';
        d.providerConfigs['nvidia'] = {
          'baseURL': 'https://existing.example/v1',
          'model': 'existing-model',
          'supportsImages': true,
        };
      });
      expect(ai.config['baseURL'], 'https://existing.example/v1');
      await ai.saveConfiguration({
        ...ai.config,
        'protocol': responsesProtocol,
      }, 'new-key');
      expect(ai.provider, 'nvidia');
      expect(ai.config['baseURL'], 'https://existing.example/v1');
      expect(ai.config['protocol'], responsesProtocol);
      expect(vault.key, 'new-key');
    },
  );
  test(
    'endpoint accepts either complete path and normalizes the selected protocol',
    () {
      expect(
        endpoint(
          'https://example.com/v1/chat/completions/',
          protocol: responsesProtocol,
        ).path,
        '/v1/responses',
      );
      expect(
        endpoint('https://example.com/v1/responses').path,
        '/v1/chat/completions',
      );
      expect(
        () => endpoint('https://user:pass@example.com/v1'),
        throwsFormatException,
      );
    },
  );

  test(
    'chat SSE handles split UTF8, reasoning and interleaved tool arguments',
    () async {
      final store = await configuredAiStore();
      var rounds = 0;
      final ai = AiService(
        store,
        TestVault('secret-value'),
        clientFactory: () => StreamingClient((request) async {
          final body = jsonDecode((request as http.Request).body);
          expect(body['stream'], true);
          expect(body.containsKey('temperature'), false);
          if (rounds++ == 0) {
            return sse(
              ': keepalive\r\n\r\n${event(chunk({'reasoning_content': '先核对预算。'}))}'
              '${event(chunk({
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'a',
                    'function': {'name': 'get_app_settings', 'arguments': '{'},
                  },
                  {
                    'index': 1,
                    'id': 'b',
                    'function': {'name': 'search_memories', 'arguments': '{"query":"工资'},
                  },
                ],
              }))}'
              '${event(chunk({
                'tool_calls': [
                  {
                    'index': 1,
                    'function': {'arguments': '15号发"}'},
                  },
                  {
                    'index': 0,
                    'function': {'arguments': '}'},
                  },
                ],
              }, 'tool_calls'))}data: [DONE]\r\n\r\n',
              fragment: true,
            );
          }
          final messages = body['messages'] as List;
          expect(messages.where((m) => m['role'] == 'tool').length, 2);
          expect(store.data.agent['memories'], isEmpty);
          expect(
            messages.firstWhere(
              (m) => m['tool_calls'] != null,
            )['reasoning_content'],
            '先核对预算。',
          );
          return sse(
            '${event(chunk({'content': '已查询。'}))}${event(chunk({}, 'stop'))}data: [DONE]\n\n',
            fragment: true,
          );
        }),
      );
      await ai.send('看看预算和工资记录');
      expect(ai.error, null);
      final run = store.data.chats.last;
      expect(run['content'], '已查询。');
      expect(run['blocks'].first['text'], '先核对预算。');
      expect(
        (run['blocks'] as List)
            .where((b) => b['type'] == 'tool')
            .every((b) => b['status'] == 'complete'),
        true,
      );
      expect(run['modelMessages'].length, 4);
    },
  );

  test('Responses SSE replays reasoning and call_id with function_call_output', () async {
    final store = await configuredAiStore();
    await store.change(
      (d) => d.providerConfigs['custom']['protocol'] = responsesProtocol,
    );
    var round = 0;
    final reasoning = <String, dynamic>{
      'type': 'reasoning',
      'id': 'rs-1',
      'summary': [
        {'type': 'summary_text', 'text': '读取账户'},
      ],
      'encrypted_content': 'opaque-reasoning',
    };
    final call = <String, dynamic>{
      'type': 'function_call',
      'id': 'fc-1',
      'call_id': 'call-1',
      'name': 'get_accounts_overview',
      'arguments': '{}',
      'status': 'completed',
    };
    final ai = AiService(
      store,
      TestVault('secret-value'),
      clientFactory: () => StreamingClient((request) async {
        expect(request.url.path, '/v1/responses');
        final body = jsonDecode((request as http.Request).body);
        expect(body.containsKey('messages'), false);
        expect(body['store'], false);
        expect(body['tools'].first['name'], 'get_app_settings');
        expect(body['tools'].first['strict'], false);
        if (round++ == 0) {
          return sse(
            '${event({'type': 'response.reasoning_summary_text.delta', 'delta': '读取账户'})}'
            '${event({'type': 'response.output_item.done', 'output_index': 0, 'item': reasoning})}'
            '${event({
              'type': 'response.output_item.added',
              'output_index': 1,
              'item': {...call, 'arguments': ''},
            })}'
            '${event({'type': 'response.function_call_arguments.delta', 'output_index': 1, 'delta': '{'})}'
            '${event({'type': 'response.function_call_arguments.delta', 'output_index': 1, 'delta': '}'})}'
            '${event({
              'type': 'response.completed',
              'response': {
                'id': 'resp-1',
                'status': 'completed',
                'output': [reasoning, call],
              },
            })}',
            fragment: true,
          );
        }
        final input = body['input'] as List;
        expect(
          input.any((m) => m['encrypted_content'] == 'opaque-reasoning'),
          true,
        );
        expect(
          input.firstWhere(
            (m) => m['type'] == 'function_call_output',
          )['call_id'],
          'call-1',
        );
        expect(
          jsonDecode(
            input.firstWhere(
              (m) => m['type'] == 'function_call_output',
            )['output'],
          )['netWorth'],
          0,
        );
        return sse(
          '${event({'type': 'response.output_text.delta', 'delta': '目前没有账户。'})}'
          '${event({
            'type': 'response.completed',
            'response': {
              'id': 'resp-2',
              'status': 'completed',
              'output': [output('目前没有账户。')],
              'usage': {'input_tokens': 12, 'output_tokens': 8},
            },
          })}',
        );
      }),
    );
    await ai.send('分析账户');
    expect(ai.error, null);
    expect(store.data.chats.last['responseItems'].length, 4);
    expect(store.data.chats.last['blocks'].first['text'], '读取账户');
    expect(store.data.chats.last['usage'].single['output_tokens'], 8);
    await ai.send('继续');
    expect(ai.error, null);
  });

  test(
    'nonstream Responses supports refusal, reasoning, usage and image schema',
    () async {
      final store = await configuredAiStore();
      await store.change(
        (d) => d.providerConfigs['custom'].addAll({
          'protocol': responsesProtocol,
          'stream': false,
          'supportsImages': true,
          'reasoningSummary': true,
          'reasoningEffort': 'high',
        }),
      );
      final ai = AiService(
        store,
        TestVault('secret-value'),
        clientFactory: () => MockClient((req) async {
          final body = jsonDecode(req.body);
          expect(body['stream'], false);
          expect(body['reasoning'], {'effort': 'high', 'summary': 'auto'});
          expect(body['input'].last['content'][1]['type'], 'input_image');
          return jsonResponse(
            jsonEncode({
              'id': 'r',
              'status': 'completed',
              'output': [
                {
                  'type': 'reasoning',
                  'summary': [
                    {'type': 'summary_text', 'text': '图片不清晰'},
                  ],
                },
                {
                  'type': 'message',
                  'role': 'assistant',
                  'content': [
                    {'type': 'refusal', 'refusal': '请提供清晰截图。'},
                  ],
                },
              ],
            }),
            200,
          );
        }),
      );
      final bytes = base64Decode('iVBORw0KGgo=');
      await ai.send('看图', image: AiImage(bytes, 'image/png'));
      expect(ai.error, null);
      expect(store.data.chats.last['content'], '请提供清晰截图。');
      expect(store.exportBackup(), isNot(contains(base64Encode(bytes))));
    },
  );

  test(
    'HTTP error includes provider details and request id but redacts credentials',
    () async {
      final store = await configuredAiStore();
      final ai = AiService(
        store,
        TestVault('secret-value'),
        clientFactory: () => MockClient(
          (_) async => jsonResponse(
            jsonEncode({
              'error': {
                'message': 'unsupported model secret-value',
                'code': 'model_not_found',
                'type': 'invalid_request_error',
                'param': 'model',
              },
            }),
            400,
            headers: {'x-request-id': 'req-123'},
          ),
        ),
      );
      await ai.send('你好');
      for (final value in [
        'HTTP 400',
        'model_not_found',
        'req-123',
        'param: model',
        '/chat/completions',
      ]) {
        expect(ai.error, contains(value));
      }
      expect(ai.error, isNot(contains('secret-value')));
      expect(store.exportBackup(), isNot(contains('secret-value')));
    },
  );

  test(
    'truncated stream persists text and retry replaces failed run without duplicating user',
    () async {
      final store = await configuredAiStore();
      var fail = true;
      final ai = AiService(
        store,
        TestVault('secret-value'),
        clientFactory: () => StreamingClient(
          (_) async => sse(
            fail
                ? event(chunk({'content': '部分回答'}))
                : '${event(chunk({'content': '完整回答'}, 'stop'))}data: [DONE]\n\n',
          ),
        ),
      );
      await ai.send('分析');
      expect(ai.error, contains('提前断开'));
      expect(store.data.chats.last['content'], '部分回答');
      fail = false;
      await ai.retryLast();
      expect(ai.error, null);
      expect(store.data.chats.length, 2);
      expect(store.data.chats.last['content'], '完整回答');
    },
  );

  test(
    'Responses incomplete retains streamed text and exposes incomplete reason',
    () async {
      final store = await configuredAiStore();
      await store.change(
        (d) => d.providerConfigs['custom']['protocol'] = responsesProtocol,
      );
      final ai = AiService(
        store,
        TestVault('secret-value'),
        clientFactory: () => StreamingClient(
          (_) async => sse(
            '${event({'type': 'response.output_text.delta', 'delta': '尚未完成'})}'
            '${event({
              'type': 'response.incomplete',
              'response': {
                'status': 'incomplete',
                'incomplete_details': {'reason': 'max_output_tokens'},
              },
            })}',
          ),
        ),
      );
      await ai.send('分析');
      expect(ai.error, contains('max_output_tokens'));
      expect(store.data.chats.last['content'], '尚未完成');
    },
  );

  test('idle stream timeout is visible and keeps partial output', () async {
    final store = await configuredAiStore();
    final stream = StreamController<List<int>>();
    final ai = AiService(
      store,
      TestVault('secret-value'),
      requestTimeout: const Duration(milliseconds: 100),
      clientFactory: () => StreamingClient(
        (_) async => http.StreamedResponse(
          stream.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ),
    );
    stream.add(utf8.encode(event(chunk({'content': '已收到'}))));
    await ai.send('你好');
    expect(ai.error, contains('超时'));
    expect(store.data.chats.last['content'], '已收到');
    await stream.close();
  });

  test(
    'invalid tool arguments are visible and returned to model without mutation',
    () async {
      final store = await configuredAiStore();
      var round = 0;
      final ai = AiService(
        store,
        TestVault('secret-value'),
        clientFactory: () => MockClient((req) async {
          if (round++ == 0) {
            return jsonResponse(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'tool_calls': [
                        {
                          'id': 'a',
                          'function': {
                            'name': 'propose_budget',
                            'arguments': '{bad json',
                          },
                        },
                      ],
                    },
                  },
                ],
              }),
              200,
            );
          }
          expect(
            jsonDecode(req.body)['messages'].last['content'],
            contains('error'),
          );
          return jsonResponse(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '请重新说明预算。'},
                },
              ],
            }),
            200,
          );
        }),
      );
      await ai.send('预算');
      expect(ai.error, null);
      expect(store.data.chats.last['blocks'].first['status'], 'error');
      expect(ai.actions.items, isEmpty);
    },
  );

  test(
    'memory deduplication, correction, deletion and legacy recall preserve fields',
    () async {
      final store = await configuredAiStore();
      await store.change(
        (d) => d.agent['memories'] = [
          {
            'id': 'old',
            'description': '每月15号发工资',
            'importance': 'core',
            'legacy': true,
          },
        ],
      );
      final ai = AiService(
        store,
        TestVault('secret-value'),
        clientFactory: () => MockClient((req) async {
          expect(
            jsonDecode(req.body)['messages'].first['content'],
            contains('每月20号发工资'),
          );
          return jsonResponse(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '工资日已纳入计划'},
                },
              ],
            }),
            200,
          );
        }),
      );
      final duplicate = await ai.memory.save({'fact': '每月 15号发工资'});
      expect(duplicate['deduplicated'], true);
      expect(store.data.agent['memories'].length, 1);
      await ai.memory.save({'id': 'old', 'fact': '每月20号发工资'}, update: true);
      expect(store.data.agent['memories'].single['legacy'], true);
      await ai.send('如何安排工资？');
      expect(ai.error, null);
      await ai.memory.forget('old');
      expect(store.data.agent['memories'], isEmpty);
    },
  );
}
