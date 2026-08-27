import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test/flutter_test.dart' as ft;
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/base_costs.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/equipment_lifecycle.dart';
import 'package:extron_configurator/manual_rooms_dialog.dart';
import 'package:extron_configurator/project_estimate.dart';

/// ============================================================================
///  THE ROOMS NOBODY HAS DRAWN
/// ============================================================================
///  Most of an estate has never been through this app. A refresh plan built
///  only from the rooms that have is a plan for a fraction of the building —
///  short in the one direction nobody checks — so a room can be typed in: a
///  name, a date, a life and a figure, saved to the building it is in.
///
///  What is held here: that such a room ages and falls due exactly like a
///  drawn one, that its money comes off the base-cost card when nobody typed
///  one, and that it survives the trip to disk and back.
/// ============================================================================
void main() {
  final asOf = DateTime(2026, 6, 15);

  group('a room typed in by hand', () {
    test('ages and falls due like a drawn room', () {
      final room = buildManualRoomLifecycle(
        room: ManualRoom(
          id: 'manual1',
          name: 'BSS 214',
          installedOn: DateTime(2014, 5, 1),
          replacementCost: 12000,
        ),
        asOf: asOf,
      );

      expect(room.roomName, 'BSS 214');
      expect(room.items, hasLength(1), reason: 'one position for the room');
      // Eight-year blanket cycle off a 2014 install: due 2022, and overdue in
      // 2026 like any other position past its life.
      expect(room.firstDueYear, 2022);
      expect(room.refreshCost, 12000);
      expect(room.costDueIn(2022), 12000);
      expect(room.timing, EquipmentTiming.wellOverdue,
          reason: 'four years past an eight-year cycle');
    });

    test('takes its own life when one is typed', () {
      final room = buildManualRoomLifecycle(
        room: ManualRoom(
          id: 'manual1',
          name: 'BSS 214',
          installedOn: DateTime(2020, 5, 1),
          lifeYears: 15,
          replacementCost: 9000,
        ),
        asOf: asOf,
      );
      expect(room.firstDueYear, 2035);
      expect(room.items.single.lifeSource, EquipmentLifeSource.position);
    });

    test('is priced off the base-cost card when nobody typed a figure', () {
      final card = BaseCostBook(
        costs: const [BaseCost(category: kRoomRefreshCategory, price: 18500)],
      );
      final room = buildManualRoomLifecycle(
        room: ManualRoom(
          id: 'manual1',
          name: 'BSS 214',
          installedOn: DateTime(2014, 5, 1),
        ),
        baseCosts: card,
        asOf: asOf,
      );

      expect(room.refreshCost, 18500);
      // And says so: a typical price presented as a quote is how a budget goes
      // wrong quietly.
      expect(room.items.single.costIsEstimate, isTrue);
    });

    test('a card with nothing for it reports unpriced, not free', () {
      final room = buildManualRoomLifecycle(
        room: ManualRoom(
          id: 'manual1',
          name: 'BSS 214',
          installedOn: DateTime(2014, 5, 1),
        ),
        baseCosts: BaseCostBook(costs: const []),
        asOf: asOf,
      );
      expect(room.refreshCost, 0);
      expect(room.items.single.costIsEstimate, isFalse);
    });

    test('a room with no date has nothing to age', () {
      final room = buildManualRoomLifecycle(
        room: const ManualRoom(id: 'manual1', name: 'BSS 214'),
        asOf: asOf,
      );
      expect(room.firstDueYear, isNull);
      expect(room.undated, 1);
    });
  });

  group('on the building', () {
    test('it is written into the project file and read back', () {
      final project = BuildingProject(name: 'Bessey Hall');
      final added = project.addManualRoom(
        name: 'BSS 214',
        installedOn: DateTime(2014, 5, 1),
        lifeYears: 10,
        replacementCost: 12000,
        notes: 'projector only',
      );
      expect(added.id, 'manual1');

      final read = BuildingProject.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(project.toJson())) as Map,
        ),
      );
      expect(read.manualRooms, hasLength(1));
      final back = read.manualRooms.single;
      expect(back.id, 'manual1');
      expect(back.name, 'BSS 214');
      expect(back.installedOn, DateTime(2014, 5, 1));
      expect(back.lifeYears, 10);
      expect(back.replacementCost, 12000);
      expect(back.notes, 'projector only');

      // The counter comes back with them, so the next room is not manual1
      // again — a reused id would make two rooms one room.
      expect(read.addManualRoom(name: 'BSS 215').id, 'manual2');
    });

    test('a room with no name is dropped on the way in', () {
      final read = BuildingProject.fromJson({
        'rooms': [],
        'manualRooms': [
          {'id': 'manual1', 'name': '   '},
          {'id': 'manual2', 'name': 'BSS 216'},
        ],
      });
      expect(read.manualRooms.map((r) => r.name), ['BSS 216']);
    });

    test('it lands on the building plan beside the drawn rooms', () {
      final project = BuildingProject(name: 'Bessey Hall');
      project.addManualRoom(
        name: 'BSS 214',
        installedOn: DateTime(2014, 5, 1),
        replacementCost: 12000,
      );

      // An estimate with no readable rooms at all — the manual room is the
      // whole plan, which is exactly the case this exists for.
      final estimate = ProjectEstimate(
        project: project,
        currency: r'$',
        projectPath: '',
        rooms: const [],
        costedRooms: const [],
        master: const [],
        vendors: const [],
        grandTotal: 0,
        equipmentTotal: 0,
        hardwareTotal: 0,
        cablingTotal: 0,
        extrasTotal: 0,
        laborTotal: 0,
        laborHours: 0,
        feeTotal: 0,
        taxTotal: 0,
        failedRooms: 0,
        unpricedParts: 0,
        untaggedParts: 0,
        controlGaps: const [],
        mixedCurrency: false,
      );

      final plan = buildProjectLifecycle(estimate: estimate, asOf: asOf);
      expect(plan.rooms, hasLength(1));
      expect(plan.rooms.single.roomName, 'BSS 214');
      expect(plan.refreshCost, 12000);
    });
  });

  group('driven through the dialog', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('rcb_manual'));
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    /// The dialog reads and writes a REAL FILE, and a testWidgets body runs on
    /// fake async where that I/O never completes. Everything that touches disk
    /// goes through here; the pumping stays outside it, where the test clock
    /// is the one driving the frames.
    Future<void> onDisk(WidgetTester tester, Future<void> Function() body) =>
        tester.runAsync(() async {
          await body();
          await Future<void>.delayed(const Duration(milliseconds: 60));
        });

    BuildingProject readBack(String file) => BuildingProject.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(File(file).readAsStringSync()) as Map,
      ),
    );

    ft.testWidgets('a room typed in is saved to the job file', (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final file = path.join(dir.path, 'bessey_project.json');
      File(file).writeAsStringSync(
        jsonEncode(BuildingProject(name: 'Bessey Hall').toJson()),
      );

      final provider = AppStateProvider(autoLoadSettings: false);
      var saved = false;

      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    saved = await showManualRoomsDialog(
                      context,
                      provider,
                      file,
                      buildingName: 'Bessey Hall',
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await onDisk(tester, () => tester.tap(find.text('open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('manual_rooms_dialog')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('manual_room_add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('manual_room_name')),
        'BSS 214',
      );
      await tester.enterText(
        find.byKey(const ValueKey('manual_room_cost')),
        '12000',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('manual_room_ok')));
      await tester.pumpAndSettle();

      // On the list, and not on disk until it is saved.
      expect(find.text('BSS 214'), findsWidgets);
      expect(readBack(file).manualRooms, isEmpty);

      await onDisk(
        tester,
        () => tester.tap(find.byKey(const ValueKey('manual_rooms_save'))),
      );
      await tester.pumpAndSettle();

      expect(saved, isTrue);
      final written = readBack(file);
      expect(written.manualRooms, hasLength(1));
      expect(written.manualRooms.single.name, 'BSS 214');
      expect(written.manualRooms.single.replacementCost, 12000);
      expect(tester.takeException(), isNull);
    });
  });
}
