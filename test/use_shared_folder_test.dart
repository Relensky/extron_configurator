import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';

/// File > Use Shared Folder for All Settings.
void main() {
  test('every file and folder setting follows the shared Root Folder',
      () async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = r'C:\elsewhere'
      ..modulesPath = r'C:\elsewhere\devices'
      ..processorsFilePath = r'C:\elsewhere\processors.json'
      ..buildingsFilePath = r'C:\elsewhere\buildings.json'
      ..templateFilePath = r'C:\elsewhere\config.json'
      ..uiSchemaPath = r'C:\elsewhere\ui_schema.json'
      ..keyMapPath = r'C:\elsewhere\key_map.json'
      ..avDevicesFilePath = r'C:\elsewhere\av_devices.json'
      ..flowRulesFilePath = r'C:\elsewhere\av_flow_rules.json'
      ..deliveryLocationsFilePath = r'C:\elsewhere\delivery_locations.json'
      ..vendorListFilePath = r'C:\elsewhere\vendor_list.json'
      ..documentationPath = r'C:\elsewhere\documentation'
      ..specSheetFolder = r'C:\elsewhere\spec_sheets'
      ..classSchedulePath = r'C:\elsewhere\schedule.csv'
      ..logFolderPath = r'C:\logs';

    await p.useSharedFolderForAll();

    expect(p.rootFolderPath, AppStateProvider.kSharedRootFolder);
    expect(p.effectiveRootFolder, AppStateProvider.kSharedRootFolder);
    for (final value in [
      p.modulesPath,
      p.processorsFilePath,
      p.buildingsFilePath,
      p.templateFilePath,
      p.uiSchemaPath,
      p.keyMapPath,
      p.avDevicesFilePath,
      p.flowRulesFilePath,
      p.deliveryLocationsFilePath,
      p.vendorListFilePath,
      p.documentationPath,
      p.specSheetFolder,
      p.classSchedulePath,
    ]) {
      expect(value, isEmpty);
    }
    // Per-machine, not shared.
    expect(p.logFolderPath, r'C:\logs');
  });
}
