import 'dart:convert';
import 'dart:math';

typedef Json = Map<String, dynamic>;
String newId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(0x7fffffff)}';

// Money is stored in integer cents, never accumulated as floating point values.
int parseMoney(String text, {bool signed = false}) {
  final clean = text.trim().replaceAll(',', '').replaceAll('¥', '');
  if (!RegExp(
    signed ? r'^-?\d+(\.\d{1,2})?$' : r'^\d+(\.\d{1,2})?$',
  ).hasMatch(clean)) {
    throw const FormatException('请输入有效金额，最多两位小数');
  }
  final parts = clean.replaceAll('-', '').split('.');
  final cents =
      int.parse(parts[0]) * 100 +
      int.parse(parts.length == 1 ? '0' : parts[1].padRight(2, '0'));
  if (cents > 999999999999) throw const FormatException('金额过大');
  return clean.startsWith('-') ? -cents : cents;
}

int legacyMoney(dynamic value) {
  if (value == null) return 0;
  final number = num.tryParse('$value');
  if (number == null || !number.isFinite || number.abs() > 9999999999.99) {
    throw const FormatException('备份包含无效金额');
  }
  return (number * 100).round();
}

String money(int cents, {bool symbol = true}) {
  final whole = (cents.abs() ~/ 100).toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '${cents < 0 ? '-' : ''}${symbol ? '¥ ' : ''}$whole.${(cents.abs() % 100).toString().padLeft(2, '0')}';
}

String moneyInput(int cents) =>
    '${cents < 0 ? '-' : ''}${cents.abs() ~/ 100}.${(cents.abs() % 100).toString().padLeft(2, '0')}';
String dayKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
DateTime localDate(dynamic raw) => raw is num
    ? DateTime.fromMillisecondsSinceEpoch(raw.toInt())
    : DateTime.parse('$raw').toLocal();

enum TxType { expense, income, transfer }

enum Period { day, week, month, year }

extension TxLabels on TxType {
  String get label => switch (this) {
    TxType.expense => '支出',
    TxType.income => '收入',
    TxType.transfer => '转账',
  };
}

extension PeriodLabels on Period {
  String get label => switch (this) {
    Period.day => '日',
    Period.week => '周',
    Period.month => '月',
    Period.year => '年',
  };
}

class DateRange {
  final DateTime start, end;
  const DateRange(this.start, this.end);
  bool contains(DateTime date) => !date.isBefore(start) && date.isBefore(end);
  factory DateRange.forPeriod(Period period, DateTime anchor) {
    final day = DateTime(anchor.year, anchor.month, anchor.day);
    return switch (period) {
      Period.day => DateRange(day, DateTime(day.year, day.month, day.day + 1)),
      Period.week => DateRange(
        DateTime(day.year, day.month, day.day - day.weekday + 1),
        DateTime(day.year, day.month, day.day - day.weekday + 8),
      ),
      Period.month => DateRange(
        DateTime(day.year, day.month),
        DateTime(day.year, day.month + 1),
      ),
      Period.year => DateRange(DateTime(day.year), DateTime(day.year + 1)),
    };
  }
  static DateTime shift(Period period, DateTime date, int delta) =>
      switch (period) {
        Period.day => DateTime(date.year, date.month, date.day + delta),
        Period.week => DateTime(date.year, date.month, date.day + 7 * delta),
        Period.month => DateTime(date.year, date.month + delta),
        Period.year => DateTime(date.year + delta),
      };
}

class WalletAccount {
  final String id, name, category, subType, icon, color, note;
  final int openingBalance, creditLimit;
  final int? billingDay, repaymentDay;
  final bool includeInTotal, archived, countBillingDayInPrevious;
  const WalletAccount({
    required this.id,
    required this.name,
    required this.category,
    required this.subType,
    this.icon = 'account_balance_wallet',
    this.color = '#137FEC',
    this.note = '',
    this.openingBalance = 0,
    this.creditLimit = 0,
    this.billingDay,
    this.repaymentDay,
    this.includeInTotal = true,
    this.archived = false,
    this.countBillingDayInPrevious = false,
  });
  Json toJson() => {
    'id': id,
    'name': name,
    'category': category,
    'subType': subType,
    'icon': icon,
    'color': color,
    'note': note,
    'openingBalance': openingBalance,
    'creditLimitCents': creditLimit,
    'billingDay': billingDay,
    'repaymentDay': repaymentDay,
    'includeInTotal': includeInTotal,
    'archived': archived,
    'countBillingDayInPrevious': countBillingDayInPrevious,
  };
  factory WalletAccount.fromJson(Json j) => WalletAccount(
    id: j['id'],
    name: j['name'],
    category: j['category'],
    subType: j['subType'],
    icon: j['icon'] ?? 'account_balance_wallet',
    color: j['color'] ?? '#137FEC',
    note: j['note'] ?? '',
    openingBalance: j['openingBalance'] ?? 0,
    creditLimit: j['creditLimitCents'] ?? 0,
    billingDay: j['billingDay'],
    repaymentDay: j['repaymentDay'],
    includeInTotal: j['includeInTotal'] != false,
    archived: j['archived'] == true,
    countBillingDayInPrevious: j['countBillingDayInPrevious'] == true,
  );
  WalletAccount copyWith({int? openingBalance, bool? archived}) =>
      WalletAccount.fromJson({
        ...toJson(),
        'openingBalance': ?openingBalance,
        'archived': ?archived,
      });
}

class LedgerTx {
  final String id, title, category, icon, note;
  final int amount;
  final DateTime date;
  final TxType type;
  final String? accountId, fromId, toId;
  const LedgerTx({
    required this.id,
    required this.title,
    required this.amount,
    required this.date,
    required this.type,
    required this.category,
    this.icon = 'receipt_long',
    this.note = '',
    this.accountId,
    this.fromId,
    this.toId,
  });
  Json toJson() => {
    'id': id,
    'title': title,
    'amountCents': amount,
    'date': date.toIso8601String(),
    'type': type.name,
    'category': category,
    'icon': icon,
    'note': note,
    'accountId': accountId,
    'transferFromId': fromId,
    'transferToId': toId,
  };
  factory LedgerTx.fromJson(Json j, {bool legacy = false}) => LedgerTx(
    id: j['id'],
    title: j['title'] ?? '未命名账单',
    amount: legacy ? legacyMoney(j['amount']) : j['amountCents'],
    date: localDate(j['date']),
    type: TxType.values.byName(j['type']),
    category: j['category'] ?? '其他',
    icon: j['icon'] ?? 'receipt_long',
    note: j['note'] ?? (legacy ? j['subtitle'] ?? '' : ''),
    accountId: j['accountId'],
    fromId: j['transferFromId'],
    toId: j['transferToId'],
  );
  int effectOn(String account) => switch (type) {
    TxType.expense => accountId == account ? -amount : 0,
    TxType.income => accountId == account ? amount : 0,
    TxType.transfer =>
      (toId == account ? amount : 0) - (fromId == account ? amount : 0),
  };
}

class WalletCategory {
  final String id, name, icon, color;
  final TxType type;
  const WalletCategory(this.id, this.name, this.icon, this.color, this.type);
  Json toJson() => {
    'id': id,
    'name': name,
    'icon': icon,
    'color': color,
    'type': type.name,
  };
  factory WalletCategory.fromJson(Json j) => WalletCategory(
    j['id'],
    j['name'],
    j['icon'],
    j['color'],
    TxType.values.byName(j['type']),
  );
}

class QuickEntry {
  final String id, title, category, icon;
  final TxType type;
  final int? amount;
  final String? accountId, fromId, toId;
  const QuickEntry({
    required this.id,
    required this.title,
    required this.type,
    required this.category,
    required this.icon,
    this.amount,
    this.accountId,
    this.fromId,
    this.toId,
  });
  Json toJson() => {
    'id': id,
    'title': title,
    'type': type.name,
    'category': category,
    'icon': icon,
    'amountCents': amount,
    'accountId': accountId,
    'fromAccountId': fromId,
    'toAccountId': toId,
  };
  factory QuickEntry.fromJson(Json j, {bool legacy = false}) => QuickEntry(
    id: j['id'],
    title: j['title'],
    type: TxType.values.byName(j['type'] ?? 'expense'),
    category: j['category'] ?? '其他',
    icon: j['icon'] ?? 'bolt',
    amount: legacy
        ? (j['amount'] == null ? null : legacyMoney(j['amount']))
        : j['amountCents'],
    accountId: j['accountId'],
    fromId: j['fromAccountId'],
    toId: j['toAccountId'],
  );
}

class WalletData {
  List<WalletAccount> accounts;
  List<LedgerTx> transactions;
  List<WalletCategory> categories;
  List<QuickEntry> quickEntries;
  Json profile, settings, agent, providerConfigs, extras;
  List<Json> goals, chats;
  WalletData({
    List<WalletAccount>? accounts,
    List<LedgerTx>? transactions,
    List<WalletCategory>? categories,
    List<QuickEntry>? quickEntries,
    Json? profile,
    Json? settings,
    Json? agent,
    Json? providerConfigs,
    Json? extras,
    List<Json>? goals,
    List<Json>? chats,
  }) : accounts = accounts ?? [],
       transactions = transactions ?? [],
       categories = categories ?? defaultCategories(),
       quickEntries = quickEntries ?? [],
       profile = profile ?? {},
       settings = settings ?? {'visible': true, 'theme': 'light', 'budget': 0},
       agent = agent ?? defaultAgent(),
       providerConfigs = providerConfigs ?? {},
       extras = extras ?? {},
       goals = goals ?? [],
       chats = chats ?? [];
  Json toJson() => {
    'format': 'findash-flutter',
    'schema': 1,
    'accounts': accounts.map((a) => a.toJson()).toList(),
    'transactions': transactions.map((t) => t.toJson()).toList(),
    'categories': categories.map((c) => c.toJson()).toList(),
    'quickEntries': quickEntries.map((q) => q.toJson()).toList(),
    'profile': profile,
    'settings': settings,
    'agent': agent,
    'providerConfigs': providerConfigs,
    'goals': goals,
    'chats': chats,
    'extras': extras,
  };
  factory WalletData.fromJson(Json j) => WalletData(
    accounts: (j['accounts'] as List)
        .map((a) => WalletAccount.fromJson(Json.from(a)))
        .toList(),
    transactions: (j['transactions'] as List)
        .map((t) => LedgerTx.fromJson(Json.from(t)))
        .toList(),
    categories: (j['categories'] as List)
        .map((c) => WalletCategory.fromJson(Json.from(c)))
        .toList(),
    quickEntries: (j['quickEntries'] as List)
        .map((q) => QuickEntry.fromJson(Json.from(q)))
        .toList(),
    profile: Json.from(j['profile'] ?? {}),
    settings: Json.from(j['settings'] ?? {}),
    agent: Json.from(j['agent'] ?? defaultAgent()),
    providerConfigs: Json.from(j['providerConfigs'] ?? {}),
    extras: Json.from(j['extras'] ?? {}),
    goals: (j['goals'] as List? ?? []).map((g) => Json.from(g)).toList(),
    chats: (j['chats'] as List? ?? []).map((c) => Json.from(c)).toList(),
  );
  WalletData clone() => WalletData.fromJson(jsonDecode(jsonEncode(toJson())));
}

Json defaultAgent() => {
  'name': 'FinDash 顾问',
  'tone': 'professional',
  'focusAreas': <String>[],
  'customPrompt': '',
  'tags': <String>[],
  'insights': <String>[],
  'description': '',
  'preferences': <String>[],
  'memories': <Json>[],
  'events': <Json>[],
  'dismissedSuggestions': <String>[],
};
List<WalletCategory> defaultCategories() => [
  const WalletCategory('e1', '餐饮', 'restaurant', '#FF8B7B', TxType.expense),
  const WalletCategory('e2', '交通', 'directions_car', '#4ECDC4', TxType.expense),
  const WalletCategory('e3', '购物', 'shopping_bag', '#A78BFA', TxType.expense),
  const WalletCategory('e4', '住房', 'home', '#F5B85B', TxType.expense),
  const WalletCategory('e5', '娱乐', 'movie', '#EC89BF', TxType.expense),
  const WalletCategory('e6', '水电', 'bolt', '#FBBF24', TxType.expense),
  const WalletCategory(
    'e7',
    '医疗',
    'medical_services',
    '#58C5AB',
    TxType.expense,
  ),
  const WalletCategory('e8', '其他', 'more_horiz', '#94A3B8', TxType.expense),
  const WalletCategory(
    'i1',
    '工资',
    'account_balance_wallet',
    '#58C5AB',
    TxType.income,
  ),
  const WalletCategory(
    'i2',
    '生活费',
    'family_restroom',
    '#F5B85B',
    TxType.income,
  ),
  const WalletCategory('i3', '收红包', 'card_giftcard', '#FF8B7B', TxType.income),
  const WalletCategory('i4', '外快', 'work', '#A78BFA', TxType.income),
  const WalletCategory('i5', '股票基金', 'trending_up', '#6BB5FF', TxType.income),
  const WalletCategory('i6', '其它', 'more_horiz', '#94A3B8', TxType.income),
];
const accountGroups = {
  'funds': '资金账户',
  'credit': '信用账户',
  'recharge': '充值账户',
  'investment': '投资理财',
};
const accountPresets = <String, List<(String, String, String)>>{
  'funds': [
    ('cash', '现金', 'payments'),
    ('wechat', '微信', 'chat'),
    ('wechat_balance', '微信零钱通', 'savings'),
    ('alipay', '支付宝', 'account_balance_wallet'),
    ('alipay_yuebao', '余额宝', 'savings'),
    ('unionpay', '云闪付', 'credit_card'),
    ('bank_card', '银行卡', 'account_balance'),
    ('housing_fund', '公积金', 'home'),
    ('qq_wallet', 'QQ钱包', 'chat'),
    ('jd_finance', '京东金融', 'store'),
    ('medical_insurance', '医保', 'medical_services'),
    ('other_funds', '其它资金', 'more_horiz'),
  ],
  'credit': [
    ('credit_card', '信用卡', 'credit_card'),
    ('huabei', '花呗', 'spa'),
    ('jiebei', '借呗', 'account_balance'),
    ('jd_baitiao', '京东白条', 'receipt_long'),
    ('meituan_pay', '美团月付', 'restaurant'),
    ('douyin_pay', '抖音月付', 'movie'),
    ('wechat_fenfu', '微信分付', 'chat'),
    ('other_credit', '其它信用', 'more_horiz'),
  ],
  'recharge': [
    ('phone_bill', '话费', 'phone_android'),
    ('utilities', '水电', 'bolt'),
    ('meal_card', '饭卡', 'restaurant'),
    ('deposit', '押金', 'lock'),
    ('transit_card', '公交卡', 'directions_bus'),
    ('membership_card', '会员卡', 'card_membership'),
    ('gas_card', '加油卡', 'local_gas_station'),
    ('other_recharge', '其它充值卡', 'more_horiz'),
  ],
  'investment': [
    ('stock', '股票', 'trending_up'),
    ('fund', '基金', 'pie_chart'),
    ('gold', '黄金', 'diamond'),
    ('forex', '外汇', 'currency_exchange'),
    ('futures', '期货', 'timeline'),
    ('bonds', '债券', 'receipt_long'),
    ('fixed_income', '固定收益', 'savings'),
    ('crypto', '加密货币', 'currency_bitcoin'),
    ('other_investment', '其它理财', 'more_horiz'),
  ],
};
