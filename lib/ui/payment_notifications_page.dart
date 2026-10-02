import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../domain/models.dart';
import '../services/payment_notifications.dart';
import 'design.dart';
import 'payment_review_page.dart';

class PaymentNotificationsPage extends StatefulWidget {
  const PaymentNotificationsPage({super.key});
  @override
  State<PaymentNotificationsPage> createState() =>
      _PaymentNotificationsPageState();
}

class _PaymentNotificationsPageState extends State<PaymentNotificationsPage>
    with WidgetsBindingObserver {
  PaymentNotifications? service;
  Json status = {};
  String? error;
  bool busy = false, history = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (service == null) {
      service = PaymentNotifications(AppScope.storeOf(context));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) refresh();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> refresh() async {
    if (busy || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await service!.sync();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException ? e.message : '读取通知失败，原始队列仍保留，请重试',
        );
      }
    }
    // Queue or ledger failures must not hide permission and capacity diagnostics.
    try {
      final next = await service!.status();
      if (mounted) setState(() => status = next);
    } catch (_) {
      if (mounted) setState(() => error ??= '无法读取采集状态，请重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> review(Json record) async {
    await reviewPaymentNotification(context, service!, record);
    if (mounted) refresh();
  }

  @override
  Widget build(BuildContext context) {
    AppScope.storeOf(context);
    final supported = service?.supported == true;
    final records =
        service?.records
            .where(
              (r) =>
                  history ? r['status'] != 'pending' : r['status'] == 'pending',
            )
            .toList() ??
        <Json>[];
    final last = status['lastReceived'] as int? ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('支付通知识别'),
        actions: [
          IconButton(
            tooltip: '刷新通知',
            onPressed: busy ? null : refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: PageList(
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('仅保存微信、支付宝的支付相关通知，先生成待确认账单。通知在本机处理，不会自动发送给 AI。'),
                const SizedBox(height: 10),
                if (!supported) const Text('通知采集仅支持 Android。'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('采集支付通知'),
                  value: status['enabled'] == true,
                  onChanged: !supported || busy
                      ? null
                      : (v) async {
                          await perform(context, () => service!.setEnabled(v));
                          await refresh();
                        },
                ),
                Text(
                  '通知使用权：${status['granted'] == true ? '已授权' : '未授权'} · 监听：${status['connected'] == true ? '已连接' : '未连接'}',
                ),
                Text(
                  '上次收到：${last == 0 ? '暂无记录' : DateFormat('MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(last))}',
                ),
                Text('原生收件箱：${status['queued'] ?? 0} 条'),
                if ((status['overflow'] as int? ?? 0) > 0)
                  Text(
                    '队列曾满，${status['overflow']} 次通知未能保存，请及时处理。',
                    style: const TextStyle(color: coral),
                  ),
                if (status['storageError'] == true)
                  const Text(
                    '原生存储发生错误，可能有通知未保存。',
                    style: TextStyle(color: coral),
                  ),
                if (supported)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => perform(context, service!.openSettings),
                    child: const Text('打开系统通知使用权设置'),
                  ),
                const Text(
                  '支付不一定产生系统通知。省电限制、撤回授权或强行停止可能中断采集；重新打开后可在此检查状态。',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(error!, style: const TextStyle(color: coral)),
            ),
          if (busy) const LinearProgressIndicator(),
          const SizedBox(height: 18),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('待确认')),
              ButtonSegment(value: true, label: Text('已处理')),
            ],
            selected: {history},
            onSelectionChanged: (v) => setState(() => history = v.first),
          ),
          const SizedBox(height: 14),
          if (!history && records.isNotEmpty)
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () => openPage(
                      context,
                      PaymentReviewPage(notifications: service),
                    ),
              icon: const Icon(Icons.fact_check_outlined),
              label: Text('集中核对 ${records.length} 条记录'),
            ),
          if (records.isEmpty)
            const EmptyState(
              '暂无记录',
              '启用并授予通知使用权后，实际收到的支付通知会显示在这里。',
              icon: Icons.notifications_none,
            ),
          for (final r in records) ...[
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${r['sourcePackage'] == 'com.tencent.mm' ? '微信' : '支付宝'} · ${r['amountCents'] == null ? '金额待补全' : money(r['amountCents'])}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    DateFormat('yyyy-MM-dd HH:mm').format(
                      DateTime.fromMillisecondsSinceEpoch(r['postedAt']),
                    ),
                  ),
                  if (r['status'] == 'pending') ...[
                    Text(r['reviewReason']),
                    if (r['possibleDuplicate'] == true)
                      const Text(
                        '与另一条通知金额、时间接近，请核对重复。',
                        style: TextStyle(color: coral),
                      ),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('查看通知原文'),
                      children: [SelectableText('${r['title']}\n${r['text']}')],
                    ),
                    Wrap(
                      spacing: 12,
                      children: [
                        if (r['kind'] != 'refund')
                          FilledButton(
                            onPressed: busy ? null : () => review(r),
                            child: const Text('核对并记账'),
                          ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => perform(
                                  context,
                                  () => service!.dismiss(r['eventId']),
                                ),
                          child: const Text('忽略'),
                        ),
                      ],
                    ),
                  ] else
                    Text(r['status'] == 'applied' ? '已入账，可在账单页修改或删除' : '已忽略'),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (!history)
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (await confirm(
                        context,
                        '清除待处理通知？',
                        '暂停采集并清除尚未入账的通知内容，已入账账单保留。',
                        action: '清除',
                      )) {
                        if (!context.mounted) return;
                        await perform(context, service!.clearPending);
                        await refresh();
                      }
                    },
              child: const Text('暂停采集并清除待处理通知'),
            ),
        ],
      ),
    );
  }
}
