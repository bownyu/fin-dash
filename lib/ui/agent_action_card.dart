import 'package:flutter/material.dart';
import '../domain/agent_action_summary.dart';
import '../domain/models.dart';
import 'design.dart';

class AgentActionCard extends StatefulWidget {
  final Json action;
  const AgentActionCard({super.key, required this.action});

  @override
  State<AgentActionCard> createState() => _AgentActionCardState();
}

class _AgentActionCardState extends State<AgentActionCard> {
  bool busy = false;
  String? error;

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => error = e is FormatException ? e.message : '操作未保存，请重试。');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void details() {
    final store = AppScope.storeOf(
      context,
      domains: const {
        WalletDomain.tasks,
        WalletDomain.ledger,
        WalletDomain.preferences,
      },
    );
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .75,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Text('变更详情', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            for (final line in agentActionPreview(
              widget.action,
              (id) => store.account(id)?.name ?? id,
            ))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(line),
              ),
            if ('${widget.action['summary'] ?? ''}'.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '${widget.action['summary']}',
                style: const TextStyle(color: muted),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => RuntimeBuilder(builder: buildContent);
  Widget buildContent(BuildContext context) {
    final a = widget.action;
    final ai = AppScope.aiOf(context);
    final store = AppScope.storeOf(
      context,
      domains: const {
        WalletDomain.tasks,
        WalletDomain.ledger,
        WalletDomain.preferences,
      },
    );
    final disabled = busy || ai.busy;
    final pending = a['status'] == 'pending';
    final summary =
        a['displaySummary'] as String? ??
        agentActionSummary(a, (id) => store.account(id)?.name ?? id);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: pending
            ? primary.withValues(alpha: .05)
            : Theme.of(context).colorScheme.surface,
        border: Border.all(
          color: pending
              ? primary.withValues(alpha: .25)
              : muted.withValues(alpha: .2),
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(switch (a['status']) {
            'pending' => '请确认本次变更',
            'applied' => '已执行',
            'rejected' => '已拒绝',
            'undone' => '已撤销',
            _ => '操作记录',
          }, style: TextStyle(fontSize: 12, color: pending ? primary : muted)),
          const SizedBox(height: 6),
          Text(summary, style: const TextStyle(fontSize: 14, height: 1.5)),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!, style: const TextStyle(color: coral, fontSize: 13)),
          ],
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (pending) ...[
                FilledButton(
                  onPressed: disabled
                      ? null
                      : () => run(() => ai.actions.apply(a['id'])),
                  child: Text(busy ? '保存中…' : '确认执行'),
                ),
                TextButton(
                  onPressed: disabled
                      ? null
                      : () => run(() => ai.actions.reject(a['id'])),
                  child: const Text('拒绝'),
                ),
              ],
              if (a['status'] == 'applied')
                TextButton(
                  onPressed: disabled
                      ? null
                      : () => run(() => ai.actions.undo(a['id'])),
                  child: const Text('撤销本次操作'),
                ),
              TextButton(onPressed: details, child: const Text('查看详情')),
            ],
          ),
        ],
      ),
    );
  }
}

List<String> agentActionPreview(
  Json action,
  String Function(String) accountName,
) {
  final desired = Json.from(action['desired']);
  final before = Json.from(action['before']);
  if (action['kind'] == 'budget') {
    return [
      '月预算：${money(before['value'] ?? 0)} → ${money(desired['amountCents'])}',
    ];
  }
  final old = before['value'] == null
      ? <String, dynamic>{}
      : Json.from(before['value']);
  const labels = {
    'name': '账户名称',
    'category': '分类',
    'subType': '账户子类型',
    'note': '备注',
    'creditLimitCents': '信用额度',
    'billingDay': '账单日',
    'repaymentDay': '还款日',
    'includeInTotal': '计入资产',
    'archived': '归档',
    'countBillingDayInPrevious': '账单日归上期',
    'title': '名称 / 商户',
    'amountCents': '金额',
    'type': '收支方向',
    'date': '交易时间',
    'accountId': '账户',
    'transferFromId': '转出账户',
    'transferToId': '转入账户',
  };
  String display(String key, dynamic v) {
    if (v == null || v == '') return '未设置';
    if (key.endsWith('Cents')) return money(v as int);
    if (v is bool) return v ? '是' : '否';
    if (key.endsWith('Id')) return accountName(v.toString());
    if (key == 'type') {
      return switch (v) {
        'expense' => '支出',
        'income' => '收入',
        _ => '转账',
      };
    }
    if (key == 'category' && accountGroups.containsKey(v)) {
      return accountGroups[v]!;
    }
    if (key == 'subType') {
      for (final presets in accountPresets.values) {
        for (final p in presets) {
          if (p.$1 == v) return p.$2;
        }
      }
    }
    return v.toString();
  }

  final result = <String>[
    if (old.isEmpty) '新增记录',
    if (action['kind'] == 'account' && old.isNotEmpty) '目标账户：${old['name']}',
  ];
  for (final key in labels.keys) {
    if (desired.containsKey(key) && desired[key] != old[key]) {
      result.add(
        '${labels[key]}：${display(key, old[key])} → ${display(key, desired[key])}',
      );
    } else if (action['kind'] == 'transaction' &&
        desired[key] != null &&
        desired[key] != '' &&
        key != 'note') {
      result.add('${labels[key]}：${display(key, desired[key])}');
    }
  }
  if (action['kind'] == 'transaction') {
    final nextTx = LedgerTx.fromJson(desired);
    final previousTx = old.isEmpty ? null : LedgerTx.fromJson(old);
    final ids = {
      nextTx.accountId,
      nextTx.fromId,
      nextTx.toId,
      previousTx?.accountId,
      previousTx?.fromId,
      previousTx?.toId,
    }..remove(null);
    for (final id in ids) {
      final effect = nextTx.effectOn(id!) - (previousTx?.effectOn(id) ?? 0);
      if (effect != 0) {
        result.add(
          '${accountName(id)}余额影响：${effect > 0 ? '+' : ''}${money(effect)}',
        );
      }
    }
  }
  final input = Json.from(action['input']);
  if (action['kind'] == 'account' && input.containsKey('currentBalanceCents')) {
    final delta = (before['transactions'] as List).fold<int>(
      0,
      (sum, t) =>
          sum + LedgerTx.fromJson(Json.from(t)).effectOn(action['targetId']),
    );
    final previous = (old['openingBalance'] as int? ?? 0) + delta;
    result.add(
      '当前余额：${money(previous)} → ${money(input['currentBalanceCents'])}',
    );
    result.add(
      '余额校正差额：${money((input['currentBalanceCents'] as int) - previous)}；请确认这是当前余额。',
    );
  }
  if (result.isEmpty) result.add('字段与当前记录相同');
  return result;
}
