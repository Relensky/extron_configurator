import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/main.dart';

/// ============================================================================
///  THE WHOLE APP, WALKED THROUGH
/// ============================================================================
///  A job with a drawn room open, and every tab, every Project pane, every
///  settings section and the profile, history and first-run windows visited
///  in turn - failing on the first error anything throws on the way.
/// ============================================================================
void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('walkthrough_');
    SettingsSection.forgetOpenForTest();
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A job with one room on it: a projector and a camera drawn and costed,
  /// a note on the list, a PO and a delivery.
  Future<AppStateProvider> job() async {
    final config = path.join(dir.path, 'BSS_103', 'config.json');
    Directory(path.join(dir.path, 'BSS_103', 'room_files'))
        .createSync(recursive: true);
    File(config).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {
        'gui_full_room_name': 'Bessey 103',
        'gve_bldg': 'BSS',
        'gve_room': '103',
      },
    }));
    File(path.join(dir.path, 'BSS_103', 'room_files', 'BSS_103_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [
        for (final (id, model) in [
          ('AVNODE_1', 'PowerLite L610U'),
          ('AVNODE_2', 'RoboSHOT 12E'),
        ])
          AvNode(
            id: id,
            label: model,
            model: model,
            pos: Offset.zero,
            ports: const [],
          ).toJson(),
      ],
    }));

    final p = AppStateProvider(autoLoadSettings: false)
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false;
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'PowerLite L610U',
        manufacturer: 'Epson',
        category: 'Projector',
        price: 1000,
        ports: [],
      ))
      ..upsert(const AvDeviceTemplate(
        model: 'RoboSHOT 12E',
        manufacturer: 'Vaddio',
        category: 'Camera',
        price: 2000,
        ports: [],
      ));
    p.newProject(name: 'Walkthrough');
    p.addRoomToProject(config);
    p.addProjectTodo('ring the dean', roomId: p.project.rooms.single.id);
    p.addProjectPo(number: 'PO-1');
    p.addProjectDelivery(itemName: 'Wall plate', qty: 2, poNumber: 'PO-1');
    await p.saveProject(to: path.join(dir.path, 'Walkthrough_project.json'));
    await p.openProjectRoomRef(p.project.rooms.single);
    return p;
  }

  Future<void> pumpApp(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Settles, then fails on anything that was thrown along the way.
  Future<void> settle(WidgetTester tester, String where) async {
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: where);
  }

  testWidgets('every tab and every project pane, with a room open',
      (tester) async {
    late AppStateProvider p;
    await tester.runAsync(() async => p = await job());
    await pumpApp(tester, p);

    for (final tab in AppTab.values) {
      p.selectTab(tab.index);
      await settle(tester, 'the ${tab.name} tab');
    }

    p.selectTab(AppTab.project.index);
    await settle(tester, 'the project tab');
    for (final pane in [
      'rooms', 'parts', 'plans', 'timeline', 'deliveries', 'lifecycle',
      'responsibility', 'procurement', 'vendors', 'todo', 'notes',
    ]) {
      final key = find.byKey(ValueKey('project_pane_$pane'));
      expect(key, findsOneWidget, reason: pane);
      await tester.tap(key);
      await settle(tester, 'the $pane pane');
    }
  });

  testWidgets('every settings section opened and shut, the page scrolled',
      (tester) async {
    late AppStateProvider p;
    await tester.runAsync(() async => p = await job());
    await pumpApp(tester, p);
    p.toggleSettings();
    await settle(tester, 'settings');

    const titles = [
      'Pricing and estimates', 'Appearance', 'Editing behavior',
      'App updates', 'Autosave and recovery', 'Logging', 'Files and folders',
      'Working together', 'Data files', 'Shared lists', 'Processor connection',
    ];
    final scroll = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byType(AppSettingsView),
            matching: find.byType(Scrollable),
          ).first,
        )
        .position;
    Future<void> reveal(String text) async {
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      while (find.text(text).evaluate().isEmpty &&
          scroll.pixels < scroll.maxScrollExtent) {
        scroll.jumpTo(scroll.pixels + 200);
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(find.text(text).first);
      await tester.pumpAndSettle();
    }

    // Open, shut, open again - the toggle the 1 October crash came from.
    for (final title in titles) {
      for (var i = 0; i < 3; i++) {
        await reveal(title);
        await tester.tap(find.text(title).first);
        await settle(tester, '$title, toggle $i');
      }
    }
    // Everything open now: run down the whole page and back.
    while (scroll.pixels < scroll.maxScrollExtent) {
      scroll.jumpTo(scroll.pixels + 300);
      await settle(tester, 'scrolling settings down');
    }
    scroll.jumpTo(0);
    await settle(tester, 'scrolling settings back');
  });

  testWidgets('the profile, history and first-run windows open and close',
      (tester) async {
    late AppStateProvider p;
    await tester.runAsync(() async => p = await job());
    await pumpApp(tester, p);

    await tester.tap(find.byKey(const ValueKey('profile_button')));
    await settle(tester, 'the profile menu');
    await tester.tap(find.byKey(const ValueKey('profile_menu_profile')));
    await settle(tester, 'the profile window');
    await tester.enterText(
      find.byKey(const ValueKey('profile_name')),
      'Walk Through',
    );
    await settle(tester, 'typing a name');
    await tester.tap(find.text('Done'));
    await settle(tester, 'closing the profile');

    await tester.tap(find.byKey(const ValueKey('show_history')));
    await settle(tester, 'the history window');
    await tester.tap(find.byKey(const ValueKey('history_tab_finished')));
    await settle(tester, 'finished tasks');
    await tester.tap(find.byKey(const ValueKey('history_close')));
    await settle(tester, 'closing history');
  });

  testWidgets('a first-ever launch shows First-Time Setup', (tester) async {
    FirstRunSetupDialog.fileServerReachableForTest = true;
    addTearDown(() => FirstRunSetupDialog.fileServerReachableForTest = null);
    final p = AppStateProvider(autoLoadSettings: false)
      ..settingsLoaded = true
      ..firstRunSetupNeeded = true;
    await pumpApp(tester, p);
    expect(find.byType(FirstRunSetupDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
