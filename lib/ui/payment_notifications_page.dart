import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../domain/models.dart';
import '../services/payment_notifications.dart';
import 'design.dart';
import 'payment_review_page.dart';

class PaymentNotificationsPage extends StatefulWidget {
  final PaymentNotifications? notifications;
  const PaymentNotificationsPage({super.key, this.notifications});
  @override
  State<PaymentNotificationsPage> createState() =>
      _PaymentNotificationsPageState();
}

class _PaymentNotificationsPageState extends State<PaymentNotificationsPage>
    with WidgetsBindingObserver {
  PaymentNotifications? service;
  Json status = {};
  String? error;
  bool busy = false, history = false, reconnecting = false;
  String? connectionMessage;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (service == null) {
      service =
          widget.notifications ??
          PaymentNotifications(AppScope.storeOf(context));
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
      connectionMessage = null;
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

  Future<void> reconnect() async {
    if (busy) return;
    setState(() {
      busy = true;
      reconnecting = true;
      error = null;
      connectionMessage = null;
    });
    try {
      await service!.reconnect();
      for (var attempt = 0; attempt < 6; attempt++) {
        final next = await service!.status();
        if (!mounted) return;
        setState(() => status = next);
        if (next['connected'] == true ||
            next['granted'] != true ||
            next['enabled'] != true) {
          break;
        }
        if (attempt < 5) {
          await Future<void>.delayed(const Duration(milliseconds: 600));
        }
        if (!mounted) return;
      }
      if (mounted) {
        setState(() {
          connectionMessage = status['enabled'] != true
              ? '请先开启采集支付通知'
              : status['granted'] != true
              ? '请在系统设置中授予通知使用权'
              : status['connected'] == true
              ? '监听已连接，可以接收新的支付通知'
              : '系统暂未连接。可稍后刷新；若仍未连接，请打开系统设置，将 FinDash 通知使用权关闭后重新开启。';
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '重新连接失败，请重试或打开系统通知使用权设置');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          reconnecting = false;
        });
      }
    }
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
                if (supported) ...[
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    key: const Key('payment-reconnect'),
                    onPressed:
                        busy ||
                            status['enabled'] != true ||
                            status['granted'] != true ||
                            status['connected'] == true
                        ? null
                        : reconnect,
                    icon: const Icon(Icons.sync_rounded),
                    label: Text(
                      reconnecting
                          ? '正在连接…'
                          : status['connected'] == true
                          ? '监听已连接'
                          : '重新连接监听',
                    ),
                  ),
                  if (connectionMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        connectionMessage!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
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
                  '无需保持 App 界面开启。收到支付通知时在本机识别并保存，重新进入 App 后再确认入账。连接中断时会有限重试，开机和升级后也会尝试恢复监听。',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ],
            ),
          ),
          if (supported) ...[
            const SizedBox(height: 12),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '后台监听设置',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    status['batteryUnrestricted'] == true
                        ? '电池优化：已允许不受限制'
                        : '电池优化：请检查是否允许后台运行',
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '在系统设置中允许 FinDash 自启动和后台运行；部分手机还需要允许关联启动，或在最近任务中锁定应用。',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        key: const Key('payment-battery-settings'),
                        onPressed: busy
                            ? null
                            : () => perform(
                                context,
                                service!.openBatterySettings,
                              ),
                        icon: const Icon(Icons.battery_saver_outlined),
                        label: const Text('电池优化设置'),
                      ),
                      TextButton.icon(
                        key: const Key('payment-app-settings'),
                        onPressed: busy
                            ? null
                            : () => perform(context, service!.openAppSettings),
                        icon: const Icon(Icons.settings_outlined),
                        label: const Text('应用后台设置'),
                      ),
                    ],
                  ),
                  const Text(
                    '一键清理仍可能中断监听；强行停止后请重新打开 App。重连无法保证补回断开期间的支付通知。',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ],
              ),
            ),
          ],
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
          if (history)
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (!await confirm(
                        context,
                        '清除已忽略通知的原文？',
                        '这些通知将无法再恢复待确认。已入账账单不受影响。',
                        action: '清除原文',
                        destructive: true,
                      )) {
                        return;
                      }
                      if (!context.mounted) return;
                      await perform(
                        context,
                        service!.clearIgnored,
                        success: '已清除已忽略通知的原文',
                      );
                    },
              child: const Text('清除已忽略通知原文'),
            ),
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
                    '${r['sourcePackage'] == 'com.tencent.mm' ? '微信' : '支付宝'} · ${r['amountCents'] == null ? '金额待补全' : privateMoney(context, r['amountCents'])}',
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
                        FilledButton(
                          onPressed: busy ? null : () => review(r),
                          child: Text(
                            r['kind'] == 'refund' ? '关联原消费并核对退款' : '核对并记账',
                          ),
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
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r['status'] == 'applied' ? '已入账，可在账单页修改或删除' : '已忽略',
                        ),
                        if (r['status'] == 'ignored' && r['cleared'] != true)
                          TextButton.icon(
                            onPressed: busy
                                ? null
                                : () => perform(
                                    context,
                                    () => service!.restoreIgnored(r['eventId']),
                                    success: '已恢复到待确认',
                                  ),
                            icon: const Icon(Icons.undo_rounded),
                            label: const Text('恢复待确认'),
                          ),
                      ],
                    ),
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
