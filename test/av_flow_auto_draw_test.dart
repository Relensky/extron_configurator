import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_routing.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  THE ROOM THE CONFIG DESCRIBES, DRAWN WITHOUT BEING ASKED
/// ============================================================================
///  `input_pc: "1"` says the room has a PC and the PC is on input 1.
///  `output_proj_1: "3B"` and the projector's own `input` name the two ends of
///  the run to the display. None of that is a preference anybody has to be
///  consulted about — and until it drew itself, a room's PC, doc cam and DTP
///  receivers reached neither the drawing nor, because the estimate counts the
///  boxes on the drawing, the quote.
///
///  Two things are being checked here. That the transcription is right: the
///  number in the file is the socket the lead is drawn into, at both ends. And
///  that running by itself is safe — never the same box twice, never a drawing
///  invented for a room that has none, and a box somebody deleted stays
///  deleted.
/// ============================================================================
void main() {
  late UiSchema schema;
  late AvDeviceLibrary library;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
    library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
  });

  /// A room whose config names a PC, a doc cam and a laptop plate, and drives
  /// one projector off output 3B — a DTP output on this matrix. The switcher
  /// and the projector are already on the canvas, which is the state the AV
  /// Flow tab is in after its first-visit seed.
  ///
  /// [projectorInput] is the projector block's own `input`: the connector
  /// somebody plugged into, and the fact the far end of the run turns on.
  AppStateProvider room({String projectorInput = 'HDBaseT'}) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..avDeviceLibrary = library;

    p.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{
      'dev_projectors': '1',
      'dev_switchers': '1',
      'dev_power_controllers': '1',
      'input_pc': '1',
      'input_hdmi': '4',
      'input_doc_cam': '6',
      // DTP IN 7 on this matrix, and a camera has an HDMI socket.
      'input_inst_cam': '7',
      'output_proj_1': '3B',
      'dev_usb_switchers': '1',
      'power1_outlet_1': 'PC',
      'power1_outlet_2': 'Switch',
      'power1_outlet_6': 'Doc\\rCam',
      'power1_outlet_7': 'Intake Fans',
    };
    p.roomConfig['CAMERADEVICE_1'] = <String, dynamic>{
      'name': 'Camera - TR311',
      'model': 'TR311',
      'com_type': 'Network',
    };
    p.roomConfig['POWERDEVICE_1'] = <String, dynamic>{
      'name': 'Power Controller - APC AP7900B',
      'model': 'AP7900B',
      'com_type': 'Network',
    };
    p.roomConfig['PROJECTORDEVICE_1'] = <String, dynamic>{
      'name': 'Projector - PowerLite L630U',
      'model': 'PowerLite L630U',
      'input': projectorInput,
      'com_type': 'Network',
    };
    p.roomConfig['SWITCHERDEVICE_1'] = <String, dynamic>{
      'name': 'Switcher - DTP CrossPoint 84 4K IPCP MA 70',
      'model': 'DTP CrossPoint 84 4K IPCP MA 70',
      'com_type': 'Network',
    };
    p.roomConfig['USBDEVICE_1'] = <String, dynamic>{
      'name': 'USB Switcher - Toggle',
      'model': 'Toggle',
      'com_type': 'Serial',
    };

    for (final key in const [
      'SWITCHERDEVICE_1',
      'PROJECTORDEVICE_1',
      'CAMERADEVICE_1',
      'POWERDEVICE_1',
      'USBDEVICE_1',
    ]) {
      final dev = p.roomConfig[key] as Map;
      final template = p.avDeviceLibrary
          .resolve(configKey: key, model: dev['model'].toString());
      p.addAvNode(AvNode(
        id: key,
        label: dev['name'].toString(),
        model: dev['model'].toString(),
        pos: Offset.zero,
        ports: withPowerInlet(template.ports, template.powerInput),
        fromConfig: true,
      ));
    }
    return p;
  }

  /// Every cable out of [nodeId], as "port -> box (port)".
  List<String> runsFrom(AppStateProvider p, String nodeId) {
    final out = <String>[];
    for (final c in p.avCables) {
      if (c.fromNodeId != nodeId) continue;
      final from = p.avNodeById(c.fromNodeId);
      final to = p.avNodeById(c.toNodeId);
      out.add('${from?.portById(c.fromPortId)?.label} -> ${to?.label} '
          '(${to?.portById(c.toPortId)?.label})');
    }
    return out;
  }

  /// Where a source's lead lands on the switcher.
  String? landsOn(AppStateProvider p, String nodeId) {
    for (final c in p.avCables) {
      if (c.fromNodeId != nodeId) continue;
      return p.avNodeById(c.toNodeId)?.portById(c.toPortId)?.label;
    }
    return null;
  }

  group('the sources', () {
    test('each one placed and tied to the input its number names', () {
      final p = room();
      autoDrawRoutingFromConfig(p);

      expect(landsOn(p, avAutoNodeId('input_pc')), 'HDMI 1');
      expect(landsOn(p, avAutoNodeId('input_hdmi')), 'HDMI 4');
      expect(landsOn(p, avAutoNodeId('input_doc_cam')), 'HDMI 6');

      expect(p.avNodeById(avAutoNodeId('input_pc'))?.model, 'PC');
      expect(p.avNodeById(avAutoNodeId('input_doc_cam'))?.model,
          'Document Camera');
    });

    test('a blank field is not a device', () {
      final p = room();
      (p.roomConfig['SYSTEM_SETUP'] as Map)['input_doc_cam'] = '';
      autoDrawRoutingFromConfig(p);
      expect(p.avNodeById(avAutoNodeId('input_doc_cam')), isNull);
    });
  });

  group('the transmitters', () {
    test('a source on a DTP input gets one', () {
      final p = room();
      autoDrawRoutingFromConfig(p);

      // input_inst_cam = 7 is DTP IN 7 on this matrix, and a camera has an
      // HDMI socket and nothing else. Twisted pair into the switcher, a short
      // HDMI lead at the camera, and a transmitter where they meet.
      final tx = p.avNodeById(avAutoNodeId('input_inst_cam_tx'));
      expect(tx, isNotNull);
      expect(tx!.model, 'DTP HDMI 4K 230 Tx');

      expect(runsFrom(p, 'CAMERADEVICE_1'),
          contains('HDMI OUT -> ${tx.label} (HDMI)'));
      expect(runsFrom(p, tx.id),
          contains('DTP -> Switcher - DTP CrossPoint 84 4K IPCP MA 70 '
              '(DTP IN 7)'));
    });

    test('a source on an HDMI input does not', () {
      final p = room();
      autoDrawRoutingFromConfig(p);

      // The PC is on HDMI 1. Both ends are HDMI, so it is one lead.
      expect(p.avNodeById(avAutoNodeId('input_pc_tx')), isNull);
      expect(landsOn(p, avAutoNodeId('input_pc')), 'HDMI 1');
    });

    test('a transmitter deleted by hand takes its two cables with it', () {
      final p = room();
      autoDrawRoutingFromConfig(p);

      p.removeAvNode(avAutoNodeId('input_inst_cam_tx'));
      autoDrawRoutingFromConfig(p);

      expect(p.avNodeById(avAutoNodeId('input_inst_cam_tx')), isNull);
      expect(runsFrom(p, 'CAMERADEVICE_1'), isEmpty);
    });
  });

  group('the power controller', () {
    /// The box an outlet's mains lead lands on.
    String? outlet(AppStateProvider p, String label) {
      for (final c in p.avCables) {
        if (c.fromNodeId != 'POWERDEVICE_1') continue;
        final from = p.avNodeById(c.fromNodeId);
        if (from?.portById(c.fromPortId)?.label != label) continue;
        return p.avNodeById(c.toNodeId)?.label;
      }
      return null;
    }

    test('an outlet named after a box is plugged into it', () {
      final p = room();
      autoDrawRoutingFromConfig(p);

      // The example the whole thing was asked for: outlet 1 says PC, so it
      // goes to the PC.
      expect(outlet(p, 'OUTLET 1'), 'Room PC');
      // And the line break in the label is not part of the name.
      expect(outlet(p, 'OUTLET 6'), 'Document camera');
    });

    test('the lead lands on the box power inlet, not a signal port', () {
      final p = room();
      autoDrawRoutingFromConfig(p);

      final lead = p.avCables.firstWhere((c) =>
          c.fromNodeId == 'POWERDEVICE_1' &&
          c.toNodeId == avAutoNodeId('input_pc'));
      expect(lead.toPortId, kPowerPortId);
      expect(lead.signal, SignalType.power);
    });

    test('the box then says it is on a controller', () {
      final p = room();
      autoDrawRoutingFromConfig(p);

      // The Power Schedule prints this column. Drawing the lead and leaving
      // the column saying "Not recorded" is a report contradicting its own
      // diagram.
      expect(p.avNodeById(avAutoNodeId('input_pc'))?.powerSource,
          PowerSource.controller);
    });

    test('"Switch" is the switcher, not a coin toss', () {
      final p = room();
      autoDrawRoutingFromConfig(p);

      // In a room built out of Extron gear the word means the matrix, and
      // 'Switcher - ...' and 'USB Switcher - ...' both start with the same
      // six letters. Scored on the label alone it was a tie and nothing was
      // drawn — in every room on the estate.
      expect(outlet(p, 'OUTLET 2'),
          'Switcher - DTP CrossPoint 84 4K IPCP MA 70');
      expect(
        planRoutingFromConfig(p).unresolved.map((u) => u.configKey),
        isNot(contains('power1_outlet_2')),
      );
    });

    test('and "USB Switch" is still the USB switcher', () {
      final p = room();
      (p.roomConfig['SYSTEM_SETUP'] as Map)['power1_outlet_2'] = 'USB Switch';
      autoDrawRoutingFromConfig(p);

      // Two words, so it misses the alias table entirely and goes on being
      // scored the way it always was.
      expect(outlet(p, 'OUTLET 2'), 'USB Switcher - Toggle');
    });

    test('an outlet naming something the drawing does not show is quiet', () {
      final p = room();
      final plan = planRoutingFromConfig(p);

      // 'Intake Fans' is a real outlet on a real APC and will never be a box
      // on a signal-flow diagram. Not a finding, just not drawn.
      expect(plan.cables.map((c) => c.configKey),
          isNot(contains('power1_outlet_7')));
      expect(plan.unresolved.map((u) => u.configKey),
          isNot(contains('power1_outlet_7')));
    });

    test('a name two boxes answer to is refused, with both named', () {
      final p = room();
      (p.roomConfig['SYSTEM_SETUP'] as Map)['power1_outlet_2'] = 'Camera';

      final plan = planRoutingFromConfig(p);
      final tie = plan.unresolved
          .firstWhere((u) => u.configKey == 'power1_outlet_2');
      expect(tie.reason, contains('Camera - TR311'));
      expect(tie.reason, contains('Document camera'));
      expect(plan.cables.map((c) => c.configKey),
          isNot(contains('power1_outlet_2')));
    });
  });

  group('the outputs', () {
    test('a DTP output to a display on HDBaseT is one cable', () {
      final p = room(projectorInput: 'HDBaseT');
      autoDrawRoutingFromConfig(p);

      // 3B on the matrix, HDBaseT at the projector, and the lead joins exactly
      // those two — no box in between, because the projector takes the twisted
      // pair itself.
      expect(
        runsFrom(p, 'SWITCHERDEVICE_1'),
        contains('DTP OUT 003B -> Projector - PowerLite L630U (HDBaseT)'),
      );
      expect(p.avNodeById(avAutoNodeId('output_proj_1_rx')), isNull);
    });

    test('a DTP output to a display on HDMI puts the receiver in', () {
      final p = room(projectorInput: 'HDMI 1');
      autoDrawRoutingFromConfig(p);

      // The cable that cannot exist is not drawn. A DTP output is twisted pair
      // and an HDMI input is not, so the run is two cables and a box: the
      // thing every tech does without writing it down, and the thing a drawing
      // taken straight off the config used to get wrong.
      final rx = p.avNodeById(avAutoNodeId('output_proj_1_rx'));
      expect(rx, isNotNull);
      expect(rx!.model, 'DTP HDMI 4K 230 Rx');

      expect(
        runsFrom(p, 'SWITCHERDEVICE_1'),
        contains('DTP OUT 003B -> ${rx.label} (DTP IN)'),
      );
      expect(
        runsFrom(p, rx.id),
        contains('HDMI OUT -> Projector - PowerLite L630U (HDMI 1)'),
      );
      expect(
        p.avCables.any((c) =>
            c.fromNodeId == 'SWITCHERDEVICE_1' &&
            c.toNodeId == 'PROJECTORDEVICE_1'),
        isFalse,
        reason: 'the direct run is the one that cannot be built',
      );
    });

    test('the receiver lands upstream of the display it feeds', () {
      final p = room(projectorInput: 'HDMI 1');
      p.setAvNodePosition('PROJECTORDEVICE_1', const Offset(1200, 300));
      autoDrawRoutingFromConfig(p);

      final rx = p.avNodeById(avAutoNodeId('output_proj_1_rx'))!;
      expect(rx.pos.dx, lessThan(1200));
      expect(rx.pos.dy, 300);
    });

    test('a receiver already on the diagram is used, not duplicated', () {
      final p = room(projectorInput: 'HDMI 1');

      // A diagram drawn by hand before any of this existed: the receiver is
      // there, cabled to the projector, under whatever name somebody gave it.
      final template = p.avDeviceLibrary
          .resolve(configKey: 'AVNODE_9', model: 'DTP HDMI 4K 230 Rx');
      final byHand = p.addAvNode(AvNode(
        id: 'AVNODE_9',
        label: 'Rx behind the screen',
        model: 'DTP HDMI 4K 230 Rx',
        pos: const Offset(900, 60),
        ports: withPowerInlet(template.ports, template.powerInput),
      ));
      p.addAvCable(
        fromNodeId: byHand.id,
        fromPortId: byHand.ports.firstWhere((x) => x.label == 'HDMI OUT').id,
        toNodeId: 'PROJECTORDEVICE_1',
        toPortId: 'in_hdmi_1',
        signal: SignalType.hdmi,
      );

      autoDrawRoutingFromConfig(p);

      expect(p.avNodeById(avAutoNodeId('output_proj_1_rx')), isNull,
          reason: 'a second receiver for the same display is not wanted');
      expect(
        p.avNodes.where((n) => n.model == 'DTP HDMI 4K 230 Rx'),
        hasLength(1),
      );
      // The half that WAS missing gets drawn: the switcher into the receiver.
      expect(runsFrom(p, 'SWITCHERDEVICE_1'),
          contains('DTP OUT 003B -> Rx behind the screen (DTP IN)'));
    });
  });

  group('running by itself', () {
    test('a second pass changes nothing', () {
      final p = room(projectorInput: 'HDMI 1');
      autoDrawRoutingFromConfig(p);
      final nodes = p.avNodes.length;
      final cables = p.avCables.length;

      final again = autoDrawRoutingFromConfig(p);
      expect(again.nodesAdded, 0);
      expect(again.cablesDrawn, 0);
      expect(p.avNodes, hasLength(nodes));
      expect(p.avCables, hasLength(cables));
    });

    test('a source deleted by hand is not put back', () {
      final p = room();
      autoDrawRoutingFromConfig(p);

      p.removeAvNode(avAutoNodeId('input_doc_cam'));
      autoDrawRoutingFromConfig(p);

      expect(p.avNodeById(avAutoNodeId('input_doc_cam')), isNull,
          reason: 'dragging back a box somebody deleted every visit is not '
              'helpful — the same rule the config seed follows');

      // The button is the opposite instruction and brings it back.
      expect(planRoutingFromConfig(p).newNodes.map((n) => n.id),
          contains(avAutoNodeId('input_doc_cam')));
    });

    test('a receiver deleted by hand takes its two cables with it', () {
      final p = room(projectorInput: 'HDMI 1');
      autoDrawRoutingFromConfig(p);

      p.removeAvNode(avAutoNodeId('output_proj_1_rx'));
      autoDrawRoutingFromConfig(p);

      expect(p.avNodeById(avAutoNodeId('output_proj_1_rx')), isNull);
      // Half a run — the switcher cabled to nothing, or a direct DTP-to-HDMI
      // lead — would be worse than the gap it leaves.
      expect(runsFrom(p, 'SWITCHERDEVICE_1'), isEmpty);
    });

    test('a room with no diagram drawn yet is left alone', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..uiSchema = schema
        ..avDeviceLibrary = library;
      p.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{'input_pc': '1'};

      expect(autoDrawRoutingFromConfig(p).nodesAdded, 0);
      expect(p.avNodes, isEmpty,
          reason: 'a PC with nothing to plug into is not a drawing');
    });
  });

  group('and the estimate counts them', () {
    CostEstimate estimateFor(AppStateProvider p) => computeRoomCost(
          model: buildAvFlowModel(p),
          library: library,
          settings: RoomCostSettings(),
        );

    test('the doc cam the config names is on the quote', () {
      final p = room();
      expect(
        estimateFor(p).equipment.any((l) => l.model == 'Document Camera'),
        isFalse,
        reason: 'nothing has placed it yet',
      );

      autoDrawRoutingFromConfig(p);
      final line = estimateFor(p)
          .equipment
          .firstWhere((l) => l.model == 'Document Camera');
      expect(line.qty, 1);
      expect(line.unitPrice, greaterThan(0),
          reason: 'the catalog prices this one');
    });

    test('so is the receiver the run needs', () {
      final p = room(projectorInput: 'HDMI 1');
      autoDrawRoutingFromConfig(p);

      final line = estimateFor(p)
          .equipment
          .firstWhere((l) => l.model == 'DTP HDMI 4K 230 Rx');
      expect(line.qty, 1);
      expect(line.unitPrice, greaterThan(0));
    });

    test('the laptop at the plate is drawn but not quoted', () {
      final p = room();
      autoDrawRoutingFromConfig(p);

      // The plate and the lead are real and the box has to be on the diagram
      // for the cable to come from somewhere. Quoting somebody for their own
      // laptop is a different matter.
      expect(p.avNodeById(avAutoNodeId('input_hdmi'))?.excludeFromCost, isTrue);
      expect(
        estimateFor(p).equipment.any((l) => l.model == 'HDMI Laptop'),
        isFalse,
      );
    });
  });
}
