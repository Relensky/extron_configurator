import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/cost_estimate.dart';

/// Two catalog additions that a quote depends on:
///
///   * the URL a price and a heat figure were read off, so next year somebody
///     can check whether they still hold;
///   * AV/Misc entries — a licence, a mount, a trip charge — which are money
///     on a job without being a box on a diagram, and which the estimate's
///     "Other items" prices off the catalog rather than from whatever was
///     typed the day the line was added.
void main() {
  group('catalog URL', () {
    test('survives a round trip, and an entry without one stays clean', () {
      const entry = AvDeviceTemplate(
        model: 'DTP2 R 211',
        url: 'https://www.extron.com/product/dtp2r211',
        ports: [],
      );
      final back = AvDeviceTemplate.fromJson(entry.toJson());
      expect(back.url, 'https://www.extron.com/product/dtp2r211');

      // Absent rather than an empty string: the catalog is read by people and
      // by diffs, and a thousand `"url": ""` lines are noise.
      const bare = AvDeviceTemplate(model: 'Nothing', ports: []);
      expect(bare.toJson().containsKey('url'), isFalse);
      expect(AvDeviceTemplate.fromJson(bare.toJson()).url, '');
    });

    test('reads `link` as an alias, the way a hand-written entry spells it',
        () {
      final t = AvDeviceTemplate.fromJson({
        'model': 'Hand typed',
        'link': 'https://example.com/thing',
        'ports': const [],
      });
      expect(t.url, 'https://example.com/thing');
    });
  });

  group('AV/Misc cost items', () {
    test('are their own slice of the catalog, apart from the equipment', () {
      final library = AvDeviceLibrary.empty();
      library.upsert(
        const AvDeviceTemplate(
          model: 'Display mount',
          category: kCategoryMisc,
          price: 240,
          powerInput: PowerInput.none,
          ports: [],
        ),
      );
      library.upsert(
        const AvDeviceTemplate(model: 'Switcher Y', price: 2500, ports: []),
      );

      expect(library.miscItems.map((t) => t.model), ['Display mount']);
      expect(library.miscItems.single.isMiscItem, isTrue);
      // It is not a box, so it must not turn up where boxes are chosen.
      expect(library.cables, isEmpty);
      expect(library.rackHardware, isEmpty);
    });

    test('a retired item drops out of the list but keeps resolving', () {
      final library = AvDeviceLibrary.empty();
      library.upsert(
        const AvDeviceTemplate(
          model: 'Old licence',
          category: kCategoryMisc,
          price: 100,
          retired: true,
          ports: [],
        ),
      );
      expect(library.miscItems, isEmpty);
      expect(library.templateForModel('Old licence')?.price, 100);
    });
  });

  group('Other items price off the catalog', () {
    AppStateProvider room() {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      p.loadAvFlowForCurrentConfig();
      return p;
    }

    AvDeviceLibrary catalog() {
      final library = AvDeviceLibrary.empty();
      library.upsert(
        const AvDeviceTemplate(
          model: 'Display mount',
          category: kCategoryMisc,
          price: 240,
          educationPrice: 150,
          powerInput: PowerInput.none,
          ports: [],
        ),
      );
      return library;
    }

    test('a line picked off the catalog follows the catalog, not the typed '
        'price', () {
      final p = room();
      p.addAvCostItem(
        catalogModel: 'Display mount',
        description: 'Display mount',
        qty: 3,
      );

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );

      final line = estimate.extras.single;
      expect(line.unitPrice, 240);
      expect(line.qty, 3);
      expect(line.total, 720);
      expect(line.source, PriceSource.catalog);
    });

    test('the education tier reaches these lines too', () {
      final p = room();
      p.addAvCostItem(catalogModel: 'Display mount', description: 'Mount');

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
        tier: PricingTier.education,
      );
      expect(estimate.extras.single.unitPrice, 150);
    });

    test('a hand-typed line still costs what was typed on it', () {
      final p = room();
      final item = p.addAvCostItem(description: 'Parking', qty: 2);
      p.updateAvCostItem(item.copyWith(unitPrice: 35));

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );
      expect(estimate.extras.single.total, 70);
    });

    test('a room price beats the catalog on these lines as well', () {
      final p = room();
      final item = p.addAvCostItem(
        catalogModel: 'Display mount',
        description: 'Display mount',
      );
      p.setAvCostPrice(item.id, 199);

      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );
      expect(estimate.extras.single.unitPrice, 199);
      expect(estimate.extras.single.source, PriceSource.override);
    });
  });
}
