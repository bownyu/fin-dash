import 'dart:convert';
import 'ledger_input.dart';
import 'models.dart';

enum TransactionWrite { upsert, insert, idempotentInsert }

/// Shared deterministic business rules. Callers own persistence and feedback.
abstract final class LedgerOperations {
  static void ensureUnlocked(WalletMetadata data) {
    if (data.settings['locked'] == true) {
      throw const FormatException('账本已锁定，请先解锁');
    }
  }

  static int money(dynamic value, String label, {bool signed = false}) {
    if (value is! int || value.abs() > 999999999999 || (!signed && value < 0)) {
      throw FormatException('$label 必须为有效的整数分');
    }
    return value;
  }

  static String text(dynamic value, String label, {bool empty = false}) {
    if (value is! String ||
        (!empty && value.trim().isEmpty) ||
        value.length > 2000) {
      throw FormatException('$label 无效或过长');
    }
    return value.trim();
  }

  static void validateTransaction(
    WalletData data,
    LedgerTx tx, {
    Set<String>? activeAccounts,
    Set<(TxType, String)>? categories,
  }) {
    text(tx.id, '账单 ID');
    text(tx.title, '账单标题');
    text(tx.note, '备注', empty: true);
    text(tx.category, '分类');
    if (tx.date.year < 1 || tx.date.year > 9999) {
      throw const FormatException('日期超出有效范围');
    }
    if (money(tx.amount, '金额') == 0) {
      throw const FormatException('交易金额必须大于零');
    }
    if (tx.type == TxType.transfer) {
      if (tx.fromId == null || tx.toId == null || tx.fromId == tx.toId) {
        throw const FormatException('请选择两个不同的账户');
      }
    } else if (!(categories?.contains((tx.type, tx.category)) ??
        data.categories.any(
          (c) => c.type == tx.type && c.name == tx.category,
        ))) {
      throw const FormatException('请使用已有的收支分类');
    }
    for (final id
        in tx.type == TxType.transfer ? [tx.fromId, tx.toId] : [tx.accountId]) {
      if (id == null ||
          !(activeAccounts?.contains(id) ??
              data.accounts.any((a) => a.id == id && !a.archived))) {
        throw const FormatException('请选择有效的未归档账户');
      }
    }
  }

  static bool sameTransaction(LedgerTx a, LedgerTx b) =>
      identical(a, b) || jsonEncode(a.toJson()) == jsonEncode(b.toJson());

  static LedgerTx putTransaction(
    WalletData data,
    LedgerTx tx, {
    TransactionWrite mode = TransactionWrite.upsert,
  }) {
    ensureUnlocked(data);
    validateTransaction(data, tx);
    tx = normalizeTransaction(data, tx);
    final index = data.transactions.indexWhere((item) => item.id == tx.id);
    if (index >= 0 && mode != TransactionWrite.upsert) {
      final previous = data.transactions[index];
      if (mode == TransactionWrite.idempotentInsert &&
          sameTransaction(previous, tx)) {
        return previous;
      }
      throw const FormatException('账单 ID 已存在，不能重复记账或覆盖其他记录');
    }
    if (index < 0) {
      data.transactions.add(tx);
    } else {
      data.transactions[index] = tx;
    }
    return tx;
  }

  /// One set of indexes for an import, rather than scanning the ledger per row.
  static void appendTransactions(WalletData data, List<LedgerTx> transactions) {
    ensureUnlocked(data);
    final ids = data.transactions.map((t) => t.id).toSet();
    final accounts = data.accounts
        .where((a) => !a.archived)
        .map((a) => a.id)
        .toSet();
    final categories = data.categories.map((c) => (c.type, c.name)).toSet();
    for (final tx in transactions) {
      if (!ids.add(tx.id)) throw const FormatException('账单 ID 已存在');
      validateTransaction(
        data,
        tx,
        activeAccounts: accounts,
        categories: categories,
      );
    }
    data.transactions.addAll(transactions.map((tx) => normalizeTransaction(data, tx)));
  }

  static LedgerTx normalizeTransaction(WalletData data,LedgerTx tx) {
    final matches=data.categories.where((c)=>c.name==tx.category && c.type==tx.type).toList();
    final id=matches.length==1 ? matches.single.id : null;
    if(tx.categoryId==id && !tx.date.isUtc)return tx;
    return LedgerTx.fromJson({...tx.toJson(),'categoryId':id,'date':tx.date.toLocal().toIso8601String()});
  }

  static int openingBalance(
    WalletData data,
    String accountId,
    int currentBalance,
  ) =>
      money(currentBalance, '当前余额', signed: true) -
      data.transactions.fold<int>(0, (sum, tx) => sum + tx.effectOn(accountId));

  static void putAccount(
    WalletData data,
    WalletAccount account, {
    int? currentBalance,
  }) {
    ensureUnlocked(data);
    text(account.id, '账户 ID');
    text(account.name, '账户名称');
    text(account.note, '备注', empty: true);
    if (!accountGroups.containsKey(account.category) ||
        !(accountPresets[account.category] ?? []).any(
          (p) => p.$1 == account.subType,
        )) {
      throw const FormatException('账户子类型与类型不匹配');
    }
    money(account.creditLimit, '信用额度');
    for (final day in [account.billingDay, account.repaymentDay]) {
      if (day != null && (day < 1 || day > 31)) {
        throw const FormatException('账单日与还款日为 1 至 31');
      }
    }
    final actual = currentBalance == null
        ? account
        : account.copyWith(
            openingBalance: openingBalance(data, account.id, currentBalance),
          );
    money(actual.openingBalance, '期初余额', signed: true);
    final index = data.accounts.indexWhere((a) => a.id == actual.id);
    if (index < 0) {
      data.accounts.add(actual);
    } else {
      data.accounts[index] = actual;
    }
  }

  static void deleteTransactions(WalletData data, Set<String> ids) {
    ensureUnlocked(data);
    data.transactions.removeWhere((t) => ids.contains(t.id));
  }

  /// JSON is an input adapter; the resulting record shares normal validation.
  static LedgerTx prepareTransaction(
    WalletData data,
    Json input, {
    required String id,
  }) {
    final old = data.transactions.where((t) => t.id == id).firstOrNull;
    if (input['id'] != null && old == null) {
      throw const FormatException('账单不存在');
    }
    final raw = <String, dynamic>{
      ...?old?.toJson(),
      'id': id,
      for (final key in [
        'title',
        'type',
        'amountCents',
        'date',
        'category',
        'note',
        'accountId',
        'transferFromId',
        'transferToId',
      ])
        if (input.containsKey(key)) key: input[key],
    };
    raw['title'] = text(raw['title'], '账单标题');
    raw['category'] = text(raw['category'], '分类');
    raw['amountCents'] = money(raw['amountCents'], '金额');
    raw['date'] = parseLedgerDate(raw['date']).toIso8601String();
    if (!TxType.values.any((type) => type.name == raw['type'])) {
      throw const FormatException('交易类型无效');
    }
    raw['note'] = raw['note'] == null
        ? ''
        : text(raw['note'], '备注', empty: true);
    if (raw['type'] == 'transfer') {
      raw['accountId'] = null;
    } else {
      raw['transferFromId'] = null;
      raw['transferToId'] = null;
    }
    for (final key in ['accountId', 'transferFromId', 'transferToId']) {
      if (raw[key] != null && raw[key] is! String) {
        throw const FormatException('账户 ID 必须为字符串');
      }
    }
    final tx = LedgerTx.fromJson(raw);
    validateTransaction(data, tx);
    final mapped = data.categories
        .where((c) => c.type == tx.type && c.name == tx.category)
        .toList();
    return LedgerTx.fromJson({
      ...tx.toJson(),
      'categoryId': mapped.length == 1 ? mapped.single.id : null,
    });
  }
}
