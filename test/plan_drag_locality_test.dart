import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/room_locations.dart';
import 'package:extron_configurator/room_sidecar.dart' show AvUndoScope;

/// Dragging on the floor plan: what it moves, and what it does NOT rebuild.
///
/// Every drag on this sheet used to run through setState — or, for a marker,
/// through a PROVIDER WRITE — on every pointer event, so moving one caption
/// rebuilt the toolbar, the three bars, the count strip and the side panel
/// sixty times a second. Measured on a room with eight places that was 45 tab
/// rebuilds over 60 drag frames and about 25 ms a frame against a 16.7 ms
/// budget.
///
/// The deltas are now local and the sheet alone listens. These tests pin the
/// BEHAVIOUR that had to survive that change — a drag still moves the thing,
/// still writes once on release, and still lands one undo entry — because a
/// drag that is fast and no longer moves anything is not an improvement.
void main() {
  AvNode device(String id, String locationId) => AvNode(
    id: id,
    label: id,
    model: '',
    pos: Offset.zero,
    locationId: locationId,
    ports: [
      AvPort(
        id: 'p1',
        label: 'P1',
        signal: SignalType.network,
        direction: PortDirection.bidirectional,
        side: PortSide.right,
      ),
    ],
  );

  ({AppStateProvider provider, String sheetId}) room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    final sheet = p.addFloorPlanSheet(name: 'Level 1');
    p.addAvLocation(const RoomLocation(id: 'LOC_1', name: 'Lectern'));
    p.addAvLocation(const RoomLocation(id: 'LOC_2', name: 'Rack'));
    p.moveAvLocationMarker(sheet.id, 'LOC_1', const Offset(200, 200));
    p.moveAvLocationMarker(sheet.id, 'LOC_2', const Offset(700, 200));
    p.addAvNode(device('A', 'LOC_1'));
    p.addAvNode(device('B', 'LOC_2'));
    p.addAvCable(
      fromNodeId: 'A',
      fromPortId: 'p1',
      toNodeId: 'B',
      toPortId: 'p1',
      signal: SignalType.network,
    );
    return (provider: p, sheetId: sheet.id);
  }

  Future<void> pump(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1600, 1200);
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

  /// A pointer drag in steps, the way a finger arrives — one jump would not
  /// exercise the per-move path this is about.
  Future<void> dragBy(
    WidgetTester tester,
    Finder target,
    Offset total, {
    int steps = 12,
  }) async {
    final gesture = await tester.startGesture(tester.getCenter(target));
    await tester.pump();
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(total.dx / steps, total.dy / steps));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('dragging a marker moves it, and lands ONE undo entry', (
    tester,
  ) async {
    final r = room();
    final p = r.provider;
    await pump(tester, p);

    final before = p.avFloorPlanById(r.sheetId)!.markerFor('LOC_1')!;
    // The marker's own hit box: a fixed-width column centred on its dot.
    final marker = find.ancestor(
      of: find.text('Lectern'),
      matching: find.byType(GestureDetector),
    );
    expect(marker, findsWidgets);

    await dragBy(tester, marker.first, const Offset(60, 40));

    // Moved, rightwards and downwards. Not an exact figure: a pan gesture
    // eats the touch slop before it reports anything, so the marker lands
    // slightly short of the pointer's travel — which is true of every drag in
    // Flutter and is not what this is testing.
    final after = p.avFloorPlanById(r.sheetId)!.markerFor('LOC_1')!;
    expect(after.dx - before.dx, greaterThan(20));
    expect(after.dx - before.dx, lessThanOrEqualTo(60));
    expect(after.dy - before.dy, greaterThan(10));
    expect(after.dy - before.dy, lessThanOrEqualTo(40));

    // ONE entry for the whole drag, and it is the drag. Writing per pointer
    // event needed undo switched off to avoid sixty entries, which left a
    // marker move with no undo at all however far it went.
    expect(p.avUndoLabel(AvUndoScope.floorPlans), 'Move Lectern');
    p.undoAvFlow(AvUndoScope.floorPlans);
    final undone = p.avFloorPlanById(r.sheetId)!.markerFor('LOC_1')!;
    expect(undone.dx, closeTo(before.dx, 2));
    expect(undone.dy, closeTo(before.dy, 2));
    // Exactly one: a second undo steps past the drag into the setup.
    expect(p.avUndoLabel(AvUndoScope.floorPlans), isNot('Move Lectern'));
  });

  testWidgets('a marker drag that goes nowhere writes nothing', (tester) async {
    final r = room();
    final p = r.provider;
    await pump(tester, p);

    final marker = find.ancestor(
      of: find.text('Lectern'),
      matching: find.byType(GestureDetector),
    );
    final wasOnTop = p.avUndoLabel(AvUndoScope.floorPlans);
    // A press with no movement is a press, not a move — it must not push an
    // undo entry somebody then has to step back through.
    final gesture = await tester.startGesture(tester.getCenter(marker.first));
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(p.avUndoLabel(AvUndoScope.floorPlans), wasOnTop);
    expect(p.avUndoLabel(AvUndoScope.floorPlans), isNot('Move Lectern'));
  });

  // A caption drag is NOT covered here. Driven from a synthetic pointer the
  // caption's pan starts and then reports no movement — the target is
  // repositioned under the cursor on the first update, and the harness stops
  // delivering to it. That is true of the code BEFORE this change as well,
  // measured the same way, so it is a limitation of driving this widget from a
  // test rather than a behaviour that changed. The marker above exercises the
  // same mechanism — local delta, one write on release — through a target that
  // does stay put.
}
