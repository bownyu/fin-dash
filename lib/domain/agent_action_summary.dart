import 'package:intl/intl.dart';
import 'models.dart';

/// A short, factual review based on the validated proposal, not model prose.
String agentActionSummary(Json action, String Function(String) accountName) {
  final desired = Json.from(action['desired']);
  final before = Json.from(action['before']);
  if (action['kind'] == 'budget') {
    return '月预算：${money(before['value'] ?? 0)} → ${money(desired['amountCents'])}';
  }
  final old = before['value'] == null
      ? <String, dynamic>{}
      : Json.from(before['value']);
  if (action['kind'] == 'transaction') {
    final next = LedgerTx.fromJson(desired);
    final amount =
        old.isNotEmpty && old['amountCents'] != desired['amountCents']
        ? '${money(old['amountCents'])} → ${money(next.amount)}'
        : money(next.amount);
    final route = next.type == TxType.transfer
        ? '${accountName(next.fromId!)} → ${accountName(next.toId!)}'
        : accountName(next.accountId!);
    return '${old.isEmpty ? '新增' : '修改'}「${next.title}」：${next.type.label} $amount\n$route · ${DateFormat('yyyy-MM-dd HH:mm').format(next.date.toLocal())}';
  }
  final parts = <String>[];
  if (old.isEmpty) {
    parts.add('新增账户「${desired['name']}」');
  } else if (old['name'] != desired['name']) {
    parts.add('账户名称：${old['name']} → ${desired['name']}');
  }
  final input = Json.from(action['input']);
  if (input.containsKey('currentBalanceCents')) {
    final delta = (before['transactions'] as List).fold<int>(
      0,
      (sum, t) =>
          sum + LedgerTx.fromJson(Json.from(t)).effectOn(action['targetId']),
    );
    final previous = (old['openingBalance'] as int? ?? 0) + delta;
    parts.add(
      '${desired['name']}当前余额：${money(previous)} → ${money(input['currentBalanceCents'])}',
    );
  }
  if (old['creditLimitCents'] != desired['creditLimitCents'] &&
      (old.isNotEmpty || (desired['creditLimitCents'] as int) > 0)) {
    parts.add(
      '信用额度：${money(old['creditLimitCents'] ?? 0)} → ${money(desired['creditLimitCents'])}',
    );
  }
  const settings = {
    'category': '账户类型',
    'subType': '账户子类型',
    'note': '备注',
    'billingDay': '账单日',
    'repaymentDay': '还款日',
    'includeInTotal': '计入资产',
    'archived': '归档状态',
    'countBillingDayInPrevious': '账单归期',
  };
  final changed = settings.entries
      .where((e) => desired[e.key] != old[e.key])
      .toList();
  if (old.isNotEmpty && changed.isNotEmpty) {
    String display(String key, dynamic value) {
      if (value == null || value == '') return '未设置';
      if (value is bool) return value ? '是' : '否';
      if (key == 'category') return accountGroups[value] ?? '$value';
      if (key == 'subType') {
        for (final presets in accountPresets.values) {
          for (final p in presets) {
            if (p.$1 == value) return p.$2;
          }
        }
      }
      return '$value';
    }

    parts.add(
      '「${desired['name']}」：${changed.take(2).map((e) => e.key == 'note' ? '更新备注' : '${e.value} ${display(e.key, old[e.key])} → ${display(e.key, desired[e.key])}').join('；')}${changed.length > 2 ? '等 ${changed.length} 项设置' : ''}',
    );
  }
  return parts.isEmpty ? '更新账户「${desired['name']}」' : parts.join('\n');
}
