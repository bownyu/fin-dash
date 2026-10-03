import 'package:flutter/material.dart';
import 'agent_action_card.dart';
import 'agent_batch_card.dart';
import 'design.dart';
import 'tasks_page.dart';

class AgentActionsPage extends StatefulWidget {
  const AgentActionsPage({super.key});
  @override
  State<AgentActionsPage> createState() => _AgentActionsPageState();
}

class _AgentActionsPageState extends State<AgentActionsPage> {
  bool history = false;

  @override
  Widget build(BuildContext context) {
    final actions = AppScope.of(context).ai.actions;
    final batches = actions.batches
        .where(
          (b) => b['legacyIds'] == null || (b['legacyIds'] as List).length > 1,
        )
        .toList();
    final covered = {
      for (final b in batches)
        ...actions.review(b['id']).items.map((a) => a['id']),
    };
    final visibleBatches = batches.where((b) {
      final review = actions.review(b['id']);
      return history
          ? review.items.any((a) => a['status'] != 'pending')
          : review.pending.isNotEmpty;
    }).toList();
    final items = actions.items
        .where((a) => !covered.contains(a['id']))
        .where(
          (a) => history ? a['status'] != 'pending' : a['status'] == 'pending',
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('操作管理')),
      body: PageList(
        children: [
          TextButton.icon(
            onPressed: () => openPage(context, const TasksPage()),
            icon: const Icon(Icons.task_alt),
            label: const Text('查看所有任务、补充信息与回执'),
          ),
          const Text('也可以直接在对话中确认变更，处理结果会保存在对话里。'),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('待确认')),
              ButtonSegment(value: true, label: Text('操作历史')),
            ],
            selected: {history},
            onSelectionChanged: (v) => setState(() => history = v.first),
          ),
          const SizedBox(height: 18),
          if (items.isEmpty && visibleBatches.isEmpty)
            const EmptyState(
              '暂无操作',
              '可以让顾问根据文字或截图准备账户和账单变更。',
              icon: Icons.fact_check_outlined,
            ),
          for (final b in visibleBatches) ...[
            AgentBatchCard(key: ValueKey(b['id']), batchId: b['id']),
            const SizedBox(height: 14),
          ],
          for (final a in items) ...[
            AgentActionCard(key: ValueKey(a['id']), action: a),
            const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }
}
