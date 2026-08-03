import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';

/// Two things that have to hold for the app to stop showing stale data:
///
///  * [AppStateProvider.configRevision] moves whenever the working config is
///    replaced. The views key their fields on it, because `initialValue` is
///    read once per element — without a new key, the previous room's name and
///    number stayed on the Wizard until the user changed tabs and came back.
///  * app_config.json lives outside the app folder, so copying a new build
///    over the installed one cannot take the user's settings with it.
void main() {
  late Directory dir;
  late String templatePath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('config_identity_test_');
    templatePath = path.join(dir.path, 'config.json');
    File(templatePath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {
        'gve_bldg': 'BSS',
        'gve_room': '103',
        'gui_full_room_name': 'Behavioral And Social Science 103',
        'dev_dsps': '2',
      },
      'DSPDEVICE_1': {'name': 'DSP 1', 'module': ''},
    }));
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppStateProvider providerOnTemplate() =>
      AppStateProvider(autoLoadSettings: false)..templateFilePath = templatePath;

  group('configRevision', () {
    test('a new config from the template is a different room', () async {
      final p = providerOnTemplate();
      final before = p.configRevision;

      expect(await p.createNewConfig(), isTrue);

      expect(p.configRevision, greaterThan(before),
          reason: 'the Wizard must repaint instead of keeping the old room');
    });

    test('editing a value in place is NOT a new room', () async {
      final p = providerOnTemplate();
      await p.createNewConfig();
      final after = p.configRevision;

      p.updateDeviceValue('DSPDEVICE_1', 'name', 'Main DSP');

      expect(p.configRevision, after,
          reason: 'keying on every keystroke would drop focus mid-typing');
    });

    test('applying raw JSON is a different room', () {
      final p = providerOnTemplate();
      final before = p.configRevision;

      p.updateConfigFromRawJson('{"SYSTEM_SETUP": {"gve_room": "204"}}');

      expect(p.configRevision, greaterThan(before));
    });

    test('a new config starts on a blank schematic', () async {
      final p = providerOnTemplate();
      p.setSchematicPosition('DSPDEVICE_1', const Offset(40, 40));
      p.addSchematicLink('PROCESSOR', 'DSPDEVICE_1', '42A5F5', 'net');

      await p.createNewConfig();

      expect(p.hasSchematicLayout, isFalse);
    });
  });

  group('settings file location', () {
    test('is not the folder a deploy overwrites', () {
      expect(AppStateProvider.resolvedSettingsFilePath(),
          isNot(AppStateProvider.legacySettingsFilePath()),
          reason:
              'copying a build over the installed app replaced app_config.json');
    });

    test('is in the per-user settings folder', () {
      final resolved = AppStateProvider.resolvedSettingsFilePath();
      expect(path.basename(resolved), 'app_config.json');

      final env = Platform.environment;
      final base = Platform.isWindows
          ? (env['APPDATA'] ?? env['LOCALAPPDATA'] ?? '')
          : (env['XDG_CONFIG_HOME'] ?? env['HOME'] ?? '');
      if (base.isEmpty) return; // no per-user folder to check against here
      expect(path.isWithin(base, resolved), isTrue,
          reason: '$resolved should sit under $base');
    });
  });
}
