import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class VoiceEntryPage extends StatefulWidget {
  final bool autoStart;
  final VoiceInput? voice;
  const VoiceEntryPage({super.key, this.autoStart = false, this.voice});
  @override
  State<VoiceEntryPage> createState() => _VoiceEntryPageState();
}

class _VoiceEntryPageState extends State<VoiceEntryPage>
    with WidgetsBindingObserver {
  final transcript = TextEditingController();
  late final voice = widget.voice ?? VoiceInput();
  String? accountId, error;
  String captureState = 'idle';
  bool initialized = false,
      listening = false,
      processing = false,
      saving = false;
  int captureGeneration = 0;
  VoiceDraft? draft;
  LedgerTx? saved;
  VoiceBookkeeping get bookkeeping =>
      VoiceBookkeeping(AppScope.storeOf(context), AppScope.of(context).ai);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) &&
        listening) {
      captureGeneration++;
      voice.cancel();
      setState(() {
        listening = false;
        captureState = 'idle';
      });
    }
  }

  Future<void> listen() async {
    if (!mounted || listening || processing || saving) return;
    final generation = ++captureGeneration;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      listening = true;
      captureState = 'starting';
      error = null;
      draft = null;
      saved = null;
    });
    // Keep the old text until the local model returns a new transcript.
    try {
      final text = await voice.listen(
        onPartial: (text) {
          if (mounted && generation == captureGeneration) {
            setState(() => transcript.text = text);
          }
        },
        onState: (state) {
          if (mounted && generation == captureGeneration) {
            setState(() => captureState = state);
            if (state == 'listening') HapticFeedback.lightImpact();
          }
        },
      );
      if (!mounted || generation != captureGeneration) return;
      setState(() {
        listening = false;
        captureState = 'idle';
      });
      if (text == null || text.trim().isEmpty) return;
      transcript.text = text;
      await preview();
    } catch (e) {
      if (mounted && generation == captureGeneration) {
        setState(() {
          listening = false;
          captureState = 'idle';
          error = e is FormatException ? e.message : '识别未完成，可以重试或编辑文字';
        });
      }
    }
  }

  Future<void> stop() async {
    if (captureState != 'listening') return;
    setState(() => captureState = 'recognizing');
    try {
      await voice.stop();
    } catch (e) {
      await voice.cancel();
      captureGeneration++;
      if (mounted) {
        setState(() {
          listening = false;
          error = e is FormatException ? e.message : '识别未完成，请重试';
        });
      }
    }
  }

  Future<void> preview() async {
    if (listening || processing || saving || transcript.text.trim().isEmpty) {
      return;
    }
    final service = bookkeeping;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      processing = true;
      error = null;
      draft = null;
      saved = null;
    });
    try {
      final result = await service.preview(
        transcript.text,
        entryId: newId(),
        accountId: accountId,
      );
      if (mounted) setState(() => draft = result);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException ? e.message : '暂时无法整理账单，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => processing = false);
    }
  }

  Future<void> confirm() async {
    if (draft == null || saving || processing || listening) return;
    final service = bookkeeping;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final tx = await service.confirm(draft!);
      if (mounted) {
        HapticFeedback.lightImpact();
        setState(() {
          saved = tx;
          draft = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException ? e.message : '保存失败，账单预览已保留，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> undo() async {
    final service = bookkeeping;
    final tx = saved!;
    setState(() => saving = true);
    final success = await perform(context, () => service.undo(tx));
    if (mounted) {
      setState(() {
        saving = false;
        if (success) {
          saved = null;
          transcript.clear();
          error = null;
        }
      });
    }
  }

  @override
  void dispose() {
    captureGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    voice.cancel();
    transcript.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    final busy = processing || saving;
    final status = listening
        ? switch (captureState) {
            'starting' => '正在启动麦克风…',
            'recognizing' => '正在本地转文字…',
            _ => '正在录音 · 说完请点结束，停顿不会结束录音',
          }
        : processing
        ? 'AI 正在整理账单…'
        : saving
        ? '正在保存…'
        : saved != null
        ? '已保存到账本'
        : draft != null
        ? '核对下方账单，确认后保存'
        : '点一下开始说话，说完再点一下';
    return PopScope(
      canPop: !saving,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('语音记账'),
          actions: [
            PopupMenuButton<String>(
              tooltip: '更多',
              enabled: !busy && !listening,
              onSelected: (value) async {
                if (value == 'settings') {
                  openPage(context, const AiSettingsPage());
                } else {
                  final supported = await voice.pinWidget();
                  if (context.mounted && !supported) {
                    toast(context, '在安卓桌面长按空白处，选择小部件 → FinDash 语音记账');
                  }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'widget', child: Text('添加桌面小部件')),
                PopupMenuItem(value: 'settings', child: Text('AI 设置')),
              ],
            ),
          ],
        ),
        body: PageList(
          children: [
            const Text(
              '说一句，核对后记账',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text('例如：蜜雪冰城十块钱，中国银行', style: TextStyle(color: muted)),
            const SizedBox(height: 8),
            const Text(
              '语音在本机转文字；AI 整理账单需要连接已配置的接口。',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            const SizedBox(height: 20),
            TextField(
              key: const Key('voice-transcript'),
              controller: transcript,
              enabled: !busy && !listening && saved == null,
              minLines: 2,
              maxLines: 4,
              maxLength: 1000,
              decoration: InputDecoration(
                labelText: listening ? '结束录音后显示文字' : '记账内容',
                hintText: '本地识别文字会出现在这里，也可以直接输入',
                counterText: '',
              ),
              onChanged: (_) => setState(() {
                draft = null;
                error = null;
              }),
            ),
            const SizedBox(height: 16),
            if (draft == null && saved == null && !listening)
              DropdownButtonFormField<String>(
                key: ValueKey('voice-account:$accountId'),
                initialValue: store.activeAccounts.any((a) => a.id == accountId)
                    ? accountId
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '没说账户时使用',
                  hintText: '选择默认账户（可选）',
                ),
                items: store.activeAccounts
                    .map(
                      (a) => DropdownMenuItem(value: a.id, child: Text(a.name)),
                    )
                    .toList(),
                onChanged: busy
                    ? null
                    : (value) => setState(() => accountId = value),
              ),
            if (store.activeAccounts.isEmpty)
              TextButton(
                onPressed: busy || listening
                    ? null
                    : () => openPage(context, const AccountEditor()),
                child: const Text('先添加记账账户'),
              ),
            if (draft != null)
              VoiceDraftCard(
                key: ValueKey(draft!.entryId),
                draft: draft!,
                enabled: !busy,
                onChanged: (value) => setState(() {
                  draft = value;
                  error = null;
                }),
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
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${saved!.title} · ${saved!.type.label} ${money(saved!.amount)}',
                      style: const TextStyle(fontSize: 20),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      saved!.type == TxType.transfer
                          ? '${store.account(saved!.fromId)?.name} → ${store.account(saved!.toId)?.name}'
                          : store.account(saved!.accountId)?.name ?? '',
                    ),
                    TextButton(
                      onPressed: busy ? null : undo,
                      child: const Text('撤销这笔账单'),
                    ),
                  ],
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Semantics(
                  liveRegion: true,
                  child: Text(error!, style: const TextStyle(color: coral)),
                ),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (listening || busy) ...[
                    LinearProgressIndicator(
                      key: const Key('voice-progress'),
                      color: listening && captureState == 'listening'
                          ? coral
                          : primary,
                    ),
                    const SizedBox(height: 10),
                  ],
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: muted, fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          key: const Key('voice-microphone'),
                          style: FilledButton.styleFrom(
                            backgroundColor: listening ? coral : null,
                            minimumSize: const Size(0, 56),
                          ),
                          onPressed:
                              busy || (listening && captureState != 'listening')
                              ? null
                              : listening
                              ? stop
                              : listen,
                          icon: Icon(
                            listening ? Icons.stop_rounded : Icons.mic_rounded,
                          ),
                          label: Text(
                            listening
                                ? '结束说话'
                                : saved != null
                                ? '再记一笔'
                                : draft != null
                                ? '重新说'
                                : '开始说话',
                          ),
                        ),
                      ),
                      if (!listening &&
                          saved == null &&
                          transcript.text.trim().isNotEmpty) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            key: const Key('voice-confirm'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 56),
                            ),
                            onPressed:
                                busy ||
                                    (draft != null &&
                                        draft!.problem(store.data) != null)
                                ? null
                                : draft == null
                                ? preview
                                : confirm,
                            icon: Icon(
                              draft == null
                                  ? Icons.receipt_long_outlined
                                  : Icons.check_rounded,
                            ),
                            label: Text(draft == null ? '生成账单' : '确认保存'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class VoiceDraftCard extends StatelessWidget {
  final VoiceDraft draft;
  final bool enabled;
  final ValueChanged<VoiceDraft> onChanged;
  const VoiceDraftCard({
    super.key,
    required this.draft,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    final fields = draft.fields;
    final type = TxType.values
        .where((t) => t.name == fields['type'])
        .firstOrNull;
    final categories = store.data.categories
        .where((c) => c.type == type)
        .map((c) => c.name)
        .toSet();
    final valid = draft.problem(store.data) == null;
    void change(String key, dynamic value) =>
        onChanged(draft.update({key: value}));
    Widget account(String field, String label) {
      final value = fields[field];
      final exists = store.activeAccounts.any((a) => a.id == value);
      return DropdownButtonFormField<String>(
        key: ValueKey('$field:$value'),
        initialValue: exists ? value as String : null,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          hintText: '请选择',
          errorText: exists ? null : '选择实际记账账户',
        ),
        items: store.activeAccounts
            .map((a) => DropdownMenuItem(value: a.id, child: Text(a.name)))
            .toList(),
        onChanged: enabled ? (v) => change(field, v) : null,
      );
    }

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            valid ? '待确认账单' : '补全后即可确认',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            valid ? '尚未入账 · 以下内容都可以修改' : '点选账户、类型，或直接补填缺失内容',
            style: const TextStyle(color: muted, fontSize: 12),
          ),
          if (draft.message != null && !valid)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                draft.message!,
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: TxType.values
                .map(
                  (t) => ChoiceChip(
                    label: Text(t.label),
                    selected: t == type,
                    onSelected: enabled
                        ? (_) {
                            final choices = store.data.categories.where(
                              (c) => c.type == t,
                            );
                            onChanged(
                              draft.update({
                                'type': t.name,
                                'category': t == TxType.transfer
                                    ? '转账'
                                    : choices.any(
                                        (c) => c.name == fields['category'],
                                      )
                                    ? fields['category']
                                    : choices
                                              .where((c) => c.name == '其他')
                                              .firstOrNull
                                              ?.name ??
                                          choices.firstOrNull?.name,
                              }),
                            );
                          }
                        : null,
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('voice-draft-amount'),
            initialValue: fields['amountCents'] is int
                ? moneyInput(fields['amountCents'])
                : '',
            enabled: enabled,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '金额',
              prefixText: '¥ ',
              hintText: '填写金额',
            ),
            onChanged: (value) {
              int? cents;
              try {
                cents = parseMoney(value);
              } on FormatException {
                cents = null;
              }
              change('amountCents', cents);
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('voice-draft-title'),
            initialValue: fields['title'] is String
                ? fields['title'] as String
                : '',
            enabled: enabled,
            decoration: const InputDecoration(
              labelText: '用途 / 商品',
              hintText: '填写用途',
            ),
            onChanged: (value) => change('title', value),
          ),
          const SizedBox(height: 12),
          if (type == TxType.transfer) ...[
            account('transferFromId', '转出账户'),
            const SizedBox(height: 12),
            account('transferToId', '转入账户'),
          ] else
            account('accountId', type == TxType.income ? '收款账户' : '付款账户'),
          const SizedBox(height: 12),
          if (type != TxType.transfer)
            DropdownButtonFormField<String>(
              key: ValueKey('category:${fields['category']}:${type?.name}'),
              initialValue: categories.contains(fields['category'])
                  ? fields['category'] as String
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '分类',
                hintText: '选择分类',
              ),
              items: categories
                  .map(
                    (name) => DropdownMenuItem(value: name, child: Text(name)),
                  )
                  .toList(),
              onChanged: enabled ? (v) => change('category', v) : null,
            ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: !enabled
                ? null
                : () async {
                    final previous = DateTime.tryParse('${fields['date']}');
                    final now = DateTime.now();
                    final date = await showDatePicker(
                      context: context,
                      initialDate: previous ?? now,
                      firstDate: DateTime(1970),
                      lastDate: DateTime(2100),
                    );
                    if (date != null) {
                      change(
                        'date',
                        DateTime(
                          date.year,
                          date.month,
                          date.day,
                          previous?.hour ?? now.hour,
                          previous?.minute ?? now.minute,
                        ).toIso8601String(),
                      );
                    }
                  },
            icon: const Icon(Icons.calendar_today_outlined, size: 16),
            label: Text(
              DateTime.tryParse('${fields['date']}') == null
                  ? '选择交易日期'
                  : dayKey(DateTime.parse(fields['date'])),
            ),
          ),
          if (!valid)
            Text(
              draft.problem(store.data)!,
              style: const TextStyle(color: coral, fontSize: 12),
            ),
        ],
      ),
    );
  }
}
