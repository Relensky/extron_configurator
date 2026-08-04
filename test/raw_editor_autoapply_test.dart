import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// The Raw JSON tab lost its Apply Changes button — the toolbar's Save is the
/// one save now. Save writes the config in MEMORY, so the editor has to put
/// typed text there on its own; without that, editing here and pressing Save
/// would write the config as it was before the edit.
void main() {
  late Directory dir;
  late String configPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('raw_editor_test_');
    configPath = path.join(dir.path, 'BSS103_config.json');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  const Map<String, dynamic> config = {
    'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103'},
  };

  String edited(String room) => const JsonEncoder.withIndent('    ').convert({
        'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': room},
      });

  Future<AppStateProvider> pumpEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    File(configPath).writeAsStringSync(jsonEncode(config));
    final provider = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = jsonDecode(jsonEncode(config))
      ..currentConfigPath = configPath
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false;
    provider.selectTab(4); // Raw JSON

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pump();
    return provider;
  }

  testWidgets('the Apply Changes button is gone', (WidgetTester tester) async {
    await pumpEditor(tester);
    expect(find.text('Apply Changes'), findsNothing);
  });

  testWidgets('typing reaches the config once the keystrokes stop',
      (WidgetTester tester) async {
    final provider = await pumpEditor(tester);

    await tester.enterText(find.byType(TextField), edited('999'));
    await tester.pump(); // onChanged only queues the commit
    expect(provider.roomConfig['SYSTEM_SETUP']['gve_room'], '103',
        reason: 'not applied on every keystroke');

    await tester.pump(const Duration(milliseconds: 500)); // debounce elapses
    expect(provider.roomConfig['SYSTEM_SETUP']['gve_room'], '999');
  });

  testWidgets('invalid JSON is reported and never applied',
      (WidgetTester tester) async {
    final provider = await pumpEditor(tester);

    await tester.enterText(find.byType(TextField), '{"SYSTEM_SETUP": {');
    await tester.pump(const Duration(milliseconds: 500));

    expect(provider.roomConfig['SYSTEM_SETUP']['gve_room'], '103',
        reason: 'the config keeps the last version that parsed');
    expect(find.textContaining('Invalid JSON'), findsOneWidget);
  });

  testWidgets('Save flushes text typed inside the debounce window',
      (WidgetTester tester) async {
    final provider = await pumpEditor(tester);

    await tester.enterText(find.byType(TextField), edited('777'));
    await tester.pump(); // still pending — no debounce wait

    // Saving must not write around it. (Driven through the provider: the
    // toolbar button's own path is covered in save_working_file_test.)
    await tester.runAsync(() => provider.saveCurrentConfigToFile());
    await tester.pump();

    expect(provider.roomConfig['SYSTEM_SETUP']['gve_room'], '777');
    final onDisk = jsonDecode(File(configPath).readAsStringSync()) as Map;
    expect(onDisk['SYSTEM_SETUP']['gve_room'], '777',
        reason: 'the file gets what was on screen, not the stale config');
  });

  testWidgets('leaving the tab still applies what was typed',
      (WidgetTester tester) async {
    final provider = await pumpEditor(tester);

    await tester.enterText(find.byType(TextField), edited('555'));
    await tester.pump();

    provider.selectTab(2); // System — the editor is disposed mid-debounce
    await tester.pump();
    await tester.pump(); // the post-frame flush runs

    expect(provider.roomConfig['SYSTEM_SETUP']['gve_room'], '555');
  });
}
