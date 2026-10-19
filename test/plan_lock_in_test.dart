import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/placed_devices.dart';
import 'package:extron_configurator/projection_calc.dart';
import 'package:extron_configurator/projection_calculator_dialog.dart';

/// A projector's calculation kept with it, and a device's numbers locked in
/// with who approved them.
void main() {
  Future<AppStateProvider> pump(WidgetTester tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      }
      ..userDisplayName = 'Derek Stanley';
    p.loadAvFlowForCurrentConfig();
    p.addFloorPlanSheet(name: 'Level 1');
    final plan = p.activeFloorPlan!;
    p.updateAvFloorPlan(plan.copyWith(pixelsPerFoot: 20));
    p.addAvPlanDevice(
      plan.id,
      const PlanDevice(
        id: '',
        deviceKey: 'generic:screen',
        label: 'Screen',
        shape: 'screen',
        pos: Offset(500, 100),
        width: 200,
      ),
    );
    p.addAvPlanDevice(
      plan.id,
      const PlanDevice(
        id: '',
        deviceKey: 'projector',
        label: 'Projector',
        shape: 'projector',
        pos: Offset(500, 400),
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
    return p;
  }

  PlanDevice named(AppStateProvider p, String label) =>
      p.activeFloorPlan!.devices.firstWhere((d) => d.label == label);

  Future<void> select(WidgetTester tester, String label) async {
    await tester.tap(find.byWidgetPredicate(
      (w) => w is Tooltip && (w.message ?? '').startsWith('$label\n'),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  test('the calculation and the approval are saved and read back', () {
    final d = PlanDevice(
      id: 'DEV_1',
      deviceKey: 'projector',
      label: 'Projector',
      shape: 'projector',
      pos: Offset.zero,
      calc: const {'throwMin': '1.5', 'sizeFt': 10.0},
      approval: SettingsApproval(
        name: 'Derek Stanley',
        email: 'd@example.com',
        at: DateTime(2026, 10, 19, 14, 30),
      ),
    );
    final back = PlanDevice.fromJson(d.toJson());
    expect(back.calc['throwMin'], '1.5');
    expect(back.approval!.label, 'Derek Stanley, Oct 19, 2026');
    expect(back.copyWith(clearApproval: true).approval, isNull);
  });

  test('a locked-in screen is not resized by its projector', () {
    const screen = PlanDevice(
      id: 'S',
      deviceKey: 's',
      label: 'Screen',
      shape: 'screen',
      pos: Offset(0, 0),
      width: 200,
    );
    const projector = PlanDevice(
      id: 'P',
      deviceKey: 'p',
      label: 'Projector',
      shape: 'projector',
      pos: Offset(0, 300),
    );
    final locked = screen.copyWith(
      approval: SettingsApproval(name: 'A', at: DateTime(2026)),
    );
    final out = withProjectionLinked(
      [locked, projector],
      projector.copyWith(fov: 80),
    );
    expect(out.firstWhere((d) => d.id == 'S').width, 200);
  });

  testWidgets('the calculator opens again as it was kept, and locks in', (
    tester,
  ) async {
    final p = await pump(tester);
    await select(tester, 'Projector');
    await tester.tap(find.byKey(const ValueKey('plan_device_calculator')));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const ValueKey('projection_throw_min')), '1.7');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('projection_keep')));
    await tester.pumpAndSettle();
    expect(named(p, 'Projector').calc['throwMin'], '1.7');

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plan_device_calculator')));
    await tester.pumpAndSettle();
    final box = find.byKey(const ValueKey('projection_throw_min'));
    expect(tester.widget<TextField>(box).controller!.text, '1.7');

    // Locked in: who approved it, and nothing can be typed.
    await tester.tap(find.byKey(const ValueKey('projection_lock_in')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('projection_lock_in_confirm')));
    await tester.pumpAndSettle();
    expect(named(p, 'Projector').approval!.name, 'Derek Stanley');
    expect(find.byKey(const ValueKey('projection_approved')), findsOneWidget);
    await tester.enterText(box, '3');
    await tester.pump();
    expect(tester.widget<TextField>(box).controller!.text, '1.7');

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan_device_approved')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan_device_auto_throw')), findsNothing);

    // Unlocked from the bar.
    await tester.tap(find.byKey(const ValueKey('plan_device_unlock')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plan_unlock_confirm')));
    await tester.pumpAndSettle();
    expect(named(p, 'Projector').approval, isNull);
    expect(named(p, 'Projector').calc['throwMin'], '1.7',
        reason: 'unlocking keeps the calculation');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a screen is sized live by its diagonal, and locks in', (
    tester,
  ) async {
    final p = await pump(tester);
    await select(tester, 'Screen');
    final before = named(p, 'Screen');
    await tester.drag(
      find.byKey(const ValueKey('plan_device_bar_diagonal')),
      const Offset(60, 0),
    );
    await tester.pumpAndSettle();
    final after = named(p, 'Screen');
    expect(after.width, greaterThan(before.width));
    // Its reach follows the new size.
    expect(after.range, closeTo(screenViewingReach(after.width), 0.01));

    await tester.tap(find.byKey(const ValueKey('plan_device_lock_in')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plan_lock_in_confirm')));
    await tester.pumpAndSettle();
    expect(named(p, 'Screen').approval!.name, 'Derek Stanley');
    expect(find.byKey(const ValueKey('plan_device_bar_diagonal')),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('screens, displays and projectors reach by the math', () {
    const screen = PlanDevice(
      id: 'S',
      deviceKey: 's',
      label: 'Screen',
      shape: 'screen',
      pos: Offset(0, 0),
      width: 200,
      range: 999,
    );
    const display = PlanDevice(
      id: 'D',
      deviceKey: 'd',
      label: 'Display',
      shape: 'display',
      pos: Offset(800, 0),
      width: 96,
      range: 999,
    );
    const projector = PlanDevice(
      id: 'P',
      deviceKey: 'p',
      label: 'Projector',
      shape: 'projector',
      pos: Offset(0, 300),
      range: 999,
    );
    final all = [screen, display, projector];
    // Six image heights at 16:10 and at 16:9.
    expect(derivedReach(screen, all), closeTo(200 / 1.6 * 6, 0.01));
    expect(derivedReach(display, all), closeTo(96 / (16 / 9) * 6, 0.01));
    // The throw to its screen.
    expect(derivedReach(projector, all), closeTo(300, 0.01));
    // No screen: its own throw, else the room's.
    final alone = [projector.copyWith(throwFt: 12)];
    expect(derivedReach(alone.single, alone, pixelsPerFoot: 20), 240);
    expect(
      derivedReach(projector, [projector], pixelsPerFoot: 20, roomThrowFt: 10),
      200,
    );
    // Locked in: what was approved.
    final locked =
        screen.copyWith(approval: SettingsApproval(name: 'A', at: DateTime(2026)));
    expect(derivedReach(locked, [locked]), isNull);
    expect(reachIsDerived('camera'), isFalse);
  });

  testWidgets('a screen shows its reach, with no slider to set it', (
    tester,
  ) async {
    await pump(tester);
    await select(tester, 'Screen');
    await tester.tap(find.byKey(const ValueKey('plan_device_fov')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan_device_bar_fov')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan_device_bar_reach')), findsNothing);
    expect(find.byKey(const ValueKey('plan_device_derived_reach')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saving the throw keeps the settings; the picker switches', (
    tester,
  ) async {
    final p = await pump(tester);
    p.addAvPlanDevice(
      p.activeFloorPlan!.id,
      const PlanDevice(
        id: '',
        deviceKey: 'projector 2',
        label: 'Projector 2',
        shape: 'projector',
        pos: Offset(900, 400),
      ),
    );
    await tester.pumpAndSettle();
    await select(tester, 'Projector');
    await tester.tap(find.byKey(const ValueKey('plan_device_calculator')));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const ValueKey('projection_throw_min')), '1.2');
    await tester.enterText(
        find.byKey(const ValueKey('projection_throw_max')), '2.0');
    await tester.pump();
    final save = find.byKey(const ValueKey('projection_save_distance'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    final kept = named(p, 'Projector').calc;
    expect(kept['throwMax'], '2.0');
    expect(kept['zoom'], 0.5);
    expect(kept['aspect'], '16:10');
    expect(kept['distanceUnit'], 'feet');

    // To the other projector, then back.
    final picker = find.byKey(const ValueKey('projection_switch'));
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Projector 2').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(
          find.byKey(const ValueKey('projection_throw_max'))).controller!.text,
      isNot('2.0'),
    );
    await tester.tap(find.byKey(const ValueKey('projection_switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Projector').last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(
          find.byKey(const ValueKey('projection_throw_max'))).controller!.text,
      '2.0',
    );

    // Applying keeps them too, and does not write over them.
    await tester.tap(find.byKey(const ValueKey('projection_apply')));
    await tester.pumpAndSettle();
    expect(named(p, 'Projector').calc['throwMax'], '2.0');
    expect(tester.takeException(), isNull);
  });

  testWidgets('an entered throw opens locked; the units are remembered', (
    tester,
  ) async {
    final p = await pump(tester);
    resetProjectionUnits();
    addTearDown(resetProjectionUnits);
    p.updateAvPlanDevice(
      p.activeFloorPlan!.id,
      named(p, 'Projector').copyWith(throwFt: 12),
    );
    await tester.pumpAndSettle();
    await select(tester, 'Projector');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('plan_device_calculator')),
        matching: find.text('Projection calculator'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('plan_device_calculator')));
    await tester.pumpAndSettle();

    final distance = find.byKey(const ValueKey('projection_distance'));
    expect(tester.widget<TextField>(distance).controller!.text, "12'");
    expect(tester.widget<TextField>(distance).readOnly, isTrue);

    // Feet for the screen size too, and it is still feet next time.
    await tester.tap(find.byKey(const ValueKey('projection_units')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('units_size_feet')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('units_ok')));
    await tester.pumpAndSettle();
    expect(p.projectionUnits, 'feet|feet|footLamberts');

    resetProjectionUnits();
    applyProjectionUnitsPref(p.projectionUnits);
    expect(projectionUnitsPref(), 'feet|feet|footLamberts');
    expect(tester.takeException(), isNull);
  });
}
