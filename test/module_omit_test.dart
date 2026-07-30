import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/ui_schema.dart';

/// The defaults that shape a device block are FAMILY-wide: key_map.json gives
/// every SWITCHERDEVICE_* the seven `group_*` audio group numbers, and
/// ui_schema.json does the same. Right for a matrix acting as the room's audio
/// hub, wrong for a plain scaler — an IN1608 ends up carrying group numbers
/// nothing reads.
///
/// A module says so itself via DEVICE_INFO "omit", and the load strips them.
void main() {
  final String devicePath = path.join(Directory.current.path, 'device');
  const String in1608 = 'modules.device.extr_scaler_IN1606_IN1608_Series_v1_7_0_0';
  const String crossPoint = 'modules.device.extr_matrix_DTPCrossPoint_86_1084K';

  Future<AppStateProvider> loaded() async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..modulesPath = devicePath
      ..uiSchema = await UiSchema.load(explicitPath: 'ui_schema.json');
    await p.preloadAllModules();
    return p;
  }

  /// A converted switcher block, as key_map.json leaves it.
  Map<String, dynamic> switcherWith(String module) => {
        'model': 'whatever',
        'module': module,
        'btn_name': 'Btn_Con_Switcher1',
        'group_ceil_mute': '4',
        'group_mic_gain': '10',
        'group_mic_mute': '2',
        'group_prog_gain': '1',
        'group_prog_mute': '5',
        'group_room_mute': '3',
        'group_voice_lift_mute': '7',
      };

  group('pattern matching', () {
    test('globs match a prefix, case-insensitively', () {
      const patterns = ['group_*'];
      expect(AppStateProvider.keyMatchesOmitPattern('group_prog_gain', patterns),
          isTrue);
      expect(AppStateProvider.keyMatchesOmitPattern('GROUP_PROG_GAIN', patterns),
          isTrue,
          reason: 'a legacy block may still be upper-cased at this point');
      expect(AppStateProvider.keyMatchesOmitPattern('grouping', patterns),
          isFalse);
      expect(AppStateProvider.keyMatchesOmitPattern('btn_name', patterns),
          isFalse);
    });

    test('an exact key with no glob matches only itself', () {
      expect(AppStateProvider.keyMatchesOmitPattern('input', ['input']), isTrue);
      expect(AppStateProvider.keyMatchesOmitPattern('input_pc', ['input']),
          isFalse);
    });

    test('no patterns matches nothing', () {
      expect(AppStateProvider.keyMatchesOmitPattern('group_prog_gain', const []),
          isFalse);
    });
  });

  group('the modules that opt out', () {
    test('every switcher we listed declares omit group_*', () async {
      final p = await loaded();
      const expected = [
        'extr_sm_NAVigator_v1_0_1_4',
        'extr_scaler_IN1606_IN1608_Series_v1_7_0_0',
        'extr_scaler_IN1608xi_Series_v1_1_3_0',
        'extr_scaler_IN1804_Series_v1_2_4_0',
        'extr_scaler_IN2004_Series_v1_0_3_0',
        'extr_Scaler_IN806_IN1808_Series_v1_1_6_0',
        'extr_switcher_SW_HD_4K_PLUS_Series_v1_1_9_0',
        'extr_switcher_SW_HD_4K_Plus_Series_v1_1_5_0',
        'extr_other_DTP_HD_DA4_4K_Series_v1_2_0_0',
      ];
      for (final module in expected) {
        expect(p.moduleOmitsFor(module), contains('group_*'),
            reason: '$module should list group_* as unused');
      }
    });

    test('the matrices and DSPs do NOT opt out', () async {
      final p = await loaded();
      // These really are the room's audio hub — they keep their group numbers.
      for (final module in const [
        'extr_matrix_DTPCrossPoint_86_1084K',
        'extr_matrix_DTP2CrossPoint_82_v1_1_0_0',
        'extr_dsp_DMP_64_Plus_Series',
      ]) {
        expect(p.moduleOmitsFor(module), isEmpty, reason: module);
      }
    });
  });

  group('stripping on load', () {
    test('a scaler loses the family group_ defaults', () async {
      final p = await loaded();
      p.roomConfig = {
        'SYSTEM_SETUP': {'dev_switchers': '1'},
        'SWITCHERDEVICE_1': switcherWith(in1608),
      };

      p.applyModuleOmissions();

      final dev = p.roomConfig['SWITCHERDEVICE_1'] as Map;
      expect(dev.keys.where((k) => k.toString().startsWith('group_')), isEmpty);
      // Everything else is untouched
      expect(dev['btn_name'], 'Btn_Con_Switcher1');
      expect(dev['module'], in1608);
      expect(dev['model'], 'whatever');
      // Each removal is reported, so it shows in the conversion log
      expect(p.systemLogs.where((l) => l.contains('group_')), hasLength(7));
    });

    test('a matrix keeps them', () async {
      final p = await loaded();
      p.roomConfig = {
        'SYSTEM_SETUP': {'dev_switchers': '1'},
        'SWITCHERDEVICE_1': switcherWith(crossPoint),
      };

      p.applyModuleOmissions();

      final dev = p.roomConfig['SWITCHERDEVICE_1'] as Map;
      expect(dev['group_prog_gain'], '1');
      expect(dev.keys.where((k) => k.toString().startsWith('group_')),
          hasLength(7));
      expect(p.systemLogs, isEmpty);
    });

    test('a device with no module resolved is left alone', () async {
      final p = await loaded();
      p.roomConfig = {
        'SYSTEM_SETUP': {'dev_switchers': '1'},
        'SWITCHERDEVICE_1': switcherWith(''),
      };

      p.applyModuleOmissions();

      expect((p.roomConfig['SWITCHERDEVICE_1'] as Map)['group_prog_gain'], '1');
    });
  });

  group('Check Defaults', () {
    test('does not offer an omitted key back', () async {
      final p = await loaded();
      p.roomConfig = {
        'SYSTEM_SETUP': {'dev_switchers': '1'},
        // Post-strip: the group keys are gone, so they'd normally read as
        // "missing" and be offered again.
        'SWITCHERDEVICE_1': {'model': 'IN1608 SA', 'module': in1608},
      };

      final missing = await p.missingDefaultsFor('SWITCHERDEVICE_1');

      expect(missing.keys.where((k) => k.startsWith('group_')), isEmpty,
          reason: 'Check Defaults must not undo the omission');
    });
  });
}
