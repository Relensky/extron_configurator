import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/config_dictionary.dart';
import 'package:extron_configurator/config_key_mapper.dart';
import 'package:extron_configurator/ui_schema.dart';

/// Every outlet a room actually has should come out of a load carrying its two
/// reboot flags — `_supports_reboot` and `_reboot_only`, which are the whole
/// story now that `_action` is retired. The gating is free: outlet keys are
/// stripped earlier in the pipeline when the room declares no power
/// controller, so by the time companions run there is nothing to attach them
/// to.
void main() {
  late ConfigKeyMap map;
  late List<String> canonicalKeys;

  setUp(() async {
    map = await ConfigKeyMap.load(explicitPath: 'key_map.json');
    final schema = await UiSchema.load(explicitPath: 'ui_schema.json');
    canonicalKeys = <String>{
      ...ConfigDictionary.descriptions.keys,
      ...schema.exactKeys,
    }.toList();
  });

  Map<String, dynamic> convert(Map<String, dynamic> config) =>
      map.apply(config, canonicalKeys: canonicalKeys).config;

  /// A legacy room with three outlets, as the file on disk spells them.
  Map<String, dynamic> legacyRoom({required String powerCount}) => {
        'SYSTEM': <String, dynamic>{
          'GVE_BLDG': 'BSS',
          'GVE_ROOM': '461',
          'dev_Power_Control': powerCount,
          'PowerOutlet1': 'PC',
          'PowerOutlet2': 'Switch',
          'PowerOutlet3': 'Doc\rCam',
        },
        'POWERDEVICE': {
          'COMTYPE': 'Network',
          'MODEL': 'AP7900B',
        },
      };

  test('each outlet gains both reboot flags', () {
    final setup =
        convert(legacyRoom(powerCount: 'Yes'))['SYSTEM_SETUP'] as Map;

    for (final n in const [1, 2, 3]) {
      expect(setup['power1_outlet_${n}_supports_reboot'], isTrue,
          reason: 'outlet $n should default to reboot supported');
      expect(setup['power1_outlet_${n}_reboot_only'], isFalse,
          reason: 'outlet $n should not default to reboot-only');
    }
    // ...and nothing recreates the retired third key
    expect(setup.keys.where((k) => k.toString().endsWith('_action')), isEmpty);
  });

  test('only for the outlets that exist', () {
    final setup =
        convert(legacyRoom(powerCount: 'Yes'))['SYSTEM_SETUP'] as Map;

    // Three outlets in, three sets of flags out — no outlet 4.
    expect(setup.keys.where((k) => k.toString().endsWith('_supports_reboot')),
        hasLength(3));
    expect(setup.containsKey('power1_outlet_4_supports_reboot'), isFalse);
  });

  test('a value already in the file is never overwritten', () {
    final room = legacyRoom(powerCount: 'Yes');
    (room['SYSTEM'] as Map)['power1_outlet_2_supports_reboot'] = false;
    (room['SYSTEM'] as Map)['power1_outlet_2_reboot_only'] = true;

    final setup = convert(room)['SYSTEM_SETUP'] as Map;

    expect(setup['power1_outlet_2_supports_reboot'], isFalse);
    expect(setup['power1_outlet_2_reboot_only'], isTrue);
    // ...while its neighbours still get the defaults
    expect(setup['power1_outlet_1_supports_reboot'], isTrue);
  });

  test('a room with no power controller gets none of it', () {
    // The outlet keys themselves are removed upstream when the room declares
    // no power controller, so there is nothing for the companions to attach to.
    final setup = convert(legacyRoom(powerCount: 'No'))['SYSTEM_SETUP'] as Map;

    expect(setup.keys.where((k) => k.toString().startsWith('power1_outlet_')),
        isEmpty);
  });

  test('the flags do not breed companions of their own', () {
    final setup =
        convert(legacyRoom(powerCount: 'Yes'))['SYSTEM_SETUP'] as Map;

    // The rules are end-anchored, so power1_outlet_1_supports_reboot can't
    // itself match and spawn power1_outlet_1_supports_reboot_supports_reboot.
    expect(setup.keys.where((k) => k.toString().contains('reboot_only_')),
        isEmpty);
    expect(
        setup.keys
            .where((k) => k.toString().contains('supports_reboot_supports')),
        isEmpty);
  });
}
