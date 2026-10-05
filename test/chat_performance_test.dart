import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fin_dash/domain/command_context.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/ui/ai_pages.dart';
import 'package:fin_dash/ui/finance_pages.dart';
import 'navigation_test.dart' show renderApp;
import 'helpers.dart';
import 'agent_chat_interaction_test.dart' show chatHarness;
import 'ai_streaming_test.dart' show StreamingClient, event, chunk;

void main() {
  test(
    'two rounds and three read tools persist counters with checkpoints',
    () async {
      final store = await configuredAiStore();
      var commits = 0, rounds = 0;
      store.addListener(() => commits++);
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': rounds++ == 0
                      ? {
                          'tool_calls': [
                            for (var i = 0; i < 3; i++)
                              {
                                'id': 'read-$i',
                                'type': 'function',
                                'function': {
                                  'name': 'get_accounts_overview',
                                  'arguments': '{}',
                                },
                              },
                          ],
                        }
                      : {'content': 'done'},
                },
              ],
            }),
            200,
          ),
        ),
      );
      await ai.send('看看账户');
      expect(ai.error, null);
      expect(rounds, 2);
      expect(commits, 3);
      expect(ai.tasks.tasks.single['attempts'], 2);
      expect(ai.tasks.tasks.single['toolCalls'], 3);
    },
  );
  testWidgets(
    'AI writes leave retained tabs and status leaves messages intact',
    (tester) async {
      final store = await renderApp(tester);
      for (final index in [1, 2, 0]) {
        await tester.tap(find.byKey(Key('nav-$index')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('AI 顾问').first);
      await tester.pumpAndSettle();
      var tabs = 0, messages = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (element.widget is HomePage ||
            element.widget is StatsPage ||
            element.widget is BillsPage) {
          tabs++;
        }
        if (element.widget.runtimeType.toString() == '_Message') messages++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      await store.changeMetadata(
        (d) => d.chats.add({
          'id': 'perf-user',
          'role': 'user',
          'content': '你好',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      await tester.pumpAndSettle();
      expect(tabs, 0);
      messages = 0;
      store.setAiStatus('处理中');
      await tester.pump();
      expect(tabs, 0);
      expect(messages, 0);
    },
  );
  test('json equality matches digest semantics without hashing', () {
    expect(
      jsonEquals(
        {
          'a': 1,
          'b': [
            1,
            {'c': null},
          ],
        },
        {
          'b': [
            1,
            {'c': null},
          ],
          'a': 1,
        },
      ),
      true,
    );
    expect(jsonEquals({'a': null}, <String, dynamic>{}), false);
    expect(jsonEquals([1, 2], [2, 1]), false);
    expect(
      jsonEquals(
        {
          'a': [1],
        },
        {
          'a': [1, 2],
        },
      ),
      false,
    );
    expect(jsonEquals('x', 'x'), true);
  });

  test(
    'commits notify only changed domains and logs stay off the UI tree',
    () async {
      final store = await configuredAiStore();
      final notified = <WalletDomain>[];
      for (final domain in WalletDomain.values) {
        store.domainUpdates[domain]!.addListener(() => notified.add(domain));
      }
      var runtime = 0, logs = 0;
      store.runtimeUpdates.addListener(() => runtime++);
      store.logUpdates.addListener(() => logs++);
      await store.changeMetadata(
        (d) => d.chats.add({'id': 'm', 'role': 'user', 'content': '你好'}),
      );
      expect(notified, [WalletDomain.conversations]);
      notified.clear();
      await store.changeMetadata((d) => d.chats.first['content'] = '你好');
      expect(notified, isEmpty);
      await store.changeMetadata((d) => d.agent['tags'] = ['通勤']);
      expect(notified, [WalletDomain.memory]);
      notified.clear();
      await store.changeMetadata(
        (d) => d.agent['dismissedSuggestions'] = ['budget'],
      );
      expect(notified, [WalletDomain.preferences, WalletDomain.memory]);
      notified.clear();
      await store.changeMetadata(
        (d) => d.extras['savedRecipes'] = [
          {'id': 'recipe'},
        ],
      );
      expect(notified, [WalletDomain.tasks]);
      store.log('request', '第 1 轮');
      expect((runtime, logs), (0, 1));
    },
  );

  test(
    'token bursts notify only the reply and persist the complete output',
    () async {
      final store = await configuredAiStore();
      final controller = StreamController<List<int>>();
      final started = Completer<void>();
      final ai = AiService(
        store,
        TestVault('key'),
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
      var ledgerNotifications = 0, replyNotifications = 0;
      store.addListener(() => ledgerNotifications++);
      ai.liveUpdates.addListener(() => replyNotifications++);
      for (var i = 0; i < 30; i++) {
        controller.add(utf8.encode(event(chunk({'content': '字'}))));
      }
      await Future<void>.delayed(const Duration(milliseconds: 110));
      expect(replyNotifications, 1);
      expect(ledgerNotifications, 0);
      expect(ai.liveMessage!['content'], List.filled(30, '字').join());
      controller.add(
        utf8.encode('${event(chunk({}, 'stop'))}data: [DONE]\n\n'),
      );
      await controller.close();
      await sending;
      expect(store.data.chats.last['content'], List.filled(30, '字').join());
      expect(ai.busy, false);
      expect(ai.error, null);
    },
  );

  testWidgets(
    'long chat is lazy and live output rebuilds neither page nor composer',
    (tester) async {
      final store = await configuredAiStore();
      await store.change((d) {
        for (var i = 0; i < 80; i++) {
          d.chats.add({
            'id': 'history-$i',
            'role': 'assistant',
            'content': '历史消息 $i\n\n**完整格式**',
            'status': 'complete',
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });
        }
      });
      final ai = AiService(store, TestVault());
      ai.liveMessage = {
        'id': 'live',
        'role': 'assistant',
        'status': 'streaming',
        'content': '**正在回答**',
        'blocks': <dynamic>[],
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      store.setAiStatus('等待模型输出…');
      await tester.pumpWidget(chatHarness(store, ai));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '下一条草稿');
      await tester.pump();
      expect(find.byType(MarkdownBody).evaluate().length, lessThan(30));
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(
        tester
            .widgetList<MarkdownBody>(find.byType(MarkdownBody))
            .every((w) => !w.selectable),
        true,
      );
      var pageBuilds = 0, composerBuilds = 0, historyParses = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (element.widget is ChatPage) pageBuilds++;
        if (element.widget is TextField) composerBuilds++;
        if (element.widget is MarkdownBody) historyParses++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      for (var i = 0; i < 20; i++) {
        ai.liveMessage!['content'] = '**正在回答** $i';
        ai.liveUpdates.value++;
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.text('**正在回答** 19'), findsOneWidget);
      expect(find.text('下一条草稿'), findsOneWidget);
      expect(pageBuilds, 0);
      expect(composerBuilds, 0);
      expect(historyParses, 0);

      // Reading older history must not be interrupted by new output.
      final list = tester.widget<ListView>(find.byType(ListView).first);
      list.controller!.jumpTo(500);
      await tester.pump();
      final offset = list.controller!.offset;
      ai.liveMessage!['content'] = '**又一段输出**';
      ai.liveUpdates.value++;
      await tester.pump(const Duration(milliseconds: 80));
      expect(list.controller!.offset, offset);

      // Completion uses Markdown selected through the list's SelectionArea.
      list.controller!.jumpTo(0);
      ai.liveMessage!['status'] = 'complete';
      final completed = ai.liveMessage!;
      ai.liveMessage = null;
      await store.change((d) => d.chats.add(completed));
      store.setAiStatus(null);
      await tester.pumpAndSettle();
      expect(find.text('又一段输出'), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );
}
