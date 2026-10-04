import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../domain/models.dart';
import '../services/voice_bookkeeping.dart';
import '../services/voice_input.dart';
import 'design.dart';
import 'interaction.dart';
import 'editors.dart';
import 'preferences.dart';

/// Opens voice bookkeeping above the current page. Dragging stays off: a drag
/// dismissal pops the route without asking about an unsaved draft.
Future<void> showVoiceEntry(
  BuildContext context, {
  bool autoStart = false,
  String? initialText,
  String? entryId,
  VoiceInput? voice,
}) {
  if (!routeReady(context)) return Future.value();
  FocusManager.instance.primaryFocus?.unfocus();
  // One instance keeps keyboard-driven sheet rebuilds out of the content.
  final sheet = VoiceEntrySheet(
    autoStart: autoStart,
    initialText: initialText,
    entryId: entryId,
    voice: voice,
  );
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: false,
    routeSettings: const RouteSettings(name: '/voice-entry'),
    builder: (_) => sheet,
  );
}

/// Microphone levels of the current capture. The meter paints from it
/// directly, so ten updates a second never rebuild the sheet.
class VoiceLevels extends ChangeNotifier {
  static const _speech = .3;
  final samples = List<double>.filled(24, 0);
  int count = 0;
  bool _heard = false;
  void add(double level) {
    samples.setRange(0, samples.length - 1, samples, 1);
    samples[samples.length - 1] = level.clamp(0.0, 1.0).toDouble();
    count++;
    _heard = _heard || level >= _speech;
    notifyListeners();
  }

  void reset() {
    samples.fillRange(0, samples.length, 0);
    count = 0;
    _heard = false;
    notifyListeners();
  }

  /// Samples arrive every 100 ms while the microphone records.
  Duration get elapsed => Duration(milliseconds: count * 100);

  /// Three seconds without speech-level sound usually means a covered or
  /// distant microphone. It is only a hint: silence never ends a recording.
  bool get silent => !_heard && count >= 30;
}

class VoiceEntrySheet extends StatefulWidget {
  final bool autoStart;
  final VoiceInput? voice;
  final String? initialText, entryId;
  const VoiceEntrySheet({
    super.key,
    this.autoStart = false,
    this.voice,
    this.initialText,
    this.entryId,
  });
  @override
  State<VoiceEntrySheet> createState() => _VoiceEntrySheetState();
}

class _VoiceEntrySheetState extends State<VoiceEntrySheet>
    with WidgetsBindingObserver {
  final transcript = TextEditingController();
  final amount = TextEditingController();
  final title = TextEditingController();
  final amountFocus = FocusNode();
  final titleFocus = FocusNode();
  final levels = VoiceLevels();
  late final voice = widget.voice ?? VoiceInput();
  String? accountId, error, notice, pendingEntryId, parsingEntryId;
  String captureState = 'idle', live = '';
  bool initialized = false,
      listening = false,
      processing = false,
      saving = false,
      editing = false;
  int captureGeneration = 0, flash = 0;

  /// Fields a spoken correction just changed; they flash once.
  Set<String> changed = const {};
  VoiceBatch? batch;
  int selectedEntry = 0;
  VoiceDraft? get draft => batch?.entries[selectedEntry];
  set draft(VoiceDraft? value) {
    if (value == null) {
      batch = null;
      selectedEntry = 0;
    } else {
      batch =
          batch?.update(value) ??
          VoiceBatch(value.entryId, [value], transcript: value.transcript);
    }
  }

  List<LedgerTx>? saved;
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
    pendingEntryId = widget.entryId;
    transcript.text = widget.initialText ?? '';
    final store = AppScope.storeOf(context);
    final accounts = store.activeAccounts;
    final preferred = store.data.settings['quickEntryAccountId'];
    accountId = accounts.any((a) => a.id == preferred)
        ? preferred as String
        : accounts.length == 1
        ? accounts.single.id
        : null;
    final stored = (store.data.extras['voiceDrafts'] as Map?)?[widget.entryId];
    if (!widget.autoStart && stored is Map && stored['draft'] is Map) {
      batch = VoiceBatch.fromJson(
        Json.from(stored['draft'] as Map),
        transcript: '${stored['text'] ?? transcript.text}',
      );
      transcript.text = batch!.transcript;
      _fill(draft!);
    }
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
        live = '';
        error = '录音因应用进入后台而中断，本次录音未保存。已有文字仍保留，请重新录音。';
      });
    }
  }

  /// With [correction] the new words amend the draft under review instead of
  /// replacing it, so one misheard word never costs the whole sentence.
  Future<void> listen({bool correction = false}) async {
    if (!mounted || listening || processing || saving) return;
    final base = correction ? batch : null;
    final generation = ++captureGeneration;
    FocusManager.instance.primaryFocus?.unfocus();
    levels.reset();
    setState(() {
      listening = true;
      captureState = 'starting';
      error = null;
      notice = null;
      live = '';
      editing = false;
      if (base == null) {
        draft = null;
        changed = const {};
        if (saved != null) {
          saved = null;
          transcript.clear();
        }
      }
    });
    // Keep the old text until the local model returns a new transcript.
    try {
      final text = await voice.listen(
        onPartial: (text) {
          if (mounted && generation == captureGeneration) {
            setState(() => live = text);
          }
        },
        onState: (state) {
          if (mounted && generation == captureGeneration) {
            setState(() => captureState = state);
            if (state == 'listening') HapticFeedback.lightImpact();
          }
        },
        onLevel: (level) {
          if (mounted && generation == captureGeneration) levels.add(level);
        },
      );
      if (!mounted || generation != captureGeneration) return;
      setState(() {
        listening = false;
        captureState = 'idle';
        live = '';
      });
      if (text == null || text.trim().isEmpty) return;
      if (base != null) {
        await preview(correction: text);
      } else {
        transcript.text = text;
        await preview();
      }
    } catch (e) {
      if (mounted && generation == captureGeneration) {
        setState(() {
          listening = false;
          captureState = 'idle';
          live = '';
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
          live = '';
          error = e is FormatException ? e.message : '识别未完成，请重试';
        });
      }
    }
  }

  void _fill(VoiceDraft value) {
    final cents = value.fields['amountCents'];
    amount.text = cents is int ? moneyInput(cents) : '';
    final name = value.fields['title'];
    title.text = name is String ? name : '';
  }

  Future<void> preview({String? correction}) async {
    final base = correction == null ? null : batch;
    final previous = draft;
    if (listening || processing || saving) return;
    if (base == null && transcript.text.trim().isEmpty) return;
    final service = bookkeeping;
    final entryId = base?.entryId ?? (pendingEntryId ??= newId());
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      processing = true;
      parsingEntryId = entryId;
      error = null;
      notice = null;
      editing = false;
      if (base == null) {
        draft = null;
        saved = null;
        changed = const {};
      }
    });
    try {
      final result = await service.previewBatch(
        correction ?? transcript.text,
        entryId: entryId,
        accountId: accountId,
        base: base,
        selectedEntryId: previous?.entryId,
      );
      if (!mounted) return;
      final current = result.entries[selectedEntry];
      _fill(current);
      setState(() {
        if (previous != null && base != null) {
          changed = {
            for (final key in {...previous.fields.keys, ...current.fields.keys})
              if (previous.fields[key] != current.fields[key]) key,
          };
          flash++;
          transcript.text = result.transcript;
        }
        batch = result;
      });
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
      final tx = await service.confirmBatch(batch!);
      if (mounted) {
        HapticFeedback.lightImpact();
        setState(() {
          saved = tx;
          draft = null;
          editing = false;
          changed = const {};
          // The next bill in this sheet needs its own entry.
          pendingEntryId = null;
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

  // Messages stay inside the sheet: a snack bar would land on the page below.
  Future<void> undo() async {
    final service = bookkeeping;
    final tx = saved!;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await service.undoBatch(tx);
      if (mounted) {
        setState(() {
          saved = null;
          transcript.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e is FormatException ? e.message : '撤销未完成，请重试');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void update(VoiceDraft value) => setState(() {
    draft = value;
    error = null;
  });

  void selectEntry(int index) => setState(() {
    selectedEntry = index;
    _fill(draft!);
    changed = const {};
    error = null;
  });

  /// Takes the user straight to the first field that blocks saving.
  Future<void> fix(String field) async {
    final store = AppScope.storeOf(context);
    final index =
        batch?.entries.indexWhere((e) => e.problem(store.data) != null) ?? -1;
    if (index >= 0 && index != selectedEntry) selectEntry(index);
    if (_accountFields.contains(field) && store.activeAccounts.isEmpty) {
      await openPage(context, const AccountEditor());
      return;
    }
    if (field == 'amountCents') {
      amountFocus.requestFocus();
    } else if (field == 'title') {
      titleFocus.requestFocus();
    } else {
      await pick(field);
    }
  }

  Future<void> pick(String field) async {
    final current = draft;
    if (current == null) return;
    final next = await _pickDraftField(context, current, field);
    if (next != null && mounted && identical(draft, current)) update(next);
  }

  @override
  void dispose() {
    captureGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    voice.cancel();
    for (final controller in [transcript, amount, title]) {
      controller.dispose();
    }
    amountFocus.dispose();
    titleFocus.dispose();
    levels.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    final colors = WalletColors.of(context);
    final busy = processing || saving;
    final hasText = transcript.text.trim().isNotEmpty;
    final current = draft;
    final problem = batch?.problem(store.data);
    final incomplete = batch?.entries
        .where((e) => e.problem(store.data) != null)
        .firstOrNull;
    final blocking = incomplete?.missing(store.data).firstOrNull;
    final recording = listening && captureState == 'listening';
    final queued =
        processing &&
        AppScope.of(
          context,
        ).ai.voiceQueue.waiting.containsKey(parsingEntryId) &&
        store.aiStatus != '解析语音账单…';
    // While a draft stays on screen during capture or parsing, the new words
    // are a correction to it.
    final status = listening
        ? switch (captureState) {
            'starting' => '正在启动麦克风…',
            'recognizing' => '正在本地转文字…',
            _ =>
              current != null ? '正在录音 · 说出要修改或补充的内容' : '正在录音 · 说完点结束，停顿不会结束录音',
          }
        : processing
        ? (queued
              ? '已排队，文字草稿已保存…'
              : current != null
              ? 'AI 正在修改账单…'
              : 'AI 正在整理账单…')
        : saving
        ? '正在保存…'
        : saved != null
        ? '已保存到账本'
        : current != null
        ? (problem == null ? '核对后确认保存 · 点麦克风可以说一句修改' : '补全标红的内容后即可保存')
        : '点一下开始说话，说完再点一下';
    final showField =
        !listening &&
        ((current == null && saved == null && !processing) || editing);
    final statusStyle = TextStyle(color: colors.secondary, fontSize: 12);
    final Widget result = saved != null
        ? Padding(
            key: ValueKey('saved:${saved!.first.id}'),
            padding: const EdgeInsets.only(top: 16),
            child: _SavedReceipt(
              transactions: saved!,
              onUndo: busy ? null : undo,
            ),
          )
        : current != null
        ? Padding(
            key: ValueKey('draft:${current.entryId}'),
            padding: const EdgeInsets.only(top: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (batch!.entries.length > 1) ...[
                  Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '识别出 ${batch!.entries.length} 笔，请逐笔核对',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        for (var i = 0; i < batch!.entries.length; i++)
                          ListTile(
                            key: ValueKey('voice-entry-$i'),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            selected: selectedEntry == i,
                            title: Text(
                              '${i + 1}. ${batch!.entries[i].fields['title'] ?? '用途待补充'}',
                            ),
                            subtitle: Text(
                              store
                                      .account(
                                        batch!.entries[i].fields['accountId'],
                                      )
                                      ?.name ??
                                  (batch!.entries[i].fields['type'] ==
                                          'transfer'
                                      ? '转账'
                                      : '账户待选择'),
                            ),
                            trailing: Text(
                              batch!.entries[i].fields['amountCents'] is int
                                  ? privateMoney(
                                      context,
                                      batch!.entries[i].fields['amountCents']
                                          as int,
                                    )
                                  : '金额待补充',
                              style: TextStyle(
                                color:
                                    batch!.entries[i].problem(store.data) ==
                                        null
                                    ? colors.ink
                                    : coral,
                              ),
                            ),
                            onTap: busy || listening
                                ? null
                                : () => selectEntry(i),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('正在核对第 ${selectedEntry + 1} 笔', style: statusStyle),
                  const SizedBox(height: 8),
                ],
                VoiceReceiptCard(
                  key: ValueKey(current.entryId),
                  draft: current,
                  enabled: !busy && !listening,
                  working: processing || listening,
                  amount: amount,
                  title: title,
                  amountFocus: amountFocus,
                  titleFocus: titleFocus,
                  changed: changed,
                  flash: flash,
                  onChanged: update,
                  onPick: pick,
                ),
              ],
            ),
          )
        : processing
        ? const Padding(
            key: ValueKey('parsing'),
            padding: EdgeInsets.only(top: 16),
            child: _ReceiptSkeleton(),
          )
        : const SizedBox.shrink(key: ValueKey('empty'));
    final Widget? next = listening
        ? null
        : processing
        ? FilledButton.tonal(
            onPressed: parsingEntryId == null
                ? null
                : () => AppScope.of(context).ai.cancelVoice(parsingEntryId!),
            child: const Text('停止解析'),
          )
        : saving
        ? const FilledButton(onPressed: null, child: Text('正在保存…'))
        : saved != null
        ? FilledButton(
            onPressed: () => Navigator.maybePop(context),
            child: const Text('完成'),
          )
        : current != null
        ? (problem == null || blocking == null
              ? FilledButton.icon(
                  key: const Key('voice-confirm'),
                  onPressed: problem == null ? confirm : null,
                  icon: const Icon(Icons.check_rounded),
                  label: Text(
                    batch!.entries.length == 1
                        ? '确认保存'
                        : '确认保存 ${batch!.entries.length} 笔',
                  ),
                )
              : FilledButton.icon(
                  key: const Key('voice-fix'),
                  onPressed: () => fix(blocking),
                  icon: const Icon(Icons.edit_rounded),
                  label: Text(
                    _fixLabel(
                      blocking,
                      incomplete?.fields['type'],
                      store.activeAccounts.isEmpty,
                    ),
                  ),
                ))
        : hasText
        ? FilledButton.icon(
            key: const Key('voice-confirm'),
            onPressed: preview,
            icon: const Icon(Icons.receipt_long_outlined),
            label: const Text('生成账单'),
          )
        : null;
    return EditorGuard(
      busy: saving,
      hasChanges: () =>
          listening ||
          processing ||
          draft != null ||
          (saved == null && transcript.text.trim().isNotEmpty),
      child: KeyboardInsetPadding(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .9,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '语音记账',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: '更多',
                      enabled: !busy && !listening,
                      onSelected: (value) async {
                        if (value == 'settings') {
                          openPage(context, const AiSettingsPage());
                        } else {
                          final supported = await voice.pinWidget();
                          if (mounted && !supported) {
                            setState(
                              () => notice = '在安卓桌面长按空白处，选择小部件 → FinDash 语音记账',
                            );
                          }
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'widget',
                          child: Row(
                            children: [
                              Icon(Icons.widgets_outlined, size: 20),
                              SizedBox(width: 12),
                              Text('添加桌面小部件'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'settings',
                          child: Row(
                            children: [
                              Icon(Icons.settings_outlined, size: 20),
                              SizedBox(width: 12),
                              Text('AI 设置'),
                            ],
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: AnimatedSize(
                    duration: motionDuration(context),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!listening &&
                            current == null &&
                            saved == null &&
                            !processing &&
                            !hasText) ...[
                          const Text(
                            '说一句，核对后记账',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '例如：蜜雪冰城十块钱，中国银行',
                            style: TextStyle(color: colors.secondary),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '语音在本机转文字；AI 整理账单需要连接已配置的接口。',
                            style: statusStyle,
                          ),
                          const SizedBox(height: 16),
                        ],
                        if (listening)
                          _LiveCapture(
                            heard: live,
                            said: current == null ? null : transcript.text,
                          )
                        else if (showField)
                          TextField(
                            key: const Key('voice-transcript'),
                            controller: transcript,
                            enabled: !busy,
                            autofocus: editing,
                            minLines: 2,
                            maxLines: 4,
                            maxLength: 1000,
                            decoration: const InputDecoration(
                              labelText: '记账内容',
                              hintText: '本地识别文字会出现在这里，也可以直接输入',
                              counterText: '',
                            ),
                            onChanged: (_) {
                              if (draft == null &&
                                  error == null &&
                                  hasText ==
                                      transcript.text.trim().isNotEmpty) {
                                return;
                              }
                              setState(() {
                                draft = null;
                                error = null;
                                changed = const {};
                              });
                            },
                          )
                        else if (hasText)
                          _TranscriptLine(
                            text: transcript.text,
                            onEdit: current == null || busy
                                ? null
                                : () => setState(() => editing = true),
                            onRestart: current == null || busy
                                ? null
                                : () => listen(),
                          ),
                        if (store.activeAccounts.isEmpty &&
                            saved == null &&
                            !listening)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: busy
                                  ? null
                                  : () => openPage(
                                      context,
                                      const AccountEditor(),
                                    ),
                              child: const Text('先添加记账账户'),
                            ),
                          ),
                        AnimatedSwitcher(
                          duration: motionDuration(context, 240),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween(
                                    begin: const Offset(0, .04),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.topCenter,
                            children: [...previous, ?current],
                          ),
                          child: result,
                        ),
                        if (error != null || notice != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                error ?? notice!,
                                style: TextStyle(
                                  color: error != null
                                      ? coral
                                      : colors.secondary,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Semantics(
                        liveRegion: true,
                        child: recording
                            ? ListenableBuilder(
                                listenable: levels,
                                builder: (_, _) => Text(
                                  levels.silent ? '还没有听到声音，请靠近麦克风说话' : status,
                                  textAlign: TextAlign.center,
                                  style: levels.silent
                                      ? const TextStyle(
                                          color: coral,
                                          fontSize: 12,
                                        )
                                      : statusStyle,
                                ),
                              )
                            : Text(
                                status,
                                textAlign: TextAlign.center,
                                style: statusStyle,
                              ),
                      ),
                      const SizedBox(height: 10),
                      _VoiceBar(
                        label: recording
                            ? '结束说话'
                            : listening
                            ? (captureState == 'starting' ? '启动中…' : '正在转文字…')
                            : current != null
                            ? '说一句修改'
                            : saved != null
                            ? '再记一笔'
                            : '开始说话',
                        recording: recording,
                        working: listening && !recording,
                        levels: levels,
                        onPressed: recording
                            ? stop
                            : listening || busy
                            ? null
                            : () => listen(correction: current != null),
                        next: next,
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

const _accountFields = {'accountId', 'transferFromId', 'transferToId'};

String _accountLabel(String field, Object? type) => switch (field) {
  'transferFromId' => '转出账户',
  'transferToId' => '转入账户',
  _ => type == TxType.income.name ? '收款账户' : '付款账户',
};

String _fixLabel(String field, Object? type, bool noAccounts) {
  if (_accountFields.contains(field)) {
    return noAccounts ? '先添加账户' : '选择${_accountLabel(field, type)}';
  }
  return switch (field) {
    'amountCents' => '填写金额',
    'title' => '填写用途',
    'type' => '选择类型',
    _ => '选择分类',
  };
}

/// Switching type keeps a category that exists for it; otherwise "其他" is
/// filled in and marked as a guess for the user to check.
VoiceDraft _withType(VoiceDraft draft, TxType type, WalletData data) {
  final choices = data.categories.where((c) => c.type == type);
  final category = type == TxType.transfer
      ? '转账'
      : choices.any((c) => c.name == draft.fields['category'])
      ? draft.fields['category']
      : choices.where((c) => c.name == '其他').firstOrNull?.name ??
            choices.firstOrNull?.name;
  final next = draft.update({'type': type.name, 'category': category});
  return category == draft.fields['category'] || type == TxType.transfer
      ? next
      : VoiceDraft(
          next.entryId,
          next.fields,
          transcript: next.transcript,
          assumed: {...next.assumed, 'category'},
        );
}

Future<VoiceDraft?> _pickDraftField(
  BuildContext context,
  VoiceDraft draft,
  String field,
) async {
  final store = AppScope.storeOf(context);
  final fields = draft.fields;
  final type = TxType.values.where((t) => t.name == fields['type']).firstOrNull;
  switch (field) {
    case 'date':
      final previous = DateTime.tryParse('${fields['date']}');
      final now = DateTime.now();
      final date = await showDatePicker(
        context: context,
        initialDate: previous ?? now,
        firstDate: DateTime(1970),
        lastDate: DateTime(2100),
      );
      if (date == null) return null;
      return draft.update({
        'date': DateTime(
          date.year,
          date.month,
          date.day,
          previous?.hour ?? now.hour,
          previous?.minute ?? now.minute,
        ).toIso8601String(),
      });
    case 'type':
      final name = await pickWalletOption<String>(
        context,
        title: '类型',
        items: [
          for (final t in TxType.values)
            DropdownMenuItem(value: t.name, child: Text(t.label)),
        ],
        label: (name) => TxType.values.byName(name).label,
        selected: type?.name,
      );
      return name == null
          ? null
          : _withType(draft, TxType.values.byName(name), store.data);
    case 'category':
      final choices = store.data.categories.where((c) => c.type == type);
      WalletCategory of(String name) =>
          choices.firstWhere((c) => c.name == name);
      final name = await pickWalletOption<String>(
        context,
        title: '分类',
        grid: true,
        items: [
          for (final name in {for (final c in choices) c.name})
            DropdownMenuItem(value: name, child: Text(name)),
        ],
        label: (name) => name,
        icon: (name) => iconOf(of(name).icon),
        color: (name) => colorOf(of(name).color),
        selected: fields['category'] is String
            ? fields['category'] as String
            : null,
      );
      return name == null ? null : draft.update({'category': name});
    default:
      final opposite = switch (field) {
        'transferFromId' => fields['transferToId'],
        'transferToId' => fields['transferFromId'],
        _ => null,
      };
      final id = await pickWalletOption<String>(
        context,
        title: _accountLabel(field, fields['type']),
        items: accountOptions(
          store.activeAccounts.where((a) => a.id != opposite).toList(),
        ),
        label: (id) => store.account(id)?.name ?? '',
        selected: fields[field] is String ? fields[field] as String : null,
      );
      return id == null ? null : draft.update({field: id});
  }
}

/// The record button, which becomes a stop button with a live level meter and
/// shrinks to a round "say a correction" button once there is a [next] step.
class _VoiceBar extends StatelessWidget {
  final String label;
  final bool recording, working;
  final VoiceLevels levels;
  final VoidCallback? onPressed;
  final Widget? next;
  const _VoiceBar({
    required this.label,
    required this.recording,
    required this.working,
    required this.levels,
    required this.onPressed,
    required this.next,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const round = 56.0, gap = 12.0;
      final wide = next == null;
      final width = wide ? box.maxWidth : round;
      final duration = motionDuration(context, 260);
      final colors = WalletColors.of(context);
      final base = recording
          ? coral
          : colors.dark
          ? primary
          : colors.ink;
      const ink = Colors.white;
      const text = TextStyle(
        color: ink,
        fontSize: 15,
        fontWeight: FontWeight.w700,
      );
      Widget label_(String value) => Flexible(
        child: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(
            value,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            style: text,
          ),
        ),
      );
      final content = recording
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  const Icon(Icons.stop_rounded, color: ink),
                  label_(label),
                  Padding(
                    padding: const EdgeInsets.only(left: 10, right: 12),
                    child: ListenableBuilder(
                      listenable: levels,
                      builder: (_, _) => Text(
                        _clock(levels.elapsed),
                        style: text.copyWith(
                          fontWeight: FontWeight.w600,
                          color: ink.withValues(alpha: .85),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: SizedBox(
                      height: 26,
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: _MeterPainter(
                            levels,
                            ink.withValues(alpha: .9),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (working)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: ink,
                    ),
                  )
                else
                  const Icon(Icons.mic_rounded, color: ink),
                if (wide) label_(label),
              ],
            );
      final button = AnimatedContainer(
        duration: duration,
        decoration: ShapeDecoration(
          color: onPressed == null && !working
              ? base.withValues(alpha: .45)
              : base,
          shape: const StadiumBorder(),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onPressed,
            // The content is laid out at its final width and clipped while the
            // button grows or shrinks, so nothing reflows mid-animation.
            child: ClipRect(
              child: OverflowBox(
                alignment: wide ? Alignment.centerLeft : Alignment.center,
                minWidth: width,
                maxWidth: width,
                child: content,
              ),
            ),
          ),
        ),
      );
      return SizedBox(
        height: round,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedPositioned(
              duration: duration,
              curve: Curves.easeOutCubic,
              top: 0,
              bottom: 0,
              left: 0,
              width: width,
              child: KeyedSubtree(
                key: const Key('voice-microphone'),
                child: wide ? button : Tooltip(message: label, child: button),
              ),
            ),
            // The next step sits above the shrinking record button, so a tap
            // lands on what is appearing. A fading-out step takes no taps.
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: max(0.0, box.maxWidth - round - gap),
              child: IgnorePointer(
                ignoring: next == null,
                child: AnimatedSwitcher(
                  duration: duration,
                  child: next == null
                      ? const SizedBox.shrink(key: ValueKey('none'))
                      : KeyedSubtree(
                          key: const ValueKey('action'),
                          child: SizedBox.expand(child: next),
                        ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

String _clock(Duration value) =>
    '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

class _MeterPainter extends CustomPainter {
  final VoiceLevels levels;
  final Color color;
  _MeterPainter(this.levels, this.color) : super(repaint: levels);
  @override
  void paint(Canvas canvas, Size size) {
    final count = levels.samples.length;
    final step = size.width / count;
    final paint = Paint()
      ..color = color
      ..strokeWidth = (step * .55).clamp(1.5, 4.0).toDouble()
      ..strokeCap = StrokeCap.round;
    final middle = size.height / 2;
    for (var i = 0; i < count; i++) {
      final half = max(1.0, levels.samples[i] * middle);
      final x = step * i + step / 2;
      canvas.drawLine(
        Offset(x, middle - half),
        Offset(x, middle + half),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) =>
      old.levels != levels || old.color != color;
}

class _LiveCapture extends StatelessWidget {
  final String heard;

  /// Earlier words when this capture corrects an existing draft.
  final String? said;
  const _LiveCapture({required this.heard, required this.said});
  @override
  Widget build(BuildContext context) {
    final colors = WalletColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (said != null) ...[
          _TranscriptLine(text: said!),
          const SizedBox(height: 8),
        ],
        Text(
          heard.isNotEmpty
              ? (said == null ? heard : '补充：$heard')
              : said == null
              ? '正在听…'
              : '例如：“改成招商银行”“金额是十五块”',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: heard.isEmpty ? colors.secondary : colors.ink,
          ),
        ),
      ],
    );
  }
}

class _TranscriptLine extends StatelessWidget {
  final String text;
  final VoidCallback? onEdit, onRestart;
  const _TranscriptLine({required this.text, this.onEdit, this.onRestart});
  @override
  Widget build(BuildContext context) {
    final colors = WalletColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3, right: 6),
          child: Icon(
            Icons.format_quote_rounded,
            size: 18,
            color: colors.secondary,
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.secondary, height: 1.45),
            ),
          ),
        ),
        if (onEdit != null)
          IconButton(
            tooltip: '修改文字',
            visualDensity: VisualDensity.compact,
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 20),
          ),
        if (onRestart != null)
          IconButton(
            tooltip: '重新说',
            visualDensity: VisualDensity.compact,
            onPressed: onRestart,
            icon: const Icon(Icons.restart_alt_rounded, size: 20),
          ),
      ],
    );
  }
}

enum _Mark { heard, assumed, missing }

/// A reviewable bill: the user checks a short receipt instead of a form.
/// Missing fields are red, AI guesses carry a "推测" tag, and every part opens
/// the same picker the rest of the app uses.
class VoiceReceiptCard extends StatelessWidget {
  final VoiceDraft draft;
  final bool enabled, working;
  final TextEditingController amount, title;
  final FocusNode amountFocus, titleFocus;
  final Set<String> changed;
  final int flash;
  final ValueChanged<VoiceDraft> onChanged;
  final ValueChanged<String> onPick;
  const VoiceReceiptCard({
    super.key,
    required this.draft,
    required this.amount,
    required this.title,
    required this.amountFocus,
    required this.titleFocus,
    required this.onChanged,
    required this.onPick,
    this.enabled = true,
    this.working = false,
    this.changed = const {},
    this.flash = 0,
  });

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    final colors = WalletColors.of(context);
    final fields = draft.fields;
    final type = TxType.values
        .where((t) => t.name == fields['type'])
        .firstOrNull;
    final problem = draft.problem(store.data);
    final missing = draft.missing(store.data).toSet();
    _Mark mark(String field) => missing.contains(field)
        ? _Mark.missing
        : draft.assumed.contains(field)
        ? _Mark.assumed
        : _Mark.heard;
    Widget flashing(String field, Widget child) => _Flash(
      active: changed.contains(field),
      generation: flash,
      child: child,
    );
    InputBorder underline(String field) => missing.contains(field)
        ? const UnderlineInputBorder(borderSide: BorderSide(color: coral))
        : InputBorder.none;
    Widget account(String field) {
      final name = store
          .account(fields[field] is String ? fields[field] as String : null)
          ?.name;
      final label = _accountLabel(field, fields['type']);
      return flashing(
        field,
        _FieldChip(
          label: label,
          text: name ?? '选择$label',
          icon: Icons.account_balance_wallet_outlined,
          mark: mark(field),
          onTap: enabled ? () => onPick(field) : null,
        ),
      );
    }

    final category = store.data.categories
        .where((c) => c.type == type && c.name == fields['category'])
        .firstOrNull;
    final date = DateTime.tryParse('${fields['date']}');
    final amountColor = switch (type) {
      TxType.income => colors.income,
      TxType.expense => colors.expense,
      _ => colors.ink,
    };
    return AnimatedOpacity(
      opacity: working ? .55 : 1,
      duration: motionDuration(context),
      child: Panel(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Appear(
              index: 0,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      problem == null ? '待确认账单' : '补全后即可确认',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '尚未入账',
                    style: TextStyle(color: colors.secondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (draft.message != null && problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  draft.message!,
                  style: TextStyle(color: colors.secondary, fontSize: 12),
                ),
              ),
            const SizedBox(height: 10),
            _Appear(
              index: 1,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final t in TxType.values)
                    ChoiceChip(
                      label: Text(t.label),
                      selected: t == type,
                      side: missing.contains('type')
                          ? const BorderSide(color: coral)
                          : null,
                      onSelected: enabled
                          ? (_) => onChanged(_withType(draft, t, store.data))
                          : null,
                    ),
                ],
              ),
            ),
            _Appear(
              index: 2,
              child: flashing(
                'amountCents',
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      '¥',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: amountColor,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        key: const Key('voice-draft-amount'),
                        controller: amount,
                        focusNode: amountFocus,
                        enabled: enabled,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -.5,
                          color: amountColor,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                        decoration: InputDecoration(
                          filled: false,
                          isDense: true,
                          hintText: '填写金额',
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 6,
                          ),
                          border: underline('amountCents'),
                          enabledBorder: underline('amountCents'),
                          disabledBorder: underline('amountCents'),
                          focusedBorder: const UnderlineInputBorder(
                            borderSide: BorderSide(color: primary),
                          ),
                        ),
                        onChanged: (value) {
                          int? cents;
                          try {
                            cents = parseMoney(value);
                          } on FormatException {
                            cents = null;
                          }
                          onChanged(draft.update({'amountCents': cents}));
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _Appear(
              index: 3,
              child: flashing(
                'title',
                TextField(
                  key: const Key('voice-draft-title'),
                  controller: title,
                  focusNode: titleFocus,
                  enabled: enabled,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    filled: false,
                    isDense: true,
                    hintText: '填写用途 / 商品',
                    contentPadding: const EdgeInsets.symmetric(vertical: 6),
                    border: underline('title'),
                    enabledBorder: underline('title'),
                    disabledBorder: underline('title'),
                    focusedBorder: const UnderlineInputBorder(
                      borderSide: BorderSide(color: primary),
                    ),
                  ),
                  onChanged: (value) =>
                      onChanged(draft.update({'title': value})),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _Appear(
              index: 4,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (type == TxType.transfer) ...[
                    account('transferFromId'),
                    account('transferToId'),
                  ] else ...[
                    account('accountId'),
                    flashing(
                      'category',
                      _FieldChip(
                        label: '分类',
                        text: category?.name ?? '选择分类',
                        icon: category == null
                            ? Icons.category_outlined
                            : iconOf(category.icon),
                        mark: mark('category'),
                        onTap: enabled && type != null
                            ? () => onPick('category')
                            : null,
                      ),
                    ),
                  ],
                  flashing(
                    'date',
                    _FieldChip(
                      label: '日期',
                      text: date == null
                          ? '选择日期'
                          : '${dateHeading(date)} ${DateFormat('HH:mm').format(date)}',
                      icon: Icons.calendar_today_outlined,
                      mark: date == null
                          ? _Mark.missing
                          : draft.assumed.contains('date')
                          ? _Mark.assumed
                          : _Mark.heard,
                      onTap: enabled ? () => onPick('date') : null,
                    ),
                  ),
                ],
              ),
            ),
            if (problem != null && missing.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  problem,
                  style: const TextStyle(color: coral, fontSize: 12),
                ),
              ),
            if (draft.assumed.isNotEmpty && problem == null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  '标“推测”的是 AI 根据习惯猜的，请留意',
                  style: TextStyle(color: colors.secondary, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FieldChip extends StatelessWidget {
  final String label, text;
  final IconData icon;
  final _Mark mark;
  final VoidCallback? onTap;
  const _FieldChip({
    required this.label,
    required this.text,
    required this.icon,
    required this.mark,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final colors = WalletColors.of(context);
    final missing = mark == _Mark.missing;
    final shape = StadiumBorder(
      side: missing ? const BorderSide(color: coral) : BorderSide.none,
    );
    return Semantics(
      button: true,
      label: '$label：$text${mark == _Mark.assumed ? '（推测）' : ''}',
      excludeSemantics: true,
      child: Material(
        color: missing
            ? coral.withValues(alpha: .08)
            : colors.ink.withValues(alpha: colors.dark ? .08 : .05),
        shape: shape,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: missing ? coral : colors.secondary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: missing ? coral : colors.ink,
                    ),
                  ),
                ),
                if (mark == _Mark.assumed) ...[
                  const SizedBox(width: 6),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5B85B).withValues(alpha: .22),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      child: Text(
                        '推测',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: colors.dark
                              ? const Color(0xFFF5C46B)
                              : const Color(0xFF8A5A00),
                        ),
                      ),
                    ),
                  ),
                ],
                Icon(
                  Icons.expand_more_rounded,
                  size: 18,
                  color: colors.secondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Fades a part in once when the receipt first appears.
class _Appear extends StatelessWidget {
  final int index;
  final Widget child;
  const _Appear({required this.index, required this.child});
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: motionDuration(context, 240 + index * 50),
    curve: Curves.easeOutCubic,
    child: child,
    builder: (_, value, child) => Opacity(
      opacity: value,
      child: Transform.translate(
        offset: Offset(0, 10 * (1 - value)),
        child: child,
      ),
    ),
  );
}

/// Highlights a field briefly after a spoken correction changed it, without
/// rebuilding the field itself.
class _Flash extends StatefulWidget {
  final bool active;
  final int generation;
  final Widget child;
  const _Flash({
    required this.active,
    required this.generation,
    required this.child,
  });
  @override
  State<_Flash> createState() => _FlashState();
}

class _FlashState extends State<_Flash> with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    value: 1,
  );

  @override
  void didUpdateWidget(covariant _Flash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active &&
        widget.generation != oldWidget.generation &&
        !MediaQuery.disableAnimationsOf(context)) {
      controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    child: widget.child,
    builder: (_, child) => DecoratedBox(
      decoration: BoxDecoration(
        color: primary.withValues(
          alpha: .18 * (1 - Curves.easeOut.transform(controller.value)),
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    ),
  );
}

class _ReceiptSkeleton extends StatefulWidget {
  const _ReceiptSkeleton();
  @override
  State<_ReceiptSkeleton> createState() => _ReceiptSkeletonState();
}

class _ReceiptSkeletonState extends State<_ReceiptSkeleton>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    value: 1,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The pulse only runs while the AI is working and stops with this widget.
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.value = 1;
    } else if (!controller.isAnimating) {
      controller.repeat(reverse: true, min: .45, max: 1);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fill = WalletColors.of(context).ink.withValues(alpha: .07);
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );
    return Semantics(
      label: 'AI 正在整理账单',
      child: FadeTransition(
        opacity: controller,
        child: Panel(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bar(96, 16),
              const SizedBox(height: 16),
              bar(150, 30),
              const SizedBox(height: 12),
              bar(190, 16),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: [bar(92, 32), bar(72, 32), bar(84, 32)],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SavedReceipt extends StatelessWidget {
  final List<LedgerTx> transactions;
  final VoidCallback? onUndo;
  const _SavedReceipt({required this.transactions, required this.onUndo});
  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: .4, end: 1),
                duration: motionDuration(context, 420),
                curve: Curves.easeOutBack,
                builder: (_, value, child) =>
                    Transform.scale(scale: value, child: child),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: mint.withValues(alpha: .14),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_rounded, color: mint),
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                '已记账',
                style: TextStyle(color: mint, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          for (final tx in transactions) ...[
            const SizedBox(height: 12),
            Text(
              '${tx.title} · ${tx.type.label} ${privateMoney(context, tx.amount)}',
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(height: 6),
            Text(
              tx.type == TxType.transfer
                  ? '${store.account(tx.fromId)?.name} → ${store.account(tx.toId)?.name}'
                  : store.account(tx.accountId)?.name ?? '',
            ),
          ],
          TextButton(
            onPressed: onUndo,
            child: Text(
              transactions.length == 1
                  ? '撤销这笔账单'
                  : '撤销这 ${transactions.length} 笔账单',
            ),
          ),
        ],
      ),
    );
  }
}
