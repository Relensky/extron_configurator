import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/placed_devices.dart';

/// A device locked on the floor plan stays where it is.
void main() {
  Future<AppStateProvider> pump(WidgetTester tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addFloorPlanSheet(name: 'Level 1');
    p.addAvCostExtraEquipment(description: 'PTZ Camera');
    p.addAvPlanDevice(
      p.activeFloorPlan!.id,
      const PlanDevice(
        id: '',
        deviceKey: 'ptz camera',
        label: 'PTZ Camera',
        shape: 'camera',
        pos: Offset(300, 300),
      ),
    );
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

  PlanDevice camera(AppStateProvider p) => p.activeFloorPlan!.devices.single;

  /// A drag in steps, the way a pointer arrives.
  Future<void> dragBy(WidgetTester tester, Finder target, Offset total) async {
    final gesture = await tester.startGesture(tester.getCenter(target));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(total / 12);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Finder marker() => find.byWidgetPredicate(
    (w) => w is Tooltip && (w.message ?? '').startsWith('PTZ Camera\n'),
  );

  test('locked is saved and read back', () {
    const d = PlanDevice(
      id: 'DEV_1',
      deviceKey: 'cam',
      label: 'Cam',
      shape: 'camera',
      pos: Offset.zero,
      locked: true,
    );
    expect(d.toJson()['locked'], true);
    expect(PlanDevice.fromJson(d.toJson()).locked, isTrue);
    expect(d.copyWith(locked: false).toJson().containsKey('locked'), isFalse);
  });

  testWidgets('a locked device does not drag, nudge or right-click away', (
    tester,
  ) async {
    final p = await pump(tester);
    await tester.tap(marker());
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('plan_device_lock')));
    await tester.pumpAndSettle();
    expect(camera(p).locked, isTrue);
    final id = camera(p).id;
    expect(find.byKey(ValueKey('plan_lock_badge_$id')), findsOneWidget);
    final at = camera(p).pos;

    await dragBy(tester, marker(), const Offset(120, 0));
    expect(camera(p).pos, at);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(camera(p).pos, at);

    await tester.tap(marker(), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(p.activeFloorPlan!.devices, hasLength(1));

    // Unlocked, it drags again.
    await tester.tap(find.byKey(const ValueKey('plan_device_lock')));
    await tester.pumpAndSettle();
    await dragBy(tester, marker(), const Offset(120, 0));
    expect(camera(p).pos.dx, greaterThan(at.dx));
    expect(tester.takeException(), isNull);
  });
}
