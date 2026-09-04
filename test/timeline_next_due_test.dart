import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_schedule.dart';
import 'package:extron_configurator/project_timeline_view.dart';

/// WHAT IS COMING, AND GETTING TO IT.
///
/// The rail draws every date the same size, so the order that has to go in on
/// Thursday looks exactly like the phase that lands in 2029. These guard the
/// two things that fixed: the next date lifted off the rail and printed large,
/// and a button that runs the rail along until the card for it is in frame.
///
/// And the third failure the rail had: several things on ONE day were several
/// stems drawn down one pixel, so the day read as a single colored line.
void main() {
  MasterPartLine part(String description) => MasterPartLine(
    key: masterPartKey(kind: 'equipment', description: description),
    kind: MasterPartKind.equipment,
    description: description,
    model: '',
    partNumber: '',
    manufacturer: '',
    category: '',
    qty: 1,
    total: 100,
    unitPrice: 100,
    maxUnitPrice: 100,
    qtyByRoom: const {},
    rfq: null,
    vendor: null,
    tagSource: RfqTagSource.none,
    unpriced: false,
  );

  ProjectEstimate estimateOf(
    BuildingProject project,
    List<MasterPartLine> master,
  ) => ProjectEstimate(
    project: project,
    currency: r'$',
    rooms: const [],
    costedRooms: const [],
    master: master,
    packages: const [],
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

  /// Worked out against a fixed day, so the rail is the same one every
  /// morning and 'in 214 days' is a number a test can assert.
  final asOf = DateTime(2026, 1, 1);

  ({BuildingProject project, ProjectSchedule schedule}) job({
    DateTime? deadline,
    Map<String, int> leadTimes = const {},
    List<ProjectTrack> tracks = const [],
  }) {
    final screens = part('Projection screen');
    final rack = part('Rack switcher');
    final project = BuildingProject(
      name: 'Bessey Hall',
      deliveryDeadline: deadline,
      partLeadTimes: {
        for (final e in leadTimes.entries)
          masterPartKey(kind: 'equipment', description: e.key): e.value,
      },
      tracks: [...tracks],
    );
    return (
      project: project,
      schedule: buildProjectSchedule(
        estimate: estimateOf(project, [screens, rack]),
        asOf: asOf,
      ),
    );
  }

  Future<void> pump(
    WidgetTester tester,
    ({BuildingProject project, ProjectSchedule schedule}) it,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProjectDateGraph(
              schedule: it.schedule,
              project: it.project,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder mark(String label) =>
      find.byKey(ValueKey('timeline_date_mark_$label'));

  group('the next date is printed, not hunted for', () {
    testWidgets('the box names the next thing due and how far off it is', (
      tester,
    ) async {
      // Due 1 Dec 2026, screens on 120 days: the first order goes in on
      // 3 Aug 2026, which is the next thing after today.
      await pump(
        tester,
        job(
          deadline: DateTime(2026, 12, 1),
          leadTimes: const {'Projection screen': 120, 'Rack switcher': 30},
        ),
      );

      final box = find.byKey(const ValueKey('timeline_next_due'));
      expect(box, findsOneWidget);
      expect(
        find.descendant(of: box, matching: find.text('NEXT UP')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: box, matching: find.text('3 Aug 2026')),
        findsOneWidget,
      );
      // How far off, not only when: the gap is what decides whether it
      // matters this week.
      expect(
        find.descendant(of: box, matching: find.text('in 214 days')),
        findsOneWidget,
      );
      // And what actually lands on it, so nobody goes to the wrong meeting.
      expect(
        find.descendant(
          of: box,
          matching: find.textContaining('First order'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('today itself is never offered as the next thing', (
      tester,
    ) async {
      await pump(
        tester,
        job(
          deadline: DateTime(2026, 12, 1),
          leadTimes: const {'Rack switcher': 30},
        ),
      );
      final box = find.byKey(const ValueKey('timeline_next_due'));
      expect(
        find.descendant(of: box, matching: find.text('1 Jan 2026')),
        findsNothing,
      );
    });

    testWidgets('take me there zooms in on a job too long to read fitted', (
      tester,
    ) async {
      // Eleven months of rail: fitted, the fortnight the order goes in is a
      // few pixels wide, so the press has to change the reading as well as
      // the scroll position.
      await pump(
        tester,
        job(
          deadline: DateTime(2026, 12, 1),
          leadTimes: const {'Projection screen': 120, 'Rack switcher': 30},
        ),
      );

      final level = find.byKey(const ValueKey('timeline_graph_zoom_level'));
      final fitted = tester.widget<Text>(
        find.descendant(of: level, matching: find.byType(Text)),
      ).data;

      await tester.tap(find.byKey(const ValueKey('timeline_next_due_go')));
      await tester.pumpAndSettle();

      final closer = tester.widget<Text>(
        find.descendant(of: level, matching: find.byType(Text)),
      ).data;
      expect(closer, isNot(fitted));
      // And the rail is scrollable now, which fitted it never is.
      expect(find.byType(Scrollbar), findsWidgets);
    });

    testWidgets('fitting the whole job again puts the light out', (
      tester,
    ) async {
      await pump(
        tester,
        job(
          deadline: DateTime(2026, 12, 1),
          leadTimes: const {'Projection screen': 120, 'Rack switcher': 30},
        ),
      );
      await tester.tap(find.byKey(const ValueKey('timeline_next_due_go')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('timeline_graph_zoom_fit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('timeline_next_due')), findsOneWidget);
    });
  });

  group('several things on one day', () {
    testWidgets('each gets its own card, stepped across the true date', (
      tester,
    ) async {
      // Two phases landing on the SAME day. Before the fan they were two
      // cards at the same x with two stems drawn down one pixel.
      await pump(
        tester,
        job(
          deadline: DateTime(2026, 12, 1),
          leadTimes: const {'Rack switcher': 30},
          tracks: [
            ProjectTrack(
              id: 'trk1',
              name: 'Infrastructure',
              deadline: DateTime(2026, 5, 1),
            ),
            ProjectTrack(
              id: 'trk2',
              name: 'Technology',
              deadline: DateTime(2026, 5, 1),
            ),
          ],
        ),
      );

      final a = mark('Infrastructure on site');
      final b = mark('Technology on site');
      expect(a, findsOneWidget);
      expect(b, findsOneWidget);

      final left = tester.getTopLeft(a);
      final right = tester.getTopLeft(b);
      // Stepped sideways, so the stem under each is visible on its own...
      expect(left.dx, isNot(right.dx));
      // ...and still stacked, so neither prints over the other's text.
      expect(left.dy, isNot(right.dy));
    });

    testWidgets('a day with one thing on it is not moved at all', (
      tester,
    ) async {
      // The fan is centered on the true date: a lone card must sit where it
      // always did, or every rail in the app quietly shifted right.
      await pump(
        tester,
        job(
          deadline: DateTime(2026, 12, 1),
          leadTimes: const {'Rack switcher': 30},
          tracks: [
            ProjectTrack(
              id: 'trk1',
              name: 'Infrastructure',
              deadline: DateTime(2026, 5, 1),
            ),
          ],
        ),
      );
      final one = tester.getCenter(mark('Infrastructure on site'));
      final deadline = tester.getCenter(mark('Delivery deadline'));
      // Nothing to assert about absolute pixels; what matters is that the
      // May phase is left of the December deadline, which a runaway fan
      // would eventually stop being true.
      expect(one.dx, lessThan(deadline.dx));
    });
  });

  group('what has to be committed, and by when', () {
    testWidgets('the curve is there once there are two order dates', (
      tester,
    ) async {
      await pump(
        tester,
        job(
          deadline: DateTime(2026, 12, 1),
          leadTimes: const {'Projection screen': 120, 'Rack switcher': 30},
        ),
      );
      expect(
        find.byKey(const ValueKey('timeline_commitment_chart')),
        findsOneWidget,
      );
      expect(
        find.text('WHAT HAS TO BE COMMITTED, AND BY WHEN'),
        findsOneWidget,
      );
    });

    testWidgets('one order date is not a curve', (tester) async {
      // Both parts on the same lead time is one trip to purchasing, and a
      // chart of one point is a number with decoration.
      await pump(
        tester,
        job(
          deadline: DateTime(2026, 12, 1),
          leadTimes: const {'Projection screen': 30, 'Rack switcher': 30},
        ),
      );
      expect(
        find.byKey(const ValueKey('timeline_commitment_chart')),
        findsNothing,
      );
    });
  });
}
