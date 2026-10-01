import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:intl/intl.dart';
import '../domain/models.dart';
import '../services/ai_service.dart';
import 'design.dart';
import 'preferences.dart';

class ChatPage extends StatefulWidget {
  final String? initialPrompt;
  final DateRange? analysisRange;
  const ChatPage({super.key, this.initialPrompt, this.analysisRange});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final input = TextEditingController(), scroll = ScrollController();
  bool started = false;
  int messageCount = -1;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!started && widget.initialPrompt != null) {
      started = true;
      input.text = widget.initialPrompt!;
    }
    final length = AppScope.storeOf(context).data.chats.length;
    if (length != messageCount) {
      messageCount = length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) {
          scroll.animateTo(
            scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> send([String? prompt]) async {
    final ai = AppScope.of(context).ai;
    final text = prompt ?? input.text.trim();
    if (text.isEmpty || ai.busy) return;
    input.clear();
    await ai.send(text, analysisRange: widget.analysisRange);
    if (mounted && ai.error != null) input.text = text;
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context), ai = AppScope.of(context).ai;
    final today = dayKey(DateTime.now());
    final messages = store.data.chats
        .where((m) => dayKey(localDate(m['timestamp'])) == today)
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            Text(store.data.agent['name'] ?? 'AI 顾问'),
            Text(
              ai.busy ? store.aiStatus! : ai.config['model'],
              style: const TextStyle(fontSize: 11, color: muted),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '历史对话',
            onPressed: () => openPage(context, const ChatHistoryPage()),
            icon: const Icon(Icons.history_rounded),
          ),
          IconButton(
            tooltip: '顾问记忆',
            onPressed: () => openPage(context, const AgentStatePage()),
            icon: const Icon(Icons.psychology_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
              children: [
                if (messages.isEmpty) ...[
                  EmptyState(
                    '给每一笔钱，一个更好的计划',
                    '我可以分析真实账单、查看账户、发现支出变化，并记住你明确告诉我的目标。',
                    icon: Icons.auto_awesome_rounded,
                  ),
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '从这里开始',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '先在 AI 设置中连接模型服务，再告诉我你想改善的收支问题。',
                          style: TextStyle(color: muted, fontSize: 13),
                        ),
                        TextButton(
                          onPressed: () =>
                              openPage(context, const AiSettingsPage()),
                          child: const Text('打开 AI 设置 →'),
                        ),
                      ],
                    ),
                  ),
                ],
                ...messages.map((m) => _Message(m)),
                if (ai.busy)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Row(
                      children: [
                        const SizedBox.square(
                          dimension: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            store.aiStatus!,
                            style: const TextStyle(color: muted),
                          ),
                        ),
                        TextButton(
                          onPressed: ai.cancel,
                          child: const Text('停止'),
                        ),
                      ],
                    ),
                  ),
                if (ai.error != null)
                  Panel(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(ai.error!, style: const TextStyle(color: coral)),
                        Row(
                          children: [
                            TextButton(
                              onPressed: ai.busy ? null : ai.retryLast,
                              child: const Text('重试'),
                            ),
                            TextButton(
                              onPressed: () =>
                                  openPage(context, const AiSettingsPage()),
                              child: const Text('检查设置'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (!ai.busy)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  for (final prompt in ['今日分析', '本周总结', '异常检测'])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text(prompt),
                        onPressed: () => send(switch (prompt) {
                          '今日分析' => '请分析今天的收入与支出。',
                          '本周总结' => '请总结本周的收支与主要变化。',
                          _ => '请根据真实账单检测最近30天异常支出。',
                        }),
                      ),
                    ),
                ],
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: input,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 3000,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: '聊聊你的收支与目标…',
                        counterText: '',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filled(
                    tooltip: '发送',
                    onPressed: ai.busy ? null : () => send(),
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final Json message;
  const _Message(this.message);
  @override
  Widget build(BuildContext context) {
    final user = message['role'] == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: user
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Text(
              '${user
                  ? '你'
                  : message['isReport'] == true
                  ? '分析报告'
                  : AppScope.storeOf(context).data.agent['name']} · ${DateFormat('HH:mm').format(localDate(message['timestamp']))}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Container(
            constraints: const BoxConstraints(maxWidth: 620),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: user
                  ? primary.withValues(alpha: .15)
                  : Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(18),
            ),
            child: user
                ? SelectableText(message['content'])
                : MarkdownBody(
                    data: message['content'],
                    selectable: true,
                    styleSheet: MarkdownStyleSheet(
                      p: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 14,
                        height: 1.65,
                      ),
                      h1: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                      h2: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                      h3: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                      blockquoteDecoration: BoxDecoration(
                        color: primary.withValues(alpha: .1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class ChatHistoryPage extends StatelessWidget {
  const ChatHistoryPage({super.key});
  @override
  Widget build(BuildContext context) {
    final groups = <String, List<Json>>{};
    for (final m in AppScope.storeOf(context).data.chats) {
      groups.putIfAbsent(dayKey(localDate(m['timestamp'])), () => []).add(m);
    }
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    return Scaffold(
      appBar: AppBar(title: const Text('历史对话')),
      body: PageList(
        children: [
          const Text(
            '按日期保存对话，保留最近 365 天。',
            style: TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          if (days.isEmpty)
            const EmptyState(
              '还没有历史对话',
              '与顾问聊过的内容会按日期保存。',
              icon: Icons.history_rounded,
            ),
          ...days.map((day) {
            final messages = groups[day]!,
                topic =
                    messages
                        .where((m) => m['role'] == 'user')
                        .firstOrNull?['content'] ??
                    '顾问分析';
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Panel(
                padding: EdgeInsets.zero,
                child: ListTile(
                  contentPadding: const EdgeInsets.all(18),
                  title: Text(
                    day,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '$topic',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    '${messages.length} 条',
                    style: const TextStyle(color: muted),
                  ),
                  onTap: () => openPage(context, _HistoryDetail(day, messages)),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _HistoryDetail extends StatelessWidget {
  final String date;
  final List<Json> messages;
  const _HistoryDetail(this.date, this.messages);
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(date)),
    body: PageList(children: messages.map((m) => _Message(m)).toList()),
  );
}

class AgentStatePage extends StatelessWidget {
  const AgentStatePage({super.key});
  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context), a = store.data.agent;
    Widget strings(String title, List<dynamic> list, String empty) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title),
        Panel(
          child: list.isEmpty
              ? Text(empty, style: const TextStyle(color: muted))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: list
                      .map(
                        (s) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '•  ',
                                style: TextStyle(color: primary),
                              ),
                              Expanded(
                                child: Text(
                                  s is Map
                                      ? '${s['description'] ?? s['preference'] ?? s}'
                                      : '$s',
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
        ),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('顾问记忆与认知'),
        actions: [
          IconButton(
            tooltip: '顾问人设',
            onPressed: () => openPage(context, const PersonaPage()),
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
      body: PageList(
        children: [
          Panel(
            child: Row(
              children: [
                IconBadge('spa', const Color(0xFFA78BFA), size: 52),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a['name'],
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Text(
                        '个人财务助手 · 以真实账本为依据',
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          strings('底线原则', [
            '分析真实账单',
            '保护个人隐私与密钥',
            '不擅自改写账单',
            '不编造操作或能力',
            '区分事实与推测',
          ], ''),
          strings('学到的偏好', a['preferences'] as List? ?? [], '你可以告诉顾问希望怎样交流。'),
          const SectionTitle('用户画像'),
          Panel(
            child: Text(
              (a['description'] as String? ?? '').isEmpty
                  ? '顾问还在慢慢了解你。'
                  : a['description'],
            ),
          ),
          const SectionTitle('用户标签'),
          Panel(
            child: (a['tags'] as List? ?? []).isEmpty
                ? const Text('暂无标签', style: TextStyle(color: muted))
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: (a['tags'] as List)
                        .map(
                          (tag) => InputChip(
                            label: Text('$tag'),
                            onDeleted: () => perform(
                              context,
                              () => store.change(
                                (d) => (d.agent['tags'] as List).remove(tag),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
          strings('核心洞察', a['insights'] as List? ?? [], '足够的数据和明确的信息，会帮助形成洞察。'),
          const SectionTitle('事实记忆'),
          Panel(
            child: (a['memories'] as List? ?? []).isEmpty
                ? const Text('暂无记忆', style: TextStyle(color: muted))
                : Column(
                    children: (a['memories'] as List).map((raw) {
                      final m = Json.from(raw);
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${m['fact'] ?? m['description'] ?? ''}'),
                        subtitle: Text(
                          '重要性：${m['importance'] ?? 'medium'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        trailing: IconButton(
                          tooltip: '删除记忆',
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            color: muted,
                          ),
                          onPressed: () async {
                            if (await confirm(
                              context,
                              '删除这条记忆？',
                              '顾问后续分析将不再使用它。',
                              action: '删除',
                            )) {
                              if (context.mounted) {
                                await perform(
                                  context,
                                  () => store.change(
                                    (d) => (d.agent['memories'] as List)
                                        .removeWhere((x) => x['id'] == m['id']),
                                  ),
                                );
                              }
                            }
                          },
                        ),
                      );
                    }).toList(),
                  ),
          ),
          const SectionTitle('近期消费模式'),
          Panel(
            child: store.patterns.isEmpty
                ? const Text('数据积累后显示重复消费模式。', style: TextStyle(color: muted))
                : Column(
                    children: store.patterns
                        .map(
                          (p) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(p['title']),
                            subtitle: Text(p['description']),
                          ),
                        )
                        .toList(),
                  ),
          ),
          const SectionTitle('记忆事件'),
          Panel(
            child: (a['events'] as List? ?? []).isEmpty
                ? const Text('暂无事件', style: TextStyle(color: muted))
                : Column(
                    children: (a['events'] as List)
                        .take(20)
                        .map(
                          (e) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: Text(
                              '${e['title'] ?? e['description'] ?? ''}',
                            ),
                            subtitle: Text(
                              e['timestamp'] == null
                                  ? ''
                                  : DateFormat(
                                      'yyyy/MM/dd HH:mm',
                                    ).format(localDate(e['timestamp'])),
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
          strings(
            '可用工具 · ${toolLabels.length} 项',
            toolLabels.values.map((s) => s.replaceAll('…', '')).toList(),
            '',
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () async {
              if (AppScope.of(context).ai.busy) {
                toast(context, '请先停止当前分析');
                return;
              }
              if (await confirm(
                context,
                '重置顾问记忆？',
                '清除画像、标签、偏好和记忆。账单、账户、目标与历史对话会保留。',
                action: '重置',
                destructive: true,
              )) {
                if (context.mounted) {
                  await perform(
                    context,
                    () => store.change((d) {
                      d.agent = defaultAgent();
                      d.extras.remove('analysisCache');
                    }),
                    success: '顾问已重置',
                  );
                }
              }
            },
            child: const Text('重置顾问记忆', style: TextStyle(color: coral)),
          ),
        ],
      ),
    );
  }
}
