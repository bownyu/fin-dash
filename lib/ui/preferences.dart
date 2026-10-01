import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../data/backup.dart';
import '../domain/models.dart';
import '../services/ai_service.dart';
import '../services/file_export.dart';
import 'ai_pages.dart';
import 'design.dart';
import 'editors.dart';
import 'finance_pages.dart';

Future<void> showThemePicker(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '选择你的外观',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                '两种质感，同样清晰。随时切换，自动保存。',
                style: Theme.of(sheetContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              ThemeOptions(onSelected: () => Navigator.of(sheetContext).pop()),
            ],
          ),
        ),
      ),
    );

class ThemeOptions extends StatelessWidget {
  final VoidCallback? onSelected;
  const ThemeOptions({super.key, this.onSelected});
  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    final selected = store.data.settings['theme'] == 'system'
        ? (Theme.of(context).brightness == Brightness.dark ? 'dark' : 'light')
        : store.data.settings['theme'] == 'dark'
        ? 'dark'
        : 'light';
    Widget option(bool dark) {
      final value = dark ? 'dark' : 'light';
      return _ThemeOption(
        dark: dark,
        selected: selected == value,
        onTap: () async {
          final saved = await perform(
            context,
            () => store.change((d) => d.settings['theme'] = value),
          );
          if (saved && context.mounted) onSelected?.call();
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 300 ||
            MediaQuery.textScalerOf(context).scale(1) > 1.2) {
          return Column(
            children: [option(false), const SizedBox(height: 12), option(true)],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: option(false)),
            const SizedBox(width: 12),
            Expanded(child: option(true)),
          ],
        );
      },
    );
  }
}

class _ThemeOption extends StatelessWidget {
  final bool dark, selected;
  final VoidCallback onTap;
  const _ThemeOption({
    required this.dark,
    required this.selected,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final colors = WalletColors.of(context);
    final sample = WalletColors(dark);
    final title = dark ? '黑色 · 蓝色' : '白色 · 透明';
    return Semantics(
      button: true,
      selected: selected,
      label: '$title${dark ? '' : '，推荐'}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: Key('theme-${dark ? 'dark' : 'light'}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: selected
                  ? primary.withValues(alpha: colors.dark ? .12 : .05)
                  : colors.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: selected
                    ? primary
                    : Theme.of(context).colorScheme.outlineVariant,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Container(
                    height: 106,
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: dark
                            ? const [Color(0xFF0C1525), Color(0xFF203C64)]
                            : const [Color(0xFFE9F2FF), Color(0xFFF1EAFB)],
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 32,
                          height: 4,
                          decoration: BoxDecoration(
                            color: sample.secondary.withValues(alpha: .5),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          height: 36,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: sample.hero),
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(color: sample.border),
                          ),
                          padding: const EdgeInsets.all(9),
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: 48,
                            height: 6,
                            decoration: BoxDecoration(
                              color: sample.ink.withValues(alpha: .7),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                        const SizedBox(height: 7),
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: sample.surface,
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: sample.surface,
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 18,
                      color: selected ? primary : colors.secondary,
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  dark ? '深邃夜色，蓝色光感' : '推荐 · 轻盈通透',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});
  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    Widget menu(
      IconData icon,
      String title,
      String subtitle,
      Widget page,
    ) => ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      leading: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: primary.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, color: primary, size: 22),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      trailing: const Icon(Icons.chevron_right_rounded, color: muted),
      onTap: () => openPage(context, page),
    );
    return PageList(
      children: [
        Text('我的', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 22),
        Panel(
          child: InkWell(
            onTap: () => openPage(context, const ProfileEditor()),
            child: Row(
              children: [
                Avatar(store.data.profile['avatar'], size: 62),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        store.data.profile['name'] ?? '我的档案',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 5),
                      Text(
                        (store.data.profile['email'] as String? ?? '').isEmpty
                            ? '本地个人档案'
                            : store.data.profile['email'],
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.edit_outlined, color: muted, size: 20),
              ],
            ),
          ),
        ),
        const SectionTitle('我的财务'),
        Panel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              menu(
                Icons.account_balance_wallet_outlined,
                '资产管理',
                '${store.activeAccounts.length} 个使用中的账户',
                const AccountsPage(),
              ),
              menu(
                Icons.flag_outlined,
                '财务目标',
                '${store.data.goals.where((g) => g['status'] == 'active').length} 个进行中的目标',
                const GoalsPage(),
              ),
              menu(
                Icons.bolt_rounded,
                '快捷交易',
                '管理常用的支出、收入和转账',
                const QuickEntriesPage(),
              ),
              menu(
                Icons.category_outlined,
                '分类管理',
                '自定义收支分类',
                const CategoriesPage(),
              ),
            ],
          ),
        ),
        const SectionTitle('AI 财务顾问'),
        Panel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              menu(
                Icons.auto_awesome_outlined,
                '与顾问聊聊',
                store.aiStatus ?? '分析账单、发现变化、制定计划',
                const ChatPage(),
              ),
              menu(
                Icons.tune_rounded,
                'AI 设置',
                AppScope.of(context).ai.config['model'],
                const AiSettingsPage(),
              ),
              menu(
                Icons.face_retouching_natural_rounded,
                '顾问人设',
                store.data.agent['name'],
                const PersonaPage(),
              ),
              menu(
                Icons.psychology_outlined,
                '顾问记忆',
                '查看画像、偏好、事实与消费模式',
                const AgentStatePage(),
              ),
              menu(
                Icons.history_rounded,
                '历史对话',
                '按日期回看交流记录',
                const ChatHistoryPage(),
              ),
            ],
          ),
        ),
        const SectionTitle('数据与偏好'),
        Panel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              menu(
                Icons.backup_outlined,
                '备份与恢复',
                '兼容旧版 wallet 的 JSON / Base64 备份',
                const BackupPage(),
              ),
              menu(
                Icons.notifications_none_rounded,
                '提醒中心',
                '预算进度与信用卡还款提醒',
                const RemindersPage(),
              ),
              menu(
                Icons.settings_outlined,
                '应用设置',
                '主题、预算与调试记录',
                const SettingsPage(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        TextButton(
          onPressed: () async {
            if (await confirm(context, '退出个人档案？', '账单和账户仍保存在本机，下次进入即可继续。')) {
              if (context.mounted) {
                AppScope.of(context).ai.cancel();
                await perform(
                  context,
                  () => store.change((d) => d.settings['locked'] = true),
                );
              }
            }
          },
          child: const Text('退出个人档案', style: TextStyle(color: coral)),
        ),
        const SizedBox(height: 12),
        const Center(
          child: Text(
            'FinDash 1.1.0',
            textAlign: TextAlign.center,
            style: TextStyle(color: muted, fontSize: 11, height: 1.8),
          ),
        ),
      ],
    );
  }
}

class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key});
  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  final name = TextEditingController(), email = TextEditingController();
  final form = GlobalKey<FormState>();
  bool saving = false;
  @override
  void dispose() {
    name.dispose();
    email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context),
        returning = store.data.profile['name'] != null;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Form(
                key: form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: Image.asset(
                        'assets/brand.png',
                        width: 82,
                        height: 82,
                      ),
                    ),
                    const SizedBox(height: 36),
                    Text(
                      returning
                          ? '欢迎回来，${store.data.profile['name']}'
                          : '每一笔，都有方向。',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      '记账、管理资产、看清收支。\n从一个属于你的本地档案开始。',
                      style: TextStyle(color: muted, height: 1.8),
                    ),
                    const SizedBox(height: 34),
                    if (!returning) ...[
                      TextFormField(
                        key: const Key('welcome-name'),
                        controller: name,
                        maxLength: 20,
                        decoration: const InputDecoration(
                          labelText: '怎么称呼你？',
                          hintText: '输入昵称',
                        ),
                        validator: (v) =>
                            v!.trim().length < 2 ? '昵称至少 2 个字符' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: email,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(labelText: '邮箱（可选）'),
                        validator: (v) =>
                            v!.isNotEmpty &&
                                !RegExp(
                                  r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                                ).hasMatch(v.trim())
                            ? '请输入有效邮箱'
                            : null,
                      ),
                      const SizedBox(height: 26),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: saving
                            ? null
                            : () async {
                                if (!form.currentState!.validate()) return;
                                setState(() => saving = true);
                                final ok = await perform(
                                  context,
                                  () => store.change((d) {
                                    if (!returning) {
                                      d.profile = {
                                        'id': newId(),
                                        'name': name.text.trim(),
                                        'email': email.text.trim(),
                                        'avatar': '🌿',
                                      };
                                    }
                                    d.settings['locked'] = false;
                                  }),
                                );
                                if (mounted && !ok) {
                                  setState(() => saving = false);
                                }
                              },
                        child: Text(
                          saving
                              ? '准备中…'
                              : returning
                              ? '继续使用'
                              : '开始记录',
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Center(
                      child: TextButton(
                        onPressed: () => openPage(context, const BackupPage()),
                        child: const Text('从旧版 wallet 备份恢复 →'),
                      ),
                    ),
                    const SizedBox(height: 34),
                    const Text(
                      '账本保存在本机，无需注册云端账号。AI 功能在配置模型服务并发送请求后使用。',
                      style: TextStyle(fontSize: 12, color: muted, height: 1.7),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ProfileEditor extends StatefulWidget {
  const ProfileEditor({super.key});
  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  final form = GlobalKey<FormState>(),
      name = TextEditingController(),
      email = TextEditingController();
  String avatar = '🌿';
  bool initialized = false, saving = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (initialized) return;
    initialized = true;
    final profile = AppScope.storeOf(context).data.profile;
    name.text = profile['name'] ?? '';
    email.text = profile['email'] ?? '';
    avatar = profile['avatar'] ?? '🌿';
  }

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    super.dispose();
  }

  Future<void> image() async {
    await perform(context, () async {
      final result = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (result == null) return;
      final bytes = await result.readAsBytes();
      if (bytes.length > 3 * 1024 * 1024) {
        throw const FormatException('头像图片超过 3 MB');
      }
      if (mounted) {
        setState(
          () => avatar = 'data:image/jpeg;base64,${base64Encode(bytes)}',
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('编辑个人资料')),
    body: Form(
      key: form,
      child: PageList(
        children: [
          Center(child: Avatar(avatar, size: 96)),
          const SizedBox(height: 20),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: ['🌿', '🐱', '🌙', '🦊', '🐼', '🌊', '🌻', '🚀']
                .map(
                  (s) => InkWell(
                    onTap: () => setState(() => avatar = s),
                    child: Avatar(s, size: 44),
                  ),
                )
                .toList(),
          ),
          Center(
            child: TextButton.icon(
              onPressed: image,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('从相册选择头像'),
            ),
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: name,
            maxLength: 20,
            decoration: const InputDecoration(labelText: '昵称'),
            validator: (v) => v!.trim().length < 2 ? '昵称至少 2 个字符' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: '邮箱（可选）'),
            validator: (v) =>
                v!.trim().isNotEmpty &&
                    !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v.trim())
                ? '请输入有效邮箱'
                : null,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    if (!form.currentState!.validate()) return;
                    setState(() => saving = true);
                    final ok = await perform(
                      context,
                      () => AppScope.storeOf(context).change(
                        (d) => d.profile = {
                          ...d.profile,
                          'name': name.text.trim(),
                          'email': email.text.trim(),
                          'avatar': avatar,
                        },
                      ),
                    );
                    if (context.mounted) {
                      if (ok) {
                        Navigator.pop(context);
                      } else {
                        setState(() => saving = false);
                      }
                    }
                  },
            child: const Text('保存资料'),
          ),
        ],
      ),
    ),
  );
}

class QuickEntriesPage extends StatelessWidget {
  const QuickEntriesPage({super.key});
  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('快捷交易'),
        actions: [
          IconButton(
            tooltip: '添加快捷交易',
            icon: const Icon(Icons.add_rounded),
            onPressed: () => openPage(
              context,
              const TransactionEditor(saveAsQuick: true),
              modal: true,
            ),
          ),
        ],
      ),
      body: PageList(
        children: [
          const Text(
            '金额或账户留空时，记账前再选择。点首页快捷交易可预填表单，核对后保存。',
            style: TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 18),
          if (store.data.quickEntries.isEmpty)
            EmptyState(
              '把常用交易存起来',
              '早餐、工资、还款，都可以成为快捷交易。',
              icon: Icons.bolt_rounded,
              action: FilledButton(
                onPressed: () => openPage(
                  context,
                  const TransactionEditor(saveAsQuick: true),
                  modal: true,
                ),
                child: const Text('添加快捷交易'),
              ),
            ),
          ...store.data.quickEntries.map(
            (q) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Panel(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: IconBadge(q.icon, txColor(q.type)),
                  title: Text(q.title),
                  subtitle: Text(
                    '${q.type.label} · ${q.amount == null ? '自定金额' : money(q.amount!)} · ${store.account(q.accountId)?.name ?? (q.type == TxType.transfer ? '${store.account(q.fromId)?.name ?? '待选'} → ${store.account(q.toId)?.name ?? '待选'}' : '记账时选择账户')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  onTap: () => openPage(
                    context,
                    TransactionEditor(quick: q, saveAsQuick: true),
                    modal: true,
                  ),
                  trailing: IconButton(
                    tooltip: '删除快捷交易',
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      color: muted,
                    ),
                    onPressed: () async {
                      if (await confirm(
                        context,
                        '删除快捷交易？',
                        '已记录的账单不受影响。',
                        action: '删除',
                      )) {
                        if (context.mounted) {
                          await perform(
                            context,
                            () => store.change(
                              (d) => d.quickEntries.removeWhere(
                                (x) => x.id == q.id,
                              ),
                            ),
                          );
                        }
                      }
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key});
  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  TxType type = TxType.expense;
  Future<void> add() async {
    final name = TextEditingController();
    var icon = 'restaurant', color = palette.first;
    final result = await showDialog<WalletCategory>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, state) => AlertDialog(
          title: Text('添加${type.label}分类'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  maxLength: 12,
                  decoration: const InputDecoration(labelText: '分类名称'),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children:
                      [
                            'restaurant',
                            'shopping_bag',
                            'directions_car',
                            'home',
                            'movie',
                            'local_cafe',
                            'medical_services',
                            'work',
                            'savings',
                            'spa',
                            'card_giftcard',
                            'more_horiz',
                          ]
                          .map(
                            (s) => IconButton(
                              onPressed: () => state(() => icon = s),
                              icon: Icon(
                                iconOf(s),
                                color: icon == s ? primary : muted,
                              ),
                            ),
                          )
                          .toList(),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: palette
                      .map(
                        (s) => InkWell(
                          onTap: () => state(() => color = s),
                          child: CircleAvatar(
                            radius: 14,
                            backgroundColor: colorOf(s),
                            child: color == s
                                ? const Icon(
                                    Icons.check_rounded,
                                    color: Colors.white,
                                    size: 17,
                                  )
                                : null,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                if (name.text.trim().isEmpty) {
                  toast(context, '请输入分类名称');
                  return;
                }
                Navigator.pop(
                  c,
                  WalletCategory(newId(), name.text.trim(), icon, color, type),
                );
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    if (result != null && mounted) {
      await perform(
        context,
        () => AppScope.storeOf(context).saveCategory(result),
        success: '分类已添加',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('分类管理'),
        actions: [
          IconButton(
            tooltip: '添加分类',
            onPressed: add,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: PageList(
        children: [
          SegmentedButton<TxType>(
            segments: [
              for (final t in [TxType.expense, TxType.income])
                ButtonSegment(value: t, label: Text(t.label)),
            ],
            selected: {type},
            onSelectionChanged: (v) => setState(() => type = v.first),
          ),
          const SizedBox(height: 20),
          Panel(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: store.data.categories
                  .where((c) => c.type == type)
                  .map(
                    (c) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: IconBadge(c.icon, colorOf(c.color), size: 38),
                      title: Text(c.name),
                      trailing: IconButton(
                        tooltip: '删除分类',
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          color: muted,
                        ),
                        onPressed: () async {
                          if (await confirm(
                            context,
                            '删除“${c.name}”？',
                            '已被账单或快捷交易使用的分类不能删除。',
                            action: '删除',
                          )) {
                            if (context.mounted) {
                              await perform(
                                context,
                                () => store.deleteCategory(c),
                              );
                            }
                          }
                        },
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: add,
            icon: const Icon(Icons.add_rounded),
            label: const Text('添加分类'),
          ),
        ],
      ),
    );
  }
}

class GoalsPage extends StatelessWidget {
  const GoalsPage({super.key});
  Future<void> edit(BuildContext context, [Json? initial]) async {
    final description = TextEditingController(
      text: initial?['description'] ?? '',
    );
    final target = TextEditingController(
      text: initial?['targetCents'] == null
          ? ''
          : moneyInput(initial!['targetCents']),
    );
    var status = initial?['status'] ?? 'active';
    final result = await showDialog<Json>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, state) => AlertDialog(
          title: Text(initial == null ? '添加财务目标' : '编辑财务目标'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: description,
                  maxLength: 200,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: '想实现什么？'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: target,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '目标金额（可选）',
                    prefixText: '¥ ',
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  decoration: const InputDecoration(labelText: '状态'),
                  items: const [
                    DropdownMenuItem(value: 'active', child: Text('进行中')),
                    DropdownMenuItem(value: 'completed', child: Text('已完成')),
                    DropdownMenuItem(value: 'paused', child: Text('已暂停')),
                    DropdownMenuItem(value: 'abandoned', child: Text('已放弃')),
                  ],
                  onChanged: (v) => state(() => status = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                if (description.text.trim().isEmpty) {
                  toast(context, '请填写目标');
                  return;
                }
                int? cents;
                try {
                  if (target.text.isNotEmpty) {
                    cents = parseMoney(target.text);
                    if (cents <= 0) throw const FormatException('目标金额须大于 0');
                  }
                } on FormatException catch (e) {
                  toast(context, e.message);
                  return;
                }
                Navigator.pop(c, {
                  ...?initial,
                  'id': initial?['id'] ?? newId(),
                  'description': description.text.trim(),
                  'targetCents': cents,
                  'status': status,
                  'createdAt':
                      initial?['createdAt'] ?? DateTime.now().toIso8601String(),
                  'updatedAt': DateTime.now().toIso8601String(),
                });
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    description.dispose();
    target.dispose();
    if (result != null && context.mounted) {
      await perform(
        context,
        () => AppScope.storeOf(context).change((d) {
          final i = d.goals.indexWhere((g) => g['id'] == result['id']);
          if (i < 0) {
            d.goals.add(result);
          } else {
            d.goals[i] = result;
          }
        }),
        success: '目标已保存',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    const labels = {
      'active': '进行中',
      'completed': '已完成',
      'paused': '已暂停',
      'abandoned': '已放弃',
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('财务目标'),
        actions: [
          IconButton(
            tooltip: '添加目标',
            onPressed: () => edit(context),
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: PageList(
        children: [
          if (store.data.goals.isEmpty)
            EmptyState(
              '给未来一点期待',
              '旅行基金、应急储备，或者更从容的生活。',
              icon: Icons.flag_outlined,
              action: FilledButton(
                onPressed: () => edit(context),
                child: const Text('添加目标'),
              ),
            ),
          ...store.data.goals.map(
            (g) => Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            g['description'],
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Chip(
                          label: Text(
                            labels[g['status']] ?? '进行中',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                    if (g['targetCents'] != null)
                      Text(
                        '目标 ${money(g['targetCents'])}',
                        style: const TextStyle(color: muted),
                      ),
                    if (g['aiAssessment'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(g['aiAssessment']),
                      ),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => edit(context, g),
                          child: const Text('编辑目标'),
                        ),
                        TextButton(
                          onPressed: () async {
                            if (await confirm(
                              context,
                              '删除目标？',
                              '账单与账户数据不受影响。',
                              action: '删除',
                            )) {
                              if (context.mounted) {
                                await perform(
                                  context,
                                  () => store.change(
                                    (d) => d.goals.removeWhere(
                                      (x) => x['id'] == g['id'],
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                          child: const Text(
                            '删除',
                            style: TextStyle(color: muted),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key});
  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  final keyInput = TextEditingController(),
      url = TextEditingController(),
      model = TextEditingController();
  String provider = 'zhipu';
  bool initialized = false, saving = false, hidden = true, loading = true;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (initialized) return;
    initialized = true;
    provider = AppScope.of(context).ai.provider;
    load(provider);
  }

  Future<void> load(String value) async {
    setState(() => loading = true);
    final scope = AppScope.of(context);
    final c = {
      ...providerDefaults[value]!,
      ...Json.from(scope.notifier!.data.providerConfigs[value] ?? {}),
    };
    url.text = c['baseURL'];
    model.text = c['model'];
    try {
      final key = await scope.ai.vault.read(value);
      if (mounted && provider == value) keyInput.text = key ?? '';
    } catch (_) {
      if (mounted) toast(context, '无法读取密钥，请重新填写');
    }
    if (mounted && provider == value) setState(() => loading = false);
  }

  Future<void> save({bool close = true}) async {
    if (saving || loading) return;
    final scope = AppScope.of(context);
    if (scope.ai.busy) {
      toast(context, '请先停止当前 AI 请求');
      return;
    }
    try {
      endpoint(url.text);
      if (model.text.trim().isEmpty) throw const FormatException('请填写模型名称');
    } on FormatException catch (e) {
      toast(context, e.message);
      return;
    }
    setState(() => saving = true);
    final ok = await perform(context, () async {
      await scope.ai.vault.write(provider, keyInput.text.trim());
      await scope.notifier!.change((d) {
        d.settings['provider'] = provider;
        d.providerConfigs[provider] = {
          'baseURL': url.text.trim(),
          'model': model.text.trim(),
        };
        d.extras.remove('analysisCache');
      });
    }, success: 'AI 设置已保存');
    if (!mounted) return;
    if (ok && close) {
      Navigator.pop(context);
    } else {
      setState(() => saving = false);
    }
  }

  @override
  void dispose() {
    keyInput.dispose();
    url.dispose();
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AI 设置')),
    body: PageList(
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.auto_awesome_rounded, color: primary, size: 30),
              const SizedBox(height: 14),
              const Text(
                '连接你的财务顾问',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                '支持智谱、NVIDIA NIM 和 OpenAI 兼容服务。密钥单独保存，不包含在账本备份中。',
                style: TextStyle(color: muted, fontSize: 13),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        DropdownButtonFormField<String>(
          initialValue: provider,
          decoration: const InputDecoration(labelText: '模型服务'),
          items: providerDefaults.entries
              .map(
                (p) => DropdownMenuItem(
                  value: p.key,
                  child: Text(p.value['name']),
                ),
              )
              .toList(),
          onChanged: saving || loading
              ? null
              : (v) async {
                  await save(close: false);
                  if (!mounted) return;
                  setState(() => provider = v!);
                  await load(provider);
                },
        ),
        const SizedBox(height: 18),
        TextField(
          controller: keyInput,
          obscureText: hidden,
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'API 密钥',
            suffixIcon: IconButton(
              tooltip: hidden ? '显示密钥' : '隐藏密钥',
              onPressed: () => setState(() => hidden = !hidden),
              icon: Icon(
                hidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: url,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            helperText: '填写 API 基础地址，如 https://…/v1',
          ),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: model,
          decoration: const InputDecoration(labelText: '模型名称'),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: saving || loading ? null : () => save(),
          child: Text(
            loading
                ? '读取设置…'
                : saving
                ? '保存中…'
                : '保存设置',
          ),
        ),
        const SizedBox(height: 14),
        TextButton(
          onPressed: saving || loading
              ? null
              : () async {
                  if (await confirm(
                    context,
                    '清除当前服务的密钥？',
                    '模型和地址设置保留。清除后需要重新填写密钥才能发送请求。',
                    action: '清除',
                  )) {
                    if (context.mounted) {
                      await perform(
                        context,
                        () => AppScope.of(context).ai.vault.write(provider, ''),
                        success: '密钥已清除',
                      );
                    }
                    if (mounted) keyInput.clear();
                  }
                },
          child: const Text('清除密钥', style: TextStyle(color: coral)),
        ),
      ],
    ),
  );
}

class PersonaPage extends StatefulWidget {
  const PersonaPage({super.key});
  @override
  State<PersonaPage> createState() => _PersonaPageState();
}

class _PersonaPageState extends State<PersonaPage> {
  final name = TextEditingController(),
      focus = TextEditingController(),
      prompt = TextEditingController();
  String tone = 'professional';
  bool initialized = false, saving = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (initialized) return;
    initialized = true;
    final a = AppScope.storeOf(context).data.agent;
    name.text = a['name'];
    focus.text = (a['focusAreas'] as List? ?? []).join('、');
    prompt.text = a['customPrompt'] ?? '';
    tone = a['tone'] ?? 'professional';
  }

  @override
  void dispose() {
    name.dispose();
    focus.dispose();
    prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('顾问人设')),
    body: PageList(
      children: [
        TextField(
          controller: name,
          maxLength: 30,
          decoration: const InputDecoration(labelText: '顾问名字'),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: tone,
          decoration: const InputDecoration(labelText: '交流风格'),
          items: const [
            DropdownMenuItem(value: 'professional', child: Text('专业理性')),
            DropdownMenuItem(value: 'humorous', child: Text('轻松幽默')),
            DropdownMenuItem(value: 'strict', child: Text('严格督促')),
            DropdownMenuItem(value: 'encouraging', child: Text('温暖鼓励')),
            DropdownMenuItem(value: 'roasting', child: Text('毒舌管家')),
          ],
          onChanged: (v) => tone = v!,
        ),
        const SizedBox(height: 18),
        TextField(
          controller: focus,
          maxLength: 200,
          decoration: const InputDecoration(
            labelText: '关注领域',
            hintText: '如：外卖、购物、深夜消费，以逗号分隔',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: prompt,
          maxLines: 5,
          maxLength: 2000,
          decoration: const InputDecoration(labelText: '额外指引（可选）'),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: saving
              ? null
              : () async {
                  if (name.text.trim().isEmpty) {
                    toast(context, '请输入顾问名字');
                    return;
                  }
                  setState(() => saving = true);
                  final ok = await perform(
                    context,
                    () => AppScope.storeOf(context).change((d) {
                      d.agent.addAll({
                        'name': name.text.trim(),
                        'tone': tone,
                        'focusAreas': focus.text
                            .split(RegExp('[,，、]'))
                            .map((s) => s.trim())
                            .where((s) => s.isNotEmpty)
                            .toList(),
                        'customPrompt': prompt.text.trim(),
                      });
                      d.extras.remove('analysisCache');
                    }),
                  );
                  if (context.mounted) {
                    if (ok) {
                      Navigator.pop(context);
                    } else {
                      setState(() => saving = false);
                    }
                  }
                },
          child: const Text('保存人设'),
        ),
      ],
    ),
  );
}

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool busy = false;
  Future<void> export() async {
    setState(() => busy = true);
    await perform(context, () async {
      final bytes = Uint8List.fromList(
        utf8.encode(AppScope.storeOf(context).exportBackup()),
      );
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '保存账本备份',
        fileName:
            'findash_backup_${DateTime.now().millisecondsSinceEpoch}.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );
      await completeFileExport(path, bytes);
      if (path != null && mounted) toast(context, '完整备份已保存');
    });
    if (mounted) setState(() => busy = false);
  }

  Future<void> import() async {
    if (AppScope.of(context).ai.busy) {
      toast(context, '请先停止当前 AI 请求');
      return;
    }
    setState(() => busy = true);
    await perform(context, () async {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (result == null) return;
      final bytes = result.files.single.bytes;
      if (bytes == null) throw const FormatException('文件无法读取');
      final preview = parseBackup(utf8.decode(bytes));
      final net = preview.data.accounts
          .where((a) => a.includeInTotal)
          .fold<int>(
            0,
            (sum, a) =>
                sum +
                a.openingBalance +
                preview.data.transactions.fold<int>(
                  0,
                  (s, t) => s + t.effectOn(a.id),
                ),
          );
      if (!mounted) return;
      final approved = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('核对导入内容'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${preview.legacy ? 'wallet 旧版' : 'Flutter'} 备份'),
                const SizedBox(height: 12),
                Text(
                  '账户 ${preview.data.accounts.length} 个\n账单 ${preview.data.transactions.length} 笔\n快捷交易 ${preview.data.quickEntries.length} 项\n净资产 ${money(net)}',
                  style: const TextStyle(height: 1.9),
                ),
                const SizedBox(height: 14),
                ...preview.notes.map(
                  (s) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      s,
                      style: const TextStyle(fontSize: 12, color: muted),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '恢复会替换当前账本。请确认这是你要使用的备份。',
                  style: TextStyle(color: coral, fontSize: 13),
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
              onPressed: () => Navigator.pop(c, true),
              child: const Text('确认恢复'),
            ),
          ],
        ),
      );
      if (approved == true && mounted) {
        await AppScope.storeOf(context).restore(preview);
        if (mounted) {
          toast(context, '已恢复 ${preview.data.transactions.length} 笔账单');
        }
      }
    });
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: PageList(
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.backup_outlined, color: primary, size: 36),
                const SizedBox(height: 18),
                const Text(
                  '让记录安心留存',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Text(
                  '${store.data.accounts.length} 个账户 · ${store.data.transactions.length} 笔账单 · ${store.data.chats.length} 条对话',
                  style: const TextStyle(color: muted),
                ),
                const SizedBox(height: 16),
                const Text(
                  '完整备份包含账户、账单、分类、快捷交易、目标、设置、顾问记忆与历史对话。API 密钥单独保存，恢复后可重新填写。',
                  style: TextStyle(color: muted, fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          FilledButton.icon(
            onPressed: busy || store.startupError != null ? null : export,
            icon: const Icon(Icons.download_rounded),
            label: const Text('导出完整备份'),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: busy ? null : import,
            icon: const Icon(Icons.upload_file_rounded),
            label: const Text('选择备份并恢复'),
          ),
          const SizedBox(height: 22),
          const Text(
            '兼容旧版 wallet 的 JSON 和 Base64 备份。导入时保留当前账户余额，避免历史账单重复扣款。',
            style: TextStyle(color: muted, fontSize: 12),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}

class RemindersPage extends StatelessWidget {
  const RemindersPage({super.key});
  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('提醒中心')),
      body: PageList(
        children: [
          Panel(
            child: Column(
              children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('预算进度提醒'),
                  subtitle: const Text('本月使用预算超过 80% 时显示'),
                  value: store.data.settings['budgetReminder'] != false,
                  onChanged: (v) => perform(
                    context,
                    () => store.change((d) => d.settings['budgetReminder'] = v),
                  ),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('还款日提醒'),
                  subtitle: const Text('信用账户还款日前 3 天显示'),
                  value: store.data.settings['repaymentReminder'] != false,
                  onChanged: (v) => perform(
                    context,
                    () => store.change(
                      (d) => d.settings['repaymentReminder'] = v,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '提醒在应用内显示，打开首页或提醒中心即可查看。',
            style: TextStyle(color: muted, fontSize: 12),
          ),
          const SectionTitle('当前提醒'),
          if (store.suggestions.isEmpty)
            const EmptyState(
              '目前没有新提醒',
              '记账和管理账户时，相关提醒会出现在这里。',
              icon: Icons.notifications_none_rounded,
            ),
          ...store.suggestions.map(
            (s) => Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s['title'],
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 10),
                    Text(s['text'], style: const TextStyle(color: muted)),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => openPage(
                            context,
                            s['action'] == 'assets'
                                ? const AccountsPage()
                                : const _StatsRoute(),
                          ),
                          child: const Text('查看详情'),
                        ),
                        TextButton(
                          onPressed: () => perform(
                            context,
                            () => store.change((d) {
                              final dismissed = List<String>.from(
                                d.agent['dismissedSuggestions'] ?? [],
                              );
                              dismissed.add(s['id']);
                              d.agent['dismissedSuggestions'] = dismissed;
                            }),
                          ),
                          child: const Text(
                            '忽略',
                            style: TextStyle(color: muted),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatsRoute extends StatelessWidget {
  const _StatsRoute();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('收支详情')),
    body: const StatsPage(),
  );
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  Future<void> budget(BuildContext context) async {
    final store = AppScope.storeOf(context),
        input = TextEditingController(
          text: moneyInput(
            AppScope.storeOf(context).data.settings['budget'] ?? 0,
          ),
        );
    final result = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('设置月预算'),
        content: TextField(
          controller: input,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            prefixText: '¥ ',
            helperText: '设为 0 关闭预算提醒',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              try {
                Navigator.pop(c, parseMoney(input.text));
              } on FormatException catch (e) {
                toast(context, e.message);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    input.dispose();
    if (result != null && context.mounted) {
      await perform(
        context,
        () => store.change((d) => d.settings['budget'] = result),
        success: '预算已更新',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('应用设置')),
      body: PageList(
        children: [
          const SectionTitle('界面外观'),
          const ThemeOptions(),
          if (store.data.settings['theme'] == 'system')
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '当前跟随系统外观，选择上方方案即可固定主题。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SectionTitle('预算与隐私'),
          Panel(
            child: Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('每月预算'),
                  subtitle: Text(
                    (store.data.settings['budget'] ?? 0) > 0
                        ? money(store.data.settings['budget'])
                        : '未设置',
                  ),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: muted,
                  ),
                  onTap: () => budget(context),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('首页显示资产金额'),
                  value: store.data.settings['visible'] != false,
                  onChanged: (v) => perform(
                    context,
                    () => store.change((d) => d.settings['visible'] = v),
                  ),
                ),
              ],
            ),
          ),
          const SectionTitle('开发者选项'),
          Panel(
            padding: EdgeInsets.zero,
            child: ListTile(
              title: const Text('顾问调试记录'),
              subtitle: const Text(
                '只记录请求状态，不包含密钥或账单内容',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right_rounded, color: muted),
              onTap: () => openPage(context, const DebugLogsPage()),
            ),
          ),
          const SectionTitle('关于'),
          const Panel(
            child: Text(
              'FinDash 1.1.0\n本地账本 · 人民币记账\n\n旧版 Kotlin 工程已保留在 legacy_android。',
              style: TextStyle(color: muted, height: 1.9),
            ),
          ),
        ],
      ),
    );
  }
}

class DebugLogsPage extends StatelessWidget {
  const DebugLogsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final logs = AppScope.storeOf(context).debugLogs;
    return Scaffold(
      appBar: AppBar(title: const Text('顾问调试记录')),
      body: PageList(
        children: [
          if (logs.isEmpty)
            const EmptyState('暂无调试记录', '本次打开应用的 AI 请求状态会显示在这里。'),
          ...logs.map(
            (log) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${log['type']} · ${log['time']}',
                      style: const TextStyle(color: muted, fontSize: 11),
                    ),
                    const SizedBox(height: 7),
                    SelectableText(log['text']),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
