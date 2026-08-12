import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/cabling_schematic.dart';
import 'package:extron_configurator/cabling_view.dart';
import 'package:extron_configurator/room_sidecar.dart' show AvUndoScope;

/// The router works out how a run gets from one box to the other, and it works
/// out something defensible. What it cannot know is which side of the building
/// the cable is actually pulled down — that follows the tray, the corridor and
/// the wall somebody is allowed to core. Bends are how the drawing says so.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  /// Two boxes with one run between them, all drawn by hand — the shape that
  /// makes a route predictable enough to assert on.
  ({AppStateProvider provider, CablingBundle run}) drawnRoom() {
    final p = room();
    final a = p.addCablingBox(kind: CablingBoxKind.pullBox);
    final b = p.addCablingBox(kind: CablingBoxKind.pathway);
    final run = p.addCablingBundle(
      fromBoxId: a.id,
      toBoxId: b.id,
      count: 2,
      cableType: 'Cat 6a',
    )!;
    return (provider: p, run: run);
  }

  Future<void> pumpTab(WidgetTester tester, AppStateProvider provider) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: CablingView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Clicks the only run on the drawing, the way a user picks one up.
  Future<void> selectTheRun(
    WidgetTester tester,
    AppStateProvider provider,
  ) async {
    final drawing = provider.cablingSchematic(buildAvFlowModel(provider));
    final origin = tester.getTopLeft(find.byType(InteractiveViewer));
    final from = drawing.boxes.first.rect.center;
    final to = drawing.boxes.last.rect.center;
    await tester.tapAt(origin + (from + to) / 2 - const Offset(0, 8));
    await tester.pumpAndSettle();
  }

  group('the drawing', () {
    test('keeps a run\'s bends, and hands it back when they are cleared', () {
      final p = room();
      p.setCablingBundleWaypoints('run:1', const [Offset(120, 300)]);
      expect(p.avCabling.waypoints['run:1'], const [Offset(120, 300)]);

      p.setCablingBundleWaypoints('run:1', const []);
      expect(p.avCabling.waypoints.containsKey('run:1'), isFalse);
    });

    test('carries them through the room file', () {
      final p = room();
      p.setCablingBundleWaypoints(
        'run:1',
        const [Offset(120, 300), Offset(420, 300)],
      );

      final back = CablingOverrides()..readJson(p.avCabling.toJson());
      expect(back.waypoints['run:1'], const [
        Offset(120, 300),
        Offset(420, 300),
      ]);
      // An empty entry is the absence of bends, and is not written.
      expect(CablingOverrides().toJson().containsKey('waypoints'), isFalse);
    });

    test('a removed run does not leave its bends behind', () {
      // A later run reusing the id would otherwise inherit somebody else's
      // route.
      final p = room();
      final a = p.addCablingBox(kind: CablingBoxKind.pullBox);
      final b = p.addCablingBox(kind: CablingBoxKind.pathway);
      final run = p.addCablingBundle(fromBoxId: a.id, toBoxId: b.id)!;
      p.setCablingBundleWaypoints(run.id, const [Offset(50, 50)]);

      p.removeCablingItem(run.id);
      expect(p.avCabling.waypoints.containsKey(run.id), isFalse);
    });

    test('a bend is undoable like any other edit to the sheet', () {
      final p = room();
      p.setCablingBundleWaypoints('run:1', const [Offset(10, 10)]);
      p.undoAvFlow(AvUndoScope.cabling);
      expect(p.avCabling.waypoints, isEmpty);
    });
  });

  group('the Cabling tab', () {
    testWidgets('grows handles on the run being worked on', (tester) async {
      final (:provider, :run) = drawnRoom();
      await pumpTab(tester, provider);

      // Nothing selected: no handles on the drawing at all.
      expect(find.byKey(ValueKey('cabling_add_bend_${run.id}_0')), findsNothing);

      await selectTheRun(tester, provider);
      expect(
        find.byKey(ValueKey('cabling_add_bend_${run.id}_0')),
        findsOneWidget,
      );

      // The hollow dot in the middle of a leg turns the run there.
      await tester.tap(find.byKey(ValueKey('cabling_add_bend_${run.id}_0')));
      await tester.pumpAndSettle();

      expect(provider.avCabling.waypoints[run.id], hasLength(1));
      expect(find.byKey(ValueKey('cabling_bend_${run.id}_0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the line follows the bend it was given', (tester) async {
      final (:provider, :run) = drawnRoom();
      await pumpTab(tester, provider);
      await selectTheRun(tester, provider);
      await tester.tap(find.byKey(ValueKey('cabling_add_bend_${run.id}_0')));
      await tester.pumpAndSettle();

      // Drag it well off the straight line. In steps, the way a pointer does
      // it: the handle and the sheet's own pan are both watching, and one jump
      // from end to end gives the arena nothing to decide on.
      final from = tester.getCenter(
        find.byKey(ValueKey('cabling_bend_${run.id}_0')),
      );
      final gesture = await tester.startGesture(from);
      await tester.pump(const Duration(milliseconds: 60));
      for (var step = 1; step <= 4; step++) {
        await gesture.moveTo(from + Offset(40.0 * step, 0));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final bend = provider.avCabling.waypoints[run.id]!.single;
      expect(bend.dx, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Straighten is the way back, and only offered when bent', (
      tester,
    ) async {
      final (:provider, :run) = drawnRoom();
      await pumpTab(tester, provider);
      await selectTheRun(tester, provider);

      expect(
        find.byKey(ValueKey('cabling_straighten_${run.id}')),
        findsNothing,
      );

      await tester.tap(find.byKey(ValueKey('cabling_add_bend_${run.id}_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('cabling_straighten_${run.id}')));
      await tester.pumpAndSettle();

      expect(provider.avCabling.waypoints.containsKey(run.id), isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}
