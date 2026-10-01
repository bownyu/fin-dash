import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/services/chat_image_storage_native.dart';
import 'package:fin_dash/services/voice_widget_runtime.dart';
import 'helpers.dart';
import 'voice_and_sessions_test.dart' show answer, expense;

Future<Json> widgetRequest(Json request) async {
  const codec = StandardMethodCodec();
  final result = Completer<Json>();
  ServicesBinding.instance.channelBuffers.push(
    VoiceWidgetRuntime.channel.name,
    codec.encodeMethodCall(MethodCall('record', request)),
    (data) {
      try {
        result.complete(Json.from(codec.decodeEnvelope(data!) as Map));
      } catch (e, stack) {
        result.completeError(e, stack);
      }
    },
  );
  return result.future;
}

void main() {
  test(
    'widget channel records and undoes with the shared ledger without opening the app',
    () async {
      final store = await configuredAiStore();
      await store.saveAccount(bank);
      var shown = 0, calls = 0;
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient((_) async {
          calls++;
          return answer(jsonEncode(expense()));
        }),
      );
      VoiceWidgetRuntime.install(store, ai, () => shown++);
      addTearDown(() => VoiceWidgetRuntime.channel.setMethodCallHandler(null));
      final request = {
        'operation': 'record',
        'text': '午餐二十八元',
        'entryId': 'widget-1',
      };
      final result = await widgetRequest(request);
      expect(result['success'], true);
      expect(result['message'], contains('¥ 28.00'));
      expect(store.balance(bank), 97200);
      expect(store.data.chats, isEmpty);
      expect(shown, 0);
      await widgetRequest(request);
      expect(calls, 1);
      expect(store.data.transactions.length, 1);
      final undo = await widgetRequest({
        'operation': 'undo',
        'transaction': jsonEncode(result['transaction']),
      });
      expect(undo['undone'], true);
      expect(store.balance(bank), 100000);
      expect(shown, 0);
    },
  );

  test(
    'widget surfaces clarification and respects the locked ledger',
    () async {
      final store = await configuredAiStore();
      await store.saveAccount(bank);
      var calls = 0;
      final ai = AiService(
        store,
        TestVault('key'),
        clientFactory: () => MockClient((_) async {
          calls++;
          return answer('{"question":"请说明金额"}');
        }),
      );
      VoiceWidgetRuntime.install(
        store,
        ai,
        () => fail('Widget must not show the app'),
      );
      addTearDown(() => VoiceWidgetRuntime.channel.setMethodCallHandler(null));
      final result = await widgetRequest({
        'operation': 'record',
        'text': '午餐',
        'entryId': 'widget-2',
      });
      expect(result['needsClarification'], true);
      expect(store.data.transactions, isEmpty);
      await store.change((d) => d.settings['locked'] = true);
      final locked = await widgetRequest({
        'operation': 'record',
        'text': '午餐28元',
        'entryId': 'widget-2',
      });
      expect(locked['message'], contains('锁定'));
      expect(calls, 1);
    },
  );

  test(
    'local image files survive service recreation and reject imported paths',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'findash-chat-image-',
      );
      addTearDown(() {
        final prefix =
            '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}findash-chat-image-';
      if (!directory.absolute.path.startsWith(prefix)) {
        throw StateError('Unexpected test directory');
      }
        return directory.delete(recursive: true);
      });
      final id = List.filled(64, 'b').join();
      final bytes = File('assets/brand.png').readAsBytesSync();
      await LocalChatImageStorage(directory: directory).save(id, bytes);
      expect(await LocalChatImageStorage(directory: directory).read(id), bytes);
      expect(
        await LocalChatImageStorage(
          directory: directory,
        ).read('../findash_ledger.json'),
        null,
      );
    },
  );
}
