import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/flow_rules.dart';
import 'package:extron_configurator/ui_schema.dart';
import 'package:extron_configurator/undo_bar.dart';
import 'package:extron_configurator/undo_history.dart';

/// UNDO ON THE THREE DOCUMENTS ABOUT THE APP ITSELF.
///
/// The catalog, the field schema and the flow rule book are not a room and not
/// a job: they decide how EVERY room behaves. That makes a mistake in one of
/// them wider than a mistake in a room — a connector deleted off a catalog
/// entry changes every drawing that model appears on — and they were the last
/// three editors in the app with no way back.
///
/// What has to hold is what holds for every other history here: a step goes
/// back and forward again, the restore is lossless, and reading a file off
/// disk starts again rather than leaving the last document's steps behind it.
void main() {
  late UiSchema schema;
  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

  AppStateProvider app() => AppStateProvider(autoLoadSettings: false);

  /// Ends the current step, the way changing tab or saving does.
  void step(AppStateProvider p) => p.recordUndoPoint();

  AvDeviceTemplate device(String model, {double price = 100}) =>
      AvDeviceTemplate(
        model: model,
        manufacturer: 'Generic',
        category: 'Display',
        price: price,
        ports: const [],
      );

  group('the catalog', () {
    test('an entry added comes off again, and comes back', () {
      final p = app();
      p.avDeviceLibrary = AvDeviceLibrary.empty();
      p.appDataReplaced(AppDataDocument.catalog);

      p.avDeviceLibrary.upsert(device('DMP 64'));
      p.avDeviceLibraryChanged();

      expect(p.canUndoAppData(AppDataDocument.catalog), isTrue);
      expect(p.undoAppData(AppDataDocument.catalog), isNotEmpty);
      expect(p.avDeviceLibrary.all.any((t) => t.model == 'DMP 64'), isFalse);

      expect(p.redoAppData(AppDataDocument.catalog), isNotEmpty);
      expect(p.avDeviceLibrary.all.any((t) => t.model == 'DMP 64'), isTrue);
    });

    test('an entry removed comes back whole', () {
      final p = app();
      p.avDeviceLibrary = AvDeviceLibrary.empty()
        ..upsert(device('DMP 64', price: 1499));
      p.appDataReplaced(AppDataDocument.catalog);

      p.avDeviceLibrary.remove('DMP 64');
      p.avDeviceLibraryChanged();
      step(p);

      p.undoAppData(AppDataDocument.catalog);

      final back = p.avDeviceLibrary.all.where((t) => t.model == 'DMP 64');
      expect(back, hasLength(1));
      // THE WHOLE ENTRY, not a re-added blank one. A price that came back as
      // zero would be a figure somebody quotes off without checking.
      expect(back.single.price, 1499);
    });

    test('the step is named after the entry that moved', () {
      final p = app();
      p.avDeviceLibrary = AvDeviceLibrary.empty();
      p.appDataReplaced(AppDataDocument.catalog);

      p.avDeviceLibrary.upsert(device('DMP 64'));
      p.avDeviceLibraryChanged();
      step(p);
      expect(p.appDataUndoLabel(AppDataDocument.catalog), 'Add DMP 64');

      p.avDeviceLibrary.remove('DMP 64');
      p.avDeviceLibraryChanged();
      step(p);
      expect(p.appDataUndoLabel(AppDataDocument.catalog), 'Remove DMP 64');
    });

    test('a built-in stays a built-in across a restore', () {
      // THE ONE THING A RESTORE HERE COULD GET QUIETLY WRONG. Only the user's
      // own entries are written to av_devices.json, so a built-in promoted to
      // a custom entry by an undo would start being saved into somebody's
      // file - and an override lost would leave the shipped entry showing in
      // its place with no sign anything had happened.
      final p = app();
      final builtInCount = p.avDeviceLibrary.customCount;
      final total = p.avDeviceLibrary.modelCount;
      step(p);

      p.avDeviceLibrary.upsert(device('Something Custom'));
      p.avDeviceLibraryChanged();
      step(p);
      p.undoAppData(AppDataDocument.catalog);

      expect(p.avDeviceLibrary.modelCount, total);
      expect(p.avDeviceLibrary.customCount, builtInCount);
    });

    test('reading the catalog off disk starts again', () async {
      final p = app();
      p.avDeviceLibrary = AvDeviceLibrary.empty();
      p.appDataReplaced(AppDataDocument.catalog);
      p.avDeviceLibrary.upsert(device('DMP 64'));
      p.avDeviceLibraryChanged();
      step(p);
      expect(p.canUndoAppData(AppDataDocument.catalog), isTrue);

      await p.loadAvDeviceLibrary();

      // A file just read is not an edit to what was there before it, and an
      // Undo that pasted the last catalog over it would be a hazard rather
      // than a safety net.
      expect(p.canUndoAppData(AppDataDocument.catalog), isFalse);
      expect(p.undoAppData(AppDataDocument.catalog), '');
    });
  });

  group('the field schema', () {
    test('an edit to the document goes back', () {
      final p = app()..uiSchema = schema;
      p.appDataReplaced(AppDataDocument.schema);
      final before = p.uiSchema.rawDoc.length;

      p.applyUiSchemaDoc({
        ...p.uiSchema.rawDoc,
        'ZZ_TEST_BLOCK': {'label': 'Only in this test'},
      });
      step(p);
      expect(p.uiSchema.rawDoc.containsKey('ZZ_TEST_BLOCK'), isTrue);

      expect(p.undoAppData(AppDataDocument.schema), isNotEmpty);
      expect(p.uiSchema.rawDoc.containsKey('ZZ_TEST_BLOCK'), isFalse);
      expect(p.uiSchema.rawDoc.length, before);
    });

    test('where the schema came from survives the restore', () {
      // The source is where the document IS, not part of the document. An
      // undo that blanked it would leave Save with nowhere to write.
      final p = app()..uiSchema = schema;
      final source = p.uiSchema.source;
      p.appDataReplaced(AppDataDocument.schema);

      p.applyUiSchemaDoc({...p.uiSchema.rawDoc, 'ZZ_TEST_BLOCK': {}});
      step(p);
      p.undoAppData(AppDataDocument.schema);

      expect(p.uiSchema.source, source);
    });
  });

  group('the flow rule book', () {
    test('an edit goes back, and the drawing is allowed to follow', () {
      final p = app();
      step(p);

      final rules = p.flowRules.toJson();
      p.applyFlowRules(FlowRules.fromJson({
        ...rules,
        'usbSwitchers': [
          {
            'switcher': 'ZZ_TESTDEVICE_1',
            'devicePorts': <String>['ZZ_PORT'],
            'hostPorts': <String>[],
          },
        ],
      }));
      step(p);
      expect(
        p.flowRules.usbSwitchers.any((r) => r.switcher == 'ZZ_TESTDEVICE_1'),
        isTrue,
        reason: 'the rule went in, so there is something to take back',
      );

      // A rule edit only reaches a room already on screen once the routing
      // pass is allowed to run again — the undo has to clear that too, or the
      // drawing keeps obeying the rule that was just taken back.
      p.avRoutedFingerprint = 'drawn already';
      expect(p.undoAppData(AppDataDocument.flowRules), isNotEmpty);
      expect(p.avRoutedFingerprint, isEmpty);
      expect(
        p.flowRules.usbSwitchers.any((r) => r.switcher == 'ZZ_TESTDEVICE_1'),
        isFalse,
      );
    });
  });

  group('the three of them are separate histories', () {
    test('undoing one does not disturb the others', () {
      final p = app()..uiSchema = schema;
      p.avDeviceLibrary = AvDeviceLibrary.empty();
      p.appDataReplaced(AppDataDocument.catalog);

      p.avDeviceLibrary.upsert(device('DMP 64'));
      p.avDeviceLibraryChanged();
      step(p);
      p.applyUiSchemaDoc({...p.uiSchema.rawDoc, 'ZZ_TEST_BLOCK': {}});
      step(p);

      p.undoAppData(AppDataDocument.schema);

      expect(p.uiSchema.rawDoc.containsKey('ZZ_TEST_BLOCK'), isFalse);
      expect(p.avDeviceLibrary.all.any((t) => t.model == 'DMP 64'), isTrue,
          reason: 'the catalog is a different document');
    });

    test('a rebuild that changed nothing leaves all three dark', () {
      final p = app()..uiSchema = schema;
      p.appDataReplaced(AppDataDocument.schema);
      p.notifyListeners();
      p.notifyListeners();

      for (final doc in AppDataDocument.values) {
        expect(p.canUndoAppData(doc), isFalse, reason: kAppDataDocumentNames[doc]);
        expect(p.undoAppData(doc), '', reason: kAppDataDocumentNames[doc]);
      }
    });
  });

  group('how far back they go', () {
    test('sixty, the same as everywhere else', () {
      final p = app();
      p.avDeviceLibrary = AvDeviceLibrary.empty();
      p.appDataReplaced(AppDataDocument.catalog);

      for (var i = 0; i < kUndoDepth + 15; i++) {
        p.avDeviceLibrary.upsert(device('Model $i'));
        p.avDeviceLibraryChanged();
        step(p);
      }

      expect(p.appDataUndoDepth(AppDataDocument.catalog), kUndoDepth);
    });
  });

  group('the title bar knows which of them a tab edits', () {
    test('each editor tab names its own document', () {
      expect(toolbarUndoTarget(AppTab.deviceEditor), ToolbarUndoTarget.catalog);
      expect(toolbarUndoTarget(AppTab.schemaEditor), ToolbarUndoTarget.schema);
      expect(toolbarUndoTarget(AppTab.flowRules), ToolbarUndoTarget.flowRules);
    });

    test('and the tooltip says which one, not just "undo"', () {
      // The failure this guards is the one somebody reported: an undo arrow in
      // the title bar that turned out to be about something else.
      expect(toolbarUndoNoun(ToolbarUndoTarget.catalog), 'catalog');
      expect(toolbarUndoNoun(ToolbarUndoTarget.schema), 'field schema');
      expect(toolbarUndoNoun(ToolbarUndoTarget.flowRules), 'flow rules');
      expect(toolbarUndoNoun(ToolbarUndoTarget.project), 'project');
      expect(toolbarUndoNoun(ToolbarUndoTarget.room), 'room');
    });
  });
}
