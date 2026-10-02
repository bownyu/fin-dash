import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/ui/preferences.dart';
import 'helpers.dart';
import 'agent_ui_test.dart' show harness;
import 'voice_and_sessions_test.dart' show answer, expense;

class ConfigurationVault implements KeyVault {
  final keys = <String, String>{};
  @override
  Future<String?> read(String provider) async => keys[provider];
  @override
  Future<void> write(String provider, String value) async {
    if (value.isEmpty) {
      keys.remove(provider);
    } else {
      keys[provider] = value;
    }
  }
}

Json config(String name, String host, {String protocol = chatProtocol}) => {
  'name': name,
  'baseURL': 'https://$host/v1',
  'model': 'model-$name',
  'protocol': protocol,
  'stream': false,
  'toolsEnabled': false,
};

void main() {
  test(
    'multiple configurations retain independent endpoints, protocols, secrets and selection after reload',
    () async {
      final storage = MemoryStorage(), vault = ConfigurationVault();
      final store = await emptyStore(storage);
      final requests = <String>[];
      final ai = AiService(
        store,
        vault,
        clientFactory: () => MockClient((request) async {
          requests.add(
            '${request.url.host}|${request.headers['authorization']}|${jsonDecode(request.body)['model']}',
          );
          return answer(jsonEncode(expense()));
        }),
      );
      await ai.saveConfiguration(
        config('A', 'a.example'),
        'key-a',
        providerId: 'a',
      );
      await ai.saveConfiguration(
        config('B', 'b.example'),
        'key-b',
        providerId: 'b',
      );
      expect(ai.provider, 'b');
      expect(ai.configurationIds, ['a', 'b']);
      await ai.interpretVoice('午餐28元');
      await ai.switchConfiguration('a');
      await ai.interpretVoice('午餐28元');
      expect(requests, [
        'b.example|Bearer key-b|model-B',
        'a.example|Bearer key-a|model-A',
      ]);
      expect(vault.keys, {'a': 'key-a', 'b': 'key-b'});
      expect(jsonEncode(store.data.toJson()), isNot(contains('key-a')));
      final reloaded = AiService(await emptyStore(storage), vault);
      expect(reloaded.provider, 'a');
      expect(reloaded.configuration('b')['baseURL'], 'https://b.example/v1');
      await reloaded.saveConfiguration(
        config('B updated', 'b2.example', protocol: responsesProtocol),
        'key-b2',
        providerId: 'b',
      );
      expect(reloaded.configuration('a')['model'], 'model-A');
      expect(vault.keys['a'], 'key-a');
      expect(reloaded.config['protocol'], responsesProtocol);
    },
  );

  test(
    'failed save/deletion rolls back only the affected configuration and its key',
    () async {
      final storage = MemoryStorage(), vault = ConfigurationVault();
      final store = await emptyStore(storage);
      final ai = AiService(store, vault);
      await ai.saveConfiguration(
        config('A', 'a.example'),
        'key-a',
        providerId: 'a',
      );
      await ai.saveConfiguration(
        config('B', 'b.example'),
        'key-b',
        providerId: 'b',
      );
      storage.failWrites = true;
      await expectLater(
        ai.saveConfiguration(
          config('A2', 'new.example'),
          'new-key',
          providerId: 'a',
        ),
        throwsStateError,
      );
      expect(ai.provider, 'b');
      expect(ai.configuration('a')['baseURL'], 'https://a.example/v1');
      expect(vault.keys, {'a': 'key-a', 'b': 'key-b'});
      await expectLater(ai.removeConfiguration('b'), throwsStateError);
      expect(ai.provider, 'b');
      expect(vault.keys['b'], 'key-b');
      storage.failWrites = false;
      await ai.removeConfiguration('b');
      expect(ai.provider, 'a');
      expect(vault.keys.containsKey('b'), false);
    },
  );

  test(
    'switching during an active request cannot change credentials underneath it',
    () async {
      final store = await emptyStore();
      final ai = AiService(store, ConfigurationVault());
      await ai.saveConfiguration(
        config('A', 'a.example'),
        'key-a',
        providerId: 'a',
      );
      await ai.saveConfiguration(
        config('B', 'b.example'),
        'key-b',
        providerId: 'b',
      );
      store.setAiStatus('等待模型');
      await expectLater(ai.switchConfiguration('a'), throwsFormatException);
      expect(ai.provider, 'b');
      store.setAiStatus(null);
    },
  );

  testWidgets(
    'add a second configuration from the UI, then switch and edit without overwriting the first',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await emptyStore();
      final vault = ConfigurationVault();
      final ai = AiService(store, vault);
      await ai.saveConfiguration(
        config('日常', 'a.example'),
        'key-a',
        providerId: 'a',
      );
      await tester.pumpWidget(harness(store, ai, const AiSettingsPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add-ai-provider')));
      await tester.pumpAndSettle();
      Future<void> fill(String key, String value) async {
        final finder = find.byKey(Key(key));
        await tester.ensureVisible(finder);
        await tester.enterText(finder, value);
      }

      await fill('provider-name', '备用');
      await fill('provider-key', 'key-b');
      await fill('provider-url', 'https://b.example/v1');
      await fill('provider-model', 'model-b');
      tester.testTextInput.hide();
      await tester.ensureVisible(find.byKey(const Key('save-ai-provider')));
      await tester.tap(find.byKey(const Key('save-ai-provider')));
      await tester.pumpAndSettle();
      final second = ai.provider;
      expect(second, isNot('a'));
      expect(ai.configurationIds.length, 2);
      expect(vault.keys[second], 'key-b');
      await tester.ensureVisible(find.byKey(const ValueKey('use-provider:a')));
      await tester.tap(find.byKey(const ValueKey('use-provider:a')));
      await tester.pumpAndSettle();
      expect(ai.provider, 'a');
      await tester.tap(find.byKey(const ValueKey('edit-provider:a')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('provider-key')))
            .controller!
            .text,
        'key-a',
      );
      expect(ai.configuration(second)['model'], 'model-b');
      expect(tester.takeException(), null);
    },
  );
}
