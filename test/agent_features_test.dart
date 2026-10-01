import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/domain/models.dart';
import 'helpers.dart';

http.Response response(Json message) => http.Response(
  jsonEncode({
    'choices': [
      {'message': message},
    ],
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
AiImage sampleImage() =>
    AiImage(Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]), 'image/png');

class DelayedVault implements KeyVault {
  final started = Completer<String>();
  final key = Completer<String?>();
  @override
  Future<String?> read(String provider) {
    started.complete(provider);
    return key.future;
  }

  @override
  Future<void> write(String provider, String value) async {}
}

void main() {
  test(
    'analysis cache expires when endpoint or proposal state changes',
    () async {
      final store = await configuredAiStore();
      var calls = 0;
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient((_) async {
          calls++;
          return response({'content': '回答 $calls'});
        }),
      );
      final range = DateRange(DateTime(2026, 10), DateTime(2026, 11));
      await ai.send('分析', analysisRange: range);
      await ai.send('分析', analysisRange: range);
      expect(calls, 1);
      await store.change(
        (d) => d.providerConfigs['custom'] = {
          ...d.providerConfigs['custom'],
          'baseURL': 'https://another.example/v1',
        },
      );
      await ai.send('分析', analysisRange: range);
      expect(calls, 2);
      await ai.actions.propose('budget', {'amountCents': 50000});
      await ai.send('分析', analysisRange: range);
      expect(calls, 3);
    },
  );

  test(
    'settings changed during key loading cannot receive the old provider key',
    () async {
      final store = await configuredAiStore(), vault = DelayedVault();
      final ai = AiService(
        store,
        vault,
        clientFactory: () => MockClient((request) async {
          expect(request.url.host, 'example.com');
          expect(jsonDecode(request.body)['model'], 'test-model');
          expect(request.headers['Authorization'], 'Bearer original-key');
          return response({'content': '回答'});
        }),
      );
      final sending = ai.send('分析');
      expect(await vault.started.future, 'custom');
      await store.change((d) {
        d.settings['provider'] = 'custom';
        d.providerConfigs['custom'] = {
          'baseURL': 'https://example.com/v1',
          'model': 'other',
        };
      });
      vault.key.complete('original-key');
      await sending;
      expect(ai.error, null);
    },
  );

  test(
    'query rejects overflow dates and image errors explain model compatibility',
    () async {
      final store = await configuredAiStore();
      await store.change(
        (d) => d.providerConfigs['custom'] = {
          ...d.providerConfigs['custom'],
          'supportsImages': true,
        },
      );
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient((_) async => http.Response('', 400)),
      );
      await expectLater(
        ai.executeTool('query_tx', {'start_date': '2026-09-31'}),
        throwsFormatException,
      );
      await ai.send('识别图片', image: sampleImage());
      expect(ai.error, contains('图片与工具调用'));
    },
  );

  test(
    'account settings and paginated totals use real IDs and full matching data',
    () async {
      final store = await configuredAiStore();
      await store.saveAccount(credit);
      await store.saveAccount(bank);
      await store.change(
        (d) => d.transactions.addAll(
          List.generate(205, (i) => tx(id: '$i', amount: 100)),
        ),
      );
      final ai = AiService(store, TestVault());
      final result = await ai.executeTool('query_tx', {
        'start_date': '2026-10-01',
        'end_date': '2026-10-02',
        'account_id': 'bank',
        'offset': 200,
        'limit': 10,
      });
      expect(result['count'], 205);
      expect(result['expense'], 205);
      expect(result['transactions'].length, 5);
      expect(result['categoryTotalsCents']['expense:餐饮'], 20500);
      expect(result['nextOffset'], null);
      final overview = await ai.executeTool('get_accounts_overview', {});
      expect(overview['accounts'].first['id'], 'credit');
      expect(overview['accounts'].first['creditLimitCents'], 100000);
      expect(overview['accounts'].first.containsKey('billingDay'), true);
      await expectLater(
        ai.executeTool('query_tx', {'offset': -1}),
        throwsFormatException,
      );
    },
  );

  test(
    'multimodal request sends selected image but never persists its bytes',
    () async {
      final store = await configuredAiStore();
      await store.change(
        (d) => d.providerConfigs['custom'] = {
          ...d.providerConfigs['custom'],
          'supportsImages': true,
        },
      );
      final image = sampleImage();
      var round = 0;
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient((req) async {
          final messages = jsonDecode(req.body)['messages'] as List;
          if (round++ == 0) {
            expect(
              messages.last['content'][1]['image_url']['url'],
              startsWith('data:image/png;base64,'),
            );
          } else {
            expect(jsonEncode(messages), isNot(contains('data:image/png')));
          }
          return response({'content': '请确认截图对应的账户。'});
        }),
      );
      await ai.send('识别账户', image: image);
      expect(ai.error, null);
      expect(store.data.chats.first['hasImage'], true);
      expect(store.exportBackup(), isNot(contains(base64Encode(image.bytes))));
      await ai.send('现在只分析数据');
      expect(round, 2);
    },
  );

  test(
    'unsupported image is refused locally and missing key retry keeps attachment',
    () async {
      final store = await configuredAiStore();
      final vault = TestVault();
      var calls = 0;
      final ai = AiService(
        store,
        vault,
        clientFactory: () => MockClient((req) async {
          calls++;
          expect(
            jsonDecode(req.body)['messages'].last['content'][1]['type'],
            'image_url',
          );
          return response({'content': '已识别'});
        }),
      );
      await ai.send('图片', image: sampleImage());
      expect(ai.error, contains('图片'));
      expect(calls, 0);
      await store.change(
        (d) => d.providerConfigs['custom'] = {
          ...d.providerConfigs['custom'],
          'supportsImages': true,
        },
      );
      await ai.send('图片', image: sampleImage());
      expect(ai.error, contains('密钥'));
      vault.key = 'key';
      await ai.retryLast();
      expect(ai.error, null);
      expect(calls, 1);
    },
  );

  test('different analysis questions do not share cached replies', () async {
    final store = await configuredAiStore();
    var calls = 0;
    final ai = AiService(
      store,
      TestVault('key'),
      clientFactory: () => MockClient((_) async {
        calls++;
        return response({'content': '回答 $calls'});
      }),
    );
    final range = DateRange(DateTime(2026, 10), DateTime(2026, 11));
    await ai.send('分析餐饮', analysisRange: range);
    await ai.send('分析交通', analysisRange: range);
    expect(calls, 2);
    expect(store.data.chats.last['content'], '回答 2');
  });

  test(
    'model proposal response is pending and no execution tool is exposed',
    () async {
      final store = await configuredAiStore();
      final ai = AiService(store, TestVault());
      final proposal = await ai.executeTool('propose_budget', {
        'amountCents': 50000,
      });
      expect(proposal['requiresUserConfirmation'], true);
      expect(store.data.settings['budget'], 0);
      final status = await ai.executeTool('get_pending_actions', {});
      expect(status['actions'].single['status'], 'pending');
      expect(
        await ai.executeTool('apply', {'id': proposal['proposalId']}),
        contains('error'),
      );
      expect(
        toolDefinitions.any((t) => t['function']['name'] == 'apply'),
        false,
      );
    },
  );
}
