import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/services/chat_image_storage.dart';
import 'package:fin_dash/services/voice_bookkeeping.dart';
import 'package:fin_dash/ui/ai_pages.dart';
import 'package:fin_dash/ui/design.dart';
import 'package:fin_dash/ui/editors.dart';
import 'helpers.dart';

http.Response answer(String text) => http.Response(
  jsonEncode({
    'choices': [
      {
        'message': {'role': 'assistant', 'content': text},
        'finish_reason': 'stop',
      },
    ],
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
Json expense({String account = 'bank', int amount = 2800}) => {
  'title': '午餐',
  'type': 'expense',
  'category': '餐饮',
  'amountCents': amount,
  'accountId': account,
  'date': '2026-10-02T12:30:00',
  'question': null,
};

class ImageFailureAi extends AiService {
  final retryResponse = Completer<void>();
  bool accepted = false;
  ImageFailureAi(WalletStore store) : super(store, TestVault('key'));
  @override
  bool get lastPromptStored => accepted;
  @override
  Future<void> send(
    String prompt, {
    DateRange? analysisRange,
    bool retry = false,
    AiImage? image,
  }) async {
    final id = List.filled(64, 'a').join();
    if (image != null) await images.save(id, image.bytes);
    await store.change(
      (d) => d.chats.addAll([
        {
          'id': 'sent',
          'role': 'user',
          'content': prompt,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'imageId': id,
          'hasImage': true,
        },
        {
          'id': 'failed',
          'role': 'assistant',
          'content': '',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'status': 'error',
          'error': '模拟请求失败',
        },
      ]),
    );
    accepted = true;
    error = '模拟请求失败';
    store.setAiStatus(null);
  }

  @override
  Future<void> retryMessage(String replyId) async {
    store.setAiStatus('重试…');
    await retryResponse.future;
    await store.change(
      (d) => d.chats.last.addAll({
        'content': '图片已识别',
        'status': 'complete',
        'error': null,
      }),
    );
    error = null;
    store.setAiStatus(null);
  }
}

class ParsedVoiceAi extends AiService {
  ParsedVoiceAi(WalletStore store) : super(store, TestVault('key'));
  @override
  Future<Json> interpretVoice(
    String text, {
    String? defaultAccountId,
    Json? current,
    List<Json> history = const [],
  }) async => expense();
}

Widget featureHarness(
  WalletStore store,
  AiService ai,
  Widget page, {
  double keyboard = 0,
}) => AppScope(
  store: store,
  ai: ai,
  child: MaterialApp(
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: walletTheme(Brightness.light),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: const TextScaler.linear(1.3),
        viewInsets: EdgeInsets.only(bottom: keyboard),
      ),
      child: child!,
    ),
    home: page,
  ),
);

void main() {
  test(
    'voice books exact cents once, uses no chat context, and supports safe undo',
    () async {
      final store = await configuredAiStore();
      await store.saveAccount(bank);
      await store.change(
        (d) => d.chats.add({
          'id': 'old',
          'role': 'user',
          'content': '其他对话内容',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      var calls = 0;
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient((request) async {
          calls++;
          final body = jsonDecode(request.body);
          expect(body.containsKey('tools'), false);
          expect(jsonEncode(body), isNot(contains('其他对话内容')));
          expect(body['messages'].last['content'], '上周五用银行卡吃午餐花了二十八元');
          return answer(jsonEncode(expense()));
        }),
      );
      final voice = VoiceBookkeeping(store, ai);
      final draft = await voice.preview(
        '上周五用银行卡吃午餐花了二十八元',
        entryId: 'voice-1',
        accountId: 'bank',
      );
      expect(store.data.transactions, isEmpty);
      expect(store.balance(bank), 100000);
      final recorded = await voice.confirm(draft);
      await voice.confirm(draft);
      expect(calls, 1);
      expect(store.data.transactions.length, 1);
      expect(store.balance(bank), 97200);
      expect(store.data.chats.length, 1);
      expect(store.data.settings['quickEntryAccountId'], 'bank');
      await voice.undo(recorded);
      expect(store.data.transactions, isEmpty);
      expect(store.balance(bank), 100000);
    },
  );

  test(
    'voice refuses clarification, invalid amounts/accounts, and model-provided updates',
    () async {
      final store = await configuredAiStore();
      await store.saveAccount(bank);
      Json result = {'question': '这笔钱从哪个账户支付？'};
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () =>
            MockClient((_) async => answer(jsonEncode(result))),
      );
      final voice = VoiceBookkeeping(store, ai);
      final incomplete = await voice.preview('午餐二十八元', entryId: 'voice');
      expect(incomplete.fields['amountCents'], null);
      expect(incomplete.problem(store.data), isNotNull);
      await expectLater(voice.confirm(incomplete), throwsFormatException);
      for (final invalid in [
        expense(amount: -1),
        expense(account: 'missing'),
        {...expense(), 'date': '2026-02-31'},
      ]) {
        result = invalid;
        final draft = await voice.preview('午餐二十八元', entryId: 'voice');
        await expectLater(voice.confirm(draft), throwsFormatException);
      }
      result = {...expense(), 'id': 'existing'};
      await expectLater(
        voice.preview('午餐二十八元', entryId: 'voice'),
        throwsFormatException,
      );
      expect(store.data.transactions, isEmpty);
      expect(store.balance(bank), 100000);
    },
  );

  test(
    'voice persistence failure can retry and later modifications block undo',
    () async {
      final storage = MemoryStorage();
      final store = await emptyStore(storage);
      await store.change(
        (d) => d.providerConfigs['custom'] = {
          'baseURL': 'https://example.com/v1',
          'model': 'test',
          'protocol': chatProtocol,
        },
      );
      await store.saveAccount(bank);
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () =>
            MockClient((_) async => answer(jsonEncode(expense()))),
      );
      final voice = VoiceBookkeeping(store, ai);
      final draft = await voice.preview('午餐28元', entryId: 'voice');
      storage.failWrites = true;
      await expectLater(voice.confirm(draft), throwsStateError);
      expect(store.data.transactions, isEmpty);
      storage.failWrites = false;
      final recorded = await voice.confirm(draft);
      await store.change(
        (d) => d.transactions[0] = LedgerTx.fromJson({
          ...recorded.toJson(),
          'amountCents': 3000,
        }),
      );
      await expectLater(voice.undo(recorded), throwsFormatException);
      expect(store.data.transactions.single.amount, 3000);
    },
  );

  test(
    'new sessions isolate model context, keep history, and preserve legacy messages',
    () async {
      final store = await configuredAiStore();
      final bodies = <Json>[];
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient((r) async {
          bodies.add(Json.from(jsonDecode(r.body)));
          return answer('收到');
        }),
      );
      await ai.send('旧会话的问题');
      expect(ai.error, null);
      await ai.actions.propose('budget', {'amountCents': 30000});
      await ai.newConversation();
      final fresh = ai.activeSessionId;
      await ai.send('新的独立问题');
      expect(ai.error, null);
      expect(jsonEncode(bodies.last), isNot(contains('旧会话的问题')));
      expect(store.data.chats.length, 4);
      expect(ai.sessions.length, 2);
      expect(ai.lastPromptStored, true);
      await ai.switchConversation('legacy');
      await ai.send('继续旧会话');
      expect(ai.error, null);
      expect(jsonEncode(bodies.last), contains('旧会话的问题'));
      expect(jsonEncode(bodies.last), isNot(contains('新的独立问题')));
      await ai.switchConversation(fresh);
      final history = await ai.executeTool('get_chat_history', {
        'date': dayKey(DateTime.now()),
      });
      expect(jsonEncode(history), isNot(contains('旧会话的问题')));
      expect(ai.error, null);
      expect(ai.lastPrompt, null);
    },
  );

  test(
    'saved image supports retry after recreating the service without duplicate user messages',
    () async {
      final store = await configuredAiStore();
      await store.change(
        (d) => d.providerConfigs['custom']['supportsImages'] = true,
      );
      final images = MemoryChatImageStorage();
      final image = AiImage(
        File('assets/brand.png').readAsBytesSync(),
        'image/png',
      );
      final first = AiService(
        store,
        TestVault('key'),
        imageStorage: images,
        clientFactory: () => MockClient(
          (_) async => http.Response('{"error":{"message":"failed"}}', 500),
        ),
      );
      await first.send('识别这张图片', image: image);
      final user = store.data.chats.first;
      expect(user['imageId'], isA<String>());
      expect(await images.read(user['imageId']), image.bytes);
      expect(store.exportBackup(), isNot(contains(base64Encode(image.bytes))));
      final second = AiService(
        store,
        TestVault('key'),
        imageStorage: images,
        clientFactory: () => MockClient((request) async {
          final body = jsonDecode(request.body);
          expect(body['messages'].last['content'][0]['text'], '识别这张图片');
          expect(
            body['messages'].last['content'][1]['image_url']['url'],
            contains(base64Encode(image.bytes)),
          );
          return answer('已识别');
        }),
      );
      await second.retryMessage(store.data.chats.last['id']);
      expect(second.error, null);
      expect(store.data.chats.length, 2);
      expect(store.data.chats.last['content'], '已识别');
    },
  );

  testWidgets(
    'image failure leaves sent content out of composer, shows image, and retry preserves new draft',
    (tester) async {
      final store = await configuredAiStore();
      await store.change(
        (d) => d.providerConfigs['custom']['supportsImages'] = true,
      );
      final image = AiImage(
        File('assets/brand.png').readAsBytesSync(),
        'image/png',
      );
      final ai = ImageFailureAi(store);
      await tester.pumpWidget(
        featureHarness(store, ai, ChatPage(imagePicker: () async => image)),
      );
      await tester.tap(find.byTooltip('添加截图'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '识别图中的账户');
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
      expect(find.byTooltip('移除截图'), findsNothing);
      expect(
        find.byKey(ValueKey('chat-image:${store.data.chats.first['imageId']}')),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('重试这条消息'));
      await tester.tap(find.text('重试这条消息'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '下一条草稿');
      ai.retryResponse.complete();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '下一条草稿',
      );
      expect(store.data.chats.length, 2);
      expect(ai.error, null);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'new conversation button hides prior messages and old pending actions',
    (tester) async {
      final store = await emptyStore();
      final ai = AiService(store, TestVault());
      await store.change(
        (d) => d.chats.add({
          'id': 'old',
          'role': 'user',
          'content': '旧会话内容',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      await ai.actions.propose('budget', {'amountCents': 10000});
      await tester.pumpWidget(featureHarness(store, ai, const ChatPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('新建对话'));
      await tester.pumpAndSettle();
      expect(find.text('旧会话内容'), findsNothing);
      expect(find.text('确认执行'), findsNothing);
      expect(store.data.chats.length, 1);
      await tester.tap(find.byTooltip('历史对话'));
      await tester.pumpAndSettle();
      expect(find.text('旧会话内容'), findsOneWidget);
      await tester.tap(find.text('旧会话内容'));
      await tester.pumpAndSettle();
      expect(ai.activeSessionId, 'legacy');
      expect(find.text('确认执行'), findsOneWidget);
    },
  );

  testWidgets(
    'keypad, account and save are visible immediately and save stays above keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await emptyStore();
      await store.saveAccount(bank);
      final ai = AiService(store, TestVault());
      for (final inset in [0.0, 260.0]) {
        await tester.pumpWidget(
          featureHarness(store, ai, const TransactionEditor(), keyboard: inset),
        );
        await tester.pumpAndSettle();
        final save = find.byKey(const Key('save-transaction'));
        expect(save.hitTestable(), findsOneWidget);
        expect(tester.getRect(save).bottom, lessThanOrEqualTo(740 - inset));
        if (inset == 0) {
          expect(
            find.byKey(const ValueKey('使用账户-bank')).hitTestable(),
            findsOneWidget,
          );
          expect(find.text('1').hitTestable(), findsOneWidget);
          expect(find.text('⌫').hitTestable(), findsOneWidget);
          await tester.tap(find.text('2'));
          await tester.tap(find.text('8'));
          expect(
            tester
                .widget<TextFormField>(find.byKey(const Key('amount-input')))
                .controller!
                .text,
            '28',
          );
        }
        expect(tester.takeException(), null);
      }
    },
  );

  testWidgets(
    'voice sheet records a typed sentence and provides undo at large text sizes',
    (tester) async {
      final store = await configuredAiStore();
      await store.saveAccount(bank);
      final ai = ParsedVoiceAi(store);
      await tester.pumpWidget(
        featureHarness(store, ai, const VoiceSheetHost()),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('voice-transcript')),
        '银行卡午餐28元',
      );
      await tester.pump();
      await tester.tap(find.text('生成账单'));
      await tester.pumpAndSettle();
      expect(store.data.transactions, isEmpty);
      await tester.tap(find.text('确认保存'));
      await tester.pumpAndSettle();
      expect(store.data.transactions.single.amount, 2800);
      await tester.ensureVisible(find.text('撤销这笔账单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('撤销这笔账单'));
      await tester.pumpAndSettle();
      expect(store.data.transactions, isEmpty);
      expect(tester.takeException(), null);
    },
  );
}
