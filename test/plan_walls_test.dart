import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/placed_devices.dart';
import 'package:extron_configurator/projection_calc.dart';
import 'package:extron_configurator/projection_calculator_dialog.dart';
import 'package:extron_configurator/room_locations.dart';

/// The room's walls on a floor plan: their sizes, the ceiling, the area, how
/// far a device is from each, and what the calculator makes of them.
void main() {
  // 20 px to the foot: 24 ft wide, 30 ft deep.
  const walls = PlanWalls(
    rect: Rect.fromLTWH(100, 100, 480, 600),
    ceilingFt: 9,
  );

  test('the walls are named from the front, and measured', () {
    expect(walls.squareFeet(20), 720);
    expect(walls.frontLength, 480);
    expect(walls.depth, 600);
    final d = walls.distancesFrom(const Offset(200, 300));
    expect(d, {'Front': 200, 'Back': 400, 'Left': 100, 'Right': 380});

    // The front on the left of the sheet: its left is the bottom.
    final turned = walls.copyWith(front: PlanWallSide.left);
    expect(turned.named['Left'], PlanWallSide.bottom);
    expect(turned.frontLength, 600);
    expect(turned.depth, 480);

    final back = PlanWalls.fromJson(turned.toJson())!;
    expect(back.rect, turned.rect);
    expect(back.front, PlanWallSide.left);
    expect(back.ceilingFt, 9);
    final plan = FloorPlan(id: 'PLAN_1', name: 'Plan', walls: walls);
    expect(FloorPlan.fromJson(plan.toJson()).walls!.rect, walls.rect);
  });

  testWidgets('walls are drawn from two corners and sized in feet', (
    tester,
  ) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addFloorPlanSheet(name: 'Level 1');
    final plan = p.activeFloorPlan!;
    p.updateAvFloorPlan(plan.copyWith(pixelsPerFoot: 20));
    p.addAvPlanDevice(
      plan.id,
      const PlanDevice(
        id: '',
        deviceKey: 'projector',
        label: 'Projector',
        shape: 'projector',
        pos: Offset(220, 260),
      ),
    );
    tester.view.physicalSize = const Size(1700, 1300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: FloorPlanView())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('plan_room_walls')));
    await tester.pumpAndSettle();
    final sheet = tester.getTopLeft(find.byType(InteractiveViewer));
    await tester.tapAt(sheet + const Offset(100, 100));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(sheet + const Offset(400, 400));
    await tester.pumpAndSettle();

    // What was drawn, typed over with the real sizes.
    await tester.enterText(find.byKey(const ValueKey('walls_width')), '24\'');
    await tester.enterText(find.byKey(const ValueKey('walls_depth')), '30\'');
    await tester.enterText(
        find.byKey(const ValueKey('walls_ceiling')), '9\'6"');
    await tester.pump();
    expect(find.text('720 sq ft'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('walls_save')));
    await tester.pumpAndSettle();

    final saved = p.activeFloorPlan!.walls!;
    expect(saved.rect.size, const Size(480, 600));
    expect(saved.ceilingFt, closeTo(9.5, 0.001));
    expect(find.textContaining('720 sq ft'), findsWidgets);

    // A device says how far it is from each wall.
    await tester.tap(find.byWidgetPredicate(
      (w) => w is Tooltip && (w.message ?? '').startsWith('Projector\n'),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    final line = tester
        .widget<Text>(find.byKey(const ValueKey('plan_device_walls')))
        .data!;
    expect(line, startsWith('Front '));
    expect(line, contains('Back '));
    expect(tester.takeException(), isNull);
  });

  group('the calculator against the room', () {
    Future<void> open(
      WidgetTester tester, {
      required double depth,
      double ceilingFt = 9,
    }) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      resetProjectionUnits();
      addTearDown(resetProjectionUnits);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectionCalculatorDialog(
              specs: const [
                ProjectorSpecs(source: 'PJ', throwMin: 2, throwMax: 2),
              ],
              roomCeilingFt: ceilingFt,
              roomDepthFt: depth,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    String ceiling(WidgetTester tester) => tester
        .widget<TextField>(find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'Ceiling',
        ))
        .controller!
        .text;

    testWidgets('the ceiling is the room\'s, and the drop is shown', (
      tester,
    ) async {
      // A 120" image from 4 ft up tops out at about 9' 4".
      await open(tester, depth: 40, ceilingFt: 10);
      expect(ceiling(tester), "10'");
      expect(find.byKey(const ValueKey('projection_drop')), findsOneWidget);
      expect(find.byKey(const ValueKey('projection_room_warning')),
          findsNothing);
    });

    testWidgets('too big a screen, or too long a throw, is called out', (
      tester,
    ) async {
      // A 120" screen at a 2:1 throw is about 17 ft out; the room is 12.
      await open(tester, depth: 12, ceilingFt: 10);
      expect(
        find.textContaining('longer than the room is deep'),
        findsOneWidget,
      );
      // 200" from 4 ft up runs well above a 9 ft ceiling.
      await tester.enterText(
          find.byKey(const ValueKey('projection_size')), '200');
      await tester.pump();
      expect(find.textContaining('above the ceiling'), findsOneWidget);
      expect(find.byKey(const ValueKey('projection_drop')).evaluate().isEmpty
          ? 'none'
          : tester
              .widget<Text>(find.byKey(const ValueKey('projection_drop')))
              .data, 'none');
    });
  });
}
