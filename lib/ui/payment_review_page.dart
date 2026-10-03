import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../domain/models.dart';
import '../services/payment_notifications.dart';
import 'design.dart';
import 'interaction.dart';
import 'editors.dart';

LedgerTx paymentNotificationDraft(
  Json record,
  WalletData data, {
  String? accountId,
}) {
  final type = switch (record['kind']) {
    'income' || 'refund' => TxType.income,
    'transfer' || 'repayment' => TxType.transfer,
    _ => TxType.expense,
  };
  final categories = data.categories.where((c) => c.type == type);
  final category = type == TxType.transfer
      ? '转账'
      : categories
                .where((c) => ['其他', '其它'].contains(c.name))
                .firstOrNull
                ?.name ??
            categories.firstOrNull?.name ??
            '其他';
  return LedgerTx(
    id: 'payment-${record['eventId']}',
    title: (record['merchant'] as String? ?? '').trim().isEmpty
        ? '支付通知'
        : record['merchant'],
    amount: record['amountCents'] ?? 0,
    date: DateTime.fromMillisecondsSinceEpoch(record['postedAt']),
    type: type,
    category: category,
    accountId: accountId,
    note:
        '来源：${record['sourcePackage'] == 'com.tencent.mm' ? '微信' : '支付宝'}支付通知\n${record['title']}\n${record['text']}',
  );
}

Future<void> reviewPaymentNotification(
  BuildContext context,
  PaymentNotifications service,
  Json record,
) async {
  final store = AppScope.storeOf(context);
  LedgerTx? original;
  final refund = record['kind'] == 'refund';
  if (refund) {
    final candidates = store
        .query(type: TxType.expense)
        .where((t) => t.amount >= (record['amountCents'] as int? ?? 0))
        .toList();
    if (candidates.isEmpty) {
      toast(context, '请先记录或导入退款对应的原消费，再核对退款到账。原通知仍保留。');
      return;
    }
    original = await pickWalletOption<LedgerTx>(
      context,
      title: '选择退款对应的原消费',
      items: [
        for (final tx in candidates)
          DropdownMenuItem(value: tx, child: Text(tx.title)),
      ],
      label: (tx) => tx.title,
      subtitle: (tx) =>
          '${dayKey(tx.date)} · ${privateMoney(context, tx.amount)} · ${store.account(tx.accountId)?.name ?? '未关联账户'}',
      icon: (_) => Icons.receipt_long_outlined,
    );
    if (original == null || !context.mounted) return;
  }
  final linked = original;
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      settings: const RouteSettings(name: '/payment-notification-review'),
      builder: (_) => TransactionEditor(
        initial: refund
            ? LedgerTx.fromJson({
                ...paymentNotificationDraft(
                  record,
                  store.data,
                  accountId: linked?.accountId,
                ).toJson(),
                'category': '退款',
              })
            : paymentNotificationDraft(record, store.data),
        saveLabel: refund ? '确认退款到账' : null,
        pageTitle: refund ? '核对退款到账' : '核对通知账单',
        reviewNote:
            '${refund ? '原消费：${linked!.title} · ${privateMoney(context, linked.amount)}\n退款将关联原消费并单独记为退款收入；原消费保留。请确认实际到账账户和金额。\n' : ''}${record['reviewReason']}\n通知时间可能与交易时间不同，请核对金额、时间和实际账户。\n\n${record['title']}\n${record['text']}',
        onSave: (updated) async {
          if (refund &&
              !await confirm(
                context,
                '确认实际退款已到账？',
                '${linked!.title}\n退款 ${privateMoney(context, updated.amount)} → ${store.account(updated.accountId)?.name ?? '待选账户'}\n原消费保留，退款单独计入退款分类。',
                action: '确认到账',
              )) {
            throw const FormatException('退款尚未确认，核对内容已保留');
          }
          final needsReview = service.needsDuplicateReview(
            record,
            transaction: updated,
          );
          var duplicateReviewed = refund;
          if (needsReview && !refund) {
            if (!context.mounted) throw const FormatException('核对页面已关闭');
            duplicateReviewed = await confirm(
              context,
              '可能存在重复账单',
              '金额与时间接近已有记录或另一条通知。请确认这是一笔独立交易。',
              action: '确认是独立交易',
            );
            if (!duplicateReviewed) {
              throw const FormatException('尚未入账，请先核对重复记录');
            }
          }
          await service.accept(
            record['eventId'],
            updated,
            duplicateReviewed: duplicateReviewed,
            refundOf: linked?.id,
          );
        },
      ),
    ),
  );
}

class PaymentReviewPage extends StatefulWidget {
  final PaymentNotifications? notifications;
  final bool reminder;
  const PaymentReviewPage({
    super.key,
    this.notifications,
    this.reminder = false,
  });
  @override
  State<PaymentReviewPage> createState() => _PaymentReviewPageState();
}

class _PaymentReviewPageState extends State<PaymentReviewPage> {
  PaymentNotifications? service;
  final selected = <String>{};
  final expanded = <String>{};
  String? accountId, error;
  bool busy = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (service != null) return;
    service =
        widget.notifications ?? PaymentNotifications(AppScope.storeOf(context));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) refresh();
    });
  }

  Future<void> refresh() async {
    if (busy || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await service!.sync();
      final eligibleIds = service!.pending
          .where((r) => service!.batchProblem(r) == null)
          .map((r) => r['eventId'])
          .toSet();
      selected.removeWhere((id) => !eligibleIds.contains(id));
    } catch (_) {
      if (mounted) setState(() => error = '同步未完成，已保存的记录仍可核对');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> acceptSelected({Json? only}) async {
    if (busy || accountId == null) return;
    final store = AppScope.storeOf(context);
    final records = service!.pending
        .where(
          (r) =>
              (only != null
                  ? r['eventId'] == only['eventId']
                  : selected.contains(r['eventId'])) &&
              service!.batchProblem(r) == null,
        )
        .toList();
    if (records.isEmpty) return;
    if (only == null && records.length > 1) {
      final accountName = store.account(accountId)?.name ?? '所选账户';
      final expense = records
          .where((r) => r['kind'] == 'expense')
          .fold<int>(0, (sum, r) => sum + (r['amountCents'] as int));
      final income = records
          .where((r) => r['kind'] == 'income')
          .fold<int>(0, (sum, r) => sum + (r['amountCents'] as int));
      if (!await confirm(
        context,
        '将 ${records.length} 笔全部记入 $accountName？',
        '支出 ${privateMoney(context, expense)} · 收入 ${privateMoney(context, income)}\n请确认每笔都属于这个账户；其他账户的记录请分开处理。',
        action: '确认入账',
      )) {
        return;
      }
      if (!mounted || busy) return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final count = await service!.acceptMany([
        for (final record in records)
          PaymentAcceptance(
            record['eventId'],
            paymentNotificationDraft(record, store.data, accountId: accountId),
          ),
      ]);
      if (mounted) {
        toast(context, '已确认 $count 笔支付记录');
        selected.removeAll(records.map((r) => r['eventId']));
        if (service!.pending.isEmpty) Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException ? e.message : '确认未保存，记录已保留，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> dismissRecord(Json record) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await service!.dismiss(record['eventId']);
      selected.remove(record['eventId']);
    } catch (_) {
      if (mounted) setState(() => error = '忽略未保存，请重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    if (store.data.settings['locked'] == true) {
      return Scaffold(
        appBar: AppBar(title: const Text('支付记录核对')),
        body: const Center(child: Text('请先解锁账本')),
      );
    }
    final records = service?.pending ?? <Json>[];
    final eligible = records
        .where((r) => service!.batchProblem(r) == null)
        .toList();
    final chosen = eligible
        .where((r) => selected.contains(r['eventId']))
        .toList();
    final allSelected = eligible.isNotEmpty && chosen.length == eligible.length;
    final validAccount = store.activeAccounts.any((a) => a.id == accountId);
    final colors = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = Duration(milliseconds: reduceMotion ? 0 : 220);
    final expense = chosen
        .where((r) => r['kind'] == 'expense')
        .fold<int>(0, (sum, r) => sum + (r['amountCents'] as int));
    final income = chosen
        .where((r) => r['kind'] == 'income')
        .fold<int>(0, (sum, r) => sum + (r['amountCents'] as int));
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        key: widget.reminder ? const Key('payment-entry-review') : null,
        backgroundColor: Theme.of(context).canvasColor,
        appBar: AppBar(
          title: const Text('确认消费'),
          leading: IconButton(
            tooltip: '稍后处理',
            onPressed: busy ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
          ),
          actions: [
            IconButton(
              tooltip: '刷新记录',
              onPressed: busy ? null : refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      records.isEmpty ? '都处理好了' : '${records.length} 笔支付，等你确认',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '在这里直接入账，详情按需展开',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '已选 ${chosen.length} 笔 · 可快捷确认 ${eligible.length} 笔',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        TextButton.icon(
                          key: const Key('payment-select-all'),
                          onPressed: busy || eligible.isEmpty
                              ? null
                              : () => setState(() {
                                  if (allSelected) {
                                    selected.clear();
                                  } else {
                                    selected.addAll(
                                      eligible.map(
                                        (r) => r['eventId'] as String,
                                      ),
                                    );
                                  }
                                }),
                          icon: Icon(
                            allSelected
                                ? Icons.deselect_rounded
                                : Icons.done_all_rounded,
                            size: 18,
                          ),
                          label: Text(allSelected ? '取消全选' : '全选'),
                        ),
                      ],
                    ),
                    if (busy) const LinearProgressIndicator(),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          error!,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    if (records.isEmpty)
                      const EmptyState(
                        '全部处理完成',
                        '已确认的记录可在账单页查看。',
                        icon: Icons.task_alt_rounded,
                      ),
                  ],
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final record = records[index];
                final id = record['eventId'] as String;
                final problem = service!.batchProblem(record);
                final checked = problem == null && selected.contains(id);
                final wechat = record['sourcePackage'] == 'com.tencent.mm';
                final sourceColor = wechat ? mint : primary;
                final kind = switch (record['kind']) {
                  'income' => '收入',
                  'refund' => '退款',
                  'transfer' => '转账',
                  'repayment' => '还款',
                  _ => '支出',
                };
                return Padding(
                  key: ValueKey(id),
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: AnimatedContainer(
                    duration: duration,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: checked
                          ? Color.alphaBlend(
                              colors.primary.withValues(alpha: .045),
                              colors.surface,
                            )
                          : colors.surface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: checked
                            ? colors.primary.withValues(alpha: .4)
                            : colors.outlineVariant,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: sourceColor.withValues(alpha: .12),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(
                                wechat
                                    ? Icons.chat_bubble_rounded
                                    : Icons.account_balance_wallet_rounded,
                                color: sourceColor,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '${wechat ? '微信' : '支付宝'} · $kind',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            Checkbox(
                              key: ValueKey('payment-select:$id'),
                              value: checked,
                              semanticLabel:
                                  '选择${wechat ? '微信' : '支付宝'}$kind记录',
                              onChanged: busy || problem != null
                                  ? null
                                  : (value) => setState(() {
                                      if (value == true) {
                                        selected.add(id);
                                      } else {
                                        selected.remove(id);
                                      }
                                    }),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          record['amountCents'] == null
                              ? '金额待核对'
                              : privateMoney(context, record['amountCents']),
                          style: Theme.of(context).textTheme.headlineLarge
                              ?.copyWith(
                                fontSize: 30,
                                color: record['kind'] == 'income' ? mint : null,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          DateFormat('yyyy年M月d日 HH:mm').format(
                            DateTime.fromMillisecondsSinceEpoch(
                              record['postedAt'],
                            ),
                          ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if ((record['merchant'] as String? ?? '').isNotEmpty)
                          Text(
                            record['merchant'],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        if (problem != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              problem,
                              style: TextStyle(
                                color: colors.error,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            FilledButton.icon(
                              key: ValueKey('payment-accept:$id'),
                              onPressed: busy
                                  ? null
                                  : problem != null
                                  ? () => reviewPaymentNotification(
                                      context,
                                      service!,
                                      record,
                                    )
                                  : () {
                                      if (!validAccount) {
                                        toast(context, '请先在底部选择实际记账账户');
                                        return;
                                      }
                                      acceptSelected(only: record);
                                    },
                              icon: Icon(
                                problem == null
                                    ? Icons.check_rounded
                                    : Icons.edit_outlined,
                                size: 18,
                              ),
                              label: Text(problem == null ? '确认入账' : '核对处理'),
                            ),
                            TextButton(
                              key: ValueKey('payment-details:$id'),
                              onPressed: () => setState(() {
                                if (!expanded.add(id)) expanded.remove(id);
                              }),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(expanded.contains(id) ? '收起' : '详情'),
                                  AnimatedRotation(
                                    turns: expanded.contains(id) ? .5 : 0,
                                    duration: duration,
                                    child: const Icon(
                                      Icons.expand_more_rounded,
                                      size: 18,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => dismissRecord(record),
                              child: const Text('忽略'),
                            ),
                          ],
                        ),
                        AnimatedSize(
                          duration: duration,
                          alignment: Alignment.topCenter,
                          child: expanded.contains(id)
                              ? SizedBox(
                                  width: double.infinity,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Divider(height: 24),
                                      Text(
                                        '通知原文',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.labelLarge,
                                      ),
                                      const SizedBox(height: 6),
                                      SelectableText(
                                        '${record['title']}\n${record['text']}',
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        '通知时间可能与交易时间不同；快捷入账分类：${paymentNotificationDraft(record, store.data).category}，可在此修改。',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                      TextButton.icon(
                                        key: ValueKey('payment-review:$id'),
                                        onPressed: busy
                                            ? null
                                            : () => reviewPaymentNotification(
                                                context,
                                                service!,
                                                record,
                                              ),
                                        icon: const Icon(
                                          Icons.edit_outlined,
                                          size: 18,
                                        ),
                                        label: const Text('修改分类、账户或时间'),
                                      ),
                                    ],
                                  ),
                                )
                              : const SizedBox(width: double.infinity),
                        ),
                      ],
                    ),
                  ),
                );
              }, childCount: records.length),
            ),
          ],
        ),
        bottomNavigationBar: records.isEmpty
            ? null
            : Material(
                color: colors.surface,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        WalletSelectField<String>(
                          key: ValueKey('payment-batch-account:$accountId'),
                          initialValue: validAccount ? accountId : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '记入账户',
                            hintText: '选择实际扣款或收款账户',
                            prefixIcon: Icon(
                              Icons.account_balance_wallet_outlined,
                            ),
                          ),
                          items: store.activeAccounts
                              .map(
                                (a) => DropdownMenuItem(
                                  value: a.id,
                                  child: Text(
                                    a.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: busy
                              ? null
                              : (id) => setState(() => accountId = id),
                        ),
                        if (store.activeAccounts.isEmpty)
                          TextButton.icon(
                            onPressed: busy
                                ? null
                                : () =>
                                      openPage(context, const AccountEditor()),
                            icon: const Icon(Icons.add),
                            label: const Text('先添加实际记账账户'),
                          ),
                        const SizedBox(height: 8),
                        Text(
                          chosen.isEmpty
                              ? '选择记录后可一起确认'
                              : '已选 ${chosen.length} 笔 · 支出 ${privateMoney(context, expense)}${income > 0 ? ' · 收入 ${privateMoney(context, income)}' : ''}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        FilledButton(
                          key: const Key('payment-confirm-batch'),
                          onPressed: busy || !validAccount || chosen.isEmpty
                              ? null
                              : () => acceptSelected(),
                          child: AnimatedSwitcher(
                            duration: duration,
                            child: Text(
                              !validAccount
                                  ? '先选择账户，再确认'
                                  : '确认 ${chosen.length} 笔 → ${store.account(accountId)?.name ?? '所选账户'}',
                              key: ValueKey('$validAccount:${chosen.length}'),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '仅将同一账户的记录一起确认',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
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
