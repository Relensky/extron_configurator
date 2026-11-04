import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/schema_field_builder.dart';
import 'package:extron_configurator/ui_schema.dart';

/// active_event_space is false (3hr), true (6hr) or "test" (2min).
void main() {
  late UiSchema schema;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

  AppStateProvider room(dynamic value) {
    final p = AppStateProvider(autoLoadSettings: false)..uiSchema = schema;
    p.roomConfig
      ..clear()
      ..addAll(<String, dynamic>{
        'SYSTEM_SETUP': {'active_event_space': value},
      });
    return p;
  }

  Future<void> pump(WidgetTester tester, AppStateProvider p) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => SchemaFieldBuilder.buildField(
                context: context,
                provider: p,
                sectionKey: 'SYSTEM_SETUP',
                fieldKey: 'active_event_space',
                value: p.roomConfig['SYSTEM_SETUP']['active_event_space'],
              )!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, String label) async {
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  test('the default is still false', () {
    expect(schema.systemDefaults['active_event_space'], false);
  });

  testWidgets('a saved false shows as Normal', (tester) async {
    await pump(tester, room(false));
    expect(find.text('Normal (3hr)'), findsOneWidget);
    expect(find.textContaining('not in schema'), findsNothing);
  });

  testWidgets('a saved "test" shows as Test', (tester) async {
    await pump(tester, room('test'));
    expect(find.text('Test (2min)'), findsOneWidget);
    expect(find.textContaining('not in schema'), findsNothing);
  });

  testWidgets('Test saves the string, Event and Normal save booleans',
      (tester) async {
    final p = room(false);
    await pump(tester, p);

    await pick(tester, 'Test (2min)');
    expect(p.roomConfig['SYSTEM_SETUP']['active_event_space'], 'test');

    await pick(tester, 'Event (6hr)');
    expect(p.roomConfig['SYSTEM_SETUP']['active_event_space'], true);

    await pick(tester, 'Normal (3hr)');
    expect(p.roomConfig['SYSTEM_SETUP']['active_event_space'], false);
  });
}
