import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_schedule.dart';
import 'package:extron_configurator/project_timeline_view.dart';

/// The timeline's dates, drawn on one rail.
///
/// The failure this guards is a graph that says something the cards below it
/// do not: a deadline missing from the rail, a phase that never appears, or a
/// rail drawn out of a single date, where the distance between two dates - the
/// only thing a graph adds to a list - would be a lie.
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

  /// A job due in a year, with two parts on very different lead times, worked
  /// out against a fixed day so the rail is the same one every morning.
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
    tester.view.physicalSize = const Size(1400, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectDateGraph(
            schedule: it.schedule,
            project: it.project,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder mark(String label) =>
      find.byKey(ValueKey('timeline_date_mark_$label'));

  group('the date graph', () {
    testWidgets('names today, the first order and the deadline', (
      tester,
    ) async {
      await pump(
        tester,
        job(
          deadline: DateTime(2026, 12, 1),
          leadTimes: const {
            'Projection screen': 120,
            'Rack switcher': 30,
          },
        ),
      );

      expect(find.byKey(const ValueKey('timeline_date_graph')), findsOneWidget);
      expect(mark('Today'), findsOneWidget);
      expect(mark('First order'), findsOneWidget);
      expect(mark('Delivery deadline'), findsOneWidget);
      // The dates are written out, not only colored: this tab is printed and
      // photographed, and a rail read by hue alone says nothing in mono.
      expect(find.text('1 Dec 2026'), findsOneWidget);
    });

    testWidgets('puts every phase on the rail under its own name', (
      tester,
    ) async {
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
              deadline: DateTime(2026, 10, 1),
            ),
          ],
        ),
      );

      expect(mark('Infrastructure on site'), findsOneWidget);
      expect(mark('Technology on site'), findsOneWidget);
    });

    // THE DISTANCE IS THE WHOLE POINT. A list puts two dates a fortnight apart
    // and two a year apart one row from each other either way; the graph exists
    // to say which is which, and it only does that if the rail is to scale.
    testWidgets('places a date by how far off it is', (tester) async {
      final it = job(
        deadline: DateTime(2026, 12, 31),
        leadTimes: const {'Rack switcher': 0},
        tracks: [
          ProjectTrack(
            id: 'trk1',
            name: 'Infrastructure',
            // A quarter of the way from 1 Jan to 31 Dec.
            deadline: DateTime(2026, 4, 2),
          ),
        ],
      );
      await pump(tester, it);

      final left = tester.getCenter(mark('Today')).dx;
      final right = tester.getCenter(mark('Delivery deadline')).dx;
      final phase = tester.getCenter(mark('Infrastructure on site')).dx;
      final along = (phase - left) / (right - left);
      expect(along, closeTo(0.25, 0.06));
    });

    // NOTHING ON THE RAIL SITS ON TOP OF ANYTHING ELSE. Six phases handed over
    // on the same day are six callouts at the same point on the rail, and a
    // fixed number of lanes meant the ones past the last lane were printed
    // over the cards already there - the dates that cluster being exactly the
    // dates somebody opened the graph to tell apart.
    testWidgets('stacks same-day dates instead of printing them over each '
        'other', (tester) async {
      final same = DateTime(2026, 6, 1);
      await pump(
        tester,
        job(
          deadline: DateTime(2026, 12, 1),
          leadTimes: const {'Rack switcher': 30},
          tracks: [
            for (var i = 1; i <= 6; i++)
              ProjectTrack(id: 'trk$i', name: 'Phase $i', deadline: same),
          ],
        ),
      );

      final rects = <Rect>[
        for (var i = 1; i <= 6; i++) tester.getRect(mark('Phase $i on site')),
        tester.getRect(mark('Today')),
        tester.getRect(mark('Delivery deadline')),
      ];
      for (var a = 0; a < rects.length; a++) {
        for (var b = a + 1; b < rects.length; b++) {
          expect(
            rects[a].overlaps(rects[b]),
            isFalse,
            reason: 'callout $a is drawn over callout $b',
          );
        }
      }
    });

    // The rail grows DOWNWARDS to fit them: the lanes stack above the line, so
    // a job whose dates all land together is a taller graph rather than a
    // tidier one.
    testWidgets('grows taller for the lanes the dates need', (tester) async {
      Future<double> calloutSpan(List<ProjectTrack> tracks) async {
        await pump(
          tester,
          job(
            deadline: DateTime(2026, 12, 1),
            leadTimes: const {'Rack switcher': 30},
            tracks: tracks,
          ),
        );
        final rects = <Rect>[
          tester.getRect(mark('Today')),
          tester.getRect(mark('Delivery deadline')),
          for (final t in tracks) tester.getRect(mark('${t.name} on site')),
        ];
        final top = rects.map((r) => r.top).reduce((a, b) => a < b ? a : b);
        final bottom = rects
            .map((r) => r.bottom)
            .reduce((a, b) => a > b ? a : b);
        return bottom - top;
      }

      final plain = await calloutSpan(const []);
      final crowded = await calloutSpan([
        for (var i = 1; i <= 6; i++)
          ProjectTrack(
            id: 'trk$i',
            name: 'Phase $i',
            deadline: DateTime(2026, 6, 1),
          ),
      ]);
      // Six more cards, none of them beside another: six more lanes of rail.
      expect(crowded, greaterThan(plain * 2));
    });

    testWidgets('draws nothing when the job has only one date', (tester) async {
      await pump(tester, job());
      expect(find.byKey(const ValueKey('timeline_date_graph')), findsNothing);
    });
  });
}
