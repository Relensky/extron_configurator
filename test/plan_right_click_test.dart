import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/placed_devices.dart';
import 'package:extron_configurator/room_locations.dart';

/// Right-click on the floor plan shows what was clicked; removing it is
/// click to select, then Delete. Right-click used to remove it outright.
void main() {
  Future<AppStateProvider> pump(WidgetTester tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addFloorPlanSheet(name: 'Level 1');
    final sheet = p.activeFloorPlan!;
    p.addAvPlanDevice(
      sheet.id,
      const PlanDevice(
        id: '',
        deviceKey: 'generic:camera',
        label: 'Camera',
        shape: 'camera',
        pos: Offset(300, 300),
      ),
    );
    p.addAvLocation(const RoomLocation(id: 'LOC_1', name: 'Lectern'));
    p.moveAvLocationMarker(sheet.id, 'LOC_1', const Offset(600, 300));
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

  Finder tip(String startsWith) => find.byWidgetPredicate(
    (w) => w is Tooltip && (w.message ?? '').startsWith(startsWith),
  );

  /// Closes whatever dialog is up.
  Future<void> cancel(WidgetTester tester) async {
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
  }

  testWidgets('a device: right-click for details, Delete removes it', (
    tester,
  ) async {
    final p = await pump(tester);
    await tester.tap(tip('Camera\n'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(p.activeFloorPlan!.devices, hasLength(1));
    expect(find.text('Cancel'), findsWidgets);
    await cancel(tester);

    // Selected by the right-click, so Delete takes it.
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(p.activeFloorPlan!.devices, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a location: click to select, Delete takes it off the sheet', (
    tester,
  ) async {
    final p = await pump(tester);
    final sheet = p.activeFloorPlan!;
    await tester.tap(tip('Lectern'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(p.activeFloorPlan!.hasMarker('LOC_1'), isTrue);
    expect(find.text('Cancel'), findsWidgets);
    await cancel(tester);

    await tester.tap(find.text('Level 1').first, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(tip('Lectern'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(p.avFloorPlanById(sheet.id)!.hasMarker('LOC_1'), isFalse);
    // The location itself stays.
    expect(p.avLocationById('LOC_1'), isNotNull);
    expect(tester.takeException(), isNull);
  });
}
