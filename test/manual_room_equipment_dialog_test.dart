import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/base_costs.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/manual_room_equipment_dialog.dart';
import 'package:extron_configurator/manual_room_lines.dart';

/// ============================================================================
///  LOOKING IN A ROOM NOBODY HAS DRAWN
/// ============================================================================
///  The plan's line items carry one figure each. A reader asked to put
///  twenty-four thousand in next year's request for AGYM 129 has every right
///  to ask what is in AGYM 129, and the room type on the master sheet ('2
///  Projector') is not an answer about that room.
///
///  What is held here: that the card summarizes the survey on the row itself,
///  that the button is on the rows that HAVE one and absent from the rows that
///  do not, and — the one worth breaking — that the dialog shows the two
///  figures as two figures. The survey priced at today's catalog and the
///  estate's refresh cost are different questions, and a screen that puts them
///  in one column invites somebody to subtract them and call the difference
///  labor.
/// ============================================================================
void main() {
  const surveyed = ManualRoom(
    id: 'manual1',
    name: 'AGYM 129',
    lifeYears: 8,
    replacementCost: 24434.6,
    equipment: [
      ManualRoomItem(model: 'IPCP Pro 350M', category: 'Control processor'),
      ManualRoomItem(
        model: 'Casio XJ-UT310WN',
        category: 'Projector',
        quantity: 2,
      ),
      ManualRoomItem(model: 'Epson DC11'),
    ],
  );

  const bare = ManualRoom(
    id: 'manual2',
    name: 'AGYM 202',
    lifeYears: 8,
    replacementCost: 5462.5,
  );

  AppStateProvider providerWith() {
    final provider = AppStateProvider(autoLoadSettings: false)
      ..baseCosts = BaseCostBook(
        costs: [
          const BaseCost(
            category: 'Projector',
            price: 3000,
            standardModel: 'PT-VMZ62BU8',
          ),
          const BaseCost(category: 'Control processor', price: 1200),
        ],
      )
      ..avDeviceLibrary = AvDeviceLibrary.empty();
    provider.newProject(name: 'Acker Gymnasium refresh', building: 'AGYM');
    return provider;
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: providerWith(),
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the card says what is in the room, rolled up by role', (
    tester,
  ) async {
    await pump(
      tester,
      const ManualRoomLineCard(room: surveyed, currency: r'$'),
    );

    expect(
      find.textContaining('in the room: 2 Projector'),
      findsOneWidget,
      reason: 'what it is mostly made of, first',
    );
  });

  testWidgets('the inventory button is only on rows that have one', (
    tester,
  ) async {
    await pump(
      tester,
      const Column(
        children: [
          ManualRoomLineCard(room: surveyed, currency: r'$'),
          ManualRoomLineCard(room: bare, currency: r'$'),
        ],
      ),
    );

    expect(
      find.byKey(const ValueKey('line_item_equipment_manual1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('line_item_equipment_manual2')),
      findsNothing,
      reason: 'a room nobody looked in would open an empty box to say so',
    );
  });

  testWidgets('the dialog lists the models and both figures', (tester) async {
    await pump(
      tester,
      const ManualRoomLineCard(room: surveyed, currency: r'$'),
    );
    await tester.tap(find.byKey(const ValueKey('line_item_equipment_manual1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('manual_room_equipment_dialog')),
      findsOneWidget,
    );
    expect(find.text('Casio XJ-UT310WN'), findsOneWidget);
    expect(find.text('Epson DC11'), findsOneWidget);

    // Two projectors at the card's 3,000 and the processor at 1,200. The
    // document camera is on the list and out of the total, and the row says
    // which one it is.
    expect(
      find.byKey(const ValueKey('manual_room_equipment_total')),
      findsOneWidget,
    );
    expect(find.text(r'$7,200.00'), findsOneWidget);
    expect(find.textContaining('4 items installed, 1 not priced'), findsOneWidget);
    // The blank option on every role picker says 'not priced' too, so the
    // one that matters is the money cell on the row that has no figure.
    expect(find.text('not priced'), findsWidgets);

    // A card figure marked as one, and the model it was benchmarked on.
    expect(find.textContaining('est.'), findsWidgets);
    expect(find.text('priced as PT-VMZ62BU8'), findsOneWidget);

    // THE OTHER FIGURE, said as its own thing.
    expect(find.text(r'$24,434.60'), findsOneWidget);
    expect(
      find.textContaining('On the plan, to refresh this room'),
      findsOneWidget,
    );
  });

  testWidgets('editing the date does not empty the room', (tester) async {
    // THE FORM EDITS FOUR FIELDS. It must not be the thing that deletes a
    // fifth: correcting a date on a budget screen is not a statement that
    // somebody took the projectors out.
    final provider = providerWith();
    final seeded = provider.addProjectManualRoom(
      name: 'AGYM 129',
      installedOn: DateTime(2015, 7, 1),
      lifeYears: 8,
      replacementCost: 24434.6,
    );
    provider.updateProjectManualRoom(
      seeded.copyWith(equipment: surveyed.equipment),
    );
    final line = provider.project.manualRooms.single;

    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: ManualRoomLineCard(room: line, currency: r'$'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ValueKey('line_item_edit_${line.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('manual_room_cost')),
      '31000',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual_room_ok')));
    await tester.pumpAndSettle();

    final after = provider.project.manualRooms.single;
    expect(after.replacementCost, 31000);
    expect(after.installedCount, 4, reason: 'the survey came through untouched');
  });

  testWidgets('a wrong model can be corrected on the report', (tester) async {
    // The poll files screen controllers as control processors and reports gear
    // that has since been swapped out. Somebody who has stood in the room
    // knows better, and this is where they say so.
    final provider = providerWith();
    final seeded = provider.addProjectManualRoom(
      name: 'AGYM 129',
      replacementCost: 24434.6,
    );
    provider.updateProjectManualRoom(
      seeded.copyWith(equipment: surveyed.equipment),
    );

    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: ManualRoomEquipmentDialog(
              room: provider.project.manualRooms.single,
              currency: r'$',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Nothing to save until something is said.
    final save = find.byKey(const ValueKey('manual_room_equipment_save'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('manual_room_equipment_model_1')),
      'PT-VMZ62BU8',
    );
    await tester.enterText(
      find.byKey(const ValueKey('manual_room_equipment_qty_1')),
      '3',
    );
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    final after = provider.project.manualRooms.single;
    expect(after.equipment[1].model, 'PT-VMZ62BU8');
    expect(after.equipment[1].quantity, 3);
    expect(
      after.equipment.first.model,
      'IPCP Pro 350M',
      reason: 'the rows nobody touched are untouched',
    );
    // A hand correction is a decision, and the log says so.
    expect(
      provider.project.history.any(
        (e) => e.field == 'What is in the room',
      ),
      isTrue,
    );
  });

  testWidgets('closing without saving leaves the plan alone', (tester) async {
    final provider = providerWith();
    final seeded = provider.addProjectManualRoom(name: 'AGYM 129');
    provider.updateProjectManualRoom(
      seeded.copyWith(equipment: surveyed.equipment),
    );

    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: ManualRoomEquipmentDialog(
              room: provider.project.manualRooms.single,
              currency: r'$',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('manual_room_equipment_remove_0')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('manual_room_equipment_close')),
    );
    await tester.pumpAndSettle();

    expect(provider.project.manualRooms.single.equipment, hasLength(3));
  });

  testWidgets('a room nobody has surveyed says so rather than showing nothing', (
    tester,
  ) async {
    await pump(
      tester,
      const ManualRoomEquipmentDialog(room: bare, currency: r'$'),
    );

    expect(
      find.textContaining('Nothing has been surveyed in this room'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('manual_room_equipment_total')),
      findsNothing,
    );
  });
}
