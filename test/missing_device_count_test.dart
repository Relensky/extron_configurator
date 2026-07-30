import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/config_dictionary.dart';
import 'package:extron_configurator/config_key_mapper.dart';
import 'package:extron_configurator/ui_schema.dart';

/// Regression cover for AJH125B: the legacy file carries a SWITCHERDEVICE
/// block but never declares a dev_Switchers count. The switcher used to
/// survive the key mapping and then get dropped downstream, because the
/// migration injected a count of "0" for the undeclared family and everything
/// after that (device tabs, schematic, export pruning) keys off the count.
///
/// The mapper half is checked here; the migration half — deriving the count
/// from the blocks that exist — lives in AppStateProvider and is covered by
/// the count-derivation test at the bottom, which mirrors that logic against
/// the mapper's real output.
void main() {
  late ConfigKeyMap map;
  late List<String> canonicalKeys;

  setUp(() async {
    map = await ConfigKeyMap.load(explicitPath: 'key_map.json');
    // The app always hands the mapper the canonical vocabulary; without it
    // auto_case_normalization can't run and GVE_ROOM / dev_Wireless never
    // reach their current spellings. Build it exactly as _processLoadedConfig
    // does, so these tests exercise the real conversion path.
    final schema = await UiSchema.load(explicitPath: 'ui_schema.json');
    canonicalKeys = <String>{
      ...ConfigDictionary.descriptions.keys,
      ...schema.exactKeys,
    }.toList();
  });

  /// Runs the mapper the way a real load does.
  KeyMapResult convert(Map<String, dynamic> config) =>
      map.apply(config, canonicalKeys: canonicalKeys);

  /// The shape of AJH125B_old_config.json, trimmed to what matters: a
  /// switcher block, several families the file DOES declare, and a SYSTEM
  /// block with no dev_Switchers anywhere in it.
  Map<String, dynamic> ajh125b() => {
        'SWITCHERDEVICE': {
          'COMTYPE': 'Serial',
          'IPADDRESS': 'N/A - COM1',
          'MODEL': 'IN1608 SA',
          'NETPORT': 23,
          'PASSWORD': 'ATEC2007',
          'SERIALPORT': 'COM1',
          'USER': 'admin',
        },
        'CAMERA1DEVICE': {
          'COMTYPE': 'Serial',
          'MODEL': 'TR311',
          'SERIALPORT': 'COM6',
        },
        'WIRELESSDEVICE': {
          'COMTYPE': 'Network',
          'MODEL': 'Via Go',
        },
        'SYSTEM': {
          'GVE_BLDG': 'AJH',
          'GVE_ROOM': '125B',
          'GVE_ID_Switcher_1': 'Switch1',
          'dev_Cameras': '1',
          'dev_Projectors': '1',
          'dev_Wireless': 'No',
          // NOTE: no dev_Switchers key at all — that is the whole point
        },
      };

  test('an undeclared family keeps its block through the mapping', () {
    final result = convert(ajh125b());

    expect(result.config.containsKey('SWITCHERDEVICE_1'), isTrue,
        reason: 'a missing count must never justify dropping the block');
    final switcher = result.config['SWITCHERDEVICE_1'] as Map;
    expect(switcher['model'], 'IN1608 SA');
    expect(switcher['serial_port'], 'COM1');
    // It is a serial device, so the network-only properties are stripped
    expect(switcher.containsKey('ip_address'), isFalse);
    expect(switcher.containsKey('net_port'), isFalse);
  });

  test('a family the file declares as unused IS dropped', () {
    // dev_Wireless "No" is an explicit statement, unlike a missing key.
    final result = convert(ajh125b());
    expect(result.config.containsKey('WIRELESSDEVICE_1'), isFalse);
  });

  test('the surviving blocks give the count the migration should derive', () {
    // Mirrors AppStateProvider._validateAndMigrateConfig: when the count key
    // is absent, count the numbered blocks of that family instead of
    // assuming zero. Guards the input side of that fix.
    final config = convert(ajh125b()).config;

    int blocksFor(String prefix) => config.keys
        .where((k) =>
            k.startsWith(prefix) &&
            int.tryParse(k.substring(prefix.length)) != null &&
            config[k] is Map)
        .length;

    expect(blocksFor('SWITCHERDEVICE_'), 1,
        reason: 'dev_switchers must be derived as 1, not defaulted to 0');
    expect(blocksFor('WIRELESSDEVICE_'), 0,
        reason: 'an explicitly-unused family really is empty');
  });

  test('the room-level junk this file carries is cleaned up', () {
    final result = convert({
      'SYSTEM': {
        'ROOM': 'AJH125B',
        'api_proxy_server': 'http://cts-metrics:8080/data',
        'GVE_ROOM': '125B',
      },
    });
    final setup = result.config['SYSTEM_SETUP'] as Map;
    expect(setup.containsKey('ROOM'), isFalse);
    expect(setup.containsKey('api_proxy_server'), isFalse);
    expect(setup['gve_room'], '125B');
  });

  test('power outlets go when the file says there is no power controller', () {
    // AJH125B has dev_Power_Control "No" but eight PowerOutlet entries.
    final result = convert({
      'SYSTEM': {
        'dev_Power_Control': 'No',
        'PowerOutlet1': 'PC',
        'PowerOutlet2': 'Switch',
        'PowerOutlet6': 'Doc\rCam',
      },
    });
    final setup = result.config['SYSTEM_SETUP'] as Map;
    expect(setup.keys.where((k) => k.toString().startsWith('power1_outlet')),
        isEmpty);
  });
}
