import '../domain/models.dart';
import '../domain/ledger_operations.dart';

/// The model can prepare these commands; only a reviewed local action applies them.
abstract final class PreferenceChanges {
  static const tools = {
    'add_memory',
    'update_memory',
    'forget_memory',
    'learn_behavior',
    'update_user_cognition',
    'update_plan',
    'set_commitment',
  };
  static const commitmentStatuses = {
    'active': '进行中',
    'done': '做到了',
    'missed': '没做到',
    'dropped': '已放弃',
  };
  static Json state(WalletMetadata d, String tool) =>
      tool == 'update_plan' ? {'goals': d.goals} : {'agent': d.agent};

  /// One readable line for the review card.
  static String summary(WalletMetadata d, String tool, Json args) {
    if (tool == 'set_commitment') {
      final old = (d.agent['commitments'] as List? ?? [])
          .whereType<Map>()
          .where((c) => c['id'] == args['id'])
          .firstOrNull;
      final text = args['text'] ?? old?['text'];
      return old == null
          ? '约定：$text（${args['check_date']} 回访）'
          : '约定「$text」：${commitmentStatuses[args['status'] ?? 'active']}${args['note'] == null ? '' : '，${args['note']}'}';
    }
    if (tool == 'update_plan') {
      return [
        '目标：${args['description']}',
        if (args['target_cents'] is int) '金额 ${money(args['target_cents'])}',
        if (args['deadline'] != null) '期限 ${args['deadline']}',
        if (args['motivation'] != null) '原因：${args['motivation']}',
      ].join('，');
    }
    final added = [
      ...?args['add_tags'] as List?,
      ...?args['add_insights'] as List?,
    ];
    if (added.isNotEmpty) return '记下：${added.join('；')}';
    return '${args['fact'] ?? args['preference'] ?? args['description'] ?? '删除或修正已保存的信息'}';
  }

  static void apply(WalletMetadata d, String tool, Json args) {
    if (!tools.contains(tool)) throw const FormatException('不支持的偏好操作');
    if (tool == 'update_plan') {
      LedgerOperations.ensureUnlocked(d);
      final text = LedgerOperations.text(args['description'], '目标');
      final status = args['status'] ?? 'active';
      if (!['active', 'paused', 'completed', 'abandoned'].contains(status)) {
        throw const FormatException('目标状态无效');
      }
      final target = args['target_cents'];
      if (target != null && (target is! int || target <= 0)) {
        throw const FormatException('目标金额须为正整数分');
      }
      final index = d.goals.indexWhere((g) => g['id'] == args['id']);
      final now = DateTime.now().toIso8601String();
      final goal = {
        'id': args['id'] ?? newId(),
        'description': text,
        'status': status,
        'targetCents': ?target,
        if (args['deadline'] != null)
          'deadline': _day(args['deadline'], '目标期限'),
        if (args['motivation'] != null)
          'motivation': LedgerOperations.text(args['motivation'], '目标原因'),
        'updatedAt': now,
      };
      if (index < 0) {
        d.goals.add({...goal, 'createdAt': now});
      } else {
        d.goals[index] = {...d.goals[index], ...goal};
      }
      return;
    }
    if (tool == 'set_commitment') {
      final list = (d.agent['commitments'] as List? ?? [])
          .map((c) => Json.from(c))
          .toList();
      final index = list.indexWhere((c) => c['id'] == args['id']);
      if (args['id'] != null && index < 0) {
        throw const FormatException('约定不存在，请核对 ID');
      }
      final status = args['status'] ?? 'active';
      if (!commitmentStatuses.containsKey(status)) {
        throw const FormatException('约定状态无效');
      }
      if (index < 0 && (args['text'] == null || args['check_date'] == null)) {
        throw const FormatException('新约定需要内容和回访日期');
      }
      final now = DateTime.now().toIso8601String();
      final value = {
        if (args['text'] != null)
          'text': LedgerOperations.text(args['text'], '约定'),
        if (args['check_date'] != null)
          'checkDate': _day(args['check_date'], '回访日期'),
        if (args['note'] != null)
          'note': LedgerOperations.text(args['note'], '约定结果'),
        'status': status,
        'updatedAt': now,
      };
      if (index < 0) {
        list.add({'id': newId(), ...value, 'createdAt': now});
      } else {
        list[index] = {...list[index], ...value};
      }
      // Keep every open commitment; drop the oldest closed ones past 50.
      while (list.length > 50) {
        final closed = list.indexWhere((c) => c['status'] != 'active');
        if (closed < 0) break;
        list.removeAt(closed);
      }
      d.agent['commitments'] = list;
      return;
    }
    if (tool == 'learn_behavior') {
      final value = LedgerOperations.text(args['preference'], '偏好');
      final list = List<String>.from(d.agent['preferences'] ?? []);
      if (!list.contains(value)) list.add(value);
      d.agent['preferences'] = list;
      return;
    }
    if (tool == 'update_user_cognition') {
      if (args['description'] != null) {
        d.agent['description'] = LedgerOperations.text(
          args['description'],
          '说明',
          empty: true,
        );
      }
      for (final field in ['tags', 'insights']) {
        final list = List<String>.from(d.agent[field] ?? []);
        for (final v in args['add_$field'] as List? ?? []) {
          final text = LedgerOperations.text(v, '事实');
          if (!list.contains(text)) list.add(text);
        }
        list.removeWhere(
          (v) => (args['remove_$field'] as List? ?? []).contains(v),
        );
        d.agent[field] = list;
      }
      return;
    }
    final list = (d.agent['memories'] as List? ?? [])
        .map((m) => Json.from(m))
        .toList();
    final index = list.indexWhere((m) => m['id'] == args['id']);
    if (tool == 'forget_memory') {
      if (index < 0) throw const FormatException('记忆不存在');
      list.removeAt(index);
    } else {
      final fact = LedgerOperations.text(args['fact'], '记忆');
      if (tool == 'update_memory' && index < 0) {
        throw const FormatException('记忆不存在');
      }
      final importance = args['importance'] ?? 'medium';
      if (!['core', 'high', 'medium', 'low'].contains(importance)) {
        throw const FormatException('记忆重要性无效');
      }
      final duplicate = list.indexWhere(
        (m) => '${m['fact'] ?? m['description']}'.trim() == fact,
      );
      if (duplicate >= 0 && tool == 'add_memory') return;
      if (duplicate >= 0 && duplicate != index) {
        throw const FormatException('相同事实已经存在');
      }
      final value = {
        'id': args['id'] ?? newId(),
        'fact': fact,
        'importance': importance,
        'updatedAt': DateTime.now().toIso8601String(),
        'source': 'explicitReview',
      };
      if (index < 0) {
        list.add(value);
      } else {
        list[index] = {...list[index], ...value};
      }
    }
    d.agent['memories'] = list;
  }

  static String _day(dynamic value, String label) {
    final parsed =
        value is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)
        ? DateTime.tryParse(value)
        : null;
    if (parsed == null || dayKey(parsed) != value) {
      throw FormatException('$label须为 YYYY-MM-DD');
    }
    return value as String;
  }
}
