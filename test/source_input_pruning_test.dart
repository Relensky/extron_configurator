import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/ui_schema.dart';

/// A room's source list is spelled in gui_tab_type ("DOC_USB_WL") and its
/// camera count in dev_cameras; the switcher input each source lands on is a
/// key of its own. Nothing tied the two together, so a room retyped down from
/// six sources kept shipping input_dvd and input_blu_ray — input numbers for
/// buttons the panel does not draw, pointing at switcher inputs something else
/// is now plugged into.
///
/// Which key each source token entitles the room to is schema-driven
/// (ui_schema.json "source_inputs"), so nothing here is hardcoded in the app.
void main() {
  /// Every input key the shipped template carries, so a prune has something
  /// to take away in each direction.
  Map<String, dynamic> setupWith({
    required String tabType,
    required String cameras,
  }) => {
    'gve_bldg': 'BSS',
    'gve_room': '103',
    'gui_inputs': '6',
    'gui_tab_type': tabType,
    'dev_cameras': cameras,
    'input_pc': '1',
    'input_pc_extended': '2',
    'input_hdmi': '4',
    'input_usb': '5',
    'input_doc_cam': '6',
    'input_wireless': '3',
    'input_dvd': '2',
    'input_blu_ray': '7',
    'input_inst_cam': '8',
    'input_aud_cam': '9',
    'input_sub_switcher': '',
    'output_audio': '1',
  };

  Map<String, dynamic> setupOf(AppStateProvider p) =>
      (p.roomConfig['SYSTEM_SETUP'] as Map).cast<String, dynamic>();

  List<String> inputKeys(AppStateProvider p) =>
      setupOf(p).keys.where((k) => k.startsWith('input_')).toList()..sort();

  group('SourceInputRules', () {
    const rules = SourceInputRules.builtIn;

    test('a tab type entitles the room to exactly its own sources', () {
      expect(
        rules.expectedKeys(tabType: 'DOC_USB_WL', cameraCount: 0),
        {
          'input_pc',
          'input_hdmi',
          'input_pc_extended',
          'input_sub_switcher',
          'input_doc_cam',
          'input_usb',
          'input_wireless',
        },
      );
    });

    test('VGA and USB are the same physical input, so one key covers both', () {
      expect(
        rules.expectedKeys(tabType: 'DOC_VGA_WL', cameraCount: 0),
        contains('input_usb'),
      );
    });

    test('cameras add their inputs only once the room has one', () {
      expect(
        rules.expectedKeys(tabType: '3_WL', cameraCount: 0),
        isNot(contains('input_inst_cam')),
      );
      expect(
        rules.expectedKeys(tabType: '3_WL', cameraCount: 2),
        containsAll(['input_inst_cam', 'input_aud_cam']),
      );
    });

    test('an input key the rules never named is not theirs to remove', () {
      expect(
        rules.staleKeysIn({
          'gui_tab_type': 'DOC_USB_WL',
          'dev_cameras': '0',
          'input_something_new': '4',
        }),
        isEmpty,
      );
    });

    test('the shipped ui_schema.json says the same thing the built-in does',
        () async {
      final loaded = await UiSchema.load(explicitPath: 'ui_schema.json');
      expect(loaded.sourceInputs.tokens, rules.tokens);
      expect(loaded.sourceInputs.always, rules.always);
      expect(loaded.sourceInputs.cameras, rules.cameras);
    });

    test('a config that never said what its sources are keeps them all', () {
      // A silence is a question, not a No. Removing these on the first load of
      // the oldest, least reproducible configs would delete real site data.
      expect(
        rules.staleKeysIn({
          'dev_cameras': '0',
          'input_dvd': '2',
          'input_blu_ray': '7',
          'input_doc_cam': '6',
        }),
        isEmpty,
      );
    });

    test('a config with no camera count keeps its camera inputs', () {
      expect(
        rules.staleKeysIn({
          'gui_tab_type': 'DOC_USB_WL',
          'input_inst_cam': '8',
          'input_dvd': '2',
        }),
        ['input_dvd'],
        reason: 'the sources ARE stated, so input_dvd still goes',
      );
    });

    test('an empty ruleset strips nothing at all', () {
      expect(
        const SourceInputRules().staleKeysIn({
          'gui_tab_type': 'WL',
          'input_dvd': '2',
        }),
        isEmpty,
      );
    });
  });

  group('pruning a loaded room', () {
    test('DOC_USB_WL with no cameras keeps only its own inputs', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig['SYSTEM_SETUP'] = setupWith(
          tabType: 'DOC_USB_WL',
          cameras: '0',
        );

      expect(p.pruneUnusedSourceInputs(), 4);

      expect(inputKeys(p), [
        'input_doc_cam',
        'input_hdmi',
        'input_pc',
        'input_pc_extended',
        'input_sub_switcher',
        'input_usb',
        'input_wireless',
      ]);
      // Nothing outside the input vocabulary is touched.
      expect(setupOf(p)['output_audio'], '1');
      expect(setupOf(p)['gve_bldg'], 'BSS');
    });

    test('the same room WITH cameras keeps the camera inputs', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig['SYSTEM_SETUP'] = setupWith(
          tabType: 'DOC_USB_WL',
          cameras: '2',
        );

      p.pruneUnusedSourceInputs();

      expect(inputKeys(p), containsAll(['input_inst_cam', 'input_aud_cam']));
      expect(inputKeys(p), isNot(contains('input_dvd')));
    });

    test('a six-source room loses nothing but the cameras', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig['SYSTEM_SETUP'] = setupWith(
          tabType: 'BR_DOC_USB_WL',
          cameras: '0',
        );

      p.pruneUnusedSourceInputs();

      expect(inputKeys(p), contains('input_blu_ray'));
      expect(inputKeys(p), isNot(contains('input_dvd')));
      expect(inputKeys(p), isNot(contains('input_inst_cam')));
    });
  });

  group('changing the sources on the System tab', () {
    test('retyping the tab type prunes what the room no longer has', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig['SYSTEM_SETUP'] = setupWith(
          tabType: 'BR_DOC_USB_WL',
          cameras: '0',
        );

      p.updateDeviceValue('SYSTEM_SETUP', 'gui_tab_type', 'DOC_USB_WL');

      expect(inputKeys(p), isNot(contains('input_blu_ray')));
      expect(setupOf(p)['input_doc_cam'], '6');
    });

    test('changing your mind puts the input number back, not a blank', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig['SYSTEM_SETUP'] = setupWith(
          tabType: 'BR_DOC_USB_WL',
          cameras: '0',
        );

      p.updateDeviceValue('SYSTEM_SETUP', 'gui_tab_type', 'DOC_USB_WL');
      expect(inputKeys(p), isNot(contains('input_blu_ray')));

      p.updateDeviceValue('SYSTEM_SETUP', 'gui_tab_type', 'BR_DOC_USB_WL');
      expect(setupOf(p)['input_blu_ray'], '7');
    });

    test('a restore never overwrites a value the room has since regained', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig['SYSTEM_SETUP'] = setupWith(
          tabType: 'BR_DOC_USB_WL',
          cameras: '0',
        );

      p.updateDeviceValue('SYSTEM_SETUP', 'gui_tab_type', 'DOC_USB_WL');
      setupOf(p)['input_blu_ray'] = 'typed by hand';
      p.updateDeviceValue('SYSTEM_SETUP', 'gui_tab_type', 'BR_DOC_USB_WL');

      expect(setupOf(p)['input_blu_ray'], 'typed by hand');
    });
  });

  group('the wizard camera count', () {
    test('dropping cameras to 0 takes the camera inputs with them', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig['SYSTEM_SETUP'] = setupWith(
          tabType: 'DOC_USB_WL',
          cameras: '2',
        );

      p.setDeviceCount('dev_cameras', 'CAMERADEVICE_', 0, {});

      expect(inputKeys(p), isNot(contains('input_inst_cam')));
      expect(inputKeys(p), isNot(contains('input_aud_cam')));
    });

    test('putting a camera back restores the numbers it had', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig['SYSTEM_SETUP'] = setupWith(
          tabType: 'DOC_USB_WL',
          cameras: '2',
        );

      p.setDeviceCount('dev_cameras', 'CAMERADEVICE_', 0, {});
      p.setDeviceCount('dev_cameras', 'CAMERADEVICE_', 1, {});

      expect(setupOf(p)['input_inst_cam'], '8');
      expect(setupOf(p)['input_aud_cam'], '9');
    });

    test('a different family at 0 leaves the camera inputs alone', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig['SYSTEM_SETUP'] = setupWith(
          tabType: 'DOC_USB_WL',
          cameras: '2',
        );

      p.setDeviceCount('dev_projectors', 'PROJECTORDEVICE_', 0, {});

      expect(setupOf(p)['input_inst_cam'], '8');
    });
  });

  group('a new file from the template', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('source_input_pruning_test_');
    });
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('starts with no camera inputs, and gains them with a camera',
        () async {
      final templatePath = path.join(dir.path, 'config.json');
      File(templatePath).writeAsStringSync(
        jsonEncode({
          'SYSTEM_SETUP': setupWith(tabType: 'DOC_USB_WL', cameras: '2'),
          'CAMERADEVICE_1': {'name': 'Camera 1', 'module': ''},
        }),
      );
      final p = AppStateProvider(autoLoadSettings: false)
        ..templateFilePath = templatePath;

      expect(await p.createNewConfig(), isTrue);

      expect(setupOf(p)['dev_cameras'], '0');
      expect(inputKeys(p), isNot(contains('input_inst_cam')));
      // The sources the template DID name are untouched by the reset.
      expect(setupOf(p)['input_doc_cam'], '6');
      expect(inputKeys(p), isNot(contains('input_dvd')));

      p.setDeviceCount(
        'dev_cameras',
        'CAMERADEVICE_',
        1,
        p.getDefaultDeviceBlock('CAMERADEVICE_'),
      );
      expect(setupOf(p)['input_inst_cam'], '8');
    });
  });
}
