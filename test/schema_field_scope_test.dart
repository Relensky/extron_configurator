import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/ui_schema.dart';

/// Which fields a block is OFFERED is a schema question, and the shipped
/// ui_schema.json is what the app reads — so the shipped file is what these
/// hold to. A field offered everywhere is a field somebody has to ignore on
/// every device in the room.
void main() {
  late UiSchema schema;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

  List<String> offeredOn(String section, {Map<String, dynamic> block = const {}}) =>
      schema
          .missingFieldsFor(section, block.keys, section: block)
          .map((f) => f.key)
          .toList();

  group('use_device_mute', () {
    test('is offered on the family with a picture to blank', () {
      // PROJECTORDEVICE_* covers both projectors and flat panels — see the
      // device_role field, which is what decides between the two.
      expect(offeredOn('PROJECTORDEVICE_1'), contains('use_device_mute'));
    });

    test('is not offered on anything else', () {
      for (final section in const [
        'CAMERADEVICE_1',
        'DSPDEVICE_1',
        'POWERDEVICE_1',
        'SWITCHERDEVICE_1',
        'WIRELESSDEVICE_1',
        'USBDEVICE_1',
        'SCREENDEVICE_1',
        'RECORDERDEVICE_1',
        'MEDIAPORTDEVICE_1',
      ]) {
        expect(
          offeredOn(section),
          isNot(contains('use_device_mute')),
          reason: '$section has no picture of its own to mute',
        );
      }
    });

    test('still renders where a block already carries one', () {
      // Only the OFFER is scoped: a legacy camera block with the key in it
      // keeps its type and description rather than turning into an unknown.
      final spec = schema.specFor('use_device_mute', sectionKey: 'CAMERADEVICE_1');
      expect(spec, isNotNull);
      expect(spec!.type, 'bool');
      expect(schema.descriptionFor('use_device_mute'), isNotNull);
    });
  });

  group('device_id', () {
    test('is not put on every device', () {
      // Every driver in the library declares it None, so nothing was ever
      // going to fill the field it was adding to all of them.
      for (final section in const [
        'PROJECTORDEVICE_1',
        'CAMERADEVICE_1',
        'POWERDEVICE_1',
        'SWITCHERDEVICE_1',
      ]) {
        expect(offeredOn(section), isNot(contains('device_id')));
      }
    });

    test('still renders where a block carries one', () {
      final spec = schema.specFor('device_id', sectionKey: 'CAMERADEVICE_1');
      expect(spec, isNotNull);
      expect(schema.descriptionFor('device_id'), isNotNull);
    });
  });

  group('SYSTEM_SETUP', () {
    test('always declares the debug server and the event space', () {
      // Every room answers these two, so a converted file that is silent about
      // them gets them on load.
      expect(schema.systemDefaults.containsKey('active_debug_server'), isTrue);
      expect(schema.systemDefaults.containsKey('active_event_space'), isTrue);
      // Off is the answer for a room nobody has asked about.
      expect(schema.systemDefaults['active_debug_server'], false);
      expect(schema.systemDefaults['active_event_space'], false);
    });

    test('never declares the conference display inputs', () {
      // They belong to Conference mode and to nothing else, so no room is
      // given them on the way in.
      expect(schema.systemDefaults.containsKey('conf_display_1'), isFalse);
      expect(schema.systemDefaults.containsKey('conf_display_2'), isFalse);
    });
  });

  group('a conference-only field', () {
    test('is hidden unless the room is in Conference mode', () {
      for (final mode in const ['Normal', 'Extended', '']) {
        expect(
          schema.isHiddenFor(
            'conf_display_1',
            {'gui_routing_mode': mode},
            sectionKey: 'SYSTEM_SETUP',
          ),
          isTrue,
          reason: 'a $mode room has no conference switcher to point at',
        );
      }
    });

    test('is shown in a Conference room, whatever the case', () {
      for (final mode in const ['Conference', 'conference']) {
        for (final key in const ['conf_display_1', 'conf_display_2']) {
          expect(
            schema.isHiddenFor(
              key,
              {'gui_routing_mode': mode},
              sectionKey: 'SYSTEM_SETUP',
            ),
            isFalse,
          );
        }
      }
    });
  });

  group('default_input', () {
    test('is offered on USB switchers and nowhere else', () {
      expect(offeredOn('USBDEVICE_1'), contains('default_input'));
      expect(offeredOn('USBDEVICE_2'), contains('default_input'));
      for (final section in const [
        'PROJECTORDEVICE_1',
        'SWITCHERDEVICE_1',
        'CAMERADEVICE_1',
        'DSPDEVICE_1',
        'MEDIAPORTDEVICE_1',
      ]) {
        expect(
          offeredOn(section),
          isNot(contains('default_input')),
          reason: '$section has no USB host to park on',
        );
      }
    });

    test('a new USB block is created sitting on input 1', () {
      expect(schema.defaultsFor('USBDEVICE_1')['default_input'], '1');
      expect(schema.defaultsFor('USBDEVICE_2')['default_input'], '1');
      expect(
        schema.defaultsFor('PROJECTORDEVICE_1').containsKey('default_input'),
        isFalse,
      );
    });

    test('offers only the two inputs the switchers have', () {
      // The processor rejects anything but 1 or 2 and falls back to 1, so the
      // dropdown must not be able to write a third value into the config.
      final spec = schema.specFor('default_input', sectionKey: 'USBDEVICE_1');
      expect(spec, isNotNull);
      expect(spec!.type, 'dropdown');
      expect(spec.options.map((o) => o.value), ['1', '2']);
    });
  });

  group('the != condition', () {
    test('reads the key and the value off either side of it', () {
      final spec = FieldSpec(key: 'x', hideWhen: ['mode!=Conference']);
      expect(spec.isHiddenIn({'mode': 'Normal'}), isTrue);
      expect(spec.isHiddenIn({'mode': 'Conference'}), isFalse);
      // An absent key is not the value, so the field is hidden.
      expect(spec.isHiddenIn(const {}), isTrue);
    });

    test('leaves plain = and ~ alone', () {
      final equals = FieldSpec(key: 'x', hideWhen: ['com_type=Serial']);
      expect(equals.isHiddenIn({'com_type': 'Serial'}), isTrue);
      expect(equals.isHiddenIn({'com_type': 'Network'}), isFalse);

      final contains = FieldSpec(key: 'x', hideWhen: ['name~rack']);
      expect(contains.isHiddenIn({'name': 'Equipment Rack'}), isTrue);
      expect(contains.isHiddenIn({'name': 'Lectern'}), isFalse);
    });
  });
}
