import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_view.dart';

/// The Deliveries pane, driven the way somebody uses it.
///
/// The model tests next door prove the record is right; what these guard is
/// the wiring — a PO entered that the job does not keep, a delivery logged
/// against nothing, a state button that moves the chip without moving the
/// record, and a note that appears on screen without the name and the time
/// that are the only reason it is worth writing down.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('deliveries_ui_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppStateProvider withProject() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    for (final stem in ['bss101', 'bss103']) {
      final file = '${dir.path}/${stem}_config.json';
      File(file).writeAsStringSync('{"SYSTEM_SETUP":{}}');
      p.addRoomToProject(file);
    }
    return p;
  }

  Future<void> pumpPane(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1400, 1200);
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

  testWidgets('a PO typed at the top is a PO the job keeps', (tester) async {
    final p = withProject();
    await pumpPane(tester, p);

    await tester.enterText(
      find.byKey(const ValueKey('po_new_number')),
      'PO-1188',
    );
    await tester.tap(find.byKey(const ValueKey('po_new_add')));
    await tester.pumpAndSettle();

    expect(p.project.purchaseOrders.single.number, 'PO-1188');
    expect(
      find.byKey(ValueKey('po_card_${p.project.purchaseOrders.single.id}')),
      findsOneWidget,
      reason: 'the PO is on the pane, not just in the model',
    );
    expect(p.projectDirty, isTrue, reason: 'an entered PO is unsaved work');

    // The same number again is the same paperwork, not a second row.
    await tester.enterText(
      find.byKey(const ValueKey('po_new_number')),
      'po-1188',
    );
    await tester.tap(find.byKey(const ValueKey('po_new_add')));
    await tester.pumpAndSettle();
    expect(p.project.purchaseOrders, hasLength(1));
  });

  testWidgets('a delivery is logged, and says where it is', (tester) async {
    final p = withProject();
    p.addProjectPo(number: 'PO-1188');
    await pumpPane(tester, p);

    await tester.tap(find.byKey(const ValueKey('delivery_log_new')));
    await tester.pumpAndSettle();

    // Nothing is on the equipment list on a job whose rooms are stubs, so the
    // dialog opens on the off-list entry and takes a typed name.
    await tester.enterText(
      find.byKey(const ValueKey('delivery_name')),
      'Wall plate',
    );
    await tester.enterText(find.byKey(const ValueKey('delivery_qty')), '18');
    await tester.enterText(
      find.byKey(const ValueKey('delivery_po')),
      'PO-1188',
    );
    await tester.enterText(
      find.byKey(const ValueKey('delivery_note')),
      '2 arrived damaged, Extron collecting',
    );
    await tester.tap(find.byKey(const ValueKey('delivery_save')));
    await tester.pumpAndSettle();

    final row = p.project.deliveries.single;
    expect(row.itemName, 'Wall plate');
    expect(row.qty, 18);
    expect(row.poNumber, 'PO-1188');
    expect(row.deliveredOn, isNotNull, reason: 'an arrival happened on a day');
    expect(row.state, DeliveryState.delivered);

    // The note carries the name and the moment, taken rather than typed.
    expect(row.notes.single.text, '2 arrived damaged, Extron collecting');
    expect(
      row.notes.single.at.difference(DateTime.now()).abs().inMinutes,
      lessThan(5),
    );

    expect(find.text('18 x Wall plate'), findsOneWidget);
  });

  testWidgets('a delivery with no PO warns, and is logged anyway', (
    tester,
  ) async {
    final p = withProject();
    await pumpPane(tester, p);

    await tester.tap(find.byKey(const ValueKey('delivery_log_new')));
    await tester.pumpAndSettle();

    // Nothing said about what it is or what bought it: the box says so before
    // it is saved rather than leaving it to be discovered in June.
    expect(
      find.byKey(const ValueKey('delivery_no_po_warning')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('delivery_name')),
      'Two boxes, no paperwork',
    );
    await tester.pumpAndSettle();
    // Named, still on nothing - the warning stays, and still does not block.
    expect(
      find.byKey(const ValueKey('delivery_no_po_warning')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('delivery_save')));
    await tester.pumpAndSettle();

    // A pallet that turned up is a fact whether or not the paperwork has
    // caught up: the row is kept, and carries the question with it.
    final row = p.project.deliveries.single;
    expect(row.itemName, 'Two boxes, no paperwork');
    expect(row.needsPaperwork, isTrue);
    expect(find.byKey(ValueKey('delivery_no_po_${row.id}')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('delivery_paperwork_line')),
      findsOneWidget,
    );
  });

  testWidgets('a P-Card purchase is tagged, and stops being a question', (
    tester,
  ) async {
    final p = withProject();
    p.addProjectPo(number: 'PO-1188');
    await pumpPane(tester, p);

    await tester.tap(find.byKey(const ValueKey('delivery_log_new')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('delivery_name')),
      'HDMI adapters',
    );
    await tester.enterText(find.byKey(const ValueKey('delivery_qty')), '4');
    await tester.tap(find.byKey(const ValueKey('delivery_one_off')));
    await tester.pumpAndSettle();

    // Ticked, the warning goes: this row is COMPLETE, with no PO to find.
    expect(find.byKey(const ValueKey('delivery_no_po_warning')), findsNothing);
    // And the PO box is shut, because a one-off has no number to put in it.
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('delivery_po'))).enabled,
      isFalse,
    );

    await tester.tap(find.byKey(const ValueKey('delivery_save')));
    await tester.pumpAndSettle();

    final row = p.project.deliveries.single;
    expect(row.oneOff, isTrue);
    expect(row.poNumber, '');
    expect(row.needsPaperwork, isFalse);
    expect(p.project.oneOffDeliveries, hasLength(1));

    // Said on the card, and counted at the top of the log - this is spend on
    // no estimate, in no vendor package and on no purchase order.
    expect(find.byKey(ValueKey('delivery_no_po_${row.id}')), findsNothing);
    expect(
      find.textContaining('bought as a one-off', findRichText: true),
      findsOneWidget,
    );

    // AND IT IS IN THE HISTORY, saying what it was.
    expect(
      p.project.history.where(
        (h) => h.summary.contains('as a one-off purchase'),
      ),
      isNotEmpty,
    );
  });

  testWidgets('the state buttons move the record, not just the chip', (
    tester,
  ) async {
    final p = withProject();
    final row = p.addProjectDelivery(itemName: 'Wall plate', qty: 6);
    await pumpPane(tester, p);

    // Into storage: the pane asks where, because "in storage" that cannot say
    // where is not an answer anybody can act on.
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('delivery_state_${row.id}')),
        matching: find.text('In storage'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('delivery_where_text')),
      'Bessey basement, rack 3',
    );
    await tester.tap(find.byKey(const ValueKey('delivery_where_save')));
    await tester.pumpAndSettle();

    var saved = p.project.deliveryById(row.id)!;
    expect(saved.state, DeliveryState.stored);
    expect(saved.location, 'Bessey basement, rack 3');

    // Into a room: dated for you, so the row can answer "when did it go in".
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('delivery_state_${row.id}')),
        matching: find.text('Installed'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delivery_install_save')));
    await tester.pumpAndSettle();

    saved = p.project.deliveryById(row.id)!;
    expect(saved.state, DeliveryState.installed);
    expect(saved.installedOn, isNotNull);
    // And it still says where it had been held.
    expect(saved.location, 'Bessey basement, rack 3');
    expect(p.project.installedQty(''), 6);
  });

  testWidgets('a note added on the card is signed and shown', (tester) async {
    final p = withProject();
    final row = p.addProjectDelivery(itemName: 'Wall plate', qty: 6);
    await pumpPane(tester, p);

    await tester.enterText(
      find.byKey(ValueKey('delivery_note_${row.id}')),
      'replacements promised for the 28th',
    );
    await tester.tap(find.byKey(ValueKey('delivery_note_${row.id}_add')));
    await tester.pumpAndSettle();

    final note = p.project.deliveryById(row.id)!.notes.single;
    expect(note.text, 'replacements promised for the 28th');
    // The note and its signature are one run of spans, so the finder has to
    // be told to look inside rich text.
    expect(
      find.textContaining(
        'replacements promised for the 28th',
        findRichText: true,
      ),
      findsOneWidget,
    );

    // AND IT IS IN THE JOB'S HISTORY, under its own kind rather than filed on
    // whichever part happened to be first on the PO.
    expect(
      p.project.history.where((h) => h.itemKind == 'delivery'),
      isNotEmpty,
    );
  });
}
