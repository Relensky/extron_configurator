import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

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
      rfq: null,
      vendor: null,
      tagSource: RfqTagSource.none,
      unpriced: unpriced,
      spareQty: spared ? 1 : 0,
    );
  }

  ProjectEstimate estimateOf(
    BuildingProject project, {
    List<MasterPartLine> master = const [],
    int untagged = 0,
    int unpriced = 0,
    String projectPath = '',
  }) => ProjectEstimate(
    project: project,
    currency: r'$',
    projectPath: projectPath,
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
    expect(all, contains('in no buying package'));
    expect(all, contains('No delivery deadline'));
    // Nothing on this job is spared, and nothing else would ever raise it.
    expect(all, contains('spare'));
    // The open note is not summarized into a line — it is listed in full in
    // the overview, and a count over the top of the list says it twice.
    expect(
      [for (final t in briefing.overview.todos) t.text],
      ['a note with no date'],
    );
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

  group('the building plans', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('rcb_briefing_plans'));
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    String projectPath() => path.join(dir.path, 'bss_project.json');

    ProjectPlan attach(BuildingProject project, String file,
        {String label = ''}) {
      final plan = ProjectPlan(
        id: project.nextPlanId(),
        filePath: file,
        label: label,
      );
      project.plans.add(plan);
      return plan;
    }

    test('the drawing set is part of what the job IS', () {
      final project = BuildingProject();
      File(path.join(dir.path, 'A-101.pdf')).writeAsStringSync('%PDF-1.4');
      attach(project, 'A-101.pdf');

      final o = buildProjectBriefing(
        estimate: estimateOf(project, projectPath: projectPath()),
        asOf: march,
      ).overview;

      expect(o.plans, 1);
      expect(o.plansMissing, 0);
    });

    test('a drawing that has moved is counted and named', () {
      final project = BuildingProject();
      File(path.join(dir.path, 'A-101.pdf')).writeAsStringSync('%PDF-1.4');
      attach(project, 'A-101.pdf');
      attach(project, 'A-999.pdf', label: 'Riser diagram');

      final briefing = buildProjectBriefing(
        estimate: estimateOf(project, projectPath: projectPath()),
        asOf: march,
      );

      expect(briefing.overview.plans, 2);
      expect(briefing.overview.plansMissing, 1);

      // Named, not just counted: which sheet went missing is the whole
      // question, and it is asked on the day the drawing is wanted.
      final line = briefing.openLines.singleWhere(
          (l) => l.pane == BriefingPane.plans);
      expect(line.message, '1 building plan is not where the project says it '
          'is');
      expect(line.detail.single, contains('Riser diagram'));
      expect(line.detail.single, contains('A-999.pdf'));
    });

    test('a broken drawing link is not a reason to interrupt', () {
      // An open question, not something time-critical: the briefing appears on
      // the way in only when something cannot wait, and a job always has open
      // questions.
      final project = BuildingProject();
      attach(project, 'A-999.pdf');

      final briefing = buildProjectBriefing(
        estimate: estimateOf(project, projectPath: projectPath()),
        asOf: march,
      );

      expect(briefing.isQuiet, isTrue);
      expect(briefing.openLines.map((l) => l.pane),
          contains(BriefingPane.plans));
    });

    test('a job with no plans says nothing about them', () {
      final briefing = buildProjectBriefing(
        estimate: estimateOf(BuildingProject(), projectPath: projectPath()),
        asOf: march,
      );

      expect(briefing.overview.plans, 0);
      expect(briefing.overview.plansMissing, 0);
      expect(briefing.lines.map((l) => l.pane),
          isNot(contains(BriefingPane.plans)));
    });
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

  group('the active job list is on it', () {
    test('open notes are listed as items, not counted', () {
      final project = BuildingProject();
      project.addTodo('move the second display');
      project.addTodo('chase Extron on the DTP lead time');

      final briefing = buildProjectBriefing(
        estimate: estimateOf(project),
        asOf: march,
      );

      expect(
        [for (final t in briefing.overview.todos) t.text],
        containsAll([
          'move the second display',
          'chase Extron on the DTP lead time',
        ]),
      );
      // ...and NOT also summarized in a line over the top of the list.
      expect(
        briefing.openLines.map((l) => l.message).join(' '),
        isNot(contains('still open')),
      );
    });

    test('overdue first, then dated, then the rest', () {
      final project = BuildingProject();
      project.addTodo('undated', created: DateTime(2026, 1, 1));
      project.addTodo('due later', due: DateTime(2026, 5, 1));
      project.addTodo('overdue', due: DateTime(2026, 1, 1));
      project.addTodo('due sooner', due: DateTime(2026, 4, 1));

      final todos = buildProjectBriefing(
        estimate: estimateOf(project),
        asOf: march,
      ).overview.todos;

      expect(
        [for (final t in todos) t.text],
        ['overdue', 'due sooner', 'due later', 'undated'],
      );
      expect(todos.first.late, isTrue);
      expect(todos.last.due, isNull);
      expect(todos.last.late, isFalse);
    });

    test('a blocked note sinks and says so', () {
      final project = BuildingProject();
      final waiting = project.addTodo('waiting on the room list');
      project.addTodo('something to do');
      project.setTodoState(waiting, ProjectTodoState.blocked);

      final todos = buildProjectBriefing(
        estimate: estimateOf(project),
        asOf: march,
      ).overview.todos;

      expect(todos.last.text, 'waiting on the room list');
      expect(todos.last.blocked, isTrue);
      expect(todos.first.blocked, isFalse);
    });

    test('a finished note is not on it', () {
      final project = BuildingProject();
      final done = project.addTodo('already handled');
      project.addTodo('still open');
      project.setTodoState(done, ProjectTodoState.done);

      final todos = buildProjectBriefing(
        estimate: estimateOf(project),
        asOf: march,
      ).overview.todos;
      expect(todos, hasLength(1));
      expect(todos.single.text, 'still open');
    });

    test('a long list stops and counts the rest', () {
      final project = BuildingProject();
      for (var i = 0; i < 11; i++) {
        project.addTodo('note $i');
      }
      final o = buildProjectBriefing(
        estimate: estimateOf(project),
        asOf: march,
      ).overview;

      expect(o.todos, hasLength(6));
      // Never pretends to be the whole list.
      expect(o.moreTodos, 5);
    });

    test('a note carries what it is filed under', () {
      final project = BuildingProject();
      project.addTodo('order the mounts', scopeLabel: 'punch list');
      project.addTodo('about the job');

      final byText = {
        for (final t in buildProjectBriefing(
          estimate: estimateOf(project),
          asOf: march,
        ).overview.todos)
          t.text: t,
      };
      expect(byText['order the mounts']!.scope, 'punch list');
      // The job as a whole has nothing to add.
      expect(byText['about the job']!.scope, isEmpty);
    });
  });

  group('copied to the clipboard', () {
    // "Where does this job stand" is almost never asked by the person looking
    // at the screen. Before this the answer was retyped out of a dialog by
    // somebody reading it off, which is how a status loses its dates.
    ProjectBriefing briefingOf() {
      final screen = part('Projection screen');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 4, 1),
        partLeadTimes: {screen.key: 200},
      );
      project.addTodo('chase Extron', due: DateTime(2026, 2, 1));
      return buildProjectBriefing(
        estimate: estimateOf(project, master: [screen]),
        asOf: march,
      );
    }

    test('it leads with the job and the day it was read', () {
      final text = renderBriefingText(briefingOf(), title: 'Bessey refresh');
      final lines = text.split('\n');
      expect(lines.first, 'Bessey refresh');
      expect(lines[1], 'Where it stands on 4 Mar 2026');
    });

    test('it carries the same facts the dialog shows', () {
      final text = renderBriefingText(briefingOf(), title: 'Bessey refresh');
      expect(text, contains('Project total'));
      expect(text, contains('Delivery'));
      expect(text, contains('1 Apr 2026'));
      expect(text, contains('STILL TO DO'));
      expect(text, contains('chase Extron'));
    });

    test('a warning travels with the pane that fixes it', () {
      final text = renderBriefingText(briefingOf(), title: 'Bessey refresh');
      expect(text, contains('ALREADY LATE'));
      expect(text, contains('past the date'));
      // A status mail that says what is wrong and not where it is answered
      // comes straight back as a question.
      expect(text, contains('Fixed on Timeline'));
      // The specifics come with it rather than being summarized away.
      expect(text, contains('Projection screen'));
    });

    test('a healthy job copies as a job with nothing wrong', () {
      final briefing = buildProjectBriefing(
        estimate: estimateOf(BuildingProject()),
        asOf: march,
      );
      final text = renderBriefingText(briefing, title: 'Quiet job');
      expect(text, contains('Quiet job'));
      expect(text, isNot(contains('ALREADY LATE')));
      // It ends on one newline, not none and not three — it is pasted into a
      // message body with text underneath it.
      expect(text.endsWith('\n'), isTrue);
      expect(text.endsWith('\n\n'), isFalse);
    });

    test('the drawing set is on the copy the same way it is on screen', () {
      final dir = Directory.systemTemp.createTempSync('rcb_briefing_copy');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      File(path.join(dir.path, 'A-101.pdf')).writeAsStringSync('%PDF-1.4');

      final project = BuildingProject();
      project.plans.add(
          ProjectPlan(id: project.nextPlanId(), filePath: 'A-101.pdf'));
      project.plans.add(
          ProjectPlan(id: project.nextPlanId(), filePath: 'A-999.pdf'));

      final text = renderBriefingText(
        buildProjectBriefing(
          estimate: estimateOf(project,
              projectPath: path.join(dir.path, 'bss_project.json')),
          asOf: march,
        ),
        title: 'Bessey refresh',
      );

      // The dialog and the copy are never allowed to disagree: the moment they
      // do, the written one is the one that gets believed.
      expect(text, contains('Plans'));
      expect(text, contains('2 · 1 not where the project says'));
      expect(text, contains('building plan is not where the project says'));
      expect(text, contains('Fixed on Plans'));
    });

    test('an untitled job still says what it is', () {
      final text = renderBriefingText(briefingOf(), title: '   ');
      expect(text.split('\n').first, 'Project');
    });
  });

  // ---------------------------------------------------------------------------
  //  THE JOB'S CALENDAR
  // ---------------------------------------------------------------------------
  //  The same facts the rows carry, in the order they happen. A list of rows
  //  cannot answer "is there room between the last order and the delivery",
  //  which is the question a briefing is opened to settle.

  group('the dates, as a calendar', () {
    test('today, the order dates and the delivery, earliest first', () {
      final screen = part('Projection screen');
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 12, 1),
        partLeadTimes: {screen.key: 30},
      );
      final briefing = buildProjectBriefing(
        estimate: estimateOf(project, master: [screen]),
        asOf: march,
      );

      final dates = briefingMilestones(briefing);
      expect(dates, isNotEmpty);
      // In date order, whatever order the briefing itself lists them in.
      for (var i = 1; i < dates.length; i++) {
        expect(
          dates[i].date.isBefore(dates[i - 1].date),
          isFalse,
          reason: 'a calendar is read left to right',
        );
      }
      // Today is on it, and so is the delivery date.
      expect(
        dates.any((d) => d.kind == BriefingDateKind.today),
        isTrue,
      );
      final delivery = dates.firstWhere(
        (d) => d.kind == BriefingDateKind.delivery,
      );
      expect(delivery.date, DateTime(2026, 12, 1));
      expect(delivery.late, isFalse);
      // And the order date the parts are worked back to.
      expect(
        dates.any((d) => d.kind == BriefingDateKind.order),
        isTrue,
      );
    });

    test('a date that has gone past is marked late', () {
      final screen = part('Projection screen');
      final project = BuildingProject(
        // Delivery is behind us, so both it and the order date for it are.
        deliveryDeadline: DateTime(2026, 2, 1),
        partLeadTimes: {screen.key: 30},
      );
      final briefing = buildProjectBriefing(
        estimate: estimateOf(project, master: [screen]),
        asOf: march,
      );

      final delivery = briefingMilestones(briefing).firstWhere(
        (d) => d.kind == BriefingDateKind.delivery,
      );
      expect(delivery.late, isTrue);
    });

    test('a job with no dates at all is today and nothing else', () {
      final briefing = buildProjectBriefing(
        estimate: estimateOf(BuildingProject()),
        asOf: march,
      );
      final dates = briefingMilestones(briefing);
      expect(dates, hasLength(1));
      expect(dates.single.kind, BriefingDateKind.today);
      expect(dates.single.date, march);
    });
  });
}
