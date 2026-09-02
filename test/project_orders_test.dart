import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_reminders.dart';
import 'package:extron_configurator/project_schedule.dart';

/// What has actually been bought, and where a lead time comes from.
///
/// Two features that exist for one reason: a schedule that does not know what
/// was ordered is a schedule that cries wolf the morning after the first
/// purchase order, and a lead time that lives only on a job is one that stops
/// getting typed. The failures worth guarding are a part that stays "late"
/// after it was bought, a catalog figure that quietly overrides what a vendor
/// quoted for THIS job, and an order record with no date taking a part off the
/// schedule on the strength of a text field.
void main() {
  MasterPartLine part(String description, {int? catalogLead}) => MasterPartLine(
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
    rfq: null,
    vendor: null,
    tagSource: RfqTagSource.none,
    unpriced: false,
    catalogLeadDays: catalogLead,
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

  final jan = DateTime(2026, 1, 1);

  group('the catalog remembers the lead time', () {
    test('a product with a catalog figure schedules itself', () {
      final screen = part('Projection screen', catalogLead: 42);
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 6, 1));
      // Nothing typed on the job at all.
      final line = schedulePart(line: screen, project: project, asOf: jan);

      expect(line.leadDays, 42);
      expect(line.leadFromCatalog, isTrue);
      expect(line.orderBy, DateTime(2026, 4, 20));
      expect(line.status, OrderStatus.onTrack);
    });

    test('what the JOB says beats what the catalog remembers', () {
      final screen = part('Projection screen', catalogLead: 42);
      final project = BuildingProject(
        deliveryDeadline: DateTime(2026, 6, 1),
        // The vendor quoted ten days for this order.
        partLeadTimes: {screen.key: 10},
      );
      final line = schedulePart(line: screen, project: project, asOf: jan);

      expect(line.leadDays, 10);
      expect(line.leadFromCatalog, isFalse);
      expect(line.orderBy, DateTime(2026, 5, 22));
    });

    test('no figure anywhere is still "nobody has asked"', () {
      final rack = part('Equipment rack');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 6, 1));
      final line = schedulePart(line: rack, project: project, asOf: jan);

      expect(line.leadDays, isNull);
      expect(line.status, OrderStatus.unknown);
      expect(line.leadFromCatalog, isFalse);
    });

    test('a catalog zero means in stock, not unrecorded', () {
      final cable = part('HDMI cable', catalogLead: 0);
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 6, 1));
      final line = schedulePart(line: cable, project: project, asOf: jan);

      expect(line.leadDays, 0);
      expect(line.status, OrderStatus.onTrack);
      expect(line.orderBy, DateTime(2026, 6, 1));
    });

    test('the catalog entry round-trips, and nonsense is dropped', () {
      const entry = AvDeviceTemplate(
        model: 'PowerLite L630U',
        leadTimeDays: 42,
        ports: [],
      );
      final back = AvDeviceTemplate.fromJson(entry.toJson());
      expect(back.leadTimeDays, 42);

      // Zero is kept — somebody checked.
      expect(
        AvDeviceTemplate.fromJson({'model': 'x', 'leadTimeDays': 0}).leadTimeDays,
        0,
      );
      // "6-8 weeks" typed where a number belongs must not read as in stock.
      expect(
        AvDeviceTemplate.fromJson({
          'model': 'x',
          'leadTimeDays': '6-8 weeks',
        }).leadTimeDays,
        isNull,
      );
      expect(
        AvDeviceTemplate.fromJson({'model': 'x', 'leadTimeDays': -5}).leadTimeDays,
        isNull,
      );
      // An entry that never had one says so rather than saying zero.
      expect(
        AvDeviceTemplate.fromJson({'model': 'x'}).leadTimeDays,
        isNull,
      );
    });

    test('a lead time can be taken back off an entry', () {
      const entry = AvDeviceTemplate(
        model: 'x',
        leadTimeDays: 42,
        ports: [],
      );
      expect(entry.copyWith(leadTimeDays: 10).leadTimeDays, 10);
      // Null means "leave it alone" everywhere else, so clearing needs its
      // own flag.
      expect(entry.copyWith(leadTimeDays: null).leadTimeDays, 42);
      expect(entry.copyWith(clearLeadTime: true).leadTimeDays, isNull);
    });
  });

  group('a part that has been bought', () {
    BuildingProject job() => BuildingProject(
      deliveryDeadline: DateTime(2026, 2, 1),
    );

    test('stops being late the moment it is ordered', () {
      final screen = part('Projection screen');
      final project = job()..setPartLeadTime(screen.key, 200);

      // Before: the order date went months ago.
      expect(
        schedulePart(line: screen, project: project, asOf: jan).status,
        OrderStatus.late,
      );

      project.setPartOrder(
        screen.key,
        PartOrder(poNumber: 'PO-1234', orderedOn: DateTime(2025, 12, 20)),
      );

      final after = schedulePart(line: screen, project: project, asOf: jan);
      expect(after.status, OrderStatus.ordered);
      expect(after.isBought, isTrue);
      expect(after.needsAttention, isFalse);
      expect(after.order!.poNumber, 'PO-1234');
    });

    test('is flagged when the vendor promises it too late', () {
      final screen = part('Projection screen');
      final project = job()..setPartLeadTime(screen.key, 10);
      project.setPartOrder(
        screen.key,
        PartOrder(
          orderedOn: DateTime(2026, 1, 2),
          // Needed 1 Feb; promised 15 Feb.
          expectedOn: DateTime(2026, 2, 15),
        ),
      );

      final line = schedulePart(line: screen, project: project, asOf: jan);
      expect(line.status, OrderStatus.arrivingLate);
      // Bought, so nothing on the ordering side can fix it — but somebody has
      // to know the room will not have it.
      expect(line.isBought, isTrue);
      expect(line.needsAttention, isTrue);
    });

    test('a promise that clears the need-by date is simply on order', () {
      final screen = part('Projection screen');
      final project = job()..setPartLeadTime(screen.key, 10);
      project.setPartOrder(
        screen.key,
        PartOrder(
          orderedOn: DateTime(2026, 1, 2),
          expectedOn: DateTime(2026, 1, 20),
        ),
      );
      expect(
        schedulePart(line: screen, project: project, asOf: jan).status,
        OrderStatus.ordered,
      );
    });

    test('is finished with once it has arrived', () {
      final screen = part('Projection screen');
      final project = job()..setPartLeadTime(screen.key, 200);
      project.setPartOrder(
        screen.key,
        PartOrder(
          orderedOn: DateTime(2025, 12, 20),
          // Even a promise that was late does not matter once it is here.
          expectedOn: DateTime(2026, 3, 1),
          receivedOn: DateTime(2026, 1, 1),
        ),
      );

      final line = schedulePart(line: screen, project: project, asOf: jan);
      expect(line.status, OrderStatus.received);
      expect(line.needsAttention, isFalse);
    });

    test('a PO number with no date does NOT count as ordered', () {
      final screen = part('Projection screen');
      final project = job()..setPartLeadTime(screen.key, 200);
      project.setPartOrder(screen.key, const PartOrder(poNumber: 'PO-1234'));

      // A record that cannot be measured against a deadline must not take the
      // part off the schedule on the strength of a text field.
      final line = schedulePart(line: screen, project: project, asOf: jan);
      expect(line.status, OrderStatus.late);
      expect(line.isBought, isFalse);
    });

    test('an empty record is removed rather than stored', () {
      final project = BuildingProject();
      project.setPartOrder('k', const PartOrder());
      expect(project.partOrders, isEmpty);
      project.setPartOrder('k', const PartOrder(orderedOn: null, qty: 0));
      expect(project.partOrders, isEmpty);
      project.setPartOrder('k', null);
      expect(project.partOrders, isEmpty);
    });
  });

  group('what the schedule and the calendar do with it', () {
    test('bought parts drop off the order dates', () {
      final a = part('Projection screen');
      final b = part('Ceiling mount');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 6, 1))
        ..setPartLeadTime(a.key, 30)
        ..setPartLeadTime(b.key, 30);
      final estimate = estimateOf(project, [a, b]);

      expect(buildProjectSchedule(estimate: estimate, asOf: jan).orderDays,
          hasLength(1));

      project.setPartOrder(a.key, PartOrder(orderedOn: DateTime(2026, 1, 2)));
      final after = buildProjectSchedule(estimate: estimate, asOf: jan);

      // The date is still there for the part that has NOT been bought...
      expect(after.orderDays, hasLength(1));
      expect(after.orderDays.single.parts, hasLength(1));
      expect(after.orderDays.single.parts.single.line.description,
          'Ceiling mount');
      // ...and the bought one is counted as bought.
      expect(after.onOrderCount, 1);
      expect(after.toBuyLines, hasLength(1));
    });

    test('the calendar does not remind anybody to buy what is bought', () {
      final a = part('Projection screen');
      final b = part('Ceiling mount');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 6, 1))
        ..setPartLeadTime(a.key, 30)
        ..setPartLeadTime(b.key, 45);
      project.setPartOrder(a.key, PartOrder(orderedOn: DateTime(2026, 1, 2)));

      final export = buildOrderReminders(
        estimate: estimateOf(project, [a, b]),
        asOf: jan,
      );
      expect(export.events, 1);
      expect(export.ics, contains('Ceiling mount'));
      expect(export.ics, isNot(contains('Projection screen')));
      // And it is not reported as unschedulable either — it is bought.
      expect(export.skipped, isEmpty);
    });

    test('everything bought leaves an empty calendar rather than a wrong one',
        () {
      final a = part('Projection screen');
      final project = BuildingProject(deliveryDeadline: DateTime(2026, 6, 1))
        ..setPartLeadTime(a.key, 30);
      project.setPartOrder(a.key, PartOrder(orderedOn: DateTime(2026, 1, 2)));

      expect(
        buildOrderReminders(
          estimate: estimateOf(project, [a]),
          asOf: jan,
        ).isEmpty,
        isTrue,
      );
    });
  });

  group('orders survive a save and a reload', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('orders_test_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('every field round-trips', () async {
      final project = BuildingProject(name: 'Bessey Hall');
      project.setPartOrder(
        'equipment|desc:~screen',
        PartOrder(
          poNumber: 'PO-1234',
          orderedOn: DateTime(2026, 1, 2),
          expectedOn: DateTime(2026, 2, 15),
          receivedOn: DateTime(2026, 2, 14),
          qty: 3,
          notes: 'split shipment',
        ),
      );

      final file = '${dir.path}/o_project.json';
      await project.save(file);
      final back = await BuildingProject.load(file);

      final order = back.orderForPart('equipment|desc:~screen')!;
      expect(order.poNumber, 'PO-1234');
      expect(order.orderedOn, DateTime(2026, 1, 2));
      expect(order.expectedOn, DateTime(2026, 2, 15));
      expect(order.receivedOn, DateTime(2026, 2, 14));
      expect(order.qty, 3);
      expect(order.notes, 'split shipment');
    });

    test('an empty record on a hand-edited file is dropped', () {
      final back = BuildingProject.fromJson({
        'rooms': <dynamic>[],
        'vendors': <dynamic>[],
        'partOrders': {
          'a': <String, dynamic>{},
          'b': {'orderedOn': '2026-01-02'},
        },
      });
      // A blank entry would take a part off the schedule while saying nothing
      // about when it was bought.
      expect(back.partOrders.keys, ['b']);
    });

    test('a project with only an order on it is not empty, and clones', () {
      final project = BuildingProject();
      project.setPartOrder('k', PartOrder(orderedOn: DateTime(2026, 1, 2)));
      expect(project.isEmpty, isFalse);

      final copy = project.clone();
      copy.setPartOrder('k', null);
      expect(project.partOrders, isNotEmpty);
      expect(copy.partOrders, isEmpty);
    });
  });
}
