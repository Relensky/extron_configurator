import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/live_text_field.dart';

/// A box marked [LiveTextField.warn] - a 0% tax rate - is outlined in red.
void main() {
  Future<InputDecoration> decorationOf(WidgetTester tester, bool warn) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LiveTextField(
          fieldId: 'tax',
          initial: '0',
          label: 'Tax rate',
          warn: warn,
          onChanged: (_) {},
        ),
      ),
    ));
    return tester.widget<TextField>(find.byType(TextField)).decoration!;
  }

  testWidgets('warn draws the error color', (tester) async {
    final d = await decorationOf(tester, true);
    final error = Theme.of(tester.element(find.byType(TextField)))
        .colorScheme
        .error;
    expect(d.enabledBorder?.borderSide.color, error);
    expect(d.focusedBorder?.borderSide.color, error);
  });

  testWidgets('no warn keeps the usual border', (tester) async {
    final d = await decorationOf(tester, false);
    expect(d.enabledBorder, isNull);
  });
}
