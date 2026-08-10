import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';

/// Unit tests for the DEVICE_INFO / self.Models parsing that feeds the
/// device-tab Model dropdown and the connection-defaults apply.
void main() {
  group('AppStateProvider.parseDeviceInfo', () {
    test('parses a JSON-style DEVICE_INFO dict', () {
      const py = '''
from extronlib.interface import EthernetClientInterface

DEVICE_INFO = {
    "device_type": "dsp",
    "models": ["DMP 64 Plus C", "DMP 64 Plus C V"],
    "connection": {
        "com_type": "Network",
        "protocol": "TCP",
        "net_port": 22023
    },
    "defaults": {
        "keep_alive_command": "RefreshMatrix",
        "keep_alive_interval": 30
    }
}

class DeviceClass:
    pass
''';
      final info = AppStateProvider.parseDeviceInfo('test.py', py);
      expect(info, isNotNull);
      expect(info!['device_type'], 'dsp');
      expect(info['models'], ['DMP 64 Plus C', 'DMP 64 Plus C V']);
      expect(info['connection'],
          {'com_type': 'Network', 'protocol': 'TCP', 'net_port': 22023});
      expect(info['defaults'],
          {'keep_alive_command': 'RefreshMatrix', 'keep_alive_interval': 30});
    });

    test('tolerates Python syntax: single quotes, comments, trailing commas, True/None', () {
      const py = '''
DEVICE_INFO = {
    'models': [
        'VPL-PHZ60',  # newest first
    ],
    'connection': {
        'protocol': 'TCP',
        'net_port': 53595,
        'manual_disconnect': False,
        'device_id': None,
    },
}
''';
      final info = AppStateProvider.parseDeviceInfo('test.py', py);
      expect(info, isNotNull);
      expect(info!['models'], ['VPL-PHZ60']);
      expect(info['connection'], {
        'protocol': 'TCP',
        'net_port': 53595,
        'manual_disconnect': false,
        'device_id': null,
      });
    });

    test('returns null when no DEVICE_INFO exists', () {
      expect(AppStateProvider.parseDeviceInfo('t.py', 'class DeviceClass:\n    pass\n'),
          isNull);
    });

    test('ignores an indented (non-module-level) DEVICE_INFO', () {
      const py = '''
class DeviceClass:
    DEVICE_INFO = {"models": ["X"]}
''';
      expect(AppStateProvider.parseDeviceInfo('t.py', py), isNull);
    });
  });

  group('device_type filtering', () {
    AppStateProvider seeded() {
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.modelRegistry['VPL-PHZ60'] = const ModelEntry(
          model: 'VPL-PHZ60',
          module: 'sony_vp_VPL_P_Series',
          explicit: true,
          deviceTypes: ['projector']);
      provider.modelRegistry['ME501'] = const ModelEntry(
          model: 'ME501',
          module: 'nec_display_MExx1_Series_v1_0_0_0',
          explicit: true,
          deviceTypes: ['display']); // label word of the projector family
      provider.modelRegistry['TR311HW'] = const ModelEntry(
          model: 'TR311HW',
          module: 'avr_TR311',
          explicit: true,
          deviceTypes: ['camera']);
      provider.modelRegistry['Mystery'] = const ModelEntry(
          model: 'Mystery',
          module: 'igen_switcher_Toggle',
          explicit: false); // untyped fallback — shows everywhere
      return provider;
    }

    test('projector tab lists only typed projector + display models '
        '(untyped hidden)', () {
      final provider = seeded();
      // Mystery (untyped self.Models fallback) is excluded — checkbox-only.
      expect(provider.availableModelsFor('PROJECTORDEVICE_1'),
          ['ME501', 'VPL-PHZ60']);
    });

    test('camera tab lists only typed camera models (untyped hidden)', () {
      final provider = seeded();
      // Mystery (untyped) no longer leaks into the camera tab.
      expect(provider.availableModelsFor('CAMERADEVICE_2'), ['TR311HW']);
    });

    test('a key outside every known family is never filtered '
        '(untyped models still show)', () {
      final provider = seeded();
      expect(provider.availableModelsFor('SOMETHINGELSE_1').length, 4);
    });

    test('type matching tolerates case, plurals, and the DEVICE suffix', () {
      final provider = AppStateProvider(autoLoadSettings: false);
      const entry = ModelEntry(
          model: 'X', module: 'm', explicit: true, deviceTypes: ['Projectors']);
      expect(provider.modelMatchesDevice(entry, 'PROJECTORDEVICE_3'), isTrue);
      expect(provider.modelMatchesDevice(entry, 'SCREENDEVICE_1'), isFalse);
    });
  });

  group('AppStateProvider.parseSelfModels', () {
    test('returns the keys of self.Models', () {
      const py = '''
        self.Models = {
            'DMP 64 Plus C': self.extr_25_4445_64,
            'DMP 64 Plus C AT': self.extr_25_4445_64AT,
        }
''';
      expect(AppStateProvider.parseSelfModels(py),
          ['DMP 64 Plus C', 'DMP 64 Plus C AT']);
    });

    test('empty self.Models yields no models', () {
      expect(AppStateProvider.parseSelfModels('self.Models = {}'), isEmpty);
    });
  });

  group('AppStateProvider model selection (preview / apply / keep)', () {
    test('previewModelSelection reports module change + diffs and index '
        'substitution, without mutating the config', () {
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.roomConfig['DSPDEVICE_3'] = <String, dynamic>{
        'model': '',
        'module': 'old_module',
        'protocol': 'SSH', // differs from module default TCP
        'name': 'DSP - DMP 64 Plus C AT', // equal to default -> not a diff
        'btn_name': 'Btn_Con_DSP3', // equal after index sub -> not a diff
      };
      provider.modelRegistry['DMP 64 Plus C'] = const ModelEntry(
          model: 'DMP 64 Plus C',
          module: 'extr_dsp_DMP_64_Plus_Series',
          explicit: true);
      provider.moduleDefaults['extr_dsp_DMP_64_Plus_Series'] = {
        'protocol': 'TCP',
        'net_port': 22023,
        'name': 'DSP - DMP 64 Plus C AT',
        'btn_name': 'Btn_Con_DSP1',
        'gve_id': 'DSP1',
        'ip_address': '', // blank default vs missing key -> not a diff
      };

      final preview =
          provider.previewModelSelection('DSPDEVICE_3', 'DMP 64 Plus C');

      expect(preview.known, isTrue);
      expect(preview.moduleChanged, isTrue);
      // The registry is keyed by the bare file stem; what lands in the config
      // (and what the dialog quotes) is always the dotted import path.
      expect(preview.newModule, 'modules.device.extr_dsp_DMP_64_Plus_Series');
      // Trailing index substituted for device 3.
      expect(preview.resolvedDefaults['btn_name'], 'Btn_Con_DSP3');
      expect(preview.resolvedDefaults['gve_id'], 'DSP3');

      final diffKeys = preview.diffs.map((d) => d.key).toSet();
      expect(diffKeys, containsAll(<String>['protocol', 'net_port', 'gve_id']));
      expect(diffKeys, isNot(contains('name')));
      expect(diffKeys, isNot(contains('btn_name'))); // equal after sub
      expect(diffKeys, isNot(contains('ip_address'))); // blank == missing

      // Read-only: nothing changed on the device.
      expect(provider.roomConfig['DSPDEVICE_3']['module'], 'old_module');
      expect(provider.roomConfig['DSPDEVICE_3']['protocol'], 'SSH');
    });

    test('applyModuleDefaults sets model, switches module, and writes all '
        'resolved defaults (index substituted)', () {
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.roomConfig['DSPDEVICE_2'] = <String, dynamic>{
        'model': '',
        'module': 'old_module',
        'protocol': 'SSH',
        'name': 'DSP',
      };
      provider.modelRegistry['DMP 64 Plus C'] = const ModelEntry(
          model: 'DMP 64 Plus C',
          module: 'extr_dsp_DMP_64_Plus_Series',
          explicit: true);
      provider.moduleDefaults['extr_dsp_DMP_64_Plus_Series'] = {
        'com_type': 'Network',
        'protocol': 'TCP',
        'net_port': 22023,
        'keep_alive_command': 'RefreshMatrix',
        'btn_name': 'Btn_Con_DSP1',
        'gve_id': 'DSP1',
      };

      final applied =
          provider.applyModuleDefaults('DSPDEVICE_2', 'DMP 64 Plus C');

      final dev = provider.roomConfig['DSPDEVICE_2'];
      expect(dev['model'], 'DMP 64 Plus C');
      expect(dev['module'], 'modules.device.extr_dsp_DMP_64_Plus_Series');
      expect(dev['protocol'], 'TCP');
      expect(dev['net_port'], 22023);
      expect(dev['com_type'], 'Network'); // added even though it was missing
      expect(dev['keep_alive_command'], 'RefreshMatrix');
      expect(dev['btn_name'], 'Btn_Con_DSP2'); // index substituted
      expect(dev['gve_id'], 'DSP2');
      expect(applied,
          contains('module = modules.device.extr_dsp_DMP_64_Plus_Series'));
      expect(applied, contains('net_port = 22023'));
    });

    test('setDeviceCount numbers the synthesized template\'s trailing "_X" '
        'placeholder per device (btn_name, gve_id)', () {
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{};

      // getDefaultDeviceBlock falls back to the synthesized "..._X" template
      // when the config has no PROJECTORDEVICE_1 and the schema no template.
      final template = provider.getDefaultDeviceBlock('PROJECTORDEVICE_');
      expect(template['btn_name'], 'Btn_Con_PROJECTORDEVICE_X');
      expect(template['gve_id'], 'PROJECTORDEVICE_X');

      provider.setDeviceCount(
          'dev_projectors', 'PROJECTORDEVICE_', 2, template);

      expect(provider.roomConfig['PROJECTORDEVICE_1']['btn_name'],
          'Btn_Con_PROJECTORDEVICE_1');
      expect(provider.roomConfig['PROJECTORDEVICE_1']['gve_id'],
          'PROJECTORDEVICE_1');
      expect(provider.roomConfig['PROJECTORDEVICE_2']['btn_name'],
          'Btn_Con_PROJECTORDEVICE_2');
      expect(provider.roomConfig['PROJECTORDEVICE_2']['gve_id'],
          'PROJECTORDEVICE_2');
    });

    test('index substitution keeps a btn_name that legitimately ends in X '
        '(no underscore before it)', () {
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{};

      provider.setDeviceCount('dev_dsps', 'DSPDEVICE_', 2, {
        'btn_name': 'Btn_Con_MTX', // ends in X but is not a placeholder
        'gve_id': 'DSPDEVICE_X',
      });

      expect(provider.roomConfig['DSPDEVICE_2']['btn_name'], 'Btn_Con_MTX');
      expect(provider.roomConfig['DSPDEVICE_2']['gve_id'], 'DSPDEVICE_2');
    });

    test('keepSettingsSwitchModule changes only model + module, preserving '
        'every other field', () {
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.roomConfig['DSPDEVICE_1'] = <String, dynamic>{
        'model': 'Old Model',
        'module': 'old_module',
        'protocol': 'SSH',
        'ip_address': '10.0.0.5',
        'name': 'My DSP',
      };
      provider.modelRegistry['DMP 64 Plus C'] = const ModelEntry(
          model: 'DMP 64 Plus C',
          module: 'extr_dsp_DMP_64_Plus_Series',
          explicit: true);
      provider.moduleDefaults['extr_dsp_DMP_64_Plus_Series'] = {
        'protocol': 'TCP',
        'net_port': 22023,
      };

      provider.keepSettingsSwitchModule('DSPDEVICE_1', 'DMP 64 Plus C');

      final dev = provider.roomConfig['DSPDEVICE_1'];
      expect(dev['model'], 'DMP 64 Plus C');
      expect(dev['module'],
          'modules.device.extr_dsp_DMP_64_Plus_Series'); // switched
      expect(dev['protocol'], 'SSH'); // preserved
      expect(dev['ip_address'], '10.0.0.5'); // preserved
      expect(dev['name'], 'My DSP'); // preserved
      expect(dev.containsKey('net_port'), isFalse); // default NOT applied
    });

    test(
        'preloadAllModules builds the registry from the real device folder '
        '(DEVICE_INFO wins over other modules\' self.Models fallbacks)', () async {
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.modulesPath = path.join(Directory.current.path, 'device');
      await provider.preloadAllModules();

      // Declared explicitly in extr_dsp_DMP_64_Plus_Series.py's DEVICE_INFO —
      // must beat the self.Models fallback of the other DMP 64 variants.
      final entry = provider.modelRegistry['DMP 64 Plus C'];
      expect(entry, isNotNull);
      expect(entry!.module, 'extr_dsp_DMP_64_Plus_Series');
      expect(entry.explicit, isTrue);
      expect(entry.deviceTypes, ['dsp']);
      // "connection" and "defaults" arrive merged into one apply-map — now the
      // full field set (site-specific ip_address/serial_port/password blank).
      expect(provider.moduleDefaults['extr_dsp_DMP_64_Plus_Series'], {
        'com_type': 'Network',
        'protocol': 'TCP',
        'net_port': 22023,
        'service_port': 0,
        'host': 'processor1',
        'ip_address': '',
        'serial_port': '',
        'btn_name': 'Btn_Con_DSP1',
        'lbl_name': 'Lbl_DSP_Name_Status',
        'gve_id': 'DSP1',
        'name': 'DSP - DMP 64 Plus C AT',
        'device_id': null,
        'keep_alive_command': 'RefreshMatrix',
        'keep_alive_interval': 30,
        'keep_alive_trigger': null,
        'manual_disconnect': false,
        'user': 'admin',
        'password': '',
        'group_prog_gain': '1',
        'group_mic_in_room_mute': '2',
        'group_voice_lift_mute': '3',
        'group_mic_ceiling_mute': '4',
        'group_prog_mute': '5',
        'group_mic_master_mute': '6',
        'group_pc_mic_input_gain': '7',
        'group_pc_output_gain': '8',
        'group_pc_output_mute': '9',
        'group_mic_master_gain': '10',
        'group_pc_record_mute': '11',
      });

      // The DMP 128 next door claims its own models now too, so nothing in
      // the shipped folder is left winning by self.Models fallback. That
      // mechanism is covered against a synthetic module below, where it can't
      // be invalidated by a driver getting its DEVICE_INFO filled in.
      final neighbor = provider.modelRegistry['DMP 128 Plus C'];
      expect(neighbor?.module, 'extr_dsp_DMP_128_Plus_Series');
      expect(neighbor?.explicit, isTrue);
    });

    test('a module with NO DEVICE_INFO still contributes its self.Models keys',
        () async {
      final dir = Directory.systemTemp.createTempSync('selfmodels_fallback_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      File(path.join(dir.path, 'vendor_widget_9000.py')).writeAsStringSync('''
class DeviceClass:
    def __init__(self):
        self.Models = {
            'Widget 9000': self.vendor_9000,
            'Widget 9000X': self.vendor_9000x,
        }
''');

      final provider = AppStateProvider(autoLoadSettings: false)
        ..modulesPath = dir.path;
      await provider.preloadAllModules();

      final entry = provider.modelRegistry['Widget 9000'];
      expect(entry, isNotNull, reason: 'self.Models keys should be picked up');
      expect(entry!.module, 'vendor_widget_9000');
      expect(entry.explicit, isFalse, reason: 'no DEVICE_INFO claimed it');
      // Untyped, so it stays out of a known family's dropdown (checkbox-only).
      expect(entry.deviceTypes, isEmpty);
    });

    test('unknown model: preview reports not-known, keep just saves the text',
        () {
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.roomConfig['PROJ_1'] =
          <String, dynamic>{'model': '', 'module': 'keep_me'};

      final preview =
          provider.previewModelSelection('PROJ_1', 'Mystery 3000');
      expect(preview.known, isFalse);

      provider.keepSettingsSwitchModule('PROJ_1', 'Mystery 3000');
      expect(provider.roomConfig['PROJ_1']['model'], 'Mystery 3000');
      expect(provider.roomConfig['PROJ_1']['module'], 'keep_me');
    });
  });
}
