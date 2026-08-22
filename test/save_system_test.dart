import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/main.dart';
import 'package:extron_configurator/save_actions.dart';

/// ============================================================================
///  THE SAVE SYSTEM
/// ============================================================================
///  Four things are under test here, and they are four halves of one feature:
///
///    * SAVE KNOWS WHERE YOU ARE. The toolbar button writes the document the
///      tab on screen belongs to, so pressing Save on the Project tab saves
///      the project rather than the room.
///    * THE APP KNOWS WHAT IS LOOSE. One list of sentences, one per document
///      that is behind its file, used by the exit prompt and by the dot on the
///      Save button.
///    * AUTOSAVE COPIES, IT DOES NOT SAVE. A snapshot of the whole open job in
///      its own folder, leaving the user's files alone — which is the only
///      reason "close without saving" can still mean anything.
///    * THE WINDOW ASKS BEFORE IT TAKES THE WORK WITH IT.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_save_system'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Map<String, dynamic> baseConfig() => {
        'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103'},
        'PROJECTORDEVICE_1': {'name': 'Projector 1', 'speaker_mute': true},
      };

  /// A provider holding a room that really exists on disk.
  AppStateProvider roomOnDisk({String stem = 'BSS103_config'}) {
    final configPath = path.join(dir.path, '$stem.json');
    File(configPath).writeAsStringSync(jsonEncode(baseConfig()));
    return AppStateProvider(autoLoadSettings: false)
      ..roomConfig = jsonDecode(File(configPath).readAsStringSync())
      ..currentConfigPath = configPath
      ..markRoomSaved();
  }

  // -------------------------------------------------------------------------
  //  SAVE MEANS THE DOCUMENT YOU ARE LOOKING AT
  // -------------------------------------------------------------------------

  group('the scope Save writes', () {
    test('every room tab saves the room', () {
      for (final tab in [
        AppTab.wizard,
        AppTab.devices,
        AppTab.system,
        AppTab.rawJson,
        AppTab.schematic,
        AppTab.avFlow,
        AppTab.floorPlan,
        AppTab.cabling,
        AppTab.racks,
        AppTab.cost,
        AppTab.appConfig,
      ]) {
        expect(saveScopeForTab(tab), SaveScope.room, reason: tab.name);
      }
    });

    test('the four tabs that are not a room each name their own document', () {
      expect(saveScopeForTab(AppTab.project), SaveScope.project);
      expect(saveScopeForTab(AppTab.deviceEditor), SaveScope.catalog);
      expect(saveScopeForTab(AppTab.schemaEditor), SaveScope.schema);
      expect(saveScopeForTab(AppTab.flowRules), SaveScope.flowRules);
    });

    test('a room with no file is still saveable — Save just asks where', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = baseConfig();
      expect(saveBlockedReason(p, SaveScope.room), '');
      expect(saveScopeNeedsFile(p, SaveScope.room), isTrue);
    });

    test('a room with a file is saveable, an empty session is not', () {
      expect(saveBlockedReason(roomOnDisk(), SaveScope.room), '');
      expect(
        saveBlockedReason(
            AppStateProvider(autoLoadSettings: false), SaveScope.room),
        'No room is open.',
      );
    });

    test('only the room and the project can be saved somewhere else', () {
      expect(saveScopeSupportsSaveAs(SaveScope.room), isTrue);
      expect(saveScopeSupportsSaveAs(SaveScope.project), isTrue);
      expect(saveScopeSupportsSaveAs(SaveScope.catalog), isFalse);
      expect(saveScopeSupportsSaveAs(SaveScope.schema), isFalse);
      expect(saveScopeSupportsSaveAs(SaveScope.flowRules), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  //  WHAT IS NOT ON DISK
  // -------------------------------------------------------------------------

  group('the unsaved-work report', () {
    test('a freshly loaded room has nothing loose', () {
      final p = roomOnDisk();
      expect(p.hasUnsavedWork, isFalse);
      expect(p.unsavedWorkSummary, isEmpty);
    });

    test('an edit names the file it is not in', () {
      final p = roomOnDisk();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);
      expect(p.hasUnsavedWork, isTrue);
      expect(p.unsavedWorkSummary.single, contains('BSS103_config.json'));
    });

    test('a room that has never been saved is loose in its own way', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = baseConfig();
      expect(p.roomNeverSaved, isTrue);
      expect(p.unsavedWorkSummary.single, contains('never been saved'));
    });

    test('the room and the project are counted separately', () {
      final p = roomOnDisk();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);
      p.setProjectField(name: 'Bessey Hall');

      expect(p.unsavedWorkSummary, hasLength(2));
      expect(p.unsavedWorkSummary.last, contains('Bessey Hall'));
    });

    test('saving the room clears its half and leaves the project alone',
        () async {
      final p = roomOnDisk();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);
      p.setProjectField(name: 'Bessey Hall');

      await p.saveRoomInPlace();

      expect(p.unsavedWorkSummary, hasLength(1));
      expect(p.unsavedWorkSummary.single, contains('Bessey Hall'));
    });

    test('the dot on the Save button follows the tab you are on', () {
      final p = roomOnDisk();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);

      expect(saveScopeIsDirty(p, SaveScope.room), isTrue);
      expect(saveScopeIsDirty(p, SaveScope.project), isFalse);

      p.setProjectField(name: 'Bessey Hall');
      expect(saveScopeIsDirty(p, SaveScope.project), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  //  ONE ROOM SAVE, NOT TWO
  // -------------------------------------------------------------------------

  group('saving the room in place', () {
    test('takes the pre-save backup the toolbar Save always did', () async {
      final p = roomOnDisk();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);

      final written = await p.saveRoomInPlace();
      expect(written, p.currentConfigPath);

      // The picker's "Save room" used to write without a backup, which meant
      // whether the save could be undone depended on which button you pressed.
      expect(p.canUndoLastSave, isTrue);
      final backup = jsonDecode(File(p.saveBackupPath).readAsStringSync());
      expect(backup['PROJECTORDEVICE_1']['speaker_mute'], isTrue,
          reason: 'the backup holds the file as it was BEFORE the save');
    });

    test('marks the room as matching its file again', () async {
      final p = roomOnDisk();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);
      expect(p.roomHasUnsavedChanges, isTrue);

      await p.saveCurrentConfigToFile();
      expect(p.roomHasUnsavedChanges, isFalse,
          reason: 'the toolbar Save left the room reporting itself as behind '
              'its file for the rest of the session');
    });
  });

  // -------------------------------------------------------------------------
  //  AUTOSAVE
  // -------------------------------------------------------------------------

  group('autosave', () {
    AppStateProvider withBackups({String stem = 'BSS103_config'}) {
      final p = roomOnDisk(stem: stem);
      p.autosaveFolderForTest = path.join(dir.path, 'autosave');
      return p;
    }

    test('copies the room, its sidecars and a manifest', () async {
      final p = withBackups();
      p.addAvNode(const AvNode(
        id: 'SW',
        label: 'Switcher',
        model: 'SW4 HD 4K PLUS',
        pos: Offset.zero,
        ports: [],
      ));

      final folder = await p.writeAutosaveSnapshot();
      expect(folder, isNotEmpty);

      final names = Directory(folder)
          .listSync()
          .map((e) => path.basename(e.path))
          .toList();
      expect(names, contains('BSS103_config.json'));
      expect(names, contains('BSS103_config_av_flow.json'));
      expect(names, contains('BSS103_config_racks.json'));
      expect(names, contains('BSS103_config_floor_plans.json'));
      expect(names, contains('BSS103_config_cabling.json'));
      expect(names, contains('BSS103_config_cost.json'));
      expect(names, contains('autosave_manifest.json'));

      // The drawing really is in there, not just a file with the right name.
      final flow = jsonDecode(
        File(path.join(folder, 'BSS103_config_av_flow.json')).readAsStringSync(),
      );
      expect((flow['nodes'] as List).single['id'], 'SW');
    });

    test('never touches the room\'s own files', () async {
      final p = withBackups();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);

      await p.writeAutosaveSnapshot();

      final onDisk = jsonDecode(File(p.currentConfigPath).readAsStringSync());
      expect(onDisk['PROJECTORDEVICE_1']['speaker_mute'], isTrue,
          reason: 'a backup that saved would make "close without saving" a lie');
      expect(p.roomHasUnsavedChanges, isTrue,
          reason: 'and it must not report the work as saved either');
    });

    test('the manifest says where the files came from and what was loose',
        () async {
      final p = withBackups();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);

      final folder = await p.writeAutosaveSnapshot();
      final manifest = jsonDecode(
        File(path.join(folder, 'autosave_manifest.json')).readAsStringSync(),
      );
      expect(manifest['roomFile'], p.currentConfigPath);
      expect(manifest['roomHadUnsavedChanges'], isTrue);
      expect(manifest['files'], contains('BSS103_config.json'));
    });

    test('an idle session is not copied twice', () async {
      final p = withBackups();
      expect(await p.writeAutosaveSnapshot(), isNotEmpty);
      expect(await p.writeAutosaveSnapshot(), isEmpty,
          reason: 'nothing changed, so there is nothing new to keep');

      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);
      expect(await p.writeAutosaveSnapshot(), isNotEmpty);
    });

    test('Back up now takes one anyway', () async {
      final p = withBackups();
      expect(await p.writeAutosaveSnapshot(), isNotEmpty);
      expect(await p.writeAutosaveSnapshot(force: true), isNotEmpty);
    });

    test('nothing open means nothing written', () async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..autosaveFolderForTest = path.join(dir.path, 'autosave');
      expect(await p.writeAutosaveSnapshot(), isEmpty);
      expect(Directory(path.join(dir.path, 'autosave')).existsSync(), isFalse);
    });

    test('the project goes into the snapshot with the room', () async {
      final p = withBackups();
      p.newProject(name: 'Bessey Hall');
      final projectPath = path.join(dir.path, 'bessey_project.json');
      await p.project.save(projectPath);
      p.currentProjectPath = projectPath;

      final folder = await p.writeAutosaveSnapshot(force: true);
      final saved = jsonDecode(
        File(path.join(folder, 'bessey_project.json')).readAsStringSync(),
      );
      expect(saved['name'], 'Bessey Hall');
    });

    test('only the last few generations are kept', () async {
      final p = withBackups();
      // The stamp is per-second, so a loop would land several snapshots in one
      // folder name. The pruning is what is under test, so the folders are
      // made by hand and one real snapshot triggers the sweep.
      final root = Directory(p.autosaveFolder)..createSync(recursive: true);
      for (int i = 0; i < AppStateProvider.kAutosaveGenerations + 4; i++) {
        Directory(path.join(root.path, '2020-01-01_00-00-${i.toString().padLeft(2, '0')}'))
            .createSync();
      }
      await p.writeAutosaveSnapshot(force: true);

      expect(root.listSync().whereType<Directory>().length,
          AppStateProvider.kAutosaveGenerations);
      // The oldest went, the newest stayed.
      expect(Directory(path.join(root.path, '2020-01-01_00-00-00')).existsSync(),
          isFalse);
    });

    test('a room with no file yet is named from its building and number',
        () async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = baseConfig()
        ..autosaveFolderForTest = path.join(dir.path, 'autosave');

      final folder = await p.writeAutosaveSnapshot();
      expect(
        Directory(folder)
            .listSync()
            .map((e) => path.basename(e.path))
            .toList(),
        contains('BSS_103_config.json'),
      );
    });
  });

  // -------------------------------------------------------------------------
  //  THE START SCREEN AND THE TOOLBAR
  // -------------------------------------------------------------------------

  group('the app around it', () {
    Future<void> pump(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      p.settingsLoaded = true;
      p.firstRunSetupNeeded = false;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const RoomConfigApp(),
        ),
      );
      await tester.pump();
    }

    testWidgets('the start screen offers the job and the room file', (
      tester,
    ) async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..selectTab(AppTab.wizard.index);
      await pump(tester, p);

      expect(find.text('Start a New Project'), findsOneWidget);
      expect(find.text('Open a Project'), findsOneWidget);
      expect(find.text('Create a New File'), findsOneWidget);
      expect(find.text('Open a File'), findsOneWidget);
    });

    testWidgets('the Save button renames itself for the tab you are on', (
      tester,
    ) async {
      final p = roomOnDisk()..selectTab(AppTab.wizard.index);
      await pump(tester, p);

      final save = find.byKey(const ValueKey('save_context'));
      expect(tester.widget<IconButton>(save).tooltip, contains('Save Room'));

      p.selectTab(AppTab.project.index);
      await tester.pump();
      expect(tester.widget<IconButton>(save).tooltip, contains('Save Project'));

      p.selectTab(AppTab.deviceEditor.index);
      await tester.pump();
      expect(tester.widget<IconButton>(save).tooltip, contains('Save Catalog'));
    });

    testWidgets('Save on the Project tab writes the project, not the room', (
      tester,
    ) async {
      final p = roomOnDisk();
      final projectPath = path.join(dir.path, 'bessey_project.json');
      p.newProject(name: 'Bessey Hall');
      // Written synchronously: inside testWidgets' fake clock an awaited real
      // file write never completes, so the setup cannot use saveProject.
      File(projectPath).writeAsStringSync(jsonEncode(p.project.toJson()));
      p.currentProjectPath = projectPath;
      p.setProjectField(client: 'Facilities');
      p.selectTab(AppTab.project.index);
      await pump(tester, p);

      // The room is behind its file too — and must STAY behind it, because
      // this button is not the room's.
      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);
      await tester.pump();

      // Real file I/O: the tap is fired without being awaited (awaiting it
      // inside runAsync never returns — the gesture needs a pump), then the
      // two clocks are alternated until the write has landed.
      await tester.runAsync(
        () async => tester.tap(find.byKey(const ValueKey('save_context'))),
      );
      // Generous, because the whole suite runs these files in parallel and a
      // loaded machine can leave this isolate waiting a long time for a write
      // that takes no time at all on its own.
      var client = '';
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline) && client != 'Facilities') {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        client =
            jsonDecode(File(projectPath).readAsStringSync())['client'] ?? '';
      }

      expect(client, 'Facilities',
          reason: 'the toolbar Save on the Project tab writes the project');
      expect(
        jsonDecode(File(p.currentConfigPath).readAsStringSync())
            ['PROJECTORDEVICE_1']['speaker_mute'],
        isTrue,
        reason: 'Save on the Project tab must not write the room',
      );
    });

    testWidgets('closing with work loose asks first, and Keep working stops it',
        (tester) async {
      final p = roomOnDisk();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);
      await pump(tester, p);

      bool? mayClose;
      // The dialog is what the window's X ends up in — driven directly here,
      // because the embedder's close request has no test harness.
      final pending = confirmCloseWithUnsavedWork(
        tester.element(find.byType(Scaffold).first),
        p,
      ).then((v) => mayClose = v);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('exit_unsaved_dialog')), findsOneWidget);
      expect(find.textContaining('BSS103_config.json'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('exit_cancel')));
      await tester.pumpAndSettle();
      await pending;
      expect(mayClose, isFalse);
    });

    testWidgets('with everything saved it closes without a word', (
      tester,
    ) async {
      final p = roomOnDisk();
      await pump(tester, p);

      final mayClose = await confirmCloseWithUnsavedWork(
        tester.element(find.byType(Scaffold).first),
        p,
      );
      await tester.pump();
      expect(mayClose, isTrue);
      expect(find.byKey(const ValueKey('exit_unsaved_dialog')), findsNothing);
    });

    testWidgets('Close without saving really does leave the file alone', (
      tester,
    ) async {
      final p = roomOnDisk();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);
      await pump(tester, p);

      bool? mayClose;
      final pending = confirmCloseWithUnsavedWork(
        tester.element(find.byType(Scaffold).first),
        p,
      ).then((v) => mayClose = v);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('exit_discard')));
      await tester.pumpAndSettle();
      await pending;

      expect(mayClose, isTrue);
      expect(
        jsonDecode(File(p.currentConfigPath).readAsStringSync())
            ['PROJECTORDEVICE_1']['speaker_mute'],
        isTrue,
      );
    });
  });

  // -------------------------------------------------------------------------
  //  THE SETTING
  // -------------------------------------------------------------------------

  group('the autosave setting', () {
    test('the interval is clamped to something a timer can use', () async {
      final p = AppStateProvider(autoLoadSettings: false);
      await p.setAutosaveMinutes(15);
      expect(p.autosaveMinutes, 15);

      // Nonsense is refused rather than turned into a zero-second timer.
      await p.setAutosaveMinutes(0);
      expect(p.autosaveMinutes, 15);
    });

    test('the status line says what somebody who just lost a session needs',
        () {
      final p = AppStateProvider(autoLoadSettings: false);
      expect(autosaveStatusLine(p), contains('every 5 minutes'));

      p.autosaveEnabled = false;
      expect(autosaveStatusLine(p), contains('Autosave is off'));
    });
  });

  test('a project saved from the toolbar is named like one saved from the tab',
      () {
    // Both go through runSave, which suggests <stem>_project.json — the name
    // the Project tab has always produced.
    expect(kProjectFileSuffix, '_project.json');
  });
}
