import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/live_text_field.dart';

/// Rack hardware on the Cost tab says what to order: maker, model, part.
void main() {
  testWidgets('a hardware row shows its maker, model and part number',
      (tester) async {
    tester.view.physicalSize = const Size(1900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'Fusion Tilt Mount',
        manufacturer: 'Chief',
        partNumber: 'XTM1U',
        category: 'Rack hardware',
        price: 258.71,
        ports: [],
      ));
    p.addAvCostExtraHardware(
      catalogModel: 'Fusion Tilt Mount',
      description: 'Display Mount',
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Display Mount'), findsOneWidget);
    expect(find.text('Chief Fusion Tilt Mount · XTM1U'), findsOneWidget);

    // The caption sits directly over the text it names.
    final textLeft =
        tester.getTopLeft(find.text('Chief Fusion Tilt Mount · XTM1U')).dx;
    final captionLefts = [
      for (final e in find.text('Model').evaluate())
        tester.getTopLeft(find.byWidget(e.widget)).dx,
    ];
    expect(captionLefts, contains(closeTo(textLeft, 0.5)));
  });

  testWidgets('a line typed by hand takes its maker and part number',
      (tester) async {
    tester.view.physicalSize = const Size(1900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = AvDeviceLibrary.empty();
    final line = p.addAvCostExtraEquipment(
      description: 'USB hub',
      unitPrice: 50,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(ValueKey('maker_${line.id}')), 'Anker');
    await tester.enterText(
      find.byKey(ValueKey('partno_${line.id}')),
      'A7518',
    );
    await tester.pump(LiveTextField.lazyPause * 2);

    final saved = p.avCost.extraEquipment.single;
    expect(saved.manufacturer, 'Anker');
    expect(saved.partNumber, 'A7518');
    // Survives the file, and reaches the export.
    expect(CostLineItem.fromJson(saved.toJson()).manufacturer, 'Anker');
    final equipment = costReportSections(p.roomCost)
        .firstWhere((s) => s.title == 'Equipment');
    expect(equipment.header, contains('Manufacturer'));
    expect(equipment.rows.single, containsAll(['Anker', 'A7518']));
  });

  testWidgets('a quoted equipment line can carry spares', (tester) async {
    tester.view.physicalSize = const Size(1900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = AvDeviceLibrary.empty();
    final line = p.addAvCostExtraEquipment(
      description: 'Ceiling mic',
      qty: 5,
      unitPrice: 100,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();

    // The Spares box is there for a line that is not on the diagram.
    final box = find.byWidgetPredicate(
      (w) => w is LiveTextField && w.fieldId == 'eqpspare_${line.id}',
    );
    expect(box, findsOneWidget);
    await tester.enterText(
      find.descendant(of: box, matching: find.byType(TextField)),
      '2',
    );
    await tester.pump(LiveTextField.lazyPause * 2);

    final priced = p.roomCost.equipment.single;
    expect(priced.spareQty, 2);
    expect(priced.qty, 7);
    expect(priced.total, 700);
    // The line's own quantity is untouched.
    expect(p.avCost.extraEquipment.single.qty, 5);
  });

  testWidgets('a drawn line can be given a title of its own', (tester) async {
    tester.view.physicalSize = const Size(1900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = AvDeviceLibrary.empty();
    // Three boxes of one model: listed by all three names until titled.
    for (var i = 1; i <= 3; i++) {
      p.addAvNode(AvNode(
        id: 'PDU$i',
        label: 'PDU $i',
        model: 'SX-DPP-102',
        pos: Offset.zero,
        ports: const [],
      ));
    }
    expect(p.roomCost.equipment.single.description, 'PDU 1, PDU 2, PDU 3');
    final key = p.roomCost.equipment.single.key;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();

    final box = find.descendant(
      of: find.byKey(ValueKey('linename_$key')),
      matching: find.byType(TextField),
    );
    await tester.enterText(box, 'Display surge protectors');
    await tester.pump(LiveTextField.lazyPause * 2);
    final titled = p.roomCost.equipment.single;
    expect(titled.description, 'Display surge protectors');
    expect(titled.defaultName, 'PDU 1, PDU 2, PDU 3');
    // Kept with the room, and in the export.
    expect(
      (RoomCostSettings()..readJson(p.avCost.toJson())).lineNames[key],
      'Display surge protectors',
    );
    expect(
      costReportSections(p.roomCost)
          .firstWhere((s) => s.title == 'Equipment')
          .rows
          .single
          .first,
      'Display surge protectors',
    );

    // Cleared, it goes back to the diagram's names.
    await tester.enterText(box, '');
    await tester.pump(LiveTextField.lazyPause * 2);
    expect(p.roomCost.equipment.single.description, 'PDU 1, PDU 2, PDU 3');
  });

  testWidgets('a name is not committed until the typing pauses', (tester) async {
    tester.view.physicalSize = const Size(1900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = AvDeviceLibrary.empty();
    final line = p.addAvCostExtraEquipment(description: 'Mic');
    var rebuilds = 0;
    p.addListener(() => rebuilds++);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();

    final box = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is LiveTextField && w.fieldId == 'eqpdesc_${line.id}',
      ),
      matching: find.byType(TextField),
    );
    // Three keystrokes in quick succession: nothing is sent yet.
    for (final text in ['C', 'Ce', 'Ceiling mic']) {
      await tester.enterText(box, text);
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(rebuilds, 0);
    expect(p.avCost.extraEquipment.single.description, 'Mic');

    // The pause: one commit, with the whole of what was typed.
    await tester.pump(LiveTextField.lazyPause * 2);
    expect(rebuilds, 1);
    expect(p.avCost.extraEquipment.single.description, 'Ceiling mic');
  });
}
