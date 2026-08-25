import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/device_editor_view.dart';

/// TWO WAYS TO READ A LIST AND ONE WAY TO CHANGE A NUMBER.
///
/// An order is placed one vendor at a time, so both the quote and the catalog
/// can be put in maker order; and the commonest edit an estimate gets — "make
/// that two" — is a button on the row rather than a box to select and retype.
void main() {
  AvNode device(String id, String label, String model) => AvNode(
    id: id,
    label: label,
    model: model,
    pos: Offset.zero,
    ports: const [],
  );

  /// Three makers, deliberately NOT in maker order by name: sorted by
  /// description alone the list reads Amp, Display, Switcher, which is the
  /// order the maker sort has to break.
  AvDeviceLibrary catalog() => AvDeviceLibrary.empty()
    ..upsert(
      const AvDeviceTemplate(
        model: 'Display X',
        manufacturer: 'Sony',
        price: 1000,
        ports: [],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(
        model: 'Switcher Y',
        manufacturer: 'Extron',
        price: 2500,
        ports: [],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(model: 'Amp Z', price: 400, ports: []),
    );

  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = catalog();
    p.addAvNode(device('D1', 'Display', 'Display X'));
    p.addAvNode(device('S1', 'Switcher', 'Switcher Y'));
    p.addAvNode(device('A1', 'Amp', 'Amp Z'));
    return p;
  }

  CostEstimate priced(AppStateProvider p) => computeRoomCost(
    model: buildAvFlowModel(p),
    library: p.avDeviceLibrary,
    settings: p.avCost,
  );

  group('sorting the quote by manufacturer', () {
    test('reorders the equipment and leaves the unattributed line last', () {
      final p = room();
      expect(
        priced(p).equipment.map((l) => l.description),
        ['Amp', 'Display', 'Switcher'],
        reason: 'the standard order is by device name',
      );

      p.setAvCostEquipmentSort(CostEquipmentSort.manufacturer);
      expect(
        priced(p).equipment.map((l) => l.description),
        // Extron, then Sony, then the amp nobody has said who makes: an empty
        // maker sorts above every letter, and this is the check that it does
        // not open the quote.
        ['Switcher', 'Display', 'Amp'],
      );
    });

    test('the maker rides on the line, off the catalog entry', () {
      final p = room();
      final switcher = priced(
        p,
      ).equipment.firstWhere((l) => l.model == 'Switcher Y');
      expect(switcher.manufacturer, 'Extron');
    });

    test('it is a fact about the quote, so it is saved with it', () {
      final settings = RoomCostSettings()
        ..equipmentSort = CostEquipmentSort.manufacturer;
      expect(settings.isEmpty, isFalse, reason: 'this alone is worth saving');

      final back = RoomCostSettings()..readJson(settings.toJson());
      expect(back.equipmentSort, CostEquipmentSort.manufacturer);

      // A file written before any of this, or hand-edited into nonsense,
      // reads as the order the estimate has always had.
      final old = RoomCostSettings()..readJson({'equipmentSort': 'by vibes'});
      expect(old.equipmentSort, CostEquipmentSort.standard);
    });

    testWidgets('the picker sets it and the table says whose line is whose', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final p = room();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sort: Device name'), findsOneWidget);
      await tester.tap(find.text('Sort: Device name'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manufacturer').last);
      await tester.pumpAndSettle();

      expect(p.avCost.equipmentSort, CostEquipmentSort.manufacturer);
      expect(tester.takeException(), isNull);
      // The Model column names the product and never its maker, so a table
      // silently grouped by vendor would look like one in no order at all.
      // Twice each: once as the heading over that vendor's block, once in the
      // key that decodes the shade its rows are washed in.
      expect(find.text('Extron'), findsNWidgets(2));
      expect(find.text('Sony'), findsNWidgets(2));
      expect(
        find.text('No manufacturer on the catalog entry'),
        findsOneWidget,
      );
    });
  });

  group('nudging a quantity', () {
    testWidgets('+ buys one more of a drawn line and − takes it back', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final p = room();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
        ),
      );
      await tester.pumpAndSettle();

      final key = priced(p).equipment
          .firstWhere((l) => l.model == 'Display X')
          .key;
      final plus = find.byTooltip('One more Display');
      final minus = find.byTooltip('One fewer Display');
      expect(plus, findsOneWidget);
      // Nothing to take away yet: the drawing owns the count, and the row
      // cannot buy minus one.
      // By its tooltip rather than by finding it: an IconButton wraps ITSELF
      // round the tooltip, so the tooltip is not something to search under.
      IconButton buttonLabelled(String tooltip) => tester
          .widgetList<IconButton>(find.byType(IconButton))
          .firstWhere((b) => b.tooltip == tooltip);
      expect(buttonLabelled('One fewer Display').onPressed, isNull);

      await tester.tap(plus);
      await tester.pumpAndSettle();
      expect(p.avEquipmentSpares(key), 1);
      expect(
        priced(p).equipment.firstWhere((l) => l.key == key).qty,
        2,
        reason: 'the drawn one plus the spare',
      );
      // The box beside the buttons is the same number, or the row disagrees
      // with its own total.
      expect(
        find.descendant(of: find.byType(TextField), matching: find.text('1')),
        findsWidgets,
      );

      await tester.tap(minus);
      await tester.pumpAndSettle();
      expect(p.avEquipmentSpares(key), 0);
      expect(priced(p).equipment.firstWhere((l) => l.key == key).qty, 1);
    });

    testWidgets('a typed line nudges its own quantity', (tester) async {
      tester.view.physicalSize = const Size(1800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final p = room();
      p.addAvCostExtraEquipment(description: 'Owner display', qty: 1);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('One more Owner display'));
      await tester.pumpAndSettle();
      expect(p.avCost.extraEquipment.single.qty, 2);

      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byTooltip('One fewer Owner display'));
        await tester.pumpAndSettle();
      }
      expect(p.avCost.extraEquipment.single.qty, 0);
      expect(
        tester
            .widgetList<IconButton>(find.byType(IconButton))
            .firstWhere((b) => b.tooltip == 'One fewer Owner display')
            .onPressed,
        isNull,
        reason: 'a quote cannot buy minus one of anything',
      );
    });
  });

  group('sorting the catalog', () {
    testWidgets('by manufacturer, even with something in the search box', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final p = AppStateProvider(autoLoadSettings: false)
        ..avDeviceLibrary = catalog();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: DeviceEditorView())),
        ),
      );
      await tester.pumpAndSettle();

      List<String> listedModels() => tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((t) => ((t.title as Text).data) ?? '')
          .toList();

      // The list's own order is already maker-first, so the sort has to be
      // asked for against something else to be worth checking: price, high to
      // low, is a different order from every other one here.
      await tester.tap(find.byKey(const ValueKey('catalog_sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Price, high to low').last);
      await tester.pumpAndSettle();
      expect(listedModels(), ['Switcher Y', 'Display X', 'Amp Z']);

      await tester.tap(find.byKey(const ValueKey('catalog_sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manufacturer').last);
      await tester.pumpAndSettle();
      // Extron, Sony, then the entry with no maker on it.
      expect(listedModels(), ['Switcher Y', 'Display X', 'Amp Z']);

      await tester.tap(find.byKey(const ValueKey('catalog_sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Model').last);
      await tester.pumpAndSettle();
      expect(listedModels(), ['Amp Z', 'Display X', 'Switcher Y']);

      // AND IT OUTRANKS RELEVANCE. "y" is in the Switcher's model and only in
      // the Display's maker, so best-match puts the Switcher first; the sort
      // was chosen with the search box in use, and it still decides.
      await tester.enterText(find.byType(TextField).first, 'y');
      await tester.pumpAndSettle();
      expect(listedModels(), ['Display X', 'Switcher Y']);
      expect(tester.takeException(), isNull);
    });
  });
}
