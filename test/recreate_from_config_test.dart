import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_routing.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/room_sidecar.dart';
import 'package:extron_configurator/schematic_view.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  START AGAIN FROM THE CONFIG
/// ============================================================================
///  Both drawings are built from the room config and then edited on top of:
///  boxes dragged, leads drawn, equipment the config knows nothing about added
///  by hand. That is the point of them — until the config moves far enough that
///  reconciling the drawing box by box costs more than drawing it again, and
///  the only way to draw it again was to delete twenty boxes by hand.
///
///  What is checked here is that "again" means AGAIN — the hand work goes, the
///  config's own picture comes back — and that it is one press of Undo to
///  change your mind.
/// ============================================================================
void main() {
  late UiSchema schema;
  late AvDeviceLibrary library;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
    library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
  });

  /// Presses one of the two buttons and says yes to the question.
  Future<void> pressRecreate(WidgetTester tester, Key key) async {
    final button = find.byKey(key);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Recreate from config?'), findsOneWidget);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Recreate'));
    await tester.pumpAndSettle();
  }

  // -------------------------------------------------------------------------
  //  THE AV FLOW
  // -------------------------------------------------------------------------

  /// A room the config describes completely: a matrix, a projector on 3B and a
  /// PC on input 1.
  AppStateProvider flowRoom() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..avDeviceLibrary = library
      ..roomConfig = {
        'SYSTEM_SETUP': {
          'gui_full_room_name': 'Test Room',
          'dev_switchers': '1',
          'dev_projectors': '1',
          'input_pc': '1',
          'output_proj_1': '3B',
        },
        'SWITCHERDEVICE_1': {
          'name': 'Switcher - DTP CrossPoint 84 4K IPCP MA 70',
          'model': 'DTP CrossPoint 84 4K IPCP MA 70',
          'com_type': 'Network',
        },
        'PROJECTORDEVICE_1': {
          'name': 'Projector - PowerLite L630U',
          'model': 'PowerLite L630U',
          'input': 'HDBaseT',
          'com_type': 'Network',
        },
      };
    // Before anything is placed: opening the tab reloads — and so clears — the
    // diagram the first time it sees a config, which would take the fixture
    // with it.
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  Future<void> pumpFlow(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: AvFlowView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  AvNode handBox(String label) => AvNode(
        id: '',
        label: label,
        model: '',
        pos: const Offset(900, 900),
        ports: const [
          AvPort(
            id: 'in_hdmi_1',
            label: 'HDMI IN',
            signal: SignalType.hdmi,
            direction: PortDirection.input,
            side: PortSide.left,
          ),
        ],
      );

  group('the AV Flow tab', () {
    testWidgets('asks first, and a cancelled question changes nothing',
        (tester) async {
      final p = flowRoom();
      await pumpFlow(tester, p);
      final byHand = p.addAvNode(handBox('Whiteboard'));

      final button = find.byKey(const ValueKey('av_flow_recreate'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(p.avNodeById(byHand.id), isNotNull);
    });

    testWidgets('drops the hand work and draws the config again',
        (tester) async {
      final p = flowRoom();
      await pumpFlow(tester, p);

      // The tab's own first visit has already placed the config devices and
      // drawn the ties their numbers describe.
      expect(p.avNodeById('SWITCHERDEVICE_1'), isNotNull);
      final drawn = p.avCables.length;
      expect(drawn, greaterThan(0));

      // Now the drift: a box the config has never heard of, a lead drawn by
      // hand, a matrix dragged across the page, and a projector deleted.
      final byHand = p.addAvNode(handBox('Whiteboard'));
      p.addAvCable(
        fromNodeId: 'SWITCHERDEVICE_1',
        fromPortId: 'hdmi_001',
        toNodeId: byHand.id,
        toPortId: 'in_hdmi_1',
        signal: SignalType.hdmi,
      );
      p.setAvNodePosition('SWITCHERDEVICE_1', const Offset(1234, 900));
      p.removeAvNode('PROJECTORDEVICE_1');
      await tester.pumpAndSettle();

      await pressRecreate(tester, const ValueKey('av_flow_recreate'));

      // Gone: the box, its lead, and the drag.
      expect(p.avNodeById(byHand.id), isNull);
      expect(p.avCables.any((c) => c.toNodeId == byHand.id), isFalse);
      expect(p.avNodeById('SWITCHERDEVICE_1')!.pos,
          isNot(const Offset(1234, 900)));

      // Back: every config device, including the one deleted by hand, and the
      // routing the config's numbers describe.
      expect(p.avNodeById('PROJECTORDEVICE_1'), isNotNull);
      expect(p.avDismissedDevices, isEmpty);
      expect(p.avCables.length, drawn);
      expect(
        p.avCables.any((c) =>
            c.fromNodeId == avAutoNodeId('input_pc') &&
            c.toNodeId == 'SWITCHERDEVICE_1'),
        isTrue,
        reason: 'input_pc: 1 is drawn again',
      );
    });

    testWidgets('one press of Undo puts the whole drawing back',
        (tester) async {
      final p = flowRoom();
      await pumpFlow(tester, p);
      final byHand = p.addAvNode(handBox('Whiteboard'));

      await pressRecreate(tester, const ValueKey('av_flow_recreate'));
      expect(p.avNodeById(byHand.id), isNull);

      // Twenty boxes placed is one edit, not twenty.
      expect(p.avUndoLabel(AvUndoScope.flow), 'Recreate from config');
      p.undoAvFlow(AvUndoScope.flow);
      expect(p.avNodeById(byHand.id), isNotNull);
    });

    testWidgets('a rail keeps its device, and loses what is not coming back',
        (tester) async {
      final p = flowRoom();
      await pumpFlow(tester, p);
      final byHand = p.addAvNode(handBox('An amp nobody has a block for'));
      p.setAvRackSlot(
          'SWITCHERDEVICE_1', const RackSlot(rackId: 'RACK_1', startU: 4));
      p.setAvRackSlot(byHand.id, const RackSlot(rackId: 'RACK_1', startU: 6));

      await pressRecreate(tester, const ValueKey('av_flow_recreate'));

      // Re-reading the config is not a reason to unrack the room.
      expect(p.avRackSlots['SWITCHERDEVICE_1']?.startU, 4);
      // And the rail the hand-added box was on is empty, rather than occupied
      // by a name nothing answers to.
      expect(p.avRackSlots.containsKey(byHand.id), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  //  THE CONTROL SCHEMATIC
  // -------------------------------------------------------------------------

  AppStateProvider schematicRoom() => AppStateProvider(autoLoadSettings: false)
    ..roomConfig = {
      'SYSTEM_SETUP': {
        'gui_full_room_name': 'Test Room',
        'processor1': 'MainProcessor',
        'dev_projectors': '1',
      },
      'PROJECTORDEVICE_1': {
        'name': 'Projector 1',
        'model': 'VPL-PHZ60',
        'com_type': 'Network',
        'ip_address': '10.0.0.5',
        'protocol': 'TCP',
      },
    };

  group('the Control Schematic tab', () {
    test('everything the config did not put there goes', () {
      final p = schematicRoom();
      final extra =
          p.addSchematicExtraNode(title: 'Building switch', icon: 'switch');
      p.addSchematicLink(extra, kSchematicProcessor, '42A5F5', 'Uplink');
      p.setSchematicPosition('PROJECTORDEVICE_1', const Offset(900, 900));
      final auto = SchematicModel.build(p)
          .edges
          .firstWhere((e) => e.fromId == 'PROJECTORDEVICE_1');
      p.hideSchematicEdge(auto.autoId);

      p.recreateSchematicFromConfig();

      expect(p.schematicExtraNodes, isEmpty);
      expect(p.schematicLinks, isEmpty);
      expect(p.schematicHiddenEdges, isEmpty);
      expect(p.schematicPositions, isEmpty);
      // And the drawing is the config's again: the hand-added box is gone with
      // the rest, and the line somebody hid is back.
      final model = SchematicModel.build(p);
      expect(model.nodeById(extra), isNull);
      expect(model.edges.any((e) => e.autoId == auto.autoId), isTrue);
    });

    test('a landing that still means something is kept', () {
      final p = schematicRoom();
      p.setSchematicLanding(kSchematicProcessor, avLan: true);
      p.setSchematicConnColor(0, const Color(0xFF66BB6A));

      p.recreateSchematicFromConfig();

      // Where the room's drops actually go is a fact somebody recorded, and
      // the colors have their own Reset all.
      expect(p.schematicAvLanTarget, kSchematicProcessor);
      expect(p.schematicConnColors[0], const Color(0xFF66BB6A));
    });

    test('a landing pointing at a box being removed goes back to the IDF', () {
      final p = schematicRoom();
      final extra =
          p.addSchematicExtraNode(title: 'AV LAN switch', icon: 'switch');
      p.setSchematicLanding(extra, avLan: true);

      p.recreateSchematicFromConfig();

      expect(p.schematicAvLanTarget, kSchematicIdf,
          reason: 'the drops would otherwise land on nothing');
    });

    testWidgets('the button is on the toolbar, and asks first', (tester) async {
      final p = schematicRoom();
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: SchematicView())),
        ),
      );
      await tester.pumpAndSettle();

      // Added after the tab has opened: its first frame loads the layout that
      // belongs to this config, which would take a box added before it.
      p.addSchematicExtraNode(title: 'Building switch', icon: 'switch');
      await tester.pumpAndSettle();

      await pressRecreate(tester, const ValueKey('schematic_recreate'));

      expect(p.schematicExtraNodes, isEmpty);
      expect(p.schematicUndoLabel, 'Recreate from config');
      p.undoSchematic();
      expect(p.schematicExtraNodes, hasLength(1));
    });
  });
}
