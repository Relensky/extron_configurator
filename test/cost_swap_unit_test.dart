import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cost_estimate_view.dart';

/// ============================================================================
///  SWAPPING THE BOX ON A QUOTE
/// ============================================================================
///  The estimate is where the wrong product gets noticed, because the total is
///  what people look at. Until now the fix lived on the Signal Flow tab, so the
///  thing that actually happened was that somebody typed a different price over
///  the row — and the quote said one product while the drawing, the rack
///  elevation and the cable schedule said another.
///
///  The swap on this page has to reach all of it: every box behind a line of
///  quantity N, the connectors under them, the runs already drawn, and the
///  price typed against the model that has just left the room.
/// ============================================================================
void main() {
  AvPort port(
    String id,
    String label,
    SignalType signal,
    PortDirection direction,
  ) => AvPort(
    id: id,
    label: label,
    signal: signal,
    direction: direction,
    side: direction == PortDirection.output ? PortSide.right : PortSide.left,
  );

  /// Two catalog displays with the same one connector, at two prices, plus a
  /// spool of cable — which the picker must NOT offer as a replacement for a
  /// display.
  AvDeviceLibrary catalog() => AvDeviceLibrary.empty()
    ..upsert(
      AvDeviceTemplate(
        model: 'Display 65',
        category: 'Display',
        price: 1000,
        rackUnits: 0,
        powerWatts: 120,
        ports: [port('in1', 'HDMI 1', SignalType.hdmi, PortDirection.input)],
      ),
    )
    ..upsert(
      AvDeviceTemplate(
        model: 'Display 86',
        category: 'Display',
        price: 2500,
        powerWatts: 220,
        ports: [port('hdmi_a', 'HDMI IN', SignalType.hdmi,
            PortDirection.input)],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(
        model: 'HDMI 25',
        category: kCategoryCable,
        cableSignal: SignalType.hdmi,
        price: 40,
        ports: [],
      ),
    );

  /// A room with two of the same display drawn, each fed from a source, so a
  /// swap has two boxes and two runs to carry.
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = catalog();
    for (final id in ['D1', 'D2']) {
      p.addAvNode(
        AvNode(
          id: id,
          label: 'Display $id',
          model: 'Display 65',
          pos: Offset.zero,
          rackUnits: 0,
          powerWatts: 120,
          ports: [port('in1', 'HDMI 1', SignalType.hdmi, PortDirection.input)],
        ),
      );
    }
    p.addAvNode(
      AvNode(
        id: 'SRC',
        label: 'Room PC',
        model: 'PC',
        pos: const Offset(400, 0),
        ports: [
          port('o1', 'HDMI OUT 1', SignalType.hdmi, PortDirection.output),
          port('o2', 'HDMI OUT 2', SignalType.hdmi, PortDirection.output),
        ],
      ),
    );
    p.addAvCable(
      fromNodeId: 'SRC',
      fromPortId: 'o1',
      toNodeId: 'D1',
      toPortId: 'in1',
      signal: SignalType.hdmi,
    );
    p.addAvCable(
      fromNodeId: 'SRC',
      fromPortId: 'o2',
      toNodeId: 'D2',
      toPortId: 'in1',
      signal: SignalType.hdmi,
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

  /// Opens the picker on one equipment row and takes [model].
  Future<void> swap(
    WidgetTester tester,
    String lineKey,
    String model,
  ) async {
    await tester.tap(
      find.byKey(ValueKey('eqp_swap_$lineKey')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('catalog_swap_$model')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog_swap_apply')));
    await tester.pumpAndSettle();
  }

  testWidgets('every box behind the line is replaced', (tester) async {
    final p = room();
    await pump(tester, p);

    await swap(tester, 'model:display 65', 'Display 86');

    for (final id in ['D1', 'D2']) {
      final node = p.avNodeById(id)!;
      expect(node.model, 'Display 86');
      expect(node.label, 'Display $id',
          reason: 'the name is a fact about the room, not about the product');
      // The physical facts come off the new entry, which is what makes the
      // power and heat reports right after a swap.
      expect(node.powerWatts, 220);
      expect(node.portById('hdmi_a'), isNotNull,
          reason: 'the connectors come with the model');
    }
  });

  testWidgets('the runs already drawn come with it', (tester) async {
    final p = room();
    await pump(tester, p);

    await swap(tester, 'model:display 65', 'Display 86');

    // Both leads are still there, landed on the new box's HDMI input — the
    // whole point of moving the cable rather than deleting the box.
    expect(p.avCables, hasLength(2));
    final byId = {for (final n in p.avNodes) n.id: n};
    for (final c in p.avCables) {
      expect(AvFlowModel.cableIsResolvable(c, byId), isTrue);
      expect(c.toPortId, 'hdmi_a');
    }
  });

  testWidgets('the line reprices off the new model', (tester) async {
    final p = room();
    await pump(tester, p);

    await swap(tester, 'model:display 65', 'Display 86');
    await tester.pumpAndSettle();

    // Two at the new list price, straight off the catalog.
    expect(find.text(r'$5,000.00'), findsWidgets);
  });

  testWidgets('a price negotiated for the old model does not follow it',
      (tester) async {
    final p = room();
    // What this job was quoted for the 65s.
    p.setAvCostPrice('model:display 65', 800);
    await pump(tester, p);

    await swap(tester, 'model:display 65', 'Display 86');

    expect(p.avCost.priceOverrides['model:display 65'], isNull);
    expect(p.avCost.priceOverrides['model:display 86'], isNull,
        reason: r'$800 was the price of a 65, not of whatever replaced it');
  });

  testWidgets('a quoted-but-undrawn line re-points at the new part',
      (tester) async {
    final p = room();
    final item = p.addAvCostExtraEquipment(
      catalogModel: 'Display 65',
      description: 'Display 65',
      qty: 1,
    );
    await pump(tester, p);

    await swap(tester, item.id, 'Display 86');

    final after = p.avCost.extraEquipment.single;
    expect(after.catalogModel, 'Display 86');
    expect(after.description, 'Display 86');
    // And nothing was drawn: this line was never on the diagram.
    expect(p.avNodes.where((n) => n.model == 'Display 86'), isEmpty);
  });

  testWidgets('a name somebody wrote themselves survives the swap',
      (tester) async {
    final p = room();
    final item = p.addAvCostExtraEquipment(
      catalogModel: 'Display 65',
      description: 'Owner-furnished display in 2201',
      qty: 1,
    );
    await pump(tester, p);

    await swap(tester, item.id, 'Display 86');

    expect(
      p.avCost.extraEquipment.single.description,
      'Owner-furnished display in 2201',
    );
  });

  testWidgets('the picker offers boxes, not cable', (tester) async {
    final p = room();
    await pump(tester, p);

    await tester.tap(
      find.byKey(const ValueKey('eqp_swap_model:display 65')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('catalog_swap_Display 86')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('catalog_swap_HDMI 25')), findsNothing,
        reason: 'a quote line for a display is not going to become a spool');
  });
}
