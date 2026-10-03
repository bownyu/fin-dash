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
  };
  static Json state(WalletMetadata d, String tool) =>
      tool == 'update_plan' ? {'goals': d.goals} : {'agent': d.agent};
  static void apply(WalletMetadata d, String tool, Json args) {
    if (!tools.contains(tool)) throw const FormatException('不支持的偏好操作');
    if (tool == 'update_plan') {
      LedgerOperations.ensureUnlocked(d);
      final text = LedgerOperations.text(args['description'], '目标');
      final status = args['status'] ?? 'active';
      if (!['active', 'paused', 'completed', 'abandoned'].contains(status)) {
        throw const FormatException('目标状态无效');
      }
      final index = d.goals.indexWhere((g) => g['id'] == args['id']);
      final goal = {
        'id': args['id'] ?? newId(),
        'description': text,
        'status': status,
        'updatedAt': DateTime.now().toIso8601String(),
      };
      if (index < 0) {
        d.goals.add(goal);
      } else {
        d.goals[index] = {...d.goals[index], ...goal};
      }
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
}
