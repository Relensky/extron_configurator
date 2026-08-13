import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cost_estimate_view.dart';

/// The estimate is read on whatever window somebody has open — a laptop, or a
/// big screen with the side panes dragged out — and it is CAPTURED as an image
/// from that same page. So nothing on it may depend on the window being wide:
/// an overflowing card heading is a row of buttons painted past the edge under
/// a yellow-and-black bar, with the last one unclickable, and it is a picture
/// somebody has to apologize for.
///
/// The card headings wrap instead. This is the regression test for that: it
/// builds a fully populated estimate at several widths and fails if any of it
/// overflows, since Flutter reports an overflow as a framework error.
void main() {
  AvNode device(String id, String label, String model) => AvNode(
    id: id,
    label: label,
    model: model,
    pos: Offset.zero,
    ports: const [],
  );

  /// Every card on the page with something on it: equipment (drawn and typed),
  /// rack hardware (placed and loose), cabling, labor, fees, tax and items.
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
    p.addAvNode(device('D1', 'Display', 'Display X'));
    p.addAvNode(device('D2', 'Owner switch', 'CAT-9300'));
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

  // 900 is narrower than any window this is used on; 1400 is the laptop that
  // used to overflow by 127 pixels.
  for (final width in [900.0, 1200.0, 1400.0, 1900.0]) {
    testWidgets('the estimate lays out at ${width.round()} px wide',
        (tester) async {
      tester.view.physicalSize = Size(width, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: fullEstimate(),
          child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Every card, not just the ones above the fold: a heading that overflows
      // is only reported once it has been laid out.
      for (var i = 0; i < 3; i++) {
        await tester.drag(
          find.byType(Scrollable).first,
          const Offset(0, -3000),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('the equipment captions sit over their own columns',
      (tester) async {
    tester.view.physicalSize = const Size(1900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: fullEstimate(),
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();

    // The captions and the cells are laid out from the same gaps and widths,
    // so a column's caption ends where the column does. It did not: the
    // trailing button column was declared 12 pixels narrower than the buttons
    // render, which walked every caption on the row out of place.
    final headerRow = find
        .ancestor(of: find.text('Device'), matching: find.byType(Row))
        .first;
    final extended = find.descendant(
      of: headerRow,
      matching: find.text('Extended'),
    );
    expect(extended, findsOneWidget);
    expect(
      tester.widget<Text>(extended).textAlign,
      TextAlign.right,
      reason: 'the money under it is right-aligned',
    );

    final row = find
        .ancestor(of: find.text('Display'), matching: find.byType(Row))
        .last;
    final money = find.descendant(
      of: row,
      matching: find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').startsWith(r'$'),
      ),
    );
    expect(money, findsWidgets);
    expect(
      (tester.getBottomRight(extended).dx -
              tester.getBottomRight(money.last).dx)
          .abs(),
      lessThan(1),
    );
  });

  testWidgets('the heading buttons are still all there when it wraps',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: fullEstimate(),
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();

    // Wrapped onto a second line rather than pushed off the card — which is
    // the whole difference between this and what it replaced.
    for (final label in const [
      'Labor rates',
      'Base costs',
      'Screenshot',
      'Save AV Setup',
      'Export',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '$label is on the card');
      expect(
        tester.getTopLeft(find.text(label)).dx,
        greaterThanOrEqualTo(0),
        reason: '$label is inside the window',
      );
      expect(
        tester.getBottomRight(find.text(label)).dx,
        lessThanOrEqualTo(1000),
        reason: '$label is inside the window',
      );
    }
  });
}
