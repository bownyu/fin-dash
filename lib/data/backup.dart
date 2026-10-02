import 'dart:convert';
import '../domain/models.dart';

class ImportPreview {
  final WalletData data;
  final List<String> notes;
  final bool legacy;
  ImportPreview(this.data, this.notes, this.legacy);
}

dynamic removeSecrets(dynamic value) {
  if (value is Map) {
    return {
      for (final e in value.entries)
        if (!RegExp(
          r'api.?key|password|authorization|secret|token',
          caseSensitive: false,
        ).hasMatch('${e.key}'))
          '${e.key}': removeSecrets(e.value),
    };
  }
  if (value is List) return value.map(removeSecrets).toList();
  return value;
}

ImportPreview parseBackup(String text) {
  if (text.length > 30 * 1024 * 1024) {
    throw const FormatException('备份文件超过 30 MB');
  }
  dynamic decoded;
  try {
    decoded = jsonDecode(text.trim().replaceFirst('\uFEFF', ''));
  } catch (_) {
    try {
      decoded = jsonDecode(
        utf8.decode(base64Decode(text.replaceAll(RegExp(r'\s'), ''))),
      );
    } catch (_) {
      throw const FormatException('不是有效的 JSON 或 Base64 备份');
    }
  }
  if (decoded is! Map) throw const FormatException('备份结构不正确');
  final j = Json.from(decoded);
  if (j['format'] == 'findash-flutter') {
    if (j['schema'] != 1) throw const FormatException('此备份版本暂不支持');
    final data = WalletData.fromJson(j);
    validateWallet(data);
    return ImportPreview(data, [
      '将恢复账户、账单、快捷交易、目标、顾问记忆与对话。API 密钥需重新填写。',
    ], false);
  }
  if (j['version'] == null || j['transactions'] is! List) {
    throw const FormatException('无法识别此 wallet 备份');
  }
  final notes = <String>['旧版当前余额会被保留，导入历史账单不会再次扣款。'];
  final transactions = (j['transactions'] as List)
      .map((t) => LedgerTx.fromJson(Json.from(t), legacy: true))
      .toList();
  final ids = (j['accounts'] as List? ?? []).map((a) => a['id']).toSet();
  var missing = 0;
  for (var i = 0; i < transactions.length; i++) {
    final t = transactions[i];
    final raw = t.toJson();
    for (final key in ['accountId', 'transferFromId', 'transferToId']) {
      if (raw[key] != null && !ids.contains(raw[key])) {
        raw[key] = null;
        missing++;
      }
    }
    transactions[i] = LedgerTx.fromJson(raw);
  }
  if (missing > 0) notes.add('$missing 个不存在的账户关联已标记为未关联，账单内容保留。');
  final accounts = (j['accounts'] as List? ?? []).map((raw) {
    final a = Json.from(raw);
    if (a['currency'] != null && a['currency'] != 'CNY') {
      throw const FormatException('当前仅支持人民币账户，请先转换外币备份');
    }
    final current = legacyMoney(a['balance']);
    final delta = transactions.fold<int>(
      0,
      (sum, t) => sum + t.effectOn(a['id']),
    );
    return WalletAccount(
      id: a['id'],
      name: a['name'],
      category: a['category'],
      subType: a['subType'],
      openingBalance: current - delta,
      creditLimit: legacyMoney(a['creditLimit']),
      icon: a['icon'] ?? 'account_balance_wallet',
      color: a['color'] ?? '#137FEC',
      note: a['note'] ?? '',
      billingDay: a['billingDay'],
      repaymentDay: a['repaymentDay'],
      includeInTotal: a['includeInTotal'] != false,
      countBillingDayInPrevious: a['countBillingDayInPrevious'] == true,
    );
  }).toList();
  final local = Json.from(j['localStorage'] ?? {});
  final parsedLocal = <String, dynamic>{};
  for (final e in local.entries) {
    try {
      parsedLocal[e.key] = e.value is String ? jsonDecode(e.value) : e.value;
    } catch (_) {
      parsedLocal[e.key] = e.value;
    }
  }
  final v2 = Json.from(j['agentV2'] ?? {});
  final self = Json.from(
    v2['agentSelfModel'] ?? parsedLocal['agent_v2_self_model'] ?? {},
  );
  final cognition = Json.from(
    v2['userCognition'] ?? parsedLocal['agent_v2_user_cognition'] ?? {},
  );
  final persona = Json.from(parsedLocal['ai_persona_config'] ?? {});
  final agent = {
    ...defaultAgent(),
    ...persona,
    'name':
        persona['name'] ??
        self['identity']?['name'] ??
        self['name'] ??
        'FinDash 顾问',
    'description':
        cognition['profileNarrative'] ??
        cognition['profileDescription'] ??
        cognition['description'] ??
        '',
    'tags': cognition['tags'] ?? [],
    'insights': cognition['keyInsights'] ?? [],
    'preferences': self['learnedBehaviors'] is List
        ? (self['learnedBehaviors'] as List)
              .where((b) => b['isActive'] != false)
              .map((b) => b['behavior'])
              .whereType<String>()
              .toList()
        : self['learnedPreferences'] ?? [],
    'memories': parsedLocal['agent_hard_memory'] ?? [],
    'events': v2['memoryEvents'] ?? parsedLocal['agent_v2_memory_events'] ?? [],
  };
  final configs = <String, dynamic>{};
  for (final provider in ['zhipu', 'nvidia', 'custom']) {
    if (parsedLocal['ai_config_$provider'] is Map) {
      configs[provider] = removeSecrets(parsedLocal['ai_config_$provider']);
    }
  }
  if (configs.isNotEmpty) notes.add('AI 提供商与模型设置已迁移，API 密钥请在设置中重新填写。');
  final data = WalletData(
    accounts: accounts,
    transactions: transactions,
    profile: Json.from(j['user'] ?? {}),
    quickEntries: (j['quickTransactions'] ?? j['quickExpenses'] ?? [])
        .map<QuickEntry>((q) => QuickEntry.fromJson(Json.from(q), legacy: true))
        .toList(),
    settings: {
      'visible': parsedLocal['balance_visible'] != false,
      'theme': 'dark',
      'budget': 0,
      'provider': parsedLocal['ai_current_provider'] ?? 'zhipu',
    },
    agent: agent,
    providerConfigs: configs,
    extras: Json.from(
      removeSecrets({'legacyLocalStorage': parsedLocal, 'agentV2': v2}),
    ),
  );
  data.profile['name'] ??= data.profile['username'];
  for (final t in transactions) {
    if (t.type != TxType.transfer &&
        !data.categories.any((c) => c.name == t.category && c.type == t.type)) {
      data.categories.add(
        WalletCategory(newId(), t.category, t.icon, '#94A3B8', t.type),
      );
    }
  }
  validateWallet(data, allowUnlinked: true);
  return ImportPreview(data, notes, true);
}

void validateWallet(WalletData data, {bool allowUnlinked = true}) {
  void unique(Iterable<String> ids) {
    final list = ids.toList();
    if (list.any((s) => s.isEmpty) || list.toSet().length != list.length) {
      throw const FormatException('备份包含重复或空的记录 ID');
    }
  }

  unique(data.accounts.map((a) => a.id));
  unique(data.transactions.map((t) => t.id));
  unique(data.categories.map((c) => c.id));
  unique(data.quickEntries.map((q) => q.id));
  final ids = data.accounts.map((a) => a.id).toSet();
  for (final a in data.accounts) {
    if (a.name.trim().isEmpty ||
        !accountGroups.containsKey(a.category) ||
        a.creditLimit < 0 ||
        a.openingBalance.abs() > 999999999999) {
      throw const FormatException('账户信息不合法');
    }
    for (final day in [a.billingDay, a.repaymentDay]) {
      if (day != null && (day < 1 || day > 28)) {
        throw const FormatException('账单日与还款日必须为 1–28');
      }
    }
  }
  for (final t in data.transactions) {
    if (t.amount <= 0 || t.amount > 999999999999 || t.title.trim().isEmpty) {
      throw const FormatException('账单金额或名称不合法');
    }
    for (final id in [t.accountId, t.fromId, t.toId]) {
      if (id != null && !ids.contains(id)) {
        throw const FormatException('账单关联账户不存在');
      }
    }
    if (t.type == TxType.transfer && t.fromId != null && t.fromId == t.toId) {
      throw const FormatException('转出与转入账户不能相同');
    }
    if (!allowUnlinked &&
        ((t.type == TxType.transfer && (t.fromId == null || t.toId == null)) ||
            (t.type != TxType.transfer && t.accountId == null))) {
      throw const FormatException('请选择账单账户');
    }
  }
  for (final q in data.quickEntries) {
    if (q.title.trim().isEmpty || (q.amount != null && q.amount! <= 0)) {
      throw const FormatException('快捷交易信息不合法');
    }
  }
}
