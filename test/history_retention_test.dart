import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/domain/history_retention.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'helpers.dart';

void main() {
  test(
    'compaction keeps recent replay and retry checkpoints with proposal links',
    () {
      final d = WalletData(
        chats: [
          for (var i = 0; i < 20; i++) ...[
            {'id': 'u-$i', 'role': 'user', 'content': 'hello'},
            {
              'id': 'a-$i',
              'role': 'assistant',
              'status': 'complete',
              'modelMessages': [
                {'content': 'replay'},
              ],
              'responseItems': [
                {'type': 'message'},
              ],
              'blocks': [
                  <String, dynamic>{
                  'type': 'tool',
                  'name': 'read',
                  'result': List.filled(9000, '字').join(),
                },
                {
                  'type': 'tool',
                  'name': 'propose_transaction',
                  'result': jsonEncode({'proposalId': 'proposal-$i'}),
                },
              ],
            },
          ],
        ],
      );
      d.chats[1]['status'] = 'error';
      d.chats[3]['status'] = 'cancelled';
      compactChatHistory(d);
      expect(d.chats[1].containsKey('modelMessages'), true);
      expect(d.chats[3].containsKey('responseItems'), true);
      expect(d.chats[5].containsKey('modelMessages'), false);
      expect(d.chats[5]['blocks'][0]['resultTruncated'], true);
      expect(messageProposalIds(d.chats[5]), {'proposal-2'});
      expect(d.chats[11].containsKey('modelMessages'), true);
      expect(d.chats.last.containsKey('responseItems'), true);
    },
  );
  test('retention preserves active work and caps settled histories', () {
    final d = WalletMetadata(
      extras: {
        'operationReceipts': [
          {
            'createdAt': DateTime.now()
                .subtract(const Duration(days: 31))
                .toIso8601String(),
          },
          for (var i = 0; i < 1005; i++)
            {'id': '$i', 'createdAt': DateTime.now().toIso8601String()},
        ],
        'tasks': [
          for (var i = 0; i < 205; i++) {'id': '$i', 'state': 'completed'},
          {'id': 'active', 'state': 'needsInput'},
        ],
        'agentActions': [
          for (var i = 0; i < 505; i++) {'id': '$i', 'status': 'applied'},
          {'id': 'pending', 'status': 'pending', 'batchId': 'active'},
        ],
        'agentActionBatches': [
          for (var i = 0; i < 505; i++) {'id': '$i', 'generation': 'ready'},
          {'id': 'active', 'generation': 'ready'},
        ],
      },
    );
    pruneHistory(d);
    expect((d.extras['operationReceipts'] as List).length, 1000);
    expect((d.extras['tasks'] as List).length, 201);
    expect((d.extras['agentActions'] as List).length, 501);
    expect((d.extras['agentActionBatches'] as List).length, 501);
  });
  test('new replies persist only the selected protocol replay', () async {
    for (final protocol in [chatProtocol, responsesProtocol]) {
      final store = await configuredAiStore();
      await store.changeMetadata(
        (d) => d.providerConfigs['custom']['protocol'] = protocol,
      );
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient(
          (_) async => http.Response(
            jsonEncode(
              protocol == chatProtocol
                  ? {
                      'choices': [
                        {
                          'message': {'content': 'done'},
                        },
                      ],
                    }
                  : {
                      'id': 'r',
                      'output': [
                        {
                          'type': 'message',
                          'role': 'assistant',
                          'content': [
                            {'type': 'output_text', 'text': 'done'},
                          ],
                        },
                      ],
                    },
            ),
            200,
          ),
        ),
      );
      await ai.send('hello');
      expect(ai.error, null);
      final message = store.data.chats.last;
      expect(
        message.containsKey(
          protocol == chatProtocol ? 'modelMessages' : 'responseItems',
        ),
        true,
      );
      expect(
        message.containsKey(
          protocol == chatProtocol ? 'responseItems' : 'modelMessages',
        ),
        false,
      );
    }
  });
}
