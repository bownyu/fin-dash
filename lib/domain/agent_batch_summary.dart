import 'models.dart';

String agentActionGroup(Json a) {
  final next = Json.from(a['desired']);
  final old = a['before']['value'] is Map
      ? Json.from(a['before']['value'])
      : <String, dynamic>{};
  if (a['kind'] == 'budget') return '调整月预算';
  if (a['kind'] == 'account') {
    return old.isEmpty
        ? '新增账户'
        : a['input'].containsKey('currentBalanceCents')
        ? '校正账户余额'
        : '调整账户设置';
  }
  if (old.isEmpty) return '新增${LedgerTx.fromJson(next).type.label}账单';
  final changed = next.keys
      .where((k) => !['id', 'categoryId'].contains(k) && next[k] != old[k])
      .toSet();
  if (changed.length == 1 && changed.contains('category')) {
    return '分类：${old['category']} → ${next['category']}';
  }
  if (changed.contains('amountCents') ||
      changed.contains('type') ||
      changed.contains('accountId') ||
      changed.contains('transferFromId') ||
      changed.contains('transferToId')) {
    return '调整账单金额／账户';
  }
  if (changed.contains('date')) return '调整账单时间（影响统计归期）';
  return '调整账单信息';
}

Map<String, int> agentBatchGroups(List<Json> items) {
  final groups = <String, int>{};
  for (final a in items) {
    groups.update(agentActionGroup(a), (n) => n + 1, ifAbsent: () => 1);
  }
  return groups;
}

List<String> agentBatchImpact(
  List<Json> items,
  String Function(String) accountName,
) {
  final effects = <String, int>{};
  var changedDate = false, changedAmounts = false, newTransactions = 0;
  final budgets = <String>[];
  for (final a in items) {
    final next = Json.from(a['desired']);
    final old = a['before']['value'];
    if (a['kind'] == 'budget') {
      budgets.add('月预算：${money(old ?? 0)} → ${money(next['amountCents'])}');
    } else if (a['kind'] == 'account') {
      final delta =
          (next['openingBalance'] as int) -
          (old?['openingBalance'] as int? ?? 0);
      effects.update(a['targetId'], (n) => n + delta, ifAbsent: () => delta);
    } else if (a['kind'] == 'transaction') {
      final tx = LedgerTx.fromJson(next);
      final previous = old == null ? null : LedgerTx.fromJson(Json.from(old));
      if (previous == null) newTransactions++;
      changedAmounts |=
          previous != null &&
          (previous.amount != tx.amount || previous.type != tx.type);
      changedDate |= previous != null && previous.date != tx.date;
      final ids = {
        tx.accountId,
        tx.fromId,
        tx.toId,
        previous?.accountId,
        previous?.fromId,
        previous?.toId,
      }..remove(null);
      for (final id in ids) {
        final effect = tx.effectOn(id!) - (previous?.effectOn(id) ?? 0);
        effects.update(id, (n) => n + effect, ifAbsent: () => effect);
      }
    }
  }
  return [
    if (newTransactions > 0) '新增 $newTransactions 笔账单',
    if (changedAmounts) '包含金额或收支方向调整',
    if (changedDate) '包含时间调整，相关月份统计会变化',
    ...budgets,
    ...effects.entries
        .where((e) => e.value != 0)
        .map(
          (e) =>
              '${accountName(e.key)}余额 ${e.value > 0 ? '+' : ''}${money(e.value)}',
        ),
    if (items.isNotEmpty &&
        budgets.isEmpty &&
        effects.values.every((e) => e == 0))
      '账户余额不变',
  ];
}

String agentBatchScope(List<Json> items) {
  final dates =
      items
          .where((a) => a['kind'] == 'transaction')
          .map((a) => DateTime.parse(a['desired']['date']).toLocal())
          .toList()
        ..sort();
  String date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  return dates.isEmpty
      ? '本任务准备的账户与预算变更'
      : '账单范围：${date(dates.first)} 至 ${date(dates.last)}';
}
