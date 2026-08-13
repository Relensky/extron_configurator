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
    // superseded by extr_dsp_DMP_64_Plus_Series_v1_4_1_0
    'extr_dsp_DMP_64_Plus_Series',
    'extr_dsp_DMP_64_Plus',
    // superseded by extr_dsp_DMP_128_Plus_Series_v1_10_13_0
    'extr_dsp_DMP_128_Plus_Series',
    // superseded by extr_switcher_SW_HD_4K_PLUS_Series_v1_1_9_0
    'extr_switcher_SW_HD_4K_Plus_Series_v1_1_5_0',
  };

  /// The families where more than one file can drive the same box, and the one
  /// that owns the models. Which file that is has moved — the library now
  /// points at the NEWEST driver of each pair rather than the unversioned one
  /// it used to — so the checks below test the RULE (exactly one owner, and it
  /// says so explicitly) rather than a filename that a version bump changes.
  const familyOwner = {
    'DMP 64 Plus C': 'extr_dsp_DMP_64_Plus_Series_v1_4_1_0',
    'DMP 128 Plus C AT': 'extr_dsp_DMP_128_Plus_Series_v1_10_13_0',
    'SW4 HD 4K PLUS': 'extr_switcher_SW_HD_4K_PLUS_Series_v1_1_9_0',
    'DTP CrossPoint 84 4K': 'extr_matrix_DTP_CrossPoint_82_84_4kSeriesv1872',
    'E868': 'nec_display_E758_E868_E988_v1_0_2_0',
    'VPL-PHZ60': 'sony_vp_VPL_P_Series',
    'PT-VMZ71': 'pana_vp_PT_BMZx1_VMWx1_VMZx1_Series_v1_0_3_0',
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

  test('every duplicated driver family has exactly one declared owner', () {
    // The point of the arrangement: where two files can drive the same box,
    // ONE declares the models and the others stay silent. A silent file never
    // wins the registry, so the answer cannot depend on filename sort order.
    familyOwner.forEach((model, owner) {
      final entry = provider.modelRegistry[model];
      expect(entry, isNotNull, reason: '$model resolves to nothing');
      expect(entry!.module, owner, reason: model);
      expect(entry.explicit, isTrue,
          reason: '$owner wins $model only by sort order');
    });
  });

  test('the superseded copies did not take their siblings\' models', () {
    for (final module in supersededByASibling) {
      final declared = provider.moduleModels[module] ?? const [];
      for (final model in declared) {
        expect(provider.modelRegistry[model]?.module, isNot(module),
            reason: '$module should have left $model to its sibling');
      }
    }
  });

  test('the DSP metadata the re-annotation stripped is back', () {
    // The audio group numbers are the fragile part: they are what makes a
    // matrix the room's audio hub, and a stub block loses them silently.
    for (final model in ['DMP 64 Plus C', 'DMP 128 Plus C AT']) {
      final owner = provider.modelRegistry[model]!.module;
      final defaults = provider.moduleDefaults[owner]!;
      expect(defaults['group_prog_gain'], '1', reason: owner);
      expect(defaults['group_pc_record_mute'], '11', reason: owner);
      // The driver declares "device_id": None, which says the model does not
      // use the key — not that a null is a value to apply. Taken literally it
      // put a null device_id on every device anybody picked a model for.
      expect(defaults.containsKey('device_id'), isFalse, reason: owner);
      // 22023 is the Extron SSH port; a block naming it and saying TCP
      // describes a connection that cannot be made.
      if (defaults['net_port'] == 22023) {
        expect(defaults['protocol'], 'SSH', reason: owner);
      }
    }
  });
}
