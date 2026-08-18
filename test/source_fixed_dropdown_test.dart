import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/schema_field_builder.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  PINNING A SCREEN TO A SOURCE IT CAN ACTUALLY SHOW
/// ============================================================================
///  `source_fixed` was a text box, and the name typed into it has to match the
///  panel's own source name exactly. Get it wrong — 'doccam' for 'doc_cam',
///  'Doc Cam', a source this room does not carry — and the screen is simply
///  never routed, with nothing anywhere saying why.
///
///  The room already knows the answer: every source it has is an input_ key in
///  SYSTEM_SETUP holding the switcher input it is wired to. So the list is a
///  read, not a menu somebody has to maintain.
/// ============================================================================
void main() {
  late UiSchema schema;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

  group('reading the room own sources', () {
    test('a key with a value is a source, a blank one is not', () {
      expect(
        roomSourceNames({
          'input_pc': '1',
          'input_pc_extended': '2',
          'input_hdmi': '4',
          'input_doc_cam': '6',
          'input_wireless': '',
          'input_dvd': null,
        }),
        ['doc_cam', 'hdmi', 'pc', 'pc_extended'],
      );
    });

    test('the plate takes the name this room calls it', () {
      expect(roomSourceNames({'input_usb': '5'}), ['usb']);
      expect(
        roomSourceNames({'input_usb': '5', 'gui_usb_or_vga': 'VGA'}),
        ['vga'],
      );
    });

    test('a sub switcher and a station feed are not source buttons', () {
      expect(
        roomSourceNames({
          'input_pc': '1',
          'input_sub_switcher': '9',
          'input_station_1': '10',
          'input_station_1_laptop': '11',
        }),
        ['pc'],
      );
    });

    test('a room that has filled nothing in offers nothing', () {
      expect(roomSourceNames(const {}), isEmpty);
    });
  });

  group('the field on the display tab', () {
    AppStateProvider room({String fixed = ''}) {
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
            'source_follow': false,
            'source_fixed': fixed,
          },
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
                  sectionKey: 'PROJECTORDEVICE_2',
                  fieldKey: 'source_fixed',
                  value: p.roomConfig['PROJECTORDEVICE_2']['source_fixed'],
                )!,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers this room sources and nothing else', (tester) async {
      final p = room();
      await pump(tester, p);

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();

      expect(find.text('pc'), findsWidgets);
      expect(find.text('pc_extended'), findsWidgets);
      expect(find.text('doc_cam'), findsWidgets);
      // input_wireless is blank: the room does not have one.
      expect(find.text('wireless'), findsNothing);
    });

    testWidgets('picking one writes it', (tester) async {
      final p = room();
      await pump(tester, p);

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('pc_extended').last);
      await tester.pumpAndSettle();

      expect(p.roomConfig['PROJECTORDEVICE_2']['source_fixed'], 'pc_extended');
    });

    testWidgets('and blank is a real choice, not the absence of one',
        (tester) async {
      final p = room(fixed: 'pc');
      await pump(tester, p);

      expect(find.text('Not pinned — this screen is not routed'), findsNothing,
          reason: 'it is an option, not the current value');

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not pinned — this screen is not routed').last);
      await tester.pumpAndSettle();

      expect(p.roomConfig['PROJECTORDEVICE_2']['source_fixed'], '');
    });

    testWidgets('a value the room cannot show is kept, and flagged',
        (tester) async {
      // Either a source nobody has wired up yet or a typo. Both are things to
      // see rather than things to overwrite the moment the field is drawn.
      final p = room(fixed: 'doccam');
      await pump(tester, p);

      expect(find.textContaining('not one of this room'), findsOneWidget);
      expect(p.roomConfig['PROJECTORDEVICE_2']['source_fixed'], 'doccam');
    });
  });
}
