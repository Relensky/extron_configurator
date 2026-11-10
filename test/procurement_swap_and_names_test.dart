import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/in_app_browser.dart';
import 'package:extron_configurator/procurement_log.dart';
import 'package:extron_configurator/procurement_sync.dart';
import 'package:extron_configurator/responsibility_matrix.dart';
import 'package:extron_configurator/xlsx_writer.dart' show XlsxTint;

/// Names and the procurement log following a part when it changes.
void main() {
  group('swappedProcurementKey', () {
    test('moves model and no-cost model keys', () {
      expect(swappedProcurementKey('model:dmp 64', 'DMP 64', 'DMP 128'),
          'model:dmp 128');
      expect(
          swappedProcurementKey('nocost:model:dmp 64', 'DMP 64', 'DMP 128'),
          'nocost:model:dmp 128');
    });

    test('leaves other keys alone', () {
      expect(swappedProcurementKey('model:other', 'DMP 64', 'DMP 128'), isNull);
      expect(swappedProcurementKey('device:n1', 'DMP 64', 'DMP 128'), isNull);
      expect(swappedProcurementKey('model:dmp 64', 'DMP 64', 'dmp 64'), isNull);
    });
  });

  group('swapProcurementModel', () {
    const a = ProcurementEntry(
      id: '1',
      roomId: 'r1',
      lineKey: 'model:dmp 64',
      notes: 'keep me',
    );
    const b = ProcurementEntry(id: '2', roomId: 'r2', lineKey: 'model:dmp 64');

    test('moves lines in the swapped rooms only, keeping what they say', () {
      final out = swapProcurementModel([a, b], {'r1'}, 'DMP 64', 'DMP 128');
      expect(out[0].lineKey, 'model:dmp 128');
      expect(out[0].notes, 'keep me');
      expect(out[1].lineKey, 'model:dmp 64');
    });

    test('does not double a room already logging the new part', () {
      const there = ProcurementEntry(
        id: '3',
        roomId: 'r1',
        lineKey: 'model:dmp 128',
      );
      final out = swapProcurementModel([a, there], {'r1'}, 'DMP 64', 'DMP 128');
      expect(out[0].lineKey, 'model:dmp 64');
    });
  });

  group('ProjectDelivery.nameOn', () {
    test('takes the part\'s current name while it is on the list', () {
      final d = ProjectDelivery(id: 'd1', partKey: 'k', itemName: 'Old name');
      expect(d.nameOn({'k': 'New name'}), 'New name');
    });

    test('falls back to the stored name', () {
      final d = ProjectDelivery(id: 'd1', partKey: 'k', itemName: 'Old name');
      expect(d.nameOn({}), 'Old name');
      expect(d.nameOn({'k': '  '}), 'Old name');
      final loose = ProjectDelivery(id: 'd2', itemName: 'Loaner');
      expect(loose.nameOn({'': 'x'}), 'Loaner');
    });
  });

  group('a part keeps its records when its key changes', () {
    test('order, deliveries and pin move to the new key', () {
      final project = BuildingProject(
        partOrders: {
          'equipment|model:x': PartOrder(
            poNumber: 'PO-1',
            orderedOn: DateTime(2027, 1, 5),
          ),
        },
        partRfqs: {'equipment|model:x': 'pkg1'},
        deliveries: [
          ProjectDelivery(id: 'd1', partKey: 'equipment|model:x', qty: 2),
        ],
      );
      expect(project.movePartKey('equipment|model:x', 'equipment|pn:123'),
          isTrue);
      expect(project.orderForPart('equipment|pn:123')?.poNumber, 'PO-1');
      expect(project.partRfqs['equipment|pn:123'], 'pkg1');
      expect(project.deliveries.single.partKey, 'equipment|pn:123');
      expect(project.orderForPart('equipment|model:x'), isNull);
    });
  });

  group('the log follows orders and deliveries', () {
    test('ordered and delivered read off the job', () {
      final project = BuildingProject(
        partOrders: {
          'k': PartOrder(poNumber: 'PO-9', orderedOn: DateTime(2027, 2, 1)),
        },
        deliveries: [
          ProjectDelivery(id: 'd1', partKey: 'k', qty: 6,
              deliveredOn: DateTime(2027, 3, 9)),
        ],
      );
      expect(procurementOrderText(project, 'k'), startsWith('PO-9, '));
      expect(procurementDeliveryText(project, 'k', 18), startsWith('6 of 18'));
      expect(procurementDeliveryText(project, 'k', 6), startsWith('All 6'));
      expect(procurementOrderText(project, 'other'), '');
      expect(procurementDeliveryText(project, 'other', 4), '');
    });
  });

  group('a delivery logged with no count', () {
    test('stands for the rest of the part', () {
      final project = BuildingProject(
        deliveries: [ProjectDelivery(id: 'd1', partKey: 'k')],
      );
      expect(project.deliveredQty('k'), 0);
      expect(project.deliveredOf('k', 2), 2);
      expect(procurementDeliveryText(project, 'k', 2), startsWith('All 2'));
      expect(project.deliveredOf('other', 2), 0);
    });
  });

  group('a part can be kept untagged', () {
    test('the untagged pin beats a category rule, and clears back', () {
      final project = BuildingProject(
        rfqs: const [
          ProjectRfq(id: 'rfq2', categories: ['Display']),
        ],
      );
      expect(
        project.rfqForPart('k', category: 'Display back box').rfq?.id,
        'rfq2',
        reason: 'the rule takes it',
      );
      project.pinPart('k', kRfqUntaggedPin);
      final kept = project.rfqForPart('k', category: 'Display back box');
      expect(kept.rfq, isNull);
      expect(kept.source, RfqTagSource.pinned);
      project.pinPart('k', '');
      expect(
        project.rfqForPart('k', category: 'Display back box').rfq?.id,
        'rfq2',
      );
    });
  });

  group('the exported sheets look like the pages', () {
    String text(Object? cell) =>
        cell is XlsxTint ? cell.text : (cell ?? '').toString();

    test('procurement: device first, a band per room, colored pills', () {
      final sheet = procurementLogSheet('HIL', const [
        ProcurementEntry(
          id: 'p1',
          room: 'HIL 101',
          device: 'Ceiling mic',
          company: 'OFCI',
          status: ProcurementStatus.submitted,
        ),
      ]);
      final head = sheet.rows[3];
      expect(text(head.first), 'Device');
      expect(head.first, isA<XlsxTint>());
      expect(text(sheet.rows[4].first), startsWith('HIL 101'));
      final line = sheet.rows[5];
      expect(text(line.first), 'Ceiling mic');
      final company = line[head.indexWhere((c) => text(c) == 'Company')];
      expect(company, isA<XlsxTint>());
      expect((company as XlsxTint).fillHex, procurementCompanyTint('OFCI').fill);
      final status = line[head.indexWhere((c) => text(c) == 'Status')];
      expect(status, isA<XlsxTint>());
      expect(sheet.freezeColumns, 1);
      expect(sheet.columnWidths[0], greaterThan(30));
    });

    test('responsibility: scope across, parties under it, rooms down', () {
      final sheet = responsibilityMatrixSheet(
        const [
          ResponsibilityItem(
            id: 'r1',
            scope: 'Projector',
            furnishedBy: 'CTS',
            installedBy: 'Contractor',
            qtyByRoom: {'a': 2},
          ),
        ],
        projectName: 'HIL',
        roomNames: const [(id: 'a', name: 'HIL 101')],
      )!;
      final firsts = [for (final r in sheet.rows) if (r.isNotEmpty) text(r.first)];
      expect(firsts, containsAllInOrder(
          ['Scope', 'Furnished by', 'Installed by', 'Room', 'HIL 101']));
      final scope = sheet.rows.firstWhere(
          (r) => r.isNotEmpty && text(r.first) == 'Scope');
      expect(text(scope[1]), 'Projector');
      final room = sheet.rows.firstWhere(
          (r) => r.isNotEmpty && text(r.first) == 'HIL 101');
      expect(text(room[1]), '2');
      expect(firsts.any((t) => t.startsWith('Totals')), isTrue);
      expect(firsts, contains('Description of Work'));
    });
  });

  group('new browser window', () {
    test('knows the new-window switch for common browsers', () {
      expect(newWindowFlagFor(r'C:\Program Files\Google\Chrome\chrome.exe'),
          '--new-window');
      expect(newWindowFlagFor(r'C:\x\msedge.exe'), '--new-window');
      expect(newWindowFlagFor(r'C:\x\firefox.exe'), '-new-window');
      expect(newWindowFlagFor(r'C:\x\other.exe'), isNull);
    });

    test('reads the exe out of an open command', () {
      expect(
        exeFromOpenCommand(
            r'"C:\Program Files\Google\Chrome\Application\chrome.exe" --single-argument %1'),
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
      );
      expect(exeFromOpenCommand(r'C:\x\firefox.exe -osint -url "%1"'),
          r'C:\x\firefox.exe');
      expect(exeFromOpenCommand(''), isNull);
    });
  });
}
