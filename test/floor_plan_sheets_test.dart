import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/room_locations.dart';

/// A room has more than one sheet as soon as it has more than one storey, a
/// reflected ceiling plan beside the furniture plan, or a demolition sheet
/// beside the new work. The model always held a list of plans; until now the
/// page only ever opened the first, so the second was unreachable.
void main() {
  AppStateProvider room() => AppStateProvider(autoLoadSettings: false)
    ..roomConfig = {
      'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
    };

  group('sheets in the provider', () {
    test('a new room has none, and the first added becomes the open one', () {
      final p = room();
      expect(p.activeFloorPlan, isNull);

      final first = p.addFloorPlanSheet(name: 'Level 1');
      expect(p.activeFloorPlan?.id, first.id);
      expect(p.avFloorPlans.single.name, 'Level 1');
    });

    test('adding a second opens it without disturbing the first', () {
      final p = room();
      final one = p.addFloorPlanSheet(name: 'Level 1');
      final two = p.addFloorPlanSheet(name: 'Level 2');

      expect(p.avFloorPlans.length, 2);
      expect(p.activeFloorPlan?.id, two.id);

      p.selectFloorPlan(one.id);
      expect(p.activeFloorPlan?.name, 'Level 1');
    });

    test('sheets are named for their number when nobody names them', () {
      final p = room();
      expect(p.addFloorPlanSheet().name, 'Sheet 1');
      expect(p.addFloorPlanSheet().name, 'Sheet 2');
    });

    test('duplicating carries the callouts, under a new id', () {
      final p = room();
      final source = p.addFloorPlanSheet(name: 'Level 1');
      p.addAvCallout(
        source.id,
        const FloorPlanCallout(id: '', tag: 'A', pos: Offset(10, 20)),
      );

      final copy = p.duplicateFloorPlanSheet(source.id)!;
      expect(copy.id, isNot(source.id));
      expect(copy.name, 'Level 1 copy');
      expect(copy.callouts.length, 1);
      expect(copy.callouts.single.tag, 'A');
      // The one it came from is untouched.
      expect(p.avFloorPlanById(source.id)!.callouts.length, 1);
      expect(p.activeFloorPlan?.id, copy.id);
    });

    test('sheets reorder, because a set is read in order', () {
      final p = room();
      final one = p.addFloorPlanSheet(name: 'Level 1');
      p.addFloorPlanSheet(name: 'Level 2');
      final rcp = p.addFloorPlanSheet(name: 'RCP');

      p.moveFloorPlanSheet(rcp.id, 0);
      expect(p.avFloorPlans.map((s) => s.name), ['RCP', 'Level 1', 'Level 2']);

      // Off the end clamps rather than throwing.
      p.moveFloorPlanSheet(one.id, 99);
      expect(p.avFloorPlans.last.name, 'Level 1');
    });

    test('removing the open sheet lands on one that still exists', () {
      final p = room();
      final one = p.addFloorPlanSheet(name: 'Level 1');
      final two = p.addFloorPlanSheet(name: 'Level 2');
      expect(p.activeFloorPlan?.id, two.id);

      p.removeAvFloorPlan(two.id);
      expect(p.activeFloorPlan?.id, one.id);

      p.removeAvFloorPlan(one.id);
      expect(p.activeFloorPlan, isNull);
    });

    test('the open sheet does not follow the user into another room', () {
      final p = room();
      p.addFloorPlanSheet(name: 'Level 1');
      p.addFloorPlanSheet(name: 'Level 2');

      // What opening a different config does.
      p.loadAvFlowForCurrentConfig();
      expect(p.avFloorPlans, isEmpty);
      expect(p.activeFloorPlan, isNull);
    });

    test('every sheet round trips through the split sidecar', () async {
      final dir = Directory.systemTemp.createTempSync('floor_plan_sheets_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final configPath = path.join(dir.path, 'BSS103_config.json');
      File(configPath).writeAsStringSync('{}');

      final p = room()..currentConfigPath = configPath;
      p.addFloorPlanSheet(name: 'Level 1');
      p.addFloorPlanSheet(name: 'Level 2');
      p.addFloorPlanSheet(name: 'RCP');
      await p.saveAvFlow();

      // They live in the floor plan file, not the flow one.
      expect(
        File(path.join(dir.path, 'BSS103_config_floor_plans.json'))
            .readAsStringSync(),
        contains('RCP'),
      );

      final back = AppStateProvider(autoLoadSettings: false)
        ..currentConfigPath = configPath
        ..loadAvFlowForCurrentConfig();
      expect(
        back.avFloorPlans.map((s) => s.name),
        ['Level 1', 'Level 2', 'RCP'],
      );
    });
  });

  group('the sheet bar', () {
    /// Sheets are added AFTER this: opening the tab calls
    /// ensureAvFlowForCurrentConfig, which reloads — and therefore clears —
    /// the document the first time it sees a config.
    AppStateProvider synced() => room()..loadAvFlowForCurrentConfig();

    Future<void> pump(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1600, 1100);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: FloorPlanView())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('stays out of the way until there is a sheet', (tester) async {
      final p = synced();
      await pump(tester, p);
      expect(find.byType(InputChip), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('lists the sheets and switches between them', (tester) async {
      final p = synced();
      final one = p.addFloorPlanSheet(name: 'Level 1');
      p.addFloorPlanSheet(name: 'Level 2');
      await pump(tester, p);

      expect(find.widgetWithText(InputChip, 'Level 1'), findsOneWidget);
      expect(find.widgetWithText(InputChip, 'Level 2'), findsOneWidget);
      expect(p.activeFloorPlan?.name, 'Level 2');

      await tester.tap(find.widgetWithText(InputChip, 'Level 1'));
      await tester.pumpAndSettle();
      expect(p.activeFloorPlan?.id, one.id);
      expect(tester.takeException(), isNull);
    });

    testWidgets('adds a sheet and asks what to call it', (tester) async {
      final p = synced()..addFloorPlanSheet(name: 'Level 1');
      await pump(tester, p);

      await tester.tap(find.widgetWithText(TextButton, 'Add sheet'));
      await tester.pumpAndSettle();

      expect(find.text('New sheet'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Reflected ceiling');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pumpAndSettle();

      expect(p.avFloorPlans.map((s) => s.name),
          ['Level 1', 'Reflected ceiling']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('will not offer to delete the only sheet', (tester) async {
      final p = synced()..addFloorPlanSheet(name: 'Level 1');
      await pump(tester, p);
      expect(
        tester
            .widget<InputChip>(find.widgetWithText(InputChip, 'Level 1'))
            .onDeleted,
        isNull,
      );
    });
  });
}
