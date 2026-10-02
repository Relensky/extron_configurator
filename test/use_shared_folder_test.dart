import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// File > Use Shared Folder for All Settings, and the file server on
/// First-Time Setup.
void main() {
  test('a new install starts on its own folder, not the file server', () {
    final p = AppStateProvider(autoLoadSettings: false);
    expect(p.rootFolderPath, isEmpty);
    expect(p.effectiveRootFolder, isNot(AppStateProvider.kSharedRootFolder));
  });

  tearDown(() => FirstRunSetupDialog.fileServerReachableForTest = null);

  Future<AppStateProvider> setup(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = AppStateProvider(autoLoadSettings: false);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(
          home: Scaffold(body: FirstRunSetupDialog()),
        ),
      ),
    );
    await tester.pump();
    return p;
  }

  testWidgets('out of the box the app runs from its own folder; an unreachable '
      'file server cannot be set', (tester) async {
    FirstRunSetupDialog.fileServerReachableForTest = false;
    final p = await setup(tester);
    expect(p.effectiveModulesPath, isNot(contains('doit-files')));
    expect(find.textContaining('Not reachable'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.ancestor(
      of: find.text('Set to file server'),
      matching: find.byWidgetPredicate((w) => w is FilledButton),
    ));
    expect(button.onPressed, isNull);
  });

  testWidgets('First-Time Setup offers the file server and sets it',
      (tester) async {
    FirstRunSetupDialog.fileServerReachableForTest = true;
    final p = await setup(tester);
    expect(find.text(AppStateProvider.kSharedRootFolder), findsOneWidget);
    expect(find.textContaining('Reachable'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey('first_run_use_file_server')),
      );
      for (var i = 0; i < 50 && p.rootFolderPath.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();

    expect(p.rootFolderPath, AppStateProvider.kSharedRootFolder);
    expect(find.text('In use'), findsOneWidget);
  });

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
