import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';

/// One Extron driver usually serves a whole product line — the same file backs
/// the DTP CrossPoint 82 4K and the 84 4K — but its DEVICE_INFO "defaults" can
/// only spell out one of them. Picking the 84 used to name the device
/// "Switcher - DTP CrossPoint 82 4K". The chosen model now wins.
void main() {
  const module = 'extr_matrix_DTP_CrossPoint_82_84_4kSeriesv1872';

  /// A provider seeded exactly the way preloadAllModules would leave it for
  /// the real 82/84 4K driver.
  AppStateProvider crosspointProvider() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.roomConfig['SWITCHERDEVICE_1'] = <String, dynamic>{
      'model': '',
      'module': '',
      'name': '',
    };
    p.moduleModels[module] = const [
      'DTP CrossPoint 82 4K',
      'DTP CrossPoint 82 4K IPCP MA 70',
      'DTP CrossPoint 82 4K IPCP SA',
      'DTP CrossPoint 84 4K',
      'DTP CrossPoint 84 4K IPCP MA 70',
      'DTP CrossPoint 84 4K IPCP SA',
    ];
    for (final model in p.moduleModels[module]!) {
      p.modelRegistry[model] =
          ModelEntry(model: model, module: module, explicit: true);
    }
    p.moduleDefaults[module] = {
      'btn_name': 'Btn_Con_Switcher1',
      'lbl_name': 'Lbl_Switcher_Model',
      'gve_id': 'Switch1',
      // The file names ONE of the six models it serves.
      'name': 'Switcher - DTP CrossPoint 82 4K',
      'keep_alive_command': 'RefreshMatrix',
      'user': 'admin',
      'password': '',
    };
    return p;
  }

  String nameAfterPicking(String model) {
    final p = crosspointProvider();
    p.applyModuleDefaults('SWITCHERDEVICE_1', model);
    return p.roomConfig['SWITCHERDEVICE_1']['name'] as String;
  }

  group('applying module defaults', () {
    test('the 84 4K is named an 84 4K, not the file\'s 82 4K', () {
      expect(nameAfterPicking('DTP CrossPoint 84 4K'),
          'Switcher - DTP CrossPoint 84 4K');
    });

    test('a longer variant replaces the whole model name, not just its start',
        () {
      // 'DTP CrossPoint 82 4K' is a prefix of the IPCP variants, so a naive
      // match would leave "... 84 4K IPCP SA 4K IPCP SA" style wreckage.
      expect(nameAfterPicking('DTP CrossPoint 84 4K IPCP SA'),
          'Switcher - DTP CrossPoint 84 4K IPCP SA');
    });

    test('picking the model the file already names changes nothing', () {
      expect(nameAfterPicking('DTP CrossPoint 82 4K'),
          'Switcher - DTP CrossPoint 82 4K');
    });

    test('generic defaults carrying no model name are untouched', () {
      final p = crosspointProvider();
      p.applyModuleDefaults('SWITCHERDEVICE_1', 'DTP CrossPoint 84 4K');
      final dev = p.roomConfig['SWITCHERDEVICE_1'];

      expect(dev['btn_name'], 'Btn_Con_Switcher1');
      expect(dev['lbl_name'], 'Lbl_Switcher_Model');
      expect(dev['gve_id'], 'Switch1');
      expect(dev['keep_alive_command'], 'RefreshMatrix');
      expect(dev['user'], 'admin');
      expect(dev['password'], '');
    });

    test('the trailing device index still substitutes alongside the model', () {
      final p = crosspointProvider();
      p.roomConfig['SWITCHERDEVICE_2'] =
          Map<String, dynamic>.from(p.roomConfig['SWITCHERDEVICE_1'] as Map);

      p.applyModuleDefaults('SWITCHERDEVICE_2', 'DTP CrossPoint 84 4K');

      final dev = p.roomConfig['SWITCHERDEVICE_2'];
      expect(dev['name'], 'Switcher - DTP CrossPoint 84 4K');
      expect(dev['btn_name'], 'Btn_Con_Switcher2');
      expect(dev['gve_id'], 'Switch2');
    });
  });

  test('the preview shows the same name the apply will write', () {
    final p = crosspointProvider();

    final preview =
        p.previewModelSelection('SWITCHERDEVICE_1', 'DTP CrossPoint 84 4K');

    expect(preview.resolvedDefaults['name'], 'Switcher - DTP CrossPoint 84 4K');
    // ...and the dialog's diff list quotes the corrected name too.
    final nameDiff = preview.diffs.where((d) => d.key == 'name').single;
    expect(nameDiff.moduleDefault, 'Switcher - DTP CrossPoint 84 4K');
  });

  test('a module that declares no models leaves its defaults alone', () {
    final p = AppStateProvider(autoLoadSettings: false);
    p.roomConfig['SWITCHERDEVICE_1'] = <String, dynamic>{'name': ''};
    p.modelRegistry['Some Switcher'] = const ModelEntry(
        model: 'Some Switcher', module: 'vendor_generic', explicit: false);
    p.moduleDefaults['vendor_generic'] = {'name': 'Switcher - Generic'};

    p.applyModuleDefaults('SWITCHERDEVICE_1', 'Some Switcher');

    expect(p.roomConfig['SWITCHERDEVICE_1']['name'], 'Switcher - Generic');
  });
}
