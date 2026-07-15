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
    "models": ["DMP 64 Plus C", "DMP 64 Plus C V"],
    "connection": {
        "com_type": "Network",
        "protocol": "TCP",
        "net_port": 22023
    }
}

class DeviceClass:
    pass
''';
      final info = AppStateProvider.parseDeviceInfo('test.py', py);
      expect(info, isNotNull);
      expect(info!['models'], ['DMP 64 Plus C', 'DMP 64 Plus C V']);
      expect(info['connection'],
          {'com_type': 'Network', 'protocol': 'TCP', 'net_port': 22023});
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

  group('AppStateProvider.applyModelSelection', () {
    test('sets model, switches module, and applies connection defaults', () {
      final provider = AppStateProvider(autoLoadSettings: false);
      // Real configs come from jsonDecode, so blocks are Map<String, dynamic>
      provider.roomConfig['DSP_1'] = <String, dynamic>{
        'model': '',
        'module': 'old_module',
        'protocol': 'SSH',
        'name': 'DSP',
      };
      provider.modelRegistry['DMP 64 Plus C'] = const ModelEntry(
          model: 'DMP 64 Plus C',
          module: 'extr_dsp_DMP_64_Plus_Series',
          explicit: true);
      provider.moduleConnectionDefaults['extr_dsp_DMP_64_Plus_Series'] = {
        'com_type': 'Network',
        'protocol': 'TCP',
        'net_port': 22023,
      };

      final applied = provider.applyModelSelection('DSP_1', 'DMP 64 Plus C');

      final dev = provider.roomConfig['DSP_1'];
      expect(dev['model'], 'DMP 64 Plus C');
      expect(dev['module'], 'extr_dsp_DMP_64_Plus_Series');
      expect(dev['protocol'], 'TCP');
      expect(dev['net_port'], 22023);
      expect(dev['com_type'], 'Network'); // added even though it was missing
      expect(applied, contains('module = extr_dsp_DMP_64_Plus_Series'));
      expect(applied, contains('net_port = 22023'));
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
      expect(
          provider.moduleConnectionDefaults['extr_dsp_DMP_64_Plus_Series'],
          {'com_type': 'Network', 'protocol': 'TCP', 'net_port': 22023});

      // Fallback source: a module with NO DEVICE_INFO still contributes the
      // keys of its self.Models dict.
      final fallback = provider.modelRegistry['DMP 128 Plus C'];
      expect(fallback, isNotNull, reason: 'self.Models keys should be picked up');
      expect(fallback!.explicit, isFalse);
    });

    test('unknown model only saves the model text', () {
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.roomConfig['PROJ_1'] =
          <String, dynamic>{'model': '', 'module': 'keep_me'};

      final applied = provider.applyModelSelection('PROJ_1', 'Mystery 3000');

      expect(provider.roomConfig['PROJ_1']['model'], 'Mystery 3000');
      expect(provider.roomConfig['PROJ_1']['module'], 'keep_me');
      expect(applied, isEmpty);
    });
  });
}
