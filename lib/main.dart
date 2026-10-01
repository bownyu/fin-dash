import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'data/storage.dart';
import 'data/wallet_store.dart';
import 'services/ai_service.dart';
import 'ui/design.dart';
import 'ui/editors.dart';
import 'ui/finance_pages.dart';
import 'ui/preferences.dart';
import 'services/voice_widget_runtime.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  const demo = bool.fromEnvironment('DEMO');
  final store = WalletStore(demo ? MemoryStorage() : LocalWalletStorage());
  final ai = AiService(store, SecureKeyVault());
  bool shown = false;
  void showApp() {
    if (shown) return;
    shown = true;
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        systemNavigationBarColor: Color(0xFFF3F5FA),
      ),
    );
    runApp(FinDashApp(store: store, ai: ai, demo: demo));
  }

  VoiceWidgetRuntime.install(store, ai, showApp);
  if (!args.contains('widget')) showApp();
  await store.initialize(demo: demo);
  try {
    await VoiceWidgetRuntime.channel.invokeMethod<void>('ready');
  } on MissingPluginException {
    /* Other platforms do not host Android widgets. */
  }
}

class FinDashApp extends StatefulWidget {
  final WalletStore store;
  final AiService ai;
  final bool demo;
  const FinDashApp({
    super.key,
    required this.store,
    required this.ai,
    this.demo = false,
  });
  @override
  State<FinDashApp> createState() => _FinDashAppState();
}

class _FinDashAppState extends State<FinDashApp> {
  static final _lightTheme = walletTheme(Brightness.light);
  static final _darkTheme = walletTheme(Brightness.dark);
  late (bool, String?, Object?, bool, bool) _configuration;

  (bool, String?, Object?, bool, bool) _readConfiguration() => (
    widget.store.loading,
    widget.store.startupError,
    widget.store.data.settings['theme'],
    widget.store.data.profile['name'] == null,
    widget.store.data.settings['locked'] == true,
  );

  @override
  void initState() {
    super.initState();
    _configuration = _readConfiguration();
    widget.store.addListener(_storeChanged);
  }

  @override
  void didUpdateWidget(covariant FinDashApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_storeChanged);
      widget.store.addListener(_storeChanged);
      _configuration = _readConfiguration();
    }
  }

  void _storeChanged() {
    final next = _readConfiguration();
    if (next == _configuration) return;
    setState(() => _configuration = next);
  }

  @override
  void dispose() {
    widget.store.removeListener(_storeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppScope(
    store: widget.store,
    ai: widget.ai,
    child: MaterialApp(
      title: 'FinDash',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: switch (widget.store.data.settings['theme']) {
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => ThemeMode.light,
      },
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness:
              Theme.of(context).brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark,
          statusBarBrightness: Theme.of(context).brightness == Brightness.dark
              ? Brightness.dark
              : Brightness.light,
          systemNavigationBarColor: WalletColors.of(context).background,
          systemNavigationBarIconBrightness:
              Theme.of(context).brightness == Brightness.dark
              ? Brightness.light
              : Brightness.dark,
        ),
        child: ColoredBox(
          color: WalletColors.of(context).background,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: child!,
            ),
          ),
        ),
      ),
      home: widget.store.loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : widget.store.startupError != null
          ? _RecoveryPage(widget.store.startupError!)
          : widget.store.data.profile['name'] == null ||
                widget.store.data.settings['locked'] == true
          ? const WelcomePage()
          : _Shell(demo: widget.demo),
    ),
  );
}

class _RecoveryPage extends StatelessWidget {
  final String error;
  const _RecoveryPage(this.error);
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: PageList(
        children: [
          const SizedBox(height: 80),
          EmptyState(
            '账本暂时无法打开',
            error,
            icon: Icons.folder_off_outlined,
            action: FilledButton(
              onPressed: () => openPage(context, const BackupPage()),
              child: const Text('从备份恢复'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Shell extends StatefulWidget {
  final bool demo;
  const _Shell({required this.demo});
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  late final List<Widget> _pages = [
    HomePage(onBills: () => select(2), onStats: () => select(1)),
    const StatsPage(),
    const BillsPage(),
    const ProfilePage(),
  ];
  final _visited = <int>{0};
  final _tabViewKey = GlobalKey(debugLabel: 'main-tabs');
  int index = 0;

  void select(int value) {
    if (value == index) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _visited.add(value);
      index = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final colors = WalletColors.of(context);
    final views = IndexedStack(
      key: _tabViewKey,
      index: index,
      children: List.generate(
        _pages.length,
        (i) => _visited.contains(i)
            ? TickerMode(
                enabled: i == index,
                child: RepaintBoundary(child: _pages[i]),
              )
            : const SizedBox.shrink(),
      ),
    );
    return PopScope(
      canPop: index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) select(0);
      },
      child: Scaffold(
        extendBody: true,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              if (widget.demo)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  color: mint.withValues(alpha: .12),
                  child: const Text(
                    '演示模式 · 示例数据，不会写入你的账本',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: mint),
                  ),
                ),
              Expanded(
                child: wide
                    ? Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 20, 4, 24),
                            child: GlassPanel(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: NavigationRail(
                                selectedIndex: index,
                                backgroundColor: Colors.transparent,
                                indicatorColor: primary.withValues(alpha: .14),
                                onDestinationSelected: select,
                                labelType: NavigationRailLabelType.all,
                                leading: Padding(
                                  padding: const EdgeInsets.only(
                                    top: 20,
                                    bottom: 28,
                                  ),
                                  child: FloatingActionButton.small(
                                    tooltip: '记一笔',
                                    backgroundColor: primary,
                                    foregroundColor: Colors.white,
                                    onPressed: () => openPage(
                                      context,
                                      const TransactionEditor(),
                                      modal: true,
                                    ),
                                    child: const Icon(Icons.add_rounded),
                                  ),
                                ),
                                destinations: const [
                                  NavigationRailDestination(
                                    icon: Icon(
                                      Icons.home_outlined,
                                      key: Key('nav-0'),
                                    ),
                                    selectedIcon: Icon(Icons.home_rounded),
                                    label: Text('首页'),
                                  ),
                                  NavigationRailDestination(
                                    icon: Icon(
                                      Icons.donut_large_rounded,
                                      key: Key('nav-1'),
                                    ),
                                    label: Text('统计'),
                                  ),
                                  NavigationRailDestination(
                                    icon: Icon(
                                      Icons.receipt_long_outlined,
                                      key: Key('nav-2'),
                                    ),
                                    label: Text('账单'),
                                  ),
                                  NavigationRailDestination(
                                    icon: Icon(
                                      Icons.person_outline_rounded,
                                      key: Key('nav-3'),
                                    ),
                                    label: Text('我的'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(child: views),
                        ],
                      )
                    : views,
              ),
            ],
          ),
        ),
        bottomNavigationBar: wide
            ? null
            : SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: GlassPanel(
                    radius: 30,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 7,
                    ),
                    child: Row(
                      children: [
                        _nav(0, Icons.home_outlined, Icons.home_rounded, '首页'),
                        _nav(
                          1,
                          Icons.donut_large_rounded,
                          Icons.donut_large_rounded,
                          '统计',
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: SizedBox.square(
                            dimension: 52,
                            child: FloatingActionButton(
                              heroTag: 'main-add',
                              tooltip: '记一笔',
                              elevation: 0,
                              backgroundColor: colors.dark
                                  ? primary
                                  : colors.ink,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                              onPressed: () => openPage(
                                context,
                                const TransactionEditor(),
                                modal: true,
                              ),
                              child: const Icon(Icons.add_rounded, size: 29),
                            ),
                          ),
                        ),
                        _nav(
                          2,
                          Icons.receipt_long_outlined,
                          Icons.receipt_long_rounded,
                          '账单',
                        ),
                        _nav(
                          3,
                          Icons.person_outline_rounded,
                          Icons.person_rounded,
                          '我的',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _nav(int value, IconData icon, IconData selected, String label) =>
      Expanded(
        child: Semantics(
          selected: value == index,
          child: InkWell(
            key: Key('nav-$value'),
            onTap: () => select(value),
            borderRadius: BorderRadius.circular(24),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              padding: const EdgeInsets.symmetric(vertical: 7),
              decoration: BoxDecoration(
                color: value == index
                    ? primary.withValues(
                        alpha: WalletColors.of(context).dark ? .22 : .09,
                      )
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    value == index ? selected : icon,
                    color: value == index
                        ? primary
                        : WalletColors.of(context).secondary,
                    size: 24,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: value == index
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: value == index
                          ? primary
                          : WalletColors.of(context).secondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
