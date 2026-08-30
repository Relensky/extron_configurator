import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/main.dart';
import 'package:extron_configurator/project_room_picker.dart';

/// Working a job the way it is actually worked: open the project, pick a room,
/// edit it on the ordinary room tabs, and watch the building total follow.
///
/// The two halves that make this more than a file dialog with a nicer name:
///
///   * switching loads the WHOLE room — config and sidecars — so the next tab
///     you look at is that room's, not half of the last one's;
///   * the open room is priced from MEMORY, so an edit shows up in the project
///     before it has been saved, and the room's row says the file is behind.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_room_switch'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  AvNode device(String id, String label, String model) => AvNode(
    id: id,
    label: label,
    model: model,
    pos: Offset.zero,
    ports: const [],
  );

  String writeRoom(
    String stem,
    String name,
    List<AvNode> nodes, {
    double taxPercent = 0,
  }) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [for (final n in nodes) n.toJson()],
    }));
    File(path.join(dir.path, '${stem}_config_cost.json'))
        .writeAsStringSync(jsonEncode({
      'cost': {'taxPercent': taxPercent, 'currency': r'$'},
    }));
    return configPath;
  }

  AppStateProvider withProject() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = dir.path;
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'Display X',
        manufacturer: 'Generic',
        category: 'Display',
        price: 1000,
        ports: [],
      ))
      ..upsert(const AvDeviceTemplate(
        model: 'Camera Y',
        manufacturer: 'Generic',
        category: 'Camera',
        price: 2000,
        ports: [],
      ));
    p.newProject(name: 'Switch test');
    p.addRoomToProject(
      writeRoom('a', 'Room A', [device('n1', 'Display', 'Display X')]),
    );
    p.addRoomToProject(
      writeRoom('b', 'Room B', [device('n1', 'Camera', 'Camera Y')]),
    );
    return p;
  }

  String roomA() => path.join(dir.path, 'a_config.json');
  String roomB() => path.join(dir.path, 'b_config.json');

  // -------------------------------------------------------------------------
  //  SWITCHING
  // -------------------------------------------------------------------------

  group('switching to a room of the project', () {
    test('loads the config and the diagram together', () async {
      final p = withProject();
      expect(p.openProjectRoom, isNull);

      final error = await p.openProjectRoomRef(p.project.rooms.first);

      expect(error, isEmpty);
      expect(p.currentConfigPath, roomA());
      expect(p.openProjectRoom?.id, p.project.rooms.first.id);
      // The sidecar came with it — not left for a visit to the AV Flow tab.
      expect(p.avNodes, hasLength(1));
      expect(p.avNodes.single.model, 'Display X');
    });

    test('the next room replaces the last one entirely', () async {
      final p = withProject();
      await p.openProjectRoomRef(p.project.rooms.first);
      await p.openProjectRoomRef(p.project.rooms.last);

      expect(p.currentConfigPath, roomB());
      expect(p.avNodes.single.model, 'Camera Y',
          reason: 'the previous room\'s diagram must not linger');
    });

    test('steps forward and wraps round', () async {
      final p = withProject();

      await p.stepProjectRoom(1);
      expect(p.openProjectRoom?.id, p.project.rooms.first.id);

      await p.stepProjectRoom(1);
      expect(p.openProjectRoom?.id, p.project.rooms.last.id);

      await p.stepProjectRoom(1);
      expect(p.openProjectRoom?.id, p.project.rooms.first.id,
          reason: 'the list is a ring');
    });

    test('steps backwards from nowhere onto the last room', () async {
      final p = withProject();
      await p.stepProjectRoom(-1);
      expect(p.openProjectRoom?.id, p.project.rooms.last.id);
    });

    test('a room whose file has gone reports rather than half-opening',
        () async {
      final p = withProject();
      await p.openProjectRoomRef(p.project.rooms.first);
      File(roomB()).deleteSync();

      final error = await p.openProjectRoomRef(p.project.rooms.last);

      expect(error, contains('The config is not at'));
      expect(p.currentConfigPath, roomA(), reason: 'still on the room it had');
    });

    test('opening a project room by any route lights up the picker', () async {
      // Not through openProjectRoomRef at all — the ordinary Open Config path.
      // The picker asks the path, not a remembered id, so it still knows.
      final p = withProject();
      await p.openConfigAtPath(roomB());

      expect(p.openProjectRoom?.id, p.project.rooms.last.id);
    });

    test('a room outside the project leaves the picker showing nothing',
        () async {
      final p = withProject();
      final stray = writeRoom('z', 'Not on the job', const []);
      await p.openConfigAtPath(stray);

      expect(p.openProjectRoom, isNull);
    });
  });

  // -------------------------------------------------------------------------
  //  REFLECTING BACK
  // -------------------------------------------------------------------------

  group('edits on the room reach the project', () {
    test('the open room is priced from memory, before it is saved', () async {
      final p = withProject();
      expect(p.priceProject().grandTotal, 3000);

      await p.openProjectRoomRef(p.project.rooms.first);
      // A price typed on the Cost tab — no save anywhere.
      p.setAvCostPrice('model:display x', 1500);

      expect(
        p.priceProject().grandTotal,
        3500,
        reason: 'the room in the editor is the one being priced',
      );
      // And the file underneath is untouched.
      expect(readRoomFromDisk(roomA()).settings.priceOverrides, isEmpty);
    });

    test('a box added to the diagram lands on the master list', () async {
      final p = withProject();
      await p.openProjectRoomRef(p.project.rooms.first);

      p.addAvNode(device('n2', 'Second display', 'Display X'));

      final line = p
          .priceProject()
          .master
          .firstWhere((l) => l.model == 'Display X');
      expect(line.qty, 2);
      expect(p.priceProject().grandTotal, 4000);
    });

    test('the room says it is behind its file, and stops once saved',
        () async {
      final p = withProject();
      await p.openProjectRoomRef(p.project.rooms.first);
      expect(p.roomHasUnsavedChanges, isFalse);

      p.setAvCostTax(percent: 10);
      expect(p.roomHasUnsavedChanges, isTrue);

      final saved = await p.saveRoomInPlace();
      expect(saved, roomA());
      expect(p.roomHasUnsavedChanges, isFalse);
      // And it really is on disk now.
      expect(readRoomFromDisk(roomA()).settings.taxPercent, 10);
    });

    test('a saved edit survives switching away and back', () async {
      final p = withProject();
      await p.openProjectRoomRef(p.project.rooms.first);
      p.setAvCostPrice('model:display x', 1500);
      await p.saveRoomInPlace();

      await p.openProjectRoomRef(p.project.rooms.last);
      expect(p.priceProject().grandTotal, 3500);

      await p.openProjectRoomRef(p.project.rooms.first);
      expect(p.avCost.priceOverrides['model:display x'], 1500);
    });

    test('an unsaved edit does NOT survive switching away', () async {
      // The honest half of the bargain: the project counts what is in memory,
      // and memory is what switching rooms replaces.
      final p = withProject();
      await p.openProjectRoomRef(p.project.rooms.first);
      p.setAvCostPrice('model:display x', 1500);
      expect(p.priceProject().grandTotal, 3500);

      await p.openProjectRoomRef(p.project.rooms.last);

      expect(p.priceProject().grandTotal, 3000);
    });

    test('saving in place needs no dialog and keeps the sidecars', () async {
      final p = withProject();
      await p.openProjectRoomRef(p.project.rooms.first);
      p.addAvNode(device('n2', 'Second display', 'Display X'));

      await p.saveRoomInPlace();

      expect(readRoomFromDisk(roomA()).model.nodes, hasLength(2));
    });

    test('a room that has never been saved says so instead of guessing',
        () async {
      final p = AppStateProvider(autoLoadSettings: false);
      final result = await p.saveRoomInPlace();
      expect(result, startsWith('Error'));
    });
  });

  // -------------------------------------------------------------------------
  //  THE PICKER
  // -------------------------------------------------------------------------

  group('the picker in the title bar', () {
    Future<void> pump(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(title: const ProjectRoomPicker()),
              body: const SizedBox(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('stays out of the way when there is no project',
        (tester) async {
      await pump(tester, AppStateProvider(autoLoadSettings: false));
      expect(find.byKey(const ValueKey('room_picker_menu')), findsNothing);
    });

    testWidgets('names the open room and lists the others', (tester) async {
      final p = withProject();
      await tester.runAsync(
        () => p.openProjectRoomRef(p.project.rooms.first),
      );
      await pump(tester, p);

      expect(find.text('Room A'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('room_picker_menu')));
      await tester.pumpAndSettle();
      expect(find.text('Room B'), findsOneWidget);
    });

    testWidgets('offers to save a room that is behind its file',
        (tester) async {
      final p = withProject();
      await tester.runAsync(
        () => p.openProjectRoomRef(p.project.rooms.first),
      );
      p.setAvCostTax(percent: 10);
      await pump(tester, p);

      expect(
        find.byKey(const ValueKey('room_picker_save')),
        findsOneWidget,
        reason: 'an unsaved room has to say so somewhere you will see it',
      );
    });

    testWidgets('no save button when the room matches its file',
        (tester) async {
      final p = withProject();
      await tester.runAsync(
        () => p.openProjectRoomRef(p.project.rooms.first),
      );
      await pump(tester, p);

      expect(find.byKey(const ValueKey('room_picker_save')), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  //  THE ROOM LIST ON THE PROJECT TAB
  // -------------------------------------------------------------------------
  //  The list already said which room was open. It had no way to CHANGE which
  //  one was — the only door was the picker up in the title bar — so somebody
  //  reading a building's rooms had to look away from the list to act on it.
  //  The name is that door now, and it goes through the same "save first?"
  //  prompt the picker does.
  // -------------------------------------------------------------------------

  group('clicking a room on the Project tab', () {
    Future<void> pumpTab(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      p.settingsLoaded = true;
      p.firstRunSetupNeeded = false;
      p.selectTab(AppTab.project.index);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const RoomConfigApp(),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// [name] as it appears IN THE ROOM LIST.
    ///
    /// Scoped to the list's own cards because the picker in the title bar
    /// names the open room as well, and an unscoped find.text would match
    /// both and fail on the room that matters most — the open one.
    Finder inList(String name) =>
        find.descendant(of: find.byType(Card), matching: find.text(name));

    testWidgets('the name opens that room', (tester) async {
      final p = withProject();
      await pumpTab(tester, p);
      expect(p.openProjectRoom, isNull, reason: 'nothing open to start with');

      await tester.runAsync(() async => tester.tap(inList('Room B')));
      // WAIT FOR THE WHOLE ROOM, not just the path. openConfigAtPath sets
      // currentConfigPath and then awaits the rest of the load, so a loop that
      // stopped at the path could look at the room in the middle of opening -
      // config in, diagram not yet - and report an empty drawing as a failure
      // to load one.
      for (var i = 0;
          i < 40 && (p.currentConfigPath.isEmpty || p.avNodes.isEmpty);
          i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }

      expect(p.currentConfigPath, roomB());
      expect(p.openProjectRoom?.id, p.project.rooms.last.id);
      // The whole room, not just the config — the same as every other way in.
      expect(p.avNodes.single.model, 'Camera Y');
    });

    testWidgets('the open room is not a way into itself', (tester) async {
      final p = withProject();
      await tester.runAsync(
        () => p.openProjectRoomRef(p.project.rooms.first),
      );
      await pumpTab(tester, p);

      // Its name is inside a plain Tooltip rather than an InkWell, and the
      // tooltip says why instead of leaving somebody clicking at a row that
      // does nothing.
      final nameA = inList('Room A');
      expect(nameA, findsOneWidget);
      expect(
        find.ancestor(of: nameA, matching: find.byType(InkWell)),
        findsNothing,
      );
      final tip = tester.widget<Tooltip>(
        find.ancestor(of: nameA, matching: find.byType(Tooltip)).first,
      );
      expect(tip.message, contains('working on'));
    });

    testWidgets('an unsaved room is offered a save before the switch',
        (tester) async {
      final p = withProject();
      await tester.runAsync(
        () => p.openProjectRoomRef(p.project.rooms.first),
      );
      p.setAvCostTax(percent: 10); // Room A is now behind its file.
      await pumpTab(tester, p);

      await tester.tap(inList('Room B'));
      await tester.pumpAndSettle();

      // The picker's prompt, reached from the list — one question with one
      // answer, however you got to it.
      expect(find.text('Save this room first?'), findsOneWidget);

      await tester.tap(find.text('Stay here'));
      await tester.pumpAndSettle();
      expect(p.currentConfigPath, roomA(),
          reason: 'backing out of the prompt leaves the room where it was');
      expect(p.avCost.taxPercent, 10, reason: 'and keeps the unsaved edit');
    });
  });
}
