import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../data/wallet_store.dart';
import '../domain/models.dart';
import '../domain/command_context.dart';
import '../services/file_export.dart';
import '../services/payment_notifications.dart';
import 'payment_review_page.dart';
import 'ai_pages.dart';
import 'charts.dart';
import 'design.dart';
import 'interaction.dart';
import 'editors.dart';
import 'preferences.dart';
import 'voice_entry_sheet.dart';

class HomePage extends StatefulWidget {
  final VoidCallback onBills, onStats;
  const HomePage({super.key, required this.onBills, required this.onStats});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  int assetView = 0;
  Period spendingPeriod = Period.day;

  /// Plays once when the home page is created; switching tabs keeps it done.
  late final intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );
  Set<String>? recentIds;
  String? recentEpoch;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (intro.isAnimating || intro.isCompleted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      intro.value = 1;
    } else {
      // The page's own first frame is the costly one; begin after it.
      intro.playSettled();
    }
  }

  @override
  void dispose() {
    intro.dispose();
    super.dispose();
  }

  /// Sections rise in one after another; finished transitions cost nothing.
  Widget reveal(int slot, Widget child) {
    final start = min(slot * .1, .5);
    final progress = intro.drive(
      CurveTween(
        curve: Interval(start, start + .5, curve: Curves.easeOutCubic),
      ),
    );
    return FadeTransition(
      opacity: progress,
      child: AnimatedBuilder(
        animation: progress,
        child: child,
        builder: (_, child) => Transform.translate(
          offset: Offset(0, 14 * (1 - progress.value)),
          child: child,
        ),
      ),
    );
  }

  /// Bills new since the previous build, so a just-saved bill can be pointed
  /// out. Restores and bulk imports change many rows and highlight none.
  Set<String> freshBills(WalletStore store, List<LedgerTx> recent) {
    final ids = {for (final t in recent) t.id};
    final known = recentEpoch == store.ledgerEpoch ? recentIds : null;
    recentIds = ids;
    recentEpoch = store.ledgerEpoch;
    if (known == null) return const {};
    final fresh = ids.difference(known);
    return fresh.length > 3 ? const {} : fresh;
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(
      context,
      domains: const {
        WalletDomain.ledger,
        WalletDomain.preferences,
        WalletDomain.sources,
      },
    );
    final colors = WalletColors.of(context);
    final visible = store.data.settings['visible'] != false;
    final value = [store.netWorth, store.assets, store.liabilities][assetView];
    final label = ['净资产', '总资产', '总负债'][assetView];
    final spend = store.total(
      TxType.expense,
      range: DateRange.forPeriod(spendingPeriod, DateTime.now()),
    );
    final recent = store.query().take(12).toList();
    final fresh = freshBills(store, recent);
    final pendingPayments = PaymentNotifications.pendingCount(store.data);
    final budget = (store.data.settings['budget'] as num? ?? 0).toInt();
    final monthSpend = store.total(
      TxType.expense,
      range: DateRange.forPeriod(Period.month, DateTime.now()),
    );
    return LayoutBuilder(
      builder: (context, viewport) {
        // extendBody supplies the floating navigation height and system inset.
        final footer = MediaQuery.paddingOf(context).bottom;
        final usableHeight = viewport.maxHeight - footer;
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        final mobile = MediaQuery.sizeOf(context).width < 900;
        final compact =
            mobile &&
            (usableHeight < 700 || textScale > 1.15 || pendingPayments > 0);
        final minimal = mobile && (usableHeight < 560 || textScale >= 1.6);
        final essential =
            mobile &&
            (usableHeight < 480 || (usableHeight < 560 && textScale > 1.4));
        final showMonthly =
            !minimal &&
            (!mobile ||
                usableHeight >=
                    (pendingPayments > 0
                        ? 780
                        : compact
                        ? 650
                        : 700));
        final deferPending = minimal && pendingPayments > 0;
        final verticalActions =
            textScale <= 1.6 &&
            (textScale > 1.4 || (viewport.maxWidth - 52) / 2 < 145);
        final monthlyTiles = <Widget>[
          _Summary(
            '本月收入',
            store.total(
              TxType.income,
              range: DateRange.forPeriod(Period.month, DateTime.now()),
            ),
            colors.income,
            panel: false,
          ),
          _Summary('本月支出', monthSpend, colors.expense, panel: false),
        ];
        final spendingDetails = Row(
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
                child: AnimatedSwitcher(
                  duration: motionDuration(context, 240),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.centerLeft,
                    children: [...previous, ?current],
                  ),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, .35),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: Column(
                    key: ValueKey(spendingPeriod),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              '${spendingPeriod == Period.day
                                  ? '今日'
                                  : spendingPeriod == Period.week
                                  ? '本周'
                                  : '本月'}支出',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.unfold_more_rounded,
                            size: 14,
                            color: colors.secondary,
                          ),
                        ],
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
            ),
            TextButton.icon(
              onPressed: () => openPage(context, const AccountsPage()),
              style: TextButton.styleFrom(
                foregroundColor: colors.ink,
                backgroundColor: colors.inset,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 11,
                ),
              ),
              icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
              label: const Text('管理资产'),
            ),
          ],
        );
        final pendingNotice = AnimatedSize(
          duration: motionDuration(context, 260),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: pendingPayments == 0
              ? const SizedBox(width: double.infinity)
              : reveal(
                  0,
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Semantics(
                      liveRegion: true,
                      child: Panel(
                        key: const Key('home-payment-pending'),
                        padding: EdgeInsets.all(compact ? 12 : 20),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.receipt_long_rounded,
                              color: primary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    compact
                                        ? '$pendingPayments 笔待确认支付'
                                        : '$pendingPayments 笔支付记录待确认',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (!compact)
                                    const Text(
                                      '核对金额和实际账户后入账',
                                      style: TextStyle(
                                        color: muted,
                                        fontSize: 12,
                                      ),
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
                  ),
                ),
        );
        final privacyToggle = IconButton(
          tooltip: visible ? '隐藏金额' : '显示金额',
          onPressed: () => perform(
            context,
            () => store.change((d) => d.settings['visible'] = !visible),
          ),
          icon: Icon(
            visible ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            color: colors.secondary,
            size: 20,
          ),
        );
        final assetSelector = DecoratedBox(
          decoration: BoxDecoration(
            color: colors.inset,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedAlign(
                  duration: motionDuration(context, 260),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment(assetView - 1.0, 0),
                  child: FractionallySizedBox(
                    widthFactor: 1 / 3,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: colors.border),
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                children: List.generate(
                  3,
                  (i) => Expanded(
                    child: Semantics(
                      selected: assetView == i,
                      child: InkWell(
                        key: Key('asset-view-$i'),
                        onTap: () => setState(() => assetView = i),
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: compact ? 7 : 9,
                          ),
                          child: AnimatedDefaultTextStyle(
                            duration: motionDuration(context, 180),
                            style: Theme.of(context).textTheme.bodySmall!
                                .copyWith(
                                  fontSize: 12,
                                  fontWeight: assetView == i
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: assetView == i
                                      ? colors.ink
                                      : colors.secondary,
                                ),
                            child: Text(
                              ['净资产', '总资产', '总负债'][i],
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
        final header = reveal(
          0,
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!essential)
                      Text(
                        DateFormat(
                          'M月d日 · EEEE',
                          'zh_CN',
                        ).format(DateTime.now()),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (!essential) const SizedBox(height: 4),
                    Text(
                      '财务概览',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineSmall!
                          .copyWith(fontSize: compact ? 20 : 24),
                    ),
                  ],
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
                  backgroundColor: colors.accent,
                  child: Icon(
                    Icons.notifications_none_rounded,
                    size: 20,
                    color: colors.secondary,
                  ),
                ),
              ),
            ],
          ),
        );
        final overview = reveal(
          1,
          OverviewGrid(
            key: const Key('home-overview'),
            hero: HeroPanel(
              padding: EdgeInsets.all(
                essential
                    ? 8
                    : compact
                    ? 16
                    : 24,
              ),
              child: essential
                  ? Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () =>
                                setState(() => assetView = (assetView + 1) % 3),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        label,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall!
                                            .copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.unfold_more_rounded,
                                      size: 15,
                                      color: colors.secondary,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                SizedBox(
                                  height: 40,
                                  width: double.infinity,
                                  child: MoneyText(
                                    value,
                                    size: 34,
                                    color: colors.ink,
                                    respectPrivacy: true,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        privacyToggle,
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The selector names the figure, so it heads the card
                        // instead of repeating the label above the amount.
                        assetSelector,
                        SizedBox(height: compact ? 8 : 14),
                        Row(
                          children: [
                            Expanded(
                              child: InkWell(
                                onTap: () => setState(
                                  () => assetView = (assetView + 1) % 3,
                                ),
                                child: SizedBox(
                                  height: compact ? 48 : 56,
                                  child: MoneyText(
                                    value,
                                    size: compact ? 36 : 40,
                                    color: colors.ink,
                                    respectPrivacy: true,
                                  ),
                                ),
                              ),
                            ),
                            privacyToggle,
                          ],
                        ),
                        if (!minimal) ...[
                          const SizedBox(height: 12),
                          Divider(color: colors.ink.withValues(alpha: .08)),
                          const SizedBox(height: 8),
                          spendingDetails,
                        ],
                      ],
                    ),
            ),
            tiles: showMonthly ? monthlyTiles : const [],
          ),
        );
        final coreEntries = reveal(
          2,
          Row(
            key: const Key('home-core-actions'),
            children: [
              Expanded(
                child: _HomePrimaryAction(
                  key: const Key('home-ai-entry'),
                  text: 'AI 顾问',
                  icon: Icons.auto_awesome_outlined,
                  vertical: verticalActions,
                  compact: essential,
                  onTap: () => openPage(context, const ChatPage()),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _HomePrimaryAction(
                  key: const Key('home-voice-entry'),
                  text: '语音记账',
                  icon: Icons.mic_none_rounded,
                  vertical: verticalActions,
                  compact: essential,
                  onTap: () => showVoiceEntry(context, autoStart: true),
                ),
              ),
            ],
          ),
        );
        final content = <Widget>[
          if (store.suggestions.isNotEmpty) ...[
            const SizedBox(height: 18),
            reveal(
              3,
              Panel(
                padding: const EdgeInsets.all(16),
                color: colors.inset,
                child: Row(
                  children: [
                    Icon(Icons.lightbulb_outline_rounded, color: colors.accent),
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
                            privateFinancialText(
                              context,
                              store.suggestions.first['text'],
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '查看提醒',
                      onPressed: () => openPage(context, const RemindersPage()),
                      icon: const Icon(
                        Icons.chevron_right_rounded,
                        color: muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          reveal(
            4,
            SectionTitle(
              '快捷交易',
              action: '管理',
              onAction: () => openPage(context, const QuickEntriesPage()),
            ),
          ),
          if (store.data.quickEntries.isEmpty)
            reveal(
              4,
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
              ),
            )
          else
            reveal(
              4,
              SizedBox(
                height: 116 * MediaQuery.textScalerOf(context).scale(1),
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
                          colors.secondary,
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
                        colors.secondary,
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
            ),
          if (budget > 0) ...[
            reveal(5, const SectionTitle('本月预算')),
            reveal(
              5,
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            monthSpend > budget
                                ? '超出 ${privateMoney(context, monthSpend - budget)}'
                                : '还可支出 ${privateMoney(context, budget - monthSpend)}',
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
                      // Grows from empty on first show, then eases between values.
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(
                          begin: 0,
                          end: (monthSpend / budget).clamp(0.0, 1.0),
                        ),
                        duration: motionDuration(context, 700),
                        curve: Curves.easeOutCubic,
                        builder: (_, value, _) => LinearProgressIndicator(
                          value: value,
                          minHeight: 6,
                          color: monthSpend > budget
                              ? colors.expense
                              : colors.accent,
                          backgroundColor: colors.inset,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '预算 ${privateMoney(context, budget)} · 支出 ${privateMoney(context, monthSpend)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
          reveal(
            6,
            SectionTitle('最近交易', action: '全部账单', onAction: widget.onBills),
          ),
          if (recent.isEmpty)
            reveal(
              6,
              Panel(
                child: EmptyState(
                  '还没有账单',
                  '暂无账单，点击开始记账。',
                  action: FilledButton(
                    onPressed: () => openPage(
                      context,
                      const TransactionEditor(),
                      modal: true,
                    ),
                    child: const Text('开始记账'),
                  ),
                ),
              ),
            )
          else
            ...groupTxs(recent).entries.map(
              (g) => reveal(
                6,
                Padding(
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
                                (t) => _FreshRow(
                                  key: ValueKey(t.id),
                                  fresh: fresh.contains(t.id),
                                  child: TransactionRow(
                                    t,
                                    neutralIcon: true,
                                    onTap: () => transactionActions(context, t),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (recent.isNotEmpty)
            TextButton(
              onPressed: widget.onBills,
              child: const Text('查看全部账单 →'),
            ),
          const SizedBox(height: 72),
        ];
        return CustomScrollView(
          key: const PageStorageKey('home-scroll'),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                20,
                essential
                    ? 10
                    : compact
                    ? 16
                    : 20,
                20,
                0,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  children: [
                    header,
                    SizedBox(
                      height: essential
                          ? 10
                          : compact
                          ? 14
                          : 22,
                    ),
                    if (!deferPending) pendingNotice,
                    overview,
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  key: const Key('home-actions'),
                  children: [
                    reveal(
                      2,
                      Row(
                        key: const Key('home-manual-actions'),
                        children: [
                          Expanded(
                            child: _HomeSecondaryAction(
                              text: '记一笔',
                              icon: Icons.add_rounded,
                              iconless: essential,
                              onTap: () => openPage(
                                context,
                                const TransactionEditor(),
                                modal: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _HomeSecondaryAction(
                              text: '转账',
                              icon: Icons.swap_horiz_rounded,
                              iconless: essential,
                              onTap: () => openPage(
                                context,
                                const TransactionEditor(
                                  initialType: TxType.transfer,
                                ),
                                modal: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    coreEntries,
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, footer + 32),
              sliver: SliverList.list(
                children: [
                  if (deferPending) pendingNotice,
                  if (!showMonthly) ...[
                    const SizedBox(height: 16),
                    reveal(3, SummaryStrip(monthlyTiles)),
                  ],
                  if (essential) ...[
                    const SizedBox(height: 16),
                    reveal(3, Panel(child: assetSelector)),
                  ],
                  if (minimal) ...[
                    const SizedBox(height: 16),
                    reveal(3, Panel(child: spendingDetails)),
                  ],
                  ...content,
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A core entry stays in the scroll content, with a readable touch target.
class _HomePrimaryAction extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback onTap;
  final bool vertical;
  final bool compact;
  const _HomePrimaryAction({
    super.key,
    required this.text,
    required this.icon,
    required this.onTap,
    this.vertical = false,
    this.compact = false,
  });
  @override
  Widget build(BuildContext context) {
    final colors = WalletColors.of(context);
    final largeLabels = MediaQuery.textScalerOf(context).scale(1) > 1.6;
    final label = Text(
      largeLabels
          ? switch (text) {
              'AI 顾问' => 'AI\n顾问',
              '语音记账' => '语音\n记账',
              _ => text,
            }
          : text,
      maxLines: 2,
      textAlign: TextAlign.center,
      style: Theme.of(
        context,
      ).textTheme.bodyMedium!.copyWith(fontWeight: FontWeight.w600),
    );
    final symbol = Icon(icon, size: 24, color: colors.accent);
    return _PressTile(
      color: colors.panel,
      padding: EdgeInsets.all(compact ? 10 : 14),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 28),
        child: vertical
            ? Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [symbol, const SizedBox(height: 6), label],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  symbol,
                  const SizedBox(width: 8),
                  Flexible(child: label),
                ],
              ),
      ),
    );
  }
}

/// Secondary actions form the upper row of the same compact operation group.
class _HomeSecondaryAction extends StatelessWidget {
  final String text;
  final IconData icon;
  final bool iconless;
  final VoidCallback onTap;
  const _HomeSecondaryAction({
    required this.text,
    required this.icon,
    required this.onTap,
    this.iconless = false,
  });
  @override
  Widget build(BuildContext context) {
    final colors = WalletColors.of(context);
    // A borderless tonal fill keeps these quieter than the outlined pair below.
    return _PressTile(
      color: colors.inset,
      bordered: false,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!iconless) ...[
              Icon(icon, size: 20, color: colors.secondary),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                text,
                maxLines: 2,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickTile extends StatelessWidget {
  final String title;
  final int? amount;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _QuickTile(this.title, this.amount, this.icon, this.color, this.onTap);
  @override
  Widget build(BuildContext context) => _PressTile(
    color: WalletColors.of(context).panel,
    padding: const EdgeInsets.all(10),
    onTap: onTap,
    child: Column(
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: WalletColors.of(context).inset,
            borderRadius: BorderRadius.circular(12),
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
          amount == null
              ? '自定金额'
              : privateMoney(context, amount!, symbol: false),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}

/// A rounded home tile that dips slightly while pressed. The scale only
/// animates during a touch, so idle tiles cost nothing.
class _PressTile extends StatefulWidget {
  final Color color;
  final EdgeInsetsGeometry padding;
  final VoidCallback onTap;
  final Widget child;
  final bool bordered;
  const _PressTile({
    required this.color,
    required this.padding,
    required this.onTap,
    required this.child,
    this.bordered = true,
  });
  @override
  State<_PressTile> createState() => _PressTileState();
}

class _PressTileState extends State<_PressTile> {
  bool pressed = false;
  @override
  Widget build(BuildContext context) => AnimatedScale(
    scale: pressed ? .96 : 1,
    duration: motionDuration(context, 120),
    curve: Curves.easeOut,
    child: Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          color: widget.color,
          borderRadius: BorderRadius.circular(16),
          border: widget.bordered
              ? Border.all(color: WalletColors.of(context).border)
              : null,
        ),
        child: InkWell(
          onTap: widget.onTap,
          onHighlightChanged: (value) => setState(() => pressed = value),
          borderRadius: BorderRadius.circular(16),
          child: Padding(padding: widget.padding, child: widget.child),
        ),
      ),
    ),
  );
}

/// Briefly tints a bill that just appeared. The tint waits until this page is
/// the visible route again, so a bill saved from the voice sheet or editor is
/// pointed out after the sheet closes rather than behind it.
class _FreshRow extends StatefulWidget {
  final bool fresh;
  final Widget child;
  const _FreshRow({super.key, required this.fresh, required this.child});
  @override
  State<_FreshRow> createState() => _FreshRowState();
}

class _FreshRowState extends State<_FreshRow>
    with SingleTickerProviderStateMixin {
  AnimationController? highlight;
  late bool waiting = widget.fresh;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!waiting || ModalRoute.isCurrentOf(context) == false) return;
    waiting = false;
    if (MediaQuery.disableAnimationsOf(context)) return;
    highlight = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..forward();
  }

  @override
  void dispose() {
    highlight?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animation = highlight;
    if (animation == null) return widget.child;
    return AnimatedBuilder(
      animation: animation,
      child: widget.child,
      builder: (_, child) => DecoratedBox(
        decoration: BoxDecoration(
          color: primary.withValues(
            alpha: .16 * (1 - Curves.easeInCubic.transform(animation.value)),
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: child,
      ),
    );
  }
}

class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(
      context,
      domains: const {WalletDomain.ledger, WalletDomain.preferences},
    );
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
              AppScope.storeOf(
                context,
                domains: const {WalletDomain.ledger, WalletDomain.preferences},
              ).balance(a),
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
    final store = AppScope.storeOf(
          context,
          domains: const {WalletDomain.ledger, WalletDomain.preferences},
        ),
        a = AppScope.storeOf(
          context,
          domains: const {WalletDomain.ledger, WalletDomain.preferences},
        ).account(id);
    if (a == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('账户')),
        body: const EmptyState('账户不存在', '该账户可能已被删除。'),
      );
    }
    final txs = store.query(accountId: id), balance = store.balance(a);
    final entries = <Object>[
      for (final group in groupTxs(txs).entries) ...[group.key, ...group.value],
    ];
    final credit = a.category == 'credit';
    DateRange? cycle;
    if (credit && a.billingDay != null) {
      final now = DateTime.now();
      cycle = creditBillingCycle(
        a.billingDay!,
        a.countBillingDayInPrevious,
        now,
      );
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
      body: LazyPageList(
        leading: [
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
                        '本期 ${DateFormat('M/d').format(cycle.start)}–${DateFormat('M/d').format(cycle.end.subtract(const Duration(days: 1)))} · 消费 ${privateMoney(context, store.total(TxType.expense, transactions: txs.where((t) => cycle!.contains(t.date)).toList()))}',
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
          if (txs.isEmpty) const EmptyState('还没有流水', '与此账户关联的账单会显示在这里。'),
        ],
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          if (entry is String) {
            return Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : 16, bottom: 8),
              child: Text(
                dateHeading(DateTime.parse(entry)),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            );
          }
          final transaction = entry as LedgerTx;
          final first = index == 0 || entries[index - 1] is String;
          final last =
              index + 1 == entries.length || entries[index + 1] is String;
          return Container(
            key: ValueKey(transaction.id),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: WalletColors.of(context).surface,
              borderRadius: BorderRadius.vertical(
                top: first ? const Radius.circular(24) : Radius.zero,
                bottom: last ? const Radius.circular(24) : Radius.zero,
              ),
            ),
            child: TransactionRow(
              transaction,
              onTap: () => transactionActions(context, transaction),
            ),
          );
        },
        trailing: [
          const SizedBox(height: 16),
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
    final store = AppScope.storeOf(
          context,
          domains: const {WalletDomain.ledger, WalletDomain.preferences},
        ),
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
                  final date = await pickPeriodAnchor(context, period, anchor);
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
              child: Text(switch (period) {
                Period.day => '今天',
                Period.week => '本周',
                Period.month => '本月',
                Period.year => '今年',
              }),
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
                      () => anchor = DateRange.shift(
                        period,
                        anchor,
                        (d.primaryVelocity ?? 0) < 0 ? 1 : -1,
                      ),
                    );
                  }
                },
                child: RingChart(
                  segments: segments,
                  onSegmentTap: (index) => openPage(
                    context,
                    FilteredBillsPage(
                      range: range,
                      type: type,
                      category: grouped.keys.elementAt(index),
                    ),
                  ),
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
                '结余 ${privateMoney(context, store.total(TxType.income, range: range) - store.total(TxType.expense, range: range))} · 转账不计入收支',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SectionTitle('收支趋势'),
        Panel(
          child: TrendChart(
            values: values,
            labels: labels,
            pointLabels: [
              for (var i = 0; i < values.length; i++)
                period == Period.day
                    ? '${i.toString().padLeft(2, '0')}:00'
                    : period == Period.year
                    ? '${i + 1}月'
                    : dayKey(range.start.add(Duration(days: i))),
            ],
          ),
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

  /// False when a [SummaryStrip] or [OverviewGrid] supplies the surface.
  final bool panel;
  const _Summary(this.title, this.value, this.color, {this.panel = true});
  @override
  Widget build(BuildContext context) {
    final figure = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
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
            Flexible(
              child: Text(title, style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
        ),
        const SizedBox(height: 10),
        MoneyText(value, size: 23),
      ],
    );
    if (!panel) return figure;
    return Panel(
      padding: const EdgeInsets.all(16),
      color: WalletColors.of(context).panel,
      child: figure,
    );
  }
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
  State<BillsPage> createState() => BillsPageState();
}

class BillsPageState extends State<BillsPage> {
  final search = TextEditingController();
  Timer? _searchTimer;
  String _query = '';
  DateRange? range;
  TxType? type;
  String? category, accountId;
  String dateLabel = '全部日期';
  Set<String>? selected;
  bool exitSelection() {
    if (selected == null) return false;
    setState(() => selected = null);
    return true;
  }

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
    _searchTimer?.cancel();
    search.dispose();
    super.dispose();
  }

  void searchChanged(String value) {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || _query == value) return;
      setState(() {
        _query = value;
        selected = null;
      });
    });
  }

  Future<void> filters() async {
    final store = AppScope.storeOf(
      context,
      domains: const {WalletDomain.ledger, WalletDomain.preferences},
    );
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
                WalletSelectField<String>(
                  key: ValueKey(newAccount),
                  initialValue: newAccount,
                  nullLabel: '全部账户',
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
                if (newType != TxType.transfer)
                  WalletSelectField<String>(
                    key: ValueKey('$newType-$newCategory'),
                    initialValue: newCategory,
                    nullLabel: '全部分类',
                    decoration: const InputDecoration(labelText: '分类'),
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem(value: '', child: Text('全部分类')),
                      ...store.data.categories
                          .where((c) => newType == null || c.type == newType)
                          .map((c) => c.name)
                          .toSet()
                          .map(
                            (name) => DropdownMenuItem(
                              value: name,
                              child: Text(name),
                            ),
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

    final store = AppScope.storeOf(
      context,
      domains: const {WalletDomain.ledger, WalletDomain.preferences},
    );
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
    final store = AppScope.storeOf(
      context,
      domains: const {WalletDomain.ledger, WalletDomain.preferences},
    );
    final list = store.query(
      range: range,
      type: type,
      category: category,
      accountId: accountId,
      search: _query,
    );
    final groups = groupTxs(list);
    // Flatten day headers and records so even one large day remains lazy.
    final entries = <(String, LedgerTx?)>[
      for (final group in groups.entries) ...[
        (group.key, null),
        for (final tx in group.value) (group.key, tx),
      ],
    ];
    final dailyExpenses = {
      for (final group in groups.entries)
        group.key: store.total(TxType.expense, transactions: group.value),
    };
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
                  tooltip: '选择账单',
                  onPressed: list.isEmpty
                      ? null
                      : () => setState(() => selected = {}),
                  icon: const Icon(Icons.checklist_rounded),
                ),
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
            onChanged: searchChanged,
            decoration: InputDecoration(
              hintText: '搜索名称、备注、分类或账户',
              prefixIcon: const Icon(Icons.search_rounded, color: muted),
              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                valueListenable: search,
                builder: (context, value, _) => value.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        tooltip: '清除搜索',
                        onPressed: () {
                          _searchTimer?.cancel();
                          search.clear();
                          setState(() {
                            _query = '';
                            selected = null;
                          });
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
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
              ? SingleChildScrollView(
                  child: EmptyState(
                    '没有符合条件的账单',
                    '调整筛选条件，或者记下新的一笔。',
                    action: TextButton(
                      onPressed: filters,
                      child: const Text('调整筛选'),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    10,
                    20,
                    MediaQuery.paddingOf(context).bottom + 30,
                  ),
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final (day, transaction) = entries[i];
                    if (transaction == null) {
                      return Padding(
                        padding: EdgeInsets.only(
                          top: i == 0 ? 0 : 20,
                          bottom: 9,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                dateHeading(DateTime.parse(day)),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            Text(
                              '支出 ${privateMoney(context, dailyExpenses[day]!)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      );
                    }
                    final first = i == 0 || entries[i - 1].$2 == null;
                    final last =
                        i + 1 == entries.length || entries[i + 1].$2 == null;
                    final colors = WalletColors.of(context);
                    return Container(
                      key: ValueKey(transaction.id),
                      padding: EdgeInsets.fromLTRB(
                        12,
                        first ? 2 : 0,
                        12,
                        last ? 2 : 0,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.vertical(
                          top: first ? const Radius.circular(24) : Radius.zero,
                          bottom: last
                              ? const Radius.circular(24)
                              : Radius.zero,
                        ),
                      ),
                      child: TransactionRow(
                        transaction,
                        selected: active
                            ? selected!.contains(transaction.id)
                            : null,
                        onLongPress: () {
                          HapticFeedback.mediumImpact();
                          setState(() => selected = {transaction.id});
                        },
                        onTap: () {
                          if (active) {
                            setState(
                              () => selected!.contains(transaction.id)
                                  ? selected!.remove(transaction.id)
                                  : selected!.add(transaction.id),
                            );
                          } else {
                            transactionActions(context, transaction);
                          }
                        },
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
