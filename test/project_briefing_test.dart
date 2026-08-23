import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_briefing.dart';
import 'package:extron_configurator/project_estimate.dart';

/// What a project says on the way in.
///
/// The failure this guards is a briefing that cries wolf — one that interrupts
/// on a healthy job, or buries the one thing that is actually late under nine
/// standing questions. Both end the same way: dismissed unread.
void main() {
  MasterPartLine part(
    String description, {
    bool unpriced = false,
    bool spared = false,
  }) {
    final key = masterPartKey(kind: 'equipment', description: description);
    return MasterPartLine(
      key: key,
      kind: MasterPartKind.equipment,
      description: description,
      model: '',
      partNumber: '',
      manufacturer: '',
      category: '',
      qty: 2,
      total: 100,
      unitPrice: 50,
      maxUnitPrice: 50,
      qtyByRoom: const {},
      vendor: null,
      tagSource: VendorTagSource.none,
      unpriced: unpriced,
      spareQty: spared ? 1 : 0,
    );
  }

  ProjectEstimate estimateOf(
    BuildingProject project, {
    List<MasterPartLine> master = const [],
    int untagged = 0,
    int unpriced = 0,
  }) => ProjectEstimate(
    project: project,
    currency: r'$',
    rooms: const [],
    costedRooms: const [],
    master: master,
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
    unpricedParts: unpriced,
    untaggedParts: untagged,
    controlGaps: const [],
    mixedCurrency: false,
  );

  final march = DateTime(2026, 3, 4);

  test('a job with nothing time-critical does not interrupt', () {
    final screen = part('Projection screen', spared: true);
    final project = BuildingProject(
      deliveryDeadline: DateTime(2026, 12, 1),
      partLeadTimes: {screen.key: 30},
    );
    final briefing = buildProjectBriefing(
      estimate: estimateOf(project, master: [screen]),
      asOf: march,
    );

    // There are standing questions (this part has no vendor), and they are
    // still listed — but nothing here should put a dialog on screen.
    expect(briefing.isQuiet, isTrue);
    expect(briefing.lateLines, isEmpty);
    expect(briefing.soonLines, isEmpty);
  });

  test('a part past its order date leads the briefing', () {
    final screen = part('Projection screen');
    final project = BuildingProject(
      deliveryDeadline: DateTime(2026, 4, 1),
      partLeadTimes: {screen.key: 200},
    );
    final briefing = buildProjectBriefing(
      estimate: estimateOf(project, master: [screen]),
      asOf: march,
    );

    expect(briefing.isQuiet, isFalse);
    expect(briefing.lines.first.urgency, BriefingUrgency.late);
    expect(briefing.lines.first.message, contains('past the date'));
    expect(briefing.lines.first.pane, BriefingPane.timeline);
    // The specifics are on the line, so it can be acted on without opening
    // anything.
    expect(briefing.lines.first.detail.first, contains('Projection screen'));
  });

  test('an overdue note is late, and a dated one due soon is not', () {
    final project = BuildingProject();
    project.addTodo('chase Extron', due: DateTime(2026, 2, 1));
    project.addTodo('call the client', due: DateTime(2026, 3, 6));

    final briefing = buildProjectBriefing(
      estimate: estimateOf(project),
      asOf: march,
    );

    expect(briefing.lateLines, hasLength(1));
    expect(briefing.lateLines.single.message, contains('past its date'));
    expect(briefing.soonLines, hasLength(1));
    expect(briefing.soonLines.single.message, contains('due this week'));
  });

  test('a deadline that has passed is called out on its own', () {
    final project = BuildingProject(deliveryDeadline: DateTime(2026, 1, 1));
    final briefing = buildProjectBriefing(
      estimate: estimateOf(project),
      asOf: march,
    );
    expect(
      briefing.lateLines.map((l) => l.message).join(),
      contains('delivery deadline'),
    );
  });

  test('a part with no lead time is an open question, not an alarm', () {
    final rack = part('Equipment rack');
    final project = BuildingProject(deliveryDeadline: DateTime(2026, 12, 1));
    final briefing = buildProjectBriefing(
      estimate: estimateOf(project, master: [rack]),
      asOf: march,
    );

    expect(briefing.isQuiet, isTrue);
    expect(
      briefing.openLines.map((l) => l.message).join(),
      contains('no lead time'),
    );
  });

  test('the standing questions are all there', () {
    final unpricedPart = part('Mystery box', unpriced: true);
    final project = BuildingProject();
    project.addTodo('a note with no date');
    final briefing = buildProjectBriefing(
      estimate: estimateOf(
        project,
        master: [unpricedPart],
        unpriced: 1,
        untagged: 1,
      ),
      asOf: march,
    );

    final all = briefing.openLines.map((l) => l.message).join(' | ');
    expect(all, contains('no price'));
    expect(all, contains('not tagged to a vendor'));
    expect(all, contains('No delivery deadline'));
    expect(all, contains('job note'));
    // Nothing on this job is spared, and nothing else would ever raise it.
    expect(all, contains('spare'));
  });

  test('an empty job says so rather than saying nothing', () {
    final briefing = buildProjectBriefing(
      estimate: estimateOf(BuildingProject()),
      asOf: march,
    );
    expect(briefing.isEmpty, isFalse);
    expect(briefing.lines.single.urgency, BriefingUrgency.clear);
    expect(briefing.isQuiet, isTrue);
  });

  test('a long list names a few and counts the rest', () {
    final project = BuildingProject();
    for (var i = 0; i < 9; i++) {
      project.addTodo('note $i', due: DateTime(2026, 2, 1));
    }
    final briefing = buildProjectBriefing(
      estimate: estimateOf(project),
      asOf: march,
    );

    final line = briefing.lateLines.single;
    expect(line.message, contains('9 job notes'));
    // Three specifics and a count — a list of nine is a list somebody has to
    // read rather than glance at.
    expect(line.detail, hasLength(4));
    expect(line.detail.last, 'and 6 more');
  });

  test('every line names the pane that fixes it', () {
    final screen = part('Projection screen', unpriced: true);
    final project = BuildingProject(
      deliveryDeadline: DateTime(2026, 4, 1),
      partLeadTimes: {screen.key: 200},
    );
    project.addTodo('overdue note', due: DateTime(2026, 1, 1));

    final briefing = buildProjectBriefing(
      estimate: estimateOf(project, master: [screen], unpriced: 1),
      asOf: march,
    );

    for (final line in briefing.lines) {
      expect(kBriefingPaneLabels[line.pane], isNotNull);
    }
  });

  group('where it stands, overall', () {
    test('it carries the job size, money and dates', () {
      final screen = part('Projection screen');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 9, 1),
        partLeadTimes: {screen.key: 45},
      );
      final o = buildProjectBriefing(
        estimate: estimateOf(project, master: [screen]),
        asOf: march,
      ).overview;

      expect(o.parts, 1);
      expect(o.deadline, DateTime(2026, 9, 1));
      // 1 Sep less 45 days.
      expect(o.firstOrder, DateTime(2026, 7, 18));
      expect(o.lastDelivery, DateTime(2026, 9, 1));
      expect(o.partsWithoutLeadTime, 0);
    });

    test('the order dates are listed, with what is due on each', () {
      final a = part('Projection screen');
      final b = part('Ceiling mount');
      final c = part('Equipment rack');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 9, 1),
        partLeadTimes: {a.key: 45, b.key: 45, c.key: 10},
      );
      final o = buildProjectBriefing(
        estimate: estimateOf(project, master: [a, b, c]),
        asOf: march,
      ).overview;

      // Two dates: the two 45-day parts share one, the 10-day part has its
      // own. An order date is a trip to purchasing, not a row per part.
      expect(o.nextOrders, hasLength(2));
      expect(o.nextOrders.first.date, DateTime(2026, 7, 18));
      expect(o.nextOrders.first.parts, 2);
      expect(o.nextOrders.first.late, isFalse);
      expect(o.nextOrders.last.date, DateTime(2026, 8, 22));
      expect(o.nextOrders.last.parts, 1);
    });

    test('a date that has gone is flagged rather than dropped', () {
      final screen = part('Projection screen');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 4, 1),
        partLeadTimes: {screen.key: 200},
      );
      final o = buildProjectBriefing(
        estimate: estimateOf(project, master: [screen]),
        asOf: march,
      ).overview;

      expect(o.nextOrders, hasLength(1));
      expect(o.nextOrders.single.late, isTrue);
    });

    test('it stops after a few dates rather than reprinting the timeline', () {
      final parts = <MasterPartLine>[];
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 12, 1));
      for (var i = 0; i < 9; i++) {
        final p = part('Part $i');
        parts.add(p);
        // A different lead time each, so each lands on its own order date.
        project.setPartLeadTime(p.key, 10 + i * 5);
      }
      final o = buildProjectBriefing(
        estimate: estimateOf(project, master: parts),
        asOf: march,
      ).overview;
      expect(o.nextOrders.length, lessThanOrEqualTo(4));
    });

    test('the phases and their dates are on it', () {
      final conduit = part('Conduit');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 9, 1));
      final infra = project.addTrack(
        'Infrastructure',
        deadline: DateTime(2026, 4, 1),
      );
      project.setPartTrack(conduit.key, infra.id);
      project.setPartLeadTime(conduit.key, 10);

      final o = buildProjectBriefing(
        estimate: estimateOf(project, master: [conduit]),
        asOf: march,
      ).overview;

      expect(o.phases, hasLength(1));
      expect(o.phases.single.name, 'Infrastructure');
      expect(o.phases.single.deadline, DateTime(2026, 4, 1));
      expect(o.phases.single.parts, 1);
    });

    test('a job with no dates still reports what it is', () {
      final o = buildProjectBriefing(
        estimate: estimateOf(BuildingProject()),
        asOf: march,
      ).overview;
      expect(o.deadline, isNull);
      expect(o.firstOrder, isNull);
      expect(o.nextOrders, isEmpty);
      expect(o.phases, isEmpty);
    });
  });
}
