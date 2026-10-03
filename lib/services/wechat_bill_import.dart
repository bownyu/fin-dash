import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:excel/excel.dart';
import '../data/wallet_store.dart';
import '../domain/models.dart';
import '../domain/ledger_operations.dart';

class WechatBillRecord {
  final String id,
      tradeNo,
      merchantNo,
      merchant,
      product,
      payment,
      status,
      kind,
      remark;
  final DateTime date;
  final int amount, row;
  final TxType type;
  const WechatBillRecord({
    required this.id,
    required this.tradeNo,
    required this.merchantNo,
    required this.merchant,
    required this.product,
    required this.payment,
    required this.status,
    required this.kind,
    required this.remark,
    required this.date,
    required this.amount,
    required this.row,
    required this.type,
  });
  bool get refund => type == TxType.income && kind.contains('退款');
  String get title => merchant.isNotEmpty
      ? merchant
      : product.isNotEmpty
      ? product
      : kind;
  LedgerTx transaction(String accountId, String category) => LedgerTx(
    id: id,
    title: title,
    amount: amount,
    date: date,
    type: type,
    category: category,
    accountId: accountId,
    note: [
      '来源：微信账单',
      '交易类型：$kind',
      '交易单号：$tradeNo',
      if (merchantNo.isNotEmpty) '商户单号：$merchantNo',
      if (merchant.isNotEmpty) '交易对方：$merchant',
      if (product.isNotEmpty) '商品：$product',
      '支付方式：$payment',
      '状态：$status',
      if (remark.isNotEmpty) '备注：$remark',
      if (refund) '退款按微信收入流水保存，统计中归入退款分类。',
    ].join('\n'),
  );
}

class WechatBillIssue {
  final int row;
  final String reason;
  const WechatBillIssue(this.row, this.reason);
}

class WechatBill {
  final List<WechatBillRecord> records;
  final List<WechatBillIssue> issues;
  final String sheet;
  const WechatBill(this.records, this.issues, this.sheet);
  int total(TxType type) =>
      records.where((r) => r.type == type).fold(0, (sum, r) => sum + r.amount);
  Map<String, int> get payments => {
    for (final payment in records.map((r) => r.payment).toSet())
      payment: records.where((r) => r.payment == payment).length,
  };

  /// Pure parsing: safe to run in a worker isolate; never writes the ledger.
  static WechatBill parse(Uint8List bytes) {
    if (bytes.length > 30 * 1024 * 1024) {
      throw const FormatException('微信账单超过 30 MB，请缩短导出时间范围');
    }
    Excel workbook;
    try {
      workbook = Excel.decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('无法读取 Excel，请选择微信导出的未加密 .xlsx 账单');
    }
    const required = [
      '交易时间',
      '交易类型',
      '交易对方',
      '商品',
      '收/支',
      '金额(元)',
      '支付方式',
      '当前状态',
      '交易单号',
    ];
    for (final sheet in workbook.tables.entries) {
      final rows = sheet.value.rows;
      if (rows.length > 50000) {
        throw const FormatException('账单超过 50000 行，请分批导出');
      }
      for (var h = 0; h < rows.length && h < 60; h++) {
        final headers = <String, int>{
          for (var c = 0; c < rows[h].length; c++)
            _header(_text(rows[h][c]?.value)): c,
        };
        if (!required.every(headers.containsKey)) continue;
        final records = <WechatBillRecord>[];
        final issues = <WechatBillIssue>[];
        for (var i = h + 1; i < rows.length; i++) {
          final row = rows[i];
          CellValue? cell(String key) {
            final col = headers[key];
            return col == null || col >= row.length ? null : row[col]?.value;
          }

          String value(String key) => _text(cell(key));
          if (row.every((c) => _text(c?.value).isEmpty)) continue;
          final direction = value('收/支'),
              kind = value('交易类型'),
              status = value('当前状态');
          final rowNumber = i + 1;
          if (!['收入', '支出'].contains(direction)) {
            issues.add(
              WechatBillIssue(rowNumber, '不计收支或中性交易：$kind（充值、提现等需另行记录账户转账）'),
            );
            continue;
          }
          if (!_settled(status)) {
            issues.add(WechatBillIssue(rowNumber, '未完成或不支持的状态：$status'));
            continue;
          }
          try {
            if (required.any((key) => cell(key) is FormulaCellValue)) {
              throw const FormatException('交易字段包含公式，请使用原始导出文件');
            }
            final tradeCell = cell('交易单号');
            if (tradeCell is! TextCellValue) {
              throw const FormatException('交易单号必须为文本，数字格式可能损失精度');
            }
            final tradeNo = value('交易单号');
            if (tradeNo.isEmpty) throw const FormatException('缺少交易单号');
            final type = direction == '收入' ? TxType.income : TxType.expense;
            final payment = value('支付方式');
            records.add(
              WechatBillRecord(
                id: 'wechat-${sha256.convert(utf8.encode('$tradeNo|${type.name}'))}',
                tradeNo: tradeNo,
                merchantNo: value('商户单号'),
                merchant: value('交易对方'),
                product: value('商品'),
                payment: payment.isNotEmpty
                    ? payment
                    : status == '已存入零钱'
                    ? '零钱'
                    : '待选账户',
                status: status,
                kind: kind,
                remark: value('备注'),
                date: _date(cell('交易时间')),
                amount: _amount(cell('金额(元)')),
                row: rowNumber,
                type: type,
              ),
            );
          } on FormatException catch (e) {
            issues.add(WechatBillIssue(rowNumber, e.message));
          }
        }
        final unique = <String, WechatBillRecord>{};
        final conflicts = <String>{};
        for (final record in records) {
          if (conflicts.contains(record.id)) {
            issues.add(WechatBillIssue(record.row, '同交易单号存在冲突，需核对原文件'));
            continue;
          }
          final previous = unique[record.id];
          if (previous == null) {
            unique[record.id] = record;
          } else if (previous.amount == record.amount &&
              previous.date == record.date &&
              previous.payment == record.payment) {
            issues.add(WechatBillIssue(record.row, '文件内重复交易单号，已保留第一笔'));
          } else {
            unique.remove(record.id);
            conflicts.add(record.id);
            issues.add(WechatBillIssue(previous.row, '同交易单号存在冲突，需核对原文件'));
            issues.add(WechatBillIssue(record.row, '同交易单号存在冲突，需核对原文件'));
          }
        }
        return WechatBill(
          List.unmodifiable(unique.values),
          List.unmodifiable(issues),
          sheet.key,
        );
      }
    }
    throw const FormatException('未找到微信账单表头，请选择微信支付导出的 .xlsx 明细文件');
  }

  static String _header(String text) => text
      .replaceAll(RegExp(r'\s'), '')
      .replaceAll('（', '(')
      .replaceAll('）', ')');
  static String _text(CellValue? cell) {
    final text = cell is TextCellValue
        ? cell.value.toString()
        : cell?.toString() ?? '';
    final clean = text.trim().replaceFirst('\uFEFF', '');
    return clean == '/' || clean == '--' ? '' : clean;
  }

  static bool _settled(String status) =>
      const {
        '支付成功',
        '已转账',
        '对方已收钱',
        '已存入零钱',
        '已收钱',
        '交易成功',
        '已到账',
        '收款成功',
        '已入账',
        '已支付',
        '已全额退款',
      }.contains(status) ||
      RegExp(r'^已退款(?:[（(]?[¥￥]?\d+(?:\.\d{1,2})?[)）]?)?$').hasMatch(status);
  static int _amount(CellValue? value) {
    final number = value is DoubleCellValue
        ? value.value
        : value is IntCellValue
        ? value.value
        : null;
    int amount;
    if (number != null) {
      if (!number.isFinite || number <= 0 || number > 9999999999.99) {
        throw const FormatException('金额无效');
      }
      amount = (number * 100).round();
      if ((number * 100 - amount).abs() > 0.00001) {
        throw const FormatException('金额超过两位小数');
      }
    } else {
      final text = _text(
        value,
      ).replaceFirst(RegExp(r'^[¥￥]'), '').replaceFirst(RegExp(r'元$'), '');
      amount = parseMoney(text);
    }
    if (amount <= 0) throw const FormatException('金额必须大于零');
    return amount;
  }

  static DateTime _date(CellValue? value) {
    DateTime? date;
    if (value is DateTimeCellValue) date = value.asDateTimeLocal();
    if (value is DateCellValue) date = value.asDateTimeLocal();
    if (value is DoubleCellValue || value is IntCellValue) {
      final days = value is DoubleCellValue
          ? value.value
          : (value as IntCellValue).value;
      if (!days.isFinite || days < 1 || days > 2958465) {
        throw const FormatException('交易时间无效');
      }
      final utc = DateTime.utc(
        1899,
        12,
        30,
      ).add(Duration(seconds: (days * 86400).round()));
      date = DateTime(
        utc.year,
        utc.month,
        utc.day,
        utc.hour,
        utc.minute,
        utc.second,
      );
    }
    if (value is TextCellValue) {
      final text = _text(value);
      final m = RegExp(
        r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?$',
      ).firstMatch(text);
      if (m != null) {
        final parts = [
          for (var i = 1; i <= 6; i++) int.parse(m.group(i) ?? '0'),
        ];
        final d = DateTime(
          parts[0],
          parts[1],
          parts[2],
          parts[3],
          parts[4],
          parts[5],
        );
        if ([d.year, d.month, d.day, d.hour, d.minute, d.second].join(',') ==
            parts.join(',')) {
          date = d;
        }
      }
    }
    if (date == null || date.year < 2000 || date.year > 2100) {
      throw const FormatException('交易时间无效');
    }
    final rounded = date.add(const Duration(milliseconds: 500));
    return DateTime(
      rounded.year,
      rounded.month,
      rounded.day,
      rounded.hour,
      rounded.minute,
      rounded.second,
    );
  }
}

class WechatImportResult {
  final int imported, duplicates;
  const WechatImportResult(this.imported, this.duplicates);
}

class WechatBillImporter {
  final WalletStore store;
  WechatBillImporter(this.store);
  Set<String> duplicates(WechatBill bill) {
    final seen = store.data.transactions.map((t) => t.id).toSet();
    return {
      for (final r in bill.records)
        if (seen.contains(r.id)) r.id,
    };
  }

  Set<String> similar(WechatBill bill) {
    final matches = _similarMatcher(store.data.transactions);
    return {
      for (final r in bill.records)
        if (matches(r)) r.id,
    };
  }

  static bool Function(WechatBillRecord) _similarMatcher(
    List<LedgerTx> transactions,
  ) {
    final buckets = <String, List<LedgerTx>>{};
    for (final tx in transactions) {
      final key =
          '${tx.type.name}|${tx.amount}|${tx.date.millisecondsSinceEpoch ~/ 120000}';
      (buckets[key] ??= []).add(tx);
    }
    return (record) {
      final time = record.date.millisecondsSinceEpoch ~/ 120000;
      for (var i = time - 1; i <= time + 1; i++) {
        final key = '${record.type.name}|${record.amount}|$i';
        if ((buckets[key] ?? const <LedgerTx>[]).any(
          (tx) => _similar(tx, record),
        )) {
          return true;
        }
      }
      return false;
    };
  }

  static bool _similar(LedgerTx t, WechatBillRecord r) =>
      t.id != r.id &&
      t.amount == r.amount &&
      t.type == r.type &&
      t.date.difference(r.date).inMilliseconds.abs() <= 120000;

  Map<String, String> suggestedAccounts(WechatBill bill) {
    final result = <String, String>{};
    for (final payment in bill.payments.keys) {
      String normalize(String s) => s
          .replaceAll(RegExp(r'\s'), '')
          .replaceAll('（', '(')
          .replaceAll('）', ')');
      final exact = store.activeAccounts
          .where((a) => normalize(a.name) == normalize(payment))
          .toList();
      if (exact.length == 1) {
        result[payment] = exact.single.id;
        continue;
      }
      final bank = RegExp(r'^(.+?银行)').firstMatch(payment)?.group(1);
      final tail = RegExp(r'[(（](\d{4})[)）]').firstMatch(payment)?.group(1);
      if (RegExp(r'[&+、;；]').hasMatch(payment)) continue;
      final possible = store.activeAccounts.where((a) {
        if (payment == '零钱') {
          return a.subType == 'wechat' || ['微信', '微信零钱'].contains(a.name);
        }
        if (bank == null || !a.name.contains(bank)) return false;
        if (RegExp(r'储蓄卡|借记卡').hasMatch(payment) && a.category == 'credit') {
          return false;
        }
        if (payment.contains('信用卡') && a.category != 'credit') return false;
        final accountTail = RegExp(
          r'[(（](\d{4})[)）]',
        ).firstMatch(a.name)?.group(1);
        return accountTail == null || tail == accountTail;
      }).toList();
      if (possible.length == 1) result[payment] = possible.single.id;
    }
    return result;
  }

  Future<WechatImportResult> import(
    WechatBill bill, {
    required Set<String> selectedIds,
    required Map<String, String> accountMapping,
    bool preserveBalances = true,
    Set<String> reviewedSimilarIds = const {},
  }) async {
    if (selectedIds.isEmpty) throw const FormatException('请至少选择一笔新账单');
    var count = 0, duplicates = 0;
    await store.change((d) {
      if (d.settings['locked'] == true) {
        throw const FormatException('账本已锁定，请先解锁');
      }
      final ids = d.transactions.map((t) => t.id).toSet();
      final accounts = d.accounts
          .where((a) => !a.archived)
          .map((a) => a.id)
          .toSet();
      final added = <LedgerTx>[];
      final matchesExisting = _similarMatcher(d.transactions);
      final effects = <String, int>{};
      for (final record in bill.records) {
        if (!selectedIds.contains(record.id)) continue;
        if (!ids.add(record.id)) {
          duplicates++;
          continue;
        }
        final account = accountMapping[record.payment];
        if (!accounts.contains(account)) {
          throw FormatException('请为“${record.payment}”选择有效账户');
        }
        if (!reviewedSimilarIds.contains(record.id) &&
            matchesExisting(record)) {
          throw const FormatException('出现可能重复的账单，请返回预览重新核对');
        }
        var category = record.refund
            ? '退款'
            : record.kind == '微信红包' && record.type == TxType.income
            ? '收红包'
            : '其他';
        if (!d.categories.any(
          (c) => c.name == category && c.type == record.type,
        )) {
          if (record.refund) {
            d.categories.add(
              WalletCategory(newId(), '退款', 'undo', '#4ECDC4', TxType.income),
            );
          } else {
            category =
                d.categories
                    .where(
                      (c) =>
                          c.type == record.type &&
                          ['其他', '其它'].contains(c.name),
                    )
                    .firstOrNull
                    ?.name ??
                '其他';
            if (!d.categories.any(
              (c) => c.type == record.type && c.name == category,
            )) {
              d.categories.add(
                WalletCategory(
                  newId(),
                  category,
                  'more_horiz',
                  '#94A3B8',
                  record.type,
                ),
              );
            }
          }
        }
        final tx = record.transaction(account!, category);
        added.add(tx);
        effects[account] = (effects[account] ?? 0) + tx.effectOn(account);
      }
      if (preserveBalances) {
        d.accounts = d.accounts
            .map(
              (a) => effects.containsKey(a.id)
                  ? a.copyWith(
                      openingBalance: a.openingBalance - effects[a.id]!,
                    )
                  : a,
            )
            .toList();
      }
      LedgerOperations.appendTransactions(d, added);
      if (added.isNotEmpty) d.extras.remove('analysisCache');
      count = added.length;
    });
    return WechatImportResult(count, duplicates);
  }
}
