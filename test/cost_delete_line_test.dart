import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/control_prefill.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  TAKING A LINE OFF THE QUOTE
/// ============================================================================
///  The estimate is COUNTED off the signal flow diagram, which makes "delete
///  this line" a question about the room rather than about the quote: a row
///  removed from the estimate and left drawn is a row that comes straight back
///  on the next rebuild.
///
///  So the delete goes all the way down - the boxes, their cables, their rack
///  slots, the control blocks behind them - and the family the blocks belonged
///  to is renumbered so the Devices tab and the Setup Wizard agree with what
///  is left. A room holding PROJECTORDEVICE_1 and _3 reports one projector and
///  hides the other from every reader in the app.
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
        model: 'PT-MZ682BU8',
        manufacturer: 'Panasonic',
        category: 'Projector',
        price: 2600,
        ports: [],
      ),
    );

  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = catalog();
    return p;
  }

  void draw(AppStateProvider p, String id, String label, String model) {
    p.addAvNode(
      AvNode(
        id: id,
        label: label,
        model: model,
        pos: Offset.zero,
        ports: const [],
      ),
    );
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

  /// Presses the row's delete and answers the question it asks.
  Future<void> deleteRow(
    WidgetTester tester,
    String lineKey, {
    bool confirm = true,
  }) async {
    await tester.tap(find.byKey(ValueKey('eqp_delete_$lineKey')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('cost_delete_confirm')),
      findsOneWidget,
      reason: 'the delete reaches outside the quote, so it asks first',
    );
    await tester.tap(
      confirm
          ? find.byKey(const ValueKey('cost_delete_confirm_go'))
          : find.text('Keep it'),
    );
    // Long enough for the "deleted" bar to have said its piece and gone: the
    // bar carries a timer that guarantees it disappears, and a test that walks
    // off while it is still counting takes the timer down with the tree.
    await tester.pumpAndSettle(const Duration(seconds: 8));
  }

  /// Puts every drawn box into the room config.
  ///
  /// The same call the Cost tab's flag menu makes, made directly: driving the
  /// menu would leave its own "created" bar on screen, and what is under test
  /// here is the delete rather than two snack bars taking turns.
  void buildControlSide(AppStateProvider p) {
    applyControlSide(p, planControlSide(p));
  }

  testWidgets('a line typed on the quote goes on its own', (tester) async {
    final p = room();
    final item = p.addAvCostExtraEquipment(
      catalogModel: 'PT-MZ682BU8',
      description: 'Owner-furnished projector',
      qty: 1,
    );
    draw(p, 'AVNODE_1', 'Projector', 'PowerLite L630U');
    await pump(tester, p);

    await deleteRow(tester, item.id);

    expect(p.avCost.extraEquipment, isEmpty);
    // Nothing was drawn for it, so nothing else in the room moved.
    expect(p.avNodes, hasLength(1));
    expect(p.roomConfig.keys.where((k) => k.startsWith('PROJECTORDEVICE_')),
        isEmpty);
  });

  testWidgets('a drawn box comes off the diagram with its cables', (
    tester,
  ) async {
    final p = room();
    draw(p, 'AVNODE_1', 'Projector', 'PowerLite L630U');
    draw(p, 'AVNODE_2', 'Panasonic', 'PT-MZ682BU8');
    p.addAvCable(
      fromNodeId: 'AVNODE_1',
      fromPortId: 'a',
      toNodeId: 'AVNODE_2',
      toPortId: 'b',
      signal: SignalType.hdmi,
    );
    await pump(tester, p);

    await deleteRow(tester, 'model:powerlite l630u');

    expect(p.avNodeById('AVNODE_1'), isNull);
    expect(p.avNodeById('AVNODE_2'), isNotNull);
    // A run pointing at a socket that no longer exists is a run the canvas
    // silently stops drawing.
    expect(p.avCables, isEmpty);
  });

  testWidgets('every box behind one row goes, not just the first', (
    tester,
  ) async {
    final p = room();
    draw(p, 'AVNODE_1', 'Projector 1', 'PowerLite L630U');
    draw(p, 'AVNODE_2', 'Projector 2', 'PowerLite L630U');
    draw(p, 'AVNODE_3', 'Panasonic', 'PT-MZ682BU8');
    await pump(tester, p);

    // One row on the estimate, quantity two - the grouping the whole page is
    // built on.
    await deleteRow(tester, 'model:powerlite l630u');

    expect(p.avNodes.where((n) => n.model == 'PowerLite L630U'), isEmpty);
    expect(p.avNodes, hasLength(1));
  });

  testWidgets('keeping it changes nothing at all', (tester) async {
    final p = room();
    draw(p, 'AVNODE_1', 'Projector', 'PowerLite L630U');
    buildControlSide(p);
    await pump(tester, p);

    await deleteRow(tester, 'model:powerlite l630u', confirm: false);

    expect(p.avNodeById('PROJECTORDEVICE_1'), isNotNull);
    expect(p.roomConfig['PROJECTORDEVICE_1'], isA<Map>());
    expect(p.roomConfig['SYSTEM_SETUP']['dev_projectors'], '1');
  });

  group('a device the room config knows about', () {
    testWidgets('loses its block, and the wizard count comes down', (
      tester,
    ) async {
      final p = room();
      draw(p, 'AVNODE_1', 'Projector', 'PowerLite L630U');
      buildControlSide(p);
      await pump(tester, p);
      expect(p.roomConfig['SYSTEM_SETUP']['dev_projectors'], '1');

      await deleteRow(tester, 'model:powerlite l630u');

      expect(p.roomConfig['PROJECTORDEVICE_1'], isNull);
      // The Setup Wizard reads this key straight out of SYSTEM_SETUP, so this
      // IS the wizard agreeing with the quote.
      expect(p.roomConfig['SYSTEM_SETUP']['dev_projectors'], '0');
      // And the Devices tab, which walks the count and takes what exists.
      expect(
        activeDeviceKeysIn(p.roomConfig, p.uiSchema.deviceCountMap),
        isEmpty,
      );
    });

    testWidgets('leaves no hole: the family is renumbered behind it', (
      tester,
    ) async {
      final p = room();
      draw(p, 'AVNODE_1', 'Projector', 'PowerLite L630U');
      draw(p, 'AVNODE_2', 'Panasonic', 'PT-MZ682BU8');
      buildControlSide(p);
      await pump(tester, p);
      expect(p.roomConfig['PROJECTORDEVICE_1']['model'], 'PowerLite L630U');
      expect(p.roomConfig['PROJECTORDEVICE_2']['model'], 'PT-MZ682BU8');

      await deleteRow(tester, 'model:powerlite l630u');

      // The survivor moved DOWN onto the vacated number rather than being
      // left at _2 above a count of 1, where every reader of the room would
      // walk past it.
      expect(p.roomConfig['PROJECTORDEVICE_2'], isNull);
      expect(p.roomConfig['PROJECTORDEVICE_1']['model'], 'PT-MZ682BU8');
      expect(p.roomConfig['SYSTEM_SETUP']['dev_projectors'], '1');
      expect(
        activeDeviceKeysIn(p.roomConfig, p.uiSchema.deviceCountMap),
        ['PROJECTORDEVICE_1'],
      );
    });

    testWidgets('and the drawing moves with it, still on the canvas', (
      tester,
    ) async {
      final p = room();
      draw(p, 'AVNODE_1', 'Projector', 'PowerLite L630U');
      draw(p, 'AVNODE_2', 'Panasonic', 'PT-MZ682BU8');
      buildControlSide(p);
      await pump(tester, p);

      await deleteRow(tester, 'model:powerlite l630u');

      // The renumbered block's box followed it onto the new key. It must also
      // still BE on the canvas: the deleted device's old key was remembered as
      // "taken off by hand", and that record has to be cleared before the
      // survivor is handed the same number.
      final survivor = p.avNodeById('PROJECTORDEVICE_1');
      expect(survivor, isNotNull);
      expect(survivor!.model, 'PT-MZ682BU8');
      expect(p.avDismissedDevices.contains('PROJECTORDEVICE_1'), isFalse);
    });
  });
}
