import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// Reproduction: "New Config" left the PREVIOUS room's building and number on
/// the Wizard until the user switched to another tab and back.
///
/// The Wizard's identity fields are `TextFormField`/`Autocomplete` built with
/// `initialValue`, which is read once per element. Replacing the config doesn't
/// change the widget's position in the tree, so Flutter reused the old elements
/// — and their text with them. The tab is now keyed on
/// [AppStateProvider.configRevision], so a replaced config gets fresh elements.
void main() {
  late Directory dir;
  late AppStateProvider provider;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('wizard_repaint_test_');
    File(path.join(dir.path, 'config.json')).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {
        'gve_bldg': 'TPL',
        'gve_room': '111',
        'gui_full_room_name': 'Template Room 111',
      },
    }));

    // autoLoadSettings: false — the async load would rewrite the real settings.
    provider = AppStateProvider(autoLoadSettings: false)
      ..templateFilePath = path.join(dir.path, 'config.json')
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false;

    // A room already open, with identifiers that share nothing with the
    // template — so a stale field is unmistakable.
    provider.roomConfig = {
      'SYSTEM_SETUP': {
        'gve_bldg': 'ZZTOP',
        'gve_room': '9911',
        'gui_full_room_name': 'Zztop Hall 9911',
      },
    };
    provider.selectTab(0); // Wizard
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('New Config repaints the Wizard instead of keeping the previous '
      'room on screen', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // The rail opens on Project now, and this test is about the Wizard.
    provider.selectTab(AppTab.wizard.index);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pump();

    // The room that is open shows through.
    expect(find.text('ZZTOP'), findsOneWidget);
    expect(find.text('9911'), findsOneWidget);
    expect(find.text('Zztop Hall 9911'), findsOneWidget);

    // Same thing the toolbar's "New Config" button does. runAsync because it
    // reads the template off disk — real I/O can't complete inside
    // testWidgets' fake-async zone.
    final bool created =
        await tester.runAsync(() => provider.createNewConfig()) ?? false;
    expect(created, isTrue);
    await tester.pump();

    // WITHOUT ever leaving the tab, the old room must be gone...
    expect(find.text('ZZTOP'), findsNothing,
        reason: 'stale building name from the previous config');
    expect(find.text('9911'), findsNothing,
        reason: 'stale room number from the previous config');
    expect(find.text('Zztop Hall 9911'), findsNothing,
        reason: 'stale full room name from the previous config');

    // ...and replaced by the template's.
    expect(find.text('TPL'), findsOneWidget);
    expect(find.text('111'), findsOneWidget);
    expect(find.text('Template Room 111'), findsOneWidget);
  });
}
