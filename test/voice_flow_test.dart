import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/services/voice_bookkeeping.dart';
import 'package:fin_dash/services/voice_input.dart';
import 'package:fin_dash/services/voice_widget_runtime.dart';
import 'package:fin_dash/ui/voice_entry_page.dart';
import 'helpers.dart';
import 'voice_and_sessions_test.dart' show featureHarness;
import 'voice_widget_runtime_test.dart' show widgetRequest;

const boc = WalletAccount(
  id: 'boc',
  name: '中国银行',
  category: 'funds',
  subType: 'bank_card',
  openingBalance: 100000,
);

class FailedAi extends AiService {
  int calls = 0;
  FailedAi(WalletStore store) : super(store, TestVault());
  @override
  Future<Json> interpretVoice(String text, {String? defaultAccountId}) async {
    calls++;
    throw const FormatException('网络不可用');
  }
}

class SuccessfulAi extends AiService {
  int calls = 0;
  String? account;
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
  Future<Json> interpretVoice(String text, {String? defaultAccountId}) async {
    calls++;
    account = defaultAccountId;
    return result;
  }
}

class ControlledVoice extends VoiceInput {
  int starts = 0, stops = 0, cancels = 0;
  Completer<String?>? result;
  void Function(String)? partial, state;
  @override
  Future<String?> listen({
    void Function(String)? onPartial,
    void Function(String)? onState,
  }) {
    starts++;
    partial = onPartial;
    state = onState;
    result = Completer<String?>();
    onState?.call('listening');
    return result!.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    state?.call('recognizing');
    result!.complete('蜜雪冰城十块钱中国银行');
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (result != null && !result!.isCompleted) result!.complete(null);
  }
}

void main() {
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
    await store.change((d) {
      d.settings['locked'] = false;
      d.accounts[0] = boc.copyWith(archived: true);
    });
    await expectLater(service.confirm(filled), throwsFormatException);
    expect(store.data.transactions, isEmpty);
  });

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

  testWidgets(
    'page does not auto-start, stop generates review, and bottom confirmation saves edited cents',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await emptyStore();
      await store.saveAccount(boc);
      final voice = ControlledVoice();
      await tester.pumpWidget(
        featureHarness(
          store,
          SuccessfulAi(store),
          VoiceEntryPage(voice: voice),
        ),
      );
      await tester.pumpAndSettle();
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
      await tester.pumpWidget(
        featureHarness(store, ai, VoiceEntryPage(voice: voice), keyboard: 260),
      );
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
    'leaving the page cancels the microphone and cannot save late results',
    (tester) async {
      final store = await emptyStore();
      await store.saveAccount(boc);
      final voice = ControlledVoice();
      await tester.pumpWidget(
        featureHarness(
          store,
          SuccessfulAi(store),
          VoiceEntryPage(voice: voice),
        ),
      );
      await tester.tap(find.text('开始说话'));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      expect(voice.cancels, 1);
      expect(store.data.transactions, isEmpty);
      expect(tester.takeException(), null);
    },
  );
}
