import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';

/// The shipped av_devices.json is generated from the Extron engineering
/// drawing stencils in drawings_library/. It is the file every room's ports,
/// rack heights and prices start from, so a malformed or half-read entry in it
/// is a defect in every room at once.
void main() {
  late AvDeviceLibrary catalog;

  setUpAll(() async {
    catalog = await AvDeviceLibrary.readFile('av_devices.json');
  });

  test('the whole catalog parses', () {
    expect(catalog.modelCount, greaterThan(900));
    for (final entry in catalog.all) {
      expect(entry.model.trim(), isNotEmpty);
      expect(entry.custom, isTrue, reason: 'a file entry is the user\'s');
    }
  });

  test('every powered device carries exactly one power inlet', () {
    int mains = 0, poe = 0, passive = 0;
    // poe is asserted on below; the count is reported for the reader.
    for (final entry in catalog.all) {
      final inlets = entry.ports.where((p) => p.isPowerInlet).toList();
      switch (entry.powerInput) {
        case PowerInput.none:
          passive++;
          expect(inlets, isEmpty, reason: '${entry.model} is passive');
        case PowerInput.poe:
          poe++;
          expect(inlets.length, 1, reason: '${entry.model} needs one inlet');
          expect(inlets.single.label, contains('PoE'));
        case PowerInput.mains:
          mains++;
          expect(inlets.length, 1, reason: '${entry.model} needs one inlet');
          expect(inlets.single.id, kPowerPortId);
      }
    }
    expect(mains, greaterThan(700));
    expect(passive, greaterThan(0));
    expect(mains + poe + passive, catalog.modelCount);
  });

  test('the inlet is kept out of the signal connector counts', () {
    final switcher = catalog.templateForModel('SW4 HD 4K PLUS')!;
    expect(switcher.ports.any((p) => p.isPowerInlet), isTrue);
    // Four HDMI in; the POWER inlet and the RS-232 port are not HDMI inputs.
    expect(
      switcher.ports.where((p) => p.signal == SignalType.hdmi).length,
      5,
    );
    expect(
      switcher.inputCount,
      switcher.ports.where((p) => !p.isPowerInlet && !p.isOutput).length,
    );
  });

  test('models the app already knew keep their rack height', () {
    expect(
      catalog.templateForModel('DTP CrossPoint 108 4K IPCP MA 70')?.rackUnits,
      3,
    );
    expect(catalog.templateForModel('DMP 128 Plus C AT')?.rackUnits, 1);
  });

  test('drawings supply the part number, description and connectors', () {
    final dsp = catalog.templateForModel('DMP 128 Plus C AT')!;
    expect(dsp.manufacturer, 'Extron');
    expect(dsp.partNumber, isNotEmpty);
    expect(dsp.category, 'Audio');
    expect(dsp.notes, contains('ProDSP'));
    expect(
      dsp.ports.where((p) => p.signal == SignalType.micLine).length,
      greaterThanOrEqualTo(12),
    );
    expect(dsp.ports.any((p) => p.signal == SignalType.dante), isTrue);
  });

  test('inputs land on the left and outputs on the right', () {
    for (final entry in catalog.all) {
      for (final port in entry.ports) {
        if (port.isPowerInlet) continue;
        expect(
          port.side,
          port.isOutput ? PortSide.right : PortSide.left,
          reason: '${entry.model} / ${port.label}',
        );
      }
    }
  });

  test('port ids are unique within a device', () {
    for (final entry in catalog.all) {
      final ids = entry.ports.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length, reason: entry.model);
    }
  });

  test('nothing is priced or metered yet — the drawings do not say', () {
    // Guards the import against inventing figures: a fabricated price is
    // worse than a blank one, because a blank is reported as missing.
    expect(catalog.all.every((e) => e.price == 0), isTrue);
    expect(catalog.all.every((e) => e.powerWatts == 0), isTrue);
  });

  test('the file is the one the app would load from the root folder', () {
    expect(File('av_devices.json').existsSync(), isTrue);
  });
}
