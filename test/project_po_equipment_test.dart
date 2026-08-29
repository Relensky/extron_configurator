import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_view.dart';

/// WHAT WENT OUT ON THIS PO.
///
/// The Bought? box on a part answers "what did this go out on". Nothing
/// answered the other way round — "what went out on PO-1188" — which is the
/// question a purchase order is opened with, the one a packing slip has to be
/// checked against, and the one nobody could answer without walking the whole
/// master list and reading a text field on every row.
///
/// So a PO is given its equipment from the PO, in one pass down the vendor's
/// lines: a PO goes to ONE company and covers that company's parts, and made
/// one part at a time what actually happened was that the first three got the
/// number and the rest stayed blank.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_po_kit'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A room with an Epson projector and a Sharp display on the drawing — two
  /// parts from two makers, so a vendor rule has something to sort.
  String writeRoom(String stem, String name) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [
        AvNode(
          id: 'PROJECTORDEVICE_1',
          label: 'Projector',
          model: 'PowerLite L610U',
          pos: Offset.zero,
          ports: const [],
        ).toJson(),
        AvNode(
          id: 'DISPLAYDEVICE_1',
          label: 'Display',
          model: 'Aquos 65',
          pos: Offset.zero,
          ports: const [],
        ).toJson(),
      ],
    }));
    return configPath;
  }

  /// The job, and the id of the vendor whose rule claims the Epson line. A new
  /// project starts with the usual vendor split on it, so ours is found by the
  /// row that was added rather than by being the only one.
  ({AppStateProvider p, String vendorId}) job() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'PowerLite L610U',
        manufacturer: 'Epson',
        category: 'Projector',
        price: 1000,
        ports: [],
      ))
      ..upsert(const AvDeviceTemplate(
        model: 'Aquos 65',
        manufacturer: 'Sharp',
        category: 'Display',
        price: 400,
        ports: [],
      ));
    p.newProject(name: 'Bessey refresh', building: 'BSS');
    // First in the list, so this rule wins the Epson line over anything the
    // starter split claims - see [BuildingProject.vendorForPart].
    final vendor = p.addProjectVendor(name: 'Epson Direct');
    p.updateProjectVendor(
      ProjectVendor(
        id: vendor.id,
        name: 'Epson Direct',
        manufacturers: const ['Epson'],
      ),
    );
    p.addRoomToProject(writeRoom('r0', 'Bessey 101'));
    return (p: p, vendorId: vendor.id);
  }

  Future<void> openDeliveries(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1700, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: ProjectView())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project_pane_deliveries')));
    await tester.pumpAndSettle();
  }

  /// The master keys, projector first — the order the parts list deals them.
  ({String epson, String sharp}) keysOf(AppStateProvider p) {
    String found(String maker) {
      for (final line in p.priceProject().master) {
        if (line.manufacturer.toLowerCase() == maker.toLowerCase()) {
          return line.key;
        }
      }
      throw StateError('no $maker part on the job');
    }

    return (epson: found('Epson'), sharp: found('Sharp'));
  }

  testWidgets("the box opens on the PO's own vendor, and can be widened", (
    tester,
  ) async {
    final (:p, :vendorId) = job();
    final po = p.addProjectPo(
      number: 'PO-1188',
      vendorId: vendorId,
      issuedOn: DateTime(2026, 3, 4),
    );
    await openDeliveries(tester, p);

    await tester.tap(find.byKey(ValueKey('po_parts_${po.id}')));
    await tester.pumpAndSettle();

    final keys = keysOf(p);
    // Only what this vendor is supplying: a hundred-line master list with the
    // other vendors mixed into it is one nobody reads to the bottom of.
    expect(find.byKey(ValueKey('po_part_${keys.epson}')), findsOneWidget);
    expect(find.byKey(ValueKey('po_part_${keys.sharp}')), findsNothing);

    // And the filter comes off, because a PO does pick up a part the vendor
    // rules never claimed.
    await tester.tap(find.byKey(const ValueKey('po_parts_vendor_only')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('po_part_${keys.sharp}')), findsOneWidget);
  });

  testWidgets('ticking puts the equipment on the PO, ordered on its date', (
    tester,
  ) async {
    final (:p, :vendorId) = job();
    final po = p.addProjectPo(
      number: 'PO-1188',
      vendorId: vendorId,
      issuedOn: DateTime(2026, 3, 4),
    );
    await openDeliveries(tester, p);
    final keys = keysOf(p);

    await tester.tap(find.byKey(ValueKey('po_parts_${po.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('po_part_${keys.epson}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('po_parts_save')));
    await tester.pumpAndSettle();

    expect(p.project.partsOnPo('PO-1188'), [keys.epson]);
    final order = p.project.orderForPart(keys.epson)!;
    // A part bought on a PO is ORDERED. A number with no date does not count
    // as an order, and would leave the part on the list of things to buy.
    expect(order.isOrdered, isTrue);
    expect(order.orderedOn, DateTime(2026, 3, 4));
    expect(p.projectDirty, isTrue, reason: 'this is unsaved work');

    // The card says what is on it without the dialog being reopened.
    expect(find.text('Equipment on this PO (1)'), findsOneWidget);

    // AND IT IS IN THE HISTORY, under the part and under the PO — "this says
    // bought, who said so" is asked of the part, "when did the mounts go on
    // this" is asked of the PO, and one line cannot answer both.
    final log = p.project.history;
    expect(log.where((h) => h.itemKind == 'part'), isNotEmpty);
    expect(
      log.where((h) => h.itemKind == 'po' && h.summary.contains('put on it')),
      isNotEmpty,
    );
  });

  testWidgets('unticking takes it back off the PO and off the bought list', (
    tester,
  ) async {
    final (:p, vendorId: _) = job();
    final po = p.addProjectPo(number: 'PO-1188', issuedOn: DateTime(2026, 3, 4));
    final keys = keysOf(p);
    p.setProjectPartsOnPo(
      'PO-1188',
      onIt: [keys.epson],
      orderedOn: DateTime(2026, 3, 4),
    );
    await openDeliveries(tester, p);

    await tester.tap(find.byKey(ValueKey('po_parts_${po.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('po_part_${keys.epson}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('po_parts_save')));
    await tester.pumpAndSettle();

    expect(p.project.partsOnPo('PO-1188'), isEmpty);
    // Nothing left behind: an order date against no paperwork reads on the
    // timeline as a part somebody bought and cannot say where from.
    expect(p.project.orderForPart(keys.epson), isNull);
  });

  testWidgets('a delivery can be pulled straight off the PO number', (
    tester,
  ) async {
    final (:p, vendorId: _) = job();
    p.addProjectPo(number: 'PO-1188', issuedOn: DateTime(2026, 3, 4));
    final keys = keysOf(p);
    p.setProjectPartsOnPo('PO-1188', onIt: [keys.epson]);
    await openDeliveries(tester, p);

    await tester.tap(find.byKey(const ValueKey('delivery_log_new')));
    await tester.pumpAndSettle();

    // The job's numbers are on the field, so the PO is picked rather than
    // retyped off a packing slip and mistyped.
    await tester.tap(find.byKey(const ValueKey('delivery_po_pick')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PO-1188').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('delivery_qty')), '1');
    // AN ADDRESS NOBODY HAS TYPED BEFORE. A job takes delivery wherever the
    // vendor could get a truck that week, and the delivery worth recording is
    // the one that went somewhere no list would have offered.
    await tester.enterText(
      find.byKey(const ValueKey('delivery_location')),
      'Central Stores, 1 Campus Drive',
    );
    await tester.tap(find.byKey(const ValueKey('delivery_save')));
    await tester.pumpAndSettle();

    final row = p.project.deliveries.single;
    expect(row.poNumber, 'PO-1188');
    expect(row.qty, 1);
    // On site, and the place is part of the answer: 'on site' with nothing
    // after it sends somebody walking round a campus looking for a pallet.
    expect(row.state, DeliveryState.delivered);
    expect(row.location, 'Central Stores, 1 Campus Drive');
    expect(row.whereText, 'On site - Central Stores, 1 Campus Drive');
    expect(p.project.deliveriesForPo('PO-1188'), hasLength(1));

    // And the place is offered back the next time, one spelling.
    expect(p.project.deliveryLocations, ['Central Stores, 1 Campus Drive']);
  });
}
