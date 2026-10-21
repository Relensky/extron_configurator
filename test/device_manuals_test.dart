import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/device_manuals.dart';
import 'package:extron_configurator/manuals_catalog.dart';

/// The usual clone of the Manuals repo - for checking the real catalog here
/// only; the app itself never reads it unless somebody picks it.
const String kGitManualsFolder = r'C:\GitHub\Manuals';

void main() {
  final catalog = ManualsCatalog.fromJson(r'C:\Manuals', {
    'manufacturers': {
      'AVer': {'prefixes': ['AVer']},
    },
    'models': {
      'aver-tr311': {
        'manufacturer': 'AVer',
        'model': 'TR311',
        'aliases': ['AVer TR311'],
        'folder': 'files/aver/tr311',
        'documents': [
          {'title': 'User Manual', 'kind': 'user-guide', 'url': 'https://example.com/a.pdf'},
        ],
      },
      'aver-cam570': {
        'manufacturer': 'AVer',
        'model': 'CAM570',
        'folder': 'files/aver/cam570',
        'documents': [],
      },
    },
  });

  test('device rows say found, no documents, or not in the catalog', () {
    final rows = deviceManualRows(catalog, {
      'TR311': 'avr_TR311',
      'CAM570': 'avr_camera_CAM570',
      'PTZ310': 'avr_camera_PTZ310',
    });
    expect(rows.map((r) => r.model), ['CAM570', 'PTZ310', 'TR311']);
    expect(rows.map((r) => r.status), [
      DeviceManualStatus.noDocuments,
      DeviceManualStatus.notInCatalog,
      DeviceManualStatus.found,
    ]);
    final text = missingDeviceManualsText(rows);
    expect(text, contains('CAM570\tavr_camera_CAM570\tno documents'));
    expect(text, contains('PTZ310\tavr_camera_PTZ310\tnot in catalog'));
    expect(text, isNot(contains('TR311\t')));
  });

  test('module rows use the module manual naming rule', () {
    final have = {path.join('docs', 'avr_TR311.pdf')};
    final rows = moduleManualRows(
      ['avr_TR311', 'vendor.extr_dsp_DMP_64', 'avr_TR311'],
      'docs',
      exists: have.contains,
    );
    expect(rows, hasLength(2), reason: 'a module listed twice is one row');
    expect(rows.first.module, 'avr_TR311');
    expect(rows.first.exists, isTrue);
    expect(rows.last.expectedName, 'extr_dsp_DMP_64.pdf');
    expect(rows.last.exists, isFalse);
    expect(missingModuleManualsText(rows),
        'Module\tExpected manual\nvendor.extr_dsp_DMP_64\textr_dsp_DMP_64.pdf');
  });

  test('the cache reads a catalog, and again once it changes', () async {
    final dir = await Directory.systemTemp.createTemp('manuals_cache');
    addTearDown(() => dir.delete(recursive: true));
    expect(await ManualsCatalogCache.load(dir.path), isNull);

    final file = File(ManualsCatalog.catalogPath(dir.path));
    await file.parent.create(recursive: true);
    Future<void> write(String model) => file.writeAsString(jsonEncode({
          'manufacturers': {},
          'models': {
            'x': {'model': model, 'documents': []}
          }
        }));
    await write('One');
    expect((await ManualsCatalogCache.load(dir.path))!.forModel('One'), isNotNull);

    await write('Two');
    await file.setLastModified(DateTime.now().add(const Duration(minutes: 1)));
    final again = await ManualsCatalogCache.load(dir.path);
    expect(again!.forModel('Two'), isNotNull);
    expect(again.forModel('One'), isNull);
    ManualsCatalogCache.clear();
  });

  // The share is never reachable under test, so a blank setting lands on the
  // fresh-install fallback: the Root Folder's own manuals folder - never a
  // clone of the Manuals repo.
  test('a blank Manuals Folder falls back to the Root Folder, not the repo',
      () {
    final provider = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = r'C:\Root';
    expect(provider.effectiveManualsFolder, path.join(r'C:\Root', 'manuals'));
    expect(provider.effectiveManualsFolder, isNot(kGitManualsFolder));
    provider.manualsFolder = '  $kDashboardManualsFolder ';
    expect(provider.effectiveManualsFolder, kDashboardManualsFolder);
  });

  // Against the real drivers and, when it is on this machine, the real
  // Manuals repo - the numbers the Manuals window shows.
  test('real drivers against the Manuals repo', () async {
    final provider = AppStateProvider(autoLoadSettings: false)
      ..modulesPath = path.join(Directory.current.path, 'device');
    await provider.preloadAllModules();
    final real = await ManualsCatalog.load(kGitManualsFolder);
    if (real == null) {
      markTestSkipped('No Manuals repo at $kGitManualsFolder');
      return;
    }
    final rows = deviceManualRows(real, {
      for (final e in provider.modelRegistry.entries) e.key: e.value.module,
    });
    expect(rows, isNotEmpty);
    // The Extron drivers' models were the first filled in.
    final found = rows.where((r) => r.status == DeviceManualStatus.found);
    expect(found.map((r) => r.model), contains('IN1608 xi'));
    final modules = moduleManualRows(provider.availableModules,
        path.join(Directory.current.path, 'documentation'));
    expect(modules.where((r) => r.exists), isNotEmpty);
  });
}
