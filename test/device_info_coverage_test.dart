import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';

/// A bulk re-annotation script once replaced hand-authored DEVICE_INFO blocks
/// with generic stubs — empty "models" lists and a name of the FILE rather than
/// the device. A driver with no declared models only ever wins the registry by
/// self.Models fallback and filename sort order, which is how the DMP 64 ended
/// up resolving to a versioned duplicate.
///
/// This walks the real device folder and holds the line: every driver that
/// knows its own models declares them, and no default names itself after its
/// file. Drivers that are a superseded copy of a sibling are listed explicitly.
void main() {
  late AppStateProvider provider;

  /// Files that deliberately declare NO models: each is an older duplicate of
  /// a sibling that owns those models explicitly. Leaving these empty is what
  /// keeps the sibling authoritative instead of the two fighting over the
  /// registry.
  const supersededByASibling = {
    // superseded by extr_matrix_DTP_CrossPoint_82_84_4kSeriesv1872
    'extr_matrix_DTP_CrossPoint_82_84_4kSeriesv1871',
    // superseded by nec_display_E758_E868_E988_v1_0_2_0
    'nec_display_E758_E868_v1_0_0_0',
    // superseded by sony_vp_VPL_P_Series
    'sony_vp_VPL_P_Series_v1_0_1_0',
  };

  setUpAll(() async {
    provider = AppStateProvider(autoLoadSettings: false)
      ..modulesPath = path.join(Directory.current.path, 'device');
    await provider.preloadAllModules();
  });

  test('the folder actually parsed', () {
    expect(provider.availableModules.length, greaterThan(50));
    expect(provider.modelRegistry, isNotEmpty);
  });

  test('every driver that knows its models declares them in DEVICE_INFO', () {
    final undeclared = <String>[];
    for (final module in provider.availableModules) {
      if (supersededByASibling.contains(module)) continue;
      final declared = provider.moduleModels[module];
      if (declared == null || declared.isEmpty) continue; // no models at all
      // moduleModels falls back to self.Models, so a module that knows its
      // models but left DEVICE_INFO empty shows up as a non-explicit winner.
      final entry = provider.modelRegistry[declared.first];
      if (entry != null && entry.module == module && !entry.explicit) {
        undeclared.add(module);
      }
    }
    expect(undeclared, isEmpty,
        reason: 'these win the registry only by filename sort order: '
            '${undeclared.join(', ')}');
  });

  test('no device default names itself after its own file', () {
    final selfNamed = <String>[];
    provider.moduleDefaults.forEach((module, defaults) {
      // A superseded copy declares no models, so there is no device name to
      // use instead — and it never wins the registry, so nothing reads it.
      if (supersededByASibling.contains(module)) return;
      final name = defaults['name']?.toString() ?? '';
      if (name.contains(module)) selfNamed.add(module);
    });
    expect(selfNamed, isEmpty,
        reason: 'a stub name from the re-annotation script: '
            '${selfNamed.join(', ')}');
  });

  group('the DMP 64 Plus metadata is back', () {
    test('the surviving driver owns its models explicitly', () {
      final entry = provider.modelRegistry['DMP 64 Plus C'];
      expect(entry, isNotNull);
      expect(entry!.module, 'extr_dsp_DMP_64_Plus_Series');
      expect(entry.explicit, isTrue);
    });

    test('the audio group numbers and device_id survived', () {
      final defaults = provider.moduleDefaults['extr_dsp_DMP_64_Plus_Series']!;
      expect(defaults['protocol'], 'TCP');
      expect(defaults['keep_alive_command'], 'RefreshMatrix');
      expect(defaults.containsKey('device_id'), isTrue);
      expect(defaults['group_prog_gain'], '1');
      expect(defaults['group_pc_record_mute'], '11');
    });
  });

  test('the DMP 128 Plus got the same treatment', () {
    final entry = provider.modelRegistry['DMP 128 Plus C AT'];
    expect(entry, isNotNull);
    expect(entry!.module, 'extr_dsp_DMP_128_Plus_Series');
    expect(entry.explicit, isTrue);

    final defaults = provider.moduleDefaults['extr_dsp_DMP_128_Plus_Series']!;
    expect(defaults['protocol'], 'TCP');
    expect(defaults['keep_alive_command'], 'RefreshMatrix');
    expect(defaults['group_prog_gain'], '1');
    expect(defaults['group_pc_record_mute'], '11');
  });

  test('the SW HD 4K Plus and Panasonic drivers claim their models', () {
    final sw = provider.modelRegistry['SW4 HD 4K PLUS'];
    expect(sw?.module, 'extr_switcher_SW_HD_4K_Plus_Series_v1_1_5_0');
    expect(sw?.explicit, isTrue);

    final pana = provider.modelRegistry['PT-VMZ71'];
    expect(pana?.module, 'pana_vp_PT_BMZx1_VMWx1_VMZx1_Series_v1_0_3_0');
    expect(pana?.explicit, isTrue);
  });

  test('the superseded copies did NOT take their siblings\' models', () {
    expect(provider.modelRegistry['DTP CrossPoint 84 4K']?.module,
        'extr_matrix_DTP_CrossPoint_82_84_4kSeriesv1872');
    expect(provider.modelRegistry['E868']?.module,
        'nec_display_E758_E868_E988_v1_0_2_0');
    expect(provider.modelRegistry['VPL-PHZ60']?.module,
        'sony_vp_VPL_P_Series');
  });
}
