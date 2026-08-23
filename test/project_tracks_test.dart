import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_reminders.dart';
import 'package:extron_configurator/project_schedule.dart';

/// Delivery phases, and the calendar that gets the order dates out of the app.
///
/// The failure this guards is a job that looks scheduled and is not: a part
/// whose phase was deleted still claiming a date, a phase date that does not
/// actually move its parts' order dates, or a re-exported calendar that
/// duplicates every event instead of revising it.
void main() {
  MasterPartLine part(String description) => MasterPartLine(
    key: masterPartKey(kind: 'equipment', description: description),
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

  final jan = DateTime(2026, 1, 1);

  group('a phase has its own deadline', () {
    test('a part on a phase is worked back from the PHASE date', () {
      final conduit = part('Conduit');
      final rack = part('Equipment rack');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 9, 1));
      final infra = project.addTrack(
        'Infrastructure',
        deadline: DateTime(2026, 4, 1),
      );
      project.setPartTrack(conduit.key, infra.id);
      project.setPartLeadTime(conduit.key, 30);
      project.setPartLeadTime(rack.key, 30);

      final byName = {
        for (final l in buildProjectSchedule(
          estimate: estimateOf(project, [conduit, rack]),
          asOf: jan,
        ).lines)
          l.line.description: l,
      };

      // The conduit rides the April phase; the rack still rides the job.
      expect(byName['Conduit']!.orderBy, DateTime(2026, 3, 2));
      expect(byName['Conduit']!.track?.name, 'Infrastructure');
      expect(byName['Equipment rack']!.orderBy, DateTime(2026, 8, 2));
      expect(byName['Equipment rack']!.track, isNull);
      expect(byName['Equipment rack']!.trackName, 'The job');
    });

    test('moving a phase date moves only its own parts', () {
      final conduit = part('Conduit');
      final rack = part('Equipment rack');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 9, 1));
      final infra = project.addTrack(
        'Infrastructure',
        deadline: DateTime(2026, 4, 1),
      );
      project.setPartTrack(conduit.key, infra.id);
      project.setPartLeadTime(conduit.key, 30);
      project.setPartLeadTime(rack.key, 30);
      final estimate = estimateOf(project, [conduit, rack]);

      project.setTrackDeadline(infra.id, DateTime(2026, 5, 1));
      final byName = {
        for (final l in buildProjectSchedule(estimate: estimate, asOf: jan)
            .lines)
          l.line.description: l,
      };
      expect(byName['Conduit']!.orderBy, DateTime(2026, 4, 1));
      expect(byName['Equipment rack']!.orderBy, DateTime(2026, 8, 2));
    });

    test('a part date still beats its phase date', () {
      final screen = part('Screen');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 9, 1));
      final infra = project.addTrack(
        'Infrastructure',
        deadline: DateTime(2026, 4, 1),
      );
      project.setPartTrack(screen.key, infra.id);
      project.setPartLeadTime(screen.key, 10);
      project.setPartNeedBy(screen.key, DateTime(2026, 2, 1));

      final line = schedulePart(line: screen, project: project, asOf: jan);
      // Most specific wins: the part's own date, not the phase's.
      expect(line.orderBy, DateTime(2026, 1, 22));
      expect(line.needByIsOwn, isTrue);
    });

    test('a phase with no date of its own falls back to the job', () {
      final conduit = part('Conduit');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 9, 1));
      final phase = project.addTrack('Phase 2');
      project.setPartTrack(conduit.key, phase.id);
      project.setPartLeadTime(conduit.key, 30);

      expect(
        schedulePart(line: conduit, project: project, asOf: jan).orderBy,
        DateTime(2026, 8, 2),
      );
    });

    test('a job with no phases behaves exactly as it did before', () {
      final rack = part('Equipment rack');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 9, 1));
      project.setPartLeadTime(rack.key, 30);
      expect(project.tracks, isEmpty);
      expect(
        schedulePart(line: rack, project: project, asOf: jan).orderBy,
        DateTime(2026, 8, 2),
      );
    });

    test('removing a phase takes its pins with it', () {
      final conduit = part('Conduit');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 9, 1));
      final infra = project.addTrack(
        'Infrastructure',
        deadline: DateTime(2026, 4, 1),
      );
      project.setPartTrack(conduit.key, infra.id);
      project.setPartLeadTime(conduit.key, 30);

      project.removeTrack(infra.id);
      // Not left pointing at a phase with no row to click.
      expect(project.partTracks, isEmpty);
      expect(project.trackForPart(conduit.key), isNull);
      expect(
        schedulePart(line: conduit, project: project, asOf: jan).orderBy,
        DateTime(2026, 8, 2),
      );
    });

    test('the starter split is the two phases a job usually has', () {
      final project = BuildingProject();
      project.tracks.addAll(starterTracks(project));
      expect(
        [for (final t in project.tracks) t.name],
        ['Infrastructure', 'Tech install'],
      );
      expect(project.tracks.map((t) => t.id).toSet(), hasLength(2));
    });

    test('phases group the schedule, job parts last', () {
      final conduit = part('Conduit');
      final rack = part('Equipment rack');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 9, 1));
      final infra = project.addTrack(
        'Infrastructure',
        deadline: DateTime(2026, 4, 1),
      );
      project.setPartTrack(conduit.key, infra.id);
      project.setPartLeadTime(conduit.key, 30);
      project.setPartLeadTime(rack.key, 30);

      final grouped = buildProjectSchedule(
        estimate: estimateOf(project, [conduit, rack]),
        asOf: jan,
      ).byTrack(project);

      expect(grouped, hasLength(2));
      expect(grouped.first.track?.name, 'Infrastructure');
      expect(grouped.first.parts.single.line.description, 'Conduit');
      // The ones riding the job itself are still shown, at the end.
      expect(grouped.last.track, isNull);
      expect(grouped.last.parts.single.line.description, 'Equipment rack');
    });
  });

  group('phases survive a save and a reload', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('tracks_test_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('the phases and their pins round-trip', () async {
      final conduit = part('Conduit');
      final project = BuildingProject(name: 'Bessey');
      final infra = project.addTrack(
        'Infrastructure',
        deadline: DateTime(2026, 4, 1),
        notes: 'while the walls are open',
      );
      project.setPartTrack(conduit.key, infra.id);

      final file = '${dir.path}/t_project.json';
      await project.save(file);
      final back = await BuildingProject.load(file);

      expect(back.tracks, hasLength(1));
      expect(back.tracks.single.name, 'Infrastructure');
      expect(back.tracks.single.deadline, DateTime(2026, 4, 1));
      expect(back.tracks.single.notes, 'while the walls are open');
      expect(back.partTracks[conduit.key], infra.id);
      // A fresh phase must not reuse an id that is already on the file.
      expect(back.addTrack('Phase 2').id, isNot(infra.id));
    });

    test('a nameless phase is dropped, and clone does not share', () {
      final back = BuildingProject.fromJson({
        'rooms': <dynamic>[],
        'vendors': <dynamic>[],
        'tracks': [
          {'id': 'track1', 'name': 'Real'},
          {'id': 'track2', 'name': '   '},
        ],
      });
      expect(back.tracks, hasLength(1));

      final copy = back.clone();
      copy.addTrack('Another');
      expect(back.tracks, hasLength(1));
      expect(copy.tracks, hasLength(2));
    });
  });

  group('the calendar export', () {
    ProjectEstimate job() {
      final conduit = part('Conduit');
      final rack = part('Equipment rack');
      final project = BuildingProject(
        name: 'Bessey Hall',
        jobNumber: 'J-1234',
        deliveryDeadline: DateTime(2026, 9, 1),
      );
      project.setPartLeadTime(conduit.key, 30);
      project.setPartLeadTime(rack.key, 30);
      return estimateOf(project, [conduit, rack]);
    }

    test('one event per order DATE, not per part', () {
      final export = buildOrderReminders(estimate: job(), asOf: jan);
      // Both parts share 2 August, so it is one trip to purchasing.
      expect(export.events, 1);
      expect('BEGIN:VEVENT'.allMatches(export.ics).length, 1);
      expect(export.ics, contains('DTSTART;VALUE=DATE:20260802'));
      // All-day: DTEND is exclusive, so it is the next day.
      expect(export.ics, contains('DTEND;VALUE=DATE:20260803'));
    });

    test('it carries an alarm ahead of the date', () {
      final export = buildOrderReminders(estimate: job(), asOf: jan);
      expect(export.ics, contains('BEGIN:VALARM'));
      expect(export.ics, contains('TRIGGER:-P${kReminderLeadDays}D'));
    });

    test('re-exporting revises rather than duplicates', () {
      final estimate = job();
      final first = buildOrderReminders(estimate: estimate, asOf: jan);
      final second = buildOrderReminders(
        estimate: estimate,
        asOf: jan,
        sequence: 1,
      );
      // Same uid, higher sequence: a calendar treats the second as an update.
      final uid = RegExp(r'UID:(\S+)').firstMatch(first.ics)!.group(1);
      expect(second.ics, contains('UID:$uid'));
      expect(first.ics, contains('SEQUENCE:0'));
      expect(second.ics, contains('SEQUENCE:1'));
    });

    test('what could not be dated is reported, not dropped silently', () {
      final conduit = part('Conduit');
      final mystery = part('Mystery box');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 9, 1));
      project.setPartLeadTime(conduit.key, 30);
      // No lead time on the second one.
      final export = buildOrderReminders(
        estimate: estimateOf(project, [conduit, mystery]),
        asOf: jan,
      );
      expect(export.events, 1);
      expect(export.skipped, hasLength(1));
      expect(export.skipped.single, contains('Mystery box'));
      expect(export.skipped.single, contains('no lead time'));
    });

    test('one phase can be exported on its own', () {
      final conduit = part('Conduit');
      final rack = part('Equipment rack');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 9, 1));
      final infra = project.addTrack(
        'Infrastructure',
        deadline: DateTime(2026, 4, 1),
      );
      project.setPartTrack(conduit.key, infra.id);
      project.setPartLeadTime(conduit.key, 30);
      project.setPartLeadTime(rack.key, 30);

      final export = buildOrderReminders(
        estimate: estimateOf(project, [conduit, rack]),
        asOf: jan,
        trackId: infra.id,
      );
      expect(export.events, 1);
      expect(export.ics, contains('DTSTART;VALUE=DATE:20260302'));
      expect(export.ics, contains('Conduit'));
      expect(export.ics, isNot(contains('Equipment rack')));
    });

    test('it is a well-formed file a calendar will accept', () {
      final export = buildOrderReminders(estimate: job(), asOf: jan);
      expect(export.ics, startsWith('BEGIN:VCALENDAR\r\n'));
      expect(export.ics.trimRight(), endsWith('END:VCALENDAR'));
      expect(export.ics, contains('VERSION:2.0'));
      // CRLF throughout, which the spec requires and Outlook enforces.
      for (final line in export.ics.split('\r\n')) {
        expect(line, isNot(contains('\n')));
        // Folded to the octet limit; a long part list breaks this instantly.
        expect(line.length, lessThanOrEqualTo(75));
      }
    });

    test('a job with nothing dated exports nothing rather than an empty file',
        () {
      final project = BuildingProject();
      final export = buildOrderReminders(
        estimate: estimateOf(project, [part('Conduit')]),
        asOf: jan,
      );
      expect(export.isEmpty, isTrue);
      expect(export.events, 0);
    });

    test('the file name says the job and the phase', () {
      final project = BuildingProject(name: 'Bessey Hall - AV refresh');
      expect(reminderFileStem(project), 'bessey-hall-av-refresh_order_dates');
      expect(
        reminderFileStem(project, trackName: 'Tech install'),
        'bessey-hall-av-refresh_tech-install_order_dates',
      );
    });
  });
}
