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

  /// The toolbar's save button — Icons.save also names the schematic's "Save
  /// Layout", so the finder is scoped to the AppBar.
  final saveButton = find.descendant(
    of: find.byType(AppBar),
    matching: find.widgetWithIcon(IconButton, Icons.save),
  );

  final undoButton = find.descendant(
    of: find.byType(AppBar),
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
    // the tap and the wait for it both run through runAsync.
    //
    // POLLED TIGHTLY, and that matters. Everything inside runAsync happens in
    // REAL time, including the snackbar's own four-second life — so a loop
    // that sleeps 20ms at a time can still be waiting when the message it is
    // about to look for has already gone, and the failure lands on the
    // snackbar assertion rather than on the slow write that caused it. Short
    // sleeps and a two-second ceiling keep the wait inside the window.
    await tester.runAsync(() async {
      await tester.tap(saveButton);
      // Waits for the NEW value specifically — the old file already contains
      // the key, so anything looser would pass before the write landed.
      for (var i = 0; i < 400; i++) {
        if (File(configPath)
            .readAsStringSync()
            .contains('"speaker_mute": false')) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pumpAndSettle(); // let the snackbar in

    final saved = jsonDecode(File(configPath).readAsStringSync()) as Map;
    expect(saved['PROJECTORDEVICE_1']['speaker_mute'], isFalse,
        reason: 'the floppy button writes over the working file');
    expect(find.textContaining('BSS103_config.json'), findsOneWidget,
        reason: 'the snackbar names the file that was written');

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

  testWidgets('stays disabled while the session has no local file',
      (WidgetTester tester) async {
    // A "Create New" config that has never been exported: nothing on disk.
    final provider = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = baseConfig();

    await pumpApp(tester, provider);

    expect(tester.widget<IconButton>(saveButton).onPressed, isNull,
        reason: 'there is no working file to write over yet');
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
