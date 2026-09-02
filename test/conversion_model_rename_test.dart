import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/config_key_mapper.dart';

/// ============================================================================
///  A ROOM THAT NAMES A SUPERSEDED BOX
/// ============================================================================
///  A room documented before a product was replaced still names the old one,
///  and the model name is the only thing tying a device to a driver: the
///  conversion carries `module` over from the template block whose model
///  matches. 'AV Bridge' matches nothing, so a converted room came out with no
///  module at all and somebody had to know to go and pick one.
///
///  Everything runs through the real key_map.json, so what is under test is
///  what ships.
/// ============================================================================
void main() {
  late ConfigKeyMap map;

  setUp(() async {
    map = await ConfigKeyMap.load(explicitPath: 'key_map.json');
  });

  Map<String, dynamic> roomWith(Map<String, dynamic> recorder) => {
        'SYSTEM_SETUP': {'dev_recorders': '1'},
        'RECORDERDEVICE_1': recorder,
      };

  test('an AV Bridge becomes an AV Bridge 2x1, with its driver', () {
    final result = map.apply(roomWith({
      'model': 'AV Bridge',
      'com_type': 'Network',
      'ip_address': '192.168.254.60',
    }));
    final dev = result.config['RECORDERDEVICE_1'] as Map;

    expect(dev['model'], 'AV Bridge 2x1');
    expect(dev['module'], 'modules.device.vadd_switcher_AV_Bridge_2x1');
    // The rename is why the module could be found at all, so the audit says
    // so — a model quietly rewritten under somebody is the kind of change
    // that has to be readable afterwards.
    expect(
      result.changes.any((c) =>
          c.contains('RECORDERDEVICE_1.model') && c.contains('AV Bridge 2x1')),
      isTrue,
    );
  });

  test('however the old name was written down', () {
    for (final spelling in const ['av bridge', 'AVBridge', 'AV  Bridge']) {
      final result = map.apply(roomWith({'model': spelling}));
      expect((result.config['RECORDERDEVICE_1'] as Map)['model'],
          'AV Bridge 2x1',
          reason: spelling);
    }
  });

  test('and the generated name follows the model, not the old one', () {
    final result = map.apply(roomWith({'model': 'AV Bridge'}));
    expect((result.config['RECORDERDEVICE_1'] as Map)['name'],
        'Recorder - AV Bridge 2x1');
  });

  test('a room that already names its own driver is left alone', () {
    // Somebody chose this. A conversion that overrules a decision already
    // made is worse than one that does nothing.
    final result = map.apply(roomWith({
      'model': 'AV Bridge',
      'module': 'modules.device.some_other_driver',
    }));
    final dev = result.config['RECORDERDEVICE_1'] as Map;

    expect(dev['model'], 'AV Bridge');
    expect(dev['module'], 'modules.device.some_other_driver');
  });

  test('a 2x1 already named keeps its driver anyway', () {
    final result = map.apply(roomWith({'model': 'AV Bridge 2x1'}));
    final dev = result.config['RECORDERDEVICE_1'] as Map;

    expect(dev['model'], 'AV Bridge 2x1');
    expect(dev['module'], 'modules.device.vadd_switcher_AV_Bridge_2x1');
  });

  test('the rename is scoped to the family it belongs to', () {
    // 'AV Bridge' means the recorder in a RECORDERDEVICE block. It is not a
    // license to rewrite the words wherever else they turn up.
    final result = map.apply({
      'SYSTEM_SETUP': {'dev_cameras': '1'},
      'CAMERADEVICE_1': {'model': 'AV Bridge'},
    });
    expect((result.config['CAMERADEVICE_1'] as Map)['model'], 'AV Bridge');
  });
}
