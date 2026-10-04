import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import '../application/preference_changes.dart';
import '../domain/models.dart';
import '../services/ai_service.dart';
import 'design.dart';
import 'tasks_page.dart';
import 'interaction.dart';
import 'preferences.dart';
import 'agent_actions_page.dart';
import 'agent_action_card.dart';
import 'agent_batch_card.dart';

class ChatPage extends StatefulWidget {
  final String? initialPrompt;
  final DateRange? analysisRange;
  final Future<AiImage?> Function()? imagePicker;
  const ChatPage({
    super.key,
    this.initialPrompt,
    this.analysisRange,
    this.imagePicker,
  });
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final input = TextEditingController(), scroll = ScrollController();
  bool started = false;
  int messageCount = -1;
  AiService? observedAi;
  bool scrollQueued = false;
  AiImage? attachment;
  String? composerSession;
  String? initialSession;
  final drafts = <String, (String, AiImage?)>{};

  Future<void> pickImage() async {
    final ai = AppScope.of(context).ai;
    if (!ai.supportsImages) {
      toast(context, '请先在 AI 设置中启用支持图片输入的模型');
      return;
    }
    try {
      if (widget.imagePicker != null) {
        final image = await widget.imagePicker!();
        if (mounted && image != null) setState(() => attachment = image);
        return;
      }
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
    if (composerSession != ai.activeSessionId) {
      initialSession ??= ai.activeSessionId;
      if (composerSession != null) {
        if (input.text.trim().isNotEmpty || attachment != null) {
          drafts[composerSession!] = (input.text, attachment);
        } else {
          drafts.remove(composerSession);
        }
        final restored = drafts.remove(ai.activeSessionId);
        input.text = restored?.$1 ?? '';
        attachment = restored?.$2;
      }
      composerSession = ai.activeSessionId;
      messageCount = -1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) scroll.jumpTo(0);
      });
    }

    if (observedAi != ai) {
      observedAi?.liveUpdates.removeListener(followOutput);
      observedAi = ai;
      ai.liveUpdates.addListener(followOutput);
    }
    final length = AppScope.storeOf(context).data.chats
        .where((m) => AiService.sessionOf(m) == ai.activeSessionId)
        .length;
    if (length != messageCount) {
      messageCount = length;
      followOutput();
    }
  }

  void followOutput() {
    if (scrollQueued || (scroll.hasClients && scroll.position.pixels > 160)) {
      return;
    }
    scrollQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scrollQueued = false;
      if (mounted && scroll.hasClients && scroll.position.pixels <= 160) {
        // The reversed list has a stable bottom at zero, even with lazy history.
        // Do not restart a scroll animation for every arriving token.
        if (scroll.position.pixels != 0) scroll.jumpTo(0);
      }
    });
  }

  @override
  void dispose() {
    observedAi?.liveUpdates.removeListener(followOutput);
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
    await ai.send(
      text,
      analysisRange: ai.activeSessionId == initialSession
          ? widget.analysisRange
          : null,
      image: image,
    );
    if (mounted &&
        ai.error != null &&
        !ai.lastPromptStored &&
        input.text.isEmpty &&
        attachment == null) {
      setState(() {
        input.text = text;
        attachment = image;
      });
    }
  }

  Future<void> retry() async {
    final ai = AppScope.of(context).ai;
    final draft = input.text, image = attachment;
    final wasStored = ai.lastPromptStored;
    await ai.retryLast();
    if (mounted &&
        !wasStored &&
        ai.error == null &&
        ai.lastPromptStored &&
        input.text == draft &&
        attachment == image) {
      setState(() {
        input.clear();
        attachment = null;
      });
    }
  }

  Future<void> newConversation() async {
    if ((input.text.trim().isNotEmpty || attachment != null) &&
        !await confirm(
          context,
          '新建对话？',
          '当前未发送的文字和图片将被清除。',
          action: '新建对话',
          cancelLabel: '继续编辑',
        )) {
      return;
    }
    if (!mounted) return;
    final ai = AppScope.of(context).ai;
    final previousSession = ai.activeSessionId;
    if (await perform(context, ai.newConversation) && mounted) {
      drafts.remove(previousSession);
      input.clear();
      setState(() {
        attachment = null;
        messageCount = -1;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context), ai = AppScope.of(context).ai;
    final messages = store.data.chats
        .where(
          (m) =>
              m['id'] != ai.liveMessage?['id'] &&
              AiService.sessionOf(m) == ai.activeSessionId,
        )
        .toList();
    if (ai.liveMessage != null &&
        AiService.sessionOf(ai.liveMessage!) == ai.activeSessionId) {
      messages.add(ai.liveMessage!);
    }
    final proposalOwners = <String, String>{
      for (final m in messages)
        for (final id in _proposalIds(m)) id: m['id'] as String,
    };
    final batches = ai.actions.batches
        .where(
          (b) =>
              b['sessionId'] == ai.activeSessionId &&
              (b['legacyIds'] == null || (b['legacyIds'] as List).length > 1),
        )
        .toList();
    final covered = {
      for (final b in batches)
        ...ai.actions.review(b['id']).items.map((a) => a['id']),
    };
    final batchOwners = <String, String>{};
    for (final b in batches) {
      final origin = messages
          .where((m) => m['id'] == b['sourceMessageId'])
          .firstOrNull;
      final feedback = messages
          .where((m) => m['role'] == 'assistant' && m['batchId'] == b['id'])
          .lastOrNull;
      if (origin != null || feedback != null) {
        batchOwners[b['id']] = (origin ?? feedback)!['id'];
      }
    }
    final unlinkedBatches = batches
        .where(
          (b) =>
              !batchOwners.containsKey(b['id']) &&
              ai.actions.review(b['id']).pending.isNotEmpty,
        )
        .toList();
    final actions = ai.actions.items.reversed
        .where((a) => (a['sessionId'] ?? 'legacy') == ai.activeSessionId)
        .where((a) => !covered.contains(a['id']))
        .toList();
    final unlinked = actions
        .where(
          (a) =>
              a['status'] == 'pending' && !proposalOwners.containsKey(a['id']),
        )
        .toList();
    return EditorGuard(
      busy: false,
      hasChanges: () =>
          input.text.trim().isNotEmpty ||
          attachment != null ||
          drafts.isNotEmpty,
      child: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Column(
              children: [
                Text(store.data.agent['name'] ?? 'AI 顾问'),
                Text(
                  ai.busy
                      ? store.aiStatus!
                      : (ai.config['model'] as String).isEmpty
                      ? '请配置模型'
                      : '${ai.configurationName(ai.provider)} · ${ai.config['model']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: muted),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: '任务与回执',
                onPressed: () => openPage(context, const TasksPage()),
                icon: const Icon(Icons.task_alt),
              ),
              IconButton(
                tooltip: '新建对话',
                onPressed: ai.busy ? null : newConversation,
                icon: const Icon(Icons.add_comment_outlined),
              ),
              IconButton(
                tooltip: '历史对话',
                onPressed: () => openPage(
                  context,
                  const ChatHistoryPage(returnToChat: true),
                ),
                icon: const Icon(Icons.history_rounded),
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'providers',
                    child: Row(
                      children: [
                        Icon(Icons.dns_outlined, size: 20),
                        SizedBox(width: 12),
                        Text('切换供应商'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'actions',
                    child: Row(
                      children: [
                        Icon(Icons.fact_check_outlined, size: 20),
                        SizedBox(width: 12),
                        Text('操作管理'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'memory',
                    child: Row(
                      children: [
                        Icon(Icons.psychology_outlined, size: 20),
                        SizedBox(width: 12),
                        Text('顾问记忆'),
                      ],
                    ),
                  ),
                ],
                onSelected: (value) => openPage(
                  context,
                  value == 'actions'
                      ? const AgentActionsPage()
                      : value == 'providers'
                      ? const AiSettingsPage()
                      : const AgentStatePage(),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: _LazyChatList(
                  controller: scroll,
                  reverse: messages.isNotEmpty,
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
                  children: [
                    if (messages.isEmpty && unlinked.isEmpty) ...[
                      Builder(
                        builder: (context) {
                          final (title, detail) = _opener(ai);
                          return EmptyState(
                            title,
                            detail,
                            icon: Icons.auto_awesome_rounded,
                          );
                        },
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
                              '先在 AI 设置中连接模型服务，然后像和朋友聊天一样，说说你的近况和想改变的事。',
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
                    ...messages.map((m) {
                      final linkedActions = actions
                          .where((a) => proposalOwners[a['id']] == m['id'])
                          .toList();
                      final linkedBatches = batches
                          .where((b) => batchOwners[b['id']] == m['id'])
                          .toList();
                      final key = ValueKey('chat-message:${m['id']}');
                      if (m['id'] == ai.liveMessage?['id']) {
                        return ValueListenableBuilder<int>(
                          key: key,
                          valueListenable: ai.liveUpdates,
                          builder: (context, _, child) => _Message(
                            ai.liveMessage ?? m,
                            actions: linkedActions,
                            batches: linkedBatches,
                          ),
                        );
                      }
                      return _Message(
                        m,
                        key: key,
                        actions: linkedActions,
                        batches: linkedBatches,
                      );
                    }),
                    for (final task in ai.tasks.tasks.where(
                      (t) =>
                          t['sessionId'] == ai.activeSessionId &&
                          (t['interaction'] != null ||
                              t['preferenceReview'] != null ||
                              t['result'] != null),
                    ))
                      TaskCard(key: ValueKey(task['id']), taskId: task['id']),
                    for (final b in unlinkedBatches)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: AgentBatchCard(
                          key: ValueKey(b['id']),
                          batchId: b['id'],
                        ),
                      ),
                    for (final a in unlinked)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: AgentActionCard(
                          key: ValueKey(a['id']),
                          action: a,
                        ),
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
                      for (final starter in {
                        if (ai.dueCommitments.isNotEmpty)
                          '约定回顾': '聊聊我们之前约定的进展吧。',
                        ..._starters,
                      }.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ActionChip(
                            label: Text(starter.key),
                            onPressed: () => send(starter.value),
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
                          '发送时上传至所配置的 AI 服务，图片保存在本机。',
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
                            hintText: '聊聊收支和目标，或说说想记的账…',
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
        ),
      ),
    );
  }
}

// Build only the messages near the viewport. Keys keep image/selection state when rows move.
const _starters = {
  '聊聊目标': '想和你聊聊我的财务目标，看看现在进展怎么样。',
  '这周花得怎样': '这周我花得怎么样？有什么值得注意的吗？',
  '有点焦虑': '最近对钱有点焦虑，想和你聊聊。',
  '定个小计划': '帮我定一个这周就能做到的小计划吧。',
};

// Built from local data so the first screen feels personal without a model call.
(String, String) _opener(AiService ai) {
  final now = DateTime.now(), data = ai.store.data;
  final name = '${data.profile['name'] ?? ''}'.trim();
  final greeting = switch (now.hour) {
    < 5 || >= 23 => '夜深了',
    < 11 => '早上好',
    < 14 => '中午好',
    < 18 => '下午好',
    _ => '晚上好',
  };
  final title = name.isEmpty ? greeting : '$greeting，$name';
  final due = ai.dueCommitments.firstOrNull;
  if (due != null) {
    return (title, '之前约好的「${due['text']}」到回访的时候了，想聊聊进展吗？');
  }
  final previous = ai.previousChat(now);
  if (previous != null) {
    return (
      title,
      '上次我们聊到「${clip('${previous['content']}', 24)}」，今天想接着聊，还是换个话题？',
    );
  }
  final goal = data.goals.where((g) => g['status'] == 'active').firstOrNull;
  if (goal != null) {
    return (title, '「${goal['description']}」还在进行中，想看看离它还有多远吗？');
  }
  return (title, '我会记住你的目标和我们聊过的事。可以从最近的开销、一个想实现的目标，或者只是对钱的感受聊起。');
}

class _LazyChatList extends StatelessWidget {
  final ScrollController controller;
  final EdgeInsets padding;
  final List<Widget> children;
  final bool reverse;
  const _LazyChatList({
    required this.controller,
    required this.padding,
    required this.children,
    required this.reverse,
  });
  @override
  Widget build(BuildContext context) {
    // Every mounted row asks for its index after a rebuild; index keys once
    // instead of scanning the whole history per row.
    Map<Key, int>? indexes;
    return ListView.builder(
      controller: controller,
      padding: padding,
      reverse: reverse,
      itemCount: children.length,
      findChildIndexCallback: (key) {
        if (indexes == null) {
          indexes = {};
          for (var i = 0; i < children.length; i++) {
            final childKey = children[i].key;
            if (childKey != null) indexes!.putIfAbsent(childKey, () => i);
          }
        }
        final index = indexes![key];
        if (index == null) return null;
        return reverse ? children.length - 1 - index : index;
      },
      itemBuilder: (_, index) =>
          children[reverse ? children.length - 1 - index : index],
    );
  }
}

class _Message extends StatelessWidget {
  final Json message;
  final List<Json>? actions;
  final List<Json>? batches;
  const _Message(this.message, {super.key, this.actions, this.batches});
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
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message['imageId'] is String) ...[
                        _ChatImage(message['imageId']),
                        const SizedBox(height: 8),
                      ] else if (message['hasImage'] == true)
                        const Text(
                          '旧消息的图片未保存',
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                      SelectableText('${message['content']}'),
                    ],
                  )
                : _AssistantContent(
                    message,
                    actions: actions,
                    batches: batches,
                  ),
          ),
        ],
      ),
    );
  }
}

class _ChatImage extends StatefulWidget {
  final String id;
  const _ChatImage(this.id);
  @override
  State<_ChatImage> createState() => _ChatImageState();
}

class _ChatImageState extends State<_ChatImage> {
  Future<Uint8List?>? image;
  String? loaded;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (loaded != widget.id) {
      loaded = widget.id;
      image = AppScope.of(context).ai.images.read(widget.id);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: image,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const SizedBox(
          height: 100,
          child: Center(child: CircularProgressIndicator()),
        );
      }
      final bytes = snapshot.data;
      if (bytes == null) {
        return const Text(
          '图片不在本机，无法预览',
          style: TextStyle(color: muted, fontSize: 12),
        );
      }
      return Semantics(
        label: '已发送的图片，点击放大',
        button: true,
        child: InkWell(
          key: ValueKey('chat-image:${widget.id}'),
          onTap: () => showDialog<void>(
            context: context,
            builder: (context) => Dialog(
              child: Stack(
                children: [
                  InteractiveViewer(
                    child: Image.memory(bytes, fit: BoxFit.contain),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IconButton(
                      tooltip: '关闭图片',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ],
              ),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              bytes,
              width: 240,
              height: 180,
              fit: BoxFit.contain,
              errorBuilder: (_, error, stack) => const SizedBox(
                height: 80,
                child: Center(child: Text('无法解码这张图片')),
              ),
            ),
          ),
        ),
      );
    },
  );
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

// Avoid reparsing a growing Markdown document for every token. Completed text remains selectable.
class _ReplyText extends StatelessWidget {
  final String data;
  final bool streaming;
  const _ReplyText({required this.data, required this.streaming});
  @override
  Widget build(BuildContext context) => streaming
      ? Text(data, style: const TextStyle(height: 1.5))
      : MarkdownBody(
          data: data,
          selectable: true,
          inlineSyntaxes: _inlineSyntaxes,
        );
}

/// CommonMark rejects `**` beside CJK punctuation, as in `**本周：0 元。**上周`,
/// which models write often; bold pairs here ignore the flanking rules.
class _CjkStrongSyntax extends md.InlineSyntax {
  _CjkStrongSyntax()
    : super(r'\*\*(?=\S)(.+?)(?<=\S)\*\*', startCharacter: 0x2A);
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element('strong', md.InlineParser(match[1]!, parser.document).parse()),
    );
    return true;
  }
}

final _inlineSyntaxes = <md.InlineSyntax>[_CjkStrongSyntax()];

class _AssistantContent extends StatelessWidget {
  final Json message;
  final List<Json>? actions;
  final List<Json>? batches;
  const _AssistantContent(this.message, {this.actions, this.batches});

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
          _ReplyText(
            data: '${message['content']}',
            streaming: message['status'] == 'streaming',
          ),
        for (final block in blocks)
          if (block['type'] == 'text')
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: _ReplyText(
                data: '${block['text']}',
                streaming:
                    message['status'] == 'streaming' &&
                    identical(block, blocks.last),
              ),
            ),
        for (final a in proposals)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: AgentActionCard(key: ValueKey(a['id']), action: a),
          ),
        for (final b in batches ?? <Json>[])
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: AgentBatchCard(key: ValueKey(b['id']), batchId: b['id']),
          ),
        if (message['status'] == 'cancelled')
          const Text(
            '已停止 · 已保留收到的内容',
            style: TextStyle(color: muted, fontSize: 12),
          ),
        if (message['status'] == 'streaming' && blocks.isEmpty)
          const Text('等待模型输出…', style: TextStyle(color: muted)),
        if (['error', 'cancelled'].contains(message['status']) &&
            (batches ?? []).isEmpty)
          TextButton(
            onPressed: AppScope.of(context).ai.busy
                ? null
                : () => perform(
                    context,
                    () => AppScope.of(context).ai.retryMessage(message['id']),
                  ),
            child: const Text('重试这条消息'),
          ),
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
      builder: (context) => ValueListenableBuilder<int>(
        valueListenable: AppScope.of(context).ai.liveUpdates,
        builder: (context, _, child) {
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
                            inlineSyntaxes: _inlineSyntaxes,
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
                    title: const Text(
                      '用量与响应信息',
                      style: TextStyle(fontSize: 13),
                    ),
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
      ),
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
  final bool returnToChat;
  const ChatHistoryPage({super.key, this.returnToChat = false});
  @override
  Widget build(BuildContext context) {
    final ai = AppScope.of(context).ai;
    final sessions = ai.sessions;
    return Scaffold(
      appBar: AppBar(title: const Text('历史对话')),
      body: PageList(
        children: [
          const Text(
            '每个对话单独保存上下文，切换后可以继续交流。',
            style: TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          if (sessions.isEmpty)
            const EmptyState(
              '还没有历史对话',
              '点击对话页右上角的新建按钮开始。',
              icon: Icons.history_rounded,
            ),
          for (final session in sessions)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Panel(
                padding: EdgeInsets.zero,
                child: ListTile(
                  title: Text(
                    '${session['title']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    DateFormat('yyyy/MM/dd HH:mm').format(
                      localDate(session['updatedAt'] ?? session['createdAt']),
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: ai.busy
                      ? null
                      : () async {
                          if (await perform(
                                context,
                                () => ai.switchConversation(session['id']),
                              ) &&
                              context.mounted) {
                            if (returnToChat) {
                              Navigator.pop(context);
                            } else {
                              Navigator.of(context).pushReplacement(
                                WalletPageRoute(
                                  builder: (_) => const ChatPage(),
                                ),
                              );
                            }
                          }
                        },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class AgentStatePage extends StatelessWidget {
  const AgentStatePage({super.key});
  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context), a = store.data.agent;
    final commitments = AppScope.of(context).ai.commitments;
    Widget remove(String label, String field, dynamic id) => IconButton(
      tooltip: '删除$label',
      icon: const Icon(Icons.delete_outline_rounded, color: muted),
      onPressed: () async {
        if (await confirm(
              context,
              '删除这条$label？',
              '顾问后续对话将不再使用它。',
              action: '删除',
            ) &&
            context.mounted) {
          await perform(
            context,
            () => store.change(
              (d) => (d.agent[field] as List).removeWhere((x) => x['id'] == id),
            ),
          );
        }
      },
    );
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
                        '长期财务伙伴 · 以真实账本为依据',
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
          strings(
            '洞察与观察',
            a['insights'] as List? ?? [],
            '顾问从账单中看出的规律，经你确认后会记在这里。',
          ),
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
                        trailing: remove('记忆', 'memories', m['id']),
                      );
                    }).toList(),
                  ),
          ),
          const SectionTitle('我们的约定'),
          Panel(
            child: commitments.isEmpty
                ? const Text(
                    '和顾问商定的小行动会记在这里，到回访日顾问会问问进展。',
                    style: TextStyle(color: muted),
                  )
                : Column(
                    children: commitments.reversed
                        .map(
                          (c) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text('${c['text']}'),
                            subtitle: Text(
                              [
                                PreferenceChanges
                                        .commitmentStatuses[c['status']] ??
                                    '进行中',
                                '回访 ${c['checkDate']}',
                                if (c['note'] != null) '${c['note']}',
                              ].join(' · '),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            trailing: remove('约定', 'commitments', c['id']),
                          ),
                        )
                        .toList(),
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
                '清除画像、标签、偏好、记忆和约定。账单、账户、目标与历史对话会保留。',
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
