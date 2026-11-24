import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:extron_configurator/live_text_field.dart';

/// A default name shown as a hint can be copied and edited: clicking in puts
/// it in the box, all selected; left unchanged, the box is empty again.
void main() {
  Future<List<String>> pumpBox(WidgetTester tester) async {
    final changes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              LiveTextField(
                fieldId: 'name',
                initial: '',
                hint: 'Display 1',
                hintIsValue: true,
                hintEditable: true,
                lazy: true,
                onChanged: changes.add,
              ),
              const TextField(key: ValueKey('other')),
            ],
          ),
        ),
      ),
    );
    return changes;
  }

  TextEditingController box(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField).first).controller!;

  testWidgets('click in fills and selects the default', (tester) async {
    final changes = await pumpBox(tester);
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.pump();
    expect(box(tester).text, 'Display 1');
    expect(box(tester).selection.textInside(box(tester).text), 'Display 1');

    // Left untouched: empty again, and nothing written.
    await tester.tap(find.byKey(const ValueKey('other')));
    await tester.pump(const Duration(seconds: 1));
    expect(box(tester).text, '');
    expect(changes.where((c) => c.isNotEmpty), isEmpty);
  });

  testWidgets('the default edited is a typed name', (tester) async {
    final changes = await pumpBox(tester);
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'Display 1 left');
    await tester.tap(find.byKey(const ValueKey('other')));
    await tester.pump(const Duration(seconds: 1));
    expect(box(tester).text, 'Display 1 left');
    expect(changes.last, 'Display 1 left');
  });
}
