import 'dart:convert';
import '../data/wallet_store.dart';
import '../domain/models.dart';
import '../domain/agent_action_summary.dart';
import '../data/backup.dart';
import 'agent_input.dart';

/// Only the local review UI calls apply/undo. Neither is exposed as an AI tool.
class AgentActions {
  final WalletStore store;
  AgentActions(this.store);

  List<Json> get items => _items(store.data).reversed.toList();
  static List<Json> _items(WalletData d) =>
      (d.extras['agentActions'] as List? ?? [])
          .map((e) => Json.from(e as Map))
          .toList();

  Future<Json> propose(String kind, Json input) async {
    final args = Json.from(jsonDecode(jsonEncode(input)));
    Json? result;
    await store.change((d) {
      if (!['account', 'transaction', 'budget'].contains(kind)) {
        throw const FormatException('不支持的操作类型');
      }
      final actions = _items(d);
      for (final a in actions) {
        if (a['status'] == 'pending' &&
            a['kind'] == kind &&
            _same(a['input'], args)) {
          result = a;
          return;
        }
      }
      if (actions.where((a) => a['status'] == 'pending').length >= 100) {
        throw const FormatException('待确认操作已达 100 项，请先处理');
      }
      final id = args['id'] == null ? newId() : _text(args['id'], 'ID');
      final before = _state(d, kind, id);
      final after = _desired(d, kind, id, args);
      final trial = d.clone();
      _write(trial, kind, id, after);
      validateWallet(trial);
      final action = <String, dynamic>{
        'id': newId(),
        'kind': kind,
        'targetId': id,
        'input': args,
        'before': before,
        'desired': after,
        'status': 'pending',
        'createdAt': DateTime.now().toIso8601String(),
        'summary': args['reason'] is String ? args['reason'] : '请核对以下变更',
        'sessionId': d.extras['activeChatSessionId'] ?? 'legacy',
      };
      action['displaySummary'] = agentActionSummary(
        action,
        (id) => d.accounts.where((a) => a.id == id).firstOrNull?.name ?? id,
      );
      actions.add(action);
      d.extras['agentActions'] = actions;
      result = action;
    });
    return {
      'proposalId': result!['id'],
      'status': result!['status'],
      'requiresUserConfirmation': true,
      'preview': result!['desired'],
    };
  }

  Future<void> apply(String id) => store.change((d) {
    final actions = _items(d);
    final a = _find(actions, id);
    if (a['status'] == 'applied') return;
    if (a['status'] != 'pending') throw const FormatException('此提案已处理');
    final kind = a['kind'] as String, target = a['targetId'] as String;
    if (!_same(a['before'], _state(d, kind, target))) {
      throw const FormatException('相关数据已变化，请拒绝此提案并重新生成');
    }
    final desired = _desired(d, kind, target, Json.from(a['input']));
    _write(d, kind, target, desired);
    a['status'] = 'applied';
    a['appliedAt'] = DateTime.now().toIso8601String();
    a['after'] = _state(d, kind, target);
    d.extras['agentActions'] = actions;
    _feedback(d, a, '确认执行', '已执行并保存到账本');
  });

  Future<void> reject(String id) => store.change((d) {
    final actions = _items(d);
    final a = _find(actions, id);
    if (a['status'] == 'rejected') return;
    if (a['status'] != 'pending') throw const FormatException('只能拒绝待确认操作');
    a['status'] = 'rejected';
    d.extras['agentActions'] = actions;
    _feedback(d, a, '拒绝', '已拒绝，本次变更未写入账本');
  });

  Future<void> undo(String id) => store.change((d) {
    final actions = _items(d);
    final a = _find(actions, id);
    if (a['status'] == 'undone') return;
    if (a['status'] != 'applied') throw const FormatException('只能撤销已执行操作');
    final kind = a['kind'] as String, target = a['targetId'] as String;
    if (!_same(a['after'], _state(d, kind, target))) {
      throw const FormatException('执行后数据又有变化，不能直接撤销');
    }
    final before = Json.from(a['before']);
    if (kind == 'account' &&
        before['value'] == null &&
        d.quickEntries.any(
          (q) => [q.accountId, q.fromId, q.toId].contains(target),
        )) {
      throw const FormatException('账户已有快捷交易关联，不能撤销创建');
    }
    _write(
      d,
      kind,
      target,
      before['value'] == null
          ? null
          : kind == 'budget'
          ? {'amountCents': before['value']}
          : Json.from(before['value']),
    );
    a['status'] = 'undone';
    a['undoneAt'] = DateTime.now().toIso8601String();
    d.extras['agentActions'] = actions;
    _feedback(d, a, '撤销', '已撤销，相关数据已恢复');
  });

  // Save the decision, result, and ledger change together so a failed write
  // never leaves a success message or an unrecorded user decision.
  static void _feedback(
    WalletData d,
    Json action,
    String decision,
    String result,
  ) {
    final summary =
        action['displaySummary'] as String? ??
        agentActionSummary(
          action,
          (id) => d.accounts.where((a) => a.id == id).firstOrNull?.name ?? id,
        );
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: 365));
    d.chats.removeWhere((m) => localDate(m['timestamp']).isBefore(cutoff));
    for (final (role, content) in [
      ('user', '$decision：$summary'),
      ('assistant', '$result。'),
    ]) {
      d.chats.add({
        'id': newId(),
        'role': role,
        'content': content,
        'timestamp': now.millisecondsSinceEpoch,
        'status': 'complete',
        'actionId': action['id'],
        'actionStatus': action['status'],
        'isActionFeedback': true,
        'sessionId': action['sessionId'] ?? 'legacy',
      });
    }
  }

  static LedgerTx prepareTransaction(
    WalletData data,
    Json input, {
    String? id,
  }) {
    if (input.containsKey('id')) throw const FormatException('语音入口只能新增账单');
    final desired = _desired(data, 'transaction', id ?? newId(), input);
    final trial = data.clone();
    _write(trial, 'transaction', desired['id'], desired);
    validateWallet(trial);
    return LedgerTx.fromJson(desired);
  }

  static Json _find(List<Json> items, String id) => items.firstWhere(
    (a) => a['id'] == id,
    orElse: () => throw const FormatException('提案不存在'),
  );

  static Json _state(WalletData d, String kind, String id) => switch (kind) {
    'account' => {
      'value': d.accounts.where((a) => a.id == id).firstOrNull?.toJson(),
      'transactions': d.transactions
          .where((t) => [t.accountId, t.fromId, t.toId].contains(id))
          .map((t) => t.toJson())
          .toList(),
    },
    'transaction' => {
      'value': d.transactions.where((t) => t.id == id).firstOrNull?.toJson(),
    },
    'budget' => {'value': d.settings['budget'] ?? 0},
    _ => throw const FormatException('无效操作'),
  };

  static Json _desired(WalletData d, String kind, String id, Json args) {
    if (kind == 'budget') {
      return {'amountCents': _money(args['amountCents'], '预算')};
    }
    if (kind == 'account') {
      final old = d.accounts.where((a) => a.id == id).firstOrNull;
      if (args['id'] != null && old == null) {
        throw const FormatException('账户不存在');
      }
      const fields = [
        'name',
        'category',
        'subType',
        'note',
        'creditLimitCents',
        'billingDay',
        'repaymentDay',
        'includeInTotal',
        'archived',
        'countBillingDayInPrevious',
      ];
      final raw = <String, dynamic>{
        ...?old?.toJson(),
        'id': id,
        for (final k in fields)
          if (args.containsKey(k)) k: args[k],
      };
      raw['name'] = _text(raw['name'], '账户名称');
      final category = raw['category'];
      if (!accountGroups.containsKey(category)) {
        throw const FormatException('账户类型无效');
      }
      if (!(accountPresets[category] ?? []).any(
        (p) => p.$1 == raw['subType'],
      )) {
        throw const FormatException('账户子类型与类型不匹配');
      }
      raw['note'] = raw['note'] == null
          ? ''
          : _text(raw['note'], '备注', empty: true);
      for (final k in [
        'includeInTotal',
        'archived',
        'countBillingDayInPrevious',
      ]) {
        if (raw.containsKey(k) && raw[k] is! bool) {
          throw FormatException('$k 必须为布尔值');
        }
      }
      raw['creditLimitCents'] = _money(raw['creditLimitCents'] ?? 0, '信用额度');
      for (final k in ['billingDay', 'repaymentDay']) {
        if (raw[k] != null && (raw[k] is! int || raw[k] < 1 || raw[k] > 28)) {
          throw const FormatException('当前账本支持的账单日与还款日为 1 至 28');
        }
      }
      if (args.containsKey('currentBalanceCents')) {
        final current = _money(
          args['currentBalanceCents'],
          '当前余额',
          signed: true,
        );
        final delta = d.transactions.fold<int>(
          0,
          (sum, t) => sum + t.effectOn(id),
        );
        raw['openingBalance'] = current - delta;
      }
      return WalletAccount.fromJson(raw).toJson();
    }
    final old = d.transactions.where((t) => t.id == id).firstOrNull;
    if (args['id'] != null && old == null) throw const FormatException('账单不存在');
    final raw = <String, dynamic>{
      ...?old?.toJson(),
      'id': id,
      for (final k in [
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
        if (args.containsKey(k)) k: args[k],
    };
    raw['title'] = _text(raw['title'], '账单标题');
    raw['category'] = _text(raw['category'], '分类');
    raw['amountCents'] = _money(raw['amountCents'], '金额');
    if (raw['amountCents'] == 0) throw const FormatException('交易金额必须大于零');
    raw['date'] = parseAgentDate(raw['date']).toIso8601String();
    if (!TxType.values.any((t) => t.name == raw['type'])) {
      throw const FormatException('交易类型无效');
    }
    raw['note'] = raw['note'] == null
        ? ''
        : _text(raw['note'], '备注', empty: true);
    final type = TxType.values.byName(raw['type']);
    if (type == TxType.transfer) {
      raw['accountId'] = null;
      if (raw['transferFromId'] == raw['transferToId']) {
        throw const FormatException('转出与转入账户不能相同');
      }
    } else {
      raw['transferFromId'] = null;
      raw['transferToId'] = null;
      if (!d.categories.any(
        (c) => c.name == raw['category'] && c.type == type,
      )) {
        throw const FormatException('请使用已有的收支分类');
      }
    }
    for (final account
        in type == TxType.transfer
            ? [raw['transferFromId'], raw['transferToId']]
            : [raw['accountId']]) {
      if (!d.accounts.any((a) => a.id == account && !a.archived)) {
        throw const FormatException('请选择有效的未归档账户');
      }
    }
    return LedgerTx.fromJson(raw).toJson();
  }

  static void _write(WalletData d, String kind, String id, Json? value) {
    switch (kind) {
      case 'account':
        d.accounts.removeWhere((a) => a.id == id);
        if (value != null) d.accounts.add(WalletAccount.fromJson(value));
      case 'transaction':
        d.transactions.removeWhere((t) => t.id == id);
        if (value != null) d.transactions.add(LedgerTx.fromJson(value));
      case 'budget':
        d.settings['budget'] = value?['amountCents'] ?? 0;
    }
  }

  static int _money(dynamic v, String label, {bool signed = false}) {
    if (v is! int || v.abs() > 999999999999 || (!signed && v < 0)) {
      throw FormatException('$label 必须为有效的整数分');
    }
    return v;
  }

  static String _text(dynamic v, String label, {bool empty = false}) {
    if (v is! String || (!empty && v.trim().isEmpty) || v.length > 2000) {
      throw FormatException('$label 无效或过长');
    }
    return v.trim();
  }

  static bool _same(dynamic a, dynamic b) =>
      jsonEncode(_ordered(a)) == jsonEncode(_ordered(b));
  static dynamic _ordered(dynamic v) {
    if (v is Map) {
      return {
        for (final k in v.keys.cast<String>().toList()..sort())
          k: _ordered(v[k]),
      };
    }
    if (v is List) return v.map(_ordered).toList();
    return v;
  }
}
