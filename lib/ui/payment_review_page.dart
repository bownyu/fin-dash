import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../domain/models.dart';
import '../services/payment_notifications.dart';
import 'design.dart';
import 'editors.dart';

LedgerTx paymentNotificationDraft(
  Json record,
  WalletData data, {
  String? accountId,
}) {
  final type = switch (record['kind']) {
    'income' => TxType.income,
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
  if (record['kind'] == 'refund') {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('先核对退款对应的原账单'),
        content: SingleChildScrollView(
          child: Text(
            '${record['title']}\n${record['text']}\n\n'
            '请核对原交易与实际到账金额。退款通知暂不直接转成收入或新消费。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    return;
  }
  final store = AppScope.storeOf(context);
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      settings: const RouteSettings(name: '/payment-notification-review'),
      builder: (_) => TransactionEditor(
        initial: paymentNotificationDraft(record, store.data),
        pageTitle: '核对通知账单',
        reviewNote:
            '${record['reviewReason']}\n通知时间可能与交易时间不同，请核对金额、时间和实际账户。\n\n${record['title']}\n${record['text']}',
        onSave: (updated) async {
          final needsReview = service.needsDuplicateReview(
            record,
            transaction: updated,
          );
          var duplicateReviewed = false;
          if (needsReview) {
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
  String? accountId, error;
  bool busy = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (service != null) return;
    service =
        widget.notifications ?? PaymentNotifications(AppScope.storeOf(context));
    selected.addAll(
      service!.pending
          .where((r) => service!.batchProblem(r) == null)
          .map((r) => r['eventId'] as String),
    );
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
    } catch (_) {
      if (mounted) setState(() => error = '同步未完成，已保存的记录仍可核对');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> acceptSelected() async {
    if (busy || accountId == null) return;
    final store = AppScope.storeOf(context);
    final records = service!.pending
        .where(
          (r) =>
              selected.contains(r['eventId']) &&
              service!.batchProblem(r) == null,
        )
        .toList();
    if (records.isEmpty) return;
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
    final chosen = records
        .where(
          (r) =>
              selected.contains(r['eventId']) &&
              service!.batchProblem(r) == null,
        )
        .toList();
    final validAccount = store.activeAccounts.any((a) => a.id == accountId);
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        key: widget.reminder ? const Key('payment-entry-review') : null,
        appBar: AppBar(
          title: Text(
            '支付记录待确认（${records.length}）',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          leading: IconButton(
            tooltip: '稍后处理',
            onPressed: busy ? null : () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
          actions: [
            IconButton(
              tooltip: '刷新记录',
              onPressed: busy ? null : refresh,
              icon: const Icon(Icons.refresh),
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
                    const Text('后台发现这些支付记录。核对金额、时间和扣款账户后，再确认入账。'),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: ValueKey('payment-batch-account:$accountId'),
                      initialValue: validAccount ? accountId : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '选中记录使用的账户',
                        hintText: '请选择实际扣款或收款账户',
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
                    const SizedBox(height: 8),
                    if (store.activeAccounts.isEmpty)
                      TextButton.icon(
                        onPressed: busy
                            ? null
                            : () => openPage(context, const AccountEditor()),
                        icon: const Icon(Icons.add),
                        label: const Text('先添加实际记账账户'),
                      ),
                    const Text(
                      '同一账户可一起确认；使用不同账户的记录请逐笔核对。退款、疑似重复或信息不全的记录不参加批量确认。',
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator(),
                      ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error!,
                          style: const TextStyle(color: coral),
                        ),
                      ),
                    if (records.isEmpty)
                      const EmptyState('全部处理完成', '已确认的记录可在账单页查看。'),
                  ],
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final record = records[index];
                final problem = service!.batchProblem(record);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        CheckboxListTile(
                          key: ValueKey('payment-select:${record['eventId']}'),
                          contentPadding: EdgeInsets.zero,
                          value:
                              problem == null &&
                              selected.contains(record['eventId']),
                          onChanged: busy || problem != null
                              ? null
                              : (v) => setState(() {
                                  if (v == true) {
                                    selected.add(record['eventId']);
                                  } else {
                                    selected.remove(record['eventId']);
                                  }
                                }),
                          title: Text(
                            '${record['sourcePackage'] == 'com.tencent.mm' ? '微信' : '支付宝'} · '
                            '${record['kind'] == 'income'
                                ? '收入'
                                : record['kind'] == 'refund'
                                ? '退款'
                                : '支出'} '
                            '${record['amountCents'] == null ? '金额待核对' : money(record['amountCents'])}',
                          ),
                          subtitle: Text(
                            '${record['merchant'] ?? ''}\n${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(record['postedAt']))}',
                          ),
                        ),
                        if (problem != null)
                          Text(
                            problem,
                            style: const TextStyle(color: coral, fontSize: 12),
                          ),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text('查看通知原文'),
                          children: [
                            SelectableText(
                              '${record['title']}\n${record['text']}',
                            ),
                          ],
                        ),
                        Wrap(
                          spacing: 12,
                          children: [
                            TextButton(
                              key: ValueKey(
                                'payment-review:${record['eventId']}',
                              ),
                              onPressed: busy
                                  ? null
                                  : () => reviewPaymentNotification(
                                      context,
                                      service!,
                                      record,
                                    ),
                              child: Text(
                                record['kind'] == 'refund' ? '核对退款' : '逐笔核对',
                              ),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => perform(
                                      context,
                                      () => service!.dismiss(record['eventId']),
                                    ),
                              child: const Text('忽略'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }, childCount: records.length),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: FilledButton(
              key: const Key('payment-confirm-batch'),
              onPressed: busy || !validAccount || chosen.isEmpty
                  ? null
                  : acceptSelected,
              child: Text(
                !validAccount && chosen.isNotEmpty
                    ? '先选择账户，再确认'
                    : '一键确认选中 ${chosen.length} 笔',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
