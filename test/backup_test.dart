import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/data/backup.dart';
import 'package:fin_dash/services/backup_bundle.dart';
import 'package:fin_dash/services/chat_image_storage.dart';
import 'package:crypto/crypto.dart';
import 'dart:typed_data';
import 'package:fin_dash/domain/models.dart';
import 'helpers.dart';
import 'package:fin_dash/data/wallet_migration.dart';

Json legacyBackup() => {
  'version': '2.0',
  'user': {'name': '旧用户'},
  'accounts': [
    {
      'id': 'bank',
      'name': '银行卡',
      'category': 'funds',
      'subType': 'bank_card',
      'balance': 999.50,
      'currency': 'CNY',
    },
    {
      'id': 'credit',
      'name': '信用卡',
      'category': 'credit',
      'subType': 'credit_card',
      'balance': -200.00,
      'creditDebt': 700,
    },
  ],
  'transactions': [
    {
      'id': 'old',
      'title': '早餐',
      'amount': .50,
      'date': '2026-10-01T08:30:00+08:00',
      'type': 'expense',
      'category': '早餐',
      'accountId': 'bank',
    },
  ],
  'quickTransactions': [
    {
      'id': 'q',
      'title': '早餐',
      'type': 'expense',
      'category': '早餐',
      'amount': .5,
      'accountId': 'bank',
    },
  ],
  'localStorage': {
    'ai_config_custom': jsonEncode({
      'apiKey': 'secret-key',
      'baseURL': 'https://example.com/v1',
      'model': 'test-model',
    }),
    'balance_visible': 'false',
    'agent_hard_memory': jsonEncode([
      {'id': 'm', 'fact': '15号发工资', 'importance': 'core'},
    ]),
  },
  'agentV2': {
    'userCognition': {
      'tags': ['节俭'],
    },
    'agentSelfModel': {'name': '财务管家'},
    'patternLibrary': [
      {'id': 'p', 'name': '旧消费规律'},
    ],
  },
};
void main() {
  test(
    'background backup keeps image bytes and strips nested credentials',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final images = MemoryChatImageStorage(),
          bytes = Uint8List.fromList([1, 2, 3]);
      final id = sha256.convert(bytes).toString();
      await images.save(id, bytes);
      await store.change((d) {
        d.chats.add({'id': 'image', 'role': 'user', 'imageId': id});
        d.extras['private'] = {'apiKey': 'secret', 'keep': 'retained'};
      });
      final raw = await exportBackupBundle(store, images);
      expect(raw, isNot(contains('secret')));
      final bundle = await parseBackupBundleAsync(
        Uint8List.fromList(utf8.encode(raw)),
      );
      expect(bundle.images[id], bytes);
      expect(bundle.preview.data.extras['private']['keep'], 'retained');
    },
  );
  test(
    'legacy JSON migration preserves balances, accounts, shortcuts and agent memory',
    () async {
      final preview = parseBackup(jsonEncode(legacyBackup())),
          store = await emptyStore();
      await store.restore(preview);
      expect(store.balance(store.account('bank')!), 99950);
      expect(store.liabilities, 20000);
      expect(store.netWorth, 79950);
      expect(store.data.quickEntries.single.accountId, 'bank');
      expect(store.data.quickEntries.single.amount, 50);
      expect(store.data.agent['tags'], ['节俭']);
      expect(store.data.agent['memories'].single['fact'], '15号发工资');
      expect(store.data.settings['visible'], false);
      expect(store.data.categories.any((c) => c.name == '早餐'), true);
      expect(store.exportBackup(), isNot(contains('secret-key')));
      expect(store.data.extras['agentV2']['patternLibrary'], isNotEmpty);
      await store.deleteTxs({'old'});
      expect(store.balance(store.account('bank')!), 100000);
    },
  );
  test('legacy Unicode Base64 backup is accepted', () {
    final raw = base64Encode(utf8.encode(jsonEncode(legacyBackup())));
    final preview = parseBackup(raw);
    expect(preview.data.profile['name'], '旧用户');
    expect(preview.data.transactions.single.title, '早餐');
  });
  test('orphaned historical references retained as unlinked transactions', () {
    final raw = legacyBackup();
    raw['transactions'][0]['accountId'] = 'deleted';
    final preview = parseBackup(jsonEncode(raw));
    expect(preview.data.transactions.single.accountId, null);
    expect(preview.notes.join(), contains('未关联'));
  });
  test('invalid backup never replaces current ledger', () async {
    final store = await emptyStore();
    await store.saveAccount(bank);
    final raw = legacyBackup();
    raw['transactions'][0]['amount'] = -10;
    expect(() => parseBackup(jsonEncode(raw)), throwsFormatException);
    expect(store.balance(bank), 100000);
    expect(() => parseBackup('invalid'), throwsFormatException);
  });
  test(
    'duplicate IDs, unknown schemas and unsupported currency are rejected',
    () {
      final raw = legacyBackup();
      raw['accounts'].add(raw['accounts'][0]);
      expect(() => parseBackup(jsonEncode(raw)), throwsFormatException);
      final foreign = legacyBackup();
      foreign['accounts'][0]['currency'] = 'USD';
      expect(() => parseBackup(jsonEncode(foreign)), throwsFormatException);
      expect(
        () => parseBackup(
          jsonEncode({'format': 'findash-flutter', 'schema': 99}),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'full Flutter backup round-trip restores all user state exactly',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveTx(tx());
      await store.change((d) {
        d.profile = {'name': '小余', 'avatar': '🌿'};
        d.settings['budget'] = 300000;
        d.goals.add({'id': 'g', 'description': '旅行', 'status': 'active'});
        d.chats.add({
          'id': 'chat',
          'role': 'user',
          'content': '你好',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      });
      final copy = await emptyStore();
      await copy.restore(parseBackup(store.exportBackup()));
      final expected = migrateWallet(store.data);
      expect(copy.ledgerEpoch, isNot(store.ledgerEpoch));
      expected.extras['ledgerEpoch'] = copy.ledgerEpoch;
      expected.extras['ledgerRevision'] = copy.ledgerRevision;
      expect(copy.data.toJson(), expected.toJson());
      expect(copy.balance(bank), 99850);
    },
  );
}
