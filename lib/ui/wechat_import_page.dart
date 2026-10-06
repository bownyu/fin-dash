import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../domain/models.dart';
import '../services/wechat_bill_import.dart';
import 'design.dart';
import 'interaction.dart';
import 'editors.dart';

class WechatImportPage extends StatefulWidget {
  final WechatBill? initialBill;
  final String initialName;
  const WechatImportPage({
    super.key,
    this.initialBill,
    this.initialName = '微信账单.xlsx',
  });
  @override
  State<WechatImportPage> createState() => _WechatImportPageState();
}

class _WechatImportPageState extends State<WechatImportPage> {
  WechatBill? bill;
  String name = '', error = '';
  bool busy = false, preserveBalances = true, initialized = false;
  final mapping = <String, String>{};
  final selected = <String>{}, similar = <String>{};
  WechatBillImporter? _importer;
  WechatBillImporter get importer =>
      _importer ??= WechatBillImporter(AppScope.storeOf(context));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!initialized) {
      initialized = true;
      if (widget.initialBill != null) {
        setPreview(widget.initialBill!, widget.initialName);
      }
    }
    if (bill != null) {
      for (final entry in importer.suggestedAccounts(bill!).entries) {
        mapping.putIfAbsent(entry.key, () => entry.value);
      }
    }
  }

  void setPreview(WechatBill value, String filename) {
    bill = value;
    name = filename;
    mapping.clear();
    mapping.addAll(importer.suggestedAccounts(value));
    similar.clear();
    similar.addAll(importer.similar(value));
    final duplicates = importer.duplicates(value);
    selected.clear();
    selected.addAll(
      value.records
          .where((r) => !duplicates.contains(r.id) && !similar.contains(r.id))
          .map((r) => r.id),
    );
    error = '';
  }

  Future<void> pick() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        withData: true,
      );
      if (result == null) return;
      final file = result.files.single;
      if (file.bytes == null) throw const FormatException('文件无法读取，请重新选择');
      final parsed = await compute(WechatBill.parse, file.bytes!);
      if (mounted) setState(() => setPreview(parsed, file.name));
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException ? e.message : '读取账单失败，请重新选择',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (busy || bill == null) return;
    final service = importer;
    final duplicates = service.duplicates(bill!);
    final rows = bill!.records
        .where((r) => selected.contains(r.id) && !duplicates.contains(r.id))
        .toList();
    final accounts = AppScope.storeOf(context).activeAccounts;
    final names = {for (final a in accounts) a.id: a.name};
    final details = <String, int>{};
    for (final row in rows) {
      final account = mapping[row.payment];
      if (!names.containsKey(account)) {
        setState(() => error = '请为“${row.payment}”选择账户');
        return;
      }
      details[account!] =
          (details[account] ?? 0) +
          (row.type == TxType.income ? row.amount : -row.amount);
    }
    if (rows.isEmpty) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('导入 ${rows.length} 笔微信账单？'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '收入 ${privateMoney(context, rows.where((r) => r.type == TxType.income).fold(0, (s, r) => s + r.amount))}\n'
                '支出 ${privateMoney(context, rows.where((r) => r.type == TxType.expense).fold(0, (s, r) => s + r.amount))}',
              ),
              const SizedBox(height: 12),
              for (final entry in details.entries)
                Text(
                  preserveBalances
                      ? '${names[entry.key]}：保持当前余额'
                      : '${names[entry.key]}：余额变化 ${privateMoney(context, entry.value)}',
                ),
              const SizedBox(height: 12),
              Text(
                preserveBalances
                    ? '作为历史账单追加，自动调整期初余额以保持当前余额。'
                    : '追加账单并按收支改变所选账户余额。',
              ),
              const Text('现有账单保留。退款按微信收入流水保存，归入退款分类。'),
              if (rows.any((r) => similar.contains(r.id)))
                const Text(
                  '本次包含你重新勾选的可能重复记录，请确认。',
                  style: TextStyle(color: coral),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('wechat-approve'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确认导入'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await service.import(
        bill!,
        selectedIds: rows.map((r) => r.id).toSet(),
        accountMapping: Map.of(mapping),
        preserveBalances: preserveBalances,
        reviewedSimilarIds: similar.intersection(selected),
      );
      if (mounted) {
        toast(
          context,
          '已导入 ${result.imported} 笔账单${result.duplicates > 0 ? '，跳过 ${result.duplicates} 笔重复' : ''}',
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e is FormatException ? e.message : '导入未保存，请重试';
          final latest = service.similar(bill!);
          selected.removeAll(latest.difference(similar));
          similar.addAll(latest);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    final duplicateIds = bill == null ? <String>{} : importer.duplicates(bill!);
    final rows = bill?.records ?? <WechatBillRecord>[];
    final chosen = rows
        .where((r) => selected.contains(r.id) && !duplicateIds.contains(r.id))
        .toList();
    final validAccounts = store.activeAccounts.map((a) => a.id).toSet();
    final ready =
        chosen.isNotEmpty &&
        chosen.every((r) => validAccounts.contains(mapping[r.payment]));
    return EditorGuard(
      busy: busy,
      hasChanges: () => bill != null,
      child: Scaffold(
        appBar: AppBar(title: const Text('导入微信账单')),
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '选择微信导出的 Excel 账单，在本机读取、核对后追加到账本。',
                      style: TextStyle(color: muted),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: busy ? null : pick,
                      icon: const Icon(Icons.upload_file),
                      label: Text(bill == null ? '选择微信账单 .xlsx' : '重新选择账单'),
                    ),
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: LinearProgressIndicator(),
                      ),
                    if (bill != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '识别 ${rows.length} 笔 · 收入 ${privateMoney(context, bill!.total(TxType.income))} · 支出 ${privateMoney(context, bill!.total(TxType.expense))}',
                      ),
                      Text(
                        '已导入 ${duplicateIds.length} 笔 · 可能重复 ${similar.length} 笔 · 跳过 ${bill!.issues.length} 行',
                        style: const TextStyle(color: muted, fontSize: 12),
                      ),
                      if (rows.any((r) => r.refund))
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            '原消费与退款分别保留；退款记为退款分类收入。已退款的原消费仍按原金额记录。',
                            style: TextStyle(color: muted, fontSize: 12),
                          ),
                        ),
                      const SectionTitle('支付方式对应账户'),
                      for (final entry in bill!.payments.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: WalletSelectField<String>(
                                  key: ValueKey(
                                    'wechat-account:${entry.key}:${mapping[entry.key]}',
                                  ),
                                  initialValue:
                                      validAccounts.contains(mapping[entry.key])
                                      ? mapping[entry.key]
                                      : null,
                                  isExpanded: true,
                                  decoration: InputDecoration(
                                    labelText:
                                        '${entry.key} · ${entry.value} 笔',
                                    hintText: '选择记账账户',
                                  ),
                                  items: store.activeAccounts
                                      .map(
                                        (a) => DropdownMenuItem(
                                          value: a.id,
                                          child: Text(a.name),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: busy
                                      ? null
                                      : (value) => setState(() {
                                          if (value != null) {
                                            mapping[entry.key] = value;
                                          }
                                        }),
                                ),
                              ),
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => setState(
                                        () => selected.removeAll(
                                          rows
                                              .where(
                                                (r) => r.payment == entry.key,
                                              )
                                              .map((r) => r.id),
                                        ),
                                      ),
                                child: const Text('跳过这组'),
                              ),
                            ],
                          ),
                        ),
                      TextButton.icon(
                        onPressed: busy
                            ? null
                            : () => openPage(context, const AccountEditor()),
                        icon: const Icon(Icons.add),
                        label: const Text('添加记账账户'),
                      ),
                      SwitchListTile(
                        key: const Key('wechat-preserve-balances'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('保持当前账户余额'),
                        subtitle: const Text('导入历史账单时调整期初余额，避免再次扣款'),
                        value: preserveBalances,
                        onChanged: busy
                            ? null
                            : (v) => setState(() => preserveBalances = v),
                      ),
                      if (bill!.issues.isNotEmpty)
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: Text('查看跳过的 ${bill!.issues.length} 行'),
                          children: [
                            for (final issue in bill!.issues.take(100))
                              ListTile(
                                dense: true,
                                title: Text('第 ${issue.row} 行：${issue.reason}'),
                              ),
                            if (bill!.issues.length > 100)
                              const Text('其余跳过记录请核对原文件。'),
                          ],
                        ),
                      const SectionTitle('核对明细'),
                      const Text(
                        '未确认分类的账单先归入“其他”，导入后可修改。可能重复的记录默认不选中。',
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                    ],
                    if (error.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error,
                          style: const TextStyle(color: coral),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final row = rows[index];
                final duplicate = duplicateIds.contains(row.id);
                return CheckboxListTile(
                  key: ValueKey('wechat-row:${row.id}'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  value: !duplicate && selected.contains(row.id),
                  onChanged: busy || duplicate
                      ? null
                      : (v) => setState(() {
                          if (v == true) {
                            selected.add(row.id);
                          } else {
                            selected.remove(row.id);
                          }
                        }),
                  title: Text(
                    '${row.type.label} ${privateMoney(context, row.amount)} · ${row.title}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${dayKey(row.date)} ${row.date.hour.toString().padLeft(2, '0')}:${row.date.minute.toString().padLeft(2, '0')} · ${row.payment}\n'
                    '${duplicate
                        ? '已导入 · 自动跳过'
                        : similar.contains(row.id)
                        ? '可能重复 · 请核对后勾选'
                        : row.refund
                        ? '退款收入 · ${row.status}'
                        : row.status}',
                  ),
                );
              }, childCount: rows.length),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
        bottomNavigationBar: bill == null
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: FilledButton(
                    key: const Key('wechat-import'),
                    onPressed: busy || !ready ? null : save,
                    child: Text(
                      ready
                          ? '核对并导入 ${chosen.length} 笔'
                          : chosen.isEmpty
                          ? '没有选中的新账单'
                          : '请先选择账户',
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
