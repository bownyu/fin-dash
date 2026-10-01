import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../services/voice_bookkeeping.dart';
import '../services/voice_input.dart';
import 'design.dart';
import 'editors.dart';
import 'preferences.dart';

Future<void> openVoiceEntry(BuildContext context) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        settings: const RouteSettings(name: '/voice-entry'),
        builder: (_) => const VoiceEntryPage(),
      ),
    );

class VoiceRouteObserver extends NavigatorObserver {
  int _open = 0;
  bool get isOpen => _open > 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name == '/voice-entry') _open++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name == '/voice-entry') _open--;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name == '/voice-entry') _open--;
  }
}

class VoiceEntryPage extends StatefulWidget {
  final bool autoStart;
  final VoiceInput? voice;
  const VoiceEntryPage({super.key, this.autoStart = true, this.voice});
  @override
  State<VoiceEntryPage> createState() => _VoiceEntryPageState();
}

class _VoiceEntryPageState extends State<VoiceEntryPage> {
  final transcript = TextEditingController();
  late final voice = widget.voice ?? VoiceInput();
  String? accountId, error;
  String entryId = newId();
  bool initialized = false, listening = false, processing = false;
  bool clarification = false;
  LedgerTx? saved;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (initialized) return;
    initialized = true;
    final store = AppScope.storeOf(context);
    final accounts = store.activeAccounts;
    final preferred = store.data.settings['quickEntryAccountId'];
    accountId = accounts.any((a) => a.id == preferred)
        ? preferred as String
        : accounts.length == 1
        ? accounts.single.id
        : null;
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => listen());
    }
  }

  Future<void> listen() async {
    if (!mounted || listening || processing) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final previous = clarification ? transcript.text.trim() : '';
    setState(() {
      listening = true;
      saved = null;
      error = null;
      entryId = newId();
      if (previous.isEmpty) transcript.clear();
    });
    try {
      final text = await voice.listen();
      if (!mounted) return;
      setState(() => listening = false);
      if (text == null || text.trim().isEmpty) return;
      transcript.text = previous.isEmpty ? text : '$previous；补充：$text';
      await record();
    } catch (e) {
      if (mounted) {
        setState(() {
          listening = false;
          error = e is FormatException ? e.message : '语音识别失败，请重试';
        });
      }
    }
  }

  Future<void> record() async {
    if (processing ||
        listening ||
        transcript.text.trim().isEmpty ||
        saved != null) {
      return;
    }
    final store = AppScope.storeOf(context);
    final ai = AppScope.of(context).ai;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      processing = true;
      error = null;
    });
    try {
      final transaction = await VoiceBookkeeping(
        store,
        ai,
      ).record(transcript.text, entryId: entryId, accountId: accountId);
      if (mounted) {
        setState(() {
          saved = transaction;
          clarification = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e is FormatException ? e.message : '账单未保存，请重试';
          clarification = e is VoiceClarification;
        });
      }
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }

  @override
  void dispose() {
    voice.cancel();
    transcript.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    return PopScope(
      canPop: !processing,
      child: Scaffold(
        appBar: AppBar(title: const Text('语音记账')),
        body: PageList(
          children: [
            const Text(
              '说出用途、金额和账户，信息完整时自动记账。',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              '例如：“今天用银行卡吃午餐花了二十八元”。识别后的文字可以修改，保存后可以撤销。',
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              key: ValueKey('voice-account:$accountId'),
              initialValue: accountId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '默认记账账户',
                hintText: '没说账户时使用，可先选择',
              ),
              items: store.activeAccounts
                  .map(
                    (a) => DropdownMenuItem(value: a.id, child: Text(a.name)),
                  )
                  .toList(),
              onChanged: listening || processing
                  ? null
                  : (value) async {
                      setState(() => accountId = value);
                      await perform(
                        context,
                        () => store.change(
                          (d) => d.settings['quickEntryAccountId'] = value,
                        ),
                      );
                    },
            ),
            const SizedBox(height: 24),
            Center(
              child: SizedBox.square(
                dimension: 88,
                child: FilledButton(
                  style: FilledButton.styleFrom(shape: const CircleBorder()),
                  onPressed: processing
                      ? null
                      : listening
                      ? () => voice.stop()
                      : listen,
                  child: Icon(
                    listening ? Icons.stop_rounded : Icons.mic_rounded,
                    size: 36,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              listening
                  ? '正在听，点击结束并识别'
                  : processing
                  ? '正在分析并记账…'
                  : '点击说一笔',
              textAlign: TextAlign.center,
              style: const TextStyle(color: muted),
            ),
            const SizedBox(height: 20),
            TextField(
              key: const Key('voice-transcript'),
              controller: transcript,
              enabled: !processing && !listening && saved == null,
              minLines: 2,
              maxLines: 5,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: '记账内容',
                hintText: '也可以直接输入一句话',
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(error!, style: const TextStyle(color: coral)),
              ),
            if (saved != null)
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '已记账',
                      style: TextStyle(
                        color: mint,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${saved!.title} · ${saved!.type.label} ${money(saved!.amount)}',
                    ),
                    Text(
                      saved!.type == TxType.transfer
                          ? '${store.account(saved!.fromId)?.name} → ${store.account(saved!.toId)?.name}'
                          : store.account(saved!.accountId)?.name ?? '',
                    ),
                    TextButton(
                      onPressed: processing
                          ? null
                          : () async {
                              final transaction = saved!;
                              setState(() => processing = true);
                              final success = await perform(
                                context,
                                () => VoiceBookkeeping(
                                  store,
                                  AppScope.of(context).ai,
                                ).undo(transaction),
                              );
                              if (mounted) {
                                setState(() {
                                  processing = false;
                                  if (success) {
                                    saved = null;
                                    entryId = newId();
                                    transcript.clear();
                                    error = '已撤销这笔账单';
                                  }
                                });
                              }
                            },
                      child: const Text('撤销这笔账单'),
                    ),
                  ],
                ),
              ),
            if (store.activeAccounts.isEmpty)
              TextButton(
                onPressed: () => openPage(context, const AccountEditor()),
                child: const Text('先添加记账账户'),
              ),
            TextButton(
              onPressed: processing
                  ? null
                  : () => openPage(context, const AiSettingsPage()),
              child: const Text('AI 设置'),
            ),
            TextButton.icon(
              onPressed: () async {
                final supported = await voice.pinWidget();
                if (context.mounted && !supported) {
                  toast(context, '请在安卓桌面长按空白处，选择小部件 → FinDash 语音记账');
                }
              },
              icon: const Icon(Icons.widgets_outlined),
              label: const Text('添加桌面小部件'),
            ),
          ],
        ),
        bottomNavigationBar: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: FilledButton.icon(
                onPressed: processing || listening
                    ? null
                    : saved != null
                    ? listen
                    : record,
                icon: const Icon(Icons.check_rounded),
                label: Text(
                  processing
                      ? '正在记账…'
                      : saved != null
                      ? '再记一笔'
                      : '记录这句话',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
