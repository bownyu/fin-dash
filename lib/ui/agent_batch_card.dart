import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../domain/agent_action_summary.dart';
import '../domain/agent_batch_summary.dart';
import '../services/agent_actions.dart';
import 'agent_action_card.dart';
import 'design.dart';
import 'editors.dart';

class AgentBatchSelection {
  final String token;
  final Set<String> ids;
  final bool allowPartial;
  const AgentBatchSelection(this.token, this.ids, this.allowPartial);
}

String _accountName(
  List<Json> items,
  String id,
  String Function(String) fallback,
) =>
    items
        .where((a) => a['kind'] == 'account' && a['targetId'] == id)
        .firstOrNull?['desired']['name'] ??
    fallback(id);

class AgentBatchCard extends StatefulWidget {
  final String batchId;
  const AgentBatchCard({super.key, required this.batchId});
  @override
  State<AgentBatchCard> createState() => _AgentBatchCardState();
}

class _AgentBatchCardState extends State<AgentBatchCard> {
  bool busy = false;
  String? error;
  AgentBatchSelection? choice;

  Future<void> run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        setState(() => error = e is FormatException ? e.message : '操作未保存，请重试。');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ai = AppScope.of(context).ai, store = AppScope.storeOf(context);
    final review = ai.actions.review(widget.batchId), b = review.batch;
    final pending = review.pending;
    final appliedCount = review.items
        .where((a) => a['status'] == 'applied')
        .length;
    final rejectedCount = review.items
        .where((a) => a['status'] == 'rejected')
        .length;
    final undoneCount = review.items
        .where((a) => a['status'] == 'undone')
        .length;
    final selected = choice?.token == review.token
        ? choice!.ids
        : review.suggested;
    final partial = choice?.token == review.token && choice!.allowPartial;
    final groups = agentBatchGroups(pending);
    final preparing = b['generation'] == 'preparing';
    final interrupted = b['generation'] == 'interrupted';
    final receipts = (b['receipts'] as List? ?? [])
        .where((r) => r['status'] == 'applied')
        .toList();
    final uncertain = pending.where((a) => a['needsReview'] == true).length;
    final chosen = pending.where((a) => selected.contains(a['id'])).toList();
    String account(String id) =>
        _accountName(review.items, id, (id) => store.account(id)?.name ?? id);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(
          color: pending.isEmpty
              ? muted.withValues(alpha: .2)
              : primary.withValues(alpha: .3),
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            preparing
                ? '正在准备 · 已生成 ${pending.length} 项'
                : interrupted && pending.isNotEmpty
                ? '准备已中断 · 已保留 ${pending.length} 项'
                : pending.isNotEmpty
                ? '待确认方案 · ${pending.length} 项'
                : appliedCount > 0
                ? '已执行 $appliedCount 项'
                : undoneCount > 0
                ? '已撤销 $undoneCount 项'
                : '方案已取消',
            style: const TextStyle(color: primary, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text(
            '${b['title']}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Text(
            agentBatchScope(review.items),
            style: const TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          if (pending.isNotEmpty && (appliedCount > 0 || rejectedCount > 0))
            Text(
              '已执行 $appliedCount 项 · 已排除 $rejectedCount 项',
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          for (final g in groups.entries.take(4))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('${g.key} · ${g.value} 项'),
            ),
          if (groups.length > 4) Text('另有 ${groups.length - 4} 组变更，明细中查看'),
          if (uncertain > 0)
            Text('$uncertain 项待核对，默认未选中', style: const TextStyle(color: coral)),
          if (review.problems.isNotEmpty)
            Text(
              '${review.problems.length} 项存在冲突，已从默认选择中排除',
              style: const TextStyle(color: coral),
            ),
          if (pending.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final line in agentBatchImpact(chosen, account).take(4))
              Text(line),
            if (agentBatchImpact(chosen, account).length > 4)
              const Text('其他账户影响可在明细中查看'),
            Text(
              '已选 ${selected.length} 项 · 尚未写入账本',
              style: const TextStyle(color: muted, fontSize: 12),
            ),
          ],
          if (interrupted && pending.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('当前内容可能不完整。可以继续准备，或在明细中选择仅执行已准备部分。'),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(error!, style: const TextStyle(color: coral)),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (pending.isNotEmpty)
                FilledButton(
                  key: ValueKey('batch-confirm:${b['id']}'),
                  onPressed:
                      busy ||
                          preparing ||
                          selected.isEmpty ||
                          (interrupted && !partial)
                      ? null
                      : () => run(() async {
                          await ai.actions.applyBatch(
                            widget.batchId,
                            review.token,
                            selected,
                            allowPartial: partial,
                          );
                        }),
                  child: Text(busy ? '保存中…' : '确认选中 ${selected.length} 项'),
                ),
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        final result = await openPage<AgentBatchSelection>(
                          context,
                          AgentBatchReviewPage(
                            batchId: widget.batchId,
                            initial: AgentBatchSelection(
                              review.token,
                              selected,
                              partial,
                            ),
                          ),
                        );
                        if (mounted && result != null) {
                          setState(() {
                            choice = result;
                            error = null;
                          });
                        }
                      },
                child: Text(pending.isNotEmpty ? '查看／调整明细' : '查看执行明细'),
              ),
              if (interrupted &&
                  pending.isNotEmpty &&
                  b['sourceMessageId'] != null &&
                  receipts.isEmpty &&
                  b['closed'] != true)
                TextButton(
                  onPressed: busy || ai.busy
                      ? null
                      : () => run(() => ai.retryMessage(b['sourceMessageId'])),
                  child: const Text('继续准备'),
                ),
              if (pending.isNotEmpty)
                TextButton(
                  onPressed: busy || preparing
                      ? null
                      : () => run(
                          () => ai.actions.rejectBatch(
                            widget.batchId,
                            review.token,
                          ),
                        ),
                  child: const Text('取消方案'),
                ),
              for (final receipt in receipts)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => run(
                          () => ai.actions.undoBatch(
                            widget.batchId,
                            receipt['id'],
                          ),
                        ),
                  child: Text(
                    '撤销本批次 ${(receipt['actionIds'] as List).length} 项',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class AgentBatchReviewPage extends StatefulWidget {
  final String batchId;
  final AgentBatchSelection? initial;
  const AgentBatchReviewPage({super.key, required this.batchId, this.initial});
  @override
  State<AgentBatchReviewPage> createState() => _AgentBatchReviewPageState();
}

class _AgentBatchReviewPageState extends State<AgentBatchReviewPage> {
  AgentBatchReview? snapshot;
  Set<String> selected = {};
  bool busy = false, partial = false;
  String filter = 'all';
  String? error;
  final scroll = ScrollController();

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (snapshot != null) return;
    snapshot = AppScope.of(context).ai.actions.review(widget.batchId);
    selected = widget.initial?.token == snapshot!.token
        ? {...widget.initial!.ids}
        : snapshot!.suggested;
    partial =
        widget.initial?.token == snapshot!.token &&
        widget.initial!.allowPartial;
  }

  void refresh({String? reviewedId}) {
    final latest = AppScope.of(context).ai.actions.review(widget.batchId);
    setState(() {
      final ids = latest.pending.map((a) => a['id']).toSet();
      selected = selected.intersection(ids.cast<String>())
        ..removeWhere(latest.problems.containsKey);
      if (reviewedId != null && !latest.problems.containsKey(reviewedId)) {
        selected.add(reviewedId);
      }
      snapshot = latest;
      error = null;
    });
  }

  void choose(Json a, bool value) {
    final required = snapshot!.dependencies;
    setState(() {
      if (value) {
        final dependencies = required[a['id']] ?? <String>{};
        final unchecked = snapshot!.pending
            .where(
              (x) =>
                  dependencies.contains(x['id']) &&
                  !selected.contains(x['id']) &&
                  (x['needsReview'] == true ||
                      snapshot!.problems.containsKey(x['id'])),
            )
            .toList();
        if (unchecked.isNotEmpty) {
          error = '请先核对并选择这笔账单依赖的新增账户';
          return;
        }
        selected.addAll(dependencies);
        selected.add(a['id']);
        error = null;
      } else {
        selected.remove(a['id']);
        selected.removeWhere((id) => (required[id] ?? {}).contains(a['id']));
      }
    });
  }

  Future<void> run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        setState(() => error = e is FormatException ? e.message : '操作未保存，请重试。');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void details(Json a) {
    final store = AppScope.storeOf(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .75,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text('变更详情', style: Theme.of(context).textTheme.titleMedium),
            for (final line in agentActionPreview(
              a,
              (id) => _accountName(
                snapshot!.items,
                id,
                (id) => store.account(id)?.name ?? id,
              ),
            ))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(line),
              ),
            if ('${a['summary'] ?? ''}'.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('${a['summary']}'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> edit(Json a) async {
    try {
      await editItem(a);
    } catch (e) {
      if (mounted) {
        setState(() => error = e is FormatException ? e.message : '操作未保存，请重试。');
      }
    }
  }

  Future<void> editItem(Json a) async {
    final ai = AppScope.of(context).ai, store = AppScope.storeOf(context);
    final token = snapshot!.token;
    final current = snapshot!.problems.containsKey(a['id']);
    if (current) {
      final preview = ai.actions.refreshedProposal(a['id']);
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('基于最新账本重新核对'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('以下差异按最新账本计算。更新方案后仍需统一确认。'),
                for (final line in agentActionPreview(
                  preview,
                  (id) => store.account(id)?.name ?? id,
                ))
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(line),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('更新此项方案'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      await run(() async {
        await ai.actions.editProposal(
          widget.batchId,
          a['id'],
          token,
          {},
          rebase: true,
          expectedBefore: Json.from(preview['before']),
        );
        if (mounted) refresh(reviewedId: a['id']);
      });
      return;
    }
    final desired = Json.from(a['desired']);
    if (a['kind'] == 'transaction') {
      final accounts = {for (final x in store.activeAccounts) x.id: x};
      for (final x in snapshot!.pending.where((x) => x['kind'] == 'account')) {
        final account = WalletAccount.fromJson(Json.from(x['desired']));
        if (!account.archived) accounts[account.id] = account;
      }
      final result = await openPage<bool>(
        context,
        TransactionEditor(
          initial: LedgerTx.fromJson(desired),
          availableAccounts: accounts.values.toList(),
          pageTitle: '调整方案中的账单',
          reviewNote: '仅更新待确认方案，统一确认后才会记账。',
          successMessage: '方案已更新，确认后才会写入账本',
          saveLabel: '更新方案',
          onSave: (tx) => ai.actions.editProposal(
            widget.batchId,
            a['id'],
            token,
            tx.toJson()..remove('id'),
          ),
        ),
      );
      if (mounted && result == true) refresh(reviewedId: a['id']);
    } else if (a['kind'] == 'account') {
      final next = WalletAccount.fromJson(desired);
      final originalBalance = store.balance(next);
      final result = await openPage<bool>(
        context,
        AccountEditor(
          initial: next,
          pageTitle: '调整方案中的账户',
          onSave: (account, balance) =>
              ai.actions.editProposal(widget.batchId, a['id'], token, {
                ...account.toJson()..remove('id'),
                if (a['input'].containsKey('currentBalanceCents') ||
                    balance != originalBalance)
                  'currentBalanceCents': balance,
              }),
        ),
      );
      if (mounted && result == true) refresh(reviewedId: a['id']);
    } else {
      final amount = await showDialog<int>(
        context: context,
        builder: (context) =>
            _BudgetDraftDialog(amount: desired['amountCents']),
      );
      // The closing route may still paint the field during its exit animation.
      if (amount != null && mounted) {
        await run(() async {
          await ai.actions.editProposal(widget.batchId, a['id'], token, {
            'amountCents': amount,
          });
          if (mounted) refresh(reviewedId: a['id']);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ai = AppScope.of(context).ai, store = AppScope.storeOf(context);
    final current = ai.actions.review(widget.batchId);
    final review = snapshot!, changed = review.token != current.token;
    final preparing = current.batch['generation'] == 'preparing';
    final interrupted = current.batch['generation'] == 'interrupted';
    final rows = review.items
        .where(
          (a) =>
              filter == 'all' ||
              filter == 'review' &&
                  a['status'] == 'pending' &&
                  a['needsReview'] == true ||
              filter == 'conflict' && current.problems.containsKey(a['id']),
        )
        .toList();
    final chosen = review.pending
        .where((a) => selected.contains(a['id']))
        .toList();
    String account(String id) =>
        _accountName(review.items, id, (id) => store.account(id)?.name ?? id);
    return PopScope<AgentBatchSelection>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !busy && context.mounted) {
          Navigator.pop(
            context,
            AgentBatchSelection(review.token, {...selected}, partial),
          );
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(
            onPressed: () {
              if (!busy) {
                Navigator.pop(
                  context,
                  AgentBatchSelection(review.token, {...selected}, partial),
                );
              }
            },
          ),
          title: const Text('审阅变更方案'),
          actions: [
            TextButton(
              onPressed: busy
                  ? null
                  : () => Navigator.pop(
                      context,
                      AgentBatchSelection(review.token, {...selected}, partial),
                    ),
              child: const Text('保留选择'),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${review.batch['title']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${review.pending.length} 项待确认 · 已选 ${selected.length} 项',
                    style: const TextStyle(color: muted),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final entry in {
                        'all': '全部',
                        'review': '待核对',
                        'conflict': '有冲突',
                      }.entries)
                        ChoiceChip(
                          label: Text(entry.value),
                          selected: filter == entry.key,
                          onSelected: (_) => setState(() => filter = entry.key),
                        ),
                      TextButton(
                        onPressed: busy || changed
                            ? null
                            : () => setState(() => selected = review.suggested),
                        child: const Text('选择明确项'),
                      ),
                      TextButton(
                        onPressed: busy ? null : () => setState(selected.clear),
                        child: const Text('清空选择'),
                      ),
                    ],
                  ),
                  if (changed)
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '方案或账本已更新，请刷新后重新核对。',
                            style: TextStyle(color: coral),
                          ),
                        ),
                        TextButton(
                          onPressed: busy ? null : () => refresh(),
                          child: const Text('刷新方案'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        filter == 'review'
                            ? '没有待核对项'
                            : filter == 'conflict'
                            ? '没有冲突项'
                            : '暂无项目',
                      ),
                    )
                  : ListView.builder(
                      controller: scroll,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final a = rows[index],
                            pending = a['status'] == 'pending';
                        final problem = current.problems[a['id']];
                        return Padding(
                          key: ValueKey('batch-row:${a['id']}'),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                value: selected.contains(a['id']),
                                onChanged:
                                    !pending ||
                                        busy ||
                                        changed ||
                                        problem != null
                                    ? null
                                    : (value) => choose(a, value == true),
                                title: Text(agentActionSummary(a, account)),
                                subtitle: Text(
                                  problem ??
                                      (a['needsReview'] == true
                                          ? '待核对：${a['reviewNote'] == '' || a['reviewNote'] == null ? '请确认此项是否正确' : a['reviewNote']}'
                                          : pending
                                          ? '待确认'
                                          : {
                                                  'applied': '已执行',
                                                  'rejected': '已排除',
                                                  'undone': '已撤销',
                                                }[a['status']] ??
                                                '已处理'),
                                  style: TextStyle(
                                    color:
                                        problem != null ||
                                            a['needsReview'] == true
                                        ? coral
                                        : muted,
                                  ),
                                ),
                              ),
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton(
                                    onPressed: () => details(a),
                                    child: const Text('完整差异'),
                                  ),
                                  if (pending)
                                    TextButton(
                                      onPressed: busy || changed || preparing
                                          ? null
                                          : () => edit(a),
                                      child: Text(
                                        problem == null ? '调整此项' : '重新核对此项',
                                      ),
                                    ),
                                  if (pending)
                                    TextButton(
                                      onPressed: busy || changed || preparing
                                          ? null
                                          : () => run(() async {
                                              await ai.actions.rejectBatch(
                                                widget.batchId,
                                                review.token,
                                                selected: {a['id']},
                                              );
                                              if (mounted) refresh();
                                            }),
                                      child: const Text('排除此项'),
                                    ),
                                ],
                              ),
                              const Divider(height: 1),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Container(
            color: Theme.of(context).colorScheme.surface,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (error != null)
                  Text(
                    error!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: coral),
                  ),
                if (interrupted)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: partial,
                    onChanged: busy || changed
                        ? null
                        : (value) => setState(() => partial = value == true),
                    title: const Text('只执行已准备部分，剩余任务尚未完成'),
                  ),
                for (final line in agentBatchImpact(chosen, account).take(3))
                  Text(line, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (agentBatchImpact(chosen, account).length > 3)
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('选中项目的完整影响'),
                        content: SingleChildScrollView(
                          child: Text(
                            agentBatchImpact(chosen, account).join('\n'),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('返回'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('查看全部账户影响'),
                  ),
                FilledButton(
                  key: const Key('batch-review-confirm'),
                  onPressed:
                      busy ||
                          preparing ||
                          changed ||
                          selected.isEmpty ||
                          selected.any(current.problems.containsKey) ||
                          interrupted && !partial
                      ? null
                      : () => run(() async {
                          await ai.actions.applyBatch(
                            widget.batchId,
                            review.token,
                            selected,
                            allowPartial: partial,
                          );
                          if (context.mounted) Navigator.pop(context);
                        }),
                  child: Text(busy ? '保存中…' : '确认选中 ${selected.length} 项'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BudgetDraftDialog extends StatefulWidget {
  final int amount;
  const _BudgetDraftDialog({required this.amount});
  @override
  State<_BudgetDraftDialog> createState() => _BudgetDraftDialogState();
}

class _BudgetDraftDialogState extends State<_BudgetDraftDialog> {
  late final controller = TextEditingController(
    text: moneyInput(widget.amount),
  );
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('调整月预算方案'),
    content: TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: '月预算', errorText: error),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('返回'),
      ),
      FilledButton(
        onPressed: () {
          try {
            Navigator.pop(context, parseMoney(controller.text));
          } on FormatException catch (e) {
            setState(() => error = e.message);
          }
        },
        child: const Text('更新方案'),
      ),
    ],
  );
}
