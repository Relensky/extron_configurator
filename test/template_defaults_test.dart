import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/config_key_mapper.dart';

/// Guards the shipped template (config.json) against re-growing defaults that
/// have been retired. A key removed from the template but left in the file the
/// wizard copies comes straight back on the next "New Config".
void main() {
  Map<String, dynamic> template() =>
      jsonDecode(File('config.json').readAsStringSync())
          as Map<String, dynamic>;

  Map<String, dynamic> systemSetup() =>
      (template()['SYSTEM_SETUP'] as Map).cast<String, dynamic>();

  group('api_proxy_server is retired', () {
    test('the template no longer offers it as a default', () {
      expect(systemSetup().containsKey('api_proxy_server'), isFalse,
          reason: 'METRICS_CONFIG (uri + bearer) replaced it');
    });

    test('METRICS_CONFIG is what carries the metrics endpoint now', () {
      final metrics = template()['METRICS_CONFIG'];
      expect(metrics, isA<Map>());
      expect((metrics as Map)['uri'].toString(), isNotEmpty);
      expect(metrics['bearer'].toString(), isNotEmpty,
          reason: 'the processor raises at startup on enabled + blank bearer');
    });

    test('a legacy config that still has it is still cleaned on load',
        () async {
      // The other half of the retirement: key_map.json drops the key from an
      // older room, so removing it from the template can never resurrect it.
      final keyMap = await ConfigKeyMap.load(explicitPath: 'key_map.json');
      final result = keyMap.apply({
        'SYSTEM_SETUP': {
          'api_proxy_server': 'http://10.255.4.52:8080/data',
          'gve_room': '103',
        },
      });

      final setup = (result.config['SYSTEM_SETUP'] as Map);
      expect(setup.containsKey('api_proxy_server'), isFalse);
      expect(setup['gve_room'], '103');
    });
  });

  group('gve_id_wireless_1 is retired', () {
    test('the template no longer offers it as a default', () {
      expect(systemSetup().containsKey('gve_id_wireless_1'), isFalse,
          reason: "a device's GVE id belongs in that device's own block");
    });

    test('the wireless device block is where the gve_id lives', () {
      final wireless = template()['WIRELESSDEVICE_1'];
      expect(wireless, isA<Map>());
      expect((wireless as Map)['gve_id'].toString(), isNotEmpty);
    });

    test('a legacy config that still has it is cleaned on load', () async {
      final keyMap = await ConfigKeyMap.load(explicitPath: 'key_map.json');
      final result = keyMap.apply({
        'SYSTEM_SETUP': {'gve_id_wireless_1': 'Wireless1', 'gve_room': '103'},
      });
      final setup = (result.config['SYSTEM_SETUP'] as Map);
      expect(setup.containsKey('gve_id_wireless_1'), isFalse);
      expect(setup['gve_room'], '103');
    });
  });

  group('use_device_mute belongs to the displays', () {
    test('no other family carries it in the template', () {
      // The wizard deep-copies the template block when it creates a device, so
      // a key left on the wrong family here is written into every new room's
      // camera and switcher — for a setting only a display has a picture to
      // act on, and only PROJECTORDEVICE_* is offered it in the schema.
      final carriers = [
        for (final entry in template().entries)
          if (entry.value is Map &&
              (entry.value as Map).containsKey('use_device_mute'))
            entry.key,
      ]..sort();

      expect(
        carriers,
        ['PROJECTORDEVICE_1', 'PROJECTORDEVICE_2', 'PROJECTORDEVICE_3',
          'PROJECTORDEVICE_4'],
      );
    });
  });

  group('the USB switcher home input', () {
    test('the template names one, so a new room is deterministic', () {
      // The processor drives this input at startup and the morning restart
      // toggles away from it and back. Absent, the room comes up on whatever
      // the switcher was left on.
      final usb = template()['USBDEVICE_1'];
      expect(usb, isA<Map>());
      expect((usb as Map)['default_input'], '1');
    });
  });

  group('pcmac is retired', () {
    test('the template no longer offers it as a default', () {
      expect(systemSetup().containsKey('pcmac'), isFalse,
          reason: 'no ControlScript template reads it');
    });

    test('a legacy config that still has it is cleaned on load', () async {
      final keyMap = await ConfigKeyMap.load(explicitPath: 'key_map.json');
      final result = keyMap.apply({
        'SYSTEM_SETUP': {'pcmac': '00:11:22:33:44:55', 'gve_room': '103'},
      });
      final setup = (result.config['SYSTEM_SETUP'] as Map);
      expect(setup.containsKey('pcmac'), isFalse);
      expect(setup['gve_room'], '103');
    });
  });
}
