import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_deliveries_view.dart';
import 'package:extron_configurator/project_estimate.dart';

/// Logging what turned up, with the paperwork already known.
///
/// Two things the delivery log gets wrong if nobody guards them: a PO typed
/// again off the same job that already knows it - which is how a delivery ends
/// up filed against the wrong order - and a truckload logged one line at a
/// time, which is how the first two lines get logged and the other seven stay
/// in somebody's head.
void main() {
  MasterPartLine part(String description, {double qty = 2}) => MasterPartLine(
    key: masterPartKey(kind: 'equipment', description: description),
    kind: MasterPartKind.equipment,
    description: description,
    model: '',
    partNumber: '',
    manufacturer: '',
    category: '',
    qty: qty,
    total: 100,
    unitPrice: 50,
    maxUnitPrice: 50,
    qtyByRoom: const {},
    rfq: null,
    vendor: null,
    tagSource: RfqTagSource.none,
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

  /// A job with three parts on it: two bought on PO-1188, one bought on
  /// nothing anybody has recorded.
  ({AppStateProvider provider, ProjectEstimate estimate}) job() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    final master = [
      part('Projection screen'),
      part('Ceiling mount'),
      part('HDMI adapter'),
    ];
    p.setProjectPartsOnPo(
      'PO-1188',
      onIt: [master[0].key, master[1].key],
      partNames: {for (final m in master) m.key: m.description},
    );
    return (provider: p, estimate: estimateOf(p.project, master));
  }

  const noRooms = <({String id, String name})>[];

  Future<void> open(
    WidgetTester tester,
    AppStateProvider provider,
    ProjectEstimate estimate, {
    bool several = false,
  }) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              key: const ValueKey('open_it'),
              onPressed: () => several
                  ? showBulkDeliveryDialog(
                      context,
                      provider: provider,
                      estimate: estimate,
                      rooms: noRooms,
                    )
                  : showDeliveryDialog(
                      context,
                      provider: provider,
                      estimate: estimate,
                      rooms: noRooms,
                    ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open_it')));
    await tester.pumpAndSettle();
  }

  /// showTimedSnackBar arms a timer a little past the bar's own duration, and
  /// the tree cannot be torn down with it still pending.
  Future<void> letTheSnackBarGo(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  }

  String poBox(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const ValueKey('delivery_po')))
      .controller!
      .text;

  Future<void> pickPart(WidgetTester tester, String description) async {
    await tester.tap(find.byKey(const ValueKey('delivery_part')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(description).last);
    await tester.pumpAndSettle();
  }

  testWidgets('picking a part brings the PO that bought it', (tester) async {
    final j = job();
    await open(tester, j.provider, j.estimate);

    expect(poBox(tester), '', reason: 'nothing picked yet, nothing to fill in');

    await pickPart(tester, 'Projection screen');
    expect(poBox(tester), 'PO-1188');
    // And it says where the number came from, because a box that fills itself
    // silently is one people distrust and retype.
    expect(find.byKey(const ValueKey('delivery_po_auto')), findsOneWidget);
    // Which also settles the warning: this row can be reconciled.
    expect(find.byKey(const ValueKey('delivery_no_po_warning')), findsNothing);

    // A part the job has no order record for takes the guess back off rather
    // than leaving the last part's number sitting on this one.
    await pickPart(tester, 'HDMI adapter');
    expect(poBox(tester), '');
    expect(find.byKey(const ValueKey('delivery_po_auto')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('delivery_save')));
    await tester.pumpAndSettle();
    expect(j.provider.project.deliveries.single.poNumber, '');
  });

  testWidgets('a number typed off the packing slip outranks the order', (
    tester,
  ) async {
    final j = job();
    await open(tester, j.provider, j.estimate);

    await tester.enterText(
      find.byKey(const ValueKey('delivery_po')),
      'PO-1204',
    );
    await tester.pumpAndSettle();
    // The slip says 1204. Picking the part does not quietly overwrite it with
    // what the job assumed.
    await pickPart(tester, 'Projection screen');
    expect(poBox(tester), 'PO-1204');
    expect(find.byKey(const ValueKey('delivery_po_auto')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('delivery_save')));
    await tester.pumpAndSettle();
    expect(j.provider.project.deliveries.single.poNumber, 'PO-1204');
  });

  testWidgets('a one-off has no PO, and gets it back when unticked', (
    tester,
  ) async {
    final j = job();
    await open(tester, j.provider, j.estimate);
    await pickPart(tester, 'Ceiling mount');
    expect(poBox(tester), 'PO-1188');

    await tester.tap(find.byKey(const ValueKey('delivery_one_off')));
    await tester.pumpAndSettle();
    expect(poBox(tester), '', reason: 'a card purchase has no order to name');

    await tester.tap(find.byKey(const ValueKey('delivery_one_off')));
    await tester.pumpAndSettle();
    expect(poBox(tester), 'PO-1188');
  });

  testWidgets('a truckload is logged once, to one place on one day', (
    tester,
  ) async {
    final j = job();
    final master = j.estimate.master;
    await open(tester, j.provider, j.estimate, several: true);

    // Nothing ticked is nothing to log.
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('bulk_delivery_save')),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(
      find.byKey(ValueKey('bulk_delivery_pick_${master[0].key}')),
    );
    await tester.tap(
      find.byKey(ValueKey('bulk_delivery_pick_${master[2].key}')),
    );
    await tester.pumpAndSettle();

    // One of the two is on no purchase order, and the box above is the one
    // gesture that fixes it.
    expect(
      find.byKey(const ValueKey('bulk_delivery_no_po_warning')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('delivery_po')),
      'PO-1204',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('bulk_delivery_no_po_warning')),
      findsNothing,
    );

    // Said ONCE, for both rows.
    await tester.enterText(
      find.byKey(const ValueKey('delivery_location')),
      'MLIB loading dock',
    );
    await tester.enterText(
      find.byKey(const ValueKey('bulk_delivery_note')),
      'all on one pallet',
    );
    // The quantity opens on what is still outstanding.
    expect(
      tester
          .widget<TextField>(
            find.byKey(ValueKey('bulk_delivery_qty_${master[0].key}')),
          )
          .controller!
          .text,
      '2',
    );
    await tester.enterText(
      find.byKey(ValueKey('bulk_delivery_qty_${master[2].key}')),
      '5',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('bulk_delivery_save')));
    await tester.pumpAndSettle();
    await letTheSnackBarGo(tester);

    final rows = j.provider.project.deliveries;
    expect(rows, hasLength(2));
    // Each row keeps the PO that actually bought it; the box above only
    // covered the row the job could not answer for.
    final screen = rows.firstWhere((d) => d.partKey == master[0].key);
    final adapter = rows.firstWhere((d) => d.partKey == master[2].key);
    expect(screen.poNumber, 'PO-1188');
    expect(adapter.poNumber, 'PO-1204');
    expect(screen.qty, 2);
    expect(adapter.qty, 5);
    for (final row in rows) {
      expect(row.location, 'MLIB loading dock');
      expect(row.deliveredOn, today());
      expect(row.state, DeliveryState.delivered);
      expect(row.itemName, isNotEmpty);
      expect(row.needsPaperwork, isFalse);
      expect(row.notes.single.text, 'all on one pallet');
    }

    // And both numbers joined the job's PO list, the same as one typed on a
    // single delivery.
    expect(
      j.provider.project.poNumbersInUse,
      containsAll(<String>['PO-1188', 'PO-1204']),
    );
  });

  testWidgets('several can go straight into a room, dated once', (
    tester,
  ) async {
    final j = job();
    final master = j.estimate.master;
    await open(tester, j.provider, j.estimate, several: true);

    await tester.tap(
      find.byKey(ValueKey('bulk_delivery_pick_${master[0].key}')),
    );
    await tester.tap(
      find.byKey(ValueKey('bulk_delivery_pick_${master[1].key}')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('bulk_delivery_state')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Installed').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('bulk_delivery_save')));
    await tester.pumpAndSettle();
    await letTheSnackBarGo(tester);

    final rows = j.provider.project.deliveries;
    expect(rows, hasLength(2));
    for (final row in rows) {
      expect(row.state, DeliveryState.installed);
      // An install with no date cannot answer "when did that go in", so the
      // arrival date stands in rather than leaving it blank.
      expect(row.installedOn, today());
    }
  });

  testWidgets('the search box narrows what can be ticked', (tester) async {
    final j = job();
    final master = j.estimate.master;
    await open(tester, j.provider, j.estimate, several: true);

    await tester.enterText(
      find.byKey(const ValueKey('bulk_delivery_search')),
      'adapter',
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(ValueKey('bulk_delivery_pick_${master[2].key}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('bulk_delivery_pick_${master[0].key}')),
      findsNothing,
    );
  });
}
