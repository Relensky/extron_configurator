import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_routing.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  THE ROOM WITH NO MATRIX
/// ============================================================================
///  A huddle space is one panel with a couple of things plugged into the back
///  of it: no switcher, no rack, and `dev_source_control: Display` because the
///  source buttons pick the DISPLAY's input rather than a matrix tie. The
///  `input_*` keys still say where each source is wired — they are numbers on
///  the panel instead of numbers on a matrix, and people write them the way
///  they are silkscreened there ("HDMI 2").
///
///  Until now that room drew nothing at all: the pass hangs off
///  SWITCHERDEVICE_1 and there is none, so the PC, the plate and the wireless
///  box reached neither the drawing nor the estimate. These check that the
///  display stands in for the switcher, and that the two things which must
///  NOT happen still do not: a second lead onto a socket that already has one,
///  and an `output_*` number resolved against a box with no outputs.
/// ============================================================================
void main() {
  late UiSchema schema;
  late AvDeviceLibrary library;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
    library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
  });

  AvNode nodeOf(String id, String model, {String? label, Offset? pos}) {
    final template = library.resolve(configKey: id, model: model);
    return AvNode(
      id: id,
      label: label ?? model,
      model: model,
      pos: pos ?? Offset.zero,
      ports: withPowerInlet(template.ports, template.powerInput),
      fromConfig: true,
    );
  }

  /// A huddle space: a display, a wireless box and a PC that is not a config
  /// block, with no SWITCHERDEVICE_1 anywhere in the file.
  AppStateProvider room({
    String pc = 'HDMI 1',
    String wireless = 'HDMI 2',
    Map<String, String> extraSetup = const {},
  }) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..avDeviceLibrary = library;

    p.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{
      'dev_projectors': '1',
      'dev_switchers': '0',
      'dev_wireless': '1',
      'dev_source_control': 'Display',
      'gui_huddle_space': 'Yes',
      'input_pc': pc,
      'input_wireless': wireless,
      'output_proj_1': 'None',
      ...extraSetup,
    };
    p.roomConfig['PROJECTORDEVICE_1'] = <String, dynamic>{
      'name': 'Display 1',
      'model': 'PowerLite L630U',
      'com_type': 'Network',
    };
    p.roomConfig['WIRELESSDEVICE_1'] = <String, dynamic>{
      'name': 'Wireless - VIA GO2',
      'model': 'VIA GO2',
      'com_type': 'Network',
    };

    p.addAvNode(nodeOf('PROJECTORDEVICE_1', 'PowerLite L630U',
        label: 'Display 1', pos: const Offset(600, 0)));
    p.addAvNode(nodeOf('WIRELESSDEVICE_1', 'VIA GO2',
        label: 'Wireless - VIA GO2'));
    return p;
  }

  /// The cables a config key produced, as "port -> port".
  List<String> ties(RoutingPlan plan, String key) => [
        for (final c in plan.cables)
          if (c.configKey == key) '${c.fromPortLabel} -> ${c.toPortLabel}',
      ];

  // -------------------------------------------------------------------------
  //  READING A SOCKET ON THE PANEL
  // -------------------------------------------------------------------------

  group('the input a display value names', () {
    AvNode display(List<AvPort> ports) => AvNode(
          id: 'PROJECTORDEVICE_1',
          label: 'Display 1',
          model: 'Test Panel',
          pos: Offset.zero,
          ports: ports,
        );

    AvPort input(String id, String label, SignalType signal) => AvPort(
          id: id,
          label: label,
          signal: signal,
          direction: PortDirection.input,
          side: PortSide.left,
        );

    test('the kind and the number, however the catalog spells it', () {
      for (final label in const ['HDMI 2', 'HDMI IN 2', 'HDMI 002']) {
        final node = display([
          input('a', label.replaceAll('2', '1'), SignalType.hdmi),
          input('b', label, SignalType.hdmi),
          input('c', 'HDBaseT', SignalType.hdbaset),
        ]);
        expect(portForDisplayInput(node, 'HDMI 2')?.label, label,
            reason: label);
      }
    });

    test('the kind is checked as well as the number', () {
      final node = display([
        input('a', 'HDMI 1', SignalType.hdmi),
        input('b', 'DISPLAYPORT 2', SignalType.displayPort),
      ]);
      // The number 2 is on the DisplayPort socket, and 'HDMI 2' is not it.
      expect(portForDisplayInput(node, 'HDMI 2'), isNull);
      expect(portForDisplayInput(node, 'DisplayPort 2')?.label,
          'DISPLAYPORT 2');
    });

    test('a kind on its own, and a bare number', () {
      final node = display([
        input('a', 'HDMI 1', SignalType.hdmi),
        input('b', 'HDMI 2', SignalType.hdmi),
        input('c', 'HDBaseT', SignalType.hdbaset),
      ]);
      expect(portForDisplayInput(node, 'HDBaseT')?.label, 'HDBaseT');
      expect(portForDisplayInput(node, '2')?.label, 'HDMI 2');
      expect(portForDisplayInput(node, '')?.label, isNull);
      expect(portForDisplayInput(node, 'None'), isNull);
    });

    test('unnumbered sockets of one kind are counted in catalog order', () {
      final node = display([
        input('a', 'HDMI', SignalType.hdmi),
        input('b', 'HDMI', SignalType.hdmi),
      ]);
      expect(portForDisplayInput(node, 'HDMI 2')?.id, 'b');
      expect(portForDisplayInput(node, 'HDMI 3'), isNull);
    });
  });

  // -------------------------------------------------------------------------
  //  THE WHOLE PASS
  // -------------------------------------------------------------------------

  group('a room with no switcher', () {
    test('routes its sources onto the display', () {
      final plan = planRoutingFromConfig(room());

      expect(ties(plan, 'input_pc'), ['HDMI OUT -> HDMI 1']);
      expect(ties(plan, 'input_wireless'), ['HDMI OUT -> HDMI 2']);
      expect(plan.unresolved, isEmpty);
      // The PC is not a config block, so it is placed like it is in a room
      // with a matrix.
      expect(plan.newNodes.map((n) => n.id), contains(avAutoNodeId('input_pc')));
    });

    test('a bare number reads as the numbered socket', () {
      final plan = planRoutingFromConfig(room(pc: '1', wireless: '2'));
      expect(ties(plan, 'input_pc'), ['HDMI OUT -> HDMI 1']);
      expect(ties(plan, 'input_wireless'), ['HDMI OUT -> HDMI 2']);
    });

    test('a socket the panel does not have is reported, not guessed', () {
      final plan = planRoutingFromConfig(room(pc: 'HDMI 4'));
      expect(ties(plan, 'input_pc'), isEmpty);
      expect(
        plan.unresolved.where((u) => u.configKey == 'input_pc').single.reason,
        contains('no input called "HDMI 4"'),
      );
    });

    test('a socket that already has something on it takes no second lead', () {
      final p = room();
      // A meeting bar somebody drew into HDMI 1 by hand.
      p.addAvNode(nodeOf('AVNODE_9', 'Neat Bar', label: 'Neat Bar'));
      final bar = p.avNodeById('AVNODE_9')!;
      p.addAvCable(
        fromNodeId: bar.id,
        fromPortId: bar.ports.firstWhere((x) => x.isOutput).id,
        toNodeId: 'PROJECTORDEVICE_1',
        toPortId: 'in_hdmi_1',
        signal: SignalType.hdmi,
      );

      final plan = planRoutingFromConfig(p);
      expect(ties(plan, 'input_pc'), isEmpty);
      expect(
        plan.unresolved.where((u) => u.configKey == 'input_pc').single.reason,
        contains('Neat Bar'),
      );
      // ... and the tie that is fine is still drawn.
      expect(ties(plan, 'input_wireless'), ['HDMI OUT -> HDMI 2']);
    });

    test('a run already drawn through a DTP pair is recognised', () {
      final p = room();
      // The wireless box reaches the panel the way the huddle preset wires
      // it: a transmitter in the credenza, twisted pair across the room, a
      // receiver at the display. Three cables, two boxes, one connection —
      // and the config saying "HDMI 2" is describing THAT run.
      p.addAvNode(nodeOf('AVNODE_1', 'DTP HDMI 4K 230 Tx', label: 'DTP Tx'));
      p.addAvNode(nodeOf('AVNODE_2', 'DTP HDMI 4K 230 Rx', label: 'DTP Rx'));
      final via = p.avNodeById('WIRELESSDEVICE_1')!;
      final tx = p.avNodeById('AVNODE_1')!;
      final rx = p.avNodeById('AVNODE_2')!;
      AvPort out(AvNode n, SignalType s) =>
          n.ports.firstWhere((x) => x.isOutput && x.signal == s);
      AvPort into(AvNode n, SignalType s) =>
          n.ports.firstWhere((x) => x.isInput && x.signal == s);

      p.addAvCable(
        fromNodeId: via.id,
        fromPortId: out(via, SignalType.hdmi).id,
        toNodeId: tx.id,
        toPortId: into(tx, SignalType.hdmi).id,
        signal: SignalType.hdmi,
      );
      p.addAvCable(
        fromNodeId: tx.id,
        fromPortId: out(tx, SignalType.hdbaset).id,
        toNodeId: rx.id,
        toPortId: into(rx, SignalType.hdbaset).id,
        signal: SignalType.hdbaset,
      );
      p.addAvCable(
        fromNodeId: rx.id,
        fromPortId: out(rx, SignalType.hdmi).id,
        toNodeId: 'PROJECTORDEVICE_1',
        toPortId: 'in_hdmi_2',
        signal: SignalType.hdmi,
      );

      final plan = planRoutingFromConfig(p);
      expect(ties(plan, 'input_wireless'), isEmpty);
      expect(plan.unresolved.where((u) => u.configKey == 'input_wireless'),
          isEmpty);
      expect(plan.alreadyDrawn, greaterThan(0));
    });

    test('output numbers are left alone — there is no output side', () {
      final plan = planRoutingFromConfig(room(extraSetup: const {
        'output_monitor_1': '2',
        'output_audio': '1',
      }));
      // No confidence monitor and no speakers placed for a number that names
      // nothing, and no complaint about either.
      expect(plan.newNodes.map((n) => n.id),
          isNot(contains(avAutoNodeId('output_monitor_1'))));
      expect(plan.newNodes.map((n) => n.id),
          isNot(contains(avAutoNodeId('output_audio'))));
      expect(
        plan.unresolved.map((u) => u.configKey),
        isNot(anyElement(anyOf('output_monitor_1', 'output_audio'))),
      );
    });

    test('twice over draws it once', () {
      final p = room();
      final first = planRoutingFromConfig(p);
      applyRoutingFromConfig(p, first, quiet: true);
      final second = planRoutingFromConfig(p);
      expect(second.cables, isEmpty);
      expect(second.newNodes, isEmpty);
      expect(second.unresolved, isEmpty);
    });
  });

  group('a room whose switcher is only missing from the canvas', () {
    test('is still told to place it, not routed onto the display', () {
      final p = room();
      // The config HAS a matrix; it is simply not drawn yet.
      p.roomConfig['SWITCHERDEVICE_1'] = <String, dynamic>{
        'name': 'Switcher - DTP CrossPoint 84 4K IPCP MA 70',
        'model': 'DTP CrossPoint 84 4K IPCP MA 70',
        'com_type': 'Network',
      };

      final plan = planRoutingFromConfig(p);
      expect(plan.cables, isEmpty);
      expect(plan.unresolved.single.reason, contains('Place all from config'));
    });
  });
}
