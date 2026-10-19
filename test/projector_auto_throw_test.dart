import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/placed_devices.dart';
import 'package:extron_configurator/projection_calc.dart';
import 'package:extron_configurator/room_sidecar.dart';

/// A projector on Auto from screen: reach to its screen, and the angle that
/// fills it inside the lens zoom.
void main() {
  // 20 px to the foot: a 10 ft wide screen 15 ft from the projector.
  const screen = PlanDevice(
    id: 'DEV_2',
    deviceKey: 'screen',
    label: 'Screen',
    shape: 'screen',
    pos: Offset(500, 100),
    width: 200,
  );
  const projector = PlanDevice(
    id: 'DEV_1',
    deviceKey: 'projector',
    label: 'Projector',
    shape: 'projector',
    pos: Offset(500, 400),
    autoThrow: true,
  );

  test('reaches the screen and fills its width', () {
    final f = fittedThrow(projector, screen);
    expect(f.range, 300);
    expect(f.zoom, 0);
    // 15 ft to fill 10 ft is a 1.5:1 throw.
    expect(f.fov, closeTo(beamAngleForRatio(1.5), 0.01));
    expect(imageWidthForBeam(f.range, f.fov), closeTo(200, 0.5));
  });

  test('held inside the lens zoom, and says which way it is out', () {
    final fits = fittedThrow(projector, screen, throwMin: 1.2, throwMax: 2.0);
    expect(fits.zoom, 0);
    expect(fits.fov, closeTo(beamAngleForRatio(1.5), 0.01));

    // A long lens this close cannot get wide enough.
    final tooClose =
        fittedThrow(projector, screen, throwMin: 2.0, throwMax: 3.0);
    expect(tooClose.zoom, -1);
    expect(tooClose.fov, closeTo(beamAngleForRatio(2.0), 0.01));

    // A short lens this far cannot get narrow enough.
    final tooFar =
        fittedThrow(projector, screen, throwMin: 0.8, throwMax: 1.0);
    expect(tooFar.zoom, 1);
    expect(tooFar.fov, closeTo(beamAngleForRatio(1.0), 0.01));
  });

  test('saved and read back; the screen is never resized to follow it', () {
    expect(PlanDevice.fromJson(projector.toJson()).autoThrow, isTrue);
    final moved = withProjectionLinked(
      [projector, screen],
      projector.copyWith(fov: 30, range: 900),
    );
    expect(moved.firstWhere((d) => d.id == 'DEV_2').width, 200);
  });

  testWidgets('the floor plan draws and reads out the fitted throw', (
    tester,
  ) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addFloorPlanSheet(name: 'Level 1');
    p.addAvCostExtraEquipment(description: 'Projector');
    p.addAvCostExtraEquipment(description: 'Screen');
    final plan = p.activeFloorPlan!;
    p.updateAvFloorPlan(plan.copyWith(pixelsPerFoot: 20));
    p.addAvPlanDevice(plan.id, screen.copyWith(id: '', deviceKey: 'screen'));
    p.addAvPlanDevice(
        plan.id, projector.copyWith(id: '', deviceKey: 'projector'));
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

    await tester.tap(find.byWidgetPredicate(
      (w) => w is Tooltip && (w.message ?? '').startsWith('Projector\n'),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    final angle = beamAngleForRatio(1.5).round();
    expect(find.text("$angle° · 15'"), findsOneWidget);

    // Turned off, the beam it was showing is kept to edit by hand.
    await tester.tap(find.byKey(const ValueKey('plan_device_auto_throw')));
    await tester.pumpAndSettle();
    final kept = p.activeFloorPlan!.devices
        .firstWhere((d) => d.shape == 'projector');
    expect(kept.autoThrow, isFalse);
    expect(kept.range, closeTo(300, 0.01));
    expect(kept.fov, closeTo(beamAngleForRatio(1.5), 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a screen is placed by size when its model is not known', (
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

    // Nothing on the estimate, and it is still on the menu.
    await tester.tap(find.byKey(const ValueKey('plan_add_device')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add_device_generic_screen')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen_size_133')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen_size_ok')));
    await tester.pumpAndSettle();

    final sheet = tester.getTopLeft(find.byType(InteractiveViewer));
    await tester.tapAt(sheet + const Offset(300, 300));
    await tester.pumpAndSettle();

    final screen = p.activeFloorPlan!.devices.single;
    expect(screen.shape, 'screen');
    expect(screen.label, 'Screen 133" 16:10');
    final want = imageFromDiagonal(133 / 12, kScreenAspects.first).width * 20;
    expect(screen.width, closeTo(want, 0.01));

    // Sized again from its bar.
    await tester.tap(find.byKey(const ValueKey('plan_device_screen_size')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen_size_100')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen_size_ok')));
    await tester.pumpAndSettle();
    expect(
      p.activeFloorPlan!.devices.single.width,
      closeTo(imageFromDiagonal(100 / 12, kScreenAspects.first).width * 20,
          0.01),
    );

    // Or measured on the wall, in feet and inches.
    await tester.tap(find.byKey(const ValueKey('plan_device_screen_size')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('screen_size_measured')), '11\'8" x 6\'5"');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen_size_ok')));
    await tester.pumpAndSettle();
    expect(p.activeFloorPlan!.devices.single.width,
        closeTo((11 + 8 / 12) * 20, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('several screens are dropped in a row and numbered', (
    tester,
  ) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addFloorPlanSheet(name: 'Level 1');
    final plan = p.activeFloorPlan!;
    p.updateAvFloorPlan(plan.copyWith(pixelsPerFoot: 10));
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

    await tester.tap(find.byKey(const ValueKey('plan_add_device')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add_device_generic_screen')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen_size_100')));
    await tester.enterText(find.byKey(const ValueKey('screen_size_count')), '3');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen_size_ok')));
    await tester.pumpAndSettle();
    final sheet = tester.getTopLeft(find.byType(InteractiveViewer));
    await tester.tapAt(sheet + const Offset(200, 300));
    await tester.pumpAndSettle();

    final screens = p.activeFloorPlan!.devices;
    expect(screens.map((d) => d.label), ['Screen 1', 'Screen 2', 'Screen 3']);
    expect(screens[1].pos.dx, greaterThan(screens[0].pos.dx + screens[0].width));
    expect(screens.map((d) => d.pos.dy).toSet(), hasLength(1));
    expect(p.avUndoLabel(AvUndoScope.floorPlans), 'Place 3 devices');
    expect(tester.takeException(), isNull);
  });
}
