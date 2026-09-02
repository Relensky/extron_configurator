import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';
import 'package:extron_configurator/undo_bar.dart';

/// THE PAIR IN THE TITLE BAR, PRESSED.
///
/// The wizard, the device forms, system settings, the raw JSON and the Project
/// tab have no canvas to hang buttons off, so their Undo lives next to Save and
/// acts on whichever document the page in front of you edits.
///
/// The failure this guards is the one somebody reported: reaching for an undo
/// arrow in the title bar and getting something else. There were two arrows up
/// there — this pair, and a button that restored a file backup — and the wrong
/// one answered. So what has to hold is that the pair is present exactly where
/// it means something, absent where the page has its own, and that pressing it
/// moves the document it claims to.
void main() {
  Future<void> pumpOn(WidgetTester tester, AppStateProvider p, AppTab tab) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    p.settingsLoaded = true;
    p.firstRunSetupNeeded = false;
    p.selectTab(tab.index);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  AppStateProvider job() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    return p;
  }

  Finder undo() => find.byKey(const ValueKey('toolbar_undo'));
  Finder redo() => find.byKey(const ValueKey('toolbar_redo'));

  /// Presses a button and lets the bar it raises close itself — every undo in
  /// the app says what it did, on a timer.
  Future<void> press(WidgetTester tester, Finder button) async {
    await tester.tap(button);
    await tester.pumpAndSettle(const Duration(seconds: 6));
  }

  group('where the pair belongs', () {
    test('the job and the three app documents each get their own', () {
      expect(toolbarUndoTarget(AppTab.project), ToolbarUndoTarget.project);
      expect(toolbarUndoTarget(AppTab.deviceEditor), ToolbarUndoTarget.catalog);
      expect(toolbarUndoTarget(AppTab.schemaEditor), ToolbarUndoTarget.schema);
      expect(toolbarUndoTarget(AppTab.flowRules), ToolbarUndoTarget.flowRules);
    });

    test('EVERY page that edits the room answers with the room', () {
      // The point of the arrangement. These eleven pages are eleven views of
      // one room, and they used to answer this six different ways — a pair on
      // each drawing, one on the estimate, one on the schematic, one up here
      // for the config. Taking back the last thing you did meant first
      // remembering which tab you did it on, which is the one thing somebody
      // reaching for Undo has lost track of.
      for (final tab in [
        AppTab.wizard,
        AppTab.devices,
        AppTab.system,
        AppTab.rawJson,
        AppTab.cost,
        AppTab.lifecycle,
        AppTab.schematic,
        AppTab.avFlow,
        AppTab.floorPlan,
        AppTab.cabling,
        AppTab.racks,
      ]) {
        expect(toolbarUndoTarget(tab), ToolbarUndoTarget.room,
            reason: '${tab.name} is a view of the room');
      }
    });

    test('settings are not a document, and get no pair', () {
      expect(toolbarUndoTarget(AppTab.appConfig), isNull);
    });
  });

  group('on the Project tab', () {
    testWidgets('the pair is there, and dark on a job nobody has edited',
        (tester) async {
      final p = job();
      await pumpOn(tester, p, AppTab.project);

      expect(undo(), findsOneWidget);
      expect(redo(), findsOneWidget);
      // An Undo that is lit and does nothing when pressed is the whole
      // complaint this file exists for.
      expect(tester.widget<IconButton>(undo()).onPressed, isNull);
      expect(tester.widget<IconButton>(redo()).onPressed, isNull);
    });

    testWidgets('it takes back an edit to the job, and gives it back',
        (tester) async {
      final p = job();
      await pumpOn(tester, p, AppTab.project);

      final row = p.addProjectDelivery(itemName: 'Wall plate', qty: 18);
      // The boundary a dialog closing or a tab changing puts in. Without one,
      // adding the delivery and editing it are a single step - which is the
      // intended behavior, and not what this test is about.
      p.recordUndoPoint();
      p.updateProjectDelivery(row.copyWith(qty: 12), summary: 'edited - qty');
      await tester.pumpAndSettle();

      expect(tester.widget<IconButton>(undo()).onPressed, isNotNull,
          reason: 'there is an edit behind it');
      // The step is named, so the tooltip answers "what am I about to undo".
      expect(tester.widget<IconButton>(undo()).tooltip, contains('Undo'));

      await press(tester, undo());
      expect(p.project.deliveries.single.qty, 18);

      await press(tester, redo());
      expect(p.project.deliveries.single.qty, 12);
    });
  });

  group('on a room page', () {
    testWidgets('it takes back an edit to the config', (tester) async {
      final p = job();
      p.currentConfigPath = 'BSS_103_config.json';
      p.roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Bessey 103'},
        'DISPLAY_1': {'model': 'NEC C651Q'},
      };
      await pumpOn(tester, p, AppTab.system);

      // Edited the way a form edits it: straight into the map, then a
      // notification. Nothing about this feature is instrumented per call
      // site, which is the point.
      p.roomConfig['DISPLAY_1']['model'] = 'Sony FW-65';
      p.notifyListeners();
      await tester.pumpAndSettle();

      expect(tester.widget<IconButton>(undo()).onPressed, isNotNull);
      await press(tester, undo());

      expect(p.roomConfig['DISPLAY_1']['model'], 'NEC C651Q');
    });
  });
}
