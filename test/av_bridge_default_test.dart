import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';

/// The recorder in a hyflex room is a Vaddio AV Bridge 2x1: two HDMI inputs,
/// a loop-through out, and the USB the room's conferencing runs on. Two places
/// disagreed with that — a new RECORDERDEVICE block came out as the older
/// one-input "AV Bridge", and the catalog's own 2x1 entry carried four HDMI
/// inputs and a DTP output that a Vaddio box does not have.
void main() {
  test('a new recorder block is an AV Bridge 2x1', () {
    final map = jsonDecode(File('key_map.json').readAsStringSync()) as Map;
    final templates = map['device_templates'] as Map;
    final recorder = templates['RECORDERDEVICE_1'] as Map;
    expect(recorder['model'], 'AV Bridge 2x1');
  });

  test('the catalog entry has two HDMI inputs', () async {
    final library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
    final entry = library.templateForModel('AV Bridge 2x1');
    expect(entry, isNotNull);

    final hdmiIn = entry!.ports
        .where((p) => p.signal == SignalType.hdmi && p.isInput)
        .map((p) => p.label)
        .toList();
    expect(hdmiIn, ['HDMI IN 1', 'HDMI IN 2']);
  });

  test('and no DTP output - it is a Vaddio box', () {
    // DTP is Extron's twisted-pair connector and this entry carried one,
    // along with the two extra HDMI inputs: a switcher template copied over
    // the top of a Vaddio product. A port the box does not have is a port
    // somebody draws a cable to.
    return AvDeviceLibrary.load(explicitPath: 'av_devices.json')
        .then((library) {
      final entry = library.templateForModel('AV Bridge 2x1')!;
      expect(entry.ports.any((p) => p.signal == SignalType.hdbaset), isFalse);
      // Categorized as what it is, too. The category is what the estimate
      // falls back to when no model price is known, so a recorder filed
      // under Switcher is priced as a switcher.
      expect(entry.category, 'Recorder / streamer');
      expect(entry.ports.map((p) => p.label), [
        'HDMI IN 1',
        'HDMI IN 2',
        'HDMI OUT',
        'AUDIO IN',
        'AUDIO OUT',
        'LAN',
        'USB OUT',
        'POWER',
      ]);
    });
  });

  test('a recorder with no model yet gets the same shape', () async {
    final library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
    final template =
        library.resolve(configKey: 'RECORDERDEVICE_1', model: '');

    final hdmiIn = template.ports
        .where((p) => p.signal == SignalType.hdmi && p.isInput)
        .map((p) => p.label)
        .toList();
    // The second input is the point: with one, the second camera or the
    // second source had nowhere to land on the drawing.
    expect(hdmiIn, ['HDMI IN 1', 'HDMI IN 2']);
    expect(template.ports.any((p) => p.signal == SignalType.usbData &&
        p.isOutput), isTrue);
  });
}
