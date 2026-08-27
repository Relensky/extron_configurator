import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_port_editor.dart' show kRowIconWidth;
import 'package:extron_configurator/cost_estimate_view.dart';

/// ============================================================================
///  THE ROW BUTTONS LINE UP DOWN THE PAGE
/// ============================================================================
///  Every table on the estimate ends in the same cluster of buttons, and they
///  are fixed slots counted from the RIGHT-HAND EDGE: delete, then back-to-
///  catalog-price, then add-to-catalog, then replace. So the trash can on the
///  labor card sits directly under the trash can on the rack-hardware card and
///  under the delete on the equipment card, and somebody who has learned where
///  the delete is on one table has learned it on all of them.
///
///  It was not like this. Each table put its buttons on in whatever order that
///  row happened to need, and one slot was SHARED between two buttons only one
///  kind of row could use — the rack-hardware column ended in "back to the
///  price list" on a placed line and a trash can on a typed one, in the same
///  place. Worse, the cabling table put replace and add-to-catalog in opposite
///  orders on its two kinds of row, one directly above the other. A column of
///  buttons that changes meaning line by line is how somebody deletes a row
///  meaning to reset its price.
/// ============================================================================
void main() {
  AvPort port(String id, String label, PortDirection direction) => AvPort(
    id: id,
    label: label,
    signal: SignalType.hdmi,
    direction: direction,
    side: direction == PortDirection.output ? PortSide.right : PortSide.left,
  );

  /// Every card on the page with something on it, and both KINDS of row on
  /// each card that has two — a device off the diagram and a line typed here,
  /// a placed plate and a loose one, a counted run and a spool.
  AppStateProvider fullEstimate() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(model: 'Display X', price: 1000, ports: []),
      )
      ..upsert(
        const AvDeviceTemplate(
          model: 'Vent plate',
          category: kCategoryRackHardware,
          rackUnits: 1,
          price: 20,
          ports: [],
        ),
      );

    // Two boxes with connectors and a lead between them, so the cabling card
    // has a COUNTED RUN on it as well as the spool below.
    p.addAvNode(
      AvNode(
        id: 'SRC',
        label: 'Room PC',
        model: 'PC',
        pos: Offset.zero,
        ports: [port('o1', 'HDMI OUT', PortDirection.output)],
      ),
    );
    p.addAvNode(
      AvNode(
        id: 'D1',
        label: 'Display',
        model: 'Display X',
        pos: const Offset(400, 0),
        ports: [port('i1', 'HDMI IN', PortDirection.input)],
      ),
    );
    p.addAvCable(
      fromNodeId: 'SRC',
      fromPortId: 'o1',
      toNodeId: 'D1',
      toPortId: 'i1',
      signal: SignalType.hdmi,
    );

    p.addAvCostItem(description: 'Trip charge', qty: 1, unitPrice: 250);
    p.addAvCostFee(name: 'Freight', percent: 5);
    p.setAvCostTax(percent: 8.25, label: 'State tax');
    p.addAvCostLabor();
    p.addAvCostExtraEquipment(description: 'Owner display', qty: 1);
    p.addAvCostExtraHardware(description: 'Spare shelf', qty: 1);
    p.addAvCostExtraCable(description: 'Cat6A spool', qty: 1);
    final rack = p.addAvRack('Rack 1', 12);
    p.addAvRackItem(
      const RackItem(
        id: '',
        catalogModel: 'Vent plate',
        label: 'Vent plate',
        category: kCategoryRackHardware,
        rackUnits: 1,
        price: 20,
      ),
      rackId: rack.id,
      startU: 1,
    );
    return p;
  }

  Future<void> pump(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1900, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Every table row on the page, by its grid key.
  List<ValueKey<String>> rowKeys(WidgetTester tester) => [
    for (final row in tester.widgetList<Row>(find.byType(Row)))
      if (row.key case final ValueKey<String> k)
        if (k.value.startsWith('gridrow_')) k,
  ];

  testWidgets('every table on the page has rows to line up', (tester) async {
    final p = fullEstimate();
    await pump(tester, p);

    final keys = rowKeys(tester).map((k) => k.value).toList();
    // The fixture is only worth anything if it actually produced one of each.
    for (final table in ['eqp_', 'hw_', 'cbl_', 'labor_', 'item_']) {
      expect(
        keys.where((k) => k.startsWith('gridrow_$table')),
        isNotEmpty,
        reason: 'no $table row on the page - the fixture is not exercising it',
      );
    }
    // BOTH KINDS of row on the three cards that have two, which is the whole
    // point of the fixture: the slots only drift apart between a line counted
    // off the drawing and a line somebody typed here.
    expect(
      keys.where((k) => k.startsWith('gridrow_eqp_') && k.contains('model:')),
      isNotEmpty,
      reason: 'no drawn device row',
    );
    expect(
      keys.where((k) => k.startsWith('gridrow_eqp_EQP_')),
      isNotEmpty,
      reason: 'no typed equipment row',
    );
    expect(
      keys.where((k) => k.startsWith('gridrow_hw_rackitem:')),
      isNotEmpty,
      reason: 'no placed rack-hardware row',
    );
    expect(
      keys.where((k) => k.startsWith('gridrow_hw_HW_')),
      isNotEmpty,
      reason: 'no typed rack-hardware row',
    );
    expect(
      keys.where((k) => k.startsWith('gridrow_cbl_') && !k.contains('CBL_')),
      isNotEmpty,
      reason: 'no counted cable run row',
    );
    expect(
      keys.where((k) => k.startsWith('gridrow_cbl_CBL_')),
      isNotEmpty,
      reason: 'no typed cable row',
    );
  });

  testWidgets('every row ends on the same right-hand edge', (tester) async {
    final p = fullEstimate();
    await pump(tester, p);

    final edges = <String, double>{};
    for (final key in rowKeys(tester)) {
      edges[key.value] = tester.getRect(find.byKey(key)).right;
    }
    expect(edges, isNotEmpty);
    final one = edges.values.first;
    for (final entry in edges.entries) {
      expect(
        entry.value,
        closeTo(one, 0.5),
        reason: '${entry.key} stops somewhere else, so nothing on it can be '
            'lined up with anything on another card',
      );
    }
  });

  testWidgets('the trash can is the last slot on every row that has one', (
    tester,
  ) async {
    final p = fullEstimate();
    await pump(tester, p);

    final keys = rowKeys(tester);
    final rowRight = tester.getRect(find.byKey(keys.first)).right;
    // Only the ones inside a TABLE ROW. The fees card carries a trash can of
    // its own and is not a grid row, so it has no slot to be in.
    final deletes = [
      for (final key in keys)
        ...find
            .descendant(
              of: find.byKey(key),
              matching: find.byIcon(Icons.delete_outline),
            )
            .evaluate(),
    ];
    expect(deletes, isNotEmpty);

    for (final element in deletes) {
      final rect = tester.getRect(
        find.byElementPredicate((e) => e == element),
      );
      // The icon is 18 inside a button that lays out at 40 hard against the
      // edge, so its own right edge sits a fixed inset in from the row's.
      expect(
        rowRight - rect.right,
        closeTo(11, 1.5),
        reason: 'a trash can that is not in the last slot is a trash can '
            'sitting under some other table\'s reset button',
      );
    }
  });

  testWidgets('the shared buttons occupy the same slot on every card', (
    tester,
  ) async {
    final p = fullEstimate();
    await pump(tester, p);

    final keys = rowKeys(tester);
    final rowRight = tester.getRect(find.byKey(keys.first)).right;

    /// Which 40-wide slot, counted back from the right edge, [icon] sits in
    /// on each table row that has one. Slot 1 is the rightmost.
    Set<int> slotsOf(IconData icon) {
      final out = <int>{};
      for (final key in keys) {
        final found = find.descendant(
          of: find.byKey(key),
          matching: find.byIcon(icon),
        );
        for (final element in found.evaluate()) {
          final rect = tester.getRect(
            find.byElementPredicate((e) => e == element),
          );
          out.add(((rowRight - rect.center.dx) / kRowIconWidth).ceil());
        }
      }
      return out;
    }

    // One slot each, wherever on the page the button appears.
    expect(slotsOf(Icons.delete_outline), {1}, reason: 'delete');
    expect(slotsOf(Icons.restart_alt), {2}, reason: 'back to catalog price');
    expect(slotsOf(Icons.find_replace), {4}, reason: 'replace');
    // Add-to-catalog draws as a plus on a line that has no entry yet and as a
    // pencil on one that has, so both faces have to land in the same slot.
    expect(
      {...slotsOf(Icons.library_add_outlined), ...slotsOf(Icons.edit_note)},
      {3},
      reason: 'add to / edit in the catalog',
    );
  });
}
