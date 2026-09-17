import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_only_notice.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/estimate_settings_section.dart';
import 'package:extron_configurator/main.dart';
import 'package:extron_configurator/nav_rail.dart';
import 'package:extron_configurator/room_sidecar.dart';

/// Estimate-only rooms, and the scope, notes and PDF settings on the Cost tab.
void main() {
  AppStateProvider room({bool estimate = true}) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room', 'gve_room': '103'},
      };
    p.loadAvFlowForCurrentConfig();
    if (estimate) p.setRoomMode(RoomMode.estimate);
    return p;
  }

  group('room mode', () {
    test('rooms saved as AV only open as estimates', () {
      expect(roomModeFromName('avOnly'), RoomMode.estimate);
      expect(roomModeFromName('estimate'), RoomMode.estimate);
      expect(roomModeFromName('full'), RoomMode.full);
      expect(roomModeFromName(null), RoomMode.full);
    });

    test('is written to the room file', () {
      final p = room();
      expect(p.avFlowAsJson()['roomMode'], 'estimate');
      expect(p.hasAvFlow, isTrue);
    });
  });

  group('the rail', () {
    test('an estimate hides the Wizard, Devices, System and Raw JSON', () {
      final tabs = visibleNavTabs(estimateOnly: true).map((t) => t.tab);
      for (final hidden in [
        AppTab.wizard,
        AppTab.devices,
        AppTab.system,
        AppTab.rawJson,
      ]) {
        expect(tabs, isNot(contains(hidden)));
      }
      expect(
        tabs,
        containsAll([AppTab.cost, AppTab.schematic, AppTab.avFlow]),
      );
      expect(visibleNavTabs(estimateOnly: false), kNavTabs);
    });

    testWidgets('the app rail follows the mode', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final p = room();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const RoomConfigApp(),
        ),
      );
      await tester.pump();

      Iterable<AppTab> railTabs() => tester
          .widgetList<NavRailRow>(find.byType(NavRailRow))
          .map((r) => r.tab.tab);
      expect(railTabs(), isNot(contains(AppTab.devices)));
      expect(railTabs(), contains(AppTab.avFlow));

      p.setRoomMode(RoomMode.full);
      await tester.pump();
      expect(railTabs(), contains(AppTab.devices));
      expect(railTabs(), contains(AppTab.wizard));
    });
  });

  group('scope of work and notes', () {
    test('round trip through the room file', () {
      final settings = RoomCostSettings()
        ..scopeOfWork = 'Replace the projector'
        ..notes = 'Valid 30 days';
      expect(settings.isEmpty, isFalse);
      final copy = RoomCostSettings()..readJson(settings.toJson());
      expect(copy.scopeOfWork, 'Replace the projector');
      expect(copy.notes, 'Valid 30 days');
      copy.clear();
      expect(copy.isEmpty, isTrue);
      expect(RoomCostSettings().toJson().containsKey('scopeOfWork'), isFalse);
    });

    test('edits can be undone', () {
      final p = room();
      p.setAvCostScopeOfWork('Replace');
      p.setAvCostNotes('Net 30');
      expect(p.avCost.scopeOfWork, 'Replace');
      p.undoAvFlow(AvUndoScope.cost);
      expect(p.avCost.notes, '');
      p.undoAvFlow(AvUndoScope.cost);
      expect(p.avCost.scopeOfWork, '');
    });
  });

  group('estimate PDF settings', () {
    test('are saved with the app settings', () async {
      final p = AppStateProvider(autoLoadSettings: false);
      await p.updateSetting('estimateLogoPath', '  C:/logo.png ');
      await p.updateSetting('estimatePreparedBy', 'Pat');
      await p.updateSetting('estimatePreparerContact', 'pat@example.edu');
      final json = p.settingsAsJson();
      expect(json['estimateLogoPath'], 'C:/logo.png');
      expect(json['estimatePreparedBy'], 'Pat');
      expect(json['estimatePreparerContact'], 'pat@example.edu');
    });

    testWidgets('App Config edits the preparer', (tester) async {
      final p = AppStateProvider(autoLoadSettings: false);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: EstimateSettingsSection()),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('estimate_prepared_by')),
        'Pat Estimator',
      );
      await tester.pump();
      expect(p.estimatePreparedBy, 'Pat Estimator');
    });

    test('the project name is only printed for a room on the project', () {
      final p = room();
      expect(estimateProjectName(p), '');
    });
  });

  group('the Cost tab', () {
    Future<void> pump(
      WidgetTester tester,
      AppStateProvider p, {
      Brightness? capturing,
    }) async {
      tester.view.physicalSize = const Size(1700, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(
              body: CostEstimateView(
                key: ValueKey(capturing),
                debugCaptureBrightness: capturing,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('an estimate offers the room number and conversion', (
      tester,
    ) async {
      await pump(tester, room());
      expect(find.text('Scope of Work'), findsOneWidget);
      expect(find.text('Room number'), findsOneWidget);
      expect(find.byKey(const ValueKey('convert_to_programmed')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Estimate Notes'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Estimate Notes'), findsOneWidget);
    });

    testWidgets('a programmed room has no convert button', (tester) async {
      await pump(tester, room(estimate: false));
      expect(find.text('Scope of Work'), findsOneWidget);
      expect(find.byKey(const ValueKey('convert_to_programmed')), findsNothing);
      expect(find.text('Room number'), findsNothing);
    });

    testWidgets('empty scope and notes stay off the screenshot', (
      tester,
    ) async {
      await pump(tester, room(), capturing: Brightness.light);
      expect(find.text('Scope of Work'), findsNothing);
      expect(find.text('Estimate Notes'), findsNothing);
      expect(find.byKey(const ValueKey('convert_to_programmed')), findsNothing);
    });

    testWidgets('filled-in scope prints as text', (tester) async {
      final p = room()..setAvCostScopeOfWork('Replace both projectors');
      await pump(tester, p, capturing: Brightness.light);
      expect(find.text('Scope of Work'), findsOneWidget);
      expect(find.text('Replace both projectors'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('converting', () {
    testWidgets('brings the room back to programmed and opens the Wizard', (
      tester,
    ) async {
      final p = room();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(
            home: Scaffold(
              body: ControlSystemPlaceholder(tabName: 'the Devices tab'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('convert_to_programmed')));
      await tester.pumpAndSettle();
      expect(find.text('Convert to a programmed room?'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Convert'));
      await tester.pumpAndSettle();
      expect(p.roomMode, RoomMode.full);
      expect(p.selectedTabIndex, AppTab.wizard.index);
    });

    testWidgets('cancel leaves it an estimate', (tester) async {
      final p = room();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(
            home: Scaffold(body: ConvertToProgrammedRoomButton()),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('convert_to_programmed')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(p.isEstimateRoom, isTrue);
    });
  });
}
