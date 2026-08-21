import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/cabling_schematic.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/room_locations.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  SWAPPING THE BOX ON A QUOTE
/// ============================================================================
///  The estimate is where the wrong product gets noticed, because the total is
///  what people look at. Until now the fix lived on the Signal Flow tab, so the
///  thing that actually happened was that somebody typed a different price over
///  the row — and the quote said one product while the drawing, the rack
///  elevation and the config said another.
///
///  So the swap has to reach all of it: every box behind a line of quantity N,
///  the connectors under them, the runs already drawn, the cabling sheet those
///  runs are drawn on, the config block the control system commissions from,
///  and the price typed against the model that has just left the room.
///
///  And it has to say when it can't. A model no Python driver claims can be
///  quoted and drawn — a part often arrives before its driver does — but the
///  config block behind it keeps a module that no longer matches the model on
///  it, and a config that looks complete is the one nobody re-checks.
/// ============================================================================
void main() {
  late UiSchema schema;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

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

  /// Three catalog displays and a spool of cable. The 86 takes the same lead
  /// as the 65 under a different connector name; the analog one has nothing a
  /// carried HDMI run can land on; the spool must never be offered as a
  /// replacement for a display.
  AvDeviceLibrary catalog() => AvDeviceLibrary.empty()
    ..upsert(
      AvDeviceTemplate(
        model: 'Display 65',
        category: 'Display',
        price: 1000,
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
        ports: [
          port('hdmi_a', 'HDMI IN', SignalType.hdmi, PortDirection.input),
        ],
      ),
    )
    ..upsert(
      AvDeviceTemplate(
        model: 'Display Analog',
        category: 'Display',
        price: 400,
        ports: [port('vga', 'VGA', SignalType.vga, PortDirection.input)],
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

  /// A room with two of the same display — drawn, in the room config, and each
  /// fed from a source, so a swap has two boxes, two control blocks and two
  /// runs to carry.
  ///
  /// [driven] registers a Python module for the 86, which is what decides
  /// whether the swap goes through silently or stops to warn.
  AppStateProvider room({bool driven = true}) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..roomConfig = {
        'SYSTEM_SETUP': {
          'gui_full_room_name': 'Test Room',
          'dev_projectors': 2,
        },
        'PROJECTORDEVICE_1': {
          'model': 'Display 65',
          'module': 'modules.device.display_65',
          'ip_address': '10.1.1.51',
        },
        'PROJECTORDEVICE_2': {
          'model': 'Display 65',
          'module': 'modules.device.display_65',
          'ip_address': '10.1.1.52',
        },
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = catalog();
    if (driven) {
      p.modelRegistry['Display 86'] = const ModelEntry(
        model: 'Display 86',
        module: 'display_86',
        explicit: true,
      );
    }

    // One place for everything, so the cabling sheet has boxes to draw runs
    // between: it is a room drawing, and a room drawing is about places.
    final lectern = p.addAvLocation(
      const RoomLocation(id: 'LOC_1', name: 'Lectern', zone: RoomZone.lectern),
    );
    final wall = p.addAvLocation(
      const RoomLocation(id: 'LOC_2', name: 'Front wall', zone: RoomZone.wall),
    );

    for (final id in ['PROJECTORDEVICE_1', 'PROJECTORDEVICE_2']) {
      p.addAvNode(
        AvNode(
          id: id,
          label: 'Display $id',
          model: 'Display 65',
          pos: Offset.zero,
          powerWatts: 120,
          fromConfig: true,
          locationId: wall.id,
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
        locationId: lectern.id,
        ports: [
          port('o1', 'HDMI OUT 1', SignalType.hdmi, PortDirection.output),
          port('o2', 'HDMI OUT 2', SignalType.hdmi, PortDirection.output),
        ],
      ),
    );
    p.addAvCable(
      fromNodeId: 'SRC',
      fromPortId: 'o1',
      toNodeId: 'PROJECTORDEVICE_1',
      toPortId: 'in1',
      signal: SignalType.hdmi,
    );
    p.addAvCable(
      fromNodeId: 'SRC',
      fromPortId: 'o2',
      toNodeId: 'PROJECTORDEVICE_2',
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

  /// Opens the picker on one equipment row and takes [model]. Stops there —
  /// whatever the page does next is what each test is about.
  Future<void> pick(
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

  /// How many runs the cabling sheet draws for this room.
  double schematicRuns(AppStateProvider p) {
    final model = buildAvFlowModel(p);
    final sheet = buildCablingSchematic(
      model: model,
      locations: model.locations,
      overrides: model.cablingEdits,
    );
    return sheet.bundles.fold(0.0, (sum, b) => sum + b.count);
  }

  group('a model a driver claims', () {
    testWidgets('goes through without stopping to ask', (tester) async {
      final p = room();
      await pump(tester, p);

      await pick(tester, 'model:display 65', 'Display 86');

      expect(find.byKey(const ValueKey('swap_no_module_warning')), findsNothing,
          reason: 'nothing to warn about — a module claims the 86');
      expect(p.avNodeById('PROJECTORDEVICE_1')!.model, 'Display 86');
    });

    testWidgets('every box behind the line is replaced', (tester) async {
      final p = room();
      await pump(tester, p);

      await pick(tester, 'model:display 65', 'Display 86');

      for (final id in ['PROJECTORDEVICE_1', 'PROJECTORDEVICE_2']) {
        final node = p.avNodeById(id)!;
        expect(node.model, 'Display 86');
        expect(node.label, 'Display $id',
            reason: 'the name is a fact about the room, not the product');
        // The physical facts come off the new entry, which is what makes the
        // power and heat reports right after a swap.
        expect(node.powerWatts, 220);
        expect(node.portById('hdmi_a'), isNotNull,
            reason: 'the connectors come with the model');
      }
    });

    testWidgets('the control side follows', (tester) async {
      final p = room();
      await pump(tester, p);

      await pick(tester, 'model:display 65', 'Display 86');

      for (final key in ['PROJECTORDEVICE_1', 'PROJECTORDEVICE_2']) {
        final dev = p.roomConfig[key] as Map;
        expect(dev['model'], 'Display 86');
        expect(dev['module'], 'modules.device.display_86',
            reason: 'a block still holding the old driver commissions the '
                'room as the box that is no longer in it');
      }
    });

    testWidgets("the room's own settings are kept", (tester) async {
      final p = room();
      await pump(tester, p);

      await pick(tester, 'model:display 65', 'Display 86');

      // An IP address is a fact about this install, not about the product on
      // the wall, and swapping the product is not a reason to lose it.
      expect((p.roomConfig['PROJECTORDEVICE_1'] as Map)['ip_address'],
          '10.1.1.51');
      expect((p.roomConfig['PROJECTORDEVICE_2'] as Map)['ip_address'],
          '10.1.1.52');
    });

    testWidgets('the runs already drawn come with it', (tester) async {
      final p = room();
      await pump(tester, p);

      await pick(tester, 'model:display 65', 'Display 86');

      expect(p.avCables, hasLength(2));
      final byId = {for (final n in p.avNodes) n.id: n};
      for (final c in p.avCables) {
        expect(AvFlowModel.cableIsResolvable(c, byId), isTrue);
        expect(c.toPortId, 'hdmi_a');
      }
    });

    testWidgets('the cabling sheet still draws them', (tester) async {
      final p = room();
      await pump(tester, p);
      expect(schematicRuns(p), 2);

      await pick(tester, 'model:display 65', 'Display 86');

      // The sheet is built from the flow rather than stored, so a swap that
      // keeps the runs keeps the drawing of them.
      expect(schematicRuns(p), 2);
    });

    testWidgets('the line reprices off the new model', (tester) async {
      final p = room();
      await pump(tester, p);

      await pick(tester, 'model:display 65', 'Display 86');
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

      await pick(tester, 'model:display 65', 'Display 86');

      expect(p.avCost.priceOverrides['model:display 65'], isNull);
      expect(p.avCost.priceOverrides['model:display 86'], isNull,
          reason: r'$800 was the price of a 65, not of whatever replaced it');
    });
  });

  group('a model no driver claims', () {
    testWidgets('is warned about before anything changes', (tester) async {
      final p = room(driven: false);
      await pump(tester, p);

      await pick(tester, 'model:display 65', 'Display 86');

      expect(find.byKey(const ValueKey('swap_no_module_warning')),
          findsOneWidget);
      expect(find.text('No control module claims Display 86'), findsOneWidget);
      // Nothing has happened yet: the dialog is asked before the first write.
      expect(p.avNodeById('PROJECTORDEVICE_1')!.model, 'Display 65');
    });

    testWidgets('cancelling leaves the room exactly as it was', (tester) async {
      final p = room(driven: false);
      p.setAvCostPrice('model:display 65', 800);
      await pump(tester, p);

      await pick(tester, 'model:display 65', 'Display 86');
      await tester.tap(find.byKey(const ValueKey('swap_cancel')));
      await tester.pumpAndSettle();

      expect(p.avNodeById('PROJECTORDEVICE_1')!.model, 'Display 65');
      expect((p.roomConfig['PROJECTORDEVICE_1'] as Map)['model'], 'Display 65');
      expect(p.avCost.priceOverrides['model:display 65'], 800,
          reason: 'a cancelled swap must not clear the room price either');
    });

    testWidgets('going ahead anyway is allowed, and says what is left undone',
        (tester) async {
      final p = room(driven: false);
      await pump(tester, p);

      await pick(tester, 'model:display 65', 'Display 86');
      await tester.tap(find.byKey(const ValueKey('swap_apply')));
      await tester.pumpAndSettle();

      // The box and the config block both move — a part often arrives before
      // its driver does, and the quote and the drawing should not wait.
      expect(p.avNodeById('PROJECTORDEVICE_1')!.model, 'Display 86');
      expect((p.roomConfig['PROJECTORDEVICE_1'] as Map)['model'], 'Display 86');
      // The module is left alone rather than blanked or guessed at, which is
      // what the Devices tab does with an unclaimed model — and exactly why
      // the warning had to be read first.
      expect((p.roomConfig['PROJECTORDEVICE_1'] as Map)['module'],
          'modules.device.display_65');
      expect(find.textContaining('no module claims Display 86'), findsWidgets);
    });
  });

  group('runs that cannot be carried', () {
    testWidgets('are dropped from the flow and from the cabling sheet',
        (tester) async {
      final p = room();
      p.modelRegistry['Display Analog'] = const ModelEntry(
        model: 'Display Analog',
        module: 'display_analog',
        explicit: true,
      );
      await pump(tester, p);
      expect(schematicRuns(p), 2);

      // Nothing on the analog display can take an HDMI lead.
      await pick(tester, 'model:display 65', 'Display Analog');

      expect(p.avCables, isEmpty);
      expect(schematicRuns(p), 0,
          reason: 'the sheet draws the runs that are left, not the ones that '
              'were there when it was last looked at');
      expect(find.textContaining('2 cables dropped'), findsWidgets);
    });
  });

  group('a line quoted without being drawn', () {
    testWidgets('re-points at the new part', (tester) async {
      final p = room();
      final item = p.addAvCostExtraEquipment(
        catalogModel: 'Display 65',
        description: 'Display 65',
        qty: 1,
      );
      await pump(tester, p);

      await pick(tester, item.id, 'Display 86');

      final after = p.avCost.extraEquipment.single;
      expect(after.catalogModel, 'Display 86');
      expect(after.description, 'Display 86');
      // And nothing was drawn: this line was never on the diagram.
      expect(p.avNodes.where((n) => n.id.startsWith('EQP_')), isEmpty);
    });

    testWidgets('keeps a name somebody wrote themselves', (tester) async {
      final p = room();
      final item = p.addAvCostExtraEquipment(
        catalogModel: 'Display 65',
        description: 'Owner-furnished display in 2201',
        qty: 1,
      );
      await pump(tester, p);

      await pick(tester, item.id, 'Display 86');

      expect(
        p.avCost.extraEquipment.single.description,
        'Owner-furnished display in 2201',
      );
    });

    testWidgets('still says when no driver claims the new part',
        (tester) async {
      final p = room(driven: false);
      final item = p.addAvCostExtraEquipment(
        catalogModel: 'Display 65',
        description: 'Display 65',
        qty: 1,
      );
      await pump(tester, p);

      await pick(tester, item.id, 'Display 86');

      // No box and no config block, so there is nothing to decide — but the
      // gap is still worth hearing about before it becomes a purchase order.
      expect(find.textContaining('no control module claims it'), findsWidgets);
    });
  });

  testWidgets('the picker offers boxes, not cable', (tester) async {
    final p = room();
    await pump(tester, p);

    await tester.tap(
      find.byKey(const ValueKey('eqp_swap_model:display 65')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('catalog_swap_Display 86')), findsOneWidget);
    expect(find.byKey(const ValueKey('catalog_swap_HDMI 25')), findsNothing,
        reason: 'a quote line for a display is not going to become a spool');
  });
}
