import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_report.dart';
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
  AppStateProvider room({
    String projectorInput = 'HDBaseT',
    String projectorModel = 'PowerLite L630U',
  }) {
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
      'model': projectorModel,
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
    ///
    /// Matched on the CONNECTOR's own name: the drawn outlet also carries the
    /// name this room gives it ('OUTLET 1 · PC'), and which box a lead reaches
    /// is not a question about what the outlet is called.
    String? outlet(AppStateProvider p, String label) {
      for (final c in p.avCables) {
        if (c.fromNodeId != 'POWERDEVICE_1') continue;
        final from = p.avNodeById(c.fromNodeId);
        if (basePortLabel(from?.portById(c.fromPortId)?.label ?? '') != label) {
          continue;
        }
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

    /// The outlet names are the room's wiring list read the other way — the
    /// box called PC is plugged into outlet 1 — and they are also what is
    /// printed on the touch panel's power page. The catalog knows a controller
    /// has eight outlets and nothing about which is which, so the drawing said
    /// 'OUTLET 3' and left the tech to go and look the name up.
    group('the outlet names', () {
      test('come onto the page with the controller', () {
        final p = room();
        autoDrawRoutingFromConfig(p);
        final apc = p.avNodeById('POWERDEVICE_1')!;

        expect(apc.portById('out_pwr_1')?.label, 'OUTLET 1 · PC');
        // The \\r in 'Doc\\rCam' breaks the touch panel button over two lines.
        // It is not part of what the outlet is called.
        expect(apc.portById('out_pwr_6')?.label, 'OUTLET 6 · Doc Cam');
        // An outlet the room never named keeps the catalog's own name rather
        // than growing an empty note.
        expect(apc.portById('out_pwr_3')?.label, 'OUTLET 3');
      });

      test('never change which socket a lead resolves to', () {
        // Every port lookup reads the connector's number off its label. A
        // named outlet that stopped parsing would quietly unplug the room.
        expect(parsePortLabel('OUTLET 3 · Via').number, 3);
        expect(parsePortLabel('OUTLET 3 · Via').letter, '');
        expect(basePortLabel('OUTLET 3 · Via'), 'OUTLET 3');
        expect(portLabelNote('OUTLET 3 · Via'), 'Via');
        expect(portLabelNote('OUTLET 3'), '');
      });

      test('follow the config onto a drawing already made', () {
        final p = room();
        autoDrawRoutingFromConfig(p);
        (p.roomConfig['SYSTEM_SETUP'] as Map)['power1_outlet_1'] = 'Room\\rPC';
        autoDrawRoutingFromConfig(p);

        expect(p.avNodeById('POWERDEVICE_1')!.portById('out_pwr_1')?.label,
            'OUTLET 1 · Room PC');
      });

      test('a spare outlet is spare, not called None', () {
        final p = room();
        (p.roomConfig['SYSTEM_SETUP'] as Map)['power1_outlet_4'] = 'None';
        autoDrawRoutingFromConfig(p);

        expect(p.avNodeById('POWERDEVICE_1')!.portById('out_pwr_4')?.label,
            'OUTLET 4');
      });

      test('reach the power schedule, which is where the tech reads them', () {
        final p = room();
        autoDrawRoutingFromConfig(p);

        final schedule = powerSections(buildAvFlowModel(p))
            .firstWhere((s) => s.title == 'Power Schedule');
        final pc = schedule.rows
            .firstWhere((r) => r.first.toString() == 'Room PC');
        expect(pc.last.toString(), 'OUTLET 1 · PC');
      });

      test('are left alone on anything that is not a controller', () {
        final p = room();
        final switcher = p.avNodeById('SWITCHERDEVICE_1')!;
        expect(
          withOutletNames(switcher.ports, switcher.id, p.roomConfig)
              .map((x) => x.label),
          switcher.ports.map((x) => x.label),
        );
      });
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
    test('a DTP output to a display that takes twisted pair skips the box',
        () {
      // The projector's config says HDMI 1, but it has an HDBaseT socket and
      // the matrix output is twisted pair — so the pair goes into that socket
      // and no receiver is bought. The declared input records which connector
      // somebody plugged into; a room wired like this has an answer already.
      final p = room(projectorInput: 'HDMI 1');
      autoDrawRoutingFromConfig(p);

      expect(
        runsFrom(p, 'SWITCHERDEVICE_1'),
        contains('DTP OUT 003B -> Projector - PowerLite L630U (HDBaseT)'),
      );
      expect(p.avNodeById(avAutoNodeId('output_proj_1_rx')), isNull);
    });

    test('a display the catalog does not know still gets its receiver', () {
      // Displays 3 and 4 of a room are flat panels, and a panel model the
      // catalog has never heard of falls back to the generic PROJECTORDEVICE
      // template — which hands every display an HDMI 1, an HDMI 2 and an
      // HDBaseT socket. That last one is a guess, and it was enough to make
      // the pass run twisted pair straight into a connector the panel does not
      // have, with the receiver the room actually needs left off the drawing
      // and off the quote.
      //
      // A socket nobody has confirmed does not settle the question: the
      // receiver goes in, and the room-end lead lands on the input the config
      // DOES name.
      final p = room(
        projectorInput: 'HDMI 1',
        projectorModel: 'Some Panel The Catalog Has Never Seen 75',
      );
      autoDrawRoutingFromConfig(p);

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
    });

    test('a config that names the HDBaseT socket is still taken at its word',
        () {
      // The other half of the same rule. An unknown model whose config says
      // the lead goes into HDBaseT is a room somebody has looked at: the
      // socket is named, so it exists, and no receiver is bought.
      final p = room(
        projectorInput: 'HDBaseT',
        projectorModel: 'Some Panel The Catalog Has Never Seen 75',
      );
      autoDrawRoutingFromConfig(p);

      expect(p.avNodeById(avAutoNodeId('output_proj_1_rx')), isNull);
      expect(
        runsFrom(p, 'SWITCHERDEVICE_1'),
        contains('DTP OUT 003B -> Projector - PowerLite L630U (HDBaseT)'),
      );
    });

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
      final p = room(projectorInput: 'HDMI 1', projectorModel: 'TT-7523Q');
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
      final p = room(projectorInput: 'HDMI 1', projectorModel: 'TT-7523Q');
      p.setAvNodePosition('PROJECTORDEVICE_1', const Offset(1200, 300));
      autoDrawRoutingFromConfig(p);

      final rx = p.avNodeById(avAutoNodeId('output_proj_1_rx'))!;
      expect(rx.pos.dx, lessThan(1200));
      expect(rx.pos.dy, 300);
    });

    test('a receiver already on the diagram is used, not duplicated', () {
      final p = room(projectorInput: 'HDMI 1', projectorModel: 'TT-7523Q');

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
      final p = room(projectorInput: 'HDMI 1', projectorModel: 'TT-7523Q');
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
              'helpful - the same rule the config seed follows');

      // The button is the opposite instruction and brings it back.
      expect(planRoutingFromConfig(p).newNodes.map((n) => n.id),
          contains(avAutoNodeId('input_doc_cam')));
    });

    test('a receiver deleted by hand takes its two cables with it', () {
      final p = room(projectorInput: 'HDMI 1', projectorModel: 'TT-7523Q');
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

  group('two ties onto one box', () {
    /// The same room with a recorder and both capture feeds configured.
    AppStateProvider withRecorder(String model) {
      final p = room();
      final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
      setup['dev_recorders'] = '1';
      setup['output_cc'] = '1';
      setup['output_cc2'] = '2';
      p.roomConfig['RECORDERDEVICE_1'] = <String, dynamic>{
        'name': 'Recorder - $model',
        'model': model,
        'com_type': 'Network',
      };
      final template =
          p.avDeviceLibrary.resolve(configKey: 'RECORDERDEVICE_1', model: model);
      p.addAvNode(AvNode(
        id: 'RECORDERDEVICE_1',
        label: 'Recorder - $model',
        model: model,
        pos: Offset.zero,
        ports: withPowerInlet(template.ports, template.powerInput),
        fromConfig: true,
      ));
      return p;
    }

    /// Where the capture feeds land on the recorder.
    List<String> captureInputs(AppStateProvider p) => [
          for (final c in p.avCables)
            if (c.toNodeId == 'RECORDERDEVICE_1')
              p.avNodeById(c.toNodeId)!.portById(c.toPortId)!.label,
        ];

    test('take a connector each', () {
      // THE BUG: both ties took the box's FIRST matching connector, so
      // output_cc and output_cc2 came out as two leads from the DTP
      // CrossPoint drawn onto HDMI IN 1 — a socket that takes one lead.
      final p = withRecorder('AV Bridge 2x1');
      autoDrawRoutingFromConfig(p);
      expect(captureInputs(p), ['HDMI IN 1', 'HDMI IN 2']);
    });

    test('and a box with only one says so rather than doubling up', () {
      // The older AV Bridge has a single HDMI input. Nothing is drawn for the
      // second feed, and the report says why.
      final p = withRecorder('AV Bridge');
      autoDrawRoutingFromConfig(p);
      expect(captureInputs(p), ['HDMI IN']);
      expect(
        planRoutingFromConfig(p)
            .unresolved
            .where((u) => u.configKey == 'output_cc2')
            .single
            .reason,
        contains('already fed'),
      );
    });

    test('an SMP takes both feeds, the way an AV Bridge 2x1 does', () {
      // A lecture capture is the presenter AND the content, which is what the
      // recorder's two inputs are for. The SMP is a catalog model rather than
      // the untyped fallback, so it had to carry two of them itself.
      final p = withRecorder('SMP 351');
      autoDrawRoutingFromConfig(p);
      expect(captureInputs(p), ['HDMI IN 1', 'HDMI IN 2']);
      expect(
        planRoutingFromConfig(p)
            .unresolved
            .where((u) => u.configKey.startsWith('output_cc')),
        isEmpty,
        reason: 'both capture feeds should have landed',
      );
    });

    test('a second pass leaves both where they are', () {
      final p = withRecorder('AV Bridge 2x1');
      autoDrawRoutingFromConfig(p);
      // Even forced past the fingerprint, the plan has to recognize its own
      // cables rather than walk along the box's inputs drawing a fresh lead.
      p.avRoutedFingerprint = '';
      autoDrawRoutingFromConfig(p);
      expect(captureInputs(p), ['HDMI IN 1', 'HDMI IN 2']);
    });
  });

  group('the program audio', () {
    /// The same room with a DSP racked beside the matrix, and an assisted
    /// listening tie.
    AppStateProvider withDsp({String ald = '4'}) {
      final p = room();
      final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
      setup['dev_dsps'] = '1';
      setup['output_audio'] = '1';
      setup['output_audio_ald'] = ald;
      p.roomConfig['DSPDEVICE_1'] = <String, dynamic>{
        'name': 'DSP - Extron DMP 64 Plus C AT',
        'model': 'DMP 64 Plus C AT',
        'com_type': 'Network',
      };
      final template = p.avDeviceLibrary
          .resolve(configKey: 'DSPDEVICE_1', model: 'DMP 64 Plus C AT');
      p.addAvNode(AvNode(
        id: 'DSPDEVICE_1',
        label: 'DSP - Extron DMP 64 Plus C AT',
        model: 'DMP 64 Plus C AT',
        pos: Offset.zero,
        ports: withPowerInlet(template.ports, template.powerInput),
        fromConfig: true,
      ));
      return p;
    }

    /// The connectors a cable between the switcher and the DSP joins.
    List<String> switcherToDsp(AppStateProvider p) => [
          for (final c in p.avCables)
            if (c.fromNodeId == 'SWITCHERDEVICE_1' &&
                c.toNodeId == 'DSPDEVICE_1')
              '${p.avNodeById(c.fromNodeId)!.portById(c.fromPortId)!.label}'
                  ' -> '
                  '${p.avNodeById(c.toNodeId)!.portById(c.toPortId)!.label}',
        ];

    test('stays on the expansion bus, with no analog lead invented', () {
      // `output_audio` is the number of the LINK on the switcher side, not a
      // discrete output somebody runs a lead from. Drawing one put a cable
      // into the DSP's own expansion port — a connector nobody patches — and
      // quoted a run that does not exist.
      final p = withDsp();
      autoDrawRoutingFromConfig(p);
      expect(switcherToDsp(p), ['DMP EXP -> DMP EXP']);
    });

    test('a room with no DSP still feeds the ceiling', () {
      // The amplifier is inside the switcher on an SA or MA build, and there
      // the same key really is a run — speaker level, to the ceiling.
      final p = room();
      (p.roomConfig['SYSTEM_SETUP'] as Map)['output_audio'] = '1';
      autoDrawRoutingFromConfig(p);
      expect(p.avNodeById(avAutoNodeId('output_audio'))?.label,
          'Ceiling speakers');
    });

    test('speakers somebody re-modelled are still this room’s speakers', () {
      // THE BUG THIS EXISTS FOR. The box `output_audio` places is recognized
      // by its ID, not by its model — a room whose ceiling speakers were
      // changed to the SM 28 pair actually specified stopped matching
      // 'Ceiling Speakers', so the pass drew a SECOND set. It arrived under a
      // re-keyed id (addAvNode renames an id that is taken), which put it
      // outside the dismissal record as well: deleting it brought it back on
      // every pass, under a new id each time.
      final p = room();
      (p.roomConfig['SYSTEM_SETUP'] as Map)['output_audio'] = '1';
      autoDrawRoutingFromConfig(p);

      final speakers = p.avNodeById(avAutoNodeId('output_audio'));
      expect(speakers, isNotNull);
      p.updateAvNode(
        speakers!.copyWith(model: 'SM 28 Black', label: 'Speakers - SM 28'),
      );

      p.avRoutedFingerprint = ''; // force the pass to run again
      autoDrawRoutingFromConfig(p);

      expect(
        p.avNodes.where((n) => n.ports.any((port) =>
            port.signal == SignalType.speaker && port.isInput)),
        hasLength(1),
        reason: 'the SM 28s are the speakers; nothing else should be placed',
      );
      expect(p.avNodeById(avAutoNodeId('output_audio'))?.model, 'SM 28 Black');
    });

    test('speakers taken off the canvas stay off it', () {
      final p = room();
      (p.roomConfig['SYSTEM_SETUP'] as Map)['output_audio'] = '1';
      autoDrawRoutingFromConfig(p);
      expect(p.avNodeById(avAutoNodeId('output_audio')), isNotNull);

      p.removeAvNode(avAutoNodeId('output_audio'));
      p.avRoutedFingerprint = '';
      autoDrawRoutingFromConfig(p);

      expect(p.avNodeById(avAutoNodeId('output_audio')), isNull);
      expect(
        p.avNodes.where((n) => n.model == 'Ceiling Speakers'),
        isEmpty,
        reason: 'a box somebody deleted stays deleted',
      );
    });

    test('assisted listening is a box of its own, cabled and quoted', () {
      final p = withDsp();
      autoDrawRoutingFromConfig(p);

      final ald = p.avNodeById(avAutoNodeId('output_audio_ald'));
      expect(ald, isNotNull);
      expect(ald!.model, 'Assisted Listening');
      // Its own tie off the matrix, landing on the box's audio input.
      final lead = p.avCables
          .firstWhere((c) => c.toNodeId == ald.id && c.signal != SignalType.power);
      expect(ald.portById(lead.toPortId)?.label, 'AUDIO IN');
      // And it is on the quote — a box the room is buying, not scenery.
      expect(ald.excludeFromCost, isFalse);
      expect(
        computeRoomCost(
          model: buildAvFlowModel(p),
          library: library,
          settings: RoomCostSettings(),
        ).equipment.any((l) => l.model == 'Assisted Listening'),
        isTrue,
      );
    });

    test('a room without one gets no assisted listening box', () {
      final p = withDsp(ald: '');
      autoDrawRoutingFromConfig(p);
      expect(p.avNodeById(avAutoNodeId('output_audio_ald')), isNull);
    });
  });

  group('the drawing stays put', () {
    // THE DIAGRAM IS A DOCUMENT. After the conversion has put the room on the
    // canvas, opening the tab again should show it as it was left. The pass
    // used to run on every visit, so a room nobody had touched could still be
    // redrawn under them — by a catalog revision moving a connector, or by
    // this file changing its mind about which socket a tie lands on.
    test('a second visit with nothing changed draws nothing', () {
      final p = room();
      final first = autoDrawRoutingFromConfig(p);
      expect(first.cablesDrawn, greaterThan(0));

      final before = p.avCables.length;
      final again = autoDrawRoutingFromConfig(p);
      expect(again, (nodesAdded: 0, cablesDrawn: 0, unresolved: 0));
      expect(p.avCables, hasLength(before));
    });

    test('a cable moved by hand is not moved back', () {
      final p = room();
      autoDrawRoutingFromConfig(p);

      // Somebody decides the PC belongs on input 2 of the matrix and drags
      // that end of the lead across. The config still says 1.
      final lead = p.avCables
          .firstWhere((c) => c.fromNodeId == avAutoNodeId('input_pc'));
      p.updateAvCable(lead.copyWith(toPortId: 'hdmi_2'));

      autoDrawRoutingFromConfig(p);
      expect(p.avCables.where((c) => c.id == lead.id).single.toPortId,
          'hdmi_2');
      expect(
          p.avCables
              .where((c) => c.fromNodeId == avAutoNodeId('input_pc')),
          hasLength(1),
          reason: 'and no second lead drawn to put it right');
    });

    test('editing the config lets the pass run again', () {
      final p = room();
      autoDrawRoutingFromConfig(p);
      final before = p.avCables.length;

      // A doc cam added to the config last week belongs on the drawing this
      // week — which is the case the repeat pass exists for.
      (p.roomConfig['SYSTEM_SETUP'] as Map)['input_dvd'] = '2';
      autoDrawRoutingFromConfig(p);

      expect(p.avNodeById(avAutoNodeId('input_dvd')), isNotNull);
      expect(p.avCables.length, greaterThan(before));
    });

    test('a device swapped for another model lets it run again too', () {
      final p = room();
      autoDrawRoutingFromConfig(p);
      final fingerprint = p.avRoutedFingerprint;
      expect(fingerprint, isNotEmpty);

      (p.roomConfig['PROJECTORDEVICE_1'] as Map)['model'] = 'TT-7523Q';
      expect(routingFingerprint(p), isNot(fingerprint));
    });
  });

  group('the USB switcher', () {
    /// The room, plus the two boxes that make its USB feed: the DSP with the
    /// microphone mix on its USB output, and the AV Bridge with the room's
    /// picture on its own.
    AppStateProvider conferenceRoom() {
      final p = room();
      void add(String key, String name, String model) {
        p.roomConfig[key] = <String, dynamic>{
          'name': name,
          'model': model,
          'com_type': 'Network',
        };
        final template =
            p.avDeviceLibrary.resolve(configKey: key, model: model);
        p.addAvNode(AvNode(
          id: key,
          label: name,
          model: model,
          pos: Offset.zero,
          ports: withPowerInlet(template.ports, template.powerInput),
          fromConfig: true,
        ));
      }

      add('DSPDEVICE_1', 'DSP - DMP 64 Plus C AT', 'DMP 64 Plus C AT');
      add('RECORDERDEVICE_1', 'Recorder - AV Bridge 2x1', 'AV Bridge 2x1');
      return p;
    }

    /// What is plugged into [label] on the Toggle.
    String? devicePort(AppStateProvider p, String label) {
      for (final c in p.avCables) {
        if (c.toNodeId != 'USBDEVICE_1') continue;
        if (p.avNodeById('USBDEVICE_1')?.portById(c.toPortId)?.label != label) {
          continue;
        }
        return p.avNodeById(c.fromNodeId)?.label;
      }
      return null;
    }

    test('the peripherals land on the DEVICE ports in build order', () {
      final p = conferenceRoom();
      autoDrawRoutingFromConfig(p);

      // Nothing in the config says any of this — there is no input_ number for
      // a USB lead — so the drawing showed a Toggle with nothing in it. This
      // is the order every one of these rooms is wired in.
      expect(devicePort(p, 'USB DEVICE 1'), 'DSP - DMP 64 Plus C AT');
      expect(devicePort(p, 'USB DEVICE 2'), 'Recorder - AV Bridge 2x1');
      expect(devicePort(p, 'USB DEVICE 3'), 'Document camera');
    });

    test('HOST 1 is the room PC', () {
      final p = conferenceRoom();
      autoDrawRoutingFromConfig(p);

      expect(runsFrom(p, 'USBDEVICE_1'),
          contains('USB HOST 1 -> Room PC (USB)'));
    });

    test('a room with no doc cam leaves DEVICE 3 empty', () {
      final p = conferenceRoom();
      (p.roomConfig['SYSTEM_SETUP'] as Map)['input_doc_cam'] = '';
      autoDrawRoutingFromConfig(p);

      // Fixed positions, not a queue: the AV Bridge stays on DEVICE 2 rather
      // than moving down onto the port the doc cam would have had.
      expect(devicePort(p, 'USB DEVICE 2'), 'Recorder - AV Bridge 2x1');
      expect(devicePort(p, 'USB DEVICE 3'), isNull);
    });

    test('a connector somebody has already used is left alone', () {
      final p = conferenceRoom();
      final bridge = p.avNodeById('RECORDERDEVICE_1')!;
      final bridgeUsb = bridge.ports
          .firstWhere((port) => port.signal == SignalType.usbData);
      p.addAvCable(
        fromNodeId: 'RECORDERDEVICE_1',
        fromPortId: bridgeUsb.id,
        toNodeId: 'USBDEVICE_1',
        toPortId: 'in_usb_3',
        signal: SignalType.usbData,
      );

      autoDrawRoutingFromConfig(p);

      // The AV Bridge has one USB socket and it is already in DEVICE 3. It is
      // not also drawn into DEVICE 2, and the doc cam does not land on top of
      // it.
      expect(devicePort(p, 'USB DEVICE 3'), 'Recorder - AV Bridge 2x1');
      expect(devicePort(p, 'USB DEVICE 2'), isNull);
      expect(
        p.avCables
            .where((c) =>
                c.fromNodeId == 'RECORDERDEVICE_1' &&
                c.fromPortId == bridgeUsb.id)
            .length,
        1,
      );
    });

    test('running twice draws the leads once', () {
      final p = conferenceRoom();
      autoDrawRoutingFromConfig(p);
      final drawn = p.avCables.length;

      // The pass is allowed to run again — a config edit is what un-sticks it
      // — and a second run must not double every USB lead.
      p.avRoutedFingerprint = '';
      autoDrawRoutingFromConfig(p);
      expect(p.avCables.length, drawn);
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
      final p = room(projectorInput: 'HDMI 1', projectorModel: 'TT-7523Q');
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
