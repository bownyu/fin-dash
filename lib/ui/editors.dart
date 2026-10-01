import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../domain/models.dart';
import 'design.dart';

class TransactionEditor extends StatefulWidget {
  final LedgerTx? initial;
  final QuickEntry? quick;
  final bool saveAsQuick;
  final TxType initialType;
  final String? initialAccount;
  const TransactionEditor({
    super.key,
    this.initial,
    this.quick,
    this.saveAsQuick = false,
    this.initialType = TxType.expense,
    this.initialAccount,
  });
  @override
  State<TransactionEditor> createState() => _TransactionEditorState();
}

class _TransactionEditorState extends State<TransactionEditor> {
  final amount = TextEditingController(),
      title = TextEditingController(),
      note = TextEditingController();
  final form = GlobalKey<FormState>();
  late TxType type;
  String? category, accountId, fromId, toId;
  DateTime date = DateTime.now();
  bool initialized = false, saving = false, changedDate = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (initialized) return;
    initialized = true;
    final store = AppScope.storeOf(context);
    final tx = widget.initial, q = widget.quick;
    type = tx?.type ?? q?.type ?? widget.initialType;
    category =
        tx?.category ??
        q?.category ??
        store.data.categories.where((c) => c.type == type).firstOrNull?.name;
    final cents = tx?.amount ?? q?.amount;
    if (cents != null) amount.text = moneyInput(cents);
    title.text = tx?.title ?? q?.title ?? '';
    note.text = tx?.note ?? '';
    date = tx?.date ?? DateTime.now();
    final ids = store.activeAccounts.map((a) => a.id).toList();
    String? valid(String? id) => ids.contains(id) ? id : null;
    accountId =
        valid(tx?.accountId ?? q?.accountId ?? widget.initialAccount) ??
        (widget.saveAsQuick || tx != null || q != null
            ? null
            : ids.firstOrNull);
    fromId =
        valid(tx?.fromId ?? q?.fromId) ??
        (widget.saveAsQuick || tx != null || q != null
            ? null
            : ids.firstOrNull);
    toId =
        valid(
          tx?.toId ??
              q?.toId ??
              (type == TxType.transfer ? widget.initialAccount : null),
        ) ??
        (widget.saveAsQuick || tx != null || q != null
            ? null
            : ids.where((id) => id != fromId).firstOrNull);
  }

  @override
  void dispose() {
    amount.dispose();
    title.dispose();
    note.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving || !form.currentState!.validate()) return;
    final store = AppScope.storeOf(context);
    int? cents;
    try {
      if (amount.text.isNotEmpty) cents = parseMoney(amount.text);
    } catch (e) {
      toast(context, (e as FormatException).message.toString());
      return;
    }
    if (!widget.saveAsQuick && (cents == null || cents <= 0)) {
      toast(context, '请输入大于 0 的金额');
      return;
    }
    if (cents != null && cents <= 0) {
      toast(context, '金额必须大于 0，也可以留空');
      return;
    }
    if (!widget.saveAsQuick && store.activeAccounts.isEmpty) {
      toast(context, '请先在资产管理中添加账户');
      return;
    }
    if (type == TxType.transfer && fromId != null && fromId == toId) {
      toast(context, '转出与转入账户不能相同');
      return;
    }
    setState(() => saving = true);
    final cat = store.data.categories
        .where((c) => c.name == category && c.type == type)
        .firstOrNull;
    final name = title.text.trim().isEmpty
        ? type == TxType.transfer
              ? '账户转账'
              : category ?? type.label
        : title.text.trim();
    final success = await perform(context, () async {
      if (widget.saveAsQuick) {
        await store.saveQuick(
          QuickEntry(
            id: widget.quick?.id ?? newId(),
            title: name,
            type: type,
            category: type == TxType.transfer ? '转账' : category ?? '其他',
            icon: type == TxType.transfer
                ? 'swap_horiz'
                : cat?.icon ?? 'receipt_long',
            amount: cents,
            accountId: type == TxType.transfer ? null : accountId,
            fromId: type == TxType.transfer ? fromId : null,
            toId: type == TxType.transfer ? toId : null,
          ),
        );
      } else {
        await store.saveTx(
          LedgerTx(
            id: widget.initial?.id ?? newId(),
            title: name,
            amount: cents!,
            date: changedDate || widget.initial != null ? date : DateTime.now(),
            type: type,
            category: type == TxType.transfer ? '转账' : category ?? '其他',
            icon: type == TxType.transfer
                ? 'swap_horiz'
                : cat?.icon ?? 'receipt_long',
            note: note.text.trim(),
            accountId: type == TxType.transfer ? null : accountId,
            fromId: type == TxType.transfer ? fromId : null,
            toId: type == TxType.transfer ? toId : null,
          ),
        );
      }
    });
    if (!mounted) return;
    if (success) {
      Navigator.pop(context, true);
      toast(context, widget.saveAsQuick ? '快捷交易已保存' : '账单已保存');
    } else {
      setState(() => saving = false);
    }
  }

  Widget accountField(
    String label,
    String? value,
    ValueChanged<String?> onChange,
  ) {
    final accounts = AppScope.storeOf(context).activeAccounts;
    return DropdownButtonFormField<String>(
      initialValue: accounts.any((a) => a.id == value) ? value : null,
      key: ValueKey('$label-$value'),
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        if (widget.saveAsQuick)
          const DropdownMenuItem(value: '', child: Text('记账时选择')),
        ...accounts.map(
          (a) => DropdownMenuItem(
            value: a.id,
            child: Row(
              children: [
                Icon(iconOf(a.icon), size: 18, color: colorOf(a.color)),
                const SizedBox(width: 10),
                Expanded(child: Text(a.name, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
        ),
      ],
      onChanged: saving
          ? null
          : (value) => setState(() => onChange(value == '' ? null : value)),
    );
  }

  void key(String text) {
    var value = amount.text;
    if (text == '⌫') {
      if (value.isNotEmpty) value = value.substring(0, value.length - 1);
    } else if (text == '.') {
      if (!value.contains('.')) value = '${value.isEmpty ? '0' : value}.';
    } else if (value.length < 13 &&
        (!value.contains('.') || value.split('.').last.length < 2)) {
      value = value == '0' ? text : '$value$text';
    }
    amount.text = value;
    amount.selection = TextSelection.collapsed(offset: value.length);
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    final categories = store.data.categories
        .where((c) => c.type == type)
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.saveAsQuick
              ? widget.quick == null
                    ? '添加快捷交易'
                    : '编辑快捷交易'
              : widget.initial == null
              ? '记一笔'
              : '编辑账单',
        ),
        leading: IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close_rounded),
          onPressed: saving ? null : () => Navigator.pop(context),
        ),
      ),
      body: Form(
        key: form,
        child: PageList(
          children: [
            SegmentedButton<TxType>(
              segments: TxType.values
                  .map((t) => ButtonSegment(value: t, label: Text(t.label)))
                  .toList(),
              selected: {type},
              onSelectionChanged: saving
                  ? null
                  : (v) => setState(() {
                      type = v.first;
                      category = store.data.categories
                          .where((c) => c.type == type)
                          .firstOrNull
                          ?.name;
                    }),
            ),
            const SizedBox(height: 20),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.saveAsQuick ? '预设金额 · 可选' : '${type.label}金额',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: const Key('amount-input'),
                    controller: amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w700,
                      color: txColor(type),
                    ),
                    decoration: const InputDecoration(
                      prefixText: '¥ ',
                      hintText: '0.00',
                      filled: false,
                      contentPadding: EdgeInsets.zero,
                    ),
                    validator: (v) =>
                        v!.isEmpty && !widget.saveAsQuick ? '请输入金额' : null,
                  ),
                  if (widget.saveAsQuick)
                    const Text(
                      '留空时，每次使用快捷交易都可以输入金额',
                      style: TextStyle(color: muted, fontSize: 12),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: title,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: '名称 / 商户',
                hintText: '如：午餐、月薪',
              ),
            ),
            if (type != TxType.transfer) ...[
              const SizedBox(height: 8),
              Text('选择分类', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, box) => Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: categories
                      .map(
                        (c) => SizedBox(
                          width: (box.maxWidth - 24) / 4,
                          child: Material(
                            color: category == c.name
                                ? colorOf(c.color).withValues(alpha: .16)
                                : Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () => setState(() => category = c.name),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                child: Column(
                                  children: [
                                    Icon(
                                      iconOf(c.icon),
                                      color: category == c.name
                                          ? colorOf(c.color)
                                          : muted,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      c.name,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: category == c.name
                                            ? colorOf(c.color)
                                            : null,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 20),
              accountField('使用账户', accountId, (v) => accountId = v),
            ] else ...[
              const SizedBox(height: 8),
              accountField('转出账户', fromId, (v) => fromId = v),
              const SizedBox(height: 14),
              accountField('转入账户', toId, (v) => toId = v),
              const SizedBox(height: 12),
              const Text(
                '账户之间的转账不计入收入或支出。还信用卡也可使用转账。',
                style: TextStyle(fontSize: 12, color: muted),
              ),
            ],
            if (!widget.saveAsQuick) ...[
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.calendar_month_rounded, size: 18),
                      label: Text(DateFormat('yyyy/MM/dd').format(date)),
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: date,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setState(() {
                            changedDate = true;
                            date = DateTime(
                              picked.year,
                              picked.month,
                              picked.day,
                              date.hour,
                              date.minute,
                              date.second,
                            );
                          });
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.fromDateTime(date),
                      );
                      if (picked != null) {
                        setState(() {
                          changedDate = true;
                          date = DateTime(
                            date.year,
                            date.month,
                            date.day,
                            picked.hour,
                            picked.minute,
                          );
                        });
                      }
                    },
                    child: Text(DateFormat('HH:mm').format(date)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: note,
                maxLines: 2,
                maxLength: 300,
                decoration: const InputDecoration(labelText: '备注（可选）'),
              ),
            ],
            if (MediaQuery.viewInsetsOf(context).bottom == 0)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: GridView.count(
                  crossAxisCount: 3,
                  childAspectRatio: 2.8,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  children:
                      [
                            '1',
                            '2',
                            '3',
                            '4',
                            '5',
                            '6',
                            '7',
                            '8',
                            '9',
                            '.',
                            '0',
                            '⌫',
                          ]
                          .map(
                            (s) => TextButton(
                              onPressed: saving ? null : () => key(s),
                              style: TextButton.styleFrom(
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.surface,
                              ),
                              child: Text(
                                s,
                                style: const TextStyle(fontSize: 22),
                              ),
                            ),
                          )
                          .toList(),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('save-transaction'),
              onPressed: saving ? null : save,
              icon: saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded),
              label: Text(widget.saveAsQuick ? '保存快捷交易' : '保存账单'),
            ),
          ],
        ),
      ),
    );
  }
}

class AccountEditor extends StatefulWidget {
  final WalletAccount? initial;
  const AccountEditor({super.key, this.initial});
  @override
  State<AccountEditor> createState() => _AccountEditorState();
}

class _AccountEditorState extends State<AccountEditor> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController(),
      balance = TextEditingController(),
      limit = TextEditingController(),
      note = TextEditingController();
  String group = 'funds',
      subType = 'cash',
      icon = 'payments',
      color = '#58C5AB';
  int? billingDay, repaymentDay;
  bool include = true,
      billingPrevious = false,
      initialized = false,
      saving = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (initialized) return;
    initialized = true;
    final a = widget.initial;
    if (a != null) {
      group = a.category;
      subType = a.subType;
      icon = a.icon;
      color = a.color;
      name.text = a.name;
      balance.text = moneyInput(AppScope.storeOf(context).balance(a));
      limit.text = moneyInput(a.creditLimit);
      note.text = a.note;
      billingDay = a.billingDay;
      repaymentDay = a.repaymentDay;
      include = a.includeInTotal;
      billingPrevious = a.countBillingDayInPrevious;
    } else {
      name.text = '现金';
      balance.text = '0.00';
      limit.text = '0.00';
    }
  }

  @override
  void dispose() {
    name.dispose();
    balance.dispose();
    limit.dispose();
    note.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving || !form.currentState!.validate()) return;
    int current, creditLimit;
    try {
      current = parseMoney(balance.text, signed: true);
      creditLimit = parseMoney(limit.text.isEmpty ? '0' : limit.text);
    } on FormatException catch (e) {
      toast(context, e.message);
      return;
    }
    setState(() => saving = true);
    final ok = await perform(
      context,
      () => AppScope.storeOf(context).saveAccount(
        WalletAccount(
          id: widget.initial?.id ?? newId(),
          name: name.text.trim(),
          category: group,
          subType: subType,
          icon: icon,
          color: color,
          note: note.text.trim(),
          includeInTotal: include,
          creditLimit: group == 'credit' ? creditLimit : 0,
          billingDay: group == 'credit' ? billingDay : null,
          repaymentDay: group == 'credit' ? repaymentDay : null,
          countBillingDayInPrevious: billingPrevious,
          archived: widget.initial?.archived ?? false,
        ),
        currentBalance: current,
      ),
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
      toast(context, '账户已保存');
    } else {
      setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.initial == null ? '添加账户' : '编辑账户')),
    body: Form(
      key: form,
      child: PageList(
        children: [
          if (widget.initial == null) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: accountGroups.entries
                  .map(
                    (g) => ChoiceChip(
                      label: Text(g.value),
                      selected: group == g.key,
                      onSelected: (_) => setState(() {
                        group = g.key;
                        final preset = accountPresets[group]!.first;
                        subType = preset.$1;
                        name.text = preset.$2;
                        icon = preset.$3;
                      }),
                    ),
                  )
                  .toList(),
            ),
            const SectionTitle('账户类型'),
            LayoutBuilder(
              builder: (context, box) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: accountPresets[group]!
                    .map(
                      (p) => SizedBox(
                        width: (box.maxWidth - 16) / 3,
                        child: Material(
                          color: subType == p.$1
                              ? primary.withValues(alpha: .15)
                              : Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => setState(() {
                              subType = p.$1;
                              icon = p.$3;
                              name.text = p.$2;
                            }),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                children: [
                                  Icon(
                                    iconOf(p.$3),
                                    color: subType == p.$1 ? primary : muted,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    p.$2,
                                    style: const TextStyle(fontSize: 12),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 24),
          ],
          TextFormField(
            key: const Key('account-name'),
            controller: name,
            maxLength: 30,
            decoration: const InputDecoration(labelText: '账户名称'),
            validator: (v) => v!.trim().isEmpty ? '请输入名称' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('account-balance'),
            controller: balance,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: InputDecoration(
              labelText: '当前余额',
              prefixText: '¥ ',
              helperText: group == 'credit' ? '欠款请输入负数，如 -200.00' : '支持负数余额',
            ),
            validator: (v) => v!.isEmpty ? '请输入余额' : null,
          ),
          if (group == 'credit') ...[
            const SizedBox(height: 18),
            TextFormField(
              controller: limit,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: '信用额度',
                prefixText: '¥ ',
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    isExpanded: true,
                    initialValue: billingDay,
                    decoration: const InputDecoration(labelText: '账单日'),
                    items: [
                      const DropdownMenuItem(value: 0, child: Text('不设置')),
                      for (var i = 1; i <= 28; i++)
                        DropdownMenuItem(value: i, child: Text('$i 日')),
                    ],
                    onChanged: (v) => billingDay = v == 0 ? null : v,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    isExpanded: true,
                    initialValue: repaymentDay,
                    decoration: const InputDecoration(labelText: '还款日'),
                    items: [
                      const DropdownMenuItem(value: 0, child: Text('不设置')),
                      for (var i = 1; i <= 28; i++)
                        DropdownMenuItem(value: i, child: Text('$i 日')),
                    ],
                    onChanged: (v) => repaymentDay = v == 0 ? null : v,
                  ),
                ),
              ],
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('账单日交易计入上一期'),
              value: billingPrevious,
              onChanged: (v) => setState(() => billingPrevious = v),
            ),
          ],
          const SectionTitle('账户颜色'),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: palette
                .map(
                  (c) => InkWell(
                    borderRadius: BorderRadius.circular(30),
                    onTap: () => setState(() => color = c),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: colorOf(c),
                        shape: BoxShape.circle,
                      ),
                      child: color == c
                          ? const Icon(
                              Icons.check_rounded,
                              color: Colors.white,
                              size: 20,
                            )
                          : null,
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 20),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('计入总资产'),
            subtitle: const Text('关闭后，该账户不会影响首页资产总额'),
            value: include,
            onChanged: (v) => setState(() => include = v),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: note,
            maxLength: 300,
            maxLines: 2,
            decoration: const InputDecoration(labelText: '备注（可选）'),
          ),
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('save-account'),
            onPressed: saving ? null : save,
            child: Text(saving ? '保存中…' : '保存账户'),
          ),
        ],
      ),
    ),
  );
}

Future<void> transactionActions(BuildContext context, LedgerTx tx) async {
  final result = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (c) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TransactionRow(tx),
          if (tx.note.isNotEmpty)
            Padding(padding: const EdgeInsets.all(12), child: Text(tx.note)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(c, 'edit'),
                  icon: const Icon(Icons.edit_rounded),
                  label: const Text('修改'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.pop(c, 'delete'),
                  icon: const Icon(Icons.delete_outline_rounded, color: coral),
                  label: const Text('删除', style: TextStyle(color: coral)),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  if (!context.mounted) return;
  if (result == 'edit') {
    await openPage(context, TransactionEditor(initial: tx), modal: true);
  } else if (result == 'delete' &&
      await confirm(
        context,
        '删除这笔账单？',
        '账户余额与统计将同步恢复。',
        action: '删除',
        destructive: true,
      )) {
    if (context.mounted) {
      await perform(
        context,
        () => AppScope.storeOf(context).deleteTxs({tx.id}),
        success: '账单已删除',
      );
    }
  }
}
