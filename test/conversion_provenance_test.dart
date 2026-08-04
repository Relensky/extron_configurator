import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/config_key_mapper.dart';

/// The colouring on the conversion screen (and on the Devices / System tabs)
/// is only worth anything if it says the right thing about each value. Three
/// states, and this pins what puts a value in each one:
///
///   legacy   the loaded file's value, untouched
///   changed  the key came from the file, the conversion rewrote the value
///   written  the conversion introduced the key
void main() {
  /// A provider with [file] as the parsed original and [now] as the working
  /// config, with the provenance diff already run.
  AppStateProvider diffed(
    Map<String, dynamic> file,
    Map<String, dynamic> now, {
    Map<String, String> renames = const {},
    List<ConversionConflict> conflicts = const [],
  }) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..originalLoadedConfig = file
      ..roomConfig = now;
    p.computeConversionProvenance(renames, conflicts);
    return p;
  }

  ConversionChange? changeFor(AppStateProvider p, String id) {
    for (final c in p.conversionChanges) {
      if (c.id == id) return c;
    }
    return null;
  }

  group('the three states', () {
    test('an untouched value is legacy', () {
      final p = diffed(
        {'SYSTEM_SETUP': {'gve_room': '125B'}},
        {'SYSTEM_SETUP': {'gve_room': '125B'}},
      );
      expect(p.originFor('SYSTEM_SETUP', 'gve_room'), ValueOrigin.legacy);
      expect(p.conversionChanges, isEmpty);
    });

    test('a value the conversion rewrote is changed, not legacy', () {
      // The building-code normalization: the key is the old file's, the value
      // on screen is the conversion's. Calling that "from the old file" sent
      // the tech looking in the wrong place.
      final p = diffed(
        {'SYSTEM_SETUP': {'gve_bldg': 'BEHAVIORAL AND SOCIAL SCIENCE'}},
        {'SYSTEM_SETUP': {'gve_bldg': 'BSS'}},
      );
      expect(p.originFor('SYSTEM_SETUP', 'gve_bldg'), ValueOrigin.changed);
      expect(changeFor(p, 'SYSTEM_SETUP.gve_bldg')?.kind,
          ConversionKind.changed);
    });

    test('a key the conversion introduced is written', () {
      final p = diffed(
        {'SYSTEM_SETUP': {'gve_room': '125B'}},
        {
          'SYSTEM_SETUP': {'gve_room': '125B'},
          'ENVIRONMENT': {'controlscript_profile': 'pro'},
        },
      );
      expect(p.originFor('ENVIRONMENT', 'controlscript_profile'),
          ValueOrigin.written);
      expect(changeFor(p, 'ENVIRONMENT.controlscript_profile')?.kind,
          ConversionKind.added);
    });

    test('a renamed key with the same value is still legacy', () {
      // auto_case_normalization renames COMTYPE -> com_type. The VALUE is what
      // is being coloured, and it did not move.
      final p = diffed(
        {'PROJECTORDEVICE': {'COMTYPE': 'Serial'}},
        {'PROJECTORDEVICE_1': {'com_type': 'Serial'}},
        renames: {'PROJECTORDEVICE': 'PROJECTORDEVICE_1'},
      );
      expect(p.originFor('PROJECTORDEVICE_1', 'com_type'), ValueOrigin.legacy);
    });
  });

  group('root-level scalars', () {
    // startup_watchdog_stage sits at the root of a downloaded config — the
    // processor writes it there. Every non-Map used to be skipped by the diff,
    // so it had no origin at all: drawn as legacy whatever had happened to it,
    // and absent from the change list.
    test('one the file carried, unchanged, is legacy', () {
      final p = diffed(
        {'startup_watchdog_stage': 0},
        {'startup_watchdog_stage': 0},
      );
      expect(p.originFor('startup_watchdog_stage', ''), ValueOrigin.legacy);
      expect(p.conversionChanges, isEmpty);
    });

    test('one the conversion rewrote is changed, and rejectable', () {
      final p = diffed(
        {'startup_watchdog_stage': 3},
        {'startup_watchdog_stage': 0},
      );
      expect(p.originFor('startup_watchdog_stage', ''), ValueOrigin.changed);
      final change = changeFor(p, 'startup_watchdog_stage.');
      expect(change, isNotNull);
      expect(change!.kind, ConversionKind.changed);
      expect(change.label, 'startup_watchdog_stage',
          reason: 'no key, so the list must not print a trailing dot');

      // Rejecting it puts the file's value back — the root entry itself, not a
      // property inside a block that isn't there.
      change.accepted = false;
      p.applyConversionChoices();
      expect(p.roomConfig['startup_watchdog_stage'], 3);
    });

    test('one the conversion added is written, and rejectable', () {
      final p = diffed({}, {'startup_watchdog_stage': 0});
      expect(p.originFor('startup_watchdog_stage', ''), ValueOrigin.written);

      changeFor(p, 'startup_watchdog_stage.')!.accepted = false;
      p.applyConversionChoices();
      expect(p.roomConfig.containsKey('startup_watchdog_stage'), isFalse);
    });

    test('one the conversion dropped is reported as removed', () {
      // The 'ROOM' removal rule drops a stray label at the root of the file.
      final p = diffed({'ROOM': 'AJH125A'}, {});
      final change = changeFor(p, 'ROOM.');
      expect(change, isNotNull, reason: 'a drop must not happen silently');
      expect(change!.kind, ConversionKind.removed);
      expect(change.before, 'AJH125A');

      change.accepted = false;
      p.applyConversionChoices();
      expect(p.roomConfig['ROOM'], 'AJH125A');
    });
  });

  group('rejecting a change recolours the field', () {
    test('a rejected rewrite reads as the old file again', () {
      final p = diffed(
        {'SYSTEM_SETUP': {'gve_bldg': 'BEHAVIORAL AND SOCIAL SCIENCE'}},
        {'SYSTEM_SETUP': {'gve_bldg': 'BSS'}},
      );
      changeFor(p, 'SYSTEM_SETUP.gve_bldg')!.accepted = false;
      p.applyConversionChoices();

      expect((p.roomConfig['SYSTEM_SETUP'] as Map)['gve_bldg'],
          'BEHAVIORAL AND SOCIAL SCIENCE');
      expect(p.originFor('SYSTEM_SETUP', 'gve_bldg'), ValueOrigin.legacy,
          reason: 'the value on screen is the old file\'s again');
    });

    test('a rejected addition has no colour at all', () {
      final p = diffed(
        {'SYSTEM_SETUP': {}},
        {'SYSTEM_SETUP': {'use_qos': true}},
      );
      changeFor(p, 'SYSTEM_SETUP.use_qos')!.accepted = false;
      p.applyConversionChoices();

      expect(p.originFor('SYSTEM_SETUP', 'use_qos'), isNull);
    });
  });

  group('a value the user sets loses its colour', () {
    // Orange says "carried over from the old file, nobody has checked it".
    // Once the tech has set the value themselves that is no longer true of
    // it, so the field goes back to the theme's ordinary colour — otherwise
    // the one signal telling them what still needs checking never shrinks.
    test('typing over a legacy value clears it', () {
      final p = diffed(
        {'SYSTEM_SETUP': {'gve_room': '125B'}},
        {'SYSTEM_SETUP': {'gve_room': '125B'}},
      );
      expect(p.originFor('SYSTEM_SETUP', 'gve_room'), ValueOrigin.legacy);

      p.updateDeviceValue('SYSTEM_SETUP', 'gve_room', '125');
      expect(p.originFor('SYSTEM_SETUP', 'gve_room'), isNull);
    });

    test('the neighbours keep theirs', () {
      final p = diffed(
        {'SYSTEM_SETUP': {'gve_room': '125B', 'gve_bldg': 'AJH'}},
        {'SYSTEM_SETUP': {'gve_room': '125B', 'gve_bldg': 'AJH'}},
      );
      p.updateDeviceValue('SYSTEM_SETUP', 'gve_room', '125');

      expect(p.originFor('SYSTEM_SETUP', 'gve_bldg'), ValueOrigin.legacy,
          reason: 'editing one field must not clear the whole room');
    });

    test('a device value the conversion rewrote clears too', () {
      final p = diffed(
        {'PROJECTORDEVICE_1': {'input': 'HDMI 1'}},
        {'PROJECTORDEVICE_1': {'input': 'HDBaseT'}},
      );
      expect(p.originFor('PROJECTORDEVICE_1', 'input'), ValueOrigin.changed);

      p.updateDeviceValue('PROJECTORDEVICE_1', 'input', 'HDMI 2');
      expect(p.originFor('PROJECTORDEVICE_1', 'input'), isNull);
    });

    test('picking a model clears every value it applies', () {
      final p = diffed(
        {'PROJECTORDEVICE_1': {'model': 'Old Model', 'protocol': 'TCP'}},
        {'PROJECTORDEVICE_1': {'model': 'Old Model', 'protocol': 'TCP'}},
      );
      // No registry entry in a bare provider, so only the model itself is
      // written — which is exactly the value whose colour must go.
      p.applyModuleDefaults('PROJECTORDEVICE_1', 'VPL-PHZ60');

      expect(p.originFor('PROJECTORDEVICE_1', 'model'), isNull);
      expect(p.originFor('PROJECTORDEVICE_1', 'protocol'), ValueOrigin.legacy,
          reason: 'a value the model change did not touch is still the file\'s');
    });

    test('deleting a key takes its colour with it', () {
      // Check Defaults can re-add the key later; it should come back as a
      // fresh value, not wearing the colour the conversion gave the old one.
      final p = diffed(
        {'SYSTEM_SETUP': {'pcmac': 'aa-bb-cc'}},
        {'SYSTEM_SETUP': {'pcmac': 'aa-bb-cc'}},
      );
      p.removeConfigKey('SYSTEM_SETUP', 'pcmac');
      p.addConfigKey('SYSTEM_SETUP', 'pcmac', '11-22-33');

      expect(p.originFor('SYSTEM_SETUP', 'pcmac'), isNull);
    });
  });
}
