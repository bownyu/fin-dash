import 'dart:convert';
import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../agent/task_runtime.dart';
import 'design.dart';
import 'query_result_card.dart';
import 'voice_entry_sheet.dart';
import 'saved_analyses_page.dart';
import 'agent_batch_card.dart';

class TasksPage extends StatelessWidget {
  const TasksPage({super.key});
  @override
  Widget build(BuildContext context) => RuntimeBuilder(builder: buildContent);
  Widget buildContent(BuildContext context) {
    final ai = AppScope.aiOf(context);
    final tasks = ai.tasks.tasks.reversed.toList();
    final drafts =
        (AppScope.storeOf(
                      context,
                      domains: const {
                        WalletDomain.tasks,
                        WalletDomain.ledger,
                        WalletDomain.preferences,
                      },
                    ).data.extras['voiceDrafts']
                    as Map? ??
                {})
            .values
            .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('任务与回执'),
        actions: [
          IconButton(
            tooltip: '常用分析',
            onPressed: () => openPage(context, const SavedAnalysesPage()),
            icon: const Icon(Icons.bookmarks_outlined),
          ),
        ],
      ),
      body: tasks.isEmpty && drafts.isEmpty
          ? const Center(child: Text('暂无任务'))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: tasks.length + drafts.length,
              itemBuilder: (context, index) => index >= tasks.length
                  ? Card(
                      child: ListTile(
                        title: Text(
                          '语音草稿：${drafts[index - tasks.length]['text']}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => showVoiceEntry(
                          context,
                          entryId: drafts[index - tasks.length]['entryId'],
                          initialText: drafts[index - tasks.length]['text'],
                        ),
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TaskCard(
                        key: ValueKey(tasks[index]['id']),
                        taskId: tasks[index]['id'],
                        showPlan: true,
                      ),
                    ),
            ),
    );
  }
}

class TaskCard extends StatefulWidget {
  final String taskId;
  final bool showPlan;
  final bool showResult;
  const TaskCard({
    super.key,
    required this.taskId,
    this.showPlan = false,
    this.showResult = true,
  });
  @override
  State<TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<TaskCard> {
  final controllers = <String, TextEditingController>{};
  final values = <String, dynamic>{};
  bool busy = false;
  String? error;
  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

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
        setState(() => error = e is FormatException ? e.message : '$e');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => RuntimeBuilder(builder: buildContent);
  Widget buildContent(BuildContext context) {
    AppScope.storeOf(
      context,
      domains: const {WalletDomain.tasks, WalletDomain.ledger},
    );
    final ai = AppScope.aiOf(context), task = ai.tasks.get(widget.taskId);
    final interaction = task['interaction'], review = task['preferenceReview'];
    final state = task['state'];
    final expired =
        task['ledgerEpoch'] !=
        AppScope.storeOf(
          context,
          domains: const {
            WalletDomain.tasks,
            WalletDomain.ledger,
            WalletDomain.preferences,
          },
        ).ledgerEpoch;
    final label = expired
        ? '账本已恢复，需要重新准备'
        : switch (state) {
            'needsInput' => '请补充信息',
            'ready' => '等待审阅',
            'completed' => '处理完成',
            'cancelled' => '已放弃',
            'interrupted' => '已中断，内容已保留',
            'failed' => '未完成',
            _ => '正在准备',
          };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${task['goal']}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(label),
            if (widget.showResult && task['result'] is Map)
              QueryResultCard(result: Json.from(task['result'])),
            if (widget.showResult && task['recipeProposal'] != null)
              TextButton(
                onPressed: busy
                    ? null
                    : () =>
                          run(() => ai.capabilities.saveRecipe(widget.taskId)),
                child: const Text('保存为常用分析'),
              ),
            if (interaction != null && state == 'needsInput' && !expired) ...[
              const SizedBox(height: 12),
              Text(
                '${interaction['title']}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if ('${interaction['reason']}'.isNotEmpty)
                Text('${interaction['reason']}'),
              for (final field in interaction['fields'])
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: field['type'] == 'accountChoice'
                      ? DropdownButtonFormField<String>(
                          initialValue: values[field['key']],
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: '${field['label'] ?? field['key']}',
                          ),
                          items: [
                            for (final option in field['options'])
                              DropdownMenuItem(
                                value: option['value'] as String,
                                child: Text(
                                  '${option['label']}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: busy
                              ? null
                              : (v) => setState(() => values[field['key']] = v),
                        )
                      : TextField(
                          controller: controllers.putIfAbsent(
                            field['key'],
                            TextEditingController.new,
                          ),
                          enabled: !busy,
                          decoration: InputDecoration(
                            labelText: '${field['label'] ?? field['key']}',
                          ),
                          keyboardType: field['type'] == 'cents'
                              ? const TextInputType.numberWithOptions(
                                  decimal: true,
                                )
                              : TextInputType.text,
                        ),
                ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: busy || ai.busy
                    ? null
                    : () => run(() async {
                        final answers = <String, dynamic>{...values};
                        for (final field in interaction['fields']) {
                          final value = controllers[field['key']]?.text.trim();
                          if (value != null) {
                            answers[field['key']] = field['type'] == 'cents'
                                ? parseMoney(value)
                                : value;
                          }
                        }
                        final result = await ai.tasks.respond(
                          widget.taskId,
                          interaction['interactionId'],
                          interaction['revision'],
                          answers,
                        );
                        await ai.resumeTask(
                          widget.taskId,
                          '继续原任务：${task['goal']}。用户补充字段：${jsonEncode(result)}',
                        );
                      }),
                child: const Text('继续准备'),
              ),
            ],
            if (review != null) ...[
              const SizedBox(height: 10),
              Text('${review['summary']}'),
              if (review['receipt']?['status'] == 'applied') ...[
                const Text('已保存，可撤销'),
                TextButton(
                  onPressed: busy || expired
                      ? null
                      : () => run(
                          () => ai.tasks.undoPreference(
                            widget.taskId,
                            review['id'],
                          ),
                        ),
                  child: const Text('撤销此次保存'),
                ),
              ] else if (review['receipt']?['status'] == 'undone')
                const Text('已撤销')
              else
                FilledButton(
                  onPressed: busy || expired || state != 'ready'
                      ? null
                      : () => run(
                          () => ai.tasks.applyPreference(
                            widget.taskId,
                            review['id'],
                          ),
                        ),
                  child: const Text('确认保存这些信息'),
                ),
            ],
            if (widget.showPlan && task['planId'] != null)
              AgentBatchCard(batchId: task['planId']),
            if (!expired && ['interrupted', 'failed'].contains(state))
              TextButton(
                onPressed: busy || ai.busy
                    ? null
                    : () => run(
                        () => ai.resumeTask(
                          widget.taskId,
                          '${task['goal']}。继续已有任务，先检查已有方案与回执。${task['answers'] == null ? '' : jsonEncode(task['answers'])}',
                        ),
                      ),
                child: const Text('继续任务'),
              ),
            if (!expired &&
                [
                  'preparing',
                  'needsInput',
                  'ready',
                  'interrupted',
                  'failed',
                ].contains(state))
              TextButton(
                onPressed: busy
                    ? null
                    : () => run(() async {
                        if (ai.liveMessage?['taskId'] == widget.taskId) {
                          await ai.cancel();
                        }
                        final plan = task['planId'];
                        if (plan != null) {
                          final r = ai.actions.review(plan);
                          if (r.pending.isNotEmpty) {
                            await ai.actions.rejectBatch(plan, r.token);
                          }
                        }
                        await ai.tasks.checkpoint(
                          widget.taskId,
                          TaskState.cancelled,
                        );
                      }),
                child: const Text('放弃未完成部分'),
              ),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }
}
