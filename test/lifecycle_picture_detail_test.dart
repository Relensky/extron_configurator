import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/campus_lifecycle.dart';
import 'package:extron_configurator/campus_lifecycle_view.dart';
import 'package:extron_configurator/equipment_lifecycle.dart';
import 'package:extron_configurator/lifecycle_picture.dart';
import 'package:extron_configurator/project_lifecycle_view.dart';

/// ============================================================================
///  THE PICTURE IS READ AT TWO LEVELS
/// ============================================================================
///  A replacement plan is handed to two rooms of people. A budget meeting wants
///  one line per room — or per building, on a campus sheet — each carrying the
///  running total it is being asked to approve. The person who has to phase the
///  work wants every one of those opened out: which dates, which rooms, and
///  which of them is the year that hurts.
///
///  The sheet on screen has always had that choice, a fold at a time. The
///  PICTURE had it made for it, and whichever way it was made was wrong for
///  half the people it was handed to — a building of forty rooms with three
///  dates each is a hundred and sixty lines nobody can see the shape of, and a
///  campus sheet folded to eleven rows will not say which building is the
///  problem.
/// ============================================================================
void main() {
  final asOf = DateTime(2026, 6, 1);

  AvNode box(String id, int installedYear) => AvNode(
    id: id,
    label: id,
    model: 'PROJ-1',
    pos: Offset.zero,
    ports: const [],
    installedOn: DateTime(installedYear, 5, 1),
  );

  AvFlowModel roomOf(List<AvNode> nodes) => AvFlowModel(
    nodes: nodes,
    cables: const [],
    racks: const [],
    rackSlots: const {},
    rackItems: const [],
    canvasSize: Size.zero,
    roomTitle: 'Test Room',
    unplaced: const [],
  );

  /// A room whose contents fall due in TWO different years, which is the only
  /// kind of room the fold does anything to.
  RoomLifecycle roomWithTwoDates(String name) => buildRoomLifecycle(
    model: roomOf([box('a', 2014), box('b', 2019)]),
    roomName: name,
    asOf: asOf,
  );

  BuildingLifecycle buildingOf(List<String> roomNames) => BuildingLifecycle(
    rooms: [for (final n in roomNames) roomWithTwoDates(n)],
    asOf: asOf,
  );

  Future<void> pumpSheet(WidgetTester tester, Widget sheet) async {
    tester.view.physicalSize = const Size(2400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(child: sheet),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The tranche lines under the room rows — "1 item due 2029".
  Finder trancheLines() => find.descendant(
    of: find.byType(LifecyclePlanSheet),
    matching: find.textContaining(' due 20'),
  );

  group("a building's plan", () {
    testWidgets('opened out, every date is a line of its own', (tester) async {
      await pumpSheet(
        tester,
        LifecyclePlanSheet(
          building: buildingOf(['Bessey 101', 'Bessey 102']),
          title: 'Bessey refresh',
          expanded: true,
        ),
      );

      // Two rooms, two dates each.
      expect(trancheLines(), findsNWidgets(4));
      expect(find.text('Bessey 101'), findsOneWidget);
      expect(find.text('Bessey 102'), findsOneWidget);
    });

    testWidgets('folded, a room is the one row carrying its total', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        LifecyclePlanSheet(
          building: buildingOf(['Bessey 101', 'Bessey 102']),
          title: 'Bessey refresh',
          expanded: false,
        ),
      );

      expect(trancheLines(), findsNothing);
      // The rooms themselves are still every one of them there — folding is
      // not filtering.
      expect(find.text('Bessey 101'), findsOneWidget);
      expect(find.text('Bessey 102'), findsOneWidget);
    });

    testWidgets('folded is a shorter sheet, which is the whole point', (
      tester,
    ) async {
      final building = buildingOf(['Bessey 101', 'Bessey 102', 'Bessey 103']);

      await pumpSheet(
        tester,
        LifecyclePlanSheet(
          building: building,
          title: 'Bessey refresh',
          expanded: true,
        ),
      );
      final open = tester.getSize(find.byType(LifecyclePlanSheet)).height;

      await pumpSheet(
        tester,
        LifecyclePlanSheet(
          building: building,
          title: 'Bessey refresh',
          expanded: false,
        ),
      );
      final folded = tester.getSize(find.byType(LifecyclePlanSheet)).height;

      expect(folded, lessThan(open));
    });

    testWidgets('opened out is how it has always been pictured', (
      tester,
    ) async {
      // The default has to stay put: somebody's existing export must not
      // change shape because a switch was added above it.
      await pumpSheet(
        tester,
        LifecyclePlanSheet(
          building: buildingOf(['Bessey 101']),
          title: 'Bessey refresh',
        ),
      );
      expect(trancheLines(), findsNWidgets(2));
    });
  });

  group('a campus plan', () {
    CampusLifecycle campusOf() => CampusLifecycle(
      jobs: [
        (
          path: 'a.json',
          name: 'Bessey Hall',
          lifecycle: buildingOf(['Bessey 101', 'Bessey 102']),
          rooms: 2,
          error: '',
        ),
        (
          path: 'b.json',
          name: 'Langdon Hall',
          lifecycle: buildingOf(['Langdon 201']),
          rooms: 1,
          error: '',
        ),
      ],
      asOf: asOf,
    );

    testWidgets('folded, it is one line per building', (tester) async {
      await pumpSheet(tester, CampusPlanSheet(campus: campusOf()));

      expect(find.text('Bessey Hall'), findsOneWidget);
      expect(find.text('Langdon Hall'), findsOneWidget);
      // The rooms inside them are the building's own plan's business.
      expect(find.text('Bessey 101'), findsNothing);
      expect(find.text('Langdon 201'), findsNothing);
    });

    testWidgets('opened out, each building lists its rooms', (tester) async {
      await pumpSheet(
        tester,
        CampusPlanSheet(campus: campusOf(), expanded: true),
      );

      expect(find.text('Bessey Hall'), findsOneWidget);
      // WHICH ROOMS THE BAD YEAR IS — the first thing anybody asks of a
      // building row, and the difference between a plan that can be phased
      // and one that cannot.
      expect(find.text('Bessey 101'), findsOneWidget);
      expect(find.text('Bessey 102'), findsOneWidget);
      expect(find.text('Langdon 201'), findsOneWidget);
    });
  });

  group('the picture dialog', () {
    /// Opens the preview over a sheet that reports which way it was asked for.
    Future<void> openPicture(
      WidgetTester tester, {
      required bool startExpanded,
    }) async {
      tester.view.physicalSize = const Size(1700, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showLifecycleSheetPicture(
                  context,
                  dialogTitle: 'The replacement plan as a picture',
                  fileStem: 'plan',
                  what: 'The replacement plan',
                  detailLabel: 'Every date',
                  startExpanded: startExpanded,
                  sheetBuilder: (expanded) => LifecyclePlanSheet(
                    building: buildingOf(['Bessey 101']),
                    title: 'Bessey refresh',
                    expanded: expanded,
                  ),
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    /// Which way the sheet in the preview is currently drawn.
    bool sheetIsExpanded(WidgetTester tester) =>
        tester.widget<LifecyclePlanSheet>(
          find.byType(LifecyclePlanSheet),
        ).expanded;

    testWidgets('carries a switch, and it moves the preview', (tester) async {
      await openPicture(tester, startExpanded: true);

      final toggle = find.byKey(const ValueKey('lifecycle_picture_expand'));
      expect(toggle, findsOneWidget);
      expect(find.text('Every date'), findsOneWidget);
      expect(sheetIsExpanded(tester), isTrue);

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      // The preview IS the picture, so what changed here is what gets saved.
      expect(sheetIsExpanded(tester), isFalse);
      expect(trancheLines(), findsNothing);

      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(sheetIsExpanded(tester), isTrue);
      expect(trancheLines(), findsNWidgets(2));
    });

    testWidgets('starts whichever way that sheet is normally pictured', (
      tester,
    ) async {
      await openPicture(tester, startExpanded: false);
      expect(sheetIsExpanded(tester), isFalse);
    });
  });
}
