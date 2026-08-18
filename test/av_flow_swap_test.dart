import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  CHANGING YOUR MIND
/// ============================================================================
///  Everything on the AV Flow page could be created and deleted and nothing
///  could be CHANGED. A run drawn to input 3 that turns out to be on input 4
///  had to be deleted and drawn again, which loses its cable id, its label and
///  its length. A box put down as the wrong model had to be deleted and
///  replaced, which loses every cable on it.
///
///  And one rule the canvas was missing while it was at it: DMP EXP is the
///  expansion bus between an Extron matrix and its DSP, spelled `network` on
///  most CrossPoints and `dante` on others, so matching by signal alone let it
///  pair with every LAN socket and every Dante channel in the room.
/// ============================================================================
void main() {
  late UiSchema schema;
  late AvDeviceLibrary library;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
    library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
  });

  AvPort port(
    String id,
    String label,
    SignalType signal,
    PortDirection direction,
  ) =>
      AvPort(
        id: id,
        label: label,
        signal: signal,
        direction: direction,
        side: direction == PortDirection.output
            ? PortSide.right
            : PortSide.left,
      );

  group('the DMP expansion bus', () {
    // The two ends as the catalog actually spells them: the matrix calls its
    // socket `network`, the DSP calls its own `dante`, and both are labelled
    // DMP EXP.
    final matrix = AvNode(
      id: 'SWITCHERDEVICE_1',
      label: 'Switcher',
      model: '',
      pos: Offset.zero,
      ports: [
        port('exp', 'DMP EXP', SignalType.network, PortDirection.output),
        port('lan', 'LAN', SignalType.network, PortDirection.bidirectional),
      ],
    );
    final dsp = AvNode(
      id: 'DSPDEVICE_1',
      label: 'DSP',
      model: '',
      pos: Offset.zero,
      ports: [
        port('exp', 'DMP EXP', SignalType.dante, PortDirection.input),
        port('dante1', 'DANTE 1', SignalType.dante, PortDirection.bidirectional),
      ],
    );
    final switchBox = AvNode(
      id: 'AVNODE_9',
      label: 'Network switch',
      model: '',
      pos: Offset.zero,
      ports: [
        port('p1', 'PORT 1', SignalType.network, PortDirection.bidirectional),
      ],
    );

    AvPort of(AvNode n, String id) => n.portById(id)!;

    test('meets another expansion port, whatever the signal says', () {
      // The catalog disagrees with itself about this cable's signal type.
      // That disagreement is in the catalog, not in the room, so this is a
      // clean match rather than an adapter warning.
      expect(
        checkPortMatch(matrix, of(matrix, 'exp'), dsp, of(dsp, 'exp')),
        PortMatch.ok,
      );
    });

    test('will not meet a network port', () {
      // The rule the whole thing is for: DMP EXP and LAN are both `network`,
      // and a lead between them would never carry anything.
      expect(
        checkPortMatch(
            matrix, of(matrix, 'exp'), switchBox, of(switchBox, 'p1')),
        PortMatch.invalid,
      );
    });

    test('will not meet a Dante port', () {
      expect(
        checkPortMatch(matrix, of(matrix, 'exp'), dsp, of(dsp, 'dante1')),
        PortMatch.invalid,
      );
    });

    test('and an ordinary port is not refused for being near one', () {
      expect(
        checkPortMatch(matrix, of(matrix, 'lan'), switchBox,
            of(switchBox, 'p1')),
        PortMatch.ok,
      );
    });

    test('EXP BUS is the same socket under the other name', () {
      expect(expansionBusFor('EXP BUS'), expansionBusFor('DMP EXP'));
      expect(expansionBusFor('exp-bus'), 'dmp');
      // Different products, different buses — folding these in would let a
      // Quantum expansion port mate with a DMP one.
      expect(expansionBusFor('EXP A'), isNull);
      expect(expansionBusFor('EXP INPUT'), isNull);
      expect(expansionBusFor('ETHERNET'), isNull);
    });
  });

  group('lining one model up with another', () {
    test('the same connector id carries across', () {
      final from = [
        port('in_hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.input),
      ];
      final to = [
        port('in_hdmi_1', 'HDMI IN 1', SignalType.hdmi, PortDirection.input),
      ];
      expect(remapPorts(from, to), {'in_hdmi_1': 'in_hdmi_1'});
    });

    test('failing that, the same label', () {
      final from = [port('a', 'HDMI 3', SignalType.hdmi, PortDirection.input)];
      final to = [port('z', 'hdmi-3', SignalType.hdmi, PortDirection.input)];
      expect(remapPorts(from, to), {'a': 'z'});
    });

    test('failing that, the nth of that kind onto the nth of that kind', () {
      // The case the two passes above miss and the real one: two boxes that
      // spell the same three inputs differently.
      final from = [
        port('a1', 'HDMI 001', SignalType.hdmi, PortDirection.input),
        port('a2', 'HDMI 002', SignalType.hdmi, PortDirection.input),
        port('a3', 'HDMI 003', SignalType.hdmi, PortDirection.input),
      ];
      final to = [
        port('b1', 'HDMI IN 1', SignalType.hdmi, PortDirection.input),
        port('b2', 'HDMI IN 2', SignalType.hdmi, PortDirection.input),
        port('b3', 'HDMI IN 3', SignalType.hdmi, PortDirection.input),
      ];
      expect(remapPorts(from, to), {'a1': 'b1', 'a2': 'b2', 'a3': 'b3'});
    });

    test('a connector the new box does not have is left out', () {
      final from = [
        port('a1', 'HDMI 1', SignalType.hdmi, PortDirection.input),
        port('a2', 'HDMI 2', SignalType.hdmi, PortDirection.input),
      ];
      final to = [port('b1', 'HDMI IN 1', SignalType.hdmi,
          PortDirection.input)];
      // Two into one: the second has nowhere to go, and saying so beats
      // landing it on the first alongside the run already there.
      expect(remapPorts(from, to), {'a1': 'b1'});
    });

    test('a connector is never claimed twice', () {
      final from = [
        port('x', 'HDMI 1', SignalType.hdmi, PortDirection.input),
        port('y', 'HDMI 1', SignalType.hdmi, PortDirection.input),
      ];
      final to = [port('x', 'HDMI 1', SignalType.hdmi, PortDirection.input)];
      final map = remapPorts(from, to);
      expect(map, {'x': 'x'});
      expect(map.values.toSet(), hasLength(map.length));
    });

    test('an output never lands on an input', () {
      final from = [
        port('o', 'AUDIO 1', SignalType.analogAudio, PortDirection.output),
      ];
      final to = [
        port('i', 'AUDIO 1', SignalType.analogAudio, PortDirection.input),
      ];
      // The label pass is the trap here: both are "AUDIO 1". Only the
      // signal+direction pass runs, and it finds no output to land on.
      expect(remapPorts(from, to), isEmpty);
    });
  });

  group('swapping the model under a box', () {
    /// A SW4 feeding a projector, with a source on its first HDMI input —
    /// two runs to carry across.
    AppStateProvider room() {
      final p = AppStateProvider(autoLoadSettings: false)
        ..uiSchema = schema
        ..avDeviceLibrary = library
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      p.loadAvFlowForCurrentConfig();
      final template = library.templateForModel('SW4 HD 4K PLUS')!;
      p.addAvNode(AvNode(
        id: 'SWITCHERDEVICE_1',
        label: 'Switcher',
        model: 'SW4 HD 4K PLUS',
        pos: const Offset(400, 60),
        ports: withPowerInlet(template.ports, template.powerInput),
        fromConfig: true,
      ));
      p.addAvNode(AvNode(
        id: 'AVNODE_1',
        label: 'Room PC',
        model: 'PC',
        pos: const Offset(40, 60),
        ports: [port('out', 'HDMI OUT', SignalType.hdmi,
            PortDirection.output)],
      ));
      p.addAvNode(AvNode(
        id: 'PROJECTORDEVICE_1',
        label: 'Projector',
        model: '',
        pos: const Offset(800, 60),
        ports: [port('in1', 'HDMI 1', SignalType.hdmi, PortDirection.input)],
      ));
      p.addAvCable(
        fromNodeId: 'AVNODE_1',
        fromPortId: 'out',
        toNodeId: 'SWITCHERDEVICE_1',
        toPortId: 'hdmi_1',
        signal: SignalType.hdmi,
      );
      p.addAvCable(
        fromNodeId: 'SWITCHERDEVICE_1',
        fromPortId: 'hdmi',
        toNodeId: 'PROJECTORDEVICE_1',
        toPortId: 'in1',
        signal: SignalType.hdmi,
      );
      return p;
    }

    testWidgets('the cables come with it', (tester) async {
      final p = room();
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
      await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('av_edit_SWITCHERDEVICE_1')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('node_swap_model')));
      await tester.pumpAndSettle();

      // Punctuation and case are ignored on both sides, so the digits are
      // enough to find it.
      await tester.enterText(
          find.byKey(const ValueKey('catalog_swap_search')), 'in1608sa');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog_swap_IN1608 SA')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog_swap_apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final node = p.avNodeById('SWITCHERDEVICE_1')!;
      expect(node.model, 'IN1608 SA');
      expect(node.portById('port_1786393608561286')?.label, 'DTP IN 7',
          reason: 'the new connectors came with the model');

      // Both runs are still drawn, on the IN1608's equivalent sockets: the
      // SW4's first HDMI input is the IN1608's first HDMI input, whatever the
      // two front panels call it, and its one HDMI output is HDMI OUT A.
      final byId = {for (final n in p.avNodes) n.id: n};
      expect(p.avCables, hasLength(2));
      for (final c in p.avCables) {
        expect(AvFlowModel.cableIsResolvable(c, byId), isTrue,
            reason: '${c.id} was left pointing at a connector that is gone');
      }
      expect(
        p.avCables.firstWhere((c) => c.fromNodeId == 'AVNODE_1').toPortId,
        'in_hdmi_3',
      );
      expect(
        p.avCables
            .firstWhere((c) => c.toNodeId == 'PROJECTORDEVICE_1')
            .fromPortId,
        'out_hdmi_1',
      );
    });
  });

  group('moving one end of a drawn run', () {
    /// A switcher, a projector and one cable between them.
    AppStateProvider room() {
      final p = AppStateProvider(autoLoadSettings: false)
        ..uiSchema = schema
        ..avDeviceLibrary = library
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      // Before the nodes go in: opening the tab calls
      // ensureAvFlowForCurrentConfig, which clears the diagram the first time
      // it sees a config. Doing it here makes the tab's own call a no-op.
      p.loadAvFlowForCurrentConfig();
      p.addAvNode(AvNode(
        id: 'SWITCHERDEVICE_1',
        label: 'Switcher',
        model: '',
        pos: Offset.zero,
        ports: [
          port('out1', 'HDMI OUT 1', SignalType.hdmi, PortDirection.output),
          port('out2', 'HDMI OUT 2', SignalType.hdmi, PortDirection.output),
          port('dtp', 'DTP OUT', SignalType.hdbaset, PortDirection.output),
        ],
      ));
      p.addAvNode(AvNode(
        id: 'PROJECTORDEVICE_1',
        label: 'Projector',
      model: '',
        pos: const Offset(400, 0),
        ports: [
          port('in1', 'HDMI 1', SignalType.hdmi, PortDirection.input),
          port('in2', 'HDMI 2', SignalType.hdmi, PortDirection.input),
        ],
      ));
      p.addAvCable(
        fromNodeId: 'SWITCHERDEVICE_1',
        fromPortId: 'out1',
        toNodeId: 'PROJECTORDEVICE_1',
        toPortId: 'in1',
        signal: SignalType.hdmi,
      );
      return p;
    }

    Future<void> openCableDialog(
      WidgetTester tester,
      AppStateProvider p,
    ) async {
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

      // The cable list lives in the bottom pane, which is an edit-mode thing.
      await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
      await tester.pumpAndSettle();

      // The pencil on that list is the way into one cable.
      await tester.tap(find.byKey(const ValueKey('av_cable_edit_C1')));
      await tester.pumpAndSettle();
    }

    testWidgets('the dialog offers both ends', (tester) async {
      final p = room();
      await openCableDialog(tester, p);

      // Scoped to the dialog: the cable list behind it prints the same two
      // endpoints, so an unscoped finder matches both and proves nothing.
      Finder inDialog(Finder f) =>
          find.descendant(of: find.byType(AlertDialog), matching: f);

      expect(inDialog(find.text('Connection')), findsOneWidget);
      expect(inDialog(find.text('Change output')), findsOneWidget);
      expect(inDialog(find.text('Change input')), findsOneWidget);
      expect(inDialog(find.text('Switcher · HDMI OUT 1')), findsOneWidget);
      expect(inDialog(find.text('Projector · HDMI 1')), findsOneWidget);
    });

    testWidgets('moving the input end keeps the same cable', (tester) async {
      final p = room();
      final before = p.avCables.single;

      await openCableDialog(tester, p);
      await tester.tap(find.byKey(const ValueKey('cable_to_end')));
      await tester.pumpAndSettle();

      // Only the projector's two inputs can take this end — not the
      // switcher's outputs, and not the input the run already sits on twice.
      expect(
        find.byKey(const ValueKey('cable_end_PROJECTORDEVICE_1_in2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('cable_end_SWITCHERDEVICE_1_out2')),
        findsNothing,
      );

      await tester
          .tap(find.byKey(const ValueKey('cable_end_PROJECTORDEVICE_1_in2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cable_end_apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final after = p.avCables.single;
      expect(after.id, before.id, reason: 'the same lead, not a new one');
      expect(after.toPortId, 'in2');
      expect(after.fromPortId, 'out1');
    });

    testWidgets('cancelling the dialog moves nothing', (tester) async {
      final p = room();
      await openCableDialog(tester, p);

      await tester.tap(find.byKey(const ValueKey('cable_to_end')));
      await tester.pumpAndSettle();
      await tester
          .tap(find.byKey(const ValueKey('cable_end_PROJECTORDEVICE_1_in2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cable_end_apply')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(p.avCables.single.toPortId, 'in1');
    });

    testWidgets('moving the output end brings the signal with it',
        (tester) async {
      final p = room();
      await openCableDialog(tester, p);

      await tester.tap(find.byKey(const ValueKey('cable_from_end')));
      await tester.pumpAndSettle();
      // An HDBaseT output into an HDMI input is offered, marked as needing an
      // adapter rather than hidden — real rooms are full of them.
      await tester
          .tap(find.byKey(const ValueKey('cable_end_SWITCHERDEVICE_1_dtp')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cable_end_apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final after = p.avCables.single;
      expect(after.fromPortId, 'dtp');
      expect(after.signal, SignalType.hdbaset,
          reason: 'the run is drawn as what its source actually sends');
    });
  });
}
