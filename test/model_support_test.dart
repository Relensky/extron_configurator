import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/device_info_source.dart';

/// DEVICE_INFO "model_support": a device is offered only the commands and
/// states its own model has, not the whole driver's.
///
/// The Epson PowerLite driver is the case it was built for: the L630U on the
/// same file as the L610U has no Computer (RGB) input (the projector answers
/// ERR), and nothing in the app could tell the two apart.
void main() {
  final String devicePath = path.join(Directory.current.path, 'device');
  const String epson = 'modules.device.epsn_vp_Powerlite';
  const String crosspoint =
      'modules.device.extr_matrix_DTP_CrossPoint_82_84_4kSeriesv1872';

  late AppStateProvider provider;

  setUpAll(() async {
    provider = AppStateProvider(autoLoadSettings: false)
      ..modulesPath = devicePath;
    await provider.preloadAllModules();
  });

  test('every driver that declares model_support parses it', () async {
    final files = Directory(devicePath)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.py'));
    var declared = 0;
    for (final file in files) {
      final content = await file.readAsString();
      if (!content.contains('"model_support"')) continue;
      declared++;
      final info = AppStateProvider.parseDeviceInfo(file.path, content);
      expect(info, isNotNull, reason: file.path);
      final groups = ModelSupport.listFrom(info!['model_support']);
      // Every multi-model driver lists ALL its groups, the ones that differ
      // from the rest and the ones that do not.
      expect(groups.length, greaterThanOrEqualTo(2), reason: file.path);
      final models = [for (final g in groups) ...g.models];
      expect(models.toSet().length, models.length,
          reason: '${file.path}: a model is in two groups');
    }
    expect(declared, greaterThanOrEqualTo(25));
  });

  test('the Input states follow the picked Epson model', () async {
    final all = await provider.getStatesForModuleCommand(epson, 'Input');
    expect(all, containsAll(['Computer 1 (RGB)', 'HDBaseT', 'AirPlay']));

    final l630u = await provider.getStatesForModuleCommand(epson, 'Input',
        model: 'PowerLite L630U');
    expect(l630u, containsAll(['Computer 1', 'HDMI 1', 'HDBaseT']));
    expect(l630u, isNot(contains('Computer 1 (RGB)')));
    expect(l630u, isNot(contains('AirPlay')));

    // The config's spelling of a model need not match the driver's case.
    expect(
        await provider.getStatesForModuleCommand(epson, 'Input',
            model: 'powerlite l400u'),
        isNot(contains('HDBaseT')));

    // A model the driver does not group is offered everything.
    expect(
        await provider.getStatesForModuleCommand(epson, 'Input',
            model: 'Not a projector'),
        all);
  });

  test('the Keep Alive commands drop what the model lacks', () async {
    final all = await provider.getCommandsForModule(crosspoint);
    expect(all, contains('HDCPOutputStatus'));
    final x82 = await provider.getCommandsForModule(crosspoint,
        model: 'DTP CrossPoint 82 4K');
    expect(x82, isNot(contains('HDCPOutputStatus')));
    expect(x82, contains('Temperature'));
    // A kit name that extends the model by whole words is that model.
    expect(
        await provider.getCommandsForModule(crosspoint,
            model: 'DTP CrossPoint 82 4K IPCP Q SA'),
        isNot(contains('HDCPOutputStatus')));
    expect(await provider.getCommandsForModule(crosspoint, model: ''), all);
  });

  test('the DEVICE_INFO editor writes model_support back readably', () async {
    final file = File(path.join(devicePath, 'epsn_vp_Powerlite.py'));
    final info = AppStateProvider.parseDeviceInfo(
        file.path, await file.readAsString())!;
    final text = formatDeviceInfo(DeviceInfoDraft.fromInfo(info));
    expect(text.split('\n').every((line) => line.length <= 120), isTrue);
    final again = AppStateProvider.parseDeviceInfo('x.py', text)!;
    expect(again['model_support'], info['model_support']);
  });
}
