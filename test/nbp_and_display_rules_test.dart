import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/ui_schema.dart';

/// Three features arrived in the ControlScript template at once, and each one
/// asks something of the schema that nothing before it did:
///
///   * NETWORK BUTTON PANELS are the first device family with NO CONNECTION —
///     no com_type, no address, no module. The connection fields are gated on
///     com_type, so a family that has none would be offered every one of them;
///   * PER-DISPLAY SOURCE RULES put four keys on the projector blocks whose
///     absence has to keep meaning "behave as before";
///   * ANNEX MUTE and the ROOM-MODE keys are ordinary SYSTEM_SETUP settings,
///     but a room that never heard of them must still load unchanged.
void main() {
  late UiSchema schema;
  late Map<String, dynamic> template;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
    template = Map<String, dynamic>.from(
        jsonDecode(File('config.json').readAsStringSync()) as Map);
  });

  Map<String, dynamic> setup() =>
      Map<String, dynamic>.from(template['SYSTEM_SETUP'] as Map);

  group('the button panel family', () {
    test('is a family the wizard manages', () {
      final spec = schema.deviceTypes
          .where((t) => t.countKey == 'dev_nbps')
          .toList();
      expect(spec, hasLength(1));
      expect(spec.single.prefix, 'NBPDEVICE_');
      expect(schema.deviceTypeForSection('NBPDEVICE_2')?.countKey, 'dev_nbps');
    });

    test('the template ships one, and it carries no connection', () {
      final block = template['NBPDEVICE_1'];
      expect(block, isA<Map>());
      final nbp = Map<String, dynamic>.from(block as Map);

      for (final key in const [
        'com_type', 'ip_address', 'net_port', 'protocol', 'service_port',
        'user', 'password', 'serial_port', 'baud', 'module', 'model',
      ]) {
        expect(nbp.containsKey(key), isFalse,
            reason: 'a UI device has no $key');
      }
      // What it does carry: the alias that IS its address, the display it
      // owns, and the buttons.
      expect(nbp['alias'], isNotEmpty);
      expect(nbp['display'], isA<int>());
      expect(nbp['sources'], isA<List>());
      expect((nbp['sources'] as List), hasLength(3));
      expect(nbp['element_ids'], isA<Map>());
      for (final key in const [
        'volume_default', 'volume_min', 'volume_max', 'volume_step',
      ]) {
        expect(nbp[key], isA<int>(), reason: key);
      }
    });

    /// The failure this guards against is silent: `hideWhen` is written against
    /// com_type, an NBP has none, so every condition reads false and the whole
    /// connection would be offered on the tab and written in on first edit.
    test('the connection fields are not offered on its tab', () {
      final block = Map<String, dynamic>.from(template['NBPDEVICE_1'] as Map);
      for (final key in const [
        'com_type', 'ip_address', 'net_port', 'protocol', 'service_port',
        'user', 'password', 'serial_port', 'baud', 'model', 'module',
        'lbl_name', 'btn_name', 'manual_disconnect', 'keep_alive_command',
        'keep_alive_interval', 'keep_alive_qualifier', 'keep_alive_trigger',
      ]) {
        final spec = schema.specFor(key, sectionKey: 'NBPDEVICE_1');
        expect(spec?.addIfMissing, isFalse,
            reason: '$key must not be added to a button panel');
      }
      // ... while its own keys are.
      for (final key in const [
        'alias', 'display', 'volume_default', 'volume_step',
      ]) {
        expect(schema.specFor(key, sectionKey: 'NBPDEVICE_1')?.addIfMissing,
            isTrue,
            reason: key);
      }
      expect(block.keys, isNotEmpty);
    });

    test('the two structured keys are not drawn as text boxes', () {
      // 'sources' is a list of objects and 'element_ids' a map. The device tab
      // renders scalars, so a text box there would turn either into a string.
      for (final key in const ['sources', 'element_ids']) {
        expect(schema.specFor(key, sectionKey: 'NBPDEVICE_1')?.type, 'hidden',
            reason: key);
        expect(schema.descriptionFor(key, sectionKey: 'NBPDEVICE_1'),
            isNotNull,
            reason: '$key still needs its description for the info button');
      }
    });

    test('a new panel gets a distinct alias, not a copy of panel 1', () {
      final p = AppStateProvider(autoLoadSettings: false)..uiSchema = schema;
      p.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{'dev_nbps': '0'};
      p.setDeviceCount('dev_nbps', 'NBPDEVICE_', 3,
          p.getDefaultDeviceBlock('NBPDEVICE_'));

      final aliases = [
        for (int i = 1; i <= 3; i++)
          (p.roomConfig['NBPDEVICE_$i'] as Map)['alias'].toString(),
      ];
      expect(aliases.toSet(), hasLength(3), reason: aliases.toString());
      expect(aliases[1], contains('2'));
      expect(aliases[2], contains('3'));
    });
  });

  group('the per-display source rules', () {
    test('every projector block in the template carries them', () {
      for (final key in template.keys.where(
          (k) => k.startsWith('PROJECTORDEVICE_'))) {
        final block = Map<String, dynamic>.from(template[key] as Map);
        expect(block['source_follow'], isTrue, reason: key);
        expect(block['presenter_follow'], isTrue, reason: key);
        expect(block.containsKey('source_fixed'), isTrue, reason: key);
        expect(block['source_overrides'], isA<Map>(), reason: key);
      }
    });

    test('they are scoped to displays and nowhere else', () {
      for (final key in const [
        'source_follow', 'source_fixed', 'presenter_follow',
      ]) {
        expect(schema.deviceSpecFor('PROJECTORDEVICE_1', key), isNotNull,
            reason: key);
        expect(schema.deviceSpecFor('CAMERADEVICE_1', key), isNull,
            reason: '$key means nothing on a camera');
      }
    });

    /// source_overrides WAS hidden, like the NBP maps: it is an object, and
    /// the device tab renders scalars. It is the one screen rule a tech
    /// actually reaches for, though, so it has an editor of its own rather
    /// than braces typed on the Raw JSON tab — 'source_map', which draws one
    /// row of two room-source dropdowns per substitution.
    test('source_overrides has the map editor, not a text box', () {
      final spec =
          schema.specFor('source_overrides', sectionKey: 'PROJECTORDEVICE_1');
      expect(spec?.type, 'source_map');
      // Offered on a projector that predates the key, like its three siblings.
      expect(spec?.addIfMissing, isTrue);
      expect(schema.descriptionFor('source_overrides',
              sectionKey: 'PROJECTORDEVICE_1'),
          isNotNull);
      // And nowhere else: a camera has no source to substitute.
      expect(schema.deviceSpecFor('CAMERADEVICE_1', 'source_overrides'), isNull);
    });
  });

  /// The processor mutes the room's microphones as it shuts down and unmutes
  /// them at startup, unless these two keys say otherwise. Absent means ON, so
  /// the only thing the config has to get right is that a room which states
  /// them states the value the processor would have used anyway — otherwise
  /// the baseline quietly changes what every new room does overnight.
  group('the shutdown mic mutes', () {
    const keys = ['shutdown_mute_ceiling_mics', 'shutdown_mute_mics'];

    test('both audio blocks in the template state them, and state ON', () {
      for (final section in const ['DSPDEVICE_1', 'SWITCHERDEVICE_1']) {
        final block = Map<String, dynamic>.from(template[section] as Map);
        for (final key in keys) {
          expect(block[key], isTrue,
              reason: '$section.$key must state the processor\'s own default');
        }
      }
    });

    test('they are scoped to the blocks that carry the mic groups', () {
      for (final key in keys) {
        for (final section in const ['DSPDEVICE_1', 'SWITCHERDEVICE_1']) {
          final spec = schema.deviceSpecFor(section, key);
          expect(spec, isNotNull, reason: '$key on $section');
          expect(spec!.type, 'bool', reason: '$key on $section');
          expect(spec.addIfMissing, isTrue, reason: '$key on $section');
          expect(schema.descriptionFor(key, sectionKey: section), isNotNull,
              reason: '$key on $section');
        }
        // A second switcher is a sub-switcher with no mic groups on it, and a
        // projector has no microphones at all.
        for (final section in const ['SWITCHERDEVICE_2', 'PROJECTORDEVICE_1']) {
          expect(schema.deviceSpecFor(section, key), isNull,
              reason: '$key means nothing on $section');
        }
      }
    });

    test('a new DSP or first switcher is created with them', () {
      final p = AppStateProvider(autoLoadSettings: false)..uiSchema = schema;
      p.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{
        'dev_dsps': '0',
        'dev_switchers': '0',
      };
      p.setDeviceCount('dev_dsps', 'DSPDEVICE_', 1,
          p.getDefaultDeviceBlock('DSPDEVICE_'));
      p.setDeviceCount('dev_switchers', 'SWITCHERDEVICE_', 2,
          p.getDefaultDeviceBlock('SWITCHERDEVICE_'));

      for (final section in const ['DSPDEVICE_1', 'SWITCHERDEVICE_1']) {
        final block = p.roomConfig[section] as Map;
        for (final key in keys) {
          expect(block[key], isTrue, reason: '$section.$key');
        }
      }
    });
  });

  group('the projector relay port', () {
    test('every projector block names its own port', () {
      // Absent, the processor falls back to RLY<n> for projector <n>. The
      // template states it so the tech can see which relay a box is on
      // without opening the rack, and the stated value has to BE that
      // default or the template quietly re-wires every room built from it.
      for (final key in template.keys
          .where((k) => k.startsWith('PROJECTORDEVICE_'))) {
        final n = key.split('_').last;
        expect((template[key] as Map)['relay_port'], 'RLY$n', reason: key);
      }
    });

    test('it is offered on projectors and nowhere else', () {
      expect(schema.deviceSpecFor('PROJECTORDEVICE_1', 'relay_port'), isNotNull);
      for (final section in const ['SCREENDEVICE_1', 'CAMERADEVICE_1']) {
        expect(schema.deviceSpecFor(section, 'relay_port'), isNull,
            reason: '$section has no relay_port; a screen names three of its '
                'own (relay_port_up/_down/_stop)');
      }
    });

    test('a new projector gets its own relay, not a copy of RLY1', () {
      // setDeviceCount clones PROJECTORDEVICE_1, so without the trailing-index
      // substitution all four blocks would name RLY1 and every projector on
      // the panel would fire the first projector's relay.
      final p = AppStateProvider(autoLoadSettings: false)..uiSchema = schema;
      p.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{'dev_projectors': '1'};
      p.roomConfig['PROJECTORDEVICE_1'] =
          Map<String, dynamic>.from(template['PROJECTORDEVICE_1'] as Map);
      p.setDeviceCount('dev_projectors', 'PROJECTORDEVICE_', 4,
          p.getDefaultDeviceBlock('PROJECTORDEVICE_'));

      final ports = [
        for (int i = 1; i <= 4; i++)
          (p.roomConfig['PROJECTORDEVICE_$i'] as Map)['relay_port'],
      ];
      expect(ports, const ['RLY1', 'RLY2', 'RLY3', 'RLY4']);
    });
  });

  group('annex mute and the room-mode keys', () {
    test('the template states them all', () {
      final s = setup();
      for (final key in const [
        'gui_presenter_mode_available', 'gui_annex_mute_available',
        'annex_mute_label', 'annex_mute_output', 'annex_mute_channels',
        'dev_source_control', 'dev_volume_control',
        'display_min_volume', 'display_max_volume', 'dev_nbps',
      ]) {
        expect(s.containsKey(key), isTrue, reason: '$key missing from config.json');
        expect(schema.descriptionFor(key), isNotNull,
            reason: '$key has no description');
      }
    });

    test('the two buttons ship off, since both need a layout object', () {
      final s = setup();
      expect(s['gui_presenter_mode_available'], 'No');
      expect(s['gui_annex_mute_available'], 'No');
    });

    test('the room-mode keys default to Auto and offer every mode', () {
      final s = setup();
      expect(s['dev_source_control'], 'Auto');
      expect(s['dev_volume_control'], 'Auto');

      final source = schema.specFor('dev_source_control')!;
      expect(source.options.map((o) => o.value),
          containsAll(['Auto', 'Switcher', 'Display']));
      final volume = schema.specFor('dev_volume_control')!;
      expect(volume.options.map((o) => o.value),
          containsAll(['Auto', 'DSP', 'Switcher', 'Display']));
    });

    test('a room that never heard of them still gets them on load', () {
      // system_defaults is what the migration injects, and a huddle room
      // converted from an older file has to come out with a stated mode
      // rather than a blank one.
      for (final key in const [
        'dev_source_control', 'dev_volume_control',
        'gui_presenter_mode_available', 'gui_annex_mute_available',
      ]) {
        expect(schema.systemDefaults.containsKey(key), isTrue, reason: key);
      }
    });
  });
}
