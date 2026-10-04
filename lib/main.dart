import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'data/storage.dart';
import 'data/wallet_store.dart';
import 'services/ai_service.dart';
import 'services/payment_notifications.dart';
import 'ui/design.dart';
import 'ui/editors.dart';
import 'ui/finance_pages.dart';
import 'ui/preferences.dart';
import 'services/voice_widget_runtime.dart';
import 'ui/payment_entry_reminder.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final item in {
      'SenseVoiceSmall · FunAudioLLM / Alibaba Group': 'sensevoice-model.txt',
      'sherpa-onnx · k2-fsa': 'sherpa-onnx.txt',
      'ONNX Runtime · Microsoft': 'onnxruntime.txt',
      'Silero VAD · Silero Team': 'silero-vad.txt',
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        item.key,
      ], await rootBundle.loadString('assets/licenses/${item.value}'));
    }
  });
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
        systemNavigationBarColor: Color(0xFFF5F3EE),
      ),
    );
    runApp(FinDashApp(store: store, ai: ai, demo: demo));
  }

  VoiceWidgetRuntime.install(store, ai, showApp);
  if (!args.contains('widget')) showApp();
  await store.initialize(demo: demo);
  try {
    await ai.actions.recoverInterrupted();
    await ai.tasks.recover();
  } catch (e) {
    store.log('error', '恢复未完成方案失败，已保留原数据：$e');
  }
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
  final NotificationBridge? notificationBridge;
  const FinDashApp({
    super.key,
    required this.store,
    required this.ai,
    this.demo = false,
    this.notificationBridge,
  });
  @override
  State<FinDashApp> createState() => _FinDashAppState();
}

class _FinDashAppState extends State<FinDashApp> {
  static final _lightTheme = walletTheme(Brightness.light);
  static final _darkTheme = walletTheme(Brightness.dark);
  late (bool, String?, Object?, bool, bool) _configuration;
  final _paymentRoutes = RouteObserver<ModalRoute<void>>();

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
      navigatorObservers: [_paymentRoutes],
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
        child: WalletBackdrop(
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
          : PaymentEntryReminder(
              routes: _paymentRoutes,
              bridge: widget.notificationBridge,
              enabled: !widget.demo,
              child: _Shell(demo: widget.demo),
            ),
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

class _ShellState extends State<_Shell> with SingleTickerProviderStateMixin {
  late final _transition = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1,
  );
  late final _tabOpacity = _transition.drive(
    CurveTween(curve: Curves.easeOutCubic),
  );
  late final _tabOffset = _transition.drive(
    Tween(
      begin: const Offset(0, .018),
      end: Offset.zero,
    ).chain(CurveTween(curve: Curves.easeOutCubic)),
  );
  final _billsKey = GlobalKey<BillsPageState>();
  late final List<Widget> _pages = [
    HomePage(onBills: () => select(2), onStats: () => select(1)),
    const StatsPage(),
    BillsPage(key: _billsKey),
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
    // Start even when this destination is mounted for the first time.
    if (MediaQuery.disableAnimationsOf(context)) {
      _transition.value = 1;
    } else {
      _transition.forward(from: 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) _transition.value = 1;
  }

  @override
  void dispose() {
    _transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final colors = WalletColors.of(context);
    final views = FadeTransition(
      key: const Key('main-tab-transition'),
      opacity: _tabOpacity,
      child: SlideTransition(
        position: _tabOffset,
        child: IndexedStack(
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
        ),
      ),
    );
    return PopScope(
      canPop: index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (index == 2 && _billsKey.currentState?.exitSelection() == true) {
            return;
          }
          select(0);
        }
      },
      child: Scaffold(
        extendBody: true,
        backgroundColor: Colors.transparent,
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
                              radius: 20,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: NavigationRail(
                                selectedIndex: index,
                                backgroundColor: Colors.transparent,
                                indicatorColor: colors.inset,
                                selectedIconTheme: IconThemeData(
                                  color: colors.ink,
                                ),
                                selectedLabelTextStyle: Theme.of(context)
                                    .textTheme
                                    .bodySmall!
                                    .copyWith(
                                      color: colors.ink,
                                      fontWeight: FontWeight.w600,
                                    ),
                                unselectedLabelTextStyle: Theme.of(
                                  context,
                                ).textTheme.bodySmall,
                                onDestinationSelected: select,
                                labelType: NavigationRailLabelType.all,
                                leading: Padding(
                                  padding: const EdgeInsets.only(
                                    top: 20,
                                    bottom: 28,
                                  ),
                                  child: FloatingActionButton.small(
                                    tooltip: '记一笔',
                                    elevation: 0,
                                    highlightElevation: 0,
                                    backgroundColor: colors.ink,
                                    foregroundColor: colors.surface,
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
                    radius: 24,
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
                              backgroundColor: colors.ink,
                              foregroundColor: colors.surface,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(17),
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
              duration: Duration(
                milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 220,
              ),
              padding: const EdgeInsets.symmetric(vertical: 7),
              decoration: BoxDecoration(
                color: value == index
                    ? WalletColors.of(context).inset
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    value == index ? selected : icon,
                    color: value == index
                        ? WalletColors.of(context).ink
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
                          ? WalletColors.of(context).ink
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
