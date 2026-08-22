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

  /// A provider holding a room that really exists on disk, in the state a real
  /// open leaves it in.
  ///
  /// The sidecar load at the end is not decoration. It is what tells the
  /// provider that this room's document has been read — and until it has been,
  /// the first tab that lazily reads it re-baselines the room and an edit made
  /// beforehand stops counting as unsaved. Every path in the app does this on
  /// open; a fixture that skipped it would be testing a state the app is never
  /// actually in.
  AppStateProvider roomOnDisk({String stem = 'BSS103_config'}) {
    final configPath = path.join(dir.path, '$stem.json');
    File(configPath).writeAsStringSync(jsonEncode(baseConfig()));
    return AppStateProvider(autoLoadSettings: false)
      ..autosaveFolderForTest = path.join(dir.path, 'recovery')
      ..roomConfig = jsonDecode(File(configPath).readAsStringSync())
      ..currentConfigPath = configPath
      ..loadAvFlowForCurrentConfig();
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
  //  AUTOSAVE — A LIVE WORKING COPY YOU CAN GET BACK
  // -------------------------------------------------------------------------

  group('the recovery copy', () {
    AppStateProvider withBackups({String stem = 'BSS103_config'}) =>
        roomOnDisk(stem: stem);

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
      expect(names, contains(AppStateProvider.kRecoveryManifest));

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
          reason: 'a copy that saved would make "close without saving" a lie');
      expect(p.roomHasUnsavedChanges, isTrue,
          reason: 'and it must not report the work as saved either');
    });

    test('a saved room has nothing worth copying', () async {
      final p = withBackups();
      expect(await p.writeAutosaveSnapshot(), isEmpty,
          reason: 'a copy of a document that matches its file would be offered '
              'back on the next open as a difference that is not there');
      expect(Directory(p.autosaveFolder).existsSync(), isFalse);
    });

    test('the manifest names the file the copy belongs to', () async {
      final p = withBackups();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);

      final folder = await p.writeAutosaveSnapshot();
      final manifest = jsonDecode(
        File(path.join(folder, AppStateProvider.kRecoveryManifest))
            .readAsStringSync(),
      );
      expect(manifest['kind'], 'room');
      expect(manifest['origin'], p.currentConfigPath);
      expect(manifest['configFile'], 'BSS103_config.json');
    });

    test('an idle session is not copied twice', () async {
      final p = withBackups();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);
      expect(await p.writeAutosaveSnapshot(), isNotEmpty);
      expect(await p.writeAutosaveSnapshot(), isEmpty,
          reason: 'nothing changed, so there is nothing new to keep');

      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute_method', 'mute');
      expect(await p.writeAutosaveSnapshot(), isNotEmpty);
    });

    test('two rooms of the same name get their own slots', () {
      final a = path.join(dir.path, 'one', 'config.json');
      final b = path.join(dir.path, 'two', 'config.json');
      expect(AppStateProvider.recoverySlotName(a),
          isNot(AppStateProvider.recoverySlotName(b)));
      // ...and the same room asked twice answers the same, or nothing could
      // ever be found again.
      expect(AppStateProvider.recoverySlotName(a),
          AppStateProvider.recoverySlotName(a));
      expect(AppStateProvider.recoverySlotName(a), startsWith('config_'));
    });

    test('saving retires the copy', () async {
      final p = withBackups();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);
      final folder = await p.writeAutosaveSnapshot();
      expect(Directory(folder).existsSync(), isTrue);

      await p.saveRoomInPlace();
      expect(Directory(folder).existsSync(), isFalse,
          reason: 'a copy of work that is already in its file can only '
              'mislead somebody');
    });

    test('the project keeps its own copy, beside the room\'s', () async {
      final p = withBackups();
      final projectPath = path.join(dir.path, 'bessey_project.json');
      p.newProject(name: 'Bessey Hall');
      await p.project.save(projectPath);
      p.currentProjectPath = projectPath;
      p.setProjectField(client: 'Facilities');

      await p.writeAutosaveSnapshot(force: true);

      final saved = jsonDecode(
        File(path.join(p.projectRecoveryFolder, 'bessey_project.json'))
            .readAsStringSync(),
      );
      expect(saved['client'], 'Facilities');
    });

    test('a room with no file yet is still copied somewhere findable',
        () async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = baseConfig()
        ..autosaveFolderForTest = path.join(dir.path, 'recovery');

      final folder = await p.writeAutosaveSnapshot();
      expect(path.basename(folder), 'untitled_BSS_103');
      expect(
        Directory(folder).listSync().map((e) => path.basename(e.path)).toList(),
        contains('BSS_103_config.json'),
      );
    });
  });

  // -------------------------------------------------------------------------
  //  FINDING IT AGAIN AFTER A CRASH
  // -------------------------------------------------------------------------

  group('reopening a room a crash left a copy of', () {
    /// A room opened the way the app opens one — through the real load, with
    /// its template defaults filled in and its sidecars read.
    ///
    /// It matters here more than anywhere else in this file: the load ADDS
    /// keys, so a room whose config was merely assigned to the provider would
    /// differ from the same room after a reopen in a dozen places that have
    /// nothing to do with a crash, and every comparison in this group would be
    /// reading that noise.
    Future<AppStateProvider> openedRoom({String stem = 'BSS103_config'}) async {
      final configPath = path.join(dir.path, '$stem.json');
      if (!File(configPath).existsSync()) {
        File(configPath).writeAsStringSync(jsonEncode(baseConfig()));
      }
      final p = AppStateProvider(autoLoadSettings: false)
        ..autosaveFolderForTest = path.join(dir.path, 'recovery');
      await p.openConfigAtPath(configPath);
      p.loadAvFlowForCurrentConfig();
      return p;
    }

    /// A room on disk, edited, copied — and then the session vanishes, which
    /// is a NEW provider opening the same file with the copy still there.
    Future<AppStateProvider> afterACrash({
      void Function(AppStateProvider)? edit,
    }) async {
      final crashed = await openedRoom();
      (edit ?? (p) => p.updateDeviceValue(
          'PROJECTORDEVICE_1', 'speaker_mute', false))(crashed);
      await crashed.writeAutosaveSnapshot();
      return openedRoom();
    }

    test('the copy is offered back, with the differences spelled out',
        () async {
      final p = await afterACrash();

      final pending = p.pendingRecovery;
      expect(pending, isNotNull);
      expect(pending!.kind, 'room');
      expect(pending.origin, p.currentConfigPath);
      expect(
        pending.deltas.map((d) => d.label),
        contains('PROJECTORDEVICE_1.speaker_mute'),
      );
      // Nothing has happened to the room yet — the prompt comes first.
      expect(p.roomConfig['PROJECTORDEVICE_1']['speaker_mute'], isTrue);
    });

    test('a drawing that only exists in the copy is reported too', () async {
      final p = await afterACrash(
        edit: (crashed) => crashed.addAvNode(const AvNode(
          id: 'SW',
          label: 'Switcher',
          model: 'SW4 HD 4K PLUS',
          pos: Offset.zero,
          ports: [],
        )),
      );

      expect(
        p.pendingRecovery!.deltas.map((d) => d.label),
        contains('Signal flow.nodes'),
      );
    });

    test('restoring puts the work on screen and leaves the file alone',
        () async {
      final p = await afterACrash();
      p.applyRecovery(p.pendingRecovery!);

      expect(p.roomConfig['PROJECTORDEVICE_1']['speaker_mute'], isFalse,
          reason: 'the recovered value is what is on screen');
      expect(
        jsonDecode(File(p.currentConfigPath).readAsStringSync())
            ['PROJECTORDEVICE_1']['speaker_mute'],
        isTrue,
        reason: 'the file is not written until Save',
      );
      expect(p.roomHasUnsavedChanges, isTrue,
          reason: 'so the Save button lights its dot, which is the honest '
              'state');
      expect(p.pendingRecovery, isNull);
    });

    test('and Save then writes the recovered work through', () async {
      final p = await afterACrash();
      p.applyRecovery(p.pendingRecovery!);
      await p.saveRoomInPlace();

      expect(
        jsonDecode(File(p.currentConfigPath).readAsStringSync())
            ['PROJECTORDEVICE_1']['speaker_mute'],
        isFalse,
      );
    });

    test('discarding it takes the folder with it', () async {
      final p = await afterACrash();
      final folder = p.pendingRecovery!.folder;
      p.discardPendingRecovery();

      expect(p.pendingRecovery, isNull);
      expect(Directory(folder).existsSync(), isFalse);
    });

    test('"not now" leaves it for next time', () async {
      final p = await afterACrash();
      final folder = p.pendingRecovery!.folder;
      p.dismissPendingRecovery();

      expect(p.pendingRecovery, isNull);
      expect(Directory(folder).existsSync(), isTrue);
    });

    test('a copy that agrees with the file is retired without a word',
        () async {
      // The crash landed AFTER the save: the copy and the file say the same
      // thing, and a prompt about it would be a dialog with nothing behind it.
      final crashed = await openedRoom();
      crashed.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);
      final folder = await crashed.writeAutosaveSnapshot();
      // The copy's own config file, put where the room's is: the file and the
      // copy now say exactly the same thing. Copied rather than saved through
      // the provider, because saving would have retired the copy itself — the
      // case under test is the one where the file caught up some other way and
      // the copy was left behind.
      File(path.join(folder, 'BSS103_config.json'))
          .copySync(crashed.currentConfigPath);

      final reopened = await openedRoom();

      expect(reopened.pendingRecovery, isNull);
      expect(Directory(folder).existsSync(), isFalse);
    });

    test('a room with no copy behind it opens as it always did', () async {
      final p = await openedRoom(stem: 'OTHER_config');
      expect(p.pendingRecovery, isNull);
    });

    test('a project a crash left behind is offered back too', () async {
      final projectPath = path.join(dir.path, 'bessey_project.json');
      final crashed = AppStateProvider(autoLoadSettings: false)
        ..autosaveFolderForTest = path.join(dir.path, 'recovery');
      crashed.newProject(name: 'Bessey Hall');
      await crashed.project.save(projectPath);
      crashed.currentProjectPath = projectPath;
      crashed.setProjectField(client: 'Facilities');
      await crashed.writeAutosaveSnapshot();

      final reopened = AppStateProvider(autoLoadSettings: false)
        ..autosaveFolderForTest = path.join(dir.path, 'recovery');
      expect(await reopened.openProject(projectPath), '');

      expect(reopened.pendingRecovery?.kind, 'project');
      expect(reopened.pendingRecovery!.deltas.map((d) => d.label),
          contains('client'));

      reopened.applyRecovery(reopened.pendingRecovery!);
      expect(reopened.project.client, 'Facilities');
      expect(reopened.projectDirty, isTrue);
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
