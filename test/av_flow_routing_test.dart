import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_routing.dart';
import 'package:extron_configurator/ui_schema.dart';

/// The config states the room's wiring in switcher numbers — `input_pc` is 1,
/// `output_proj_1` is "3B", and the projector's own `input` is "HDBaseT" — and
/// until now not one of those reached the drawing. These cover the two halves
/// of turning them back into cables:
///
///   * resolving a number onto a real connector, which is hard because the
///     number is what is printed on the box and the catalog records names;
///   * the whole pass over a real room, checked against three configs from the
///     ControlScript template that between them use all three spellings a
///     value comes in ("1", "3B" and a bare "C").
void main() {
  // A switcher's connectors, as the catalog spells them for that model.
  Future<AvNode> switcherNode(String model) async {
    final library =
        await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
    final template = library.resolve(
      configKey: 'SWITCHERDEVICE_1',
      model: model,
    );
    return AvNode(
      id: 'SWITCHERDEVICE_1',
      label: 'Switcher - $model',
      model: model,
      pos: Offset.zero,
      ports: template.ports,
    );
  }

  group('reading a connector reference', () {
    test('a number, a number and a letter, or a letter on its own', () {
      expect(parseIoValue('1'), (number: 1, letter: ''));
      expect(parseIoValue('3B'), (number: 3, letter: 'B'));
      expect(parseIoValue(' 4b '), (number: 4, letter: 'B'));
      expect(parseIoValue('C'), (number: null, letter: 'C'));
      expect(parseIoValue(''), (number: null, letter: ''));
      expect(parseIoValue('None'), (number: null, letter: ''));
    });

    test('a port label reads the same way', () {
      expect(parsePortLabel('HDMI 003'), (number: 3, letter: ''));
      expect(parsePortLabel('DTP OUT 003B'), (number: 3, letter: 'B'));
      expect(parsePortLabel('HDMI IN 3'), (number: 3, letter: ''));
      expect(parsePortLabel('DTP OUT C'), (number: null, letter: 'C'));
      expect(parsePortLabel('AUDIO OUT'), (number: null, letter: ''));
      // The trap: a label ending in a word is not a label ending in a letter.
      expect(parsePortLabel('HDMI'), (number: null, letter: ''));
      expect(parsePortLabel('SPEAKER OUT'), (number: null, letter: ''));
    });
  });

  group('finding the input a number names', () {
    test('across the three ways Extron spells an input', () async {
      // Same input 3, three different catalog spellings.
      for (final (model, label) in const [
        ('DTP CrossPoint 84 4K IPCP MA 70', 'HDMI 3'),
        ('DTP CrossPoint 84 4K', 'HDMI 003'),
        ('IN1608 SA', 'HDMI IN 3'),
      ]) {
        final node = await switcherNode(model);
        final port = portForIoValue(node, '3', wantOutput: false);
        expect(port?.label, label, reason: model);
      }
    });

    test('a DTP input is found by its number like any other', () async {
      final ma70 = await switcherNode('DTP CrossPoint 84 4K IPCP MA 70');
      expect(portForIoValue(ma70, '7', wantOutput: false)?.label, 'DTP IN 7');

      final in1608 = await switcherNode('IN1608 SA');
      expect(portForIoValue(in1608, '8', wantOutput: false)?.label, 'DTP IN 8');
      // Input 1 on an IN1608 is a VGA connector, and that is the right answer:
      // an old room's laptop plate really is on it.
      expect(portForIoValue(in1608, '1', wantOutput: false)?.label, 'VGA IN 1');
    });
  });

  group('finding the output a number names', () {
    test('when the catalog spells out the connector letter', () async {
      final node = await switcherNode('DTP CrossPoint 84 4K IPCP MA 70');
      expect(
        portForIoValue(node, '3B', wantOutput: true, declaredOutputs: 4)?.label,
        'DTP OUT 003B',
      );
      expect(
        portForIoValue(node, '4B', wantOutput: true, declaredOutputs: 4)?.label,
        'DTP OUT 004B',
      );
    });

    /// The pass that earns its keep: this entry labels the 84's two DTP
    /// sockets "DTP OUT 1" and "DTP OUT 2" — a per-connector counter — so
    /// neither carries the number 3. The model number says the box has four
    /// outputs and Extron puts the DTP sockets on the last of them, which
    /// makes DTP OUT 1 output 3.
    test('when the catalog counts connectors instead of outputs', () async {
      final node = await switcherNode('DTP CrossPoint 84 4K');
      expect(
        portForIoValue(node, '3B', wantOutput: true, declaredOutputs: 4)?.label,
        'DTP OUT 1',
      );
      expect(
        portForIoValue(node, '4B', wantOutput: true, declaredOutputs: 4)?.label,
        'DTP OUT 2',
      );
      // ... and it must NOT quietly fall back to the HDMI socket with that
      // number, which is a different cable to a different box.
      expect(
        portForIoValue(node, '3B', wantOutput: true, declaredOutputs: 0),
        isNull,
        reason: 'without the output count there is nothing to infer from',
      );
    });

    test('the 108, whose last four outputs carry the DTP connectors', () async {
      final node = await switcherNode('DTP CrossPoint 108 4K IPCP MA 70');
      // 8 outputs, 10 connectors: 1-4 are HDMI only, 5 and 6 carry both an
      // HDMI (A) and a DTP (B) socket, 7 and 8 are DTP only. The catalog
      // entry used to number its connectors within each signal instead
      // ('HDMI 1'..'HDMI 6', 'DTP OUT 1'..'DTP OUT 4'), which lost the
      // correspondence to the output numbers the config states — and made
      // '3B' resolve onto nothing while looking like an app bug rather than
      // what it is: output 3 of a 108 has no DTP connector.
      expect(
        portForIoValue(node, '5B', wantOutput: true, declaredOutputs: 8)?.label,
        'DTP OUT 005B',
      );
      expect(
        portForIoValue(node, '8B', wantOutput: true, declaredOutputs: 8)?.label,
        'DTP OUT 008',
      );
      // The bare number of a DTP-only output names it too — there is no other
      // connector on output 8 to mean.
      expect(
        portForIoValue(node, '8', wantOutput: true, declaredOutputs: 8)?.label,
        'DTP OUT 008',
      );
      // And output 5's bare number is its HDMI socket, the way '5B' is its
      // twisted-pair one.
      expect(
        portForIoValue(node, '5', wantOutput: true, declaredOutputs: 8)?.label,
        'HDMI 005A',
      );
      // Output 3 has no DTP connector, and saying so is the right answer.
      expect(
        portForIoValue(node, '3B', wantOutput: true, declaredOutputs: 8),
        isNull,
      );
    });

    test('a bare letter, which is how an IN1608 names its outputs', () async {
      final node = await switcherNode('IN1608 SA');
      expect(portForIoValue(node, 'C', wantOutput: true)?.label, 'DTP OUT C');
      expect(portForIoValue(node, 'A', wantOutput: true)?.label, 'HDMI OUT A');
    });

    test('a value that names nothing on this box resolves to nothing', () async {
      final node = await switcherNode('DTP CrossPoint 84 4K IPCP MA 70');
      expect(portForIoValue(node, '9B', wantOutput: true, declaredOutputs: 4),
          isNull);
    });
  });

  group('finding the socket a display says the lead goes into', () {
    Future<AvNode> displayNode(String model) async {
      final library =
          await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
      final template =
          library.resolve(configKey: 'PROJECTORDEVICE_1', model: model);
      return AvNode(
        id: 'PROJECTORDEVICE_1',
        label: 'Projector - $model',
        model: model,
        pos: Offset.zero,
        ports: template.ports,
      );
    }

    test('by name, however it is punctuated', () async {
      final node = await displayNode('PowerLite L630U');
      expect(portForDeviceInput(node, 'HDBaseT')?.label, 'HDBaseT');
      expect(portForDeviceInput(node, 'HDBASE-T')?.label, 'HDBaseT');
      expect(portForDeviceInput(node, 'HDMI 1')?.label, 'HDMI 1');
      expect(portForDeviceInput(node, 'HDMI 2')?.label, 'HDMI 2');
    });

    test('a name the display does not have resolves to nothing', () async {
      final node = await displayNode('PowerLite L630U');
      expect(portForDeviceInput(node, 'Digital Link'), isNull);
      expect(portForDeviceInput(node, ''), isNull);
    });
  });

  // -------------------------------------------------------------------------
  //  THE WHOLE PASS, ON REAL ROOMS
  // -------------------------------------------------------------------------

  /// A room with its devices placed, which is the state the AV flow tab is in
  /// after "Place all from config".
  Future<AppStateProvider> roomOf(Map<String, dynamic> config) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = await UiSchema.load(explicitPath: 'ui_schema.json')
      ..avDeviceLibrary =
          await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
    p.roomConfig
      ..clear()
      ..addAll(config);

    for (final key
        in activeDeviceKeysIn(p.roomConfig, p.uiSchema.deviceCountMap)) {
      final dev = p.roomConfig[key];
      if (dev is! Map) continue;
      final model = dev['model']?.toString() ?? '';
      final template =
          p.avDeviceLibrary.resolve(configKey: key, model: model);
      p.addAvNode(AvNode(
        id: key,
        label: dev['name']?.toString() ?? key,
        model: model,
        pos: Offset.zero,
        ports: withPowerInlet(template.ports, template.powerInput),
        fromConfig: true,
      ));
    }
    return p;
  }

  /// The same, read off a real ControlScript config. Null when the template
  /// repo is not checked out beside this one.
  Future<AppStateProvider?> roomFrom(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    return roomOf(Map<String, dynamic>.from(
        jsonDecode(file.readAsStringSync()) as Map));
  }

  /// The cable a config key produced, as "port -> port".
  String? tie(RoutingPlan plan, String key) {
    for (final c in plan.cables) {
      if (c.configKey == key) return '${c.fromPortLabel} -> ${c.toPortLabel}';
    }
    return null;
  }

  /// Every cable a key produced, in the order they run. One key is not always
  /// one cable: a DTP output feeding a display on HDMI is two, with the
  /// receiver between them.
  List<String> ties(RoutingPlan plan, String key) => [
        for (final c in plan.cables)
          if (c.configKey == key) '${c.fromPortLabel} -> ${c.toPortLabel}',
      ];

  /// The mains lead an outlet key produced, as "outlet -> box".
  String? power(RoutingPlan plan, String key) {
    for (final c in plan.cables) {
      if (c.configKey == key) return '${c.fromPortLabel} -> ${c.toLabel}';
    }
    return null;
  }

  const template = 'C:/GitHub/ControlScript-Template/rooms';

  test('BSS 239 - the current standard hyflex build', () async {
    final p = await roomFrom('$template/BSS239/code/upload_to_root/config.json');
    if (p == null) return; // the template repo is not beside this one
    final plan = planRoutingFromConfig(p);

    // Sources: each one onto the input its number names.
    expect(tie(plan, 'input_pc'), 'HDMI OUT -> HDMI 1');
    expect(tie(plan, 'input_wireless'), 'HDMI OUT -> HDMI 3');
    expect(tie(plan, 'input_hdmi'), 'HDMI OUT -> HDMI 4');
    expect(tie(plan, 'input_usb'), 'USB-C OUT -> HDMI 5');
    expect(tie(plan, 'input_doc_cam'), 'HDMI OUT -> HDMI 6');
    // The cameras are on DTP inputs and a camera has an HDMI socket and
    // nothing else, so each of those two runs is a transmitter and two leads.
    expect(ties(plan, 'input_aud_cam'),
        ['HDMI OUT -> HDMI', 'DTP -> DTP IN 7']);
    expect(ties(plan, 'input_inst_cam'),
        ['HDMI OUT -> HDMI', 'DTP -> DTP IN 8']);
    expect(
      plan.newNodes.where((n) => n.model == 'DTP HDMI 4K 230 Tx'),
      hasLength(2),
      reason: 'one per camera, not one shared between them',
    );

    // The output the question was about: 3B on the matrix, HDBaseT at the
    // projector, and the cable joins exactly those two.
    expect(tie(plan, 'output_proj_1'), 'DTP OUT 003B -> HDBaseT');

    // The APC's outlet names are a wiring list nobody had drawn: outlet 1 is
    // 'PC', and the PC is the box the room's own sources list put on input 1.
    expect(power(plan, 'power1_outlet_1'), 'OUTLET 1 -> Room PC');
    // 'Switch' in a room built out of Extron gear is the matrix. Scored on
    // the label alone it tied with the USB switcher and nothing was drawn.
    expect(power(plan, 'power1_outlet_2'),
        'OUTLET 2 -> Switcher - DTP CrossPoint 84 4K IPCP MA 70');
    expect(power(plan, 'power1_outlet_3'), 'OUTLET 3 -> Wireless - Via Go2');
    expect(power(plan, 'power1_outlet_6'),
        'OUTLET 6 -> DSP - Extron DMP 64 Plus C AT');
    // The outlet 8 label carries the touch panel's line break, and
    // stripping it is what makes its two words readable as two words.
    expect(power(plan, 'power1_outlet_8'),
        'OUTLET 8 -> USB Switcher - Inogeni Toggle');

    // The program audio stays on the expansion bus. `output_audio` is the
    // number of that link on the switcher side, not a discrete analog output
    // — so the one cable drawn is DMP EXP to DMP EXP, and no lead is run into
    // a MIC/LINE input that nobody patches.
    expect(tie(plan, 'output_audio'), 'DMP EXP -> DMP EXP');
    expect(
      plan.cables.where((c) => c.fromPortLabel.startsWith('AUDIO')),
      isEmpty,
    );

    // One finding, and it is a real fact about the config rather than a
    // failure to resolve: the recorder is the older one-input AV Bridge while
    // the config asks for two capture feeds. output_cc takes the one HDMI
    // input and output_cc2 has nowhere to go, which is worth saying rather
    // than drawing a second lead onto a socket that already has one.
    //
    // This room also used to carry a leftover output_proj_2 with one
    // projector on the drawing, which the pass reports rather than draws.
    // The key was cleaned out of the template's config on 2026-08-19, so that
    // case is pinned in 'a display output for a display the room has not got'
    // below — on a config this test owns, where nobody can tidy it away.
    expect(plan.unresolved.map((u) => u.configKey), ['output_cc2']);
    expect(plan.unresolved.single.reason, contains('already fed'));
    expect(tie(plan, 'output_cc'), 'HDMI 001 -> HDMI IN');
  });

  /// Dead config left behind when a room shrank: the second projector is
  /// gone, its output number is not, and to everyone reading the file it
  /// still looks like a second projector. The pass says so instead of drawing
  /// a cable to a box that is not there or silently dropping the key.
  test('a display output for a display the room has not got', () async {
    final p = await roomOf({
      'SYSTEM_SETUP': {
        'dev_projectors': '1',
        'dev_switchers': '1',
        'output_proj_1': '3B',
        'output_proj_2': '4B',
      },
      'SWITCHERDEVICE_1': {
        'model': 'DTP CrossPoint 84 4K IPCP MA 70',
        'name': 'Switcher - DTP CrossPoint 84 4K IPCP MA 70',
      },
      'PROJECTORDEVICE_1': {
        'model': 'PowerLite L630U',
        'name': 'Projector 1 - PowerLite L630U',
        'input': 'HDBaseT',
      },
    });
    final plan = planRoutingFromConfig(p);

    // The projector the room HAS is cabled normally.
    expect(tie(plan, 'output_proj_1'), 'DTP OUT 003B -> HDBaseT');

    final left = plan.unresolved.singleWhere(
        (u) => u.configKey == 'output_proj_2');
    expect(left.value, '4B');
    expect(left.reason, contains('1 display'));
    expect(left.reason, contains('dev_projectors'));
    // Not drawn — that is the whole point of reporting it.
    expect(tie(plan, 'output_proj_2'), isNull);
  });

  test('BSS 122 - the catalog counts connectors on this one', () async {
    final p = await roomFrom('$template/BSS122/code/upload_to_root/config.json');
    if (p == null) return;
    final plan = planRoutingFromConfig(p);

    expect(tie(plan, 'input_pc'), 'HDMI OUT -> HDMI 001');
    expect(tie(plan, 'input_wireless'), 'HDMI OUT -> HDMI 003');
    expect(tie(plan, 'input_usb'), 'USB-C OUT -> HDMI 005');
    // The HDMI plate and the camera are both on DTP inputs here.
    expect(ties(plan, 'input_hdmi'), ['HDMI OUT -> HDMI', 'DTP -> DTP IN 007']);
    expect(ties(plan, 'input_inst_cam'),
        ['HDMI OUT -> HDMI', 'DTP -> DTP IN 008']);

    // Both projectors say 'HDMI 1' and the matrix outputs are DTP. Both
    // PowerLites have an HDBaseT socket, so the pair goes into that and no
    // receiver is bought: the declared input records which connector somebody
    // plugged into, and a room wired like this already has the answer. The
    // matrix outputs are the inferred ones: DTP OUT 1 is output 3.
    expect(ties(plan, 'output_proj_1'), ['DTP OUT 1 -> HDBaseT']);
    expect(ties(plan, 'output_proj_2'), ['DTP OUT 2 -> HDBaseT']);

    // And nothing was invented to get there.
    expect(plan.newNodes.where((n) => n.model == 'DTP HDMI 4K 230 Rx'),
        isEmpty);
  });

  test('AJH 125A - an IN1608, whose outputs are lettered', () async {
    final p =
        await roomFrom('$template/AJH125A/code/upload_to_root/config.json');
    if (p == null) return;
    final plan = planRoutingFromConfig(p);

    expect(tie(plan, 'input_usb'), isNotNull);
    expect(tie(plan, 'input_pc'), 'HDMI OUT -> HDMI IN 3');
    expect(tie(plan, 'input_hdmi'), 'HDMI OUT -> HDMI IN 4');
    expect(tie(plan, 'input_doc_cam'), 'HDMI OUT -> HDMI IN 5');
    expect(ties(plan, 'input_inst_cam'),
        ['HDMI OUT -> HDMI', 'DTP -> DTP IN 7']);

    // output_proj_1 is the bare letter 'C'.
    expect(tie(plan, 'output_proj_1'), startsWith('DTP OUT C -> '));

    // The room has no wireless and no second camera, and says so with blanks —
    // a blank is not an unresolved tie.
    expect(plan.unresolved.map((u) => u.configKey),
        isNot(contains('input_wireless')));
  });

  test('a second pass draws nothing twice', () async {
    final p = await roomFrom('$template/BSS239/code/upload_to_root/config.json');
    if (p == null) return;

    final first = planRoutingFromConfig(p);
    expect(first.cables, isNotEmpty);
    applyRoutingFromConfig(p, first);

    final second = planRoutingFromConfig(p);
    expect(second.cables, isEmpty,
        reason: 'every tie was drawn on the first pass');
    expect(second.newNodes, isEmpty,
        reason: 'the sources it created the first time are still there');
    expect(second.alreadyDrawn, first.cables.length);
  });

  test('a room with no switcher on the canvas says so', () async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = await UiSchema.load(explicitPath: 'ui_schema.json')
      ..avDeviceLibrary =
          await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
    p.roomConfig['SYSTEM_SETUP'] = {'input_pc': '1'};

    final plan = planRoutingFromConfig(p);
    expect(plan.isEmpty, isTrue);
    expect(plan.unresolved, hasLength(1));
    expect(plan.unresolved.first.reason, contains('SWITCHERDEVICE_1'));
  });
}
