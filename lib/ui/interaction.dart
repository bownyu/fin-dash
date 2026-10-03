import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../domain/models.dart';
import 'design.dart';

/// Guards both the app-bar action and the Android back gesture.
/// Successful saves may still pop programmatically after their durable commit.
class EditorGuard extends StatefulWidget {
  final Widget child;
  final bool busy;
  final bool Function() hasChanges;
  const EditorGuard({
    super.key,
    required this.child,
    required this.hasChanges,
    this.busy = false,
  });
  static Future<void> close(BuildContext context) async {
    final guard = context.findAncestorStateOfType<_EditorGuardState>();
    if (guard != null) {
      await guard.close();
    } else {
      Navigator.pop(context);
    }
  }

  @override
  State<EditorGuard> createState() => _EditorGuardState();
}

class _EditorGuardState extends State<EditorGuard> {
  bool asking = false;
  @override
  void didUpdateWidget(covariant EditorGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.busy && !oldWidget.busy) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  Future<void> close() async {
    if (widget.busy || asking) return;
    if (!widget.hasChanges()) {
      Navigator.pop(context);
      return;
    }
    asking = true;
    final leave = await confirm(
      context,
      '保留这次编辑？',
      '内容还没有保存。继续编辑可保留已填写的内容，放弃后将丢失本次修改。',
      action: '放弃修改',
      cancelLabel: '继续编辑',
      destructive: true,
    );
    asking = false;
    if (leave && mounted && !widget.busy) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) close();
    },
    child: AbsorbPointer(absorbing: widget.busy, child: widget.child),
  );
}

class _Selection<T> {
  final T? value;
  const _Selection(this.value);
}

Future<T?> pickWalletOption<T>(
  BuildContext context, {
  required String title,
  required List<DropdownMenuItem<T>> items,
  required String Function(T) label,
  String? Function(T)? subtitle,
  IconData? Function(T)? icon,
  T? selected,
}) async {
  final selection = await showModalBottomSheet<_Selection<T>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _ChoiceSheet<T>(
      title: title,
      items: items,
      selected: selected,
      label: (item) => label(item.value as T),
      subtitle: subtitle,
      icon: icon,
      color: null,
      grid: false,
    ),
  );
  return selection?.value;
}

/// A mobile selection surface shared by account, category and settings fields.
/// Keeping a FormField preserves form validation and keyboard behavior.
class WalletSelectField<T> extends FormField<T> {
  WalletSelectField({
    super.key,
    super.initialValue,
    bool isExpanded = true,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?>? onChanged,
    InputDecoration decoration = const InputDecoration(),
    String Function(T)? optionLabel,
    String? Function(T)? optionSubtitle,
    IconData? Function(T)? optionIcon,
    Color? Function(T)? optionColor,
    bool grid = false,
    String? nullLabel,
    super.validator,
  }) : super(
         enabled: onChanged != null,
         builder: (field) {
           String label(DropdownMenuItem<T> item) =>
               item.value != null && optionLabel != null
               ? optionLabel(item.value as T)
               : item.child is Text
               ? (item.child as Text).data ?? ''
               : decoration.labelText ?? '选项';
           final selected = items
               .where(
                 (item) =>
                     item.value == field.value ||
                     (field.value == null && item.value == ''),
               )
               .firstOrNull;
           final ink = WalletColors.of(field.context);
           return Semantics(
             button: true,
             enabled: onChanged != null,
             child: Material(
               color: Colors.transparent,
               child: InkWell(
                 borderRadius: BorderRadius.circular(18),
                 onTap: onChanged == null
                     ? null
                     : () async {
                         FocusManager.instance.primaryFocus?.unfocus();
                         final result =
                             await showModalBottomSheet<_Selection<T>>(
                               context: field.context,
                               isScrollControlled: true,
                               useSafeArea: true,
                               showDragHandle: true,
                               builder: (_) => _ChoiceSheet<T>(
                                 title: decoration.labelText ?? '请选择',
                                 items: items,
                                 selected: field.value,
                                 label: label,
                                 subtitle: optionSubtitle,
                                 icon: optionIcon,
                                 color: optionColor,
                                 grid:
                                     grid ||
                                     (decoration.labelText?.contains('分类') ??
                                         false),
                               ),
                             );
                         if (result == null || !field.mounted) return;
                         field.didChange(result.value);
                         HapticFeedback.selectionClick();
                         onChanged(result.value);
                       },
                 child: InputDecorator(
                   isEmpty: false,
                   decoration: decoration.copyWith(
                     enabled: onChanged != null,
                     errorText: field.errorText ?? decoration.errorText,
                     suffixIcon: const Icon(
                       Icons.unfold_more_rounded,
                       size: 22,
                     ),
                   ),
                   child: Text(
                     selected == null
                         ? nullLabel ?? decoration.hintText ?? '请选择'
                         : label(selected),
                     maxLines: 1,
                     overflow: TextOverflow.ellipsis,
                     style: TextStyle(
                       color: selected == null ? ink.secondary : ink.ink,
                       fontWeight: FontWeight.w600,
                     ),
                   ),
                 ),
               ),
             ),
           );
         },
       );
}

class _ChoiceSheet<T> extends StatefulWidget {
  final String title;
  final List<DropdownMenuItem<T>> items;
  final T? selected;
  final String Function(DropdownMenuItem<T>) label;
  final String? Function(T)? subtitle;
  final IconData? Function(T)? icon;
  final Color? Function(T)? color;
  final bool grid;
  const _ChoiceSheet({
    required this.title,
    required this.items,
    required this.selected,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.grid,
  });
  @override
  State<_ChoiceSheet<T>> createState() => _ChoiceSheetState<T>();
}

class _ChoiceSheetState<T> extends State<_ChoiceSheet<T>> {
  String query = '';
  final scroll = ScrollController();
  bool get dayPicker => widget.title == '账单日' || widget.title == '还款日';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients) return;
      final index = widget.items.indexWhere(
        (item) => item.value == widget.selected,
      );
      if (index < 0) return;
      final extent = dayPicker
          ? (index ~/ 5) * 66.0
          : widget.grid
          ? (index ~/ 4) * 134.0
          : index * 56.0;
      scroll.jumpTo(extent.clamp(0.0, scroll.position.maxScrollExtent));
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final columns = dayPicker
        ? 5
        : MediaQuery.sizeOf(context).width < 370
        ? 3
        : 4;
    final rows = (widget.items.length / columns).ceil();
    final estimatedHeight = widget.grid || dayPicker
        ? rows *
                  (dayPicker ? 56 : 124) *
                  MediaQuery.textScalerOf(context).scale(1) +
              (rows - 1) * 10 +
              (widget.items.length > 6 && !dayPicker ? 160 : 104)
        : widget.items.length * 72.0 + (widget.items.length > 6 ? 160 : 104);
    final height = (estimatedHeight / MediaQuery.sizeOf(context).height).clamp(
      .3,
      .85,
    );
    final items = widget.items
        .where(
          (item) =>
              widget.label(item).toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    Widget option(DropdownMenuItem<T> item) {
      final checked =
          item.value == widget.selected ||
          (widget.selected == null && item.value == '');
      final value = item.value;
      final scope = context.dependOnInheritedWidgetOfExactType<AppScopeData>();
      final account = value is String ? scope?.notifier.account(value) : null;
      final category = value is String
          ? scope?.notifier.data.categories
                .where((c) => c.name == value)
                .firstOrNull
          : null;
      final icon = value == null
          ? null
          : widget.icon?.call(value) ??
                (account == null
                    ? (category == null ? null : iconOf(category.icon))
                    : iconOf(account.icon));
      final subtitle = value == null
          ? null
          : widget.subtitle?.call(value) ??
                (account == null
                    ? null
                    : accountOptionDetail(context, account));
      final color = value == null
          ? null
          : widget.color?.call(value) ??
                (account == null
                    ? (category == null ? null : colorOf(category.color))
                    : colorOf(account.color));
      void choose() => Navigator.pop(context, _Selection<T>(value));
      if (dayPicker) {
        return Semantics(
          label: widget.label(item),
          selected: checked,
          child: Material(
            color: checked
                ? scheme.primaryContainer
                : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: choose,
              child: Center(
                child: Text(
                  value == 0 ? '不设置' : '$value',
                  style: TextStyle(
                    fontSize: value == 0 ? 12 : 18,
                    fontWeight: checked ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        );
      }
      if (widget.grid) {
        return Semantics(
          selected: checked,
          child: Material(
            color: checked
                ? scheme.primaryContainer
                : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: item.enabled ? choose : null,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon ?? Icons.category_outlined,
                      color: color ?? scheme.primary,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.label(item),
                      maxLines: 2,
                      textAlign: TextAlign.center,
                    ),
                    if (checked) const Icon(Icons.check_rounded, size: 16),
                  ],
                ),
              ),
            ),
          ),
        );
      }
      return ListTile(
        selected: checked,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        selectedTileColor: scheme.primaryContainer.withValues(alpha: .5),
        leading: icon == null
            ? null
            : Icon(icon, color: color ?? scheme.primary),
        title: Text(widget.label(item)),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: checked
            ? Icon(Icons.check_circle_rounded, color: scheme.primary)
            : null,
        enabled: item.enabled,
        onTap: choose,
      );
    }

    return FractionallySizedBox(
      heightFactor: MediaQuery.viewInsetsOf(context).bottom > 0 ? .95 : height,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: '关闭选择',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            if (widget.items.length > 6 && !dayPicker) ...[
              const SizedBox(height: 12),
              TextField(
                decoration: const InputDecoration(
                  hintText: '搜索选项',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                onChanged: (value) {
                  if (scroll.hasClients) scroll.jumpTo(0);
                  setState(() => query = value);
                },
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('没有匹配选项'))
                  : widget.grid || dayPicker
                  ? LayoutBuilder(
                      builder: (context, size) => GridView.builder(
                        controller: scroll,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: dayPicker
                              ? 5
                              : size.maxWidth < 330
                              ? 3
                              : 4,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          mainAxisExtent:
                              (dayPicker ? 56 : 124) *
                              MediaQuery.textScalerOf(context).scale(1),
                        ),
                        itemCount: items.length,
                        itemBuilder: (_, index) => option(items[index]),
                      ),
                    )
                  : ListView.separated(
                      controller: scroll,
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 4),
                      itemBuilder: (_, index) => option(items[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

List<DropdownMenuItem<String>> accountOptions(List<WalletAccount> accounts) => [
  for (final account in accounts)
    DropdownMenuItem(value: account.id, child: Text(account.name)),
];

String accountOptionDetail(BuildContext context, WalletAccount account) =>
    '${account.archived ? '已归档' : accountGroups[account.category]} · ${privateMoney(context, AppScope.storeOf(context).balance(account))}';

Future<DateTime?> pickPeriodAnchor(
  BuildContext context,
  Period period,
  DateTime initial,
) async {
  if (period == Period.year) {
    final year = await pickWalletOption<int>(
      context,
      title: '选择年份',
      selected: initial.year,
      items: [
        for (var year = 2000; year <= 2100; year++)
          DropdownMenuItem(value: year, child: Text('$year 年')),
      ],
      label: (year) => '$year 年',
    );
    return year == null ? null : DateTime(year);
  }
  if (period == Period.month) {
    var year = initial.year;
    return showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .62,
        child: StatefulBuilder(
          builder: (context, state) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: '上一年',
                      onPressed: year > 2000 ? () => state(() => year--) : null,
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                    Expanded(
                      child: Text(
                        '$year 年',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: '下一年',
                      onPressed: year < 2100 ? () => state(() => year++) : null,
                      icon: const Icon(Icons.chevron_right_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: GridView.count(
                    crossAxisCount: 3,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.5,
                    children: [
                      for (var month = 1; month <= 12; month++)
                        FilledButton.tonal(
                          onPressed: () =>
                              Navigator.pop(context, DateTime(year, month)),
                          child: Text(
                            '$month 月${year == initial.year && month == initial.month ? ' ✓' : ''}',
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  return showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(2000),
    lastDate: DateTime(2100),
  );
}

Duration motionDuration(BuildContext context, [int milliseconds = 220]) =>
    Duration(
      milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : milliseconds,
    );
