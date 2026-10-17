import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cost_estimate_view.dart';

/// An Other items line off the catalog shows the catalog's price, and a
/// catalog entry can be saved with no connectors at all.
void main() {
  const mount = AvDeviceTemplate(
    model: 'RPMA-UW Elite Universal Ceiling Mount for Projectors (White)',
    manufacturer: 'Chief',
    partNumber: 'RPMAUW',
    category: kCategoryMisc,
    price: 279.95,
    educationPrice: 245.59,
    powerInput: PowerInput.none,
    custom: true,
    ports: [],
  );

  testWidgets('an Other items line off the catalog shows its price',
      (tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Arts 111'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = AvDeviceLibrary.empty()..upsert(mount);
    // As linking a typed line to a new catalog entry leaves it: no typed
    // price, so the catalog's wins.
    p.addAvCostItem(description: 'Projector mount', catalogModel: mount.model);
    tester.view.physicalSize = const Size(1900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();
    expect(p.roomCost.extras.single.unitPrice, 279.95);
    // In the Other items table: the catalog price behind the unit box, and
    // the extended total. Before, the box was blank and the total $0.00.
    final card = find.ancestor(
      of: find.text('Add other items'),
      matching: find.byType(Card),
    );
    expect(
      find.descendant(of: card, matching: find.text(r'$279.95')),
      findsOneWidget,
    );
    final boxes = tester.widgetList<TextField>(
        find.descendant(of: card, matching: find.byType(TextField)));
    expect(boxes.map((f) => f.decoration?.hintText), contains('279.95'));
  });

  group('All catalog items in an add dialog', () {
    Future<AppStateProvider> open(WidgetTester tester) async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Arts 111'},
        };
      p.loadAvFlowForCurrentConfig();
      p.avDeviceLibrary = AvDeviceLibrary.empty()
        ..upsert(mount)
        ..upsert(const AvDeviceTemplate(
          model: 'RSB 129 Rack Shelf',
          category: 'Shelf',
          rackUnits: 1,
          price: 120,
          powerInput: PowerInput.none,
          ports: [],
        ));
      tester.view.physicalSize = const Size(1900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cost_add_equipment')));
      await tester.pumpAndSettle();
      return p;
    }

    testWidgets('a part off the catalog can go on from our stock, in kind',
        (tester) async {
      final p = await open(tester);
      await tester.enterText(
          find.widgetWithText(TextField, 'Name on the estimate'),
          'Old projector lift');
      await tester.tap(find.byKey(const ValueKey('add_from_stock')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('add_stock_value')), '400');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();
      final line = p.avCost.extraEquipment.single;
      expect(line.description, 'Old projector lift');
      expect(line.unitPrice, 400);
      expect(p.avCost.furnishedLines[line.id], 'stock');
      expect(p.roomCost.equipmentTotal, 0);
      expect(p.roomCost.inKindTotal, 400);
      expect(find.byKey(const ValueKey('cost_in_kind')), findsOneWidget);
    });

    testWidgets('off, a rack shelf is not offered as equipment',
        (tester) async {
      await open(tester);
      expect(find.text('RSB 129 Rack Shelf'), findsNothing);
    });

    testWidgets('on, a picked shelf goes in Rack hardware and a mount in '
        'Other items', (tester) async {
      final p = await open(tester);
      await tester.tap(find.byKey(const ValueKey('add_show_all')));
      await tester.pumpAndSettle();
      expect(find.text('Shelf · Goes in Rack hardware · 1U · \$120.00'),
          findsOneWidget);
      await tester.tap(find.text('RSB 129 Rack Shelf'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();
      expect(p.avCost.extraHardware.single.catalogModel, 'RSB 129 Rack Shelf');
      expect(p.avCost.extraEquipment, isEmpty);
      expect(find.text('RSB 129 Rack Shelf added to Rack hardware.'),
          findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('cost_add_equipment')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add_show_all')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(mount.model));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();
      expect(p.avCost.items.single.catalogModel, mount.model);
    });
  });

  test('deleting the power inlet leaves it off through a save', () {
    final library = AvDeviceLibrary.empty()
      ..upsert(mount.copyWith(
        powerInput: PowerInput.mains,
        ports: withPowerInlet(const [], PowerInput.mains),
      ));
    final saved = library.templateForModel(mount.model)!;
    expect(saved.ports, hasLength(1));
    // What the Device Editor now does when the inlet is deleted.
    library.upsert(saved.copyWith(ports: const [], powerInput: PowerInput.none));
    library.normalizePowerInlets();
    expect(library.templateForModel(mount.model)!.ports, isEmpty);
    // Left on mains, the save would have put it back.
    library.upsert(saved.copyWith(ports: const []));
    library.normalizePowerInlets();
    expect(library.templateForModel(mount.model)!.ports, hasLength(1));
  });
}
