import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/config_key_mapper.dart';

/// Covers the conversion rules that DELETE data — the ones where a mistake is
/// silent and only shows up as a room that no longer works. Everything runs
/// through the real key_map.json so the shipped rules are what's under test.
void main() {
  late ConfigKeyMap map;

  setUp(() async {
    map = await ConfigKeyMap.load(explicitPath: 'key_map.json');
  });

  group('serial devices lose their network-only properties', () {
    Map<String, dynamic> serialCamera() => {
          'SYSTEM_SETUP': {'dev_cameras': '1', 'dev_power_controllers': '1'},
          'CAMERADEVICE_1': {
            'com_type': 'Serial',
            'serial_port': 'COM6',
            'service_port': 0,
            'model': 'TR311',
            'device_id': null,
            'keep_alive_trigger': null,
            'ip_address': 'N/A - Serial COM6',
            'net_port': 52381,
            'protocol': 'UDP',
            'password': 'ATEC2008',
            'user': 'main',
          },
        };

    test('drops exactly the six network-only keys', () {
      final result = map.apply(serialCamera());
      final dev = result.config['CAMERADEVICE_1'] as Map;

      for (final gone in const [
        'ip_address', 'net_port', 'protocol', 'service_port', 'password',
        'user',
      ]) {
        expect(dev.containsKey(gone), isFalse, reason: '$gone must be removed');
      }
      // device_id and keep_alive_trigger describe the module, not the link
      expect(dev.containsKey('device_id'), isTrue);
      expect(dev.containsKey('keep_alive_trigger'), isTrue);
      // The serial side is untouched
      expect(dev['serial_port'], 'COM6');
    });

    test('reports a real value as a conflict, a placeholder as a plain removal', () {
      final result = map.apply(serialCamera());
      final byKey = {for (final c in result.conflicts) c.key: c};

      // "N/A - Serial COM6" is a placeholder, not a real address
      expect(byKey.containsKey('ip_address'), isFalse);
      // ...but a password and a port genuinely were set
      expect(byKey['password']?.value, 'ATEC2008');
      expect(byKey['net_port']?.value, 52381);
      expect(byKey['password']?.reason, contains('Serial'));
      expect(byKey['password']?.section, 'CAMERADEVICE_1');
    });

    test('leaves a network device completely alone', () {
      final result = map.apply({
        'SYSTEM_SETUP': {'dev_cameras': '1'},
        'CAMERADEVICE_1': {
          'com_type': 'Network',
          'ip_address': '192.168.254.67',
          'net_port': 52381,
          'protocol': 'UDP',
          'password': 'ATEC2008',
          'user': 'main',
        },
      });
      final dev = result.config['CAMERADEVICE_1'] as Map;
      expect(dev['ip_address'], '192.168.254.67');
      expect(dev['user'], 'main');
      expect(result.conflicts, isEmpty);
    });
  });

  group('rule-driven removals', () {
    test('always drops api_proxy_server and the generic ROOM', () {
      final result = map.apply({
        'SYSTEM_SETUP': {
          'api_proxy_server': 'http://cts-metrics:8080/data',
          'ROOM': 'AJH125A',
          'gve_room': '125A',
        },
      });
      final setup = result.config['SYSTEM_SETUP'] as Map;
      expect(setup.containsKey('api_proxy_server'), isFalse);
      expect(setup.containsKey('ROOM'), isFalse);
      expect(setup['gve_room'], '125A', reason: 'the real room id stays');
    });

    test('drops a stray ROOM sitting at the root of the file', () {
      final result = map.apply({
        'ROOM': 'AJH125A',
        'SYSTEM_SETUP': {'gve_room': '125A'},
      });
      expect(result.config.containsKey('ROOM'), isFalse);
    });

    test('drops the power outlets when the room has no power controller', () {
      final result = map.apply({
        'SYSTEM_SETUP': {
          'dev_power_controllers': 'No', // value_map turns this into "0"
          'power1_outlet_1': 'PC',
          'power1_outlet_1_reboot_only': false,
          'power1_outlet_4': 'TLP\\rPoE',
          'power1_outlet_4_reboot_only': false,
        },
      });
      final setup = result.config['SYSTEM_SETUP'] as Map;
      expect(setup.keys.where((k) => k.toString().startsWith('power1_outlet')),
          isEmpty);
    });

    test('keeps the outlets when there IS a power controller', () {
      final result = map.apply({
        'SYSTEM_SETUP': {
          'dev_power_controllers': '1',
          'power1_outlet_1': 'PC',
          'power1_outlet_8': 'USB\\rSwitch',
        },
      });
      final setup = result.config['SYSTEM_SETUP'] as Map;
      expect(setup['power1_outlet_1'], 'PC');
      expect(setup['power1_outlet_8'], 'USB\\rSwitch');
    });

    test('a missing power count is not treated as "no controller"', () {
      // Absent information must never justify deleting data.
      final result = map.apply({
        'SYSTEM_SETUP': {'power1_outlet_1': 'PC'},
      });
      expect((result.config['SYSTEM_SETUP'] as Map)['power1_outlet_1'], 'PC');
    });
  });

  group('section renames are reported for the provenance diff', () {
    test('maps the legacy name to the converted one', () {
      final result = map.apply({
        'SYSTEM': {'dev_cameras': '1'},
        'CAMERA1DEVICE': {'COMTYPE': 'Serial', 'SERIALPORT': 'COM6'},
      });
      expect(result.sectionRenames['CAMERA1DEVICE'], 'CAMERADEVICE_1');
      expect(result.sectionRenames['SYSTEM'], 'SYSTEM_SETUP');
    });
  });

  group('module name normalization', () {
    test('adds the modules.device. prefix to a bare stem', () {
      expect(AppStateProvider.normalizeModuleName('avr_TR311'),
          'modules.device.avr_TR311');
    });

    test('leaves an already-qualified name alone', () {
      expect(AppStateProvider.normalizeModuleName('modules.device.avr_TR311'),
          'modules.device.avr_TR311');
    });

    test('does not double up a half-qualified name', () {
      expect(AppStateProvider.normalizeModuleName('device.avr_TR311'),
          'modules.device.avr_TR311');
      expect(AppStateProvider.normalizeModuleName('devices.avr_TR311'),
          'modules.device.avr_TR311');
      expect(AppStateProvider.normalizeModuleName('modules.avr_TR311'),
          'modules.device.avr_TR311');
    });

    test('strips a .py extension and path separators', () {
      expect(AppStateProvider.normalizeModuleName('device/avr_TR311.py'),
          'modules.device.avr_TR311');
      expect(AppStateProvider.normalizeModuleName(r'device\avr_TR311.py'),
          'modules.device.avr_TR311');
    });

    test('leaves an empty value empty rather than inventing a module', () {
      expect(AppStateProvider.normalizeModuleName(''), '');
      expect(AppStateProvider.normalizeModuleName('   '), '');
    });
  });
}
