import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/domain/models.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/services/payment_notifications.dart';
import 'package:fin_dash/ui/design.dart';
import 'package:fin_dash/ui/payment_notifications_page.dart';
import 'helpers.dart';

class ConnectionBridge implements NotificationBridge {
  bool granted = true, enabled = true, connected = false;
  bool connectOnRequest = true;
  int requests = 0;
  final calls = <String>[];
  bool batteryUnrestricted = false;
  bool failSettings = false;
  @override
  bool get supported => true;
  @override
  Future<dynamic> call(String method, [Json? arguments]) async {
    calls.add(method);
    if (method == 'openBatterySettings' || method == 'openAppSettings') {
      if (failSettings) throw StateError('Settings unavailable');
      return null;
    }
    if (method == 'peek') return [];
    if (method == 'reconnect') {
      requests++;
      connected = connectOnRequest;
    }
    if (method == 'status') {
      return {
        'enabled': enabled,
        'granted': granted,
        'connected': connected,
        'batteryUnrestricted': batteryUnrestricted,
      };
    }
    return null;
  }
}

void main() {
  Future<void> showPage(WidgetTester tester, ConnectionBridge bridge) async {
    final store = await emptyStore();
    await tester.pumpWidget(
      AppScope(
        store: store,
        ai: AiService(store, TestVault()),
        child: MaterialApp(
          theme: walletTheme(Brightness.light),
          home: PaymentNotificationsPage(
            notifications: PaymentNotifications(store, bridge: bridge),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('reconnect confirms real connection without toggling capture', (
    tester,
  ) async {
    final bridge = ConnectionBridge();
    await showPage(tester, bridge);
    await tester.tap(find.byKey(const Key('payment-reconnect')));
    await tester.pumpAndSettle();
    expect(bridge.requests, 1);
    expect(bridge.enabled, true);
    expect(find.text('监听已连接，可以接收新的支付通知'), findsOneWidget);
  });

  testWidgets('request alone is not reported as a successful connection', (
    tester,
  ) async {
    final bridge = ConnectionBridge()..connectOnRequest = false;
    await showPage(tester, bridge);
    await tester.tap(find.byKey(const Key('payment-reconnect')));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('系统暂未连接'), findsOneWidget);
    expect(find.text('监听已连接，可以接收新的支付通知'), findsNothing);
    expect(tester.takeException(), null);
  });

  testWidgets('missing permission disables reconnect', (tester) async {
    final bridge = ConnectionBridge()..granted = false;
    await showPage(tester, bridge);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('payment-reconnect')))
          .onPressed,
      null,
    );
    expect(bridge.requests, 0);
  });

  testWidgets('background guidance opens settings only after a user tap', (
    tester,
  ) async {
    final bridge = ConnectionBridge()..batteryUnrestricted = true;
    await showPage(tester, bridge);
    expect(find.text('电池优化：已允许不受限制'), findsOneWidget);
    expect(find.textContaining('无需保持 App 界面开启'), findsOneWidget);
    expect(bridge.calls, ['peek', 'status']);
    await tester.ensureVisible(
      find.byKey(const Key('payment-battery-settings')),
    );
    await tester.tap(find.byKey(const Key('payment-battery-settings')));
    await tester.pumpAndSettle();
    expect(bridge.calls.last, 'openBatterySettings');
    await tester.tap(find.byKey(const Key('payment-app-settings')));
    await tester.pumpAndSettle();
    expect(bridge.calls.last, 'openAppSettings');
    final calls = bridge.calls.length;
    await tester.pump(const Duration(minutes: 5));
    expect(bridge.calls.length, calls);
    expect(tester.takeException(), null);
  });

  testWidgets('settings failure keeps the capture page usable', (tester) async {
    final bridge = ConnectionBridge()..failSettings = true;
    await showPage(tester, bridge);
    await tester.ensureVisible(find.byKey(const Key('payment-app-settings')));
    await tester.tap(find.byKey(const Key('payment-app-settings')));
    await tester.pumpAndSettle();
    expect(bridge.enabled, true);
    expect(tester.takeException(), null);
  });
}
