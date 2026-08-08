import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/ui_schema.dart';

/// A device's connection settings split cleanly in two, and carrying the wrong
/// half is dead data that still ships to the processor and still has to be
/// read past on the device tab:
///
///   Serial          serial_port, baud — the only com_type that opens a COM
///                   port on the host processor/spdevice
///   Network / SoE   ip_address, net_port, protocol, service_port, user,
///                   password — how everything else reaches its hardware
///
/// The split is schema-driven ("hideWhen" on each key in ui_schema.json), so
/// nothing below is hardcoded to a connection in the app. These cover every
/// route by which a device could pick up the wrong half: the template it is
/// copied from, the wizard's device_defaults, Check Defaults, a model's
/// DEVICE_INFO, and an edit that changes the connection out from under an
/// existing value — plus the keys that belong to a device whatever it is
/// plugged into.
void main() {
  Future<UiSchema> schema() => UiSchema.load(explicitPath: 'ui_schema.json');

  /// Only a device that talks over the network carries these.
  const networkKeys = [
    'ip_address', 'net_port', 'protocol', 'service_port', 'user', 'password',
  ];

  /// Only a device on a COM port carries these.
  const serialKeys = ['serial_port', 'baud'];

  /// Every device carries these, whatever it is plugged into.
  const alwaysKeys = [
    'device_id', 'keep_alive_qualifier', 'keep_alive_trigger', 'model',
    'lbl_name', 'use_device_mute', 'manual_disconnect',
  ];

  late Directory dir;
  late String templatePath;

  Map<String, dynamic> networkDevice() => {
        'name': 'Projector 1',
        'com_type': 'Network',
        'module': '',
        'ip_address': '192.168.254.114',
        'net_port': 53595,
      };

  setUp(() {
    dir = Directory.systemTemp.createTempSync('connection_fields_test_');
    templatePath = path.join(dir.path, 'config.json');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('the schema itself', () {
    test('rules serial_port and baud out of every non-serial connection',
        () async {
      final s = await schema();
      for (final key in serialKeys) {
        for (final com in ['Network', 'SerialOverEthernet', 'HTTP']) {
          expect(s.isHiddenFor(key, {'com_type': com}), isTrue,
              reason: '$key should not be offered on a $com device');
        }
        expect(s.isHiddenFor(key, {'com_type': 'Serial'}), isFalse,
            reason: '$key is exactly what a Serial device needs');
      }
    });

    test('rules the network settings out of a serial connection', () async {
      final s = await schema();
      for (final key in networkKeys) {
        expect(s.isHiddenFor(key, {'com_type': 'Serial'}), isTrue,
            reason: '$key means nothing on a COM port');
        for (final com in ['Network', 'SerialOverEthernet']) {
          expect(s.isHiddenFor(key, {'com_type': com}), isFalse,
              reason: '$key is how a $com device is reached');
        }
      }
    });

    test('gates none of the keys every device carries', () async {
      final s = await schema();
      for (final key in alwaysKeys) {
        for (final com in ['Serial', 'SerialOverEthernet', 'Network', 'HTTP']) {
          expect(s.isHiddenFor(key, {'com_type': com}), isFalse,
              reason: '$key describes the device, not the link');
        }
      }
    });

    test("leaves 'host' alone on both sides", () async {
      // It names the processor/spdevice a serial line is wired to and is
      // simply ignored on a network device, so it is on neither list.
      final s = await schema();
      for (final com in ['Serial', 'Network', 'SerialOverEthernet']) {
        expect(s.isHiddenFor('host', {'com_type': com}), isFalse);
      }
    });
  });

  group('the device tab', () {
    /// What the tab renders on top of the keys the block already holds.
    Future<Iterable<String>> offered(Map<String, dynamic> dev) async =>
        (await schema())
            .missingFieldsFor('PROJECTORDEVICE_1', dev.keys, section: dev)
            .map((s) => s.key);

    test('offers a serial device the port and baud it has yet to be given',
        () async {
      // The other half of taking serial_port out of the network template: a
      // device switched TO Serial has nowhere to type the port unless the tab
      // draws the field before the key exists.
      final dev = {'com_type': 'Serial', 'ip_address': ''};
      expect(await offered(dev), containsAll(['serial_port', 'baud']));
    });

    test('offers neither to a network or serial-over-ethernet device',
        () async {
      for (final com in ['Network', 'SerialOverEthernet', 'HTTP']) {
        final keys = await offered({'com_type': com});
        expect(keys, isNot(contains('serial_port')), reason: com);
        expect(keys, isNot(contains('baud')), reason: com);
      }
    });

    test('does not re-offer a port the device already has', () async {
      final dev = {'com_type': 'Serial', 'serial_port': 'COM3', 'baud': 9600};
      final keys = await offered(dev);
      expect(keys, isNot(contains('serial_port')));
      expect(keys, isNot(contains('baud')));
    });

    test('offers a network device every connection setting it needs',
        () async {
      for (final com in ['Network', 'SerialOverEthernet']) {
        expect(await offered({'com_type': com}), containsAll(networkKeys),
            reason: com);
      }
    });

    test('offers a serial device none of the network settings', () async {
      final keys = await offered({'com_type': 'Serial'});
      for (final key in networkKeys) {
        expect(keys, isNot(contains(key)), reason: key);
      }
    });

    test('offers the always-present keys on every connection', () async {
      for (final com in ['Serial', 'SerialOverEthernet', 'Network']) {
        final keys = await offered({'com_type': com});
        // 'model' has its own dedicated slot at the top of the tab, so the
        // device form skips it in this list; the rest render inline.
        expect(keys, containsAll(alwaysKeys), reason: com);
      }
    });
  });

  group('the shipped template', () {
    Map<String, Map> devices() {
      final config =
          jsonDecode(File('config.json').readAsStringSync()) as Map;
      final out = <String, Map>{};
      config.forEach((section, block) {
        if (block is Map && block.containsKey('com_type')) {
          out[section.toString()] = block;
        }
      });
      return out;
    }

    test('has device blocks to check', () {
      expect(devices(), isNotEmpty);
    });

    test('gives every device the keys that do not depend on the link', () {
      final offenders = <String>[];
      devices().forEach((section, block) {
        for (final key in alwaysKeys) {
          if (!block.containsKey(key)) offenders.add('$section.$key');
        }
      });
      expect(offenders, isEmpty, reason: 'missing from the template');
    });

    test('gives a network device its settings and no COM port', () {
      final offenders = <String>[];
      devices().forEach((section, block) {
        if (block['com_type'].toString().toLowerCase() == 'serial') return;
        for (final key in networkKeys) {
          if (!block.containsKey(key)) offenders.add('$section.$key missing');
        }
        for (final key in serialKeys) {
          if (block.containsKey(key)) offenders.add('$section.$key present');
        }
      });
      expect(offenders, isEmpty);
    });

    test('gives a serial device its COM port and none of the network keys',
        () {
      final offenders = <String>[];
      devices().forEach((section, block) {
        if (block['com_type'].toString().toLowerCase() != 'serial') return;
        for (final key in serialKeys) {
          if (!block.containsKey(key)) offenders.add('$section.$key missing');
        }
        for (final key in networkKeys) {
          if (block.containsKey(key)) offenders.add('$section.$key present');
        }
      });
      expect(offenders, isEmpty);
    });
  });

  /// A loaded room with one projector, the shape the wizard copies from.
  Future<AppStateProvider> roomWith(Map<String, dynamic> projector) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..templateFilePath = templatePath
      ..uiSchema = await schema();
    p.roomConfig['SYSTEM_SETUP'] = {'dev_projectors': '1'};
    p.roomConfig['PROJECTORDEVICE_1'] = projector;
    return p;
  }

  test('a device added by the wizard gets no serial port', () async {
    final p = await roomWith(networkDevice());

    p.setDeviceCount('dev_projectors', 'PROJECTORDEVICE_', 2,
        p.getDefaultDeviceBlock('PROJECTORDEVICE_'));

    for (final key in ['PROJECTORDEVICE_1', 'PROJECTORDEVICE_2']) {
      final dev = p.roomConfig[key] as Map;
      expect(dev['com_type'], 'Network', reason: key);
      expect(dev.containsKey('serial_port'), isFalse, reason: key);
      expect(dev.containsKey('baud'), isFalse, reason: key);
      // The rest of the family's device_defaults still land.
      expect(dev['relay_host'], 'processor1', reason: key);
    }
  });

  test('a serial device added by the wizard keeps its port and baud', () async {
    final p = await roomWith({
      'name': 'Projector 1',
      'com_type': 'Serial',
      'module': '',
      'host': 'processor1',
      'serial_port': 'COM3',
      'baud': 9600,
    });

    p.setDeviceCount('dev_projectors', 'PROJECTORDEVICE_', 2,
        p.getDefaultDeviceBlock('PROJECTORDEVICE_'));

    final dev = p.roomConfig['PROJECTORDEVICE_2'] as Map;
    expect(dev['serial_port'], 'COM3');
    expect(dev['baud'], 9600);
  });

  test('a serial template block hands no port to a network device', () async {
    // The wizard copies PROJECTORDEVICE_1; when that one is Serial and the new
    // block is put on a network connection, the copied port has to go.
    final p = await roomWith({
      'name': 'Projector 1',
      'com_type': 'Serial',
      'module': '',
      'serial_port': 'COM3',
      'baud': 9600,
    });
    p.setDeviceCount('dev_projectors', 'PROJECTORDEVICE_', 2,
        p.getDefaultDeviceBlock('PROJECTORDEVICE_'));

    p.updateDeviceValue('PROJECTORDEVICE_2', 'com_type', 'SerialOverEthernet');

    final dev = p.roomConfig['PROJECTORDEVICE_2'] as Map;
    expect(dev.containsKey('serial_port'), isFalse);
    expect(dev.containsKey('baud'), isFalse);
    expect((p.roomConfig['PROJECTORDEVICE_1'] as Map)['serial_port'], 'COM3',
        reason: 'the serial device it was copied from is untouched');
  });

  test('Check Defaults never offers the template port back to a network device',
      () async {
    // A template whose PROJECTORDEVICE_1 is Serial, and a room whose projector
    // is Network — the case where the template block is the wrong shape.
    File(templatePath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'dev_projectors': '1'},
      'PROJECTORDEVICE_1': {
        'name': 'Projector 1',
        'com_type': 'Serial',
        'module': '',
        'serial_port': 'COM3',
        'baud': 9600,
        'relay_host': 'processor1',
      },
    }));
    final p = AppStateProvider(autoLoadSettings: false)
      ..templateFilePath = templatePath
      ..uiSchema = await schema();
    p.roomConfig['SYSTEM_SETUP'] = {'dev_projectors': '1'};
    p.roomConfig['PROJECTORDEVICE_1'] = networkDevice();

    final missing = await p.missingDefaultsFor('PROJECTORDEVICE_1');

    expect(missing.containsKey('serial_port'), isFalse);
    expect(missing.containsKey('baud'), isFalse);
    expect(missing['relay_host'], 'processor1',
        reason: 'the rest of the template block is still offered');
  });

  test('switching an existing device to Network drops the port it held',
      () async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = await schema();
    p.roomConfig['PROJECTORDEVICE_1'] = {
      'name': 'Projector 1',
      'com_type': 'Serial',
      'module': '',
      'host': 'processor1',
      'serial_port': 'COM3',
      'baud': 9600,
    };

    p.updateDeviceValue('PROJECTORDEVICE_1', 'com_type', 'Network');

    final dev = p.roomConfig['PROJECTORDEVICE_1'] as Map;
    expect(dev.containsKey('serial_port'), isFalse);
    expect(dev.containsKey('baud'), isFalse);
    expect(dev['host'], 'processor1',
        reason: 'host is not one of the connection-gated keys');
  });

  test('switching an existing device to Serial drops its network settings',
      () async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = await schema();
    p.roomConfig['PROJECTORDEVICE_1'] = {
      'name': 'Projector 1',
      'com_type': 'Network',
      'module': '',
      'host': 'processor1',
      'ip_address': '192.168.254.114',
      'net_port': 53595,
      'protocol': 'TCP',
      'service_port': 0,
      'user': 'root',
      'password': 'secret',
      'model': 'VPL-PHZ60',
    };

    p.updateDeviceValue('PROJECTORDEVICE_1', 'com_type', 'Serial');

    final dev = p.roomConfig['PROJECTORDEVICE_1'] as Map;
    for (final key in networkKeys) {
      expect(dev.containsKey(key), isFalse, reason: '$key should be gone');
    }
    expect(dev['host'], 'processor1');
    expect(dev['model'], 'VPL-PHZ60',
        reason: 'the keys that describe the device survive the switch');
  });

  test('an ordinary edit on a serial device takes nothing away', () async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = await schema();
    p.roomConfig['PROJECTORDEVICE_1'] = {
      'com_type': 'Serial',
      'module': '',
      'serial_port': 'COM3',
      'baud': 9600,
    };

    p.updateDeviceValue('PROJECTORDEVICE_1', 'name', 'Renamed');

    final dev = p.roomConfig['PROJECTORDEVICE_1'] as Map;
    expect(dev['serial_port'], 'COM3');
    expect(dev['baud'], 9600);
  });
}
