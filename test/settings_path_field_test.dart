import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/settings_path_field.dart';

/// A path is applied once typing stops, not on every letter, and the box
/// shows it is reading until the work behind it is done.
void main() {
  Future<AppStateProvider> pump(WidgetTester tester) async {
    final p = AppStateProvider(autoLoadSettings: false);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          SettingsPathField(
            provider: p,
            settingKey: 'documentationPath',
            value: p.documentationPath,
            decoration: const InputDecoration(labelText: 'Docs'),
          ),
          const TextField(key: ValueKey('elsewhere')),
        ]),
      ),
    ));
    return p;
  }

  testWidgets('waits for typing to stop before applying', (tester) async {
    final p = await pump(tester);
    final box = find.byKey(const ValueKey('documentationPath_field'));

    await tester.enterText(box, r'C:\do');
    await tester.pump(const Duration(milliseconds: 300));
    expect(p.documentationPath, '');
    await tester.enterText(box, r'C:\docs');
    await tester.pump(const Duration(milliseconds: 600));
    expect(p.documentationPath, '', reason: 'the wait restarts per key');

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(p.documentationPath, r'C:\docs');
    // The box keeps its text and was not rebuilt under the cursor.
    expect(find.text(r'C:\docs'), findsOneWidget);
  });

  testWidgets('Enter applies at once, and the spinner goes when it is read',
      (tester) async {
    final p = await pump(tester);
    final box = find.byKey(const ValueKey('documentationPath_field'));

    await tester.enterText(box, r'C:\manuals');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(p.documentationPath, r'C:\manuals');

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings_path_reading')), findsNothing);
  });
}
