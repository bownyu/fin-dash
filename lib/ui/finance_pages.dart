import 'dart:convert';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../domain/models.dart';
import '../services/file_export.dart';
import '../services/payment_notifications.dart';
import 'payment_review_page.dart';
import 'ai_pages.dart';
import 'charts.dart';
import 'design.dart';
import 'editors.dart';
import 'preferences.dart';

class HomePage extends StatefulWidget {
  final VoidCallback onBills, onStats;
  const HomePage({super.key, required this.onBills, required this.onStats});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int assetView = 0;
  Period spendingPeriod = Period.day;
  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    final colors = WalletColors.of(context);
    final visible = store.data.settings['visible'] != false;
    final value = [store.netWorth, store.assets, store.liabilities][assetView];
    final label = ['净资产', '总资产', '总负债'][assetView];
    final spend = store.total(
      TxType.expense,
      range: DateRange.forPeriod(spendingPeriod, DateTime.now()),
    );
    final recent = store.query().take(12).toList();
    final pendingPayments = PaymentNotifications.pendingCount(store.data);
    final budget = (store.data.settings['budget'] as num? ?? 0).toInt();
    final monthSpend = store.total(
      TxType.expense,
      range: DateRange.forPeriod(Period.month, DateTime.now()),
    );
    return PageList(
      children: [
        if (pendingPayments > 0) ...[
          Semantics(
            liveRegion: true,
            child: Panel(
              key: const Key('home-payment-pending'),
              child: Row(
                children: [
                  const Icon(Icons.receipt_long_rounded, color: primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$pendingPayments 笔支付记录待确认',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const Text(
                          '核对金额和实际账户后入账',
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        openPage(context, const PaymentReviewPage()),
                    child: const Text('去核对'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
        OverviewGrid(
          hero: HeroPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () =>
                            setState(() => assetView = (assetView + 1) % 3),
                        child: Row(
                          children: [
                            Text(
                              label,
                              style: TextStyle(
                                color: colors.secondary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              Icons.unfold_more_rounded,
                              size: 15,
                              color: colors.secondary,
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('theme-picker'),
                      tooltip: '切换外观',
                      onPressed: () => showThemePicker(context),
                      icon: Icon(
                        colors.dark
                            ? Icons.dark_mode_outlined
                            : Icons.light_mode_outlined,
                        size: 20,
                        color: colors.secondary,
                      ),
                    ),
                    IconButton(
                      tooltip: '提醒中心',
                      onPressed: () => openPage(context, const RemindersPage()),
                      icon: Badge(
                        isLabelVisible: store.suggestions.isNotEmpty,
                        smallSize: 6,
                        child: Icon(
                          Icons.notifications_none_rounded,
                          size: 20,
                          color: colors.secondary,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: visible ? '隐藏金额' : '显示金额',
                      onPressed: () => perform(
                        context,
                        () => store.change(
                          (d) => d.settings['visible'] = !visible,
                        ),
                      ),
                      icon: Icon(
                        visible
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        color: colors.secondary,
                        size: 20,
                      ),
                    ),
                  ],
                ),
                InkWell(
                  onTap: () => setState(() => assetView = (assetView + 1) % 3),
                  child: SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: MoneyText(
                      value,
                      size: 40,
                      color: colors.ink,
                      respectPrivacy: true,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: List.generate(
                    3,
                    (i) => Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: i == 2 ? 0 : 6),
                        child: Semantics(
                          selected: assetView == i,
                          child: InkWell(
                            key: Key('asset-view-$i'),
                            onTap: () => setState(() => assetView = i),
                            borderRadius: BorderRadius.circular(12),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              decoration: BoxDecoration(
                                color: assetView == i
                                    ? primary.withValues(
                                        alpha: colors.dark ? .25 : .1,
                                      )
                                    : colors.ink.withValues(alpha: .035),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                ['净资产', '总资产', '总负债'][i],
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: assetView == i
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: assetView == i
                                      ? (colors.dark
                                            ? const Color(0xFFA8CBFF)
                                            : primary)
                                      : colors.secondary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Divider(color: colors.ink.withValues(alpha: .08)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => setState(
                          () => spendingPeriod = spendingPeriod == Period.day
                              ? Period.week
                              : spendingPeriod == Period.week
                              ? Period.month
                              : Period.day,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${spendingPeriod == Period.day
                                  ? '今日'
                                  : spendingPeriod == Period.week
                                  ? '本周'
                                  : '本月'}支出 ↕',
                              style: TextStyle(
                                color: colors.secondary,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 5),
                            MoneyText(
                              spend,
                              size: 21,
                              color: colors.ink,
                              respectPrivacy: true,
                            ),
                          ],
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => openPage(context, const AccountsPage()),
                      style: TextButton.styleFrom(
                        foregroundColor: colors.dark
                            ? const Color(0xFFB6D4FF)
                            : primary,
                        backgroundColor: primary.withValues(alpha: .09),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 11,
                        ),
                      ),
                      icon: const Icon(
                        Icons.account_balance_wallet_outlined,
                        size: 18,
                      ),
                      label: const Text('管理资产'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          tiles: [
            _Summary(
              '本月收入',
              store.total(
                TxType.income,
                range: DateRange.forPeriod(Period.month, DateTime.now()),
              ),
              colors.income,
              respectPrivacy: true,
            ),
            _Summary('本月支出', monthSpend, colors.expense, respectPrivacy: true),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _Action(
                '记一笔',
                Icons.add_rounded,
                primary,
                () => openPage(context, const TransactionEditor(), modal: true),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Action(
                '转账',
                Icons.swap_horiz_rounded,
                mint,
                () => openPage(
                  context,
                  const TransactionEditor(initialType: TxType.transfer),
                  modal: true,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Action(
                'AI 顾问',
                Icons.auto_awesome_rounded,
                const Color(0xFFA78BFA),
                () => openPage(context, const ChatPage()),
              ),
            ),
          ],
        ),
        if (store.suggestions.isNotEmpty) ...[
          const SizedBox(height: 18),
          Panel(
            padding: const EdgeInsets.all(16),
            color: primary.withValues(alpha: .09),
            child: Row(
              children: [
                const Icon(Icons.lightbulb_outline_rounded, color: primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        store.suggestions.first['title'],
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        store.suggestions.first['text'],
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '查看提醒',
                  onPressed: () => openPage(context, const RemindersPage()),
                  icon: const Icon(Icons.chevron_right_rounded, color: muted),
                ),
              ],
            ),
          ),
        ],
        SectionTitle(
          '快捷交易',
          action: '管理',
          onAction: () => openPage(context, const QuickEntriesPage()),
        ),
        if (store.data.quickEntries.isEmpty)
          Panel(
            padding: const EdgeInsets.all(16),
            child: InkWell(
              onTap: () => openPage(
                context,
                const TransactionEditor(saveAsQuick: true),
                modal: true,
              ),
              child: const Row(
                children: [
                  Icon(Icons.add_circle_outline_rounded, color: primary),
                  SizedBox(width: 12),
                  Expanded(child: Text('添加快捷交易')),
                  Icon(Icons.chevron_right_rounded, color: muted),
                ],
              ),
            ),
          )
        else
          SizedBox(
            height: 132 * MediaQuery.textScalerOf(context).scale(1),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: store.data.quickEntries.length + 1,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                if (i == store.data.quickEntries.length) {
                  return SizedBox(
                    width: 96,
                    child: _QuickTile(
                      '添加',
                      null,
                      Icons.add_rounded,
                      muted,
                      () => openPage(
                        context,
                        const TransactionEditor(saveAsQuick: true),
                        modal: true,
                      ),
                    ),
                  );
                }
                final q = store.data.quickEntries[i];
                return SizedBox(
                  width: 96,
                  child: _QuickTile(
                    q.title,
                    q.amount,
                    iconOf(q.icon),
                    txColor(q.type),
                    () => openPage(
                      context,
                      TransactionEditor(quick: q),
                      modal: true,
                    ),
                  ),
                );
              },
            ),
          ),
        if (budget > 0) ...[
          const SectionTitle('本月预算'),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        monthSpend > budget
                            ? '超出 ${money(monthSpend - budget)}'
                            : '还可支出 ${money(budget - monthSpend)}',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: monthSpend > budget ? coral : null,
                        ),
                      ),
                    ),
                    Text(
                      '${(monthSpend / budget * 100).round()}%',
                      style: const TextStyle(color: muted),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: (monthSpend / budget).clamp(0.0, 1.0),
                    minHeight: 6,
                    color: monthSpend > budget ? coral : primary,
                    backgroundColor: primary.withValues(alpha: .1),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '预算 ${money(budget)} · 支出 ${money(monthSpend)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
        SectionTitle('最近交易', action: '全部账单', onAction: widget.onBills),
        if (recent.isEmpty)
          Panel(
            child: EmptyState(
              '还没有账单',
              '暂无账单，点击开始记账。',
              action: FilledButton(
                onPressed: () =>
                    openPage(context, const TransactionEditor(), modal: true),
                child: const Text('开始记账'),
              ),
            ),
          )
        else
          ...groupTxs(recent).entries.map(
            (g) => Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 3, bottom: 8),
                    child: Text(
                      dateHeading(DateTime.parse(g.key)),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Panel(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 2,
                    ),
                    child: Column(
                      children: g.value
                          .map(
                            (t) => TransactionRow(
                              t,
                              onTap: () => transactionActions(context, t),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (recent.isNotEmpty)
          TextButton(onPressed: widget.onBills, child: const Text('查看全部账单 →')),
        const SizedBox(height: 72),
      ],
    );
  }
}

class _Action extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _Action(this.text, this.icon, this.color, this.onTap);
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Ink(
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: .05),
          WalletColors.of(context).surface,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: WalletColors.of(context).border),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color, size: 23),
              ),
              const SizedBox(height: 8),
              Text(
                text,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _QuickTile extends StatelessWidget {
  final String title;
  final int? amount;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _QuickTile(this.title, this.amount, this.icon, this.color, this.onTap);
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Ink(
      decoration: BoxDecoration(
        color: WalletColors.of(context).surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: WalletColors.of(context).border),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(height: 7),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              Text(
                amount == null ? '自定金额' : money(amount!, symbol: false),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('资产管理'),
        actions: [
          IconButton(
            tooltip: '添加账户',
            onPressed: () =>
                openPage(context, const AccountEditor(), modal: true),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: PageList(
        children: [
          HeroPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '净资产',
                  style: TextStyle(color: WalletColors.of(context).secondary),
                ),
                const SizedBox(height: 8),
                MoneyText(
                  store.netWorth,
                  size: 36,
                  color: WalletColors.of(context).ink,
                  respectPrivacy: true,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(child: _AssetMini('总资产', store.assets, mint)),
                    Expanded(
                      child: _AssetMini('总负债', store.liabilities, coral),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (store.data.accounts.isEmpty)
            EmptyState(
              '添加你的第一个账户',
              '支持资金、信用、充值与投资理财账户。',
              icon: Icons.account_balance_wallet_outlined,
              action: FilledButton.icon(
                onPressed: () =>
                    openPage(context, const AccountEditor(), modal: true),
                icon: const Icon(Icons.add_rounded),
                label: const Text('添加账户'),
              ),
            ),
          ...accountGroups.entries
              .where(
                (g) => store.activeAccounts.any((a) => a.category == g.key),
              )
              .map((g) {
                final accounts = store.activeAccounts
                    .where((a) => a.category == g.key)
                    .toList();
                return Column(
                  children: [
                    SectionTitle(g.value),
                    Panel(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 4,
                      ),
                      child: Column(
                        children: accounts
                            .map(
                              (a) => _AccountRow(
                                a,
                                onTap: () =>
                                    openPage(context, AccountDetailPage(a.id)),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ],
                );
              }),
          if (store.data.accounts.any((a) => a.archived)) ...[
            const SectionTitle('已归档账户'),
            Panel(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: store.data.accounts
                    .where((a) => a.archived)
                    .map(
                      (a) => _AccountRow(
                        a,
                        onTap: () => openPage(context, AccountDetailPage(a.id)),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () =>
                openPage(context, const AccountEditor(), modal: true),
            icon: const Icon(Icons.add_rounded),
            label: const Text('添加账户'),
          ),
        ],
      ),
    );
  }
}

class _AssetMini extends StatelessWidget {
  final String title;
  final int value;
  final Color color;
  const _AssetMini(this.title, this.value, this.color);
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            title,
            style: TextStyle(
              color: WalletColors.of(context).secondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
      const SizedBox(height: 7),
      MoneyText(value, size: 19, respectPrivacy: true),
    ],
  );
}

class _AccountRow extends StatelessWidget {
  final WalletAccount a;
  final VoidCallback onTap;
  const _AccountRow(this.a, {required this.onTap});
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(vertical: 4),
    onTap: onTap,
    leading: IconBadge(a.icon, colorOf(a.color)),
    title: Text(a.name, style: const TextStyle(fontWeight: FontWeight.w600)),
    subtitle: Text(
      a.archived
          ? '已归档 · 历史账单保留'
          : a.includeInTotal
          ? accountGroups[a.category]!
          : '不计入总资产',
      style: Theme.of(context).textTheme.bodySmall,
    ),
    trailing: SizedBox(
      width: 135,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Expanded(
            child: MoneyText(
              AppScope.storeOf(context).balance(a),
              size: 17,
              respectPrivacy: true,
            ),
          ),
          const Icon(Icons.chevron_right_rounded, size: 18, color: muted),
        ],
      ),
    ),
  );
}

class AccountDetailPage extends StatelessWidget {
  final String id;
  const AccountDetailPage(this.id, {super.key});
  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context),
        a = AppScope.storeOf(context).account(id);
    if (a == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('账户')),
        body: const EmptyState('账户不存在', '该账户可能已被删除。'),
      );
    }
    final txs = store.query(accountId: id), balance = store.balance(a);
    final credit = a.category == 'credit';
    DateRange? cycle;
    if (credit && a.billingDay != null) {
      final now = DateTime.now();
      final cutoffDay = a.billingDay! + (a.countBillingDayInPrevious ? 1 : 0);
      final cutoff = DateTime(now.year, now.month, cutoffDay);
      cycle = now.isBefore(cutoff)
          ? DateRange(DateTime(now.year, now.month - 1, cutoffDay), cutoff)
          : DateRange(cutoff, DateTime(now.year, now.month + 1, cutoffDay));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(a.name),
        actions: [
          IconButton(
            tooltip: '编辑账户',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () =>
                openPage(context, AccountEditor(initial: a), modal: true),
          ),
        ],
      ),
      body: PageList(
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconBadge(a.icon, colorOf(a.color)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        a.name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (a.archived) const Chip(label: Text('已归档')),
                  ],
                ),
                const SizedBox(height: 22),
                Text(
                  credit && balance < 0 ? '当前欠款' : '账户余额',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 5),
                MoneyText(
                  credit && balance < 0 ? -balance : balance,
                  size: 34,
                  color: balance < 0 ? coral : null,
                  respectPrivacy: true,
                ),
                if (credit) ...[
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '信用额度',
                              style: TextStyle(color: muted, fontSize: 12),
                            ),
                            MoneyText(
                              a.creditLimit,
                              size: 18,
                              respectPrivacy: true,
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '可用额度',
                              style: TextStyle(color: muted, fontSize: 12),
                            ),
                            MoneyText(
                              max(0, a.creditLimit + balance),
                              size: 18,
                              color: mint,
                              respectPrivacy: true,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '账单日 ${a.billingDay ?? '未设置'} · 还款日 ${a.repaymentDay ?? '未设置'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (cycle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        '本期 ${DateFormat('M/d').format(cycle.start)}–${DateFormat('M/d').format(cycle.end.subtract(const Duration(days: 1)))} · 消费 ${money(store.total(TxType.expense, transactions: txs.where((t) => cycle!.contains(t.date)).toList()))}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
                if (a.note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      a.note,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  a.includeInTotal ? '此账户计入总资产' : '此账户不计入总资产',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (!a.archived) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => openPage(
                context,
                TransactionEditor(
                  initialType: credit ? TxType.transfer : TxType.expense,
                  initialAccount: a.id,
                ),
                modal: true,
              ),
              icon: Icon(credit ? Icons.swap_horiz_rounded : Icons.add_rounded),
              label: Text(credit ? '信用卡还款' : '使用此账户记账'),
            ),
          ],
          SectionTitle('账户流水 · ${txs.length} 笔'),
          if (txs.isEmpty)
            const EmptyState('还没有流水', '与此账户关联的账单会显示在这里。')
          else
            ...groupTxs(txs).entries.map(
              (g) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    dateHeading(DateTime.parse(g.key)),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Panel(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Column(
                      children: g.value
                          .map(
                            (t) => TransactionRow(
                              t,
                              onTap: () => transactionActions(context, t),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          OutlinedButton.icon(
            onPressed: () async {
              if (await confirm(
                context,
                a.archived ? '恢复账户？' : '归档账户？',
                '历史账单和余额会保留。归档后不能用于新记账，是否计入总资产由账户设置决定。',
              )) {
                if (context.mounted) {
                  await perform(
                    context,
                    () => store.saveAccount(a.copyWith(archived: !a.archived)),
                    success: a.archived ? '账户已恢复' : '账户已归档',
                  );
                }
              }
            },
            icon: Icon(
              a.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
            ),
            label: Text(a.archived ? '恢复账户' : '归档账户'),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () async {
              if (await confirm(
                context,
                '删除账户？',
                '只有没有关联账单的账户可以删除。',
                action: '删除',
                destructive: true,
              )) {
                if (!context.mounted) return;
                final ok = await perform(
                  context,
                  () => store.deleteAccount(id),
                );
                if (ok && context.mounted) Navigator.pop(context);
              }
            },
            child: const Text('删除账户', style: TextStyle(color: coral)),
          ),
        ],
      ),
    );
  }
}

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});
  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  Period period = Period.day;
  DateTime anchor = DateTime.now();
  TxType type = TxType.expense;
  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context),
        range = DateRange.forPeriod(period, anchor);
    final grouped = store.breakdown(type, range),
        total = store.total(type, range: range),
        count = store.query(range: range, type: type).length;
    Color categoryColor(String name, int i) => colorOf(
      store.data.categories
              .where((c) => c.name == name && c.type == type)
              .firstOrNull
              ?.color ??
          palette[i % palette.length],
    );
    final segments = grouped.entries.indexed
        .map((e) => (e.$2.value, categoryColor(e.$2.key, e.$1)))
        .toList();
    final title = switch (period) {
      Period.day => DateFormat('yyyy年M月d日').format(anchor),
      Period.week =>
        '${DateFormat('M/d').format(range.start)} – ${DateFormat('M/d').format(range.end.subtract(const Duration(days: 1)))}',
      Period.month => DateFormat('yyyy年M月').format(anchor),
      Period.year => '${anchor.year}年',
    };
    final values = List<int>.filled(
      period == Period.day
          ? 24
          : period == Period.year
          ? 12
          : range.end.difference(range.start).inDays,
      0,
    );
    for (final t in store.query(range: range, type: type)) {
      final i = period == Period.day
          ? t.date.hour
          : period == Period.year
          ? t.date.month - 1
          : DateTime(
              t.date.year,
              t.date.month,
              t.date.day,
            ).difference(range.start).inDays;
      if (i >= 0 && i < values.length) values[i] += t.amount;
    }
    final labels = switch (period) {
      Period.day => ['00:00', '12:00', '23:00'],
      Period.week => ['周一', '周四', '周日'],
      Period.month => [
        '1日',
        '${(values.length / 2).round()}日',
        '${values.length}日',
      ],
      Period.year => ['1月', '6月', '12月'],
    };
    return PageList(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '统计',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            TextButton.icon(
              onPressed: () => openPage(
                context,
                ChatPage(
                  initialPrompt: '请分析 $title 的收支，并给出具体改进建议。',
                  analysisRange: range,
                ),
              ),
              icon: const Icon(Icons.auto_awesome_rounded, size: 18),
              label: const Text('AI 分析'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        SegmentedButton<Period>(
          segments: Period.values
              .map((p) => ButtonSegment(value: p, label: Text(p.label)))
              .toList(),
          selected: {period},
          onSelectionChanged: (v) => setState(() => period = v.first),
        ),
        const SizedBox(height: 15),
        Row(
          children: [
            IconButton(
              tooltip: '上一周期',
              onPressed: () =>
                  setState(() => anchor = DateRange.shift(period, anchor, -1)),
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Expanded(
              child: TextButton(
                onPressed: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: anchor,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (date != null) setState(() => anchor = date);
                },
                child: Text(
                  title,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '下一周期',
              onPressed: () =>
                  setState(() => anchor = DateRange.shift(period, anchor, 1)),
              icon: const Icon(Icons.chevron_right_rounded),
            ),
            TextButton(
              onPressed: () => setState(() => anchor = DateTime.now()),
              child: const Text('今天'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _Summary(
                '收入',
                store.total(TxType.income, range: range),
                mint,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Summary(
                '支出',
                store.total(TxType.expense, range: range),
                coral,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Panel(
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final t in [TxType.expense, TxType.income])
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: ChoiceChip(
                        label: Text(t.label),
                        selected: type == t,
                        onSelected: (_) => setState(() => type = t),
                      ),
                    ),
                ],
              ),
              GestureDetector(
                onHorizontalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0).abs() > 100) {
                    setState(
                      () => period =
                          Period.values[(period.index +
                                  ((d.primaryVelocity ?? 0) < 0 ? 1 : -1))
                              .clamp(0, 3)],
                    );
                  }
                },
                child: RingChart(
                  segments: segments,
                  center: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '总${type.label}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 6),
                      MoneyText(total, size: 27),
                      const SizedBox(height: 6),
                      Text(
                        '$count 笔账单',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              if (total == 0)
                const Text(
                  '这个周期还没有记录，试试切换日期。',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              const SizedBox(height: 8),
              Text(
                '结余 ${money(store.total(TxType.income, range: range) - store.total(TxType.expense, range: range))} · 转账不计入收支',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SectionTitle('收支趋势'),
        Panel(
          child: TrendChart(values: values, labels: labels),
        ),
        const SectionTitle('分类明细'),
        if (grouped.isEmpty)
          const EmptyState('暂无分类数据', '有账单后，会在这里显示分类占比。')
        else
          Panel(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              children: grouped.entries.indexed.map((e) {
                final color = categoryColor(e.$2.key, e.$1),
                    category = store.data.categories
                        .where((c) => c.name == e.$2.key && c.type == type)
                        .firstOrNull;
                return InkWell(
                  onTap: () => openPage(
                    context,
                    FilteredBillsPage(
                      range: range,
                      type: type,
                      category: e.$2.key,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            IconBadge(
                              category?.icon ?? 'more_horiz',
                              color,
                              size: 36,
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Text(e.$2.key)),
                            MoneyText(e.$2.value, size: 17),
                            const SizedBox(width: 12),
                            Text(
                              '${(e.$2.value / total * 100).toStringAsFixed(1)}%',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const Icon(
                              Icons.chevron_right_rounded,
                              color: muted,
                              size: 16,
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: LinearProgressIndicator(
                            value: e.$2.value / total,
                            minHeight: 4,
                            color: color,
                            backgroundColor: color.withValues(alpha: .08),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  final String title;
  final int value;
  final Color color;
  final bool respectPrivacy;
  const _Summary(
    this.title,
    this.value,
    this.color, {
    this.respectPrivacy = false,
  });
  @override
  Widget build(BuildContext context) => Panel(
    padding: const EdgeInsets.all(16),
    color: Color.alphaBlend(
      color.withValues(alpha: .055),
      WalletColors.of(context).surface,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            Icon(
              title.contains('收入')
                  ? Icons.south_west_rounded
                  : Icons.north_east_rounded,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 6),
            Text(title, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 10),
        MoneyText(value, size: 23, respectPrivacy: respectPrivacy),
      ],
    ),
  );
}

class BillsPage extends StatefulWidget {
  final DateRange? initialRange;
  final TxType? initialType;
  final String? initialCategory;
  const BillsPage({
    super.key,
    this.initialRange,
    this.initialType,
    this.initialCategory,
  });
  @override
  State<BillsPage> createState() => _BillsPageState();
}

class _BillsPageState extends State<BillsPage> {
  final search = TextEditingController();
  DateRange? range;
  TxType? type;
  String? category, accountId;
  String dateLabel = '全部日期';
  Set<String>? selected;
  @override
  void initState() {
    super.initState();
    range = widget.initialRange;
    type = widget.initialType;
    category = widget.initialCategory;
    if (range != null) {
      dateLabel =
          '${DateFormat('M/d').format(range!.start)}–${DateFormat('M/d').format(range!.end.subtract(const Duration(days: 1)))}';
    }
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> filters() async {
    final store = AppScope.storeOf(context);
    var newType = type, newCategory = category, newAccount = accountId;
    var newRange = range;
    var label = dateLabel;
    final applied = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (c) => StatefulBuilder(
        builder: (c, state) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            20 + MediaQuery.viewInsetsOf(c).bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '筛选账单',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 20),
                const Text('日期范围', style: TextStyle(color: muted)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('全部'),
                      selected: newRange == null,
                      onSelected: (_) => state(() {
                        newRange = null;
                        label = '全部日期';
                      }),
                    ),
                    for (final p in Period.values)
                      ChoiceChip(
                        label: Text('本${p.label}'),
                        selected: label == '本${p.label}',
                        onSelected: (_) => state(() {
                          newRange = DateRange.forPeriod(p, DateTime.now());
                          label = '本${p.label}';
                        }),
                      ),
                    ActionChip(
                      label: const Text('自定义'),
                      avatar: const Icon(Icons.date_range_rounded, size: 17),
                      onPressed: () async {
                        final picked = await showDateRangePicker(
                          context: c,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                          initialDateRange: newRange == null
                              ? null
                              : DateTimeRange(
                                  start: newRange!.start,
                                  end: newRange!.end.subtract(
                                    const Duration(days: 1),
                                  ),
                                ),
                        );
                        if (picked != null) {
                          state(() {
                            newRange = DateRange(
                              picked.start,
                              DateTime(
                                picked.end.year,
                                picked.end.month,
                                picked.end.day + 1,
                              ),
                            );
                            label =
                                '${DateFormat('M/d').format(picked.start)}–${DateFormat('M/d').format(picked.end)}';
                          });
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                const Text('交易类型', style: TextStyle(color: muted)),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('全部'),
                      selected: newType == null,
                      onSelected: (_) => state(() {
                        newType = null;
                        newCategory = null;
                      }),
                    ),
                    for (final t in TxType.values)
                      ChoiceChip(
                        label: Text(t.label),
                        selected: newType == t,
                        onSelected: (_) => state(() {
                          newType = t;
                          newCategory = null;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                DropdownButtonFormField<String>(
                  key: ValueKey(newAccount),
                  initialValue: newAccount,
                  decoration: const InputDecoration(labelText: '账户'),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: '', child: Text('全部账户')),
                    ...store.data.accounts.map(
                      (a) => DropdownMenuItem(value: a.id, child: Text(a.name)),
                    ),
                  ],
                  onChanged: (v) =>
                      state(() => newAccount = v == '' ? null : v),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: ValueKey('$newType-$newCategory'),
                  initialValue: newCategory,
                  decoration: const InputDecoration(labelText: '分类'),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: '', child: Text('全部分类')),
                    ...store.data.categories
                        .where((c) => newType == null || c.type == newType)
                        .map((c) => c.name)
                        .toSet()
                        .map(
                          (name) =>
                              DropdownMenuItem(value: name, child: Text(name)),
                        ),
                  ],
                  onChanged: (v) =>
                      state(() => newCategory = v == '' ? null : v),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => state(() {
                          newType = null;
                          newCategory = null;
                          newAccount = null;
                          newRange = null;
                          label = '全部日期';
                        }),
                        child: const Text('重置'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('应用筛选'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (applied == true) {
      setState(() {
        type = newType;
        category = newCategory;
        accountId = newAccount;
        range = newRange;
        dateLabel = label;
        selected = null;
      });
    }
  }

  Future<void> exportCsv(List<LedgerTx> list) async {
    String field(String text) {
      final safe = RegExp(r'^[=+\-@\t\r]').hasMatch(text.trimLeft())
          ? "'$text"
          : text;
      return '"${safe.replaceAll('"', '""')}"';
    }

    final store = AppScope.storeOf(context);
    final rows = [
      '日期,类型,名称,分类,金额,账户,转出账户,转入账户,备注',
      ...list.map(
        (t) => [
          t.date.toIso8601String(),
          t.type.label,
          t.title,
          t.category,
          moneyInput(t.amount),
          store.account(t.accountId)?.name ?? '',
          store.account(t.fromId)?.name ?? '',
          store.account(t.toId)?.name ?? '',
          t.note,
        ].map(field).join(','),
      ),
    ];
    await perform(context, () async {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出筛选结果',
        fileName: 'findash_bills_${dayKey(DateTime.now())}.csv',
        type: FileType.custom,
        allowedExtensions: ['csv'],
        bytes: Uint8List.fromList(utf8.encode('\uFEFF${rows.join('\r\n')}')),
      );
      await completeFileExport(
        path,
        Uint8List.fromList(utf8.encode('\uFEFF${rows.join('\r\n')}')),
      );
      if (path != null && mounted) toast(context, '已导出 ${list.length} 笔账单');
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    final list = store.query(
      range: range,
      type: type,
      category: category,
      accountId: accountId,
      search: search.text,
    );
    final groups = groupTxs(list).entries.toList();
    final active = selected != null;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 14, 4),
          child: Row(
            children: [
              if (active)
                IconButton(
                  tooltip: '退出选择',
                  onPressed: () => setState(() => selected = null),
                  icon: const Icon(Icons.close_rounded),
                ),
              Expanded(
                child: Text(
                  active ? '已选 ${selected!.length} 笔' : '账单',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              if (active) ...[
                TextButton(
                  onPressed: () =>
                      setState(() => selected = list.map((t) => t.id).toSet()),
                  child: const Text('全选'),
                ),
                IconButton(
                  tooltip: '删除所选账单',
                  onPressed: selected!.isEmpty
                      ? null
                      : () async {
                          final ids = Set<String>.from(selected!);
                          if (await confirm(
                            context,
                            '删除 ${ids.length} 笔账单？',
                            '所有关联账户余额与统计会同步更新。',
                            action: '删除',
                            destructive: true,
                          )) {
                            if (context.mounted &&
                                await perform(
                                  context,
                                  () => store.deleteTxs(ids),
                                  success: '账单已删除',
                                )) {
                              setState(() => selected = null);
                            }
                          }
                        },
                  icon: const Icon(Icons.delete_outline_rounded, color: coral),
                ),
              ] else ...[
                IconButton(
                  tooltip: '导出当前账单',
                  onPressed: list.isEmpty ? null : () => exportCsv(list),
                  icon: const Icon(Icons.ios_share_rounded, size: 21),
                ),
                IconButton(
                  tooltip: '筛选',
                  onPressed: filters,
                  icon: const Icon(Icons.tune_rounded),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: TextField(
            controller: search,
            onChanged: (_) => setState(() => selected = null),
            decoration: InputDecoration(
              hintText: '搜索名称、备注、分类或账户',
              prefixIcon: const Icon(Icons.search_rounded, color: muted),
              suffixIcon: search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      onPressed: () => setState(() => search.clear()),
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '$dateLabel · ${list.length} 笔',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (type != null || category != null || accountId != null)
                TextButton(
                  onPressed: filters,
                  child: Text(
                    [
                      type?.label,
                      category,
                      store.account(accountId)?.name,
                    ].whereType<String>().join(' · '),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
          child: Panel(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '收入',
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                      MoneyText(
                        store.total(TxType.income, transactions: list),
                        size: 19,
                        color: mint,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '支出',
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                      MoneyText(
                        store.total(TxType.expense, transactions: list),
                        size: 19,
                        color: coral,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: groups.isEmpty
              ? const SingleChildScrollView(
                  child: EmptyState('没有符合条件的账单', '调整筛选条件，或者记下新的一笔。'),
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    10,
                    20,
                    MediaQuery.paddingOf(context).bottom + 30,
                  ),
                  itemCount: groups.length,
                  itemBuilder: (context, i) {
                    final g = groups[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 9),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    dateHeading(DateTime.parse(g.key)),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                                Text(
                                  '支出 ${money(store.total(TxType.expense, transactions: g.value))}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          Panel(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 2,
                            ),
                            child: Column(
                              children: g.value
                                  .map(
                                    (t) => TransactionRow(
                                      t,
                                      selected: active
                                          ? selected!.contains(t.id)
                                          : null,
                                      onLongPress: () {
                                        HapticFeedback.mediumImpact();
                                        setState(() => selected = {t.id});
                                      },
                                      onTap: () {
                                        if (active) {
                                          setState(
                                            () => selected!.contains(t.id)
                                                ? selected!.remove(t.id)
                                                : selected!.add(t.id),
                                          );
                                        } else {
                                          transactionActions(context, t);
                                        }
                                      },
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class FilteredBillsPage extends StatelessWidget {
  final DateRange range;
  final TxType type;
  final String category;
  const FilteredBillsPage({
    super.key,
    required this.range,
    required this.type,
    required this.category,
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('$category明细')),
    body: BillsPage(
      initialRange: range,
      initialType: type,
      initialCategory: category,
    ),
  );
}
