import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p2;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// Smoke test for the state a FRESH INSTALL lands in: no files associated, so
/// every path setting is blank. Renders and scrolls the whole App Config tab
/// and asserts it builds without throwing.
///
/// (It also covers the field keys now being namespaced per setting. With the
/// bare value as the key, four siblings shared a ValueKey('') when all paths
/// were blank. That is a latent hazard worth avoiding, though testing showed
/// it was NOT the cause of the sliver_multi_box_adaptor child-order assertion.)
void main() {
  testWidgets('App Config renders with every path blank (no duplicate keys)',
      (WidgetTester tester) async {
    // Desktop-sized surface: the default 800x600 test window is narrower than
    // the app ever runs at, and the side-by-side path rows overflow it.
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // autoLoadSettings: false — the async load rewrites the real
    // app_config.json (and can corrupt it when tests run concurrently), and
    // this test wants the untouched fresh-install state anyway.
    final provider = AppStateProvider(autoLoadSettings: false);

    // The state a fresh install lands in: nothing chosen, nothing associated.
    expect(provider.modulesPath, isEmpty);
    expect(provider.buildingsFilePath, isEmpty);
    expect(provider.processorsFilePath, isEmpty);
    expect(provider.rootFolderPath, isEmpty);
    expect(provider.avDevicesFilePath, isEmpty);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: AppSettingsView())),
      ),
    );
    await tester.pump();

    // Before the fix this threw the sliver assertion instead of building.
    expect(tester.takeException(), isNull);
    expect(find.byType(AppSettingsView), findsOneWidget);

    // Scroll the whole list: the assertion fires as children are lazily
    // built and inserted, so a static first frame alone would not catch it.
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  /// THE CATALOG IS THE DEPARTMENT'S PRICE LIST, and it is only shared if it
  /// can be pointed somewhere shared. Blank still means "in the Root Folder",
  /// which is what every existing install is running on.
  group('the device catalog path', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('catalog_path');
    });
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('blank falls back to the root folder', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..rootFolderPath = dir.path;
      expect(p.effectiveAvDevicesPath, p2.join(dir.path, 'av_devices.json'));
    });

    test('a chosen path wins, even before anything is read from it', () {
      // A catalog pointed at a share that has no file in it yet is a first
      // save INTO the share, not a stray copy left in the root folder.
      final p = AppStateProvider(autoLoadSettings: false)
        ..rootFolderPath = dir.path
        ..avDevicesFilePath = '${dir.path}/shared/av_devices.json';
      expect(p.effectiveAvDevicesPath, '${dir.path}/shared/av_devices.json');
    });

    test('the catalog is read from it', () async {
      final shared = '${dir.path}/shared.json';
      await File(shared).writeAsString(jsonEncode({
        'devices': [
          {
            'model': 'Shared Switcher',
            'price': 4200.0,
            'ports': <Map<String, dynamic>>[],
          },
        ],
      }));

      final p = AppStateProvider(autoLoadSettings: false)
        ..avDevicesFilePath = shared;
      await p.loadAvDeviceLibrary();

      expect(p.avDeviceLibrary.templateForModel('Shared Switcher')?.price,
          4200);
      expect(p.avDeviceLibrary.filePath, shared);
      // And the Device Editor writes back to the same file rather than
      // dropping a second catalog beside the app.
      expect(p.effectiveAvDevicesPath, shared);
    });

    test('it survives a save and a reload of the settings file', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..avDevicesFilePath = '${dir.path}/shared.json';
      final saved = jsonDecode(jsonEncode(p.settingsAsJson())) as Map;
      expect(saved['avDevicesFilePath'], '${dir.path}/shared.json');
    });
  });
}
