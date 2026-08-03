import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';

/// The processor imports a device driver as `modules.device.<file stem>`, so
/// that is the ONLY spelling config.json may carry. Loading an old file already
/// rewrote the value; these cover the other half — a module chosen on a NEW
/// device, whichever way it was chosen.
void main() {
  AppStateProvider newProvider() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.roomConfig['DSPDEVICE_1'] = <String, dynamic>{
      'model': '',
      'module': '',
    };
    return p;
  }

  String moduleOf(AppStateProvider p) =>
      p.roomConfig['DSPDEVICE_1']['module'] as String;

  group('updateDeviceValue prefixes the module', () {
    test('a bare file stem picked from the dropdown', () {
      final p = newProvider();
      p.updateDeviceValue('DSPDEVICE_1', 'module', 'avr_TR311');
      expect(moduleOf(p), 'modules.device.avr_TR311');
    });

    test('a stem still carrying .py, as the file picker produces', () {
      final p = newProvider();
      p.updateDeviceValue('DSPDEVICE_1', 'module',
          'extr_scaler_IN1608xi_Series_v1_1_3_0.py');
      expect(moduleOf(p),
          'modules.device.extr_scaler_IN1608xi_Series_v1_1_3_0');
    });

    test('a sub-foldered relative path becomes dots under the prefix', () {
      final p = newProvider();
      p.updateDeviceValue('DSPDEVICE_1', 'module', 'extron\\avr_TR311');
      expect(moduleOf(p), 'modules.device.extron.avr_TR311');
    });

    test('an already-qualified value is left alone (never doubled)', () {
      final p = newProvider();
      p.updateDeviceValue(
          'DSPDEVICE_1', 'module', 'modules.device.avr_TR311');
      expect(moduleOf(p), 'modules.device.avr_TR311');
    });

    test('a cleared field stays empty rather than becoming a bare prefix', () {
      final p = newProvider();
      p.updateDeviceValue('DSPDEVICE_1', 'module', '');
      expect(moduleOf(p), '');
    });

    test('other properties are untouched by the module rule', () {
      final p = newProvider();
      p.updateDeviceValue('DSPDEVICE_1', 'model', 'TR311');
      expect(p.roomConfig['DSPDEVICE_1']['model'], 'TR311');
    });
  });

  test('the dropdown offers the import path, not the bare stem', () {
    final p = AppStateProvider(autoLoadSettings: false);
    p.availableModules = ['avr_TR311', 'extr_dsp_DMP_64_Plus_Series'];

    expect(p.availableModuleImports, [
      'modules.device.avr_TR311',
      'modules.device.extr_dsp_DMP_64_Plus_Series',
    ]);
  });
}
