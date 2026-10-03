import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/services/agent_actions.dart';
import 'helpers.dart';

void main() {
  test(
    'review summaries expose key amounts and changed settings without model parameters',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveAccount(credit);
      final actions = AgentActions(store);
      await actions.propose('account', {
        'id': 'credit',
        'creditLimitCents': 200000,
        'repaymentDay': 20,
      });
      final summary = actions.items.first['displaySummary'] as String;
      expect(summary, contains('信用额度：¥ 1,000.00 → ¥ 2,000.00'));
      expect(summary, contains('还款日 未设置 → 20'));
      await actions.propose('transaction', {
        'title': '午餐',
        'amountCents': 1250,
        'type': 'expense',
        'date': '2026-10-01T12:30:00',
        'category': '餐饮',
        'accountId': 'bank',
      });
      expect(
        actions.items.first['displaySummary'],
        contains('新增「午餐」：支出 ¥ 12.50'),
      );
      expect(
        actions.items.first['displaySummary'],
        contains('银行卡 · 2026-10-01 12:30'),
      );
      expect(
        actions.items.first['displaySummary'],
        isNot(contains('accountId')),
      );
    },
  );

  test('invalid calendar and clock values never create a proposal', () async {
    final store = await emptyStore();
    await store.saveAccount(bank);
    final actions = AgentActions(store);
    for (final date in [
      '2026-02-29',
      '2026-02-31T12:00:00',
      '2026-13-01',
      '2026-10-01T24:00:00',
      '2026-10-01T12:60:00',
      '2026-10-01T12:00:60',
      '2026-10-01T12:00:00+08:60',
    ]) {
      await expectLater(
        actions.propose('transaction', {
          'title': '午餐',
          'type': 'expense',
          'amountCents': 1250,
          'category': '餐饮',
          'accountId': 'bank',
          'date': date,
        }),
        throwsFormatException,
        reason: date,
      );
    }
    expect(actions.items, isEmpty);
    final proposal = await actions.propose('transaction', {
      'title': '午餐',
      'type': 'expense',
      'amountCents': 1250,
      'category': '餐饮',
      'accountId': 'bank',
      'date': '2024-02-29T12:30:00+08:00',
    });
    await actions.apply(proposal['proposalId']);
    expect(
      store.data.transactions.single.date.toUtc(),
      DateTime.utc(2024, 2, 29, 4, 30),
    );
  });

  test(
    'updating a transfer preserves unrelated fields and undo restores both accounts',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveAccount(cash);
      await store.saveTx(tx(type: TxType.transfer, from: 'bank', to: 'cash'));
      final actions = AgentActions(store);
      final proposal = await actions.propose('transaction', {
        'id': 'tx',
        'amountCents': 300,
      });
      await actions.apply(proposal['proposalId']);
      expect(store.balance(bank), 99700);
      expect(store.balance(cash), 10300);
      expect(store.data.transactions.single.title, '测试账单');
      await actions.undo(proposal['proposalId']);
      expect(store.balance(bank), 99850);
      expect(store.balance(cash), 10150);
    },
  );

  test(
    'proposals do not mutate balances and repeated confirmation is idempotent',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final actions = AgentActions(store);
      final args = {'id': 'bank', 'name': '工资卡', 'currentBalanceCents': 80000};
      final first = await actions.propose('account', args);
      final again = await actions.propose('account', args);
      expect(again['proposalId'], first['proposalId']);
      expect(store.account('bank')!.name, '银行卡');
      expect(store.balance(bank), 100000);
      await actions.apply(first['proposalId']);
      await actions.apply(first['proposalId']);
      expect(store.account('bank')!.name, '工资卡');
      expect(store.balance(store.account('bank')!), 80000);
      expect(store.data.chats.length, 2);
      expect(store.data.chats.first['content'], contains('确认执行'));
      expect(store.data.chats.last['actionStatus'], 'applied');
      await actions.undo(first['proposalId']);
      await actions.undo(first['proposalId']);
      expect(store.account('bank')!.name, '银行卡');
      expect(store.balance(store.account('bank')!), 100000);
      expect(store.data.chats.length, 4);
      expect(store.data.chats.last['content'], contains('已撤销'));
    },
  );

  test('balance correction respects existing ledger effects', () async {
    final store = await emptyStore();
    await store.saveAccount(bank);
    await store.saveTx(tx(amount: 300));
    final actions = AgentActions(store);
    final p = await actions.propose('account', {
      'id': 'bank',
      'currentBalanceCents': 90000,
    });
    await actions.apply(p['proposalId']);
    expect(store.account('bank')!.openingBalance, 90300);
    expect(store.balance(store.account('bank')!), 90000);
    expect(store.data.transactions.length, 1);
  });

  test(
    'stale balance proposals and undo after later changes are rejected',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final actions = AgentActions(store);
      final p = await actions.propose('account', {'id': 'bank', 'name': '新名字'});
      await store.saveTx(tx());
      await expectLater(actions.apply(p['proposalId']), throwsFormatException);
      expect(store.account('bank')!.name, '银行卡');
      expect(store.data.chats, isEmpty);
      final budget = await actions.propose('budget', {'amountCents': 20000});
      await actions.apply(budget['proposalId']);
      await store.change((d) => d.settings['budget'] = 30000);
      await expectLater(
        actions.undo(budget['proposalId']),
        throwsFormatException,
      );
      expect(store.data.settings['budget'], 30000);
    },
  );

  test(
    'failed persistence keeps proposal pending and ledger unchanged',
    () async {
      final storage = MemoryStorage();
      final store = await emptyStore(storage);
      await store.saveAccount(bank);
      final actions = AgentActions(store);
      final p = await actions.propose('account', {'id': 'bank', 'name': '工资卡'});
      storage.failWrites = true;
      await expectLater(actions.apply(p['proposalId']), throwsStateError);
      expect(actions.items.single['status'], 'pending');
      expect(store.account('bank')!.name, '银行卡');
      storage.failWrites = false;
      await actions.apply(p['proposalId']);
      final reloaded = await emptyStore(storage);
      expect(AgentActions(reloaded).items.single['status'], 'applied');
      expect(reloaded.data.chats.length, 2);
      expect(reloaded.data.chats.last['content'], contains('已执行并保存到账本'));
    },
  );

  test(
    'new transaction requires valid fields and cannot be approved by model args',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final actions = AgentActions(store);
      await expectLater(
        actions.propose('transaction', {'title': '午餐', 'amountCents': -10}),
        throwsFormatException,
      );
      final p = await actions.propose('transaction', {
        'title': '午餐',
        'amountCents': 1250,
        'type': 'expense',
        'date': '2026-10-01T12:00:00',
        'category': '餐饮',
        'accountId': 'bank',
        'status': 'applied',
      });
      expect(store.data.transactions, isEmpty);
      await actions.apply(p['proposalId']);
      expect(store.balance(bank), 98750);
      await actions.undo(p['proposalId']);
      expect(store.data.transactions, isEmpty);
    },
  );

  test(
    'bad account settings rejected before preview, rejected actions never execute',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final actions = AgentActions(store);
      await expectLater(
        actions.propose('account', {'id': 'missing', 'name': '卡'}),
        throwsFormatException,
      );
      await expectLater(
        actions.propose('account', {'id': 'bank', 'billingDay': 32}),
        throwsFormatException,
      );
      await expectLater(
        actions.propose('account', {'id': 'bank', 'creditLimitCents': 12.3}),
        throwsFormatException,
      );
      final p = await actions.propose('budget', {'amountCents': 15000});
      await actions.reject(p['proposalId']);
      await actions.reject(p['proposalId']);
      await expectLater(actions.apply(p['proposalId']), throwsFormatException);
      expect(store.data.settings['budget'], 0);
      expect(store.data.chats.length, 2);
      expect(store.data.chats.last['actionStatus'], 'rejected');
    },
  );
}
