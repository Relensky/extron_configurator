import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_view.dart';
import 'package:extron_configurator/room_presets.dart';
import 'package:extron_configurator/save_actions.dart'
    show splitLineItemName;

/// ============================================================================
///  FROM A REFRESH PLAN TO A ROOM
/// ============================================================================
///  A building arrives on the plan as a list of estimates - a name, a date, a
///  life and a figure off a master spreadsheet - and that is enough to budget
///  with and not enough to build with. Two things had to follow from it:
///
///    * The TIMELINE had to work. Its order dates are worked back from lead
///      times, and a lead time is a fact about a part, so a job of pure line
///      items got "nothing to schedule" - true about the parts and quite wrong
///      about the job, which is all calendar.
///
///    * A line item had to become a ROOM: a real config file with the
///      equipment its own room type is priced on already in it. Done by hand
///      that is seven steps, and the one that gets forgotten is deleting the
///      estimate - which puts the room on its building's plan twice.
/// ============================================================================
void main() {
  group('the name on a line item', () {
    test('reads as a building and a room', () {
      final where = splitLineItemName('AGYM 129');
      expect(where.building, 'AGYM');
      expect(where.room, '129');
    });

    test('takes the job\'s building when the line is just a number', () {
      final where = splitLineItemName('205', fallbackBuilding: 'glnn');
      expect(where.building, 'GLNN');
      expect(where.room, '205');
    });

    test('leaves the number blank rather than guessing one', () {
      // 'Ground floor teaching lab' is neither a building nor a room, and a
      // number invented here is a number nobody chose.
      final where = splitLineItemName(
        'Ground floor teaching lab',
        fallbackBuilding: 'GLNN',
      );
      expect(where.building, 'GLNN');
      expect(where.room, isEmpty);
    });
  });

  group('the room type an estimate was priced against', () {
    test('is read out of the line item\'s notes', () {
      const room = ManualRoom(
        id: 'manual1',
        name: 'AGYM 129',
        notes: 'LEC-Lecture  ·  capacity 44  ·  RYG estimate for 2 Projector',
      );
      expect(room.sourceType, '2 Projector');
    });

    test('stops at the importer\'s own annotations', () {
      const room = ManualRoom(
        id: 'manual1',
        name: 'AGYM 129',
        notes: 'RYG estimate for 1 Projector  ·  last update unknown on the '
            'master sheet',
      );
      expect(room.sourceType, '1 Projector');
    });

    test('is empty on a line nobody imported', () {
      const room = ManualRoom(id: 'manual1', name: 'AGYM 129', notes: 'tbd');
      expect(room.sourceType, isEmpty);
    });

    test('finds the preset that was built from the same sheet', () {
      final provider = AppStateProvider(autoLoadSettings: false);
      // The presets live beside the app; skip where they have not been built.
      if (!Directory('room_presets').existsSync()) return;

      final preset = provider.presetForSourceName('2 Projector');
      expect(preset, isNotNull);
      expect(preset!.sourceName, '2 Projector');
      expect(
        preset.nodes,
        isNotEmpty,
        reason: 'the room type has to bring its equipment with it',
      );
    });

    test('a sheet nothing was built for finds nothing, rather than the wrong '
        'thing', () {
      final provider = AppStateProvider(autoLoadSettings: false);
      expect(provider.presetForSourceName('no such room type'), isNull);
      expect(provider.presetForSourceName(''), isNull);
    });
  });

  group('a preset records the sheet it came from', () {
    test('and survives the trip to disk', () {
      const preset = RoomPreset(
        name: '2 Projector, 2 Camera, Multi-mic',
        sourceName: '2 Projector 2 Cam Multimic',
      );
      final back = RoomPreset.fromJson(preset.toJson());
      // The two drift on purpose: the picker's name is written out for a
      // reader, the sheet's is what a line item matches on.
      expect(back.name, '2 Projector, 2 Camera, Multi-mic');
      expect(back.sourceName, '2 Projector 2 Cam Multimic');
    });

    test('a preset somebody drew carries no sheet name', () {
      const preset = RoomPreset(name: 'Huddle');
      expect(preset.toJson().containsKey('sourceName'), isFalse);
      expect(RoomPreset.fromJson(preset.toJson()).sourceName, isEmpty);
    });
  });

  group('the timeline on a job with no parts', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('rcb_timeline'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<AppStateProvider> pumpTimeline(
      WidgetTester tester, {
      required bool withLines,
    }) async {
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.newProject(name: 'Glenn refresh', building: 'GLNN');
      if (withLines) {
        provider.addProjectManualRoom(
          name: 'GLNN 100',
          installedOn: DateTime(2018, 7),
          lifeYears: 8,
          replacementCost: 24000,
        );
        provider.addProjectManualRoom(
          name: 'GLNN 205',
          installedOn: DateTime(2020, 7),
          lifeYears: 8,
          replacementCost: 31000,
        );
        // No date at all, which is a survey to do rather than a year to
        // budget.
        provider.addProjectManualRoom(name: 'GLNN 301');
      }

      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: ProjectView())),
        ),
      );
      await tester.pumpAndSettle();
      provider.requestProjectPane('timeline');
      await tester.pumpAndSettle();
      return provider;
    }

    testWidgets('shows the replacement calendar instead of giving up', (
      tester,
    ) async {
      await pumpTimeline(tester, withLines: true);

      // Not "nothing to schedule": a refresh plan is the one kind of work that
      // is all calendar.
      expect(find.textContaining('Nothing to schedule yet'), findsNothing);
      expect(find.text('DUE BY YEAR'), findsOneWidget);
      // 2018 + 8 and 2020 + 8.
      expect(find.byKey(const ValueKey('timeline_due_2026')), findsOneWidget);
      expect(find.byKey(const ValueKey('timeline_due_2028')), findsOneWidget);
    });

    testWidgets('the phases can still be set, which is the point', (
      tester,
    ) async {
      await pumpTimeline(tester, withLines: true);
      // A refresh is planned in phases, and that half of this pane never
      // needed a part to exist.
      expect(find.textContaining('phase'), findsWidgets);
    });

    testWidgets('a room with no date is counted, not hidden', (tester) async {
      await pumpTimeline(tester, withLines: true);
      expect(
        find.textContaining('no date'),
        findsWidgets,
        reason: 'a plan that quietly dropped it would read better than the '
            'building actually is',
      );
    });

    testWidgets('a job with neither parts nor lines still says so', (
      tester,
    ) async {
      await pumpTimeline(tester, withLines: false);
      expect(find.textContaining('Nothing to schedule yet'), findsOneWidget);
    });
  });

  testWidgets('the Build button is offered on every line item', (tester) async {
    final provider = AppStateProvider(autoLoadSettings: false);
    provider.newProject(name: 'Glenn refresh', building: 'GLNN');
    final line = provider.addProjectManualRoom(
      name: 'GLNN 100',
      notes: 'RYG estimate for 2 Projector',
    );

    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: ProjectView())),
      ),
    );
    await tester.pumpAndSettle();

    // Both ways out of an estimate: build the room, or point at one that
    // already exists.
    expect(
      find.byKey(ValueKey('line_item_build_${line.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('line_item_swap_${line.id}')),
      findsOneWidget,
    );
  });

  test('a half-finished conversion leaves the estimate on the plan', () {
    // Every way the build can stop - canceled, no template, save dialog
    // closed - has to leave the plan as it was. The estimate is the only
    // record of that room.
    final dir = Directory.systemTemp.createTempSync('rcb_convert');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final provider = AppStateProvider(autoLoadSettings: false);
    provider.newProject(name: 'Glenn refresh');
    final line = provider.addProjectManualRoom(name: 'GLNN 100');

    // The last step of the build is the swap, and it refuses a file that is
    // not there - see [AppStateProvider.swapManualRoomForConfig].
    final missing = path.join(dir.path, 'never_saved.json');
    expect(provider.swapManualRoomForConfig(line.id, missing), isNotEmpty);
    expect(provider.project.manualRooms.single.id, line.id);
    expect(provider.project.rooms, isEmpty);
  });

  test('a line item that became a room is on the job once, not twice', () {
    final dir = Directory.systemTemp.createTempSync('rcb_convert2');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final provider = AppStateProvider(autoLoadSettings: false);
    provider.newProject(name: 'Glenn refresh');
    final line = provider.addProjectManualRoom(
      name: 'GLNN 100',
      replacementCost: 24000,
    );
    final config = path.join(dir.path, 'glnn100_config.json');
    File(config).writeAsStringSync(jsonEncode({'roomName': 'GLNN 100'}));

    expect(provider.swapManualRoomForConfig(line.id, config), isEmpty);
    expect(provider.project.manualRooms, isEmpty);
    expect(provider.project.rooms.single.label, 'GLNN 100');
  });
}
