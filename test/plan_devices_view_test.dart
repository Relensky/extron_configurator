import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/placed_devices.dart';

/// Placing the estimate's devices on a floor plan sheet.
void main() {
  Future<AppStateProvider> pump(WidgetTester tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addFloorPlanSheet(name: 'Level 1');
    p.addAvCostExtraEquipment(description: 'PTZ Camera');
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
    return p;
  }

  testWidgets('a line of known length sets the scale', (tester) async {
    final p = await pump(tester);

    await tester.tap(find.byKey(const ValueKey('plan_set_scale')));
    await tester.pumpAndSettle();
    final sheet = tester.getTopLeft(find.byType(InteractiveViewer));
    await tester.tapAt(sheet + const Offset(100, 300));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(sheet + const Offset(300, 300));
    await tester.pumpAndSettle();

    expect(find.text('It is 200 px on the sheet.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('plan_scale_feet')),
      '10',
    );
    await tester.tap(find.byKey(const ValueKey('plan_scale_save')));
    await tester.pumpAndSettle();

    expect(p.activeFloorPlan!.pixelsPerFoot, closeTo(20, 0.01));
    expect(find.text('Scale: 20.0 px/ft'), findsOneWidget);
  });

  testWidgets('pick from the menu, click the sheet, turn it, show its cone', (
    tester,
  ) async {
    final p = await pump(tester);

    await tester.tap(find.byKey(const ValueKey('plan_add_device')));
    await tester.pumpAndSettle();
    expect(find.text('0 / 1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add_device_ptz camera')));
    await tester.pumpAndSettle();
    expect(find.text('Placing PTZ Camera'), findsOneWidget);

    final sheet = tester.getTopLeft(find.byType(InteractiveViewer));
    await tester.tapAt(sheet + const Offset(300, 300));
    await tester.pumpAndSettle();

    var device = p.activeFloorPlan!.devices.single;
    expect(device.shape, 'camera');
    // The only one bought is placed, so the sheet is no longer armed.
    expect(find.text('Placing PTZ Camera'), findsNothing);

    // Placing it selects it, so its bar is up.
    await tester.tap(find.byIcon(Icons.rotate_right));
    await tester.pumpAndSettle();
    device = p.activeFloorPlan!.devices.single;
    expect(device.rotation, 15);

    await tester.tap(find.byKey(const ValueKey('plan_device_fov')));
    await tester.pumpAndSettle();
    expect(p.activeFloorPlan!.devices.single.showFov, isTrue);

    // The angle slider in the bar moves the cone and saves on release.
    final before = p.activeFloorPlan!.devices.single.fov;
    await tester.drag(
      find.byKey(const ValueKey('plan_device_bar_fov')),
      const Offset(60, 0),
    );
    await tester.pumpAndSettle();
    expect(p.activeFloorPlan!.devices.single.fov, greaterThan(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the room keeps a throw distance typed in feet and inches', (
    tester,
  ) async {
    final p = await pump(tester);

    await tester.tap(find.byKey(const ValueKey('plan_throw_distance')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('throw_distance_feet')),
      '18',
    );
    await tester.enterText(
      find.byKey(const ValueKey('throw_distance_inches')),
      '6',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(p.avThrowDistanceFt, 18.5);
    expect(find.text('Throw 18\' 6"'), findsOneWidget);
    expect(p.avFlowAsJson()['throwDistanceFt'], 18.5);

    // The calculator starts from it.
    await tester.tap(find.byKey(const ValueKey('plan_projection_calculator')));
    await tester.pumpAndSettle();
    expect(find.text("the room's throw distance"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the room light is set from the floor plan', (tester) async {
    final p = await pump(tester);

    await tester.tap(find.byKey(const ValueKey('plan_room_light')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('room_light_fc')), '20');
    await tester.tap(find.byKey(const ValueKey('room_light_contrast')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Full-motion video (80:1)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(p.avRoomLightFc, 20);
    expect(p.avContrastTarget, 80);
    expect(p.avFlowAsJson()['roomLight'], {'fc': 20.0, 'contrast': 80.0});
    expect(find.text('Room light 20 fc · 80:1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Measure shows once the sheet has a scale', (tester) async {
    final p = await pump(tester);
    expect(find.byKey(const ValueKey('plan_measure')), findsNothing);

    p.updateAvFloorPlan(p.activeFloorPlan!.copyWith(pixelsPerFoot: 20));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plan_measure')));
    await tester.pumpAndSettle();
    final sheet = tester.getTopLeft(find.byType(InteractiveViewer));
    await tester.tapAt(sheet + const Offset(100, 300));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(sheet + const Offset(350, 300));
    await tester.pumpAndSettle();
    // Measuring changes nothing on the sheet.
    expect(p.activeFloorPlan!.pixelsPerFoot, 20);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a projector squares itself to the screen', (tester) async {
    final p = await pump(tester);
    p.addAvCostExtraEquipment(description: 'Laser Projector');
    p.addAvCostExtraEquipment(description: 'Projection Screen');
    final plan = p.activeFloorPlan!;
    p.addAvPlanDevice(
      plan.id,
      const PlanDevice(
        id: '',
        deviceKey: 'projection screen',
        label: 'Projection Screen',
        shape: 'screen',
        pos: Offset(300, 500),
      ),
    );
    p.addAvPlanDevice(
      plan.id,
      const PlanDevice(
        id: '',
        deviceKey: 'laser projector',
        label: 'Laser Projector',
        shape: 'projector',
        pos: Offset(500, 200),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w is Tooltip && (w.message ?? '').startsWith('Laser Projector\n'),
      ),
    );
    // Past the double-click wait.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan_square_readout')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan_device_calculator')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('plan_square_projector')));
    await tester.pumpAndSettle();
    final projector = p.activeFloorPlan!.devices.firstWhere(
      (d) => d.shape == 'projector',
    );
    // The screen faces up the sheet, so square on is straight above it,
    // facing down, the same distance away.
    expect(projector.rotation, 180);

    // With a cone showing, the export offers a copy without the angles.
    final screen = p.activeFloorPlan!.devices.firstWhere(
      (d) => d.shape == 'screen',
    );
    p.updateAvPlanDevice(plan.id, screen.copyWith(showFov: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Export the plan'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan_export_plain')), findsOneWidget);
    expect(find.textContaining('with viewing angles'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    expect(projector.pos.dx, closeTo(300, 0.01));
    expect(
      (projector.pos - const Offset(300, 500)).distance,
      closeTo((const Offset(500, 200) - const Offset(300, 500)).distance, 0.01),
    );
    expect(tester.takeException(), isNull);
  });
}