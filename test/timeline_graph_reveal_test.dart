import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_schedule.dart';
import 'package:extron_configurator/project_timeline_view.dart';

/// The rail drawing itself, left to right.
///
/// The failures this guards are the two an animation can hide behind: a rail
/// that never finishes, so a date somebody has to act on is left half drawn;
/// and a rail that ignores reduce motion, where the reader who asked for no
/// movement gets the whole sweep anyway.
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

  final asOf = DateTime(2026, 1, 1);

  ({BuildingProject project, ProjectSchedule schedule}) job({
    DateTime? deadline,
    Map<String, int> leadTimes = const {},
    List<ProjectTrack> tracks = const [],
  }) {
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
        estimate: estimateOf(project, [
          part('Projection screen'),
          part('Rack switcher'),
        ]),
        asOf: asOf,
      ),
    );
  }

  Future<void> show(
    WidgetTester tester,
    ({BuildingProject project, ProjectSchedule schedule}) it, {
    bool stillness = false,
  }) async {
    tester.view.physicalSize = const Size(1400, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: stillness),
          child: Scaffold(
            body: ProjectDateGraph(
              schedule: it.schedule,
              project: it.project,
            ),
          ),
        ),
      ),
    );
  }

  Finder mark(String label) =>
      find.byKey(ValueKey('timeline_date_mark_$label'));

  /// How far out a callout is, as the sweep has it this frame.
  double shown(WidgetTester tester, String label) {
    final opacity = find.ancestor(
      of: mark(label),
      matching: find.byType(Opacity),
    );
    return tester.widget<Opacity>(opacity.first).opacity;
  }

  final it = job(
    deadline: DateTime(2026, 12, 1),
    leadTimes: const {'Projection screen': 120, 'Rack switcher': 30},
  );

  group('the rail draws itself', () {
    // THE SWEEP RUNS IN THE DIRECTION THE JOB DOES. December cannot be on
    // screen before August, or the run says nothing about the order of the
    // work and is decoration.
    testWidgets('the near dates arrive before the far ones', (tester) async {
      await show(tester, it);
      await tester.pump(const Duration(milliseconds: 260));

      expect(
        shown(tester, 'Today'),
        greaterThan(shown(tester, 'Delivery deadline')),
      );
      await tester.pumpAndSettle();
    });

    // AND FINISHES. Every date is at full strength once the run is over -
    // a card left at nine tenths is a date somebody reads as less urgent.
    testWidgets('every date is fully drawn once it settles', (tester) async {
      await show(tester, it);
      await tester.pumpAndSettle();

      expect(shown(tester, 'Today'), 1);
      expect(shown(tester, 'First order'), 1);
      expect(shown(tester, 'Delivery deadline'), 1);
    });

    // Reduce motion means 'show me the schedule', not 'show me a slower one'.
    testWidgets('reduce motion gets the whole rail on the first frame', (
      tester,
    ) async {
      await show(tester, it, stillness: true);
      await tester.pump();

      expect(shown(tester, 'Delivery deadline'), 1);
    });

    testWidgets('the run can be played again', (tester) async {
      await show(tester, it);
      await tester.pumpAndSettle();
      expect(shown(tester, 'Delivery deadline'), 1);

      await tester.tap(find.byKey(const ValueKey('timeline_graph_replay')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(shown(tester, 'Delivery deadline'), lessThan(1));

      // And still ends where it started, with the whole job drawn.
      await tester.pumpAndSettle();
      expect(shown(tester, 'Delivery deadline'), 1);
    });

    // A DATE THAT CHANGES ANIMATES ONTO THE RAIL. The rail is redrawn from the
    // job, so a phase somebody has just dated should arrive rather than
    // appear - which is also the check that the replay is not fired by every
    // rebuild.
    testWidgets('a new phase plays onto the rail; a rebuild does not', (
      tester,
    ) async {
      await show(tester, it);
      await tester.pumpAndSettle();

      // The same job again: nothing about the dates changed.
      await show(tester, it);
      await tester.pump(const Duration(milliseconds: 60));
      expect(shown(tester, 'Delivery deadline'), 1);

      await show(
        tester,
        job(
          deadline: DateTime(2026, 12, 1),
          leadTimes: const {'Projection screen': 120, 'Rack switcher': 30},
          tracks: [
            ProjectTrack(
              id: 'trk1',
              name: 'Infrastructure',
              deadline: DateTime(2026, 5, 1),
            ),
          ],
        ),
      );
      await tester.pump(const Duration(milliseconds: 60));
      expect(shown(tester, 'Delivery deadline'), lessThan(1));
      await tester.pumpAndSettle();
      expect(shown(tester, 'Infrastructure on site'), 1);
    });
  });
}
