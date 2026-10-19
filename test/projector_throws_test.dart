import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/placed_devices.dart';

/// A throw distance saved per projector on the floor plan.
void main() {
  Future<AppStateProvider> pump(WidgetTester tester, {int projectors = 2}) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addFloorPlanSheet(name: 'Level 1');
    final plan = p.activeFloorPlan!;
    for (var i = 1; i <= projectors; i++) {
      p.addAvCostExtraEquipment(description: 'Projector $i');
      p.addAvPlanDevice(
        plan.id,
        PlanDevice(
          id: '',
          deviceKey: 'projector $i',
          label: 'Projector $i',
          shape: 'projector',
          pos: Offset(200.0 * i, 200),
        ),
      );
    }
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

  List<PlanDevice> projectorsOf(AppStateProvider p) => p.activeFloorPlan!.devices
      .where((d) => d.shape == 'projector')
      .toList();

  test('a projector keeps its own throw through save and load', () {
    const d = PlanDevice(
      id: 'DEV_1',
      deviceKey: 'projector',
      label: 'Projector',
      shape: 'projector',
      pos: Offset.zero,
      throwFt: 14.5,
    );
    expect(d.toJson()['throwFt'], 14.5);
    expect(PlanDevice.fromJson(d.toJson()).throwFt, 14.5);
    // Unset, nothing is written and it reads back as the room's.
    expect(d.copyWith(throwFt: 0).toJson().containsKey('throwFt'), isFalse);
    expect(PlanDevice.fromJson(d.copyWith(throwFt: 0).toJson()).throwFt, 0);
  });

  testWidgets('with two projectors the Throw button lists both', (
    tester,
  ) async {
    final p = await pump(tester);
    expect(find.text('Throws (2)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plan_throw_distance')));
    await tester.pumpAndSettle();

    final [first, second] = projectorsOf(p);
    expect(find.text('Projector 1'), findsWidgets);
    expect(find.text('Projector 2'), findsWidgets);
    await tester.enterText(
        find.byKey(const ValueKey('throw_feet_room')), '20');
    await tester.enterText(
        find.byKey(ValueKey('throw_feet_${first.id}')), '12');
    await tester.enterText(
        find.byKey(ValueKey('throw_inches_${first.id}')), '6');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(p.avThrowDistanceFt, 20);
    final [a, b] = projectorsOf(p);
    expect(a.id, first.id);
    expect(a.throwFt, 12.5);
    expect(b.id, second.id);
    expect(b.throwFt, 0, reason: 'left blank, it uses the room\'s');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a selected projector shows its throw and sets it', (
    tester,
  ) async {
    final p = await pump(tester, projectors: 1);
    // One projector: the toolbar still edits the room's throw.
    expect(find.text('Throw distance'), findsOneWidget);

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message ?? '').startsWith('Projector 1\n'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('plan_device_throw'));
    expect(button, findsOneWidget);
    expect(find.text('Set throw'), findsOneWidget);

    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('throw_distance_feet')), '16');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(projectorsOf(p).single.throwFt, 16);
    expect(find.text('Throw 16\''), findsOneWidget);

    // The calculator starts from it.
    await tester.tap(find.byKey(const ValueKey('plan_device_calculator')));
    await tester.pumpAndSettle();
    expect(find.text("Projector 1's throw distance"), findsOneWidget);
    // The distance box sits level with the Aspect box beside it.
    final aspect = tester.getRect(find
        .ancestor(of: find.text('Aspect'), matching: find.byType(InputDecorator))
        .first);
    final distance =
        tester.getRect(find.byKey(const ValueKey('projection_distance')));
    expect((distance.top - aspect.top).abs(), lessThan(4));
    expect((distance.bottom - aspect.bottom).abs(), lessThan(4));
    // Results, and the save button, show once there is a throw ratio.
    await tester.enterText(
        find.byKey(const ValueKey('projection_throw_min')), '1.5');
    await tester.pumpAndSettle();
    expect(find.text("Save as Projector 1's throw distance"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
