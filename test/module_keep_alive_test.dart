import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/ui_schema.dart';

/// Regression cover for AJH125B's switcher.
///
/// A config stores `module` as the import path the processor uses
/// ('modules.device.extr_scaler_...'), but the .py file sits directly under the
/// modules folder. Resolving the file by turning EVERY dot into a separator
/// looked for '<modules>/modules/device/extr_scaler_....py', found nothing, and
/// two things followed: the Keep Alive dropdown came up empty until the module
/// was picked again by hand (which writes the bare stem), and the keep-alive
/// audit had no command list to check against — so the switcher kept the
/// key_map family default 'RefreshMatrix', a command the IN1608 driver doesn't
/// implement, instead of the module's own 'Temperature'.
void main() {
  final String devicePath = path.join(Directory.current.path, 'device');
  // The real driver for AJH125B's 'IN1608 SA': DEVICE_INFO names Temperature,
  // and the file defines no Power or RefreshMatrix at all.
  const String in1608 = 'extr_scaler_IN1606_IN1608_Series_v1_7_0_0';

  AppStateProvider provider() =>
      AppStateProvider(autoLoadSettings: false)..modulesPath = devicePath;

  group('module path resolution', () {
    test('strips the modules.device. import prefix down to the file stem', () {
      expect(AppStateProvider.moduleStem('modules.device.avr_TR311'),
          'avr_TR311');
      expect(AppStateProvider.moduleStem('avr_TR311'), 'avr_TR311');
      expect(AppStateProvider.moduleStem('device.avr_TR311'), 'avr_TR311');
      expect(AppStateProvider.moduleStem('avr_TR311.py'), 'avr_TR311');
      // A sub-foldered module keeps its own dots as folders
      expect(AppStateProvider.moduleStem('modules.device.extron.matrix'),
          'extron.matrix');
    });

    test('both spellings resolve to the same .py file', () {
      final p = provider();
      final dotted = p.modulePyPath('modules.device.$in1608');
      expect(dotted, p.modulePyPath(in1608));
      expect(File(dotted).existsSync(), isTrue,
          reason: 'expected the real driver at $dotted');
      expect(p.modulePyPath(''), '');
    });

    test('the dotted config spelling parses commands (was an empty dropdown)',
        () async {
      final commands =
          await provider().getCommandsForModule('modules.device.$in1608');
      expect(commands, contains('Temperature'));
      expect(commands, isNot(contains('RefreshMatrix')));
    });
  });

  group('keep-alive audit', () {
    test("replaces the family default with the module's own command", () async {
      final p = provider();
      p.uiSchema = await UiSchema.load(explicitPath: 'ui_schema.json');
      await p.preloadAllModules();
      p.roomConfig = {
        'SYSTEM_SETUP': {'dev_switchers': '1'},
        'SWITCHERDEVICE_1': {
          'model': 'IN1608 SA',
          'module': 'modules.device.$in1608',
          // What key_map.json injects for every switcher
          'keep_alive_command': 'RefreshMatrix',
          'keep_alive_interval': 30,
        },
      };

      await p.validateKeepAliveCommands();

      // DEVICE_INFO wins over the family's keepAlivePreference (RefreshMatrix
      // first, then Power) AND over the 'contains power' heuristic, which would
      // otherwise have landed on PowerSaveMode.
      expect(p.roomConfig['SWITCHERDEVICE_1']['keep_alive_command'],
          'Temperature');
      expect(p.systemLogs.any((l) => l.contains('keep_alive_command')), isTrue,
          reason: 'the change must show up in the conversion acknowledgement');
    });

    test('leaves a command the module really implements alone', () async {
      final p = provider();
      p.uiSchema = await UiSchema.load(explicitPath: 'ui_schema.json');
      await p.preloadAllModules();
      p.roomConfig = {
        'SYSTEM_SETUP': {'dev_switchers': '1'},
        'SWITCHERDEVICE_1': {
          'model': 'IN1608 SA',
          'module': 'modules.device.$in1608',
          // A deliberate site choice: not the DEVICE_INFO default, but valid
          'keep_alive_command': 'Input',
        },
      };

      await p.validateKeepAliveCommands();

      expect(p.roomConfig['SWITCHERDEVICE_1']['keep_alive_command'], 'Input');
    });
  });

  group('module_states audit', () {
    // AJH125B's projector: the PT-FW430U driver's SetInput offers Computer 1,
    // Computer 2, Video, S-Video, DVI-I, Network, HDMI — and no HDBaseT, which
    // is what key_map.json injects for every PROJECTORDEVICE_*.
    const String ptfw = 'pana_vp_PTFW4xxEA_Series';

    Future<AppStateProvider> projectorWith(String input) async {
      final p = provider();
      p.uiSchema = await UiSchema.load(explicitPath: 'ui_schema.json');
      await p.preloadAllModules();
      p.roomConfig = {
        'SYSTEM_SETUP': {'dev_projectors': '1'},
        'PROJECTORDEVICE_1': {
          'model': 'PT-FW430U',
          'module': 'modules.device.$ptfw',
          'input': input,
        },
      };
      return p;
    }

    test('flags an input the module does not implement, without changing it',
        () async {
      final p = await projectorWith('HDBaseT');
      await p.validateModuleStateFields();

      final flags = p.systemLogs.where((l) => l.contains('input')).toList();
      expect(flags, hasLength(1));
      expect(flags.single, contains('HDBaseT'));
      expect(flags.single, contains('HDMI')); // lists what the module DOES have
      // Flagged, never guessed at — which port it's wired to is a site fact
      expect(p.roomConfig['PROJECTORDEVICE_1']['input'], 'HDBaseT');
    });

    test('says nothing when the input is a real state of the module', () async {
      final p = await projectorWith('HDMI');
      await p.validateModuleStateFields();
      expect(p.systemLogs, isEmpty);
    });

    test('does not flag an empty input', () async {
      final p = await projectorWith('');
      await p.validateModuleStateFields();
      expect(p.systemLogs, isEmpty);
    });
  });

  group('ENVIRONMENT is opt-in', () {
    test('ui_schema.json no longer injects traceback_allowed on load', () async {
      final schema = await UiSchema.load(explicitPath: 'ui_schema.json');
      expect(schema.sectionDefaults.containsKey('ENVIRONMENT'), isFalse,
          reason: 'a conversion must not turn tracebacks on by itself');
      // The field definition stays, so a room that DOES carry the block gets a
      // proper editor for it.
      expect(schema.specFor('traceback_allowed', sectionKey: 'ENVIRONMENT'),
          isNotNull);
    });
  });
}
