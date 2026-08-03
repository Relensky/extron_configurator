import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';

/// Outlet names with no power controller behind them are dead data: they ship
/// to the processor and the tech still has to read past them on the System tab.
/// key_map.json already dropped them when an existing config was LOADED; these
/// cover the wizard side — a new file, and the count dropdown.
///
/// Which keys a family owns is schema-driven (device_types "systemKeys"), so
/// nothing here is hardcoded to power controllers in the app.
void main() {
  late Directory dir;
  late String templatePath;

  /// SYSTEM_SETUP as the shipped template has it: outlet names present, one
  /// power controller, plus keys that must survive whatever happens.
  Map<String, dynamic> templateSetup() => {
        'gve_bldg': 'BSS',
        'gve_room': '103',
        'dev_power_controllers': '1',
        'dev_projectors': '1',
        'power1_outlet_1': 'Projector',
        'power1_outlet_2': 'Rack Fan',
        'power1_outlet_2_supports_reboot': true,
        'power1_outlet_3': '',
        'gui_demo_mode': false,
        'conf_display_1': '1',
      };

  setUp(() {
    dir = Directory.systemTemp.createTempSync('power_outlet_pruning_test_');
    templatePath = path.join(dir.path, 'config.json');
    File(templatePath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': templateSetup(),
      'POWERDEVICE_1': {'name': 'Power 1', 'module': ''},
      'PROJECTORDEVICE_1': {'name': 'Projector 1', 'module': ''},
    }));
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, dynamic> setupOf(AppStateProvider p) =>
      (p.roomConfig['SYSTEM_SETUP'] as Map).cast<String, dynamic>();

  List<String> outletKeys(AppStateProvider p) => setupOf(p)
      .keys
      .where((k) => k.toLowerCase().startsWith('power1_outlet_'))
      .toList()
    ..sort();

  test('a new file from the template carries no outlet settings', () async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..templateFilePath = templatePath;

    expect(await p.createNewConfig(), isTrue);

    expect(setupOf(p)['dev_power_controllers'], '0');
    expect(outletKeys(p), isEmpty,
        reason: 'no power controller chosen, so no outlet settings');
    // Everything that isn't a power-controller setting stays put.
    expect(setupOf(p)['gve_bldg'], 'BSS');
    expect(setupOf(p)['gui_demo_mode'], false);
    expect(setupOf(p)['conf_display_1'], '1');
    expect(setupOf(p)['dev_projectors'], '0');
  });

  test('choosing a power controller in the wizard brings them back', () async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..templateFilePath = templatePath;
    await p.createNewConfig();
    expect(outletKeys(p), isEmpty);

    p.setDeviceCount('dev_power_controllers', 'POWERDEVICE_', 1,
        p.getDefaultDeviceBlock('POWERDEVICE_'));

    expect(setupOf(p)['power1_outlet_1'], 'Projector');
    expect(setupOf(p)['power1_outlet_2'], 'Rack Fan');
    expect(setupOf(p)['power1_outlet_2_supports_reboot'], true);
    expect(setupOf(p)['power1_outlet_3'], '',
        reason: 'a blank outlet name is still a real key');
  });

  group('the wizard count dropdown', () {
    AppStateProvider loadedRoom() => AppStateProvider(autoLoadSettings: false)
      ..roomConfig['SYSTEM_SETUP'] = templateSetup();

    test('dropping power controllers to 0 removes the outlet settings', () {
      final p = loadedRoom();

      p.setDeviceCount('dev_power_controllers', 'POWERDEVICE_', 0, {});

      expect(outletKeys(p), isEmpty);
      expect(setupOf(p)['dev_power_controllers'], '0');
    });

    test('a different family at 0 leaves the outlets alone', () {
      final p = loadedRoom();

      p.setDeviceCount('dev_projectors', 'PROJECTORDEVICE_', 0, {});

      expect(outletKeys(p), [
        'power1_outlet_1',
        'power1_outlet_2',
        'power1_outlet_2_supports_reboot',
        'power1_outlet_3',
      ]);
    });

    test('0 then back to 2 restores the values that were there', () {
      final p = loadedRoom();
      setupOf(p)['power1_outlet_1'] = 'Custom Name';

      p.setDeviceCount('dev_power_controllers', 'POWERDEVICE_', 0, {});
      expect(outletKeys(p), isEmpty);

      p.setDeviceCount('dev_power_controllers', 'POWERDEVICE_', 2, {});
      expect(setupOf(p)['power1_outlet_1'], 'Custom Name',
          reason: 'the edited name should survive a mind change');
      expect(setupOf(p)['dev_power_controllers'], '2');
    });

    test('a restore never overwrites a value the room has since regained', () {
      final p = loadedRoom();

      p.setDeviceCount('dev_power_controllers', 'POWERDEVICE_', 0, {});
      setupOf(p)['power1_outlet_1'] = 'Typed By Hand';
      p.setDeviceCount('dev_power_controllers', 'POWERDEVICE_', 1, {});

      expect(setupOf(p)['power1_outlet_1'], 'Typed By Hand');
    });

    test('loading another room drops the stash, so nothing leaks across',
        () async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..templateFilePath = templatePath;
      p.roomConfig['SYSTEM_SETUP'] = templateSetup();
      p.setDeviceCount('dev_power_controllers', 'POWERDEVICE_', 0, {});

      // A new room, then a power controller chosen in it.
      await p.createNewConfig();
      p.setDeviceCount('dev_power_controllers', 'POWERDEVICE_', 1, {});

      // The values restored are this template's, not the previous room's.
      expect(setupOf(p)['power1_outlet_1'], 'Projector');
    });
  });
}
