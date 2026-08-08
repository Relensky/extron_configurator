import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/ui_schema.dart';

/// The config items the current ControlScript template reads that the builder
/// did not know about: the share room (a wall of up to 13 panels on one grid
/// page), source sub-switching (a second switcher hanging off one input of the
/// first), the wireless device's GVE id, and the camera response-timeout cap.
///
/// A key the processor reads but the builder never writes is a room setting
/// nobody can reach — it has to be in the template AND described in the schema
/// to be editable, so both halves are asserted here together.
void main() {
  Map<String, dynamic> template() =>
      jsonDecode(File('config.json').readAsStringSync())
          as Map<String, dynamic>;

  Map<String, dynamic> systemSetup() =>
      (template()['SYSTEM_SETUP'] as Map).cast<String, dynamic>();

  Future<UiSchema> schema() => UiSchema.load(explicitPath: 'ui_schema.json');

  /// SYSTEM_SETUP keys read by src/, with the value the template ships.
  const newSystemKeys = <String, Object?>{
    'active_share_room': false,
    'share_room_default_mode': 'combined',
    'sub_switch_sources': '',
    'input_sub_switcher': '',
    'sub_switch_switcher': '2',
  };

  group('SYSTEM_SETUP', () {
    newSystemKeys.forEach((key, shipped) {
      test("the template ships '$key'", () {
        expect(systemSetup().containsKey(key), isTrue);
        expect(systemSetup()[key], shipped,
            reason: 'the shipped value must leave the feature switched off');
      });

      test("'$key' has a schema entry, so it is editable", () async {
        expect((await schema()).specFor(key), isNotNull);
        expect((await schema()).descriptionFor(key), isNotNull);
      });
    });

    test('a loaded room missing them has them injected', () async {
      final s = await schema();
      for (final key in newSystemKeys.keys) {
        expect(s.systemDefaults.containsKey(key), isTrue,
            reason: "an older room has no '$key' until the migration adds it");
      }
    });

    test('display_name_* is described for the share room grid', () async {
      final s = await schema();
      expect(s.descriptionFor('display_name_1'), isNotNull);
      expect(s.descriptionFor('display_name_13'), isNotNull);
    });
  });

  group('device blocks', () {
    test('every projector carries device_role, blank so the model list wins',
        () {
      final config = template();
      final projectors =
          config.keys.where((k) => k.startsWith('PROJECTORDEVICE_'));
      expect(projectors, isNotEmpty);
      for (final key in projectors) {
        expect((config[key] as Map)['device_role'], '', reason: key);
      }
    });

    test('the projector-only keys are scoped to projector tabs', () async {
      final s = await schema();
      for (final key in ['device_role', 'input_individual']) {
        expect(s.deviceSpecFor('PROJECTORDEVICE_1', key), isNotNull);
        expect(s.deviceSpecFor('SWITCHERDEVICE_1', key), isNull,
            reason: '$key means nothing on a switcher');
      }
    });

    test('input_individual is offered on a projector before it exists',
        () async {
      // Absence is meaningful — a screen with no input_individual is not a
      // station — so the key stays OUT of the template and reaches the tab
      // through addIfMissing instead.
      final config = template();
      expect((config['PROJECTORDEVICE_1'] as Map).containsKey('input_individual'),
          isFalse);
      final offered = (await schema())
          .missingFieldsFor('PROJECTORDEVICE_1',
              (config['PROJECTORDEVICE_1'] as Map).keys.map((k) => k.toString()),
              section: (config['PROJECTORDEVICE_1'] as Map)
                  .cast<String, dynamic>())
          .map((s) => s.key);
      expect(offered, contains('input_individual'));
    });
  });

  test('the wizard offers the 13 projector slots a share room can use',
      () async {
    final family = (await schema()).deviceTypes
        .firstWhere((t) => t.countKey == 'dev_projectors');
    expect(family.maxCount, 13,
        reason: 'the processor builds ProjectorHandler_1..13 for a share room');
  });
}
