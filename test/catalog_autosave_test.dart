import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';

/// The catalog can save itself on the autosave clock.
void main() {
  late Directory dir;
  late AppStateProvider p;
  late String file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('catalog_autosave');
    file = '${dir.path}/av_devices.json';
    p = AppStateProvider(autoLoadSettings: false)..avDevicesFilePath = file;
  });
  tearDown(() => dir.delete(recursive: true));

  void edit({String category = 'Switcher'}) => p.avDeviceLibrary.upsert(
        AvDeviceTemplate(
          model: 'IN1608 xi',
          category: category,
          custom: true,
          price: 1500,
          ports: const [],
        ),
      );

  test('off by default: nothing is written', () async {
    edit();
    expect(p.catalogAutosave, isFalse);
    expect(await p.autosaveCatalog(), '');
    expect(File(file).existsSync(), isFalse);
  });

  test('on: an edit is saved, and a clean catalog is left alone', () async {
    p.catalogAutosave = true;
    edit();
    expect(await p.autosaveCatalog(), file);
    expect(jsonEncode(jsonDecode(File(file).readAsStringSync())),
        contains('IN1608 xi'));
    expect(p.lastCatalogAutosaveAt, isNotNull);
    expect(p.avDeviceLibrary.differsFromBaseline, isFalse);
    // Nothing changed since: no second write.
    expect(await p.autosaveCatalog(), '');
  });

  test('waits while a changed entry has no category', () async {
    p.catalogAutosave = true;
    edit(category: '');
    expect(await p.autosaveCatalog(), '');
    expect(File(file).existsSync(), isFalse);
    expect(p.catalogAutosaveNote, contains('no category'));
  });
}
