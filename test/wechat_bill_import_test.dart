import 'package:fin_dash/ui/interaction.dart';
import 'dart:typed_data';
import 'package:excel/excel.dart';
import 'package:flutter/material.dart' hide TextSpan;
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/data/storage_base.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/services/wechat_bill_import.dart';
import 'package:fin_dash/ui/wechat_import_page.dart';
import 'helpers.dart';
import 'voice_and_sessions_test.dart' show featureHarness;

Uint8List fixture({List<List<CellValue?>>? rows}) {
  final book = Excel.createExcel();
  final sheet = book['Sheet1'];
  sheet.appendRow([TextCellValue('微信支付账单明细')]);
  for (var i = 0; i < 15; i++) {
    sheet.appendRow([TextCellValue('导出说明')]);
  }
  sheet.appendRow([
    for (final label in [
      '交易时间',
      '交易类型',
      '交易对方',
      '商品',
      '收/支',
      '金额(元)',
      '支付方式',
      '当前状态',
      '交易单号',
      '商户单号',
      '备注',
    ])
      TextCellValue(label),
  ]);
  for (final row in rows ?? [entry()]) {
    sheet.appendRow(row);
  }
  return Uint8List.fromList(book.encode()!);
}

List<CellValue?> entry({
  String id = '123456789012345678901234567890',
  String direction = '支出',
  String kind = '商户消费',
  String status = '支付成功',
  String payment = '中国银行储蓄卡(9516)',
  CellValue? date,
  CellValue? amount,
}) => [
  date ?? TextCellValue('2026-10-01 18:58:51'),
  TextCellValue(kind),
  TextCellValue('测试商户'),
  TextCellValue('测试商品'),
  TextCellValue(direction),
  amount ?? const DoubleCellValue(28.05),
  TextCellValue(payment),
  TextCellValue(status),
  TextCellValue(id),
  TextCellValue('ORDER-001'),
  TextCellValue('已优惠¥1.00'),
];

void main() {
  test(
    'file duplicate IDs keep one row while conflicting amounts exclude both',
    () {
      final repeated = WechatBill.parse(fixture(rows: [entry(), entry()]));
      expect(repeated.records.length, 1);
      expect(repeated.issues.length, 1);
      final conflict = WechatBill.parse(
        fixture(
          rows: [
            entry(),
            entry(amount: const IntCellValue(100)),
          ],
        ),
      );
      expect(conflict.records, isEmpty);
      expect(conflict.issues.length, 2);
      final pendingRefund = WechatBill.parse(
        fixture(rows: [entry(status: '已退款处理中')]),
      );
      expect(pendingRefund.records, isEmpty);
    },
  );

  test(
    'concurrent imports deduplicate at commit and create a missing other category',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      await store.change((d) => d.categories.clear());
      final bill = WechatBill.parse(fixture());
      final service = WechatBillImporter(store);
      final results = await Future.wait([
        for (var i = 0; i < 2; i++)
          service.import(
            bill,
            selectedIds: {bill.records.single.id},
            accountMapping: {bill.records.single.payment: 'bank'},
          ),
      ]);
      expect(results.fold(0, (sum, result) => sum + result.imported), 1);
      expect(store.data.transactions.length, 1);
      expect(store.balance(store.account('bank')!), 100000);
      expect(store.data.categories.single.name, '其他');
    },
  );
  test('reads preamble, Excel dates, exact cents and long text IDs', () {
    final bill = WechatBill.parse(
      fixture(rows: [entry(date: const DoubleCellValue(46296.790868055556))]),
    );
    expect(bill.issues, isEmpty);
    expect(bill.records.single.amount, 2805);
    expect(bill.records.single.tradeNo, '123456789012345678901234567890');
    expect(bill.records.single.date, DateTime(2026, 10, 1, 18, 58, 51));
    expect(bill.payments.keys, ['中国银行储蓄卡(9516)']);
  });

  test(
    'refunds preserve income while partial/full refunded original purchases stay expenses',
    () {
      final bill = WechatBill.parse(
        fixture(
          rows: [
            entry(
              id: 'original',
              amount: const IntCellValue(110),
              status: '已退款(¥100.00)',
            ),
            entry(
              id: 'refund',
              direction: '收入',
              kind: '测试商户-退款',
              amount: const IntCellValue(100),
              status: '已退款¥100.00',
            ),
            entry(id: 'refunded', status: '已全额退款'),
            entry(
              id: 'transfer',
              direction: '收入',
              kind: '转账',
              status: '已存入零钱',
              payment: '/',
            ),
          ],
        ),
      );
      expect(bill.issues, isEmpty);
      expect(bill.records[0].type, TxType.expense);
      expect(bill.records[1].refund, true);
      expect(bill.records[2].type, TxType.expense);
      expect(bill.records[3].type, TxType.income);
      expect(bill.records[3].payment, '零钱');
    },
  );

  test(
    'neutral, pending, invalid money/date, formulas and numeric IDs are skipped visibly',
    () {
      final numericId = entry(id: 'numeric')
        ..[8] = const DoubleCellValue(123456789.0);
      final bill = WechatBill.parse(
        fixture(
          rows: [
            entry(id: 'neutral', direction: '不计收支', kind: '零钱充值'),
            entry(id: 'pending', status: '待支付'),
            entry(id: 'precision', amount: const DoubleCellValue(1.234)),
            entry(id: 'date', date: TextCellValue('2026-02-31 12:30:00')),
            numericId,
            entry(id: 'valid', amount: TextCellValue('￥1,234.56')),
          ],
        ),
      );
      expect(bill.records.length, 1);
      expect(bill.records.single.amount, 123456);
      expect(bill.issues.length, 5);
      final formula = WechatBill.parse(
        fixture(rows: [entry(amount: const FormulaCellValue('1+2'))]),
      );
      expect(formula.records, isEmpty);
      expect(formula.issues.single.reason, contains('公式'));
      expect(
        () => WechatBill.parse(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
      expect(
        () =>
            WechatBill.parse(Uint8List.fromList(Excel.createExcel().encode()!)),
        throwsFormatException,
      );
    },
  );

  test(
    'append, refund category, preserved balances, persistence and repeat import',
    () async {
      final storage = MemoryStorage();
      final store = await emptyStore(storage);
      await store.saveAccount(bank);
      await store.saveTx(tx());
      final bill = WechatBill.parse(
        fixture(
          rows: [
            entry(),
            entry(
              id: 'refund',
              direction: '收入',
              kind: '商户-退款',
              status: '已全额退款',
            ),
          ],
        ),
      );
      final service = WechatBillImporter(store);
      final balance = store.balance(bank);
      final selected = bill.records.map((r) => r.id).toSet();
      final mapping = {for (final p in bill.payments.keys) p: 'bank'};
      expect(store.data.transactions.length, 1);
      final result = await service.import(
        bill,
        selectedIds: selected,
        accountMapping: mapping,
      );
      expect(result.imported, 2);
      expect(store.data.transactions.length, 3);
      expect(store.balance(store.account('bank')!), balance);
      expect(store.data.transactions.last.category, '退款');
      expect(store.data.transactions.last.note, contains('商户单号：ORDER-001'));
      expect(store.data.transactions.last.note, contains('已优惠¥1.00'));
      final repeat = await service.import(
        bill,
        selectedIds: selected,
        accountMapping: mapping,
      );
      expect(repeat.imported, 0);
      expect(repeat.duplicates, 2);
      expect(store.balance(store.account('bank')!), balance);
      final restored = await emptyStore(storage);
      expect(restored.data.transactions.length, 3);
      expect(WechatBillImporter(restored).duplicates(bill).length, 2);
    },
  );

  test('balance-changing mode and failed writes are atomic', () async {
    final storage = MemoryStorage();
    final store = await emptyStore(storage);
    await store.saveAccount(bank);
    final bill = WechatBill.parse(fixture());
    final service = WechatBillImporter(store);
    final ids = bill.records.map((r) => r.id).toSet();
    final mapping = {bill.records.single.payment: 'bank'};
    storage.failWrites = true;
    await expectLater(
      service.import(bill, selectedIds: ids, accountMapping: mapping),
      throwsStateError,
    );
    expect(store.data.transactions, isEmpty);
    expect(store.account('bank')!.openingBalance, 100000);
    storage.failWrites = false;
    await service.import(
      bill,
      selectedIds: ids,
      accountMapping: mapping,
      preserveBalances: false,
    );
    expect(store.balance(bank), 97195);
  });

  test(
    'archived/missing accounts, locked ledgers and unreviewed similar entries cannot import',
    () async {
      final store = await emptyStore();
      await store.saveAccount(bank);
      final bill = WechatBill.parse(fixture());
      final service = WechatBillImporter(store);
      final ids = bill.records.map((r) => r.id).toSet();
      final mapping = {bill.records.single.payment: 'bank'};
      await expectLater(
        service.import(bill, selectedIds: ids, accountMapping: {}),
        throwsFormatException,
      );
      await store.change((d) => d.settings['locked'] = true);
      await expectLater(
        service.import(bill, selectedIds: ids, accountMapping: mapping),
        throwsFormatException,
      );
      await store.setLocked(false);
      await store.change((d) {
        d.accounts[0] = bank.copyWith(archived: true);
      });
      await expectLater(
        service.import(bill, selectedIds: ids, accountMapping: mapping),
        throwsFormatException,
      );
      await store.change((d) => d.accounts[0] = bank);
      await store.saveTx(tx(amount: 2805, date: bill.records.single.date));
      expect(service.similar(bill), ids);
      await expectLater(
        service.import(bill, selectedIds: ids, accountMapping: mapping),
        throwsFormatException,
      );
      await service.import(
        bill,
        selectedIds: ids,
        accountMapping: mapping,
        reviewedSimilarIds: ids,
      );
      expect(store.data.transactions.length, 2);
    },
  );

  test(
    'account suggestions require a unique bank/card match and never map WeChat savings to balance',
    () async {
      final store = await emptyStore();
      final bill = WechatBill.parse(
        fixture(
          rows: [
            entry(),
            entry(id: 'balance', payment: '零钱'),
          ],
        ),
      );
      await store.saveAccount(
        WalletAccount.fromJson({...bank.toJson(), 'name': '中国银行储蓄卡(2222)'}),
      );
      await store.change(
        (d) => d.accounts.add(
          const WalletAccount(
            id: 'fund',
            name: '微信零钱通',
            category: 'investment',
            subType: 'wechat_balance',
          ),
        ),
      );
      final service = WechatBillImporter(store);
      expect(service.suggestedAccounts(bill), isEmpty);
      await store.saveAccount(
        WalletAccount.fromJson({...bank.toJson(), 'name': '中国银行'}),
      );
      expect(service.suggestedAccounts(bill), {
        bill.records.first.payment: 'bank',
      });
      await store.saveAccount(
        WalletAccount.fromJson({
          ...bank.toJson(),
          'id': 'bank2',
          'name': '中国银行备用卡',
        }),
      );
      expect(service.suggestedAccounts(bill), isEmpty);
    },
  );

  testWidgets(
    'phone preview requires account mapping and confirmation before append',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await emptyStore();
      await store.saveAccount(bank);
      final bill = WechatBill.parse(fixture());
      await tester.pumpWidget(
        featureHarness(
          store,
          AiService(store, TestVault()),
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => WechatImportPage(initialBill: bill),
                ),
              ),
              child: const Text('打开导入'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开导入'));
      await tester.pumpAndSettle();
      expect(store.data.transactions, isEmpty);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('wechat-import')))
            .onPressed,
        null,
      );
      await tester.tap(find.byType(WalletSelectField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('银行卡').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wechat-import')));
      await tester.pumpAndSettle();
      expect(store.data.transactions, isEmpty);
      expect(find.text('导入 1 笔微信账单？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.data.transactions, isEmpty);
      await tester.tap(find.byKey(const Key('wechat-import')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wechat-approve')));
      await tester.pumpAndSettle();
      expect(store.data.transactions.length, 1);
      expect(store.balance(store.account('bank')!), 100000);
      expect(find.text('打开导入'), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );
}
