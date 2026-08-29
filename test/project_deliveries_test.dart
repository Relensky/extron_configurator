import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';

/// The purchase orders a job was bought on, and where the kit ended up.
///
/// Both exist for one reason: an order record answers "was this bought" and
/// stops there, so the weeks between the loading dock and the finished room —
/// which is where a job actually loses things — were not written down
/// anywhere.
///
/// The failures worth guarding are all about a LINK going quietly wrong. A PO
/// renumbered in one place and left dangling on forty parts. A part order
/// written under an older build that never joins the PO list, so "what is on
/// PO-1188" answers nothing. A returned pallet still counted as kit the job
/// has. And a signed note losing the name or the time that is the whole reason
/// it is signed.
void main() {
  group('the job carries its purchase orders', () {
    test('a number is one PO however it was typed', () {
      final project = BuildingProject();
      final first = project.addPo(number: 'PO-1188', vendor: 'Extron');
      final again = project.addPo(number: ' po-1188 ');

      // The same paperwork, so the same row - not a second one that splits
      // what is on the PO across two answers.
      expect(again.id, first.id);
      expect(project.purchaseOrders, hasLength(1));
      expect(project.poByNumber('PO-1188')?.vendor, 'Extron');
    });

    test('renumbering carries the parts and the deliveries across', () {
      final project = BuildingProject();
      final po = project.addPo(number: 'PO-1188');
      project.setPartOrder(
        'equipment|desc:~screen',
        PartOrder(poNumber: 'PO-1188', orderedOn: DateTime(2026, 3, 4)),
      );
      project.addDelivery(
        partKey: 'equipment|desc:~screen',
        poNumber: 'po-1188',
        qty: 2,
        deliveredOn: DateTime(2026, 4, 1),
      );

      expect(project.renamePo(po.id, 'PO-1188-A'), isTrue);

      expect(project.poById(po.id)?.number, 'PO-1188-A');
      expect(
        project.orderForPart('equipment|desc:~screen')!.poNumber,
        'PO-1188-A',
      );
      expect(project.deliveries.single.poNumber, 'PO-1188-A');
      // And the PO can still be asked what is on it, which is the whole point
      // of carrying the parts across rather than leaving them pointing at a
      // number nothing has any more.
      expect(project.partsOnPo('PO-1188-A'), ['equipment|desc:~screen']);
    });

    test('renumbering onto a number the job already has is refused', () {
      final project = BuildingProject();
      final first = project.addPo(number: 'PO-1188');
      project.addPo(number: 'PO-1200');

      expect(project.renamePo(first.id, 'PO-1200'), isFalse);
      expect(project.renamePo(first.id, '   '), isFalse);
      expect(project.poById(first.id)?.number, 'PO-1188');
    });

    test('deleting a PO leaves the parts saying what they were bought on', () {
      final project = BuildingProject();
      final po = project.addPo(number: 'PO-1188');
      project.setPartOrder(
        'k',
        PartOrder(poNumber: 'PO-1188', orderedOn: DateTime(2026, 3, 4)),
      );

      project.removePo(po.id);

      expect(project.purchaseOrders, isEmpty);
      // Removing the job's copy of the paperwork is not a statement that the
      // part was never bought on it.
      expect(project.orderForPart('k')!.poNumber, 'PO-1188');
    });

    test('a PO typed onto a part before the list existed joins it', () {
      // A file written by the build that only had a per-part PO field.
      final back = BuildingProject.fromJson({
        'rooms': <dynamic>[],
        'partOrders': {
          'k1': {'poNumber': 'PO-1188', 'orderedOn': '2026-03-04'},
          'k2': {'poNumber': 'po-1188', 'orderedOn': '2026-03-04'},
          'k3': {'poNumber': 'PO-1200', 'orderedOn': '2026-03-05'},
        },
      });

      // Two POs, not three: the two spellings of 1188 are one purchase order.
      expect(back.purchaseOrders.map((p) => p.number), ['PO-1188', 'PO-1200']);
      expect(back.partsOnPo('PO-1188'), ['k1', 'k2']);
    });

    test('adopting is idempotent - opening twice does not double the list', () {
      final once = BuildingProject.fromJson({
        'rooms': <dynamic>[],
        'partOrders': {
          'k1': {'poNumber': 'PO-1188', 'orderedOn': '2026-03-04'},
        },
      });
      final twice = BuildingProject.fromJson(once.toJson());
      expect(twice.purchaseOrders, hasLength(1));
      expect(twice.purchaseOrders.single.id, once.purchaseOrders.single.id);
    });
  });

  group('where the kit is', () {
    BuildingProject withThreeLots() {
      final project = BuildingProject();
      // 18 wall plates bought; 6 into a room, 10 on a shelf, 2 sent back.
      project.addDelivery(
        partKey: 'plate',
        itemName: 'Wall plate',
        qty: 6,
        deliveredOn: DateTime(2026, 4, 1),
        state: DeliveryState.installed,
        roomId: 'room1',
      );
      project.addDelivery(
        partKey: 'plate',
        itemName: 'Wall plate',
        qty: 10,
        deliveredOn: DateTime(2026, 4, 1),
        state: DeliveryState.stored,
        location: 'Bessey basement, rack 3',
      );
      project.addDelivery(
        partKey: 'plate',
        itemName: 'Wall plate',
        qty: 2,
        deliveredOn: DateTime(2026, 4, 1),
        state: DeliveryState.returned,
      );
      return project;
    }

    test('a lot that went back is not kit the job has', () {
      final project = withThreeLots();
      expect(project.deliveredQty('plate'), 16);
      expect(project.installedQty('plate'), 6);
      expect(project.awaitingInstallQty('plate'), 10);
    });

    test('kit on the dock counts as waiting, the same as kit on a shelf', () {
      final project = BuildingProject();
      project.addDelivery(partKey: 'p', qty: 4);
      expect(project.deliveries.single.state, DeliveryState.delivered);
      expect(project.awaitingInstallQty('p'), 4);
      expect(project.installedQty('p'), 0);
    });

    test('an install dates itself and a move out of a room undates it', () {
      final project = BuildingProject();
      final row = project.addDelivery(
        partKey: 'p',
        qty: 1,
        deliveredOn: DateTime(2026, 4, 1),
        state: DeliveryState.installed,
      );
      expect(row.installedOn, DateTime(2026, 4, 1));

      project.updateDelivery(
        row.copyWith(state: DeliveryState.stored, clearInstalledOn: true),
      );
      expect(project.deliveryById(row.id)!.installedOn, isNull);
    });

    test('storage places are offered back, one spelling each', () {
      final project = BuildingProject();
      project.addDelivery(
        partKey: 'a',
        state: DeliveryState.stored,
        location: 'Bessey basement, rack 3',
      );
      project.addDelivery(
        partKey: 'b',
        state: DeliveryState.stored,
        location: 'bessey basement, rack 3',
      );
      project.addDelivery(
        partKey: 'c',
        state: DeliveryState.stored,
        location: 'Shipping container',
      );
      expect(project.storageLocations, [
        'Bessey basement, rack 3',
        'Shipping container',
      ]);
    });

    test('arrivals for one part come back newest first', () {
      final project = BuildingProject();
      project.addDelivery(partKey: 'p', qty: 1, deliveredOn: DateTime(2026, 1, 5));
      project.addDelivery(partKey: 'p', qty: 2, deliveredOn: DateTime(2026, 3, 9));
      project.addDelivery(partKey: 'q', qty: 3, deliveredOn: DateTime(2026, 2, 1));

      final rows = project.deliveriesForPart('p');
      expect(rows.map((r) => r.qty), [2, 1]);
    });

    test('where it is reads as a sentence, storage naming the shelf', () {
      expect(
        ProjectDelivery(
          id: 'd1',
          state: DeliveryState.stored,
          location: 'Bessey basement',
        ).whereText,
        'In storage - Bessey basement',
      );
      expect(
        ProjectDelivery(id: 'd2', state: DeliveryState.stored).whereText,
        'In storage',
      );
      expect(
        ProjectDelivery(id: 'd3').whereText,
        'On site',
      );
    });
  });

  group('a note carries who wrote it and when', () {
    test('the name and the moment are taken, not typed', () {
      final note = ProjectNote.now(
        '  2 arrived damaged  ',
        user: 'dstanley',
        at: DateTime(2026, 3, 12, 14, 32),
      );
      expect(note.text, '2 arrived damaged');
      expect(note.user, 'dstanley');
      // WITH THE CLOCK ON. Two notes on one afternoon are two notes, and a
      // date alone loses the order they were written in.
      expect(note.at, DateTime(2026, 3, 12, 14, 32));
    });

    test('notes stack rather than overwrite', () {
      final project = BuildingProject();
      final row = project.addDelivery(partKey: 'p', qty: 6);
      project.addDeliveryNote(
        row.id,
        ProjectNote.now('2 damaged', user: 'dstanley', at: DateTime(2026, 3, 12)),
      );
      project.addDeliveryNote(
        row.id,
        ProjectNote.now(
          'replacements promised for the 28th',
          user: 'jperez',
          at: DateTime(2026, 3, 19),
        ),
      );

      final notes = project.deliveryById(row.id)!.notes;
      expect(notes.map((n) => n.user), ['dstanley', 'jperez']);
      expect(notes.last.text, 'replacements promised for the 28th');
    });

    test('an empty note is not a note', () {
      final project = BuildingProject();
      final row = project.addDelivery(partKey: 'p');
      expect(
        project.addDeliveryNote(
          row.id,
          ProjectNote.now('   ', user: 'x', at: DateTime(2026, 3, 1)),
        ),
        isFalse,
      );
      expect(project.deliveryById(row.id)!.notes, isEmpty);
    });

    test('a note can be taken back off, and a missing one is not an error', () {
      final project = BuildingProject();
      final row = project.addDelivery(partKey: 'p');
      project.addDeliveryNote(
        row.id,
        ProjectNote.now('typo', user: 'x', at: DateTime(2026, 3, 1)),
      );
      expect(project.removeDeliveryNote(row.id, 0), isTrue);
      expect(project.removeDeliveryNote(row.id, 0), isFalse);
      expect(project.removeDeliveryNote('nope', 0), isFalse);
    });
  });

  group('the file', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('rcb_deliveries');
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('every field round-trips', () async {
      final project = BuildingProject(name: 'Bessey Hall');
      project.addPo(
        number: 'PO-1188',
        vendorId: 'vendor1',
        issuedOn: DateTime(2026, 3, 4),
        expectedOn: DateTime(2026, 4, 30),
        amount: 12480,
      );
      project.addPoNote(
        project.purchaseOrders.single.id,
        ProjectNote.now(
          'acknowledged, 6 week lead',
          user: 'dstanley',
          at: DateTime(2026, 3, 5, 9, 15),
        ),
      );
      final row = project.addDelivery(
        partKey: 'equipment|desc:~plate',
        itemName: 'Wall plate',
        poNumber: 'PO-1188',
        qty: 6,
        deliveredOn: DateTime(2026, 4, 1),
        state: DeliveryState.installed,
        roomId: 'room1',
        installedOn: DateTime(2026, 4, 11),
      );
      project.addDeliveryNote(
        row.id,
        ProjectNote.now(
          '2 arrived damaged',
          user: 'jperez',
          at: DateTime(2026, 4, 1, 16, 40),
        ),
      );

      final file = '${dir.path}/d_project.json';
      await project.save(file);
      final back = await BuildingProject.load(file);

      final po = back.poByNumber('PO-1188')!;
      expect(po.vendorId, 'vendor1');
      expect(po.issuedOn, DateTime(2026, 3, 4));
      expect(po.expectedOn, DateTime(2026, 4, 30));
      expect(po.amount, 12480);
      expect(po.notes.single.user, 'dstanley');
      expect(po.notes.single.at, DateTime(2026, 3, 5, 9, 15));

      final saved = back.deliveries.single;
      expect(saved.partKey, 'equipment|desc:~plate');
      expect(saved.itemName, 'Wall plate');
      expect(saved.poNumber, 'PO-1188');
      expect(saved.qty, 6);
      expect(saved.deliveredOn, DateTime(2026, 4, 1));
      expect(saved.state, DeliveryState.installed);
      expect(saved.roomId, 'room1');
      expect(saved.installedOn, DateTime(2026, 4, 11));
      expect(saved.notes.single.text, '2 arrived damaged');
      expect(saved.notes.single.user, 'jperez');
    });

    test('ids are never handed out twice after a reload', () async {
      final project = BuildingProject();
      project.addPo(number: 'PO-1');
      project.addDelivery(partKey: 'p');

      final file = '${dir.path}/i_project.json';
      await project.save(file);
      final back = await BuildingProject.load(file);

      // A reused id would merge two deliveries into one, and moving one would
      // move the other.
      expect(back.nextPoId(), 'po2');
      expect(back.nextDeliveryId(), 'del2');
    });

    test('a hand-edited state this build does not know still counts as here', () {
      final back = BuildingProject.fromJson({
        'rooms': <dynamic>[],
        'deliveries': [
          {'id': 'del1', 'partKey': 'p', 'qty': 3, 'state': 'teleported'},
        ],
      });
      expect(back.deliveries.single.state, DeliveryState.delivered);
      expect(back.deliveredQty('p'), 3);
    });

    test('a job with no deliveries writes no keys for them', () {
      final json = BuildingProject(name: 'x').toJson();
      expect(json.containsKey('deliveries'), isFalse);
      expect(json.containsKey('purchaseOrders'), isFalse);
    });

    test('an undo copy does not share note lists with the job', () {
      final project = BuildingProject();
      final row = project.addDelivery(partKey: 'p');
      final snapshot = project.clone();

      project.addDeliveryNote(
        row.id,
        ProjectNote.now('after', user: 'x', at: DateTime(2026, 5, 1)),
      );

      expect(project.deliveryById(row.id)!.notes, hasLength(1));
      expect(snapshot.deliveryById(row.id)!.notes, isEmpty);
    });
  });
}
