import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/data/backup.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/data/wallet_store.dart';
import 'package:fin_dash/domain/models.dart';
import 'helpers.dart';

void main() {
  test(
    'search index follows committed edits, account renames and failed saves',
    () async {
      final storage = MemoryStorage();
      final store = await emptyStore(storage);
      await store.saveAccount(bank);
      await store.saveTx(tx());
      expect(store.query(search: '银行卡').length, 1);
      expect(store.query(search: '测试').length, 1);
      storage.failWrites = true;
      await expectLater(
        store.saveAccount(
          WalletAccount.fromJson({...bank.toJson(), 'name': '新账户'}),
        ),
        throwsStateError,
      );
      expect(store.query(search: '银行卡').length, 1);
      expect(store.query(search: '新账户'), isEmpty);
      storage.failWrites = false;
      await store.saveAccount(
        WalletAccount.fromJson({...bank.toJson(), 'name': '新账户'}),
      );
      expect(store.query(search: '银行卡'), isEmpty);
      expect(store.query(search: '新账户').length, 1);
      await store.saveTx(
        LedgerTx.fromJson({...tx().toJson(), 'note': 'Coffee'}),
      );
      expect(store.query(search: 'coffee').length, 1);
      await store.deleteTxs({'tx'});
      expect(store.query(search: 'coffee'), isEmpty);
    },
  );

  test(
    'repeated ledger reads stay current across failed saves, edits, deletion and restore',
    () async {
      final storage = MemoryStorage();
      final store = await emptyStore(storage);
      await store.saveAccount(bank);
      await store.saveAccount(cash);
      await store.saveTx(
        tx(id: 'older', amount: 150, date: DateTime(2026, 9, 30)),
      );
      await store.saveTx(
        tx(
          id: 'newer',
          type: TxType.income,
          amount: 200,
          account: 'cash',
          date: DateTime(2026, 10, 1),
        ),
      );
      final backup = parseBackup(store.exportBackup());
      final month = DateRange.forPeriod(Period.month, DateTime(2026, 10, 1));
      expect(store.balance(bank), 99850);
      expect(store.balance(cash), 10200);
      expect(store.query().map((entry) => entry.id), ['newer', 'older']);
      expect(() => store.query().clear(), throwsUnsupportedError);
      expect(store.query().length, 2);
      expect(store.total(TxType.expense, range: month), 0);
      expect(store.total(TxType.income, range: month), 200);
      storage.failWrites = true;
      await expectLater(
        store.saveTx(tx(id: 'failed', amount: 300)),
        throwsStateError,
      );
      expect(store.balance(bank), 99850);
      expect(store.query().map((entry) => entry.id), ['newer', 'older']);
      storage.failWrites = false;
      await store.saveTx(
        tx(
          id: 'older',
          amount: 250,
          account: 'cash',
          date: DateTime(2026, 10, 2),
        ),
      );
      expect(store.balance(bank), 100000);
      expect(store.balance(cash), 9950);
      expect(store.query().map((entry) => entry.id), ['older', 'newer']);
      expect(store.total(TxType.expense, range: month), 250);
      await store.deleteTxs({'newer'});
      expect(store.balance(cash), 9750);
      expect(store.total(TxType.income, range: month), 0);
      await store.restore(backup);
      expect(store.balance(bank), 99850);
      expect(store.balance(cash), 10200);
      expect(store.query().map((entry) => entry.id), ['newer', 'older']);
      expect(store.total(TxType.expense, range: month), 0);
      expect(store.total(TxType.income, range: month), 200);
    },
  );
  test('integer money preserves pennies, signed balances and formatting', () {
    expect(parseMoney('1.5'), 150);
    expect(parseMoney('0.01'), 1);
    expect(parseMoney('-0.01', signed: true), -1);
    expect(money(123456789), '¥ 1,234,567.89');
    expect(money(-1), '-¥ 0.01');
    for (final value in [
      '1.001',
      'NaN',
      'Infinity',
      '-1',
      '1..2',
      '100000000000',
    ]) {
      expect(() => parseMoney(value), throwsFormatException);
    }
  });
  test(
    'expense edits undo previous amount and previous account exactly',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveAccount(cash);
      await store.saveTx(tx());
      expect(store.balance(bank), 99850);
      await store.saveTx(tx(amount: 230, account: 'cash'));
      expect(store.balance(bank), 100000);
      expect(store.balance(cash), 9770);
      await store.saveTx(tx(amount: 333, type: TxType.income, account: 'bank'));
      expect(store.balance(cash), 10000);
      expect(store.balance(bank), 100333);
      await store.deleteTxs({'tx'});
      expect(store.balance(bank), 100000);
    },
  );
  test(
    'transfer and credit repayment conserve net worth and avoid income/expense',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveAccount(credit);
      final net = store.netWorth;
      await store.saveTx(
        tx(
          type: TxType.transfer,
          amount: 12000,
          account: null,
          from: 'bank',
          to: 'credit',
        ),
      );
      expect(store.balance(bank), 88000);
      expect(store.balance(credit), -8000);
      expect(store.netWorth, net);
      expect(store.total(TxType.expense), 0);
      expect(store.total(TxType.income), 0);
      await store.deleteTxs({'tx'});
      expect(store.balance(credit), -20000);
      expect(store.balance(bank), 100000);
    },
  );
  test(
    'invalid transfer never alters either account or saved transactions',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await expectLater(
        store.saveTx(tx(type: TxType.transfer, from: 'bank', to: 'bank')),
        throwsFormatException,
      );
      await expectLater(
        store.saveTx(tx(type: TxType.transfer, from: 'bank', to: 'missing')),
        throwsFormatException,
      );
      expect(store.balance(bank), 100000);
      expect(store.data.transactions, isEmpty);
    },
  );
  test(
    'negative balances and excluded accounts obey assets minus liabilities',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveAccount(credit);
      await store.saveAccount(
        const WalletAccount(
          id: 'hidden',
          name: '不计入',
          category: 'funds',
          subType: 'cash',
          openingBalance: 999999,
          includeInTotal: false,
        ),
      );
      expect(store.assets, 100000);
      expect(store.liabilities, 20000);
      expect(store.netWorth, 80000);
      await store.saveAccount(credit, currentBalance: 5000);
      expect(store.assets, 105000);
      expect(store.liabilities, 0);
    },
  );
  test(
    'calibrating current balance does not reapply historical transactions',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveTx(tx(amount: 8000));
      await store.saveAccount(bank, currentBalance: 150000);
      expect(store.balance(store.account('bank')!), 150000);
      await store.deleteTxs({'tx'});
      expect(store.balance(store.account('bank')!), 158000);
    },
  );
  test('batch deletion reverses all ledger effects', () async {
    final store = await emptyStore();
    await store.saveAccount(bank);
    await store.saveAccount(cash);
    await store.saveTx(tx(id: 'a', amount: 10));
    await store.saveTx(tx(id: 'b', type: TxType.income, amount: 20));
    await store.saveTx(
      tx(id: 'c', type: TxType.transfer, amount: 30, from: 'bank', to: 'cash'),
    );
    await store.deleteTxs({'a', 'b', 'c'});
    expect(store.balance(bank), 100000);
    expect(store.balance(cash), 10000);
  });
  test(
    'failed persistence leaves in-memory state intact and next operation works',
    () async {
      final storage = MemoryStorage(), store = await emptyStore();
      final failing = WalletStore(storage);
      await failing.initialize();
      await failing.saveAccount(bank);
      storage.failWrites = true;
      await expectLater(failing.saveTx(tx()), throwsStateError);
      expect(failing.data.transactions, isEmpty);
      expect(failing.balance(bank), 100000);
      storage.failWrites = false;
      await failing.saveTx(tx());
      expect(failing.balance(bank), 99850);
      expect(store.data.transactions, isEmpty);
    },
  );
  test('concurrent writes serialize without losing transactions', () async {
    final store = await emptyStore();
    await store.saveAccount(bank);
    await Future.wait(
      List.generate(50, (i) => store.saveTx(tx(id: '$i', amount: 1))),
    );
    expect(store.data.transactions.length, 50);
    expect(store.balance(bank), 99950);
    final restored = WalletStore(store.storage);
    await restored.initialize();
    expect(restored.balance(bank), 99950);
  });
  test(
    'archive retains history and blocks new transactions, linked account cannot be deleted',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.saveTx(tx());
      await expectLater(store.deleteAccount('bank'), throwsFormatException);
      await store.saveAccount(bank.copyWith(archived: true));
      expect(store.activeAccounts, isEmpty);
      expect(store.data.transactions.length, 1);
      await expectLater(store.saveTx(tx(id: 'new')), throwsFormatException);
      expect(store.balance(bank), 99850);
    },
  );
  test(
    'date ranges include start and exclude end across leap year and year boundary',
    () {
      final leap = DateRange.forPeriod(Period.month, DateTime(2024, 2, 29));
      expect(leap.end, DateTime(2024, 3, 1));
      expect(leap.contains(DateTime(2024, 2, 1)), isTrue);
      expect(leap.contains(DateTime(2024, 3, 1)), isFalse);
      final week = DateRange.forPeriod(Period.week, DateTime(2026, 1, 1));
      expect(week.start, DateTime(2025, 12, 29));
      expect(week.end, DateTime(2026, 1, 5));
      expect(
        DateRange.shift(Period.month, DateTime(2026, 1, 31), 1),
        DateTime(2026, 2),
      );
    },
  );
  test('search and account filter include both sides of a transfer', () async {
    final store = await emptyStore();
    await store.saveAccount(bank);
    await store.saveAccount(cash);
    await store.saveTx(tx(type: TxType.transfer, from: 'bank', to: 'cash'));
    expect(store.query(accountId: 'cash').length, 1);
    expect(store.query(accountId: 'bank').length, 1);
    expect(store.query(search: '测试').length, 1);
    expect(store.query(search: '不存在'), isEmpty);
  });
  test('JSON envelope detects corruption and malformed structures', () {
    final text = jsonEncode({'name': '小余'});
    expect(unseal(seal(text)), text);
    expect(
      () => unseal(seal(text).replaceAll('小余', '篡改')),
      throwsFormatException,
    );
    expect(() => unseal('{}'), throwsFormatException);
  });
}
