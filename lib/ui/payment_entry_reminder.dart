import 'package:flutter/material.dart';
import '../services/payment_notifications.dart';
import 'design.dart';
import 'payment_review_page.dart';

/// Sync and remind on app entry, after unlocking and without interrupting an editor.
class PaymentEntryReminder extends StatefulWidget {
  final Widget child;
  final RouteObserver<ModalRoute<void>> routes;
  final NotificationBridge? bridge;
  final bool enabled;
  const PaymentEntryReminder({
    super.key,
    required this.child,
    required this.routes,
    this.bridge,
    this.enabled = true,
  });
  @override
  State<PaymentEntryReminder> createState() => _PaymentEntryReminderState();
}

class _PaymentEntryReminderState extends State<PaymentEntryReminder>
    with WidgetsBindingObserver, RouteAware {
  PaymentNotifications? service;
  ModalRoute<void>? route;
  bool syncing = false,
      waiting = false,
      showing = false,
      foreground = true,
      enterAgain = false;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextRoute = ModalRoute.of<void>(context);
    if (route != nextRoute && nextRoute != null) {
      widget.routes.unsubscribe(this);
      route = nextRoute;
      widget.routes.subscribe(this, nextRoute);
    }
    final store = AppScope.storeOf(context);
    if (service == null || service!.store != store) {
      service = PaymentNotifications(store, bridge: widget.bridge);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) enter();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      foreground = false;
      generation++;
    } else if (state == AppLifecycleState.resumed && !foreground) {
      foreground = true;
      enter();
    }
  }

  @override
  void didPopNext() {
    if (!waiting || showing || !foreground) return;
    // Wait for the outgoing page animation to finish before opening the review sheet.
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (mounted) showWaiting();
    });
  }

  Future<void> enter() async {
    if (!widget.enabled || !mounted || !foreground) return;
    if (syncing) {
      enterAgain = true;
      return;
    }
    final token = ++generation;
    syncing = true;
    try {
      await service!.sync();
    } catch (_) {
      /* Saved candidates remain reviewable even when native ACK fails. */
    } finally {
      syncing = false;
    }
    if (enterAgain && mounted && foreground) {
      enterAgain = false;
      enter();
      return;
    }
    if (!mounted || !foreground || token != generation) return;
    if (showing) return;
    waiting = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showWaiting();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> showWaiting() async {
    if (!waiting ||
        showing ||
        !mounted ||
        !foreground ||
        route?.isCurrent != true) {
      return;
    }
    final store = service!.store;
    if (store.loading ||
        store.startupError != null ||
        store.data.settings['locked'] == true) {
      return;
    }
    waiting = false;
    final ids = service!.pending.map((r) => r['eventId'] as String).toSet();
    if (ids.isEmpty || ids.difference(service!.reminderSeen).isEmpty) return;
    showing = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        routeSettings: const RouteSettings(name: '/payment-entry-review'),
        isScrollControlled: true,
        useSafeArea: true,
        isDismissible: false,
        enableDrag: false,
        builder: (_) => FractionallySizedBox(
          heightFactor: .9,
          child: PaymentReviewPage(notifications: service, reminder: true),
        ),
      );
      if (mounted) {
        try {
          await service!.markReminderSeen(ids);
        } catch (_) {
          /* The persistent homepage entry keeps unfinished records accessible. */
        }
      }
    } finally {
      showing = false;
    }
  }

  @override
  void dispose() {
    generation++;
    widget.routes.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
