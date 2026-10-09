import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/placed_devices.dart';
import 'package:extron_configurator/projection_calc.dart';

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

  testWidgets('the sheet zooms out far enough to see it whole', (
    tester,
  ) async {
    await pump(tester);
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    // A finite margin would stop the zoom once the sheet filled the window.
    expect(viewer.boundaryMargin.left, double.infinity);
    expect(viewer.minScale, lessThanOrEqualTo(0.02));
  });

  testWidgets('toolbar groups fold away and come back', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('plan_set_scale')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plan_group_Measure and project')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan_set_scale')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('plan_group_Measure and project')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan_set_scale')), findsOneWidget);

    // The whole toolbar folds to its title and the exports.
    await tester.tap(find.byKey(const ValueKey('plan_toolbar_toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan_set_scale')), findsNothing);
    expect(find.text('Location report'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plan_toolbar_toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan_set_scale')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
    // Nothing on the sheet can be picked up while measuring.
    expect(find.byKey(const ValueKey('plan_measure_cover')), findsOneWidget);
    final sheet = tester.getTopLeft(find.byType(InteractiveViewer));
    await tester.tapAt(sheet + const Offset(100, 300));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(sheet + const Offset(350, 300));
    await tester.pumpAndSettle();
    // Measuring changes nothing on the sheet.
    expect(p.activeFloorPlan!.pixelsPerFoot, 20);
    await tester.tap(find.byKey(const ValueKey('plan_measure')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan_measure_cover')), findsNothing);
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

    // Pair it with the screen by name, not just by nearness.
    await tester.tap(find.byKey(const ValueKey('plan_pair_menu')));
    await tester.pumpAndSettle();
    final screenId = p.activeFloorPlan!.devices
        .firstWhere((d) => d.shape == 'screen')
        .id;
    await tester.tap(find.byKey(ValueKey('plan_pair_$screenId')).last);
    await tester.pumpAndSettle();
    final paired = p.activeFloorPlan!.devices;
    expect(
      paired.firstWhere((d) => d.shape == 'projector').pairedWith,
      screenId,
    );
    expect(
      paired.firstWhere((d) => d.shape == 'screen').pairedWith,
      paired.firstWhere((d) => d.shape == 'projector').id,
    );

    await tester.tap(find.byKey(const ValueKey('plan_square_projector')));
    await tester.pumpAndSettle();
    final projector = p.activeFloorPlan!.devices.firstWhere(
      (d) => d.shape == 'projector',
    );
    // The screen faces up the sheet, so square on is straight above it,
    // facing down, the same distance away.
    expect(projector.rotation, 180);

    // Throw to screen: the reach ends at the screen and the image fills it.
    await tester.tap(find.byKey(const ValueKey('plan_throw_to_screen')));
    await tester.pumpAndSettle();
    final thrown = p.activeFloorPlan!.devices.firstWhere(
      (d) => d.shape == 'projector',
    );
    final lit = p.activeFloorPlan!.devices.firstWhere(
      (d) => d.shape == 'screen',
    );
    expect(thrown.range, closeTo((thrown.pos - lit.pos).distance, 0.01));
    expect(imageWidthForBeam(thrown.range, thrown.fov), closeTo(lit.width, 0.01));

    // With a cone showing, the export offers a copy without the angles.
    final screen = p.activeFloorPlan!.devices.firstWhere(
      (d) => d.shape == 'screen',
    );
    p.updateAvPlanDevice(plan.id, screen.copyWith(showFov: true));
    await tester.pumpAndSettle();
    // The cones can be hidden on screen without touching the devices.
    final angles = find.byKey(const ValueKey('plan_viewing_angles'));
    expect(tester.widget<FilterChip>(angles).selected, isTrue);
    await tester.tap(angles);
    await tester.pumpAndSettle();
    expect(tester.widget<FilterChip>(angles).selected, isFalse);
    expect(p.activeFloorPlan!.devices.any((d) => d.showFov), isTrue);
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

  testWidgets('each throw is shown and colored on its own', (tester) async {
    final p = await pump(tester);
    p.addAvCostExtraEquipment(description: 'Laser Projector');
    final plan = p.activeFloorPlan!;
    for (final (key, label, shape, pos) in [
      ('ptz camera', 'PTZ Camera', 'camera', const Offset(300, 300)),
      ('laser projector', 'Laser Projector', 'projector', const Offset(600, 300)),
    ]) {
      p.addAvPlanDevice(
        plan.id,
        PlanDevice(id: '', deviceKey: key, label: label, shape: shape, pos: pos),
      );
    }
    await tester.pumpAndSettle();
    PlanDevice byShape(String s) =>
        p.activeFloorPlan!.devices.firstWhere((d) => d.shape == s);

    await tester.tap(find.byKey(const ValueKey('plan_cone_list')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('plan_cone_show_${byShape('projector').id}')),
    );
    await tester.pumpAndSettle();
    expect(byShape('projector').showFov, isTrue);
    expect(byShape('camera').showFov, isFalse);

    // A color of its own is kept, saved and put back.
    final projector = byShape('projector');
    p.updateAvPlanDevice(plan.id, projector.copyWith(coneColor: 0xFF00838F));
    await tester.pumpAndSettle();
    expect(byShape('projector').fovColor, const Color(0xFF00838F));
    expect(
      PlanDevice.fromJson(byShape('projector').toJson()).coneColor,
      0xFF00838F,
    );
    await tester.tap(find.byKey(ValueKey('plan_cone_reset_${projector.id}')));
    await tester.pumpAndSettle();
    expect(byShape('projector').coneColor, 0);

    await tester.tap(find.byKey(const ValueKey('plan_cone_all')));
    await tester.pumpAndSettle();
    expect(p.activeFloorPlan!.devices.every((d) => d.showFov), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a projector is paired from its device box', (tester) async {
    final p = await pump(tester);
    p.addAvCostExtraEquipment(description: 'Laser Projector');
    p.addAvCostExtraEquipment(description: 'Screen 1');
    p.addAvCostExtraEquipment(description: 'Screen 2');
    final plan = p.activeFloorPlan!;
    for (final (key, label, shape, pos) in [
      ('screen 1', 'Screen 1', 'screen', const Offset(300, 500)),
      ('screen 2', 'Screen 2', 'screen', const Offset(900, 500)),
      ('laser projector', 'Laser Projector', 'projector', const Offset(320, 200)),
    ]) {
      p.addAvPlanDevice(
        plan.id,
        PlanDevice(id: '', deviceKey: key, label: label, shape: shape, pos: pos),
      );
    }
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (w) =>
            w is Tooltip && (w.message ?? '').startsWith('Laser Projector\n'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Edit'));
    await tester.pumpAndSettle();

    // The box has its own menu, beside the one above the sheet.
    final menus = find.byKey(const ValueKey('plan_pair_menu'));
    expect(menus, findsNWidgets(2));
    await tester.tap(menus.last);
    await tester.pumpAndSettle();
    final far = p.activeFloorPlan!.devices
        .firstWhere((d) => d.label == 'Screen 2')
        .id;
    await tester.tap(find.byKey(ValueKey('plan_pair_$far')).last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Paired: Screen 2'), findsWidgets);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final projector = p.activeFloorPlan!.devices
        .firstWhere((d) => d.shape == 'projector');
    expect(projector.pairedWith, far);
    expect(tester.takeException(), isNull);
  });
}
