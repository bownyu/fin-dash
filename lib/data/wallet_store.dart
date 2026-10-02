import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../domain/models.dart';
import 'backup.dart';
import 'storage_base.dart';
import 'wallet_codec.dart';

class WalletStore extends ChangeNotifier {
  final WalletStorage storage;
  WalletData _data = WalletData();
  WalletData? _derivedFrom;
  Map<String, int>? _balanceEffects;
  List<LedgerTx>? _orderedTransactions;
  Map<String, WalletAccount>? _accountsById;
  Map<String, String>? _searchText;
  WalletData get data => _data;
  bool loading = true;
  String? startupError;
  String? aiStatus;
  final List<Json> debugLogs = [];
  Future<void> _tail = Future.value();
  WalletStore(this.storage);
  Future<void> initialize({bool demo = false}) async {
    try {
      final backend = storage;
      final loaded = backend is IncrementalWalletStorage
          ? await backend.loadSnapshot()
          : await _loadJson();
      if (loaded != null) {
        _data = loaded;
      } else if (demo) {
        _data = demoData();
      }
    } catch (e) {
      startupError = '本地数据加载失败：$e';
    }
    loading = false;
    notifyListeners();
  }

  Future<WalletData?> _loadJson() async {
    final raw = await storage.load();
    return raw == null ? null : decodeWalletSnapshot(raw);
  }

  Future<void> change(void Function(WalletData) mutate) {
    final work = _tail.then((_) async {
      if (startupError != null) throw StateError('请先恢复账本');
      final next = _data.clone();
      mutate(next);
      final backend = storage;
      if (backend is IncrementalWalletStorage) {
        await backend.commitSnapshot(_data, next);
      } else {
        await backend.save(await encodeWalletSnapshot(next));
      }
      _data = next;
      notifyListeners();
    });
    _tail = work.catchError((_) {});
    return work;
  }

  Future<void> restore(ImportPreview preview) {
    final work = _tail.then((_) async {
      final next = preview.data.clone();
      final backend = storage;
      if (backend is IncrementalWalletStorage) {
        await backend.replaceSnapshot(next);
      } else {
        await backend.save(await encodeWalletSnapshot(next));
      }
      _data = next;
      startupError = null;
      notifyListeners();
    });
    _tail = work.catchError((_) {});
    return work;
  }

  String exportBackup() => const JsonEncoder.withIndent('  ').convert(
    removeSecrets({
      ..._data.toJson(),
      'exportDate': DateTime.now().toIso8601String(),
    }),
  );
  List<WalletAccount> get activeAccounts =>
      _data.accounts.where((a) => !a.archived).toList();
  WalletAccount? account(String? id) {
    _checkDerivedData();
    _accountsById ??= {
      for (final account in _data.accounts) account.id: account,
    };
    return _accountsById![id];
  }

  // Committed writes replace _data. Failed saves and AI status updates keep
  // the current snapshot, so cached ledger results remain valid.
  void _checkDerivedData() {
    if (identical(_derivedFrom, _data)) return;
    _derivedFrom = _data;
    _balanceEffects = null;
    _orderedTransactions = null;
    _accountsById = null;
    _searchText = null;
  }

  Map<String, int> get _effects {
    _checkDerivedData();
    if (_balanceEffects != null) return _balanceEffects!;
    final result = <String, int>{};
    void add(String? id, int amount) {
      if (id != null) result[id] = (result[id] ?? 0) + amount;
    }

    for (final tx in _data.transactions) {
      switch (tx.type) {
        case TxType.expense:
          add(tx.accountId, -tx.amount);
        case TxType.income:
          add(tx.accountId, tx.amount);
        case TxType.transfer:
          add(tx.fromId, -tx.amount);
          add(tx.toId, tx.amount);
      }
    }
    return _balanceEffects = result;
  }

  List<LedgerTx> get _ordered {
    _checkDerivedData();
    return _orderedTransactions ??= (_data.transactions.toList()
      ..sort((a, b) => b.date.compareTo(a.date)));
  }

  int balance(WalletAccount a) => a.openingBalance + (_effects[a.id] ?? 0);
  int get assets => _data.accounts
      .where((a) => a.includeInTotal)
      .fold(0, (sum, a) => sum + max(0, balance(a)));
  int get liabilities => _data.accounts
      .where((a) => a.includeInTotal)
      .fold(0, (sum, a) => sum + max(0, -balance(a)));
  int get netWorth => assets - liabilities;
  List<LedgerTx> query({
    DateRange? range,
    TxType? type,
    String? accountId,
    String? category,
    String search = '',
  }) {
    _checkDerivedData();
    final normalizedSearch = search.toLowerCase();
    // Build normalized text once per committed snapshot, not per keystroke.
    if (search.isNotEmpty) {
      _searchText ??= {
        for (final t in _data.transactions)
          t.id:
              '${t.title} ${t.note} ${t.category} ${account(t.accountId)?.name ?? ''} ${account(t.fromId)?.name ?? ''} ${account(t.toId)?.name ?? ''}'
                  .toLowerCase(),
      };
    }
    return _ordered
        .where(
          (t) =>
              (range == null || range.contains(t.date)) &&
              (type == null || t.type == type) &&
              (category == null || t.category == category) &&
              (accountId == null ||
                  [t.accountId, t.fromId, t.toId].contains(accountId)) &&
              (search.isEmpty ||
                  _searchText![t.id]!.contains(normalizedSearch)),
        )
        .toList();
  }

  int total(TxType type, {DateRange? range, List<LedgerTx>? transactions}) =>
      (transactions ?? _data.transactions)
          .where(
            (t) =>
                t.type == type &&
                (transactions != null ||
                    range == null ||
                    range.contains(t.date)),
          )
          .fold(0, (sum, t) => sum + t.amount);
  Map<String, int> breakdown(TxType type, DateRange range) {
    final result = <String, int>{};
    for (final t in _data.transactions.where(
      (t) => t.type == type && range.contains(t.date),
    )) {
      result[t.category] = (result[t.category] ?? 0) + t.amount;
    }
    return Map.fromEntries(
      result.entries.toList()..sort((a, b) => b.value.compareTo(a.value)),
    );
  }

  Future<void> saveTx(LedgerTx tx) => change((d) {
    if (tx.type == TxType.transfer) {
      if (tx.fromId == null || tx.toId == null || tx.fromId == tx.toId) {
        throw const FormatException('请选择两个不同的账户');
      }
    } else if (tx.accountId == null) {
      throw const FormatException('请选择账户');
    }
    for (final id
        in tx.type == TxType.transfer ? [tx.fromId, tx.toId] : [tx.accountId]) {
      if (!d.accounts.any((a) => a.id == id && !a.archived)) {
        throw const FormatException('账户已归档或不存在');
      }
    }
    final index = d.transactions.indexWhere((t) => t.id == tx.id);
    if (index < 0) {
      d.transactions.add(tx);
    } else {
      d.transactions[index] = tx;
    }
    if (tx.accountId != null) d.settings['quickEntryAccountId'] = tx.accountId;
  });
  Future<void> deleteTxs(Set<String> ids) =>
      change((d) => d.transactions.removeWhere((t) => ids.contains(t.id)));
  Future<void> saveAccount(WalletAccount a, {int? currentBalance}) =>
      change((d) {
        final delta = d.transactions.fold<int>(
          0,
          (sum, t) => sum + t.effectOn(a.id),
        );
        final actual = currentBalance == null
            ? a
            : a.copyWith(openingBalance: currentBalance - delta);
        final index = d.accounts.indexWhere((x) => x.id == a.id);
        if (index < 0) {
          d.accounts.add(actual);
        } else {
          d.accounts[index] = actual;
        }
      });
  Future<void> deleteAccount(String id) => change((d) {
    if (d.transactions.any(
      (t) => [t.accountId, t.fromId, t.toId].contains(id),
    )) {
      throw const FormatException('账户有关联账单，请使用归档以保留历史');
    }
    d.accounts.removeWhere((a) => a.id == id);
    d.quickEntries = d.quickEntries
        .map(
          (q) => QuickEntry.fromJson({
            ...q.toJson(),
            if (q.accountId == id) 'accountId': null,
            if (q.fromId == id) 'fromAccountId': null,
            if (q.toId == id) 'toAccountId': null,
          }),
        )
        .toList();
  });
  Future<void> saveQuick(QuickEntry q) => change((d) {
    final i = d.quickEntries.indexWhere((x) => x.id == q.id);
    if (i < 0) {
      d.quickEntries.add(q);
    } else {
      d.quickEntries[i] = q;
    }
  });
  Future<void> saveCategory(WalletCategory category) => change((d) {
    if (d.categories.any(
      (c) =>
          c.name == category.name &&
          c.type == category.type &&
          c.id != category.id,
    )) {
      throw const FormatException('分类名称已存在');
    }
    d.categories.add(category);
  });
  Future<void> deleteCategory(WalletCategory c) => change((d) {
    if (d.transactions.any((t) => t.category == c.name && t.type == c.type) ||
        d.quickEntries.any((q) => q.category == c.name && q.type == c.type)) {
      throw const FormatException('此分类正在被账单或快捷交易使用');
    }
    if (d.categories.where((x) => x.type == c.type).length <= 1) {
      throw const FormatException('至少保留一个分类');
    }
    d.categories.removeWhere((x) => x.id == c.id);
  });
  void setAiStatus(String? status) {
    aiStatus = status;
    notifyListeners();
  }

  void log(String type, String text) {
    debugLogs.insert(0, {
      'time': DateTime.now().toIso8601String(),
      'type': type,
      'text': text,
    });
    if (debugLogs.length > 100) debugLogs.removeLast();
    notifyListeners();
  }

  List<Json> get patterns {
    final range = DateRange(
      DateTime.now().subtract(const Duration(days: 30)),
      DateTime.now().add(const Duration(seconds: 1)),
    );
    final txs = query(range: range, type: TxType.expense);
    final grouped = <String, List<LedgerTx>>{};
    for (final t in txs) {
      grouped.putIfAbsent(t.category, () => []).add(t);
    }
    return grouped.entries
        .where((e) => e.value.length >= 3)
        .map(
          (e) => {
            'title': '${e.key} · ${e.value.length} 笔',
            'description':
                '近 30 天合计 ${money(e.value.fold<int>(0, (sum, t) => sum + t.amount))}',
            'category': e.key,
          },
        )
        .toList();
  }

  List<Json> get suggestions {
    final month = DateRange.forPeriod(Period.month, DateTime.now());
    final budget = (_data.settings['budget'] as num? ?? 0).toInt();
    final spend = total(TxType.expense, range: month);
    final result = <Json>[];
    if (activeAccounts.isEmpty) {
      result.add({
        'id': 'accounts',
        'title': '先添加一个账户',
        'text': '从现金、微信或银行卡开始，让每一笔钱都有去处。',
        'action': 'assets',
      });
    }
    if (_data.settings['budgetReminder'] != false &&
        budget > 0 &&
        spend >= budget * .8) {
      result.add({
        'id': 'budget-${dayKey(month.start)}',
        'title': spend > budget ? '本月支出已超过预算' : '本月预算已使用超过 80%',
        'text': '已支出 ${money(spend)}，预算 ${money(budget)}。',
        'action': 'stats',
      });
    }
    for (final a in activeAccounts.where(
      (a) =>
          _data.settings['repaymentReminder'] != false &&
          a.category == 'credit' &&
          balance(a) < 0 &&
          a.repaymentDay != null,
    )) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final due = DateTime(
        now.year,
        now.month + (now.day > a.repaymentDay! ? 1 : 0),
        a.repaymentDay!,
      );
      if (due.difference(today).inDays <= 3) {
        result.add({
          'id': 'repay-${a.id}-${due.year}-${due.month}',
          'title': '${a.name} 还款日将至',
          'text': '${due.month}月${due.day}日还款，当前欠款 ${money(-balance(a))}。',
          'action': 'assets',
        });
      }
    }
    return result
        .where(
          (s) => !(_data.agent['dismissedSuggestions'] as List? ?? []).contains(
            s['id'],
          ),
        )
        .toList();
  }
}

WalletData demoData() {
  final now = DateTime.now();
  final d = WalletData(
    profile: {'name': '小余', 'email': 'hello@example.com', 'avatar': '🌿'},
    settings: {'visible': true, 'theme': 'light', 'budget': 500000},
  );
  d.accounts = [
    const WalletAccount(
      id: 'bank',
      name: '招商银行',
      category: 'funds',
      subType: 'bank_card',
      icon: 'account_balance',
      color: '#F5B85B',
      openingBalance: 2432600,
    ),
    const WalletAccount(
      id: 'wechat',
      name: '微信钱包',
      category: 'funds',
      subType: 'wechat',
      icon: 'chat',
      color: '#58C5AB',
      openingBalance: 186800,
    ),
    const WalletAccount(
      id: 'credit',
      name: '我的信用卡',
      category: 'credit',
      subType: 'credit_card',
      icon: 'credit_card',
      color: '#A78BFA',
      openingBalance: -235000,
      creditLimit: 2000000,
      billingDay: 5,
      repaymentDay: 25,
    ),
  ];
  final samples = [
    ('午间简餐', 3200, '餐饮', 'restaurant'),
    ('地铁通勤', 600, '交通', 'directions_car'),
    ('咖啡时间', 2800, '餐饮', 'restaurant'),
    ('生活用品', 12850, '购物', 'shopping_bag'),
    ('电影之夜', 6800, '娱乐', 'movie'),
    ('超市采购', 21680, '购物', 'shopping_bag'),
    ('晚餐', 5600, '餐饮', 'restaurant'),
    ('通勤打车', 2400, '交通', 'directions_car'),
  ];
  for (var i = 0; i < samples.length; i++) {
    final s = samples[i];
    d.transactions.add(
      LedgerTx(
        id: 'demo-$i',
        title: s.$1,
        amount: s.$2,
        date: DateTime(now.year, now.month, now.day - i ~/ 2, 12 + i % 6, 25),
        type: TxType.expense,
        category: s.$3,
        icon: s.$4,
        accountId: 'wechat',
      ),
    );
  }
  d.transactions.add(
    LedgerTx(
      id: 'salary',
      title: '本月工资',
      amount: 1200000,
      date: DateTime(now.year, now.month, 1, 9),
      type: TxType.income,
      category: '工资',
      icon: 'work',
      accountId: 'bank',
    ),
  );
  d.quickEntries = [
    const QuickEntry(
      id: 'q1',
      title: '早餐',
      type: TxType.expense,
      category: '餐饮',
      icon: 'restaurant',
      amount: 1200,
      accountId: 'wechat',
    ),
    const QuickEntry(
      id: 'q2',
      title: '交通',
      type: TxType.expense,
      category: '交通',
      icon: 'directions_car',
      amount: 600,
    ),
    const QuickEntry(
      id: 'q3',
      title: '咖啡',
      type: TxType.expense,
      category: '餐饮',
      icon: 'local_cafe',
      amount: 2800,
      accountId: 'wechat',
    ),
    const QuickEntry(
      id: 'q4',
      title: '转账',
      type: TxType.transfer,
      category: '转账',
      icon: 'swap_horiz',
      fromId: 'bank',
      toId: 'wechat',
    ),
  ];
  d.goals = [
    {
      'id': 'g1',
      'description': '攒下一笔旅行基金',
      'targetCents': 1000000,
      'status': 'active',
      'createdAt': now.toIso8601String(),
    },
  ];
  return d;
}
