import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart'
    show buildAvFlowModel;
import 'package:extron_configurator/base_costs.dart';
import 'package:extron_configurator/control_prefill.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  QUOTED, BUT IS IT IN THE ROOM?
/// ============================================================================
///  The estimate is where a room gets specified — parts picked with quantities
///  and a total — and the control side is built weeks later out of whatever
///  somebody remembers. A line that never becomes a device block is a box that
///  gets ordered, delivered, racked, and then has nothing to drive it, and the
///  first anybody hears of it is at commissioning.
///
///  So an equipment line the config has never heard of flies an orange flag,
///  and the flag is also the button that fixes it. The one thing that keeps
///  the flag meaningful is being able to say "this one never will be in the
///  config": a SPARE is bought for the shelf on purpose. Without that, half a
///  quote is permanently flagged and the flag becomes wallpaper.
/// ============================================================================
void main() {
  late UiSchema schema;
  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

  AvDeviceLibrary catalog() => AvDeviceLibrary.empty()
    ..upsert(
      const AvDeviceTemplate(
        model: 'PowerLite L630U',
        manufacturer: 'Epson',
        category: 'Projector',
        price: 2200,
        ports: [],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(
        model: 'PowerLite L730U',
        manufacturer: 'Epson',
        category: 'Projector',
        price: 3100,
        ports: [],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(
        model: 'PT-MZ682BU8',
        manufacturer: 'Panasonic',
        category: 'Projector',
        price: 2600,
        ports: [],
      ),
    );

  /// A room with one projector drawn but NOT in the config — the state a room
  /// specified from the estimate is in before anybody builds the control side.
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = catalog();
    p.addAvNode(
      const AvNode(
        id: 'AVNODE_1',
        label: 'Projector',
        model: 'PowerLite L630U',
        pos: Offset.zero,
        ports: [],
      ),
    );
    return p;
  }

  Future<void> pump(WidgetTester tester, AppStateProvider p) async {
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
  }

  Finder flagFor(String lineKey) => find.byKey(ValueKey('cfgflag_$lineKey'));

  /// The icon the flag is currently showing.
  IconData iconOf(WidgetTester tester, Finder f) =>
      tester.widget<Icon>(find.descendant(of: f, matching: find.byType(Icon)))
          .icon!;

  Color? colorOf(WidgetTester tester, Finder f) =>
      tester.widget<Icon>(find.descendant(of: f, matching: find.byType(Icon)))
          .color;

  group('a drawn box the config has never heard of', () {
    testWidgets('flies an orange flag', (tester) async {
      final p = room();
      await pump(tester, p);

      final flag = flagFor('model:powerlite l630u');
      expect(flag, findsOneWidget);
      expect(iconOf(tester, flag), Icons.flag);
      expect(colorOf(tester, flag), Colors.orange.shade700,
          reason: 'a thing to do, not a thing that is broken');
    });

    testWidgets('the flag is the button that fixes it', (tester) async {
      final p = room();
      await pump(tester, p);

      await tester.tap(flagFor('model:powerlite l630u'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to the room config'));
      await tester.pumpAndSettle();

      // A device block of the right family, with the room's own defaults.
      final dev = p.roomConfig['PROJECTORDEVICE_1'];
      expect(dev, isA<Map>());
      expect((dev as Map)['model'], 'PowerLite L630U');
      expect(p.roomConfig['SYSTEM_SETUP']['dev_projectors'], '1');
      // And the drawing is re-keyed onto it, so the two are one device rather
      // than two records of it.
      expect(p.avNodeById('PROJECTORDEVICE_1'), isNotNull);
      expect(p.avNodeById('AVNODE_1'), isNull);
    });

    testWidgets('and then flies no flag at all', (tester) async {
      final p = room();
      await pump(tester, p);
      await tester.tap(flagFor('model:powerlite l630u'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to the room config'));
      await tester.pumpAndSettle();

      final flag = flagFor('model:powerlite l630u');
      expect(iconOf(tester, flag), Icons.check_circle_outline);
    });
  });

  group('a line quoted on this page', () {
    testWidgets('is flagged the same way', (tester) async {
      final p = room();
      final item = p.addAvCostExtraEquipment(
        catalogModel: 'PT-MZ682BU8',
        description: 'Second projector',
        qty: 1,
      );
      await pump(tester, p);

      expect(iconOf(tester, flagFor(item.id)), Icons.flag);
    });

    testWidgets('becomes a drawn device AND a config block', (tester) async {
      final p = room();
      final item = p.addAvCostExtraEquipment(
        catalogModel: 'PT-MZ682BU8',
        description: 'Second projector',
        qty: 1,
      );
      await pump(tester, p);

      await tester.tap(flagFor(item.id));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to the room config'));
      await tester.pumpAndSettle();

      // The quote line has become the thing it was quoting — on the diagram
      // and in the config — and is gone from the "not drawn" list, because
      // leaving both would quote the room twice for one box.
      expect(p.avCost.extraEquipment, isEmpty);
      expect(p.avNodes.where((n) => n.model == 'PT-MZ682BU8'), hasLength(1));
      expect(
        p.roomConfig.keys.where((k) => k.startsWith('PROJECTORDEVICE_')),
        hasLength(1),
      );
    });

    testWidgets('a hand-typed line says why it cannot go in', (tester) async {
      final p = room();
      final item = p.addAvCostExtraEquipment(
        description: 'Owner-furnished display',
        qty: 1,
      );
      await pump(tester, p);

      await tester.tap(flagFor(item.id));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to the room config'));
      await tester.pumpAndSettle();

      // Nothing half-done: there is no part to build a device out of.
      expect(p.avCost.extraEquipment, hasLength(1));
      expect(find.textContaining('no part to build a device from'),
          findsOneWidget);
    });
  });

  group('a spare', () {
    testWidgets('can be marked, and stops being flagged', (tester) async {
      final p = room();
      final item = p.addAvCostExtraEquipment(
        catalogModel: 'PowerLite L630U',
        description: 'Spare projector',
        qty: 1,
      );
      await pump(tester, p);

      await tester.tap(flagFor(item.id));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as a spare'));
      await tester.pumpAndSettle();

      expect(p.avCost.extraEquipment.single.spare, isTrue);
      expect(iconOf(tester, flagFor(item.id)), Icons.inventory_2_outlined);
      expect(colorOf(tester, flagFor(item.id)), isNot(Colors.orange.shade700));
      // Still quoted — a spare is real money.
      expect(find.textContaining('spare'), findsWidgets);
    });

    testWidgets('survives being written out and read back', (tester) async {
      final p = room();
      final item = p.addAvCostExtraEquipment(
        catalogModel: 'PowerLite L630U',
        description: 'Spare projector',
        qty: 1,
      );
      p.updateAvCostExtraEquipment(item.copyWith(spare: true));

      final written = p.avCost.toJson();
      final read = RoomCostSettings()..readJson(written);
      expect(read.extraEquipment.single.spare, isTrue);
    });

    testWidgets('a drawn box cannot be one', (tester) async {
      final p = room();
      await pump(tester, p);

      await tester.tap(flagFor('model:powerlite l630u'));
      await tester.pumpAndSettle();

      // Offered but disabled, with the reason on it: a box on the diagram is
      // in the room.
      final entry = tester.widget<PopupMenuItem<String>>(
        find.ancestor(
          of: find.text('Mark as a spare'),
          matching: find.byType(PopupMenuItem<String>),
        ),
      );
      expect(entry.enabled, isFalse);
    });
  });

  group('a box the control system does not drive', () {
    testWidgets('can be said so, and stops being flagged', (tester) async {
      final p = room();
      await pump(tester, p);

      await tester.tap(flagFor('model:powerlite l630u'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not part of the room config'));
      await tester.pumpAndSettle();

      expect(p.avNodeById('AVNODE_1')!.excludeFromControl, isTrue);
      expect(iconOf(tester, flagFor('model:powerlite l630u')), Icons.link_off);
      expect(colorOf(tester, flagFor('model:powerlite l630u')),
          isNot(Colors.orange.shade700));
    });

    testWidgets('stays on the diagram, selectable and priced', (tester) async {
      final p = room();
      await pump(tester, p);
      await tester.tap(flagFor('model:powerlite l630u'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not part of the room config'));
      await tester.pumpAndSettle();

      // The whole point: it is still a box in the room. Nothing about the
      // drawing, the cabling or the quote changes — only what the config-side
      // lists say about it.
      final node = p.avNodeById('AVNODE_1')!;
      expect(node.model, 'PowerLite L630U');
      expect(node.excludeFromCost, isFalse);
      expect(p.avNodes, hasLength(1));
      expect(find.text(r'$2,200.00'), findsWidgets);
    });

    testWidgets('drops off every "missing from the config" list',
        (tester) async {
      final p = room();
      expect(p.avDevicesWithoutControl, hasLength(1));
      expect(planControlSide(p).creatable, hasLength(1));

      p.updateAvNode(
        p.avNodeById('AVNODE_1')!.copyWith(excludeFromControl: true),
      );

      expect(p.avDevicesWithoutControl, isEmpty,
          reason: 'the app stops asking for a block nobody will fill in');
      expect(planControlSide(p).creatable, isEmpty,
          reason: 'and the prefill stops offering to write one');
    });

    testWidgets('and can be put back', (tester) async {
      final p = room();
      await pump(tester, p);
      await tester.tap(flagFor('model:powerlite l630u'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not part of the room config'));
      await tester.pumpAndSettle();

      await tester.tap(flagFor('model:powerlite l630u'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Driven by this system after all'));
      await tester.pumpAndSettle();

      expect(p.avNodeById('AVNODE_1')!.excludeFromControl, isFalse);
      expect(iconOf(tester, flagFor('model:powerlite l630u')), Icons.flag);
    });

    testWidgets('survives being written out and read back', (tester) async {
      final node = const AvNode(
        id: 'AVNODE_9',
        label: 'House switch',
        model: 'CAT-9300',
        pos: Offset.zero,
        ports: [],
        excludeFromControl: true,
      );
      expect(AvNode.fromJson(node.toJson()).excludeFromControl, isTrue);
    });
  });

  group('searching the catalog by more than one word', () {
    test('a maker and a product line find the products', () {
      // The report: "Epson Powerlite" found nothing, because the query was
      // squashed to one token and no field holds those two next to each other.
      final hits = searchCatalog(catalog().equipment, 'Epson Powerlite');
      expect(
        [for (final t in hits) t.model],
        containsAll(['PowerLite L630U', 'PowerLite L730U']),
      );
      expect(
        [for (final t in hits) t.model],
        isNot(contains('PT-MZ682BU8')),
        reason: 'every word still has to land — this is a filter, not a mood',
      );
    });

    test('one word still works the way it always did', () {
      expect(
        [for (final t in searchCatalog(catalog().equipment, 'l730u')) t.model],
        ['PowerLite L730U'],
      );
    });

    test('punctuation is still forgiven, in every word', () {
      expect(
        [
          for (final t in searchCatalog(catalog().equipment, 'panasonic pt mz682'))
            t.model,
        ],
        ['PT-MZ682BU8'],
      );
    });

    test('the model the words name sorts above one matched by its maker', () {
      // "Epson PowerLite" must not put an Epson document camera first.
      final wider = catalog()
        ..upsert(
          const AvDeviceTemplate(
            model: 'AAA DocCam',
            manufacturer: 'Epson PowerLite family',
            category: 'Camera',
            ports: [],
          ),
        );
      final hits = searchCatalog(wider.equipment, 'Epson PowerLite');
      expect(hits.first.model, startsWith('PowerLite'));
    });
  });

  group('a base cost for a length of cable', () {
    test('is a category on the shared card', () {
      expect(cableBaseCategory('HDMI', 25), 'Cable: HDMI 25ft');
      expect(cableBaseCategory('HDMI', 0), 'Cable: HDMI');
      expect(isCableBaseCategory('Cable: HDMI 25ft'), isTrue);
      expect(isCableBaseCategory('Projector'), isFalse);
    });

    test('the length asked for wins over the type figure', () {
      final book = BaseCostBook(
        costs: [
          const BaseCost(category: 'Cable: HDMI', price: 20),
          const BaseCost(category: 'Cable: HDMI 25ft', price: 45),
        ],
      );
      expect(book.priceForCable('HDMI', 25, PricingTier.msrp).price, 45);
      // A length with no figure of its own falls back to the type's.
      expect(book.priceForCable('HDMI', 50, PricingTier.msrp).price, 20);
      // And a type with neither is still unpriced rather than free.
      expect(book.priceForCable('Dante', 25, PricingTier.msrp).price, 0);
    });

    test('the estimate prices a run off it', () {
      final p = room();
      p.addAvNode(
        const AvNode(
          id: 'AVNODE_2',
          label: 'PC',
          model: '',
          pos: Offset(300, 0),
          ports: [
            AvPort(
              id: 'o1',
              label: 'HDMI OUT',
              signal: SignalType.hdmi,
              direction: PortDirection.output,
              side: PortSide.right,
            ),
          ],
        ),
      );
      p.addAvNode(
        const AvNode(
          id: 'AVNODE_3',
          label: 'Display',
          model: '',
          pos: Offset(600, 0),
          ports: [
            AvPort(
              id: 'i1',
              label: 'HDMI IN',
              signal: SignalType.hdmi,
              direction: PortDirection.input,
              side: PortSide.left,
            ),
          ],
        ),
      );
      p.addAvCable(
        fromNodeId: 'AVNODE_2',
        fromPortId: 'o1',
        toNodeId: 'AVNODE_3',
        toPortId: 'i1',
        signal: SignalType.hdmi,
      );

      CostEstimate priced(BaseCostBook book) => computeRoomCost(
        model: buildAvFlowModel(p),
        library: p.avDeviceLibrary,
        settings: p.avCost,
        rates: p.laborRates,
        baseCosts: book,
        tier: PricingTier.msrp,
      );

      // With nothing on the card the run is counted and unpriced, which is
      // the hole this fills.
      final before = priced(BaseCostBook());
      expect(before.cabling.single.source, PriceSource.none);

      final after = priced(
        BaseCostBook(costs: [const BaseCost(category: 'Cable: HDMI', price: 18)]),
      );
      expect(after.cabling.single.unitPrice, 18);
      expect(after.cabling.single.source, PriceSource.baseCost);
      // A total built on typical figures is a budget, and the page says so.
      expect(after.isBudgetary, isTrue);
    });
  });
}
