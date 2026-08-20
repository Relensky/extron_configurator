import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/schema_field_builder.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  SOURCE SUBSTITUTIONS, WITHOUT TYPING BRACES
/// ============================================================================
///  `source_overrides` is the rule for the second image that is nearly the
///  room's: the confidence monitor that mirrors the extended desktop while the
///  PC is up and follows the room for everything else. One row — pc shows
///  pc_extended — and nothing else about the screen changes.
///
///  It is an OBJECT, so the device tab (which renders scalars) hid it and left
///  it to the Raw JSON tab. That put the one screen rule a tech is most likely
///  to want behind hand-typed JSON, where a stray comma takes the whole config
///  down and a misspelt source name silently unroutes a screen. The
///  'source_map' field type draws it instead: one row of two dropdowns per
///  substitution, both filled from the room's own sources.
/// ============================================================================
void main() {
  late UiSchema schema;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

  AppStateProvider room({dynamic overrides}) {
    final p = AppStateProvider(autoLoadSettings: false)..uiSchema = schema;
    p.roomConfig
      ..clear()
      ..addAll(<String, dynamic>{
        'SYSTEM_SETUP': {
          'input_pc': '1',
          'input_pc_extended': '2',
          'input_doc_cam': '6',
          'input_wireless': '',
        },
        'PROJECTORDEVICE_2': {
          'name': 'Confidence monitor',
          'source_overrides': overrides ?? <String, dynamic>{},
        },
      });
    return p;
  }

  Map<String, dynamic> stored(AppStateProvider p) =>
      Map<String, dynamic>.from(
          (p.roomConfig['PROJECTORDEVICE_2'] as Map)['source_overrides'] as Map);

  Future<void> pump(WidgetTester tester, AppStateProvider p) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer<AppStateProvider>(
              builder: (context, watched, _) => SingleChildScrollView(
                child: SchemaFieldBuilder.buildField(
                  context: context,
                  provider: watched,
                  sectionKey: 'PROJECTORDEVICE_2',
                  fieldKey: 'source_overrides',
                  value: (watched.roomConfig['PROJECTORDEVICE_2']
                      as Map)['source_overrides'],
                )!,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an empty map says so, rather than showing nothing at all',
      (tester) async {
    await pump(tester, room());
    expect(find.textContaining('No substitutions'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
  });

  testWidgets('a stored substitution comes back as two dropdowns',
      (tester) async {
    final p = room(overrides: {'pc': 'pc_extended'});
    await pump(tester, p);

    expect(find.byType(DropdownButtonFormField<String>), findsNWidgets(2));
    expect(find.text('pc'), findsOneWidget);
    expect(find.text('pc_extended'), findsOneWidget);
  });

  testWidgets('adding a row writes a real map, keyed on a source this room has',
      (tester) async {
    final p = room();
    await pump(tester, p);

    await tester.tap(find.text('Add substitution'));
    await tester.pumpAndSettle();

    final map = stored(p);
    expect(map, hasLength(1));
    expect(roomSourceNames(Map<String, dynamic>.from(
            p.roomConfig['SYSTEM_SETUP'] as Map)),
        contains(map.keys.single));
    // The right-hand side is the tech's to pick, and until they do the row is
    // flagged rather than left looking finished.
    expect(map.values.single, '');
    expect(find.textContaining('leaves this screen unrouted'), findsOneWidget);
  });

  testWidgets('picking the right-hand source completes the substitution',
      (tester) async {
    final p = room(overrides: {'pc': ''});
    await pump(tester, p);

    // The second dropdown is the "this screen shows" side.
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('pc_extended').last);
    await tester.pumpAndSettle();

    expect(stored(p), {'pc': 'pc_extended'});
  });

  testWidgets('the left-hand side keeps its place when it is changed',
      (tester) async {
    // Renaming a key by removing and re-adding it would drop the row to the
    // bottom of the list under the tech's cursor.
    final p = room(overrides: {'pc': 'pc_extended', 'doc_cam': 'pc'});
    await pump(tester, p);

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('pc_extended').last);
    await tester.pumpAndSettle();

    expect(stored(p).keys.toList(), ['pc_extended', 'doc_cam']);
    expect(stored(p)['pc_extended'], 'pc_extended',
        reason: 'only the left side changed; the row kept what it shows');
  });

  testWidgets('a row can be removed', (tester) async {
    final p = room(overrides: {'pc': 'pc_extended'});
    await pump(tester, p);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(stored(p), isEmpty);
    expect(find.textContaining('No substitutions'), findsOneWidget);
  });

  testWidgets('the left side never offers a source another row already claims',
      (tester) async {
    final p = room(overrides: {'pc': 'pc_extended'});
    await pump(tester, p);

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();

    // Its own key, plus the two sources not yet substituted. 'pc' appears
    // twice — the closed field and the open menu item.
    expect(find.text('doc_cam'), findsOneWidget);
    expect(find.text('pc_extended'), findsWidgets);
    expect(find.text('pc'), findsNWidgets(2));
  });

  testWidgets('every source already substituted leaves nothing to add',
      (tester) async {
    final p = room(overrides: {
      'pc': 'pc_extended',
      'pc_extended': 'pc',
      'doc_cam': 'pc',
    });
    await pump(tester, p);

    final button = tester.widget<TextButton>(find.byType(TextButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('a name the room cannot show is kept, and flagged',
      (tester) async {
    // Written by hand on the Raw JSON tab, or carried in from a room whose
    // source was renamed. Both are things to see rather than to overwrite the
    // moment the field is drawn.
    final p = room(overrides: {'pc': 'doccam'});
    await pump(tester, p);

    expect(find.textContaining('not one of this room'), findsOneWidget);
    expect(stored(p), {'pc': 'doccam'});
  });

  testWidgets('a room with no sources filled in says so instead of nothing',
      (tester) async {
    final p = room();
    (p.roomConfig['SYSTEM_SETUP'] as Map).clear();
    await pump(tester, p);

    expect(find.textContaining('no sources filled in yet'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byType(TextButton)).onPressed,
        isNull);
  });
}
