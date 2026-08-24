import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// The toolbar's floppy button writes the in-memory config straight back over
/// the file the session is working from — the same "Apply = save" the Raw JSON
/// tab does, without the Export dialog. A session with no local file (a brand
/// new config that was never exported) has nothing to write over, so the
/// button stays disabled rather than silently doing nothing.
void main() {
  late Directory dir;
  late String configPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('save_working_file_test_');
    configPath = path.join(dir.path, 'BSS103_config.json');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// The real app, mounted on the System tab with [provider] already holding a
  /// config (the boot-time async loads can't be awaited from testWidgets).
  Future<void> pumpApp(WidgetTester tester, AppStateProvider provider) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    provider.settingsLoaded = true;
    provider.firstRunSetupNeeded = false;
    provider.selectTab(2); // System

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pump();
  }

  /// Pumps until [finder] matches, letting REAL async work run between frames.
  ///
  /// The two clocks are the whole problem in this file. A save is real file
  /// I/O, which only runs inside [WidgetTester.runAsync]; the snackbar that
  /// reports it is a widget, which only appears when a frame is pumped, and
  /// pumping is not allowed inside runAsync. So neither waiting nor pumping
  /// alone can see the end of a save — this alternates them.
  ///
  /// Returns false if it never turned up, so the caller can fail with its own
  /// reason rather than a bare "0 widgets found".
  Future<bool> pumpUntilFound(
    WidgetTester tester,
    Finder finder, {
    Duration limit = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(limit);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump();
      if (finder.evaluate().isNotEmpty) return true;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    return false;
  }

  /// The toolbar's save button — Icons.save also names the schematic's "Save
  /// Layout", so the finder is scoped to the bar it lives on.
  ///
  /// That bar is the TITLE BAR: Save stands with New and Open, the three every
  /// other application on the machine keeps together. The banner below it
  /// keeps the buttons that do something OTHER than write to the open
  /// document — convert it, fetch it from a processor, send it to one, put
  /// back the last save, export it.
  final saveButton = find.descendant(
    of: find.byType(AppBar),
    matching: find.widgetWithIcon(IconButton, Icons.save),
  );

  final undoButton = find.descendant(
    of: find.byType(TopLevelBar),
    matching: find.widgetWithIcon(IconButton, Icons.undo),
  );

  Map<String, dynamic> baseConfig() => {
        'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103'},
        'PROJECTORDEVICE_1': {'name': 'Projector 1', 'speaker_mute': true},
      };

  testWidgets('saves the edited config over the file the session opened',
      (WidgetTester tester) async {
    File(configPath).writeAsStringSync(jsonEncode(baseConfig()));

    final provider = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = jsonDecode(File(configPath).readAsStringSync())
      ..currentConfigPath = configPath;

    await pumpApp(tester, provider);

    // An edit made on a tab — on disk the file still holds the old value.
    provider.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);
    await tester.pump();
    expect(
        (jsonDecode(File(configPath).readAsStringSync())
            as Map)['PROJECTORDEVICE_1']['speaker_mute'],
        isTrue,
        reason: 'editing alone must not touch the file');

    // Real file I/O: testWidgets' fake async never lets the write complete, so
    // the tap runs through runAsync.
    await tester.runAsync(() async => tester.tap(saveButton));

    // WAIT FOR THE SNACKBAR, not for the config file — the difference is the
    // whole flake. Saving the config is not the end of the save: the AV flow,
    // the estimate and the control schematic are written to their sidecars
    // afterwards, and only then does the button report. A wait that stopped
    // when the config file changed was letting go of the real clock three
    // writes early, so whether the message had appeared by the time the test
    // looked came down to how busy the machine was.
    // Scoped to the snack bar. With no job open the BANNER names the room's
    // own file, so an unscoped search matched before the save had started and
    // the file was read back three writes early.
    final reported = await pumpUntilFound(
      tester,
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining('BSS103_config.json'),
      ),
    );
    expect(reported, isTrue,
        reason: 'the snackbar names the file that was written');

    final saved = jsonDecode(File(configPath).readAsStringSync()) as Map;
    expect(saved['PROJECTORDEVICE_1']['speaker_mute'], isFalse,
        reason: 'the floppy button writes over the working file');

    // The pre-save copy sits beside it, holding what the file used to say.
    final backup = File(provider.saveBackupPath);
    expect(backup.existsSync(), isTrue,
        reason: 'the save takes a backup first');
    expect(
        (jsonDecode(backup.readAsStringSync()) as Map)['PROJECTORDEVICE_1']
            ['speaker_mute'],
        isTrue,
        reason: 'the backup is the file as it was BEFORE this save');

    // ...which is what turns the Undo button on.
    expect(tester.widget<IconButton>(undoButton).onPressed, isNotNull);
  });

  testWidgets('undo is disabled until something has been saved',
      (WidgetTester tester) async {
    File(configPath).writeAsStringSync(jsonEncode(baseConfig()));
    final provider = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = jsonDecode(File(configPath).readAsStringSync())
      ..currentConfigPath = configPath;

    await pumpApp(tester, provider);

    expect(tester.widget<IconButton>(undoButton).onPressed, isNull,
        reason: 'a session that has saved nothing has nothing to put back');
  });

  testWidgets('offers to give an unsaved room a file rather than going dead',
      (WidgetTester tester) async {
    // A "Create New" config that has never been exported: nothing on disk.
    // The button used to be disabled here, which sent people hunting for the
    // command then called "Export Config Locally". It now opens the Save As
    // dialog, and says so before it is pressed.
    final provider = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = baseConfig();

    await pumpApp(tester, provider);

    final button = tester.widget<IconButton>(saveButton);
    expect(button.onPressed, isNotNull);
    expect(button.tooltip, contains('asks where to put it'));
  });

  testWidgets('is disabled only when there is no room at all',
      (WidgetTester tester) async {
    final provider = AppStateProvider(autoLoadSettings: false);
    await pumpApp(tester, provider);
    expect(tester.widget<IconButton>(saveButton).onPressed, isNull);
  });

  // --- The provider side, without the widget tree ---------------------------

  AppStateProvider loaded() => AppStateProvider(autoLoadSettings: false)
    ..roomConfig = jsonDecode(File(configPath).readAsStringSync())
    ..currentConfigPath = configPath;

  test('undo puts back both the file and the config in memory', () async {
    File(configPath).writeAsStringSync(jsonEncode(baseConfig()));
    final p = loaded();

    p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);
    p.updateDeviceValue('SYSTEM_SETUP', 'gve_room', '104');
    await p.saveCurrentConfigToFile();

    expect(p.canUndoLastSave, isTrue);
    expect(await p.undoLastSave(), isTrue);

    // On disk...
    final onDisk = jsonDecode(File(configPath).readAsStringSync()) as Map;
    expect(onDisk['PROJECTORDEVICE_1']['speaker_mute'], isTrue);
    expect(onDisk['SYSTEM_SETUP']['gve_room'], '103');
    // ...and on screen.
    expect(p.roomConfig['PROJECTORDEVICE_1']['speaker_mute'], isTrue);
    expect(p.roomConfig['SYSTEM_SETUP']['gve_room'], '103');

    expect(p.canUndoLastSave, isFalse,
        reason: 'undo is one level deep, not a redo toggle');
  });

  test('the undo dialog lists every property the restore would change',
      () async {
    File(configPath).writeAsStringSync(jsonEncode(baseConfig()));
    final p = loaded();

    p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute', false);
    await p.saveCurrentConfigToFile();
    // Edited AFTER the save: it goes with the restore too, which is exactly
    // what the dialog has to disclose.
    p.updateDeviceValue('PROJECTORDEVICE_1', 'speaker_mute_method', 'mute');

    final deltas = await p.undoDeltas();
    expect(deltas.map((d) => d.label),
        containsAll(<String>[
          'PROJECTORDEVICE_1.speaker_mute',
          'PROJECTORDEVICE_1.speaker_mute_method',
        ]));
    expect(
        deltas
            .firstWhere((d) => d.key == 'speaker_mute_method')
            .kind,
        DeltaKind.added,
        reason: 'the backup never had that key');
  });

  test('a backup that belongs to another config is never offered', () async {
    File(configPath).writeAsStringSync(jsonEncode(baseConfig()));
    final p = loaded();
    await p.saveCurrentConfigToFile();
    expect(p.canUndoLastSave, isTrue);

    // Export adopts a new working file; the old backup is not its history.
    p.currentConfigPath = path.join(dir.path, 'OTHER_config.json');
    expect(p.canUndoLastSave, isFalse);
  });

  test('diffConfigs reports additions, removals and rewrites', () {
    final deltas = AppStateProvider.diffConfigs(
      {
        'SYSTEM_SETUP': {'gve_room': '103', 'dropped': 1},
        'startup_watchdog_stage': 0,
      },
      {
        'SYSTEM_SETUP': {'gve_room': '104', 'added': true},
        'startup_watchdog_stage': 2,
      },
    );

    final byLabel = {for (final d in deltas) d.label: d};
    expect(byLabel['SYSTEM_SETUP.gve_room']!.kind, DeltaKind.changed);
    expect(byLabel['SYSTEM_SETUP.gve_room']!.before, '103');
    expect(byLabel['SYSTEM_SETUP.gve_room']!.after, '104');
    expect(byLabel['SYSTEM_SETUP.added']!.kind, DeltaKind.added);
    expect(byLabel['SYSTEM_SETUP.dropped']!.kind, DeltaKind.removed);
    // A root scalar the processor maintains is diffed like any other value
    expect(byLabel['startup_watchdog_stage']!.kind, DeltaKind.changed);
  });
}
