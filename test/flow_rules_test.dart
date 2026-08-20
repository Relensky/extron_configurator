import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_routing.dart';
import 'package:extron_configurator/flow_rules.dart';
import 'package:extron_configurator/flow_rules_view.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  THE RULE BOOK
/// ============================================================================
///  The routing pass used to carry its decisions as constants: input_pc is a
///  PC, a twisted-pair output reaching an HDMI display needs a DTP 230
///  receiver, the Toggle's DEVICE ports carry the DSP, the AV Bridge and the
///  doc cam in that order. Every one of those is a fact about how this shop
///  builds rooms, and every one of them was a code change away from being
///  wrong for the next room.
///
///  Two things are checked here. That the built-in rules ARE the old
///  constants, so a room with no rule file draws exactly as it always did —
///  the auto-draw and routing suites are the rest of that proof. And that
///  editing a rule actually changes the drawing, which is the entire point.
/// ============================================================================
void main() {
  late UiSchema schema;
  late AvDeviceLibrary library;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
    library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
  });

  /// A hyflex room: a matrix, a projector on a DTP output, a PC, a doc cam,
  /// the DSP and AV Bridge that make the USB feed, and the Toggle they land
  /// on.
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..avDeviceLibrary = library;

    p.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{
      'dev_projectors': '1',
      'dev_switchers': '1',
      'dev_dsps': '1',
      'dev_recorders': '1',
      'dev_usb_switchers': '1',
      'input_pc': '1',
      'input_doc_cam': '6',
      'output_proj_1': '3B',
    };
    void device(String key, String name, String model, [String? input]) {
      p.roomConfig[key] = <String, dynamic>{
        'name': name,
        'model': model,
        'input': ?input,
        'com_type': 'Network',
      };
      final template = p.avDeviceLibrary.resolve(configKey: key, model: model);
      p.addAvNode(AvNode(
        id: key,
        label: name,
        model: model,
        pos: Offset.zero,
        ports: withPowerInlet(template.ports, template.powerInput),
        fromConfig: true,
      ));
    }

    device('SWITCHERDEVICE_1', 'Switcher - DTP CrossPoint 84 4K IPCP MA 70',
        'DTP CrossPoint 84 4K IPCP MA 70');
    device('PROJECTORDEVICE_1', 'Projector - TT-7523Q', 'TT-7523Q', 'HDMI 1');
    device('DSPDEVICE_1', 'DSP - DMP 64 Plus C AT', 'DMP 64 Plus C AT');
    device('RECORDERDEVICE_1', 'Recorder - AV Bridge 2x1', 'AV Bridge 2x1');
    device('USBDEVICE_1', 'USB Switcher - Toggle', 'Toggle');
    return p;
  }

  /// What is plugged into one connector of the Toggle.
  String? onTogglePort(AppStateProvider p, String label) {
    for (final c in p.avCables) {
      final toggle = p.avNodeById('USBDEVICE_1');
      if (c.toNodeId == 'USBDEVICE_1' &&
          toggle?.portById(c.toPortId)?.label == label) {
        return p.avNodeById(c.fromNodeId)?.label;
      }
      if (c.fromNodeId == 'USBDEVICE_1' &&
          toggle?.portById(c.fromPortId)?.label == label) {
        return p.avNodeById(c.toNodeId)?.label;
      }
    }
    return null;
  }

  group('the document', () {
    test('survives a round trip through JSON', () {
      final rules = FlowRules.builtIn();
      final again = FlowRules.fromJson(
          jsonDecode(jsonEncode(rules.toJson())) as Map<String, dynamic>);

      expect(again.sourceBoxes.map((r) => r.configKey),
          rules.sourceBoxes.map((r) => r.configKey));
      expect(again.sourceBoxFor('input_hdmi')!.excludeFromCost, isTrue);
      expect(again.destinationBoxFor('output_audio_ald')!.signals, 'lineAudio');
      expect(again.extenders.map((r) => r.model),
          rules.extenders.map((r) => r.model));
      expect(again.usbSwitchers.single.devicePorts,
          rules.usbSwitchers.single.devicePorts);
      expect(again.outletAliases, rules.outletAliases);
      expect(again.expansionKeywords, rules.expansionKeywords);
    });

    test('a family the file leaves out keeps its built-in rules', () {
      final rules = FlowRules.fromJson({
        'extenders': {
          'rx': {
            'switcherSignal': 'hdbaset',
            'farSignal': 'hdmi',
            'onOutput': true,
            'model': 'DTP2 R 211',
            'label': 'Room-end receiver',
          },
        },
      });

      // Stated: replaced outright, both directions of it.
      expect(rules.extenders, hasLength(1));
      expect(rules.extenders.single.model, 'DTP2 R 211');
      // Unstated: exactly as shipped.
      expect(rules.sourceBoxFor('input_pc')?.model, 'PC');
      expect(rules.usbSwitchers.single.devicePorts.first, 'DSPDEVICE_');
    });

    test('reads and writes a file, and falls back when there is none',
        () async {
      final dir = Directory.systemTemp.createTempSync('flow_rules_test_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final file = path.join(dir.path, 'av_flow_rules.json');

      // Nothing there yet: the built-ins, and not an error.
      final missing = await FlowRules.load(explicitPath: file);
      expect(missing.source, 'Built-in defaults');

      final edited = FlowRules.builtIn().copyWith(
        outletAliases: {'switch': 'SWITCHERDEVICE_', 'brain': 'PROCESSOR'},
      );
      expect(await edited.save(file), file);

      final reopened = await FlowRules.load(explicitPath: file);
      expect(reopened.outletAliases['brain'], 'PROCESSOR');
      expect(reopened.source, file);
    });

    test('a file that is not readable leaves the room drawable', () async {
      final dir = Directory.systemTemp.createTempSync('flow_rules_bad_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final file = path.join(dir.path, 'av_flow_rules.json');
      File(file).writeAsStringSync('{ this is not json');

      final rules = await FlowRules.load(explicitPath: file);
      expect(rules.sourceBoxFor('input_pc')?.model, 'PC',
          reason: 'a broken rule file is not a reason to draw nothing');
      expect(rules.source, contains('Built-in defaults'));
    });
  });

  group('editing a rule changes the drawing', () {
    test('a different receiver model is the box that gets placed', () {
      final p = room();
      p.applyFlowRules(p.flowRules.copyWith(extenders: [
        for (final r in p.flowRules.extenders)
          if (r.onOutput)
            r.copyWith(model: 'DTP HDMI 4K 330 Rx', label: 'Long-run receiver')
          else
            r,
      ]));

      autoDrawRoutingFromConfig(p);

      final rx = p.avNodeById(avAutoNodeId('output_proj_1_rx'));
      expect(rx, isNotNull, reason: 'the run still needs a box between it');
      expect(rx!.model, 'DTP HDMI 4K 330 Rx');
      expect(rx.label, contains('Long-run receiver'));
    });

    test('no receiver rule at all leaves the run unresolved rather than '
        'drawing a cable that cannot exist', () {
      final p = room();
      p.applyFlowRules(p.flowRules.copyWith(extenders: const []));

      final plan = planRoutingFromConfig(p);

      // Without a rule the two ends are joined directly — which is the old
      // bug, so this is the check that a shop removing the rule is choosing
      // that, rather than getting it by accident.
      expect(p.avNodeById(avAutoNodeId('output_proj_1_rx')), isNull);
      expect(
        plan.cables.where((c) => c.configKey == 'output_proj_1'),
        hasLength(1),
      );
    });

    test('the USB order is the rule, port for port', () {
      final p = room();
      autoDrawRoutingFromConfig(p);
      expect(onTogglePort(p, 'USB DEVICE 2'), 'Recorder - AV Bridge 2x1');
      expect(onTogglePort(p, 'USB DEVICE 3'), 'Document camera');

      // A room wired the other way round says so, and the drawing follows.
      final swapped = p.flowRules.copyWith(usbSwitchers: [
        p.flowRules.usbSwitchers.single.copyWith(devicePorts: const [
          'DSPDEVICE_',
          'input_doc_cam',
          'RECORDERDEVICE_|MEDIAPORTDEVICE_',
        ]),
      ]);
      final fresh = room()..applyFlowRules(swapped);
      autoDrawRoutingFromConfig(fresh);

      expect(onTogglePort(fresh, 'USB DEVICE 2'), 'Document camera');
      expect(onTogglePort(fresh, 'USB DEVICE 3'), 'Recorder - AV Bridge 2x1');
    });

    test('a new source box rule places and cables a box nobody coded for', () {
      final p = room();
      (p.roomConfig['SYSTEM_SETUP'] as Map)['input_cable_box'] = '2';
      p.applyFlowRules(p.flowRules.copyWith(sourceBoxes: [
        ...p.flowRules.sourceBoxes,
        const FlowBoxRule(
          configKey: 'input_cable_box',
          label: 'Cable TV box',
          model: 'Blu-ray Player',
          zone: 'rack',
        ),
      ]));

      autoDrawRoutingFromConfig(p);

      final node = p.avNodeById(avAutoNodeId('input_cable_box'));
      expect(node, isNotNull);
      expect(node!.label, 'Cable TV box');
      expect(
        p.avCables.any((c) =>
            c.fromNodeId == node.id && c.toNodeId == 'SWITCHERDEVICE_1'),
        isTrue,
        reason: 'input_cable_box: 2 is a lead into input 2',
      );
    });

    test('a source rule removed stops drawing that box', () {
      final p = room();
      p.applyFlowRules(p.flowRules.copyWith(sourceBoxes: [
        for (final r in p.flowRules.sourceBoxes)
          if (r.configKey != 'input_doc_cam') r,
      ]));

      autoDrawRoutingFromConfig(p);

      expect(p.avNodeById(avAutoNodeId('input_doc_cam')), isNull);
      // And the USB rule that names it draws nothing rather than guessing.
      expect(onTogglePort(p, 'USB DEVICE 3'), isNull);
    });

    test('an outlet alias is what settles a name two boxes answer to', () {
      final p = room();
      (p.roomConfig['SYSTEM_SETUP'] as Map)['power1_outlet_2'] = 'Switch';
      p.roomConfig['POWERDEVICE_1'] = <String, dynamic>{
        'name': 'Power Controller - APC AP7900B',
        'model': 'AP7900B',
        'com_type': 'Network',
      };
      final template = p.avDeviceLibrary
          .resolve(configKey: 'POWERDEVICE_1', model: 'AP7900B');
      p.addAvNode(AvNode(
        id: 'POWERDEVICE_1',
        label: 'Power Controller - APC AP7900B',
        model: 'AP7900B',
        pos: Offset.zero,
        ports: withPowerInlet(template.ports, template.powerInput),
        fromConfig: true,
      ));

      // With the alias: the matrix, every time.
      final withAlias = planRoutingFromConfig(p);
      expect(
        withAlias.cables
            .firstWhere((c) => c.configKey == 'power1_outlet_2')
            .toNodeId,
        'SWITCHERDEVICE_1',
      );

      // Without it: a tie between the matrix and the USB switcher, and a tie
      // draws nothing rather than the wrong thing.
      p.applyFlowRules(p.flowRules.copyWith(outletAliases: const {}));
      final without = planRoutingFromConfig(p);
      expect(without.cables.map((c) => c.configKey),
          isNot(contains('power1_outlet_2')));
      expect(without.unresolved.map((u) => u.configKey),
          contains('power1_outlet_2'));
    });
  });

  group('the tab', () {
    Future<void> pump(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: FlowRulesView())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('opens on the source boxes, with every family listed',
        (tester) async {
      await pump(tester, room());

      for (final section in const [
        'flow_rules_section_sourceBoxes',
        'flow_rules_section_extenders',
        'flow_rules_section_usbSwitchers',
        'flow_rules_section_outletAliases',
      ]) {
        expect(find.byKey(ValueKey(section)), findsOneWidget);
      }
      expect(find.text('input_pc'), findsOneWidget);
      expect(find.textContaining('Room PC'), findsOneWidget);
    });

    testWidgets('an edit reaches the rules, and the drawing follows',
        (tester) async {
      final p = room();
      await pump(tester, p);

      await tester.tap(
          find.byKey(const ValueKey('flow_rules_section_outletAliases')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('flow_rules_add')));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'The whole outlet label'), 'Brain');
      await tester.enterText(
          find.widgetWithText(TextField, 'The device it means'),
          'PROCESSORDEVICE_');
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(ElevatedButton, 'Save'),
      ));
      await tester.pumpAndSettle();

      expect(p.flowRules.outletAliases['brain'], 'PROCESSORDEVICE_');
      // And the drawing is allowed to be built again with it — the pass skips
      // a room whose fingerprint has not moved, and a rule edit has to count
      // as movement or the change is invisible until something else changes.
      expect(p.avRoutedFingerprint, isEmpty);
    });

    testWidgets('Reset to built-in puts every family back', (tester) async {
      final p = room();
      p.applyFlowRules(p.flowRules.copyWith(sourceBoxes: const []));
      await pump(tester, p);

      await tester.tap(find.byKey(const ValueKey('flow_rules_reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Reset'));
      await tester.pumpAndSettle();

      expect(p.flowRules.sourceBoxFor('input_pc')?.model, 'PC');
    });

    testWidgets('a rule naming a model the catalog lacks says so',
        (tester) async {
      final p = room();
      p.applyFlowRules(p.flowRules.copyWith(sourceBoxes: [
        const FlowBoxRule(
            configKey: 'input_pc', label: 'Room PC', model: 'Beige Box 9000'),
      ]));
      await pump(tester, p);

      // Not fatal — the family template stands in — but nearly always a typo,
      // and a box that costs nothing on the estimate is worth noticing.
      expect(find.textContaining('does not carry "Beige Box 9000"'),
          findsOneWidget);
    });
  });

  group('the rules the app starts with', () {
    test('are the constants the routing pass used to carry', () {
      final rules = FlowRules.builtIn();

      expect(rules.sourceBoxFor('input_pc')?.model, 'PC');
      expect(rules.sourceBoxFor('input_doc_cam')?.model, 'Document Camera');
      expect(rules.sourceBoxFor('input_hdmi')?.excludeFromCost, isTrue);
      expect(rules.sourceBoxFor('input_dvd')?.zone, 'rack');
      expect(rules.sourceBoxFor(kFlowVgaPlateKey)?.model, 'VGA Laptop');

      expect(
        rules.extenderFor(
          switcherSignal: SignalType.hdbaset,
          farSignal: SignalType.hdmi,
          onOutput: true,
        )?.model,
        'DTP HDMI 4K 230 Rx',
      );
      expect(
        rules.extenderFor(
          switcherSignal: SignalType.hdbaset,
          farSignal: SignalType.hdmi,
          onOutput: false,
        )?.model,
        'DTP HDMI 4K 230 Tx',
      );
      // Two ends that take the same cable need no box between them.
      expect(
        rules.extenderFor(
          switcherSignal: SignalType.hdmi,
          farSignal: SignalType.hdmi,
          onOutput: true,
        ),
        isNull,
      );

      expect(rules.isExpansionLabel('DMP EXP'), isTrue);
      expect(rules.isExpansionLabel('EXPO'), isFalse);
      expect(rules.outletAliases['switch'], 'SWITCHERDEVICE_');
    });
  });
}
