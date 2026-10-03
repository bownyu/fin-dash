import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fin_dash/services/ai_service.dart';
import 'package:fin_dash/ui/design.dart';
import 'package:fin_dash/ui/editors.dart';
import 'helpers.dart';

void main() {
  testWidgets('keyboard animation does not rebuild the transaction form', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final store = await emptyStore();
    await store.saveAccount(bank);
    await tester.pumpWidget(
      AppScope(
        store: store,
        ai: AiService(store, TestVault()),
        child: MaterialApp(
          theme: walletTheme(Brightness.light),
          home: const TransactionEditor(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('amount-input')), '12.50');
    final title = find.byKey(const Key('transaction-title'));
    await tester.showKeyboard(title);
    const composing = TextEditingValue(
      text: '午餐pin',
      selection: TextSelection.collapsed(offset: 5),
      composing: TextRange(start: 2, end: 5),
    );
    tester.testTextInput.updateEditingValue(composing);
    await tester.pump();
    final keypad = tester.element(find.byKey(const Key('transaction-keypad')));
    var editorBuilds = 0;
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      if (element.widget is TransactionEditor) editorBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previous);
    for (final height in [
      30.0,
      70.0,
      130.0,
      210.0,
      290.0,
      340.0,
      290.0,
      210.0,
      130.0,
      70.0,
      30.0,
      0.0,
    ]) {
      tester.view.viewInsets = FakeViewPadding(bottom: height);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.widget<TextFormField>(title).controller!.value, composing);
      final save = find.byKey(const Key('save-transaction'));
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(844 - height));
      expect(
        find.text('1').hitTestable(),
        height == 0 ? findsOneWidget : findsNothing,
      );
    }
    expect(
      editorBuilds,
      0,
      reason: 'IME insets must only rebuild the keyboard dock, not the form',
    );
    expect(
      tester.element(find.byKey(const Key('transaction-keypad'))),
      same(keypad),
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('amount-input')))
          .controller!
          .text,
      '12.50',
    );
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '午餐拼单',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.pump();
    expect(tester.widget<TextFormField>(title).controller!.text, '午餐拼单');
    expect(tester.takeException(), null);
  });
}
