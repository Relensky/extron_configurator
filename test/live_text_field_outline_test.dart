import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:extron_configurator/live_text_field.dart';

/// The outline on a name nobody typed: there while the box is empty, gone
/// the moment something is typed, back when it is cleared.
void main() {
  InputBorder? border(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).decoration?.enabledBorder;

  testWidgets('outlined only while empty', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveTextField(
            fieldId: 'name',
            initial: '',
            hint: 'Display 1',
            hintIsValue: true,
            outlineColor: Colors.orange,
            outlineOnlyWhenEmpty: true,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    expect(border(tester), isNotNull, reason: 'auto name: outlined');

    await tester.enterText(find.byType(TextField), 'Lectern display');
    await tester.pump();
    expect(border(tester), isNull, reason: 'a typed name is a normal box');

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(border(tester), isNotNull, reason: 'blanked: auto name again');

    // Let any save timer the box holds run out.
    await tester.pump(const Duration(seconds: 5));
  });
}
