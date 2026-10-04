import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/services/voice_bookkeeping.dart';
import 'package:fin_dash/services/voice_input.dart';
import 'package:fin_dash/services/voice_widget_runtime.dart';
import 'package:fin_dash/ui/voice_entry_sheet.dart';
import 'helpers.dart';
import 'voice_and_sessions_test.dart' show answer, expense, featureHarness;
import 'voice_widget_runtime_test.dart' show widgetRequest;

const boc = WalletAccount(
  id: 'boc',
  name: '中国银行',
  category: 'funds',
  subType: 'bank_card',
  openingBalance: 100000,
);

const cmb = WalletAccount(
  id: 'cmb',
  name: '招商银行',
  category: 'funds',
  subType: 'bank_card',
  openingBalance: 100000,
);

const twoBillTranscript = '今天中午吃饭花了18块钱，以及对咖啡生杯花了3块钱，都是用的中国银行。';
Json twoBills() => {
  'entries': [
    {...expense(account: 'boc', amount: 1800), 'title': '午饭'},
    {...expense(account: 'boc', amount: 300), 'title': '咖啡'},
  ],
};

class FailedAi extends AiService {
  int calls = 0;
  FailedAi(WalletStore store) : super(store, TestVault());
  @override
  Future<Json> interpretVoice(
    String text, {
    String? defaultAccountId,
    Json? current,
    List<Json> history = const [],
  }) async {
    calls++;
    throw const FormatException('网络不可用');
  }
}

class SuccessfulAi extends AiService {
  int calls = 0;
  String? account;
  Json? current;
  List<Json> history = const [];
  final texts = <String>[];
  Json result = {
    'title': '蜜雪冰城',
    'type': 'expense',
    'amountCents': 1000,
    'accountId': 'boc',
    'category': '餐饮',
    'date': '2026-10-02T12:30:00',
  };
  SuccessfulAi(WalletStore store) : super(store, TestVault());
  @override
  Future<Json> interpretVoice(
    String text, {
    String? defaultAccountId,
    Json? current,
    List<Json> history = const [],
  }) async {
    calls++;
    account = defaultAccountId;
    this.current = current;
    this.history = history;
    texts.add(text);
    return result;
  }
}

class ControlledVoice extends VoiceInput {
  int starts = 0, stops = 0, cancels = 0;
  String spoken = '蜜雪冰城十块钱中国银行';
  Completer<String?>? result;
  void Function(String)? partial, state;
  void Function(double)? level;
  @override
  Future<String?> listen({
    void Function(String)? onPartial,
    void Function(String)? onState,
    void Function(double)? onLevel,
  }) {
    starts++;
    partial = onPartial;
    state = onState;
    level = onLevel;
    result = Completer<String?>();
    onState?.call('listening');
    return result!.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    state?.call('recognizing');
    result!.complete(spoken);
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (result != null && !result!.isCompleted) result!.complete(null);
  }
}

Future<void> openSheet(
  WidgetTester tester,
  WalletStore store,
  AiService ai,
  VoiceInput voice, {
  double keyboard = 0,
}) async {
  await tester.pumpWidget(
    featureHarness(store, ai, VoiceSheetHost(voice: voice), keyboard: keyboard),
  );
  await tester.pumpAndSettle();
}

Future<void> speak(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('voice-microphone')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('voice-microphone')));
  await tester.pumpAndSettle();
}

void main() {
  test(
    'multi-bill JSON preserves both amounts from the screenshot and the shared account',
    () async {
      final store = await configuredAiStore();
      await store.saveAccount(boc);
      String? prompt;
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          prompt = (body['messages'] as List).first['content'] as String;
          final reply = twoBills();
          (reply['entries'] as List)[0]['amountCents'] = '1800';
          (reply['entries'] as List)[1]['amountCents'] = 300.0;
          return answer(jsonEncode(reply));
        }),
      );
      final batch = await VoiceBookkeeping(
        store,
        ai,
      ).previewBatch(twoBillTranscript, entryId: 'screenshot');
      expect(batch.entries.map((e) => e.fields['amountCents']), [1800, 300]);
      expect(batch.entries.map((e) => e.fields['accountId']), ['boc', 'boc']);
      expect(batch.problem(store.data), null);
      expect(store.data.transactions, isEmpty);
      expect(prompt, contains('先按用途区分交易'));
      expect(prompt, contains('合计21'));
      expect(prompt, isNot(contains('一次只处理一笔')));
    },
  );

  test(
    'multi-bill confirmation is atomic, retryable and idempotent; undo removes both',
    () async {
      final storage = MemoryStorage();
      final store = await emptyStore(storage);
      await store.saveAccount(boc);
      final ai = SuccessfulAi(store)..result = twoBills();
      final service = VoiceBookkeeping(store, ai);
      final batch = await service.previewBatch(
        twoBillTranscript,
        entryId: 'atomic',
      );
      final incomplete = batch.update(
        batch.entries.last.update({'amountCents': null}),
      );
      await expectLater(
        service.confirmBatch(incomplete),
        throwsFormatException,
      );
      expect(store.data.transactions, isEmpty);
      final before = storage.content;
      storage.failWrites = true;
      await expectLater(service.confirmBatch(batch), throwsStateError);
      expect(store.data.transactions, isEmpty);
      expect(store.balance(boc), 100000);
      expect(storage.content, before);
      expect(
        (store.data.extras['voiceDrafts'] as Map).containsKey('atomic'),
        true,
      );
      storage.failWrites = false;
      final saved = await Future.wait([
        service.confirmBatch(batch),
        service.confirmBatch(batch),
      ]);
      expect(store.data.transactions.map((e) => e.amount), [1800, 300]);
      expect(store.balance(boc), 97900);
      expect((store.data.extras['sourceReceipts'] as List).length, 2);
      expect(
        (store.data.extras['voiceDrafts'] as Map).containsKey('atomic'),
        false,
      );
      await service.undoBatch(saved.first);
      expect(store.data.transactions, isEmpty);
      expect(store.balance(boc), 100000);
    },
  );

  test(
    'a correction repairs one incomplete bill and rejects dropping the other bill',
    () async {
      final store = await emptyStore();
      await store.saveAccount(boc);
      final reply = twoBills();
      (reply['entries'] as List)[1]['amountCents'] = null;
      (reply['entries'] as List)[1]['question'] = '请补充金额';
      final ai = SuccessfulAi(store)..result = reply;
      final service = VoiceBookkeeping(store, ai);
      final base = await service.previewBatch(
        '午饭18元，咖啡忘了多少钱，都是中国银行',
        entryId: 'pair',
      );
      expect(base.entries.first.missing(store.data), isEmpty);
      expect(base.entries.last.missing(store.data), ['amountCents']);
      ai.result = {
        'entries': [
          {'entryId': 'pair'},
          {'entryId': 'pair:2', 'amountCents': 300},
        ],
      };
      final corrected = await service.previewBatch(
        '咖啡3块钱',
        entryId: 'pair',
        base: base,
        selectedEntryId: 'pair:2',
      );
      expect(ai.current?['selectedEntryId'], 'pair:2');
      expect(corrected.entries.map((e) => e.fields['amountCents']), [
        1800,
        300,
      ]);
      expect(corrected.entries.map((e) => e.fields['title']), ['午饭', '咖啡']);
      expect(corrected.problem(store.data), null);
      ai.result = expense(account: 'boc', amount: 300);
      await expectLater(
        service.previewBatch('改成五块', entryId: 'pair', base: corrected),
        throwsFormatException,
      );
      final stored = (store.data.extras['voiceDrafts'] as Map)['pair'] as Map;
      final retained = VoiceBatch.fromJson(Json.from(stored['draft'] as Map));
      expect(retained.entries.map((e) => e.fields['amountCents']), [1800, 300]);
      expect(store.data.transactions, isEmpty);
    },
  );

  test(
    'widget reviews, confirms and undoes both bills without dropping an amount',
    () async {
      final store = await emptyStore();
      await store.saveAccount(boc);
      final ai = SuccessfulAi(store)..result = twoBills();
      VoiceWidgetRuntime.install(store, ai, () {});
      addTearDown(() => VoiceWidgetRuntime.channel.setMethodCallHandler(null));
      final review = await widgetRequest({
        'operation': 'preview',
        'text': twoBillTranscript,
        'entryId': 'widget-pair',
      });
      expect(review['canConfirm'], true);
      expect(review['summary'], contains('18.00'));
      expect(review['summary'], contains('3.00'));
      final confirmation = {
        'operation': 'confirm',
        'draft': jsonEncode(review['draft']),
      };
      final saved = await widgetRequest(confirmation);
      expect(saved['success'], true);
      await widgetRequest(confirmation);
      expect(store.data.transactions.length, 2);
      expect(store.balance(boc), 97900);
      final undone = await widgetRequest({
        'operation': 'undo',
        'transaction': jsonEncode(saved['transaction']),
      });
      expect(undone['undone'], true);
      expect(store.data.transactions, isEmpty);
      ai.result = {
        'entries': [...twoBills()['entries'] as List, expense(account: 'boc')],
      };
      final larger = await widgetRequest({
        'operation': 'preview',
        'text': '午饭18、咖啡3，还有晚饭28',
        'entryId': 'larger',
      });
      expect(larger['canConfirm'], false);
      expect(larger['message'], contains('App 任务页'));
      final blocked = await widgetRequest({
        'operation': 'confirm',
        'draft': jsonEncode(larger['draft']),
      });
      expect(blocked['success'], false);
      expect(store.data.transactions, isEmpty);
    },
  );

  testWidgets(
    'opening a retained multi-bill draft restores both entries without an AI request',
    (tester) async {
      final store = await emptyStore();
      await store.saveAccount(boc);
      final ai = SuccessfulAi(store)..result = twoBills();
      await VoiceBookkeeping(
        store,
        ai,
      ).previewBatch(twoBillTranscript, entryId: 'resume');
      await tester.pumpWidget(
        featureHarness(
          store,
          ai,
          Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showVoiceEntry(
                    context,
                    entryId: 'resume',
                    initialText: twoBillTranscript,
                  ),
                  child: const Text('恢复草稿'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复草稿'));
      await tester.pumpAndSettle();
      expect(find.text('识别出 2 笔，请逐笔核对'), findsOneWidget);
      expect(find.textContaining('18.00'), findsWidgets);
      expect(find.textContaining('3.00'), findsWidgets);
      expect(ai.calls, 1);
      expect(store.data.transactions, isEmpty);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'sheet shows both amounts, edits and corrects the second bill, saves and undoes both',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await emptyStore();
      await store.saveAccount(boc);
      final ai = SuccessfulAi(store)..result = twoBills();
      final voice = ControlledVoice()..spoken = twoBillTranscript;
      await openSheet(tester, store, ai, voice);
      await speak(tester);
      expect(find.text('识别出 2 笔，请逐笔核对'), findsOneWidget);
      expect(find.textContaining('18.00'), findsWidgets);
      expect(find.textContaining('3.00'), findsWidgets);
      expect(store.data.transactions, isEmpty);
      final second = find.byKey(const ValueKey('voice-entry-1'));
      await tester.ensureVisible(second);
      await tester.tap(second);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('voice-draft-amount')));
      await tester.enterText(
        find.byKey(const Key('voice-draft-amount')),
        '3.50',
      );
      await tester.pump();
      // Positional replies remain compatible, while the request names the selected bill.
      ai.result = {
        'entries': [
          {},
          {'amountCents': 500},
        ],
      };
      voice.spoken = '金额改成五块';
      await speak(tester);
      expect(ai.current?['selectedEntryId'], endsWith(':2'));
      expect((ai.current?['entries'] as List).last['amountCents'], 350);
      await tester.tap(find.text('确认保存 2 笔'));
      await tester.pumpAndSettle();
      expect(store.data.transactions.map((e) => e.amount), [1800, 500]);
      final undo = find.text('撤销这 2 笔账单');
      await tester.ensureVisible(undo);
      await tester.tap(undo);
      await tester.pumpAndSettle();
      expect(store.data.transactions, isEmpty);
      expect(tester.takeException(), null);
    },
  );

  test(
    'simple sentences always use AI and write only after confirmation',
    () async {
      final store = await emptyStore();
      await store.saveAccount(boc);
      final ai = SuccessfulAi(store);
      final service = VoiceBookkeeping(store, ai);
      final draft = await service.preview('蜜雪冰城十块钱中国银行', entryId: 'example');
      expect(ai.calls, 1);
      expect(draft.fields, containsPair('title', '蜜雪冰城'));
      expect(draft.fields, containsPair('amountCents', 1000));
      expect(draft.fields, containsPair('accountId', 'boc'));
      expect(draft.fields, containsPair('category', '餐饮'));
      expect(draft.fields, containsPair('type', 'expense'));
      expect(store.balance(boc), 100000);
      await Future.wait([service.confirm(draft), service.confirm(draft)]);
      expect(store.data.transactions.length, 1);
      expect(store.balance(boc), 99000);
    },
  );

  test(
    'AI missing fields stay empty without rule guesses or default merging',
    () async {
      final store = await emptyStore();
      await store.saveAccount(boc);
      final ai = SuccessfulAi(store);
      ai.result = {
        'question': '请补充金额',
        'missingFields': ['amountCents'],
      };
      final draft = await VoiceBookkeeping(
        store,
        ai,
      ).preview('奶茶10元中国银行', entryId: 'missing', accountId: 'boc');
      expect(ai.calls, 1);
      expect(ai.account, 'boc');
      expect(draft.fields, isEmpty);
      expect(draft.message, '请补充金额');
      expect(draft.problem(store.data), isNotNull);
      expect(store.data.transactions, isEmpty);
    },
  );

  test('AI failures never produce a rule-generated bill', () async {
    final store = await emptyStore();
    await store.saveAccount(boc);
    final ai = FailedAi(store);
    await expectLater(
      VoiceBookkeeping(store, ai).preview('蜜雪冰城十块钱中国银行', entryId: 'failed'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('已保留'),
        ),
      ),
    );
    expect(ai.calls, 1);
    expect(store.data.transactions, isEmpty);
  });

  test('locked and archived accounts cannot confirm an AI draft', () async {
    final store = await emptyStore();
    await store.saveAccount(boc);
    final ai = SuccessfulAi(store);
    final service = VoiceBookkeeping(store, ai);
    final filled = await service.preview('蜜雪冰城十块钱中国银行', entryId: 'partial');
    await store.change((d) => d.settings['locked'] = true);
    await expectLater(service.confirm(filled), throwsFormatException);
    await store.setLocked(false);
    await store.change((d) {
      d.accounts[0] = boc.copyWith(archived: true);
    });
    await expectLater(service.confirm(filled), throwsFormatException);
    expect(store.data.transactions, isEmpty);
  });

  test(
    'a spoken correction sends the draft under review and keeps settled fields',
    () async {
      final store = await emptyStore();
      await store.saveAccount(boc);
      final ai = SuccessfulAi(store);
      final service = VoiceBookkeeping(store, ai);
      ai.result = {
        ...ai.result,
        'assumed': ['accountId', 'category', 'unknown'],
      };
      final first = await service.preview('蜜雪冰城十块钱', entryId: 'entry');
      expect(first.assumed, {'accountId', 'category'});
      expect(first.fields.containsKey('assumed'), false);
      // Editing a guessed field confirms it.
      final edited = first.update({'category': '餐饮'});
      expect(edited.assumed, {'accountId'});
      ai.result = {...ai.result, 'amountCents': 1500};
      final corrected = await service.preview(
        '金额是十五',
        entryId: 'entry',
        base: edited,
      );
      expect(ai.texts.last, '金额是十五');
      expect(ai.current, edited.fields);
      expect(corrected.fields['amountCents'], 1500);
      expect(corrected.transcript, '蜜雪冰城十块钱；补充：金额是十五');
      // The AI still lists category, but the user settled it and it did not move.
      expect(corrected.assumed, {'accountId'});
      final drafts = store.data.extras['voiceDrafts'] as Map;
      expect(drafts.keys, ['entry']);
      expect(drafts['entry']['text'], corrected.transcript);
    },
  );

  test(
    'similar confirmed bills correct misheard merchants without amounts',
    () async {
      final store = await emptyStore();
      await store.saveAccount(boc);
      await store.saveAccount(
        WalletAccount.fromJson({
          ...cmb.toJson(),
          'id': 'old',
          'name': '旧卡',
          'archived': true,
        }),
      );
      LedgerTx bill(String id, String title, String account, int day) =>
          LedgerTx(
            id: id,
            title: title,
            amount: 1000 + day,
            date: DateTime(2026, 9, day),
            type: TxType.expense,
            category: '餐饮',
            accountId: account,
            note: '私人备注',
          );
      await store.change(
        (d) => d.transactions.addAll([
          bill('a', '蜜雪冰城', 'boc', 1),
          bill('b', '蜜雪冰城', 'boc', 2),
          bill('c', '冰城串吧', 'old', 3),
          bill('d', '房租', 'boc', 4),
        ]),
      );
      final hints = VoiceBookkeeping.similarBills(store.data, '米雪冰城十块钱');
      expect(hints, [
        {
          'title': '蜜雪冰城',
          'type': 'expense',
          'category': '餐饮',
          'accountId': 'boc',
        },
        // Archived accounts are not offered back to the model.
        {
          'title': '冰城串吧',
          'type': 'expense',
          'category': '餐饮',
          'accountId': null,
        },
      ]);
      expect(jsonEncode(hints), isNot(contains('私人备注')));
      expect(VoiceBookkeeping.similarBills(store.data, '加油'), isEmpty);
      final ai = SuccessfulAi(store);
      await VoiceBookkeeping(store, ai).preview('米雪冰城十块钱', entryId: 'e');
      expect(ai.history, hints);
    },
  );

  test('missing lists the fields that block saving in fixing order', () async {
    final store = await emptyStore();
    await store.saveAccount(boc);
    expect(
      VoiceDraft('x', {
        'type': 'expense',
        'title': ' ',
        'amountCents': 0,
        'accountId': 'nope',
        'category': '不存在',
      }).missing(store.data),
      ['amountCents', 'title', 'accountId', 'category'],
    );
    expect(
      VoiceDraft('x', {
        'type': 'transfer',
        'title': '还款',
        'amountCents': 100,
        'transferFromId': 'boc',
        'transferToId': 'boc',
      }).missing(store.data),
      ['transferToId'],
    );
    expect(VoiceDraft('x', {}).missing(store.data).first, 'type');
  });

  test(
    'voice prompt explains recognition errors and carries hints and the draft',
    () async {
      final store = await configuredAiStore();
      await store.saveAccount(bank);
      final systems = <String>[];
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient((request) async {
          final messages =
              (jsonDecode(request.body) as Map)['messages'] as List;
          systems.add(messages.first['content'] as String);
          return answer(jsonEncode(expense()));
        }),
      );
      await ai.interpretVoice('午餐二十八');
      await ai.interpretVoice(
        '金额是三十',
        current: {'title': '午餐', 'amountCents': 2800},
        history: [
          {
            'title': '午餐',
            'type': 'expense',
            'category': '餐饮',
            'accountId': 'bank',
          },
        ],
      );
      expect(systems.first, contains('同音字'));
      expect(systems.first, contains('assumed'));
      expect(systems.first, isNot(contains('相似账单')));
      expect(systems.first, isNot(contains('当前草稿')));
      expect(systems.last, contains('相似账单'));
      expect(systems.last, contains('"accountId":"bank"'));
      expect(systems.last, contains('当前草稿：{"title":"午餐","amountCents":2800}'));
    },
  );

  test(
    'widget lets the user choose an AI-reported ambiguous account',
    () async {
      final store = await emptyStore();
      await store.saveAccount(
        WalletAccount.fromJson({...boc.toJson(), 'name': '中国银行储蓄卡'}),
      );
      await store.saveAccount(
        WalletAccount.fromJson({
          ...boc.toJson(),
          'id': 'boc2',
          'name': '中国银行信用卡',
        }),
      );
      final ai = SuccessfulAi(store);
      ai.result = {...ai.result, 'accountId': null};
      VoiceWidgetRuntime.install(
        store,
        ai,
        () => fail('Widget must stay on desktop'),
      );
      addTearDown(() => VoiceWidgetRuntime.channel.setMethodCallHandler(null));
      final preview = await widgetRequest({
        'operation': 'preview',
        'entryId': 'widget',
        'text': '蜜雪冰城十块钱中国银行',
      });
      expect(preview['canConfirm'], false);
      expect(preview['summary'], contains('10.00'));
      expect(store.data.transactions, isEmpty);
      final selected = await widgetRequest({
        'operation': 'account',
        'draft': jsonEncode(preview['draft']),
      });
      expect(selected['canConfirm'], true);
      expect(store.data.transactions, isEmpty);
      final saved = await widgetRequest({
        'operation': 'confirm',
        'draft': jsonEncode(selected['draft']),
      });
      expect(saved['success'], true);
      expect(store.data.transactions.single.amount, 1000);
      expect(ai.calls, 1);
    },
  );

  test(
    'widget corrections amend the reviewed draft under its original entry',
    () async {
      final store = await emptyStore();
      await store.saveAccount(boc);
      await store.saveAccount(cmb);
      final ai = SuccessfulAi(store);
      ai.result = {...ai.result, 'accountId': null};
      VoiceWidgetRuntime.install(
        store,
        ai,
        () => fail('Widget must stay on desktop'),
      );
      addTearDown(() => VoiceWidgetRuntime.channel.setMethodCallHandler(null));
      final preview = await widgetRequest({
        'operation': 'preview',
        'entryId': 'widget',
        'text': '蜜雪冰城十块钱',
      });
      expect(preview['text'], '蜜雪冰城十块钱');
      expect(preview['message'], '点账单选择付款账户');
      ai.result = {...ai.result, 'accountId': 'cmb'};
      final corrected = await widgetRequest({
        'operation': 'preview',
        'entryId': 'unused',
        'text': '招商银行',
        'previous': '蜜雪冰城十块钱',
        'draft': jsonEncode(preview['draft']),
      });
      expect(ai.texts.last, '招商银行');
      expect(ai.current, containsPair('accountId', null));
      expect(corrected['text'], '蜜雪冰城十块钱；补充：招商银行');
      expect(corrected['canConfirm'], true);
      expect((corrected['draft'] as Map)['entryId'], 'widget');
      expect((store.data.extras['voiceDrafts'] as Map).keys, ['widget']);
    },
  );

  testWidgets(
    'sheet does not auto-start, stop generates review, and bottom confirmation saves edited cents',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await emptyStore();
      await store.saveAccount(boc);
      final voice = ControlledVoice();
      await openSheet(tester, store, SuccessfulAi(store), voice);
      expect(voice.starts, 0);
      expect(
        tester.getCenter(find.byKey(const Key('voice-microphone'))).dy,
        greaterThan(650),
      );
      await tester.tap(find.byKey(const Key('voice-microphone')));
      await tester.pump();
      expect(voice.starts, 1);
      expect(find.text('结束说话'), findsOneWidget);
      await tester.pump(const Duration(seconds: 40));
      expect(voice.stops, 0);
      expect(voice.result!.isCompleted, false);
      expect(store.data.transactions, isEmpty);
      voice.partial?.call('蜜雪冰城十块钱中国银行');
      await tester.pump();
      await tester.tap(find.byKey(const Key('voice-microphone')));
      await tester.pumpAndSettle();
      expect(voice.stops, 1);
      expect(find.text('待确认账单'), findsOneWidget);
      expect(store.data.transactions, isEmpty);
      await tester.ensureVisible(find.byKey(const Key('voice-draft-amount')));
      await tester.enterText(
        find.byKey(const Key('voice-draft-amount')),
        '12.35',
      );
      await tester.pump();
      await tester.tap(find.text('确认保存'));
      await tester.pumpAndSettle();
      expect(store.data.transactions.single.amount, 1235);
      expect(find.text('已记账'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.text('语音记账'), findsNothing);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'AI failure preserves the local transcript and retries through AI',
    (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await emptyStore();
      await store.saveAccount(boc);
      final voice = ControlledVoice();
      final ai = FailedAi(store);
      await openSheet(tester, store, ai, voice, keyboard: 260);
      await tester.tap(find.text('开始说话'));
      await tester.pump();
      voice.partial?.call('蜜雪冰城十块钱中国银行');
      voice.result!.complete('蜜雪冰城十块钱中国银行');
      await tester.pumpAndSettle();
      expect(find.text('蜜雪冰城十块钱中国银行'), findsOneWidget);
      final button = find.byKey(const Key('voice-confirm'));
      expect(tester.getBottomLeft(button).dy, lessThanOrEqualTo(520));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('待确认账单'), findsNothing);
      expect(ai.calls, 2);
      expect(find.textContaining('请重试 AI 解析'), findsOneWidget);
      expect(find.text('蜜雪冰城十块钱中国银行'), findsOneWidget);
      expect(store.data.transactions, isEmpty);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'leaving the sheet cancels the microphone and cannot save late results',
    (tester) async {
      final store = await emptyStore();
      await store.saveAccount(boc);
      final voice = ControlledVoice();
      await openSheet(tester, store, SuccessfulAi(store), voice);
      await tester.tap(find.text('开始说话'));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      expect(voice.cancels, 1);
      expect(store.data.transactions, isEmpty);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'a spoken correction keeps the receipt, changes one field and one entry',
    (tester) async {
      final store = await emptyStore();
      await store.saveAccount(boc);
      await store.saveAccount(cmb);
      final ai = SuccessfulAi(store);
      final voice = ControlledVoice();
      await openSheet(tester, store, ai, voice);
      await speak(tester);
      expect(find.text('中国银行'), findsOneWidget);
      ai.result = {...ai.result, 'accountId': 'cmb'};
      voice.spoken = '改成招商银行';
      await tester.tap(find.byKey(const Key('voice-microphone')));
      await tester.pump();
      expect(voice.starts, 2);
      // The receipt stays visible while the correction is recorded.
      expect(find.text('待确认账单'), findsOneWidget);
      expect(find.textContaining('正在录音 · 说出要修改'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-microphone')));
      await tester.pumpAndSettle();
      expect(ai.texts.last, '改成招商银行');
      expect(ai.current, containsPair('accountId', 'boc'));
      expect(find.text('招商银行'), findsOneWidget);
      expect(find.text('蜜雪冰城十块钱中国银行；补充：改成招商银行'), findsOneWidget);
      await tester.tap(find.text('确认保存'));
      await tester.pumpAndSettle();
      expect(store.data.transactions.single.accountId, 'cmb');
      expect(store.data.extras['voiceDrafts'], isEmpty);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'a missing account opens its picker from the main button and guesses are tagged',
    (tester) async {
      final store = await emptyStore();
      await store.saveAccount(boc);
      await store.saveAccount(cmb);
      final ai = SuccessfulAi(store);
      ai.result = {
        ...ai.result,
        'accountId': null,
        'assumed': ['category'],
        'missingFields': ['accountId'],
        'question': '请选择付款账户',
      };
      await openSheet(tester, store, ai, ControlledVoice());
      await tester.enterText(find.byKey(const Key('voice-transcript')), '奶茶十块');
      await tester.pumpAndSettle();
      await tester.tap(find.text('生成账单'));
      await tester.pumpAndSettle();
      expect(find.text('补全后即可确认'), findsOneWidget);
      expect(find.text('推测'), findsOneWidget);
      expect(find.byKey(const Key('voice-confirm')), findsNothing);
      await tester.tap(find.byKey(const Key('voice-fix')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('招商银行'));
      await tester.pumpAndSettle();
      expect(find.text('待确认账单'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-confirm')));
      await tester.pumpAndSettle();
      expect(store.data.transactions.single.accountId, 'cmb');
      expect(tester.takeException(), null);
    },
  );

  testWidgets('another bill after saving gets its own entry', (tester) async {
    final store = await emptyStore();
    await store.saveAccount(boc);
    final ai = SuccessfulAi(store);
    final voice = ControlledVoice();
    await openSheet(tester, store, ai, voice);
    await speak(tester);
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(find.text('已记账'), findsOneWidget);
    // "再记一笔" starts a fresh bill instead of reusing the saved entry.
    await speak(tester);
    expect(find.text('已记账'), findsNothing);
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(store.data.transactions.length, 2);
    expect(find.textContaining('已经保存'), findsNothing);
    expect(tester.takeException(), null);
  });

  testWidgets(
    'the recording meter shows time and hints at a silent microphone',
    (tester) async {
      final store = await emptyStore();
      await store.saveAccount(boc);
      final voice = ControlledVoice();
      await openSheet(tester, store, SuccessfulAi(store), voice);
      await tester.tap(find.byKey(const Key('voice-microphone')));
      await tester.pump();
      for (var i = 0; i < 30; i++) {
        voice.level!(.05);
      }
      await tester.pump();
      expect(find.text('0:03'), findsOneWidget);
      expect(find.text('还没有听到声音，请靠近麦克风说话'), findsOneWidget);
      voice.level!(.8);
      await tester.pump();
      expect(find.text('还没有听到声音，请靠近麦克风说话'), findsNothing);
      expect(tester.takeException(), null);
    },
  );
}
