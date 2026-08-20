import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/schema_editor_view.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  EDITING THE SCHEMA IN THE APP
/// ============================================================================
///  ui_schema.json decides what every config key looks like on the Devices and
///  System tabs: its label, its description, whether it is a switch or a
///  dropdown and what the dropdown offers, which device families exist at all.
///  It has always been editable, in a text editor, against a config file open
///  in another window to see which keys were still undescribed.
///
///  What is checked here is the two things that make an in-app editor safe to
///  use on a file people share: that the document survives a round trip with
///  everything this build does not understand still in it, and that "described
///  or not" is measured against a real config file rather than guessed.
/// ============================================================================
void main() {
  late Directory dir;
  late String schemaPath;
  late String templatePath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('schema_editor_test_');
    schemaPath = path.join(dir.path, 'ui_schema.json');
    templatePath = path.join(dir.path, 'config.json');
    File(templatePath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {
        'gve_bldg': 'BSS',
        'gve_room': '103',
        'gui_mic_mix': 'No',
        // The key nothing describes yet — the one this whole tab is for.
        'gui_new_feature': 'Off',
      },
      'PROJECTORDEVICE_1': {
        'name': 'Projector 1',
        'model': 'VPL-PHZ60',
        'input': 'HDBaseT',
      },
    }));
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, dynamic> schemaDoc() => {
        '__comment': 'Written by hand, and it should stay written.',
        'fields': {
          'gui_mic_mix': {
            'type': 'dropdown',
            'label': 'Microphone mix',
            'options': ['Yes', 'No'],
          },
        },
        'device_fields': {
          'PROJECTORDEVICE_*': {
            'input': {'type': 'text', 'label': 'Connector plugged into'},
          },
        },
        'something_a_later_build_understands': {'and this one does not': true},
      };

  AppStateProvider provider({bool withFile = true}) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..templateFilePath = templatePath;
    if (withFile) {
      File(schemaPath).writeAsStringSync(jsonEncode(schemaDoc()));
      p.uiSchemaPath = schemaPath;
    }
    return p;
  }

  /// The same room, with the schema already in memory.
  ///
  /// A widget test runs in fake async, where real file I/O never completes —
  /// so the schema is built from the document here rather than read off the
  /// disk, which is what [UiSchema.load] does with it anyway.
  AppStateProvider loadedProvider({bool withFile = true}) {
    final p = provider(withFile: withFile);
    if (withFile) {
      p.uiSchema = UiSchema.fromDoc(schemaDoc())..source = schemaPath;
    }
    return p;
  }

  group('the document', () {
    test('is kept verbatim, including what this build cannot read', () async {
      final p = provider();
      await p.loadUiSchema();

      expect(p.uiSchema.rawDoc['__comment'], isNotNull,
          reason: 'a file explains itself, and the explanation is not noise');
      expect(p.uiSchema.rawDoc['something_a_later_build_understands'],
          isNotNull);
      expect(p.uiSchema.specFor('gui_mic_mix')?.label, 'Microphone mix');
      expect(
        p.uiSchema
            .specFor('input', sectionKey: 'PROJECTORDEVICE_1')
            ?.label,
        'Connector plugged into',
      );
    });

    test('an edit is applied to the app immediately, and saved on demand',
        () async {
      final p = provider();
      await p.loadUiSchema();

      final doc = jsonDecode(jsonEncode(p.uiSchema.rawDoc))
          as Map<String, dynamic>;
      (doc['fields'] as Map)['gui_new_feature'] = {
        'type': 'bool',
        'label': 'The new feature',
      };
      p.applyUiSchemaDoc(doc);

      // In memory, before anything is written: the tabs follow it now.
      expect(p.uiSchema.specFor('gui_new_feature')?.label, 'The new feature');

      expect(await p.saveUiSchema(), schemaPath);
      final onDisk =
          jsonDecode(File(schemaPath).readAsStringSync()) as Map<String, dynamic>;
      expect((onDisk['fields'] as Map)['gui_new_feature'], isNotNull);
      expect(onDisk['__comment'], isNotNull,
          reason: 'saving is the file it read, with the edit in it');
      expect(onDisk['something_a_later_build_understands'], isNotNull);

      // And it reads back the same way on the next launch.
      final again = AppStateProvider(autoLoadSettings: false)
        ..uiSchemaPath = schemaPath;
      await again.loadUiSchema();
      expect(again.uiSchema.specFor('gui_new_feature')?.type, 'bool');
    });

    test('a document with no fields object is refused, not half-applied',
        () async {
      final p = provider();
      await p.loadUiSchema();
      final before = p.uiSchema.specFor('gui_mic_mix')?.label;

      expect(() => p.applyUiSchemaDoc({'device_types': {}}),
          throwsA(isA<FormatException>()));
      expect(p.uiSchema.specFor('gui_mic_mix')?.label, before);
    });

    test('device families defined in the file replace the built-in list', () {
      final schema = UiSchema.fromDoc({
        'fields': {},
        'device_types': {
          'dev_projectors': {'prefix': 'PROJECTORDEVICE_', 'label': 'Displays'},
          'dev_lasers': {'prefix': 'LASERDEVICE_', 'label': 'Lasers', 'max': 2},
        },
      });

      expect(schema.deviceTypes.map((t) => t.countKey),
          ['dev_projectors', 'dev_lasers']);
      expect(schema.deviceTypeForSection('LASERDEVICE_2')?.label, 'Lasers');
      expect(schema.deviceTypeForSection('CAMERADEVICE_1'), isNull,
          reason: 'defining families at all replaces the built-in list');
    });
  });

  group('the tab', () {
    Future<void> pump(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: SchemaEditorView())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('measures the schema against the default config file',
        (tester) async {
      final p = loadedProvider();
      await pump(tester, p);

      // Every SYSTEM_SETUP key in the template is listed, described or not.
      expect(find.text('gui_mic_mix'), findsOneWidget);
      expect(find.text('gui_new_feature'), findsOneWidget);
      expect(find.textContaining('of 4 keys described'), findsOneWidget);
      expect(find.text('Describe'), findsWidgets);
    });

    testWidgets('describing a key writes a field into the document',
        (tester) async {
      final p = loadedProvider();
      await pump(tester, p);

      // The undescribed key, and the button beside it.
      final row = find.byKey(const ValueKey('schema_coverage_gui_new_feature'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: row, matching: find.text('Describe')));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Label'), 'The new feature');
      // The dialog's Save, not the toolbar's.
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(ElevatedButton, 'Save'),
      ));
      await tester.pumpAndSettle();

      expect(p.uiSchema.specFor('gui_new_feature')?.label, 'The new feature');
      expect((p.uiSchema.rawDoc['fields'] as Map)['gui_new_feature'],
          isNotNull);
      // Not written yet — the file is only touched by Save.
      final onDisk =
          jsonDecode(File(schemaPath).readAsStringSync()) as Map<String, dynamic>;
      expect((onDisk['fields'] as Map)['gui_new_feature'], isNull);
    });

    testWidgets('the raw view applies a whole document, and says why not',
        (tester) async {
      final p = loadedProvider();
      await pump(tester, p);

      await tester.tap(find.byKey(const ValueKey('schema_section_raw')));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const ValueKey('schema_raw_json')), '{ not json');
      await tester.tap(find.byKey(const ValueKey('schema_apply_raw')));
      await tester.pumpAndSettle();
      expect(find.textContaining('FormatException'), findsWidgets);
      expect(p.uiSchema.specFor('gui_mic_mix')?.label, 'Microphone mix',
          reason: 'a document that will not parse changes nothing');

      await tester.enterText(
        find.byKey(const ValueKey('schema_raw_json')),
        jsonEncode({
          'fields': {
            'gui_mic_mix': {'label': 'Mic mixing'},
          },
        }),
      );
      await tester.tap(find.byKey(const ValueKey('schema_apply_raw')));
      await tester.pumpAndSettle();
      expect(p.uiSchema.specFor('gui_mic_mix')?.label, 'Mic mixing');
    });

    testWidgets('a schema that came from no file will not overwrite one',
        (tester) async {
      // Nothing has been read, so the document is empty — writing it would
      // replace whatever schema is on the share with nothing at all.
      final p = loadedProvider(withFile: false);
      await pump(tester, p);

      await tester.tap(find.byKey(const ValueKey('schema_editor_save')));
      await tester.pumpAndSettle();

      expect(find.textContaining('built-in schema'), findsOneWidget);
      expect(File(schemaPath).existsSync(), isFalse);
    });
  });
}
