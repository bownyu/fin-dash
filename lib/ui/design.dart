import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../data/wallet_store.dart';
import '../domain/models.dart';
import '../domain/command_context.dart';
import '../services/ai_service.dart';

const primary = Color(0xFFA75F43);
const mint = Color(0xFF527563);
const coral = Color(0xFFAA6257);
const muted = Color(0xFF77736C);
const darkBg = Color(0xFF1C1C1A);
const darkSurface = Color(0xFF282825);
const palette = [
  '#FF8B7B',
  '#4ECDC4',
  '#A78BFA',
  '#F5B85B',
  '#EC89BF',
  '#6BB5FF',
  '#58C5AB',
  '#94A3B8',
];
Color colorOf(String hex) => Color(
  int.tryParse(hex.replaceFirst('#', ''), radix: 16) != null
      ? 0xFF000000 | int.parse(hex.replaceFirst('#', ''), radix: 16)
      : 0xFF94A3B8,
);
Color txColor(TxType type) => switch (type) {
  TxType.income => mint,
  TxType.expense => coral,
  TxType.transfer => primary,
};
String formSnapshot(List<Object?> values) => jsonEncode(values);

/// Editable amounts remain visible; read-only ledger summaries use this scope.
String privateMoney(BuildContext context, int value, {bool symbol = true}) =>
    AppScope.storeOf(context).data.settings['visible'] == false
    ? (symbol ? '¥ ••••••' : '••••••')
    : money(value, symbol: symbol);

String privateFinancialText(BuildContext context, String text) =>
    AppScope.storeOf(context).data.settings['visible'] == false
    ? text.replaceAll(RegExp(r'[-+]?¥\s*[\d,]+(?:\.\d{2})?'), '¥ ••••••')
    : text;
IconData iconOf(String name) => switch (name) {
  'restaurant' || 'fastfood' => Icons.restaurant_rounded,
  'directions_car' || 'local_taxi' => Icons.directions_car_rounded,
  'directions_bus' => Icons.directions_bus_rounded,
  'shopping_bag' || 'shopping_cart' => Icons.shopping_bag_rounded,
  'home' || 'cottage' => Icons.home_rounded,
  'movie' || 'music_note' => Icons.movie_rounded,
  'bolt' => Icons.bolt_rounded,
  'medical_services' => Icons.medical_services_rounded,
  'account_balance_wallet' => Icons.account_balance_wallet_rounded,
  'account_balance' => Icons.account_balance_rounded,
  'credit_card' => Icons.credit_card_rounded,
  'payments' => Icons.payments_rounded,
  'local_cafe' => Icons.local_cafe_rounded,
  'card_giftcard' => Icons.card_giftcard_rounded,
  'work' => Icons.work_rounded,
  'family_restroom' => Icons.family_restroom_rounded,
  'trending_up' || 'candlestick_chart' => Icons.trending_up_rounded,
  'savings' => Icons.savings_rounded,
  'chat' || 'chat_bubble' => Icons.chat_bubble_rounded,
  'phone_android' => Icons.phone_android_rounded,
  'lock' => Icons.lock_rounded,
  'card_membership' => Icons.card_membership_rounded,
  'local_gas_station' => Icons.local_gas_station_rounded,
  'pie_chart' => Icons.pie_chart_rounded,
  'diamond' => Icons.diamond_rounded,
  'currency_exchange' => Icons.currency_exchange_rounded,
  'currency_bitcoin' => Icons.currency_bitcoin_rounded,
  'timeline' => Icons.timeline_rounded,
  'spa' => Icons.spa_rounded,
  'store' => Icons.store_rounded,
  'swap_horiz' => Icons.swap_horiz_rounded,
  'receipt_long' || 'receipt' => Icons.receipt_long_rounded,
  _ => Icons.more_horiz_rounded,
};
ThemeData walletTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors = WalletColors(dark);
  final ink = colors.ink;
  final secondaryInk = colors.secondary;
  final scheme =
      ColorScheme.fromSeed(seedColor: primary, brightness: brightness).copyWith(
        primary: colors.accent,
        onPrimary: dark ? darkBg : Colors.white,
        secondary: mint,
        surface: colors.surface,
        onSurface: ink,
        onSurfaceVariant: secondaryInk,
        outline: secondaryInk.withValues(alpha: .3),
        outlineVariant: secondaryInk.withValues(alpha: .14),
      );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: colors.background,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: WalletPageTransitionsBuilder(),
        TargetPlatform.fuchsia: WalletPageTransitionsBuilder(),
        TargetPlatform.windows: WalletPageTransitionsBuilder(),
        TargetPlatform.linux: WalletPageTransitionsBuilder(),
        TargetPlatform.iOS: WalletPageTransitionsBuilder(cupertino: true),
        TargetPlatform.macOS: WalletPageTransitionsBuilder(cupertino: true),
      },
    ),
    fontFamily: 'SF Pro Display',
    fontFamilyFallback: const [
      'Segoe UI',
      'PingFang SC',
      'Microsoft YaHei',
      'sans-serif',
    ],
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontFamily: 'SF Pro Display',
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
    ),
    textTheme: TextTheme(
      headlineLarge: TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w800,
        letterSpacing: -.8,
        color: ink,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        letterSpacing: -.5,
        color: ink,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      bodyLarge: TextStyle(fontSize: 16, color: ink, height: 1.5),
      bodyMedium: TextStyle(fontSize: 14, color: ink, height: 1.5),
      bodySmall: TextStyle(fontSize: 12, color: secondaryInk, height: 1.5),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.inset,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        textStyle: const TextStyle(
          fontFamily: 'SF Pro Display',
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      side: BorderSide.none,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      elevation: 8,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        side: const WidgetStatePropertyAll(BorderSide.none),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? primary.withValues(alpha: dark ? .24 : .12)
              : secondaryInk.withValues(alpha: .06),
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? primary : secondaryInk,
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    ),
    dividerTheme: DividerThemeData(color: colors.border),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
  );
}

/// Color and surface roles shared by both appearances.
class WalletColors {
  final bool dark;
  const WalletColors(this.dark);
  static WalletColors of(BuildContext context) =>
      WalletColors(Theme.of(context).brightness == Brightness.dark);
  Color get background => dark ? darkBg : const Color(0xFFF5F3EE);
  Color get ink => dark ? const Color(0xFFEAE7E0) : const Color(0xFF302E2A);
  Color get secondary =>
      dark ? const Color(0xFFAAA69D) : const Color(0xFF77736C);
  Color get border => dark ? const Color(0xFF3D3D37) : const Color(0xFFE2DED6);
  Color get surface => dark ? darkSurface : const Color(0xFFFCFBF8);
  Color get panel => surface.withValues(alpha: dark ? .84 : .76);
  Color get glassBorder => Colors.white.withValues(alpha: dark ? .16 : .88);
  List<Color> get glassTints => dark
      ? [
          const Color(0xFF45453E).withValues(alpha: .8),
          darkSurface.withValues(alpha: .72),
        ]
      : [Colors.white.withValues(alpha: .88), surface.withValues(alpha: .64)];
  Color get inset => dark ? const Color(0xFF33332E) : const Color(0xFFEDEAE3);
  Color get accent => dark ? const Color(0xFFD3A18A) : primary;
  Color get income => dark ? const Color(0xFF96B5A2) : mint;
  Color get expense => dark ? const Color(0xFFD5A097) : coral;
}

class WalletBackdrop extends StatelessWidget {
  final Widget child;
  const WalletBackdrop({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    final colors = WalletColors.of(context);
    return ColoredBox(
      color: colors.background,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(.9, -.85),
                  radius: 1.3,
                  colors: [
                    (colors.dark ? const Color(0xFF555548) : Colors.white)
                        .withValues(alpha: colors.dark ? .34 : .85),
                    colors.background.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-1, .35),
                  radius: 1.2,
                  colors: [
                    const Color(
                      0xFFB4AA98,
                    ).withValues(alpha: colors.dark ? .07 : .18),
                    colors.background.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Each route owns an opaque backdrop, including while it enters or leaves.
/// Sliding an isolated layer avoids blending two pages of text together.
class WalletPageTransitionsBuilder extends PageTransitionsBuilder {
  final bool cupertino;
  const WalletPageTransitionsBuilder({this.cupertino = false});

  @override
  Duration get transitionDuration => cupertino
      ? const CupertinoPageTransitionsBuilder().transitionDuration
      : const Duration(milliseconds: 240);

  @override
  Duration get reverseTransitionDuration => cupertino
      ? const CupertinoPageTransitionsBuilder().reverseTransitionDuration
      : const Duration(milliseconds: 200);

  @override
  DelegatedTransitionBuilder? get delegatedTransition => cupertino
      ? const CupertinoPageTransitionsBuilder().delegatedTransition
      : null;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final page = RepaintBoundary(child: WalletBackdrop(child: child));
    if (MediaQuery.disableAnimationsOf(context)) return page;
    if (cupertino) {
      return const CupertinoPageTransitionsBuilder().buildTransitions(
        route,
        context,
        animation,
        secondaryAnimation,
        page,
      );
    }
    final offset = route.fullscreenDialog
        ? const Offset(0, 1)
        : Offset(
            Directionality.of(context) == ui.TextDirection.rtl ? -1 : 1,
            0,
          );
    return SlideTransition(
      position: animation.drive(
        Tween(
          begin: offset,
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
      ),
      child: page,
    );
  }
}

/// Real background blur is confined to the clipped floating navigation.
class GlassPanel extends StatelessWidget {
  static final _blur = ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10);
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = 28,
  });
  @override
  Widget build(BuildContext context) {
    final colors = WalletColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: colors.dark ? .18 : .06),
            blurRadius: 22,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: _blur,
          child: RepaintBoundary(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: colors.glassTints,
                ),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: colors.glassBorder),
              ),
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class HeroPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const HeroPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
  });
  @override
  Widget build(BuildContext context) {
    final colors = WalletColors.of(context);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors.glassTints,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: colors.glassBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: colors.dark ? .1 : .025),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class OverviewGrid extends StatelessWidget {
  final Widget hero;
  final List<Widget> tiles;
  const OverviewGrid({super.key, required this.hero, required this.tiles});
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (tiles.isEmpty) return hero;
      if (constraints.maxWidth >= 620) {
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 5, child: hero),
              const SizedBox(width: 16),
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    for (var i = 0; i < tiles.length; i++) ...[
                      if (i > 0) const SizedBox(height: 12),
                      Expanded(
                        child: SizedBox(
                          width: double.infinity,
                          child: tiles[i],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      }
      return Column(
        children: [
          hero,
          const SizedBox(height: 14),
          Row(
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: tiles[i]),
              ],
            ],
          ),
        ],
      );
    },
  );
}

class AppScope extends StatefulWidget {
  final WalletStore store;
  final AiService ai;
  final Widget child;
  const AppScope({
    super.key,
    required this.store,
    required this.ai,
    required this.child,
  });
  static AppScopeData of(BuildContext context) =>
      InheritedModel.inheritFrom<AppScopeData>(context)!;
  static WalletStore storeOf(
    BuildContext context, {
    Set<WalletDomain>? domains,
  }) {
    final selected = domains ?? WalletDomain.values.toSet();
    for (final domain in selected) {
      InheritedModel.inheritFrom<AppScopeData>(context, aspect: domain);
    }
    return context.getInheritedWidgetOfExactType<AppScopeData>()!.store;
  }

  @override
  State<AppScope> createState() => _AppScopeState();
}

class _AppScopeState extends State<AppScope> {
  final versions = {for (final domain in WalletDomain.values) domain: 0};
  final callbacks = <WalletDomain, VoidCallback>{};
  int runtime = 0;
  void refreshRuntime() {
    if (mounted) setState(() => runtime++);
  }

  @override
  void initState() {
    super.initState();
    for (final domain in WalletDomain.values) {
      callbacks[domain] = () {
        if (mounted) setState(() => versions[domain] = versions[domain]! + 1);
      };
      widget.store.domainUpdates[domain]!.addListener(callbacks[domain]!);
    }
    widget.store.runtimeUpdates.addListener(refreshRuntime);
  }

  @override
  void didUpdateWidget(covariant AppScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store == widget.store) return;
    for (final domain in WalletDomain.values) {
      oldWidget.store.domainUpdates[domain]!.removeListener(callbacks[domain]!);
      widget.store.domainUpdates[domain]!.addListener(callbacks[domain]!);
      versions[domain] = versions[domain]! + 1;
    }
    oldWidget.store.runtimeUpdates.removeListener(refreshRuntime);
    widget.store.runtimeUpdates.addListener(refreshRuntime);
    runtime++;
  }

  @override
  void dispose() {
    for (final domain in WalletDomain.values) {
      widget.store.domainUpdates[domain]!.removeListener(callbacks[domain]!);
    }
    widget.store.runtimeUpdates.removeListener(refreshRuntime);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppScopeData(
    store: widget.store,
    ai: widget.ai,
    versions: Map.of(versions),
    runtime: runtime,
    child: widget.child,
  );
}

class AppScopeData extends InheritedModel<WalletDomain> {
  final WalletStore store;
  final AiService ai;
  final Map<WalletDomain, int> versions;
  final int runtime;
  WalletStore get notifier => store;
  const AppScopeData({
    super.key,
    required this.store,
    required this.ai,
    required this.versions,
    required this.runtime,
    required super.child,
  });
  @override
  bool updateShouldNotify(AppScopeData oldWidget) =>
      runtime != oldWidget.runtime ||
      versions.entries.any((e) => oldWidget.versions[e.key] != e.value);
  @override
  bool updateShouldNotifyDependent(
    AppScopeData oldWidget,
    Set<WalletDomain> dependencies,
  ) => dependencies.any((d) => versions[d] != oldWidget.versions[d]);
}

/// False while the caller's route is covered or still animating, so a double
/// tap never stacks two pages or sheets.
bool routeReady(BuildContext context) {
  final current = ModalRoute.of(context);
  return current == null ||
      (current.isCurrent && current.animation?.isAnimating != true);
}

Future<T?> openPage<T>(
  BuildContext context,
  Widget page, {
  bool modal = false,
}) {
  if (!routeReady(context)) return Future<T?>.value();
  FocusManager.instance.primaryFocus?.unfocus();
  return Navigator.of(
    context,
  ).push<T>(MaterialPageRoute(builder: (_) => page, fullscreenDialog: modal));
}

void toast(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
Future<bool> perform(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    if (context.mounted && success != null) toast(context, success);
    return true;
  } catch (e) {
    if (context.mounted) {
      toast(context, e is FormatException ? e.message : '操作未保存，请重试。$e');
    }
    return false;
  }
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String message, {
  String action = '确认',
  String cancelLabel = '取消',
  bool destructive = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(cancelLabel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(
              action,
              style: TextStyle(color: destructive ? coral : primary),
            ),
          ),
        ],
      ),
    ) ??
    false;

class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.color,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: color ?? WalletColors.of(context).panel,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: WalletColors.of(context).border),
    ),
    child: child,
  );
}

class SectionTitle extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const SectionTitle(this.title, {super.key, this.action, this.onAction});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        if (action != null)
          TextButton(onPressed: onAction, child: Text(action!)),
      ],
    ),
  );
}

class EmptyState extends StatelessWidget {
  final String title, detail;
  final IconData icon;
  final Widget? action;
  const EmptyState(
    this.title,
    this.detail, {
    super.key,
    this.icon = Icons.receipt_long_rounded,
    this.action,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 20),
    child: Column(
      children: [
        Container(
          padding: const EdgeInsets.all(19),
          decoration: BoxDecoration(
            color: primary.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Icon(icon, size: 35, color: primary),
        ),
        const SizedBox(height: 18),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          detail,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (action != null)
          Padding(padding: const EdgeInsets.only(top: 18), child: action!),
      ],
    ),
  );
}

/// Keeps per-frame keyboard metrics out of the form/page owning the controls.
class KeyboardInsetPadding extends StatelessWidget {
  final Widget child;
  const KeyboardInsetPadding({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: child,
  );
}

class PageList extends StatelessWidget {
  final List<Widget> children;
  const PageList({super.key, required this.children});
  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.fromLTRB(
      20,
      20,
      20,
      MediaQuery.paddingOf(context).bottom + 32,
    ),
    children: children,
  );
}

/// Headers and footers stay simple; large data sections create only visible rows.
class LazyPageList extends StatelessWidget {
  final List<Widget> leading, trailing;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  const LazyPageList({
    super.key,
    this.leading = const [],
    this.trailing = const [],
    required this.itemCount,
    required this.itemBuilder,
  });

  @override
  Widget build(BuildContext context) => ListView.builder(
    padding: EdgeInsets.fromLTRB(
      20,
      20,
      20,
      MediaQuery.paddingOf(context).bottom + 32,
    ),
    itemCount: leading.length + itemCount + trailing.length,
    itemBuilder: (context, index) {
      if (index < leading.length) return leading[index];
      final row = index - leading.length;
      if (row < itemCount) return itemBuilder(context, row);
      return trailing[row - itemCount];
    },
  );
}

class MoneyText extends StatelessWidget {
  final int value;
  final double size;
  final Color? color;
  final bool respectPrivacy;
  const MoneyText(
    this.value, {
    super.key,
    this.size = 24,
    this.color,
    this.respectPrivacy = true,
  });
  @override
  Widget build(BuildContext context) {
    final visible =
        !respectPrivacy ||
        AppScope.storeOf(context).data.settings['visible'] != false;
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      // Hiding or showing amounts cross-fades instead of snapping.
      child: AnimatedSwitcher(
        duration: Duration(
          milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 180,
        ),
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.centerLeft,
          children: [...previous, ?current],
        ),
        child: visible
            ? TweenAnimationBuilder<int>(
                key: const ValueKey(true),
                tween: IntTween(begin: value, end: value),
                duration: Duration(
                  milliseconds: MediaQuery.disableAnimationsOf(context)
                      ? 0
                      : 220,
                ),
                builder: (_, amount, _) => Text(
                  money(amount),
                  style: TextStyle(
                    fontSize: size,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.5,
                    color: color,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
              )
            : Text(
                '¥ ••••••',
                key: const ValueKey(false),
                style: TextStyle(
                  fontSize: size,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
      ),
    );
  }
}

class Avatar extends StatelessWidget {
  final String? value;
  final double size;
  const Avatar(this.value, {super.key, this.size = 44});
  @override
  Widget build(BuildContext context) {
    Widget content = Text(
      value != null &&
              !value!.startsWith('data:') &&
              !value!.startsWith('http') &&
              value!.length < 12
          ? value!
          : '🌿',
      style: TextStyle(fontSize: size * .47),
    );
    if (value?.startsWith('data:image') == true) {
      try {
        content = Image.memory(
          base64Decode(value!.split(',').last),
          width: size,
          height: size,
          fit: BoxFit.cover,
        );
      } catch (_) {
        /* Keep fallback. */
      }
    }
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: mint.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(size * .35),
      ),
      child: content,
    );
  }
}

class IconBadge extends StatelessWidget {
  final String icon;
  final Color color;
  final double size;
  const IconBadge(this.icon, this.color, {super.key, this.size = 44});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(size * .3),
    ),
    child: Icon(iconOf(icon), color: color, size: size * .48),
  );
}

class TransactionRow extends StatelessWidget {
  final LedgerTx tx;
  final VoidCallback? onTap, onLongPress;
  final bool? selected;
  final bool neutralIcon;
  const TransactionRow(
    this.tx, {
    super.key,
    this.onTap,
    this.onLongPress,
    this.selected,
    this.neutralIcon = false,
  });
  @override
  Widget build(BuildContext context) {
    final store = AppScope.storeOf(context);
    final accounts = tx.type == TxType.transfer
        ? '${store.account(tx.fromId)?.name ?? '未关联'} → ${store.account(tx.toId)?.name ?? '未关联'}'
        : store.account(tx.accountId)?.name ?? '未关联账户';
    final category = store.data.categories
        .where((c) => c.name == tx.category && c.type == tx.type)
        .firstOrNull;
    final color = neutralIcon
        ? WalletColors.of(context).secondary
        : tx.type == TxType.transfer
        ? primary
        : colorOf(category?.color ?? '#94A3B8');
    return Material(
      color: selected == true
          ? primary.withValues(alpha: .1)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 2),
          child: Row(
            children: [
              if (selected != null)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Icon(
                    selected!
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selected! ? primary : muted,
                  ),
                ),
              IconBadge(
                tx.type == TxType.transfer
                    ? 'swap_horiz'
                    : category?.icon ?? tx.icon,
                color,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tx.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${tx.category} · $accounts',
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        '${tx.type == TxType.expense
                            ? '−'
                            : tx.type == TxType.income
                            ? '+'
                            : ''}${privateMoney(context, tx.amount, symbol: false)}',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: tx.type == TxType.income
                              ? WalletColors.of(context).income
                              : tx.type == TxType.transfer
                              ? primary
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      DateFormat('HH:mm').format(tx.date),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Map<String, List<LedgerTx>> groupTxs(List<LedgerTx> list) {
  final result = <String, List<LedgerTx>>{};
  for (final t in list) {
    result.putIfAbsent(dayKey(t.date), () => []).add(t);
  }
  return result;
}

String dateHeading(DateTime date) {
  final today = DateTime.now();
  if (dayKey(date) == dayKey(today)) return '今天';
  if (dayKey(date) == dayKey(today.subtract(const Duration(days: 1)))) {
    return '昨天';
  }
  const weekdays = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
  return '${date.month}月${date.day}日 ${weekdays[date.weekday - 1]}';
}
