import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_routing.dart';
import 'package:extron_configurator/av_flow_routing_dialog.dart';
import 'package:extron_configurator/ui_schema.dart';

/// Drawing cables from config numbers is not something to do on one click and
/// a hope, so it goes through the same review the control side does: every tie
/// listed with the key it came from and the value that key held, and nothing
/// touched until somebody presses the button.
void main() {
  // Loaded once, outside any widget test: reading the schema and the catalog
  // is real file I/O, and a future that touches the disk inside testWidgets'
  // fake-async zone never completes.
  late UiSchema schema;
  late AvDeviceLibrary library;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
    library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
  });

  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..avDeviceLibrary = library;

    p.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{
      'dev_projectors': '1',
      'dev_switchers': '1',
      'input_pc': '1',
      'input_hdmi': '4',
      'output_proj_1': '3B',
    };
    p.roomConfig['PROJECTORDEVICE_1'] = <String, dynamic>{
      'name': 'Projector - PowerLite L630U',
      'model': 'PowerLite L630U',
      'input': 'HDBaseT',
      'com_type': 'Network',
    };
    p.roomConfig['SWITCHERDEVICE_1'] = <String, dynamic>{
      'name': 'Switcher - DTP CrossPoint 84 4K IPCP MA 70',
      'model': 'DTP CrossPoint 84 4K IPCP MA 70',
      'com_type': 'Network',
    };

    for (final key in const ['SWITCHERDEVICE_1', 'PROJECTORDEVICE_1']) {
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

  Future<void> open(WidgetTester tester, AppStateProvider p) async {
    // A surface big enough for the whole list: the tie list is a ListView, so
    // an item below the fold is never built and a finder cannot see it.
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => showRoutingDialog(context, p),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  testWidgets('the review names the key and the value behind every cable',
      (tester) async {
    final p = room();
    await open(tester, p);

    expect(find.text('Draw the routing from the config'), findsOneWidget);
    // The tie the whole feature is about, spelled out both ways: the cable it
    // would draw, and the config that says so.
    expect(find.textContaining('DTP OUT 003B'), findsOneWidget);
    expect(find.textContaining('HDBaseT'), findsWidgets);
    expect(find.textContaining('output_proj_1 = 3B'), findsOneWidget);
    expect(find.textContaining('input_pc = 1'), findsOneWidget);
  });

  testWidgets('cancelling draws nothing', (tester) async {
    final p = room();
    final cablesBefore = p.avCables.length;
    final nodesBefore = p.avNodes.length;

    await open(tester, p);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(p.avCables, hasLength(cablesBefore));
    expect(p.avNodes, hasLength(nodesBefore));
  });

  testWidgets('confirming draws the cables and adds the sources',
      (tester) async {
    final p = room();
    await open(tester, p);

    await tester.tap(find.textContaining('Draw 3 cable'));
    await tester.pumpAndSettle();

    expect(p.avCables, hasLength(3));
    // The PC and the HDMI plate laptop are not config blocks, so they had to
    // be created for their cables to land on something.
    expect(p.avNodes.map((n) => n.model), containsAll(['PC', 'HDMI Laptop']));

    final projectorTie = p.avCables.firstWhere(
        (c) => c.toNodeId == 'PROJECTORDEVICE_1' ||
            c.fromNodeId == 'PROJECTORDEVICE_1');
    expect(projectorTie.fromNodeId, 'SWITCHERDEVICE_1');
    expect(projectorTie.fromPortId, 'dtp_out_003b');
    expect(projectorTie.toPortId, 'in_hdbt_1');
    expect(projectorTie.signal, SignalType.hdbaset);
  });

  testWidgets('a room with nothing to draw says so instead', (tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..avDeviceLibrary = library;
    p.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{'input_pc': '1'};

    await open(tester, p);
    expect(find.text('Nothing to draw'), findsOneWidget);
    expect(find.textContaining('SWITCHERDEVICE_1'), findsOneWidget);
  });

  test('the plan is empty for a room that states no numbers', () {
    final p = room();
    (p.roomConfig['SYSTEM_SETUP'] as Map)
      ..remove('input_pc')
      ..remove('input_hdmi')
      ..remove('output_proj_1');
    expect(planRoutingFromConfig(p).isEmpty, isTrue);
  });
}
