import 'package:extron_configurator/form_factor.dart';
import 'package:extron_configurator/live_text_field.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// A note opens in a large editor: a tap on an iPad or iPhone, the expand
/// button on a desktop. Done writes it back; Cancel leaves it.
String boxText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).first).controller!.text;

void main() {
  Future<List<String>> pump(WidgetTester tester) async {
    final saved = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LiveTextField(
          fieldId: 'n',
          initial: 'first line',
          label: 'Notes',
          expandable: true,
          onChanged: (_) {},
          onSubmitted: saved.add,
        ),
      ),
    ));
    return saved;
  }

  testWidgets('a tap on a phone opens the editor, and Done saves',
      (tester) async {
    debugMobileDevice = true;
    addTearDown(() => debugMobileDevice = null);
    final saved = await pump(tester);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('live_text_editor')), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('live_text_editor_box')), 'a\nlong\nnote');
    await tester.tap(find.byKey(const ValueKey('live_text_editor_done')));
    await tester.pumpAndSettle();
    expect(saved, ['a\nlong\nnote']);
    expect(boxText(tester), 'a\nlong\nnote');
  });

  testWidgets('the desktop opens it from its button; Cancel keeps the note',
      (tester) async {
    debugMobileDevice = false;
    addTearDown(() => debugMobileDevice = null);
    final saved = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('live_text_expand')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('live_text_editor_box')), 'changed');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    expect(boxText(tester), 'first line');
  });
}
