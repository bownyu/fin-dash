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
  @override
  bool get supported => true;
  @override
  Future<dynamic> call(String method, [Json? arguments]) async {
    if (method == 'peek') return [];
    if (method == 'reconnect') {
      requests++;
      connected = connectOnRequest;
    }
    if (method == 'status') {
      return {'enabled': enabled, 'granted': granted, 'connected': connected};
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
}
