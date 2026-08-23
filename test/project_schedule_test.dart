import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_schedule.dart';

/// Lead times, the job deadline, and the one subtraction between them.
///
/// The failure mode this guards is a schedule that is quietly wrong: a date
/// that drifts a day across a daylight-saving boundary, a part with no lead
/// time reported as fine, or an early-delivery date that gets overwritten by
/// the job's own deadline. Each of those reads as a healthy timeline right up
/// until something does not arrive.
void main() {
  MasterPartLine part(String description, {String model = ''}) {
    final key = masterPartKey(
      kind: 'equipment',
      model: model,
      description: description,
    );
    return MasterPartLine(
      key: key,
      kind: MasterPartKind.equipment,
      description: description,
      model: model,
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
      unpriced: false,
    );
  }

  ProjectEstimate estimateOf(
    BuildingProject project,
    List<MasterPartLine> master,
  ) => ProjectEstimate(
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
    unpricedParts: 0,
    untaggedParts: 0,
    controlGaps: const [],
    mixedCurrency: false,
  );

  group('the one subtraction', () {
    test('order-by is the delivery date minus the lead time', () {
      final screen = part('Projection screen');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 6, 1),
        partLeadTimes: {screen.key: 42},
      );
      final schedule = buildProjectSchedule(
        estimate: estimateOf(project, [screen]),
        asOf: DateTime(2026, 1, 1),
      );

      // 1 June less 42 days is 20 April.
      expect(schedule.lines.single.orderBy, DateTime(2026, 4, 20));
      expect(schedule.lines.single.status, OrderStatus.onTrack);
    });

    test('a part with its own date is ordered against THAT, not the job', () {
      final screen = part('Projection screen');
      final rack = part('Equipment rack');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 6, 1),
        // The screen goes in while the walls are open, six weeks early.
        partNeedBy: {screen.key: DateTime(2026, 4, 20)},
        partLeadTimes: {screen.key: 30, rack.key: 30},
      );
      final schedule = buildProjectSchedule(
        estimate: estimateOf(project, [screen, rack]),
        asOf: DateTime(2026, 1, 1),
      );

      final byName = {
        for (final l in schedule.lines) l.line.description: l,
      };
      expect(byName['Projection screen']!.orderBy, DateTime(2026, 3, 21));
      expect(byName['Projection screen']!.needByIsOwn, isTrue);
      // Same lead time, later delivery, later order date.
      expect(byName['Equipment rack']!.orderBy, DateTime(2026, 5, 2));
      expect(byName['Equipment rack']!.needByIsOwn, isFalse);
    });

    test('moving the deadline moves every order date with it', () {
      final screen = part('Projection screen');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 6, 1),
        partLeadTimes: {screen.key: 10},
      );
      final estimate = estimateOf(project, [screen]);

      expect(
        buildProjectSchedule(estimate: estimate, asOf: DateTime(2026, 1, 1))
            .lines
            .single
            .orderBy,
        DateTime(2026, 5, 22),
      );

      // Nothing is stored, so the schedule follows the deadline rather than
      // going stale behind it.
      project.deliveryDeadline = DateTime(2026, 7, 1);
      expect(
        buildProjectSchedule(estimate: estimate, asOf: DateTime(2026, 1, 1))
            .lines
            .single
            .orderBy,
        DateTime(2026, 6, 21),
      );
    });

    test('a lead time that STRADDLES the clock change keeps its day', () {
      // The case the test below missed and a real export got wrong: both of
      // ITS endpoints were on the same side of the switch, so nothing moved.
      // Here the need-by date is in summer time and the order date is not, and
      // subtracting a fixed number of HOURS lands at 23:00 the day before —
      // which, reduced to a date, silently eats a day of lead time in the
      // direction that misses the delivery.
      final screen = part('Projection screen');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 4, 1),
        partLeadTimes: {screen.key: 30},
      );
      final line = buildProjectSchedule(
        estimate: estimateOf(project, [screen]),
        asOf: DateTime(2026, 1, 1),
      ).lines.single;

      expect(line.orderBy, DateTime(2026, 3, 2));
      expect(daysBetween(line.orderBy!, DateTime(2026, 4, 1)), 30);
    });

    test('a lead time crossing a daylight-saving boundary keeps its day', () {
      // Northern-hemisphere clocks move in March, and subtracting local
      // DateTimes across that boundary yields 23 hours for one of the days.
      // Truncated, that is a whole day of lead time lost.
      final screen = part('Projection screen');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 4, 10),
        partLeadTimes: {screen.key: 30},
      );
      final line = buildProjectSchedule(
        estimate: estimateOf(project, [screen]),
        asOf: DateTime(2026, 1, 1),
      ).lines.single;

      expect(line.orderBy, DateTime(2026, 3, 11));
      expect(daysBetween(line.orderBy!, DateTime(2026, 4, 10)), 30);
    });
  });

  group('what the list has an opinion about', () {
    test('no lead time is its own state, not zero days', () {
      final rack = part('Equipment rack');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 6, 1));
      final schedule = buildProjectSchedule(
        estimate: estimateOf(project, [rack]),
        asOf: DateTime(2026, 1, 1),
      );

      final line = schedule.lines.single;
      expect(line.leadDays, isNull);
      expect(line.orderBy, isNull);
      expect(line.status, OrderStatus.unknown);
      expect(schedule.unknownCount, 1);
      // And it is still ON the list — a part left out entirely is a part
      // nobody remembers to ask about.
      expect(schedule.lines, hasLength(1));
    });

    test('zero days is a real answer and schedules', () {
      final cable = part('HDMI cable');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 6, 1),
        partLeadTimes: {cable.key: 0},
      );
      final line = buildProjectSchedule(
        estimate: estimateOf(project, [cable]),
        asOf: DateTime(2026, 1, 1),
      ).lines.single;

      expect(line.leadDays, 0);
      expect(line.orderBy, DateTime(2026, 6, 1));
      expect(line.status, OrderStatus.onTrack);
    });

    test('an order date already gone reads as late, with the gap', () {
      final screen = part('Projection screen');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 6, 1),
        partLeadTimes: {screen.key: 200},
      );
      final schedule = buildProjectSchedule(
        estimate: estimateOf(project, [screen]),
        asOf: DateTime(2026, 1, 1),
      );

      final line = schedule.lines.single;
      expect(line.status, OrderStatus.late);
      expect(line.daysUntilOrder, isNegative);
      expect(schedule.lateCount, 1);
      expect(formatDayGap(line.daysUntilOrder!), contains('late'));
    });

    test('due soon is the fortnight before the order date', () {
      final screen = part('Projection screen');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 6, 1),
        partLeadTimes: {screen.key: 145}, // order by 7 January
      );
      final schedule = buildProjectSchedule(
        estimate: estimateOf(project, [screen]),
        asOf: DateTime(2026, 1, 1),
      );
      expect(schedule.lines.single.status, OrderStatus.dueSoon);
      expect(schedule.dueSoonCount, 1);
    });

    test('no deadline anywhere is reported, not guessed at', () {
      final rack = part('Equipment rack');
      final project = BuildingProject(partLeadTimes: {rack.key: 30});
      final schedule = buildProjectSchedule(
        estimate: estimateOf(project, [rack]),
        asOf: DateTime(2026, 1, 1),
      );
      expect(schedule.lines.single.status, OrderStatus.noDeadline);
      expect(schedule.hasNoDates, isTrue);
    });
  });

  group('the timeline reading', () {
    test('parts sharing an order date are one day, earliest first', () {
      final a = part('Projection screen');
      final b = part('Ceiling mount');
      final c = part('Equipment rack');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 6, 1),
        partLeadTimes: {a.key: 30, b.key: 30, c.key: 10},
      );
      final schedule = buildProjectSchedule(
        estimate: estimateOf(project, [a, b, c]),
        asOf: DateTime(2026, 1, 1),
      );

      final days = schedule.orderDays;
      expect(days, hasLength(2));
      expect(days.first.date, DateTime(2026, 5, 2));
      expect(days.first.parts, hasLength(2));
      expect(days.last.date, DateTime(2026, 5, 22));
      expect(days.last.parts, hasLength(1));
      // The earliest order is where the job actually starts.
      expect(schedule.firstOrderDate, DateTime(2026, 5, 2));
    });

    test('undated parts sort last rather than to the top', () {
      final dated = part('Projection screen');
      final undated = part('Equipment rack');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 6, 1),
        partLeadTimes: {dated.key: 30},
      );
      final schedule = buildProjectSchedule(
        estimate: estimateOf(project, [undated, dated]),
        asOf: DateTime(2026, 1, 1),
      );
      expect(schedule.lines.first.line.description, 'Projection screen');
      expect(schedule.lines.last.line.description, 'Equipment rack');
    });
  });

  group('it survives a save and a reload', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('schedule_test_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('deadline, lead times and early dates round-trip', () async {
      final screen = part('Projection screen');
      final project = BuildingProject(
        name: 'Bessey Hall',
        deliveryDeadline: DateTime(2026, 6, 1),
        partLeadTimes: {screen.key: 42},
        partNeedBy: {screen.key: DateTime(2026, 4, 20)},
      );

      final file = '${dir.path}/bessey_project.json';
      await project.save(file);
      final back = await BuildingProject.load(file);

      expect(back.deliveryDeadline, DateTime(2026, 6, 1));
      expect(back.partLeadTimes[screen.key], 42);
      expect(back.partNeedBy[screen.key], DateTime(2026, 4, 20));
    });

    test('a date is written as a plain day, with no time on it', () async {
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 6, 1, 23, 30),
      );
      final file = '${dir.path}/p_project.json';
      await project.save(file);
      expect(await File(file).readAsString(), contains('"2026-06-01"'));

      // And comes back as midnight, so "is this overdue" never hinges on the
      // hour the app was opened at.
      final back = await BuildingProject.load(file);
      expect(back.deliveryDeadline, DateTime(2026, 6, 1));
    });

    test('a hand-edited nonsense lead time is dropped, not defaulted', () {
      final back = BuildingProject.fromJson({
        'rooms': <dynamic>[],
        'vendors': <dynamic>[],
        // Somebody typed the vendor's answer in verbatim.
        'partLeadTimes': {'equipment|model:x': '6-8 weeks'},
        'partNeedBy': {'equipment|model:x': 'sometime in May'},
      });
      // Dropped: the part reads as "nobody has answered this", which is true
      // and visible, rather than as zero days, which is false and silent.
      expect(back.partLeadTimes, isEmpty);
      expect(back.partNeedBy, isEmpty);
    });

    test('a project with only a deadline on it is not empty', () {
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 6, 1),
      );
      // isEmpty drives the "nothing to save" path, and a deadline somebody
      // typed is work that must not be thrown away.
      expect(project.isEmpty, isFalse);
      expect(BuildingProject().isEmpty, isTrue);
    });

    test('clone carries the schedule, and does not share its maps', () {
      final screen = part('Projection screen');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 6, 1),
        partLeadTimes: {screen.key: 42},
        partNeedBy: {screen.key: DateTime(2026, 4, 20)},
      );
      final copy = project.clone();
      copy.setPartLeadTime(screen.key, 10);
      copy.deliveryDeadline = DateTime(2026, 7, 1);

      expect(project.partLeadTimes[screen.key], 42);
      expect(project.deliveryDeadline, DateTime(2026, 6, 1));
      expect(copy.partNeedBy[screen.key], DateTime(2026, 4, 20));
    });
  });

  group('setters', () {
    test('a blank lead time forgets the figure', () {
      final project = BuildingProject();
      project.setPartLeadTime('k', 42);
      expect(project.partLeadTimes['k'], 42);
      project.setPartLeadTime('k', null);
      expect(project.partLeadTimes.containsKey('k'), isFalse);
      // Negative is not an answer either.
      project.setPartLeadTime('k', -3);
      expect(project.partLeadTimes.containsKey('k'), isFalse);
    });

    test('clearing a part date puts it back on the job deadline', () {
      final screen = part('Projection screen');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 6, 1),
        partLeadTimes: {screen.key: 10},
      );
      project.setPartNeedBy(screen.key, DateTime(2026, 4, 1));
      expect(
        schedulePart(line: screen, project: project, asOf: DateTime(2026, 1, 1))
            .orderBy,
        DateTime(2026, 3, 22),
      );

      project.setPartNeedBy(screen.key, null);
      final back = schedulePart(
        line: screen,
        project: project,
        asOf: DateTime(2026, 1, 1),
      );
      expect(back.orderBy, DateTime(2026, 5, 22));
      expect(back.needByIsOwn, isFalse);
    });

    test('a part date keeps only the day it was given', () {
      final project = BuildingProject();
      project.setPartNeedBy('k', DateTime(2026, 4, 1, 17, 45));
      expect(project.partNeedBy['k'], DateTime(2026, 4, 1));
    });
  });

  group('how the dates read', () {
    test('a lead time is spoken the way it was quoted', () {
      expect(formatLeadTime(null), 'not asked');
      expect(formatLeadTime(0), 'in stock');
      expect(formatLeadTime(10), '10 days');
      expect(formatLeadTime(42), '6 weeks');
      // Not a whole number of weeks — stays in days rather than rounding a
      // delivery date away.
      expect(formatLeadTime(45), '45 days');
    });

    test('a date is written with the month spelled', () {
      // 03/04 is two different days depending on who is reading it, and a
      // delivery date is the wrong thing to be ambiguous about.
      expect(formatScheduleDate(DateTime(2026, 3, 4)), '4 Mar 2026');
    });

    test('a day gap reads as a sentence', () {
      expect(formatDayGap(0), 'today');
      expect(formatDayGap(1), 'tomorrow');
      expect(formatDayGap(21), 'in 21 days');
      expect(formatDayGap(-1), '1 day late');
      expect(formatDayGap(-3), '3 days late');
    });
  });
}
