import 'package:flutter/material.dart';
import 'agent_action_card.dart';
import 'design.dart';

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
    final items = actions.items
        .where(
          (a) => history ? a['status'] != 'pending' : a['status'] == 'pending',
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('操作管理')),
      body: PageList(
        children: [
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
          if (items.isEmpty)
            const EmptyState(
              '暂无操作',
              '可以让顾问根据文字或截图准备账户和账单变更。',
              icon: Icons.fact_check_outlined,
            ),
          for (final a in items) ...[
            AgentActionCard(key: ValueKey(a['id']), action: a),
            const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }
}
