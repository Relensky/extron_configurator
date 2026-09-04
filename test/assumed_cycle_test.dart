import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/campus_file.dart';
import 'package:extron_configurator/campus_lifecycle.dart';
import 'package:extron_configurator/campus_lifecycle_view.dart';
import 'package:extron_configurator/equipment_lifecycle.dart';

/// ============================================================================
///  WHAT IF WE DID EVERY ROOM AT TEN YEARS?
/// ============================================================================
///  The question every capital planning meeting asks, and the one this app
///  could not answer without rewriting the record: the life on a position is
///  a decision somebody made, and editing it across forty rooms to see what
///  twelve years looks like is not a what-if, it is a rewrite with no way
///  back.
///
///  Held here: that a restated plan really does move every due date, that it
///  is a LENS and writes nothing, that a position taken off the cycle is not
///  quietly put back on the budget by it, and that a document produced while
///  it is on says on its face that it is not the plan.
/// ============================================================================
void main() {
  AvNode box(String id, {required DateTime installed, required int life}) =>
      AvNode(
        id: id,
        label: id,
        model: '',
        pos: Offset.zero,
        ports: const [],
        installedOn: installed,
        lifeYears: life,
      );

  RoomLifecycle roomOf(List<AvNode> nodes, {DateTime? asOf}) =>
      buildRoomLifecycle(
        model: AvFlowModel(
          nodes: nodes,
          cables: const [],
          racks: const [],
          rackSlots: const {},
          canvasSize: Size.zero,
          roomTitle: 'Bessey 101',
          unplaced: const [],
        ),
        roomName: 'BSS 101',
        asOf: asOf ?? DateTime(2026, 6, 15),
      );

  group('one room, restated', () {
    test('every position falls due on the assumed cycle instead', () {
      // A projector on five years and a display on fifteen: two very
      // different due dates, and the whole point of the question is what
      // happens when they are both put on ten.
      final room = roomOf([
        box('PROJECTORDEVICE_1', installed: DateTime(2020, 5), life: 5),
        box('DISPLAYDEVICE_1', installed: DateTime(2020, 5), life: 15),
      ]);
      expect(
        {for (final i in room.items) i.node.id: i.dueYear},
        {'PROJECTORDEVICE_1': 2025, 'DISPLAYDEVICE_1': 2035},
      );

      final ten = room.onCycle(10);
      expect(
        {for (final i in ten.items) i.node.id: i.dueYear},
        {'PROJECTORDEVICE_1': 2030, 'DISPLAYDEVICE_1': 2030},
      );
      expect(ten.assumedLifeYears, 10);
      // And the life on each says where it came from, so a row cannot read
      // as though somebody had recorded ten years against it.
      expect(
        ten.items.every(
          (i) => i.lifeSource == EquipmentLifeSource.assumed,
        ),
        isTrue,
      );
    });

    test('the room it was restated from is untouched', () {
      // A LENS, NOT AN EDIT. The original object has to survive intact or the
      // control cannot say what it moved, and nothing can get back to the
      // plan as recorded.
      final room = roomOf([
        box('PROJECTORDEVICE_1', installed: DateTime(2020, 5), life: 5),
      ]);
      room.onCycle(20);
      expect(room.items.single.dueYear, 2025);
      expect(room.assumedLifeYears, isNull);
    });

    test('as recorded gives the same room back', () {
      final room = roomOf([
        box('PROJECTORDEVICE_1', installed: DateTime(2020, 5), life: 5),
      ]);
      expect(identical(room.onCycle(null), room), isTrue);
      expect(identical(room.onCycle(0), room), isTrue);
    });

    test('a position taken off the cycle stays off it', () {
      // The one thing a what-if must never do. A bracket held off the refresh
      // plan is not a life figure to be argued with, and an estate whose
      // mounts and poles suddenly grew a budget is an estate nobody believes.
      final room = roomOf([
        box('PROJECTORDEVICE_1', installed: DateTime(2020, 5), life: 5),
        box(
          'MOUNTDEVICE_1',
          installed: DateTime(2020, 5),
          life: kNeverReplacedLife,
        ),
      ]);
      expect(room.neverCount, 1);

      final ten = room.onCycle(10);
      expect(ten.neverCount, 1, reason: 'still held off the plan');
      expect(ten.items.length, 1, reason: 'and not added to it');
      expect(ten.neverReplaced.single.dueYear, isNull);
    });
  });

  group('a whole estate, restated', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('rcb_cycle_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// A building of one line item: done in 2018, on an eight-year cycle,
    /// so it falls due in 2026 as recorded and in 2030 on twelve.
    String job(String stem) {
      final project = BuildingProject(name: stem, building: stem);
      project.addManualRoom(
        name: '$stem 101',
        installedOn: DateTime(2018, 7),
        lifeYears: 8,
        replacementCost: 24000,
      );
      final file = path.join(dir.path, '${stem}_project.json');
      File(file).writeAsStringSync(jsonEncode(project.toJson()));
      return file;
    }

    Future<CampusLifecycle> read(WidgetTester tester, List<String> jobs) async {
      final provider = AppStateProvider(autoLoadSettings: false);
      late final CampusLifecycle campus;
      await tester.runAsync(() async {
        campus = await readCampus(
          provider: provider,
          projectPaths: jobs,
          asOf: DateTime(2026, 6, 15),
        );
      });
      return campus;
    }

    testWidgets('the money moves into a different year', (tester) async {
      final campus = await read(tester, [job('SCI'), job('BSS')]);
      expect(campus.totalIn(2026), 48000, reason: 'as recorded, both in 2026');

      final twelve = campus.onCycle(12);
      expect(twelve.totalIn(2026), 0, reason: 'nothing left in 2026');
      expect(twelve.totalIn(2030), 48000, reason: 'four years later instead');
      expect(twelve.assumedLifeYears, 12);
      // The estate it came from is still the estate.
      expect(campus.totalIn(2026), 48000);
    });

    testWidgets('a shorter cycle brings the whole estate forward', (
      tester,
    ) async {
      final campus = await read(tester, [job('SCI')]);
      final six = campus.onCycle(6);
      expect(six.totalIn(2024), 24000, reason: 'already late on six years');
      expect(six.overdueCost, 24000);
    });

    testWidgets('a picture taken on a restated estate says so on its face', (
      tester,
    ) async {
      // THE MOST DANGEROUS DOCUMENT THIS SCREEN CAN PRODUCE is a photographed
      // what-if that looks exactly like the plan. The note goes on the sheet
      // itself, not only on the screen it was taken from.
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final campus = await read(tester, [job('SCI')]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CampusPlanSheet(campus: campus.onCycle(12)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('12-year cycle'), findsOneWidget);
    });

    testWidgets('and a plan as recorded says nothing of the kind', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final campus = await read(tester, [job('SCI')]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: CampusPlanSheet(campus: campus)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('cycle, whatever'), findsNothing);
    });
  });

  group('the control, on the campus screen', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('rcb_cycle_ui_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    String job(String stem) {
      final project = BuildingProject(name: stem, building: stem);
      project.addManualRoom(
        name: '$stem 101',
        installedOn: DateTime(2018, 7),
        lifeYears: 8,
        replacementCost: 24000,
      );
      final file = path.join(dir.path, '${stem}_project.json');
      File(file).writeAsStringSync(jsonEncode(project.toJson()));
      return file;
    }

    Future<void> until(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 60 && !done(); i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pump();
    }

    testWidgets('picking a cycle restates the estate on screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final provider = AppStateProvider(autoLoadSettings: false);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showCampusLifecycleFile(
                  context,
                  CampusFile(name: 'Chico', projects: [job('SCI')]),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await until(
        tester,
        () => find
            .byKey(const ValueKey('campus_assumed_cycle'))
            .evaluate()
            .isNotEmpty,
      );

      // At rest it is the plan as recorded and says nothing about a what-if.
      expect(find.textContaining('What-if only'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('campus_cycle_picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('12-year cycle').last);
      await tester.pumpAndSettle();

      // Now it says what it is, and what it moved.
      expect(find.textContaining('What-if only'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('campus_shift_Worst single year')),
        findsOneWidget,
      );
    });
  });
}
