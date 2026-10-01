import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import '../domain/models.dart';
import '../services/ai_service.dart';
import 'design.dart';
import 'preferences.dart';
import 'agent_actions_page.dart';
import 'agent_action_card.dart';

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
  String liveSignature = '';
  AiImage? attachment;

  Future<void> pickImage() async {
    final ai = AppScope.of(context).ai;
    if (!ai.supportsImages) {
      toast(context, '请先在 AI 设置中启用支持图片输入的模型');
      return;
    }
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (file == null || !mounted) return;
      if (await file.length() > 5 * 1024 * 1024) {
        throw const FormatException('请选择 5 MB 以内的图片');
      }
      final bytes = await file.readAsBytes();
      final image = AiImage(
        bytes,
        bytes.isNotEmpty && bytes[0] == 137 ? 'image/png' : 'image/jpeg',
      );
      if (mounted) setState(() => attachment = image);
    } catch (e) {
      if (mounted) {
        toast(context, e is FormatException ? e.message : '无法读取图片，请重新选择');
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!started && widget.initialPrompt != null) {
      started = true;
      input.text = widget.initialPrompt!;
    }
    final ai = AppScope.of(context).ai;
    final length = AppScope.storeOf(context).data.chats.length;
    final live = ai.liveMessage;
    final blocks = live?['blocks'] as List? ?? [];
    final last = blocks.isEmpty ? null : blocks.last;
    final signature =
        '${live?['id']}:${live?['content']?.length}:${blocks.length}:${last?['text']?.length}:${last?['arguments']?.length}:${last?['status']}';
    final nearBottom = !scroll.hasClients || scroll.position.extentAfter < 160;
    if (length != messageCount || signature != liveSignature && nearBottom) {
      liveSignature = signature;
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
    final text =
        prompt ??
        (input.text.trim().isEmpty && attachment != null
            ? '请识别这张截图，先读取已有账户和设置，再准备待确认的账户或账单变更；不确定的信息请询问我。'
            : input.text.trim());
    if (text.isEmpty || ai.busy) return;
    input.clear();
    final image = attachment;
    setState(() => attachment = null);
    await ai.send(text, analysisRange: widget.analysisRange, image: image);
    if (mounted && ai.error != null) {
      setState(() {
        input.text = text;
        attachment = image;
      });
    }
  }

  Future<void> retry() async {
    final ai = AppScope.of(context).ai;
    final draft = input.text, image = attachment;
    await ai.retryLast();
    if (mounted &&
        ai.error == null &&
        input.text == draft &&
        attachment == image) {
      setState(() {
        input.clear();
        attachment = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context), ai = AppScope.of(context).ai;
    final messages = store.data.chats
        .where((m) => m['id'] != ai.liveMessage?['id'])
        .toList();
    if (ai.liveMessage != null) messages.add(ai.liveMessage!);
    final proposalOwners = <String, String>{
      for (final m in messages)
        for (final id in _proposalIds(m)) id: m['id'] as String,
    };
    final actions = ai.actions.items.reversed.toList();
    final unlinked = actions
        .where(
          (a) =>
              a['status'] == 'pending' && !proposalOwners.containsKey(a['id']),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Column(
          children: [
            Text(store.data.agent['name'] ?? 'AI 顾问'),
            Text(
              ai.busy
                  ? store.aiStatus!
                  : (ai.config['model'] as String).isEmpty
                  ? '请配置模型'
                  : ai.config['model'],
              style: const TextStyle(fontSize: 11, color: muted),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '操作管理',
            onPressed: () => openPage(context, const AgentActionsPage()),
            icon: const Icon(Icons.fact_check_outlined),
          ),
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
                if (messages.isEmpty && unlinked.isEmpty) ...[
                  EmptyState(
                    '给每一笔钱，一个更好的计划',
                    '我可以分析真实账单、读取账户设置，并根据文字或截图准备可核对的账户和账单变更。',
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
                ...messages.map(
                  (m) => _Message(
                    m,
                    actions: actions
                        .where((a) => proposalOwners[a['id']] == m['id'])
                        .toList(),
                  ),
                ),
                for (final a in unlinked)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: AgentActionCard(key: ValueKey(a['id']), action: a),
                  ),
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
                        SelectableText(
                          ai.error!,
                          style: const TextStyle(color: coral),
                        ),
                        Row(
                          children: [
                            TextButton(
                              onPressed: ai.busy ? null : retry,
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
          if (attachment != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      attachment!.bytes,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '发送时将图片交给所配置的 AI 服务；图片不保存到聊天历史。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  IconButton(
                    tooltip: '移除截图',
                    onPressed: () => setState(() => attachment = null),
                    icon: const Icon(Icons.close),
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
                  IconButton(
                    tooltip: '添加截图',
                    onPressed: ai.busy ? null : pickImage,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                  ),
                  Expanded(
                    child: TextField(
                      controller: input,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 3000,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: '分析账单，或描述想调整的账户…',
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
  final List<Json>? actions;
  const _Message(this.message, {this.actions});
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
                ? SelectableText(
                    '${message['content']}${message['hasImage'] == true ? '\n📎 附有截图（图片未保存）' : ''}',
                  )
                : _AssistantContent(message, actions: actions),
          ),
        ],
      ),
    );
  }
}

Set<String> _proposalIds(Json message) {
  final ids = <String>{};
  if (message['role'] == 'assistant' && message['actionId'] is String) {
    ids.add(message['actionId'] as String);
  }
  for (final block in message['blocks'] as List? ?? []) {
    if (block['type'] != 'tool' || !'${block['name']}'.startsWith('propose_')) {
      continue;
    }
    try {
      final raw = block['result'];
      final result = raw is String ? jsonDecode(raw) : raw;
      if (result is Map && result['proposalId'] is String) {
        ids.add(result['proposalId'] as String);
      }
    } catch (_) {
      // Partial streamed arguments/results do not yet identify a proposal.
    }
  }
  return ids;
}

class _AssistantContent extends StatelessWidget {
  final Json message;
  final List<Json>? actions;
  const _AssistantContent(this.message, {this.actions});

  @override
  Widget build(BuildContext context) {
    final blocks = message['blocks'] as List? ?? [];
    final proposals =
        actions ??
        AppScope.of(context).ai.actions.items
            .where((a) => _proposalIds(message).contains(a['id']))
            .toList();
    final hasTrace =
        blocks.any((b) => b['type'] == 'tool' || b['type'] == 'reasoning') ||
        message['usage'] is List ||
        message['error'] != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasTrace) _ProcessingTrace(message),
        if (blocks.isEmpty && '${message['content'] ?? ''}'.isNotEmpty)
          MarkdownBody(data: '${message['content']}', selectable: true),
        for (final block in blocks)
          if (block['type'] == 'text')
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: MarkdownBody(data: '${block['text']}', selectable: true),
            ),
        for (final a in proposals)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: AgentActionCard(key: ValueKey(a['id']), action: a),
          ),
        if (message['status'] == 'cancelled')
          const Text(
            '已停止 · 已保留收到的内容',
            style: TextStyle(color: muted, fontSize: 12),
          ),
        if (message['status'] == 'streaming' && blocks.isEmpty)
          const Text('等待模型输出…', style: TextStyle(color: muted)),
      ],
    );
  }
}

class _ProcessingTrace extends StatelessWidget {
  final Json message;
  const _ProcessingTrace(this.message);

  String pretty(dynamic value) {
    try {
      return const JsonEncoder.withIndent(
        '  ',
      ).convert(value is String ? jsonDecode(value) : value);
    } catch (_) {
      return '${value ?? ''}';
    }
  }

  String status(Json block) => switch (block['status']) {
    'complete' => '已完成',
    'error' => '失败',
    'running' => '执行中',
    _ => ['cancelled', 'error'].contains(message['status']) ? '未执行' : '接收参数',
  };

  void details(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) {
        AppScope.storeOf(context);
        final blocks = message['blocks'] as List? ?? [];
        return FractionallySizedBox(
          heightFactor: .8,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              Text('处理记录', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (var i = 0; i < blocks.length; i++)
                if (blocks[i]['type'] == 'reasoning')
                  ExpansionTile(
                    key: ValueKey('${message['id']}:reasoning:$i'),
                    tilePadding: EdgeInsets.zero,
                    title: const Text(
                      '思考 / 摘要',
                      style: TextStyle(fontSize: 13),
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: MarkdownBody(
                          data: '${blocks[i]['text']}',
                          selectable: true,
                        ),
                      ),
                    ],
                  )
                else if (blocks[i]['type'] == 'tool')
                  ExpansionTile(
                    key: ValueKey('${message['id']}:tool:$i'),
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      '${toolLabels[blocks[i]['name']] ?? blocks[i]['name'] ?? '工具调用'}'
                          .replaceAll('…', ''),
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      status(Json.from(blocks[i])),
                      style: TextStyle(
                        fontSize: 12,
                        color: blocks[i]['status'] == 'error' ? coral : muted,
                      ),
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '调用参数',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            SelectableText(
                              pretty(blocks[i]['arguments']),
                              style: const TextStyle(fontSize: 12),
                            ),
                            if (blocks[i]['result'] != null) ...[
                              const SizedBox(height: 8),
                              const Text(
                                '工具结果',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              SelectableText(
                                pretty(blocks[i]['result']),
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
              if (message['error'] != null)
                SelectableText(
                  '${message['error']}',
                  style: const TextStyle(color: coral, fontSize: 12),
                ),
              if (message['usage'] is List)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('用量与响应信息', style: TextStyle(fontSize: 13)),
                  children: [
                    SelectableText(
                      pretty({
                        'model': message['model'],
                        'responseId': message['responseId'],
                        'usage': message['usage'],
                      }),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final blocks = message['blocks'] as List? ?? [];
    final tools = blocks.where((b) => b['type'] == 'tool').toList();
    final errors = tools.where((b) => b['status'] == 'error').length;
    final running = tools
        .where((b) => b['status'] == 'running' || b['status'] == 'pending')
        .lastOrNull;
    final active = message['status'] == 'streaming';
    final label = message['error'] != null
        ? '请求失败 · 查看记录'
        : active && running != null
        ? '${toolLabels[running['name']] ?? '调用工具…'} · ${tools.length} 次调用'
        : tools.isNotEmpty
        ? '${tools.length} 次工具调用${errors > 0
              ? ' · $errors 次失败'
              : message['status'] == 'cancelled'
              ? ' · 已停止'
              : ''}'
        : active
        ? '思考中…'
        : '处理记录';
    return TextButton(
      key: ValueKey('${message['id']}:processing'),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: errors > 0 || message['error'] != null ? coral : muted,
      ),
      onPressed: () => details(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            errors > 0 || message['error'] != null
                ? Icons.error_outline
                : active || message['status'] == 'cancelled'
                ? Icons.more_horiz
                : Icons.check_circle_outline,
            size: 14,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 2),
          const Icon(Icons.chevron_right, size: 14),
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
                  onTap: () => openPage(context, _HistoryDetail(day)),
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
  const _HistoryDetail(this.date);
  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    final messages = store.data.chats
        .where((m) => dayKey(localDate(m['timestamp'])) == date)
        .toList();
    final actions = AppScope.of(context).ai.actions.items.reversed.toList();
    final owners = <String, String>{
      for (final m in messages)
        for (final id in _proposalIds(m)) id: m['id'] as String,
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(date),
        actions: [
          TextButton(
            onPressed: () => openPage(context, const ChatPage()),
            child: const Text('继续对话'),
          ),
        ],
      ),
      body: PageList(
        children: messages
            .map(
              (m) => _Message(
                m,
                actions: actions
                    .where((a) => owners[a['id']] == m['id'])
                    .toList(),
              ),
            )
            .toList(),
      ),
    );
  }
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
