import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/base_costs.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  PRICING A MODEL THE CATALOG KNOWS BUT CANNOT PRICE
/// ============================================================================
///  BSS 237 has a DTP CrossPoint 108 4K IPCP MA 70 in it. The catalog has that
///  exact model, with its part number — and no price, because the part is
///  retired and Extron's list only carries the current variants. The estimate
///  should then fall back to the base card, and for a long time it did not:
///  the card is written in the app's words ('Switcher') and the catalog entry
///  says 'Matrix', so the lookup missed and the line came out at $0 — worse
///  than if the catalog had never heard of the model at all, because an entry
///  with no category would have been priced off its config section.
///
///  Two rungs fix that, and both are checked here: translate the catalog
///  families that mean exactly one thing, and for the rest ask what the device
///  does in the room.
/// ============================================================================
void main() {
  AvNode device(String id, String label, String model) => AvNode(
        id: id,
        label: label,
        model: model,
        pos: Offset.zero,
        ports: const [],
      );

  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  /// One catalog entry, with a category and no price — the retired-part case.
  AvDeviceLibrary catalogWith({
    required String model,
    required String category,
  }) {
    final library = AvDeviceLibrary.empty();
    library.upsert(
      AvDeviceTemplate(model: model, category: category, ports: const []),
    );
    return library;
  }

  BaseCostBook card() => BaseCostBook(costs: [
        const BaseCost(category: 'Switcher', price: 13000, educationPrice: 7052.8),
        const BaseCost(category: 'Screen', price: 2000, educationPrice: 1500),
        const BaseCost(category: 'USB interface', price: 800, educationPrice: 650),
        const BaseCost(category: 'DSP', price: 2500, educationPrice: 1832.8),
      ]);

  CostLine priceOne(
    AvNode node, {
    required AvDeviceLibrary library,
    PricingTier tier = PricingTier.msrp,
  }) {
    final p = room()..addAvNode(node);
    final estimate = computeRoomCost(
      model: buildAvFlowModel(p),
      library: library,
      settings: p.avCost,
      baseCosts: card(),
      tier: tier,
    );
    return estimate.equipment.single;
  }

  group('the base card is asked twice', () {
    test("a catalog family that means one thing is translated", () {
      final line = priceOne(
        device('SWITCHERDEVICE_1', 'Switcher', 'DTP CrossPoint 108 4K IPCP MA 70'),
        library: catalogWith(
          model: 'DTP CrossPoint 108 4K IPCP MA 70',
          category: 'Matrix',
        ),
      );
      expect(line.unitPrice, 13000);
      // Estimated, not quoted: the line says so wherever it is shown.
      expect(line.source, PriceSource.baseCost);
      // The line still reads as the catalog files it — the translation is for
      // the lookup, not for the paperwork.
      expect(line.category, 'Matrix');
    });

    test('the education tier is translated the same way', () {
      final line = priceOne(
        device('SWITCHERDEVICE_1', 'Switcher', 'DTP CrossPoint 108 4K IPCP MA 70'),
        library: catalogWith(
          model: 'DTP CrossPoint 108 4K IPCP MA 70',
          category: 'Matrix',
        ),
        tier: PricingTier.education,
      );
      expect(line.unitPrice, 7052.8);
    });

    test('a family that means several things falls back to the room role', () {
      // 'Architectural' is cable cubbies and AC outlets as well as this screen
      // controller, so it is deliberately NOT on the alias table. The config
      // section is: a SCREENDEVICE is a screen.
      final line = priceOne(
        device('SCREENDEVICE_1', 'Screen 1', 'Controller'),
        library: catalogWith(model: 'Controller', category: 'Architectural'),
      );
      expect(line.unitPrice, 2000);
      expect(line.source, PriceSource.baseCost);
      expect(line.category, 'Architectural');
    });

    test('a device with no room role and no known family stays unpriced', () {
      // Nothing to translate and nothing to ask: an honest hole in the total
      // beats a made-up number. 'Audio' is exactly this case — a DSP, an
      // amplifier and a loudspeaker all live under it.
      final line = priceOne(
        device('EXTRA_1', 'Something', 'Mystery Box'),
        library: catalogWith(model: 'Mystery Box', category: 'Audio'),
      );
      expect(line.unitPrice, 0);
      expect(line.source, PriceSource.none);
    });

    test('a real catalog price still wins over both', () {
      final library = AvDeviceLibrary.empty()
        ..upsert(const AvDeviceTemplate(
          model: 'Priced Matrix',
          category: 'Matrix',
          price: 9000,
          ports: [],
        ));
      final line = priceOne(
        device('SWITCHERDEVICE_1', 'Switcher', 'Priced Matrix'),
        library: library,
      );
      expect(line.unitPrice, 9000);
      expect(line.source, PriceSource.catalog);
    });
  });

  group('the alias table', () {
    test('translates only onto categories the card actually has', () {
      for (final target in kCategoryAliases.values) {
        expect(
          BaseCostBook.defaults.any((c) => c.category == target),
          isTrue,
          reason: '$target is aliased to but is not a base cost category',
        );
      }
    });

    test('a card category is never re-pointed by an alias', () {
      // 'Display' is both a catalog category and one of ours. Translating it
      // would be a bug that only showed up on a card where the two differ.
      final book = BaseCostBook(costs: [
        const BaseCost(category: 'Display', price: 2000),
      ])
        ..aliases['display'] = 'Screen';
      expect(book.resolveCategory('Display'), 'Display');
      expect(book.priceFor('Display', PricingTier.msrp).price, 2000);
    });

    test('the file can teach the card a family the app does not know', () async {
      final dir = await Directory.systemTemp.createTemp('base_costs_alias');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/base_costs.json';
      await File(path).writeAsString(jsonEncode({
        'costs': [
          {'category': 'Switcher', 'price': 13000.0, 'educationPrice': 7052.8},
        ],
        'aliases': {'Fox Systems': 'Switcher'},
      }));

      final book = await BaseCostBook.load(path);
      expect(book.priceFor('Fox Systems', PricingTier.msrp).price, 13000);
      // And it survives a save, or the next write would quietly drop it.
      await book.save();
      final reread = await BaseCostBook.load(path);
      expect(reread.priceFor('Fox Systems', PricingTier.msrp).price, 13000);
    });
  });

  // ---------------------------------------------------------------------------
  //  THE ROOM THIS CAME FROM
  // ---------------------------------------------------------------------------
  test('BSS 237 prices every line', () async {
    const path = 'C:/GitHub/ControlScript-Template/rooms/BSS237/code/'
        'upload_to_root/config.json';
    final file = File(path);
    if (!file.existsSync()) return; // the template repo is not beside this one

    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = await UiSchema.load(explicitPath: 'ui_schema.json')
      ..avDeviceLibrary =
          await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
    p.roomConfig
      ..clear()
      ..addAll(Map<String, dynamic>.from(
          jsonDecode(file.readAsStringSync()) as Map));
    for (final key
        in activeDeviceKeysIn(p.roomConfig, p.uiSchema.deviceCountMap)) {
      final dev = p.roomConfig[key];
      if (dev is! Map) continue;
      final model = dev['model']?.toString() ?? '';
      p.addAvNode(device(key, dev['name']?.toString() ?? key, model));
    }

    final estimate = computeRoomCost(
      model: buildAvFlowModel(p),
      library: p.avDeviceLibrary,
      settings: p.avCost,
      baseCosts: await BaseCostBook.load('base_costs.json'),
    );

    final switcher = estimate.equipment
        .firstWhere((l) => l.model == 'DTP CrossPoint 108 4K IPCP MA 70');
    // The right entry — the part number proves the lookup hit the exact model
    // and not one of the eight other CrossPoint 108s — at the switcher base
    // cost, because that entry carries no price of its own.
    expect(switcher.partNumber, '60-1381-23');
    expect(switcher.unitPrice, greaterThan(0));
    expect(switcher.source, PriceSource.baseCost);

    expect(
      estimate.unpricedLines,
      0,
      reason: estimate.equipment
          .where((l) => l.source == PriceSource.none)
          .map((l) => '${l.model} (${l.category})')
          .join(', '),
    );
  });
}
