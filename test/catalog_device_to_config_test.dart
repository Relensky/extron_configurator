import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/control_prefill.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/device_start_wizard.dart';
import 'package:extron_configurator/ui_schema.dart';
import 'package:provider/provider.dart';

/// Adding a part out of the catalog is somebody saying the room HAS this box,
/// and the control side should not have to be told a second time.
///
/// The device lands in the family its DEVICE TYPE names — the catalog's own
/// record of what the thing is — and the block comes out carrying the driver's
/// answer for that model rather than the family's generic one: a DMP 64 is
/// reached on Extron's SSH port whatever the DSP family usually does.
void main() {
  Future<AppStateProvider> emptyRoom() async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = await UiSchema.load(explicitPath: 'ui_schema.json')
      ..avDeviceLibrary =
          await AvDeviceLibrary.load(explicitPath: 'av_devices.json')
      ..modulesPath = path.join(Directory.current.path, 'device');
    p.roomConfig
      ..clear()
      ..addAll(
        Map<String, dynamic>.from(
          jsonDecode(File('config.json').readAsStringSync()) as Map,
        ),
      );
    // A room with no hardware in it yet, the way New Config leaves one.
    p.roomConfig.removeWhere((k, v) => v is Map && v.containsKey('com_type'));
    final setup = p.roomConfig['SYSTEM_SETUP'] as Map;
    for (final spec in p.uiSchema.deviceTypes) {
      setup[spec.countKey] = '0';
    }
    // The driver library is where the device type and the connection defaults
    // both come from, so the registry has to be built before anything is added.
    await p.preloadAllModules();
    return p;
  }

  /// The box the "Add device" dialog puts on the canvas: a catalog model, and
  /// an id the provider assigned rather than a config section key.
  AvNode place(AppStateProvider p, String model) => p.addAvNode(
        AvNode(
          id: '',
          label: model,
          model: model,
          pos: const Offset(40, 60),
          ports: p.avDeviceLibrary.templateForModel(model)?.ports ?? const [],
        ),
      );

  test('a catalog part added to the room gets a block in its own family',
      () async {
    final p = await emptyRoom();
    final node = place(p, 'DMP 64 Plus C');

    final plan = planControlSide(p, nodeIds: [node.id]);
    expect(plan.creatable, hasLength(1));
    expect(plan.creatable.single.family!.prefix, 'DSPDEVICE_',
        reason: "the catalog says this model's device type is dsp");

    final result = applyControlSide(p, plan);
    expect(result.created, 1);
    expect(result.sectionKeys, ['DSPDEVICE_1']);

    final dev = p.roomConfig['DSPDEVICE_1'];
    expect(dev, isA<Map>());
    expect((dev as Map)['model'], 'DMP 64 Plus C');
    expect(p.roomConfig['SYSTEM_SETUP']['dev_dsps'], '1');

    // The drawing and the config are one device now, not two records of it.
    expect(p.avNodeById('DSPDEVICE_1'), isNotNull);
    expect(p.avNodeById(node.id), isNull);
  });

  test('the block comes out on the driver\'s own connection settings',
      () async {
    final p = await emptyRoom();
    final node = place(p, 'DMP 64 Plus C');
    applyControlSide(p, planControlSide(p, nodeIds: [node.id]));

    final dev = p.roomConfig['DSPDEVICE_1'] as Map;
    final module = dev['module'].toString();
    expect(module, isNotEmpty, reason: 'the library claims this model');

    // Whatever the driver publishes for this model is what the block says —
    // read from the module rather than frozen here, because a port or a
    // protocol changing in the library is a fact about the room, not a
    // failing test.
    final defaults = p.moduleDefaultsFor(module)!;
    for (final key in ['com_type', 'protocol', 'net_port']) {
      expect(dev[key], defaults[key],
          reason: '$key should come from the driver, not the family');
    }
  });

  test('a part no family claims is left on the diagram alone', () async {
    final p = await emptyRoom();
    // A passive box: nothing drives a wall plate, and a block for one would be
    // a slot waiting forever for an IP address.
    final node = place(p, 'Speaker');

    final plan = planControlSide(p, nodeIds: [node.id]);
    expect(plan.creatable, isEmpty);
    expect(p.roomConfig.keys.where((k) => k.startsWith('DSPDEVICE_')), isEmpty);
    expect(p.avNodeById(node.id), isNotNull);
  });

  test('a second part of the same family numbers past the first', () async {
    final p = await emptyRoom();
    final first = place(p, 'DMP 64 Plus C');
    applyControlSide(p, planControlSide(p, nodeIds: [first.id]));

    final second = place(p, 'DMP 64 Plus C');
    final result =
        applyControlSide(p, planControlSide(p, nodeIds: [second.id]));

    expect(result.sectionKeys, ['DSPDEVICE_2']);
    expect(p.roomConfig['SYSTEM_SETUP']['dev_dsps'], '2');
    // The first one is still there — adding is never a rebuild of the family.
    expect(p.roomConfig['DSPDEVICE_1'], isA<Map>());
  });

  /// The whole way through, from the button somebody actually presses.
  ///
  /// The unit tests above call the prefill directly; this is the wiring — that
  /// the "Add device" dialog hands the box it just placed to it, rather than
  /// leaving the config side for a pass somebody has to remember to run.
  testWidgets('adding a device from the dialog writes the config block',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // runAsync: the setup reads the schema, the catalog and every driver in
    // the modules folder off the real disk, and a testWidgets body runs on
    // fake async where that I/O never completes.
    late AppStateProvider p;
    await tester.runAsync(() async {
      p = await emptyRoom();
    });
    // Before the tab is pumped: opening it reloads (and clears) the diagram
    // the first time it sees a config.
    p.loadAvFlowForCurrentConfig();

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: AvFlowView())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Add custom device'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Search the catalog'),
      'dmp64plusc',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('DMP 64 Plus C').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final dev = p.roomConfig['DSPDEVICE_1'];
    expect(dev, isA<Map>(), reason: 'the part is in the room, so it is a DSP');
    expect((dev as Map)['model'], 'DMP 64 Plus C');
    expect(p.roomConfig['SYSTEM_SETUP']['dev_dsps'], '1');
    // And said so, because a device block appearing silently is a change
    // nobody knows to fill an address in on.
    expect(find.textContaining('DSPDEVICE_1'), findsOneWidget);
  });

  /// The same rule on the page a room is actually specified from.
  ///
  /// Quoting a device IS putting it in the room: the estimate is where the
  /// parts are picked, and a line that never reached a device block is a box
  /// that gets ordered, racked and then has nothing to drive it.
  testWidgets('a device quoted on the cost page lands in the config too',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppStateProvider p;
    await tester.runAsync(() async {
      p = await emptyRoom();
    });
    p.loadAvFlowForCurrentConfig();

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add from catalog').first);
    await tester.pumpAndSettle();
    expect(find.text('Add equipment'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Search the device catalog'),
      'dmp64plusc',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('DMP 64 Plus C').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final dev = p.roomConfig['DSPDEVICE_1'];
    expect(dev, isA<Map>());
    expect((dev as Map)['model'], 'DMP 64 Plus C');
    // The count the Wizard and the Devices tab read.
    expect(p.roomConfig['SYSTEM_SETUP']['dev_dsps'], '1');
    // On the diagram as a real box rather than sitting as a quoted line.
    expect(p.avNodeById('DSPDEVICE_1'), isNotNull);
    expect(p.avCost.extraEquipment, isEmpty);
  });

  /// The wizard a room is started from.
  ///
  /// This is where the parts list for a new room is picked, twenty at a time,
  /// and it used to leave the config side empty: the Wizard tab's hardware
  /// counts read zero while the estimate under it listed the whole room, and
  /// every device had to be told to the config a second time.
  testWidgets('the start wizard builds the control side of what it places',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppStateProvider p;
    await tester.runAsync(() async {
      p = await emptyRoom();
    });
    p.loadAvFlowForCurrentConfig();

    DeviceStartResult? result;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () async {
                  result = await showDeviceStartWizard(ctx, p);
                },
                child: const Text('open the wizard'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open the wizard'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Search the catalog'),
      'dmp64plusc',
    );
    await tester.pumpAndSettle();
    // The catalog row on the left, not the picked line that appears on the
    // right once it has been chosen.
    await tester.tap(find.widgetWithText(ListTile, 'DMP 64 Plus C').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Add to the room'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(result?.placed, 1);
    expect(result?.blocks, 1);

    final dev = p.roomConfig['DSPDEVICE_1'];
    expect(dev, isA<Map>());
    expect((dev as Map)['model'], 'DMP 64 Plus C');
    // The count the Wizard tab reads, so the room does not say it has none.
    expect(p.roomConfig['SYSTEM_SETUP']['dev_dsps'], '1');
    // Still the same box on the canvas, under the config's own key.
    expect(p.avNodeById('DSPDEVICE_1'), isNotNull);
  });
}
