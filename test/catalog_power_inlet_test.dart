import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/device_editor_view.dart';

/// "Every powered device carries exactly one power inlet" is the rule
/// test/catalog_import_test.dart holds the shipped av_devices.json to, and it
/// is the rule the rack load, the power report and the drawing all read the
/// same way. The AP7900B reached the file breaking it — saved as mains, with no
/// inlet — because the Device Editor stored whatever ports it was handed.
///
/// So the write reconciles the two. These cover both halves of that: what
/// lands on disk, and what does NOT happen while somebody is still typing.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('av_inlet_test_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AvPort hdmi(String id, String label) => AvPort(
    id: id,
    label: label,
    signal: SignalType.hdmi,
    direction: PortDirection.input,
    side: PortSide.left,
  );

  /// Saves [library] to a fresh file and reads it back the way the app would.
  Future<AvDeviceTemplate> roundTrip(
    AvDeviceLibrary library,
    String model,
  ) async {
    final target = path.join(dir.path, 'av_devices.json');
    expect(await library.save(toPath: target), target);
    final back = await AvDeviceLibrary.readFile(target);
    return back.templateForModel(model)!;
  }

  List<String> labelsOf(AvDeviceTemplate entry) => [
    for (final p in entry.ports) p.label,
  ];

  group('saving the catalog', () {
    test('a mains entry saved without an inlet gets one', () async {
      // The AP7900B's shape exactly: a PDU, powerInput left at its mains
      // default, connectors filled in and no inlet among them.
      final library = AvDeviceLibrary.empty()
        ..upsert(
          AvDeviceTemplate(
            model: 'Rack PDU',
            ports: [hdmi('in_1', 'HDMI IN 1')],
          ),
        );

      final saved = await roundTrip(library, 'Rack PDU');
      final inlets = saved.ports.where((p) => p.isPowerInlet).toList();
      expect(inlets.length, 1);
      expect(inlets.single.id, kPowerPortId);
      expect(inlets.single.label, 'POWER');
      // Appended, not inserted: the connectors keep the order they were given.
      expect(labelsOf(saved), ['HDMI IN 1', 'POWER']);
    });

    test('a PoE entry gets the inlet its toggle calls for', () async {
      final library = AvDeviceLibrary.empty()
        ..upsert(
          const AvDeviceTemplate(
            model: 'Ceiling Mic',
            powerInput: PowerInput.poe,
            ports: [],
          ),
        );

      final saved = await roundTrip(library, 'Ceiling Mic');
      expect(saved.ports.single.isPowerInlet, isTrue);
      expect(saved.ports.single.label, contains('PoE'));
    });

    test('a passive entry does not keep a stray inlet', () async {
      // Switching an entry to "None" by hand, or merging one in from a file
      // that had it wrong: a speaker with a mains plug lands in the rack load.
      final library = AvDeviceLibrary.empty()
        ..upsert(
          AvDeviceTemplate(
            model: 'Passive Speaker',
            powerInput: PowerInput.none,
            ports: [
              hdmi('in_1', 'HDMI IN 1'),
              powerInletPort(PowerInput.mains),
            ],
          ),
        );

      final saved = await roundTrip(library, 'Passive Speaker');
      expect(saved.ports.any((p) => p.isPowerInlet), isFalse);
      expect(labelsOf(saved), ['HDMI IN 1']);
    });

    test('a mains inlet that was already right is left alone', () async {
      final library = AvDeviceLibrary.empty()
        ..upsert(
          AvDeviceTemplate(
            model: 'Switcher Y',
            ports: [
              hdmi('in_1', 'HDMI IN 1'),
              powerInletPort(PowerInput.mains),
            ],
          ),
        );

      final saved = await roundTrip(library, 'Switcher Y');
      expect(labelsOf(saved), ['HDMI IN 1', 'POWER']);
      expect(saved.ports.where((p) => p.isPowerInlet).length, 1);
    });

    test('the inlet a PoE entry was saved with is relabelled', () async {
      // The toggle relabels the inlet as it moves, but an entry can arrive
      // from a hand-edited file or a merge with the two out of step.
      final library = AvDeviceLibrary.empty()
        ..upsert(
          AvDeviceTemplate(
            model: 'Camera',
            powerInput: PowerInput.poe,
            ports: [powerInletPort(PowerInput.mains)],
          ),
        );

      final saved = await roundTrip(library, 'Camera');
      expect(saved.ports.single.label, contains('PoE'));
    });

    test('built-ins are not rewritten, since they are not written', () async {
      // Every built-in declares its connectors without an inlet and is given
      // one when it is placed. Reconciling them here would edit a table the
      // file never carries.
      final library = AvDeviceLibrary.builtIn()
        ..upsert(
          AvDeviceTemplate(model: 'Mine', ports: [hdmi('in_1', 'HDMI IN 1')]),
        );
      final builtIn = library.templateForModel(
        'DTP CrossPoint 108 4K IPCP MA 70',
      )!;
      expect(builtIn.custom, isFalse);
      final before = labelsOf(builtIn);

      final target = path.join(dir.path, 'av_devices.json');
      await library.save(toPath: target);

      expect(
        labelsOf(library.templateForModel('DTP CrossPoint 108 4K IPCP MA 70')!),
        before,
      );
      // And the entry that IS the user's was reconciled.
      expect(labelsOf(library.templateForModel('Mine')!), [
        'HDMI IN 1',
        'POWER',
      ]);
    });

    test('every entry written satisfies the catalog invariant', () async {
      // The same check test/catalog_import_test.dart runs over the shipped
      // file, over a catalog assembled entirely out of broken entries.
      final library = AvDeviceLibrary.empty()
        ..upsert(AvDeviceTemplate(model: 'No inlet', ports: []))
        ..upsert(
          const AvDeviceTemplate(
            model: 'PoE, no inlet',
            powerInput: PowerInput.poe,
            ports: [],
          ),
        )
        ..upsert(
          AvDeviceTemplate(
            model: 'Passive with inlet',
            powerInput: PowerInput.none,
            ports: [powerInletPort(PowerInput.mains)],
          ),
        )
        ..upsert(
          AvDeviceTemplate(
            model: 'Two inlets',
            ports: [
              powerInletPort(PowerInput.mains),
              powerInletPort(PowerInput.poe),
            ],
          ),
        );

      final target = path.join(dir.path, 'av_devices.json');
      await library.save(toPath: target);
      final back = await AvDeviceLibrary.readFile(target);

      expect(back.modelCount, 4);
      for (final entry in back.all) {
        final inlets = entry.ports.where((p) => p.isPowerInlet).toList();
        switch (entry.powerInput) {
          case PowerInput.none:
            expect(inlets, isEmpty, reason: '${entry.model} is passive');
          case PowerInput.poe:
            expect(inlets.length, 1, reason: entry.model);
            expect(inlets.single.label, contains('PoE'));
          case PowerInput.mains:
            expect(inlets.length, 1, reason: entry.model);
            expect(inlets.single.id, kPowerPortId);
        }
      }
    });
  });

  group('while an entry is being edited', () {
    test('upsert stores the ports exactly as handed over', () {
      // The editor upserts on every keystroke. Reconciling there would move
      // the inlet to the end of the list mid-edit, so it deliberately does
      // not — this is the guard on that, not an oversight.
      final library = AvDeviceLibrary.empty()
        ..upsert(
          AvDeviceTemplate(
            model: 'Switcher Y',
            ports: [
              powerInletPort(PowerInput.mains),
              hdmi('in_1', 'HDMI IN 1'),
            ],
          ),
        );

      expect(labelsOf(library.templateForModel('Switcher Y')!), [
        'POWER',
        'HDMI IN 1',
      ]);
    });

    testWidgets('typing in the Device Editor does not move the inlet', (
      tester,
    ) async {
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.avDeviceLibrary = AvDeviceLibrary.empty()
        ..upsert(
          AvDeviceTemplate(
            model: 'Switcher Y',
            ports: [
              hdmi('in_1', 'HDMI IN 1'),
              powerInletPort(PowerInput.mains),
              hdmi('in_2', 'HDMI IN 2'),
            ],
          ),
        );

      tester.view.physicalSize = const Size(1800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: DeviceEditorView())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Switcher Y'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Manufacturer'),
        'Extron',
      );
      await tester.pumpAndSettle();

      final entry = provider.avDeviceLibrary.templateForModel('Switcher Y')!;
      expect(entry.manufacturer, 'Extron');
      // The POWER row is still where it was put, not shuffled to the bottom
      // under the pointer.
      expect(labelsOf(entry), ['HDMI IN 1', 'POWER', 'HDMI IN 2']);
      expect(tester.takeException(), isNull);
    });
  });
}
