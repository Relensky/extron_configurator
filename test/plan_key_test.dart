import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/room_locations.dart';
import 'package:extron_configurator/screenshot_tools.dart';

/// A plan exported as a PNG and mailed to a contractor is read away from this
/// app, and every convention on it — a ceiling icon, a dashed line, a squiggle
/// leaving the page, a red arrow, a numbered callout — means nothing on its
/// own. So the key is drawn ON the sheet, inside the boundary that gets
/// captured, rather than being a panel that only exists on screen.
void main() {
  AvNode device(String id, String locationId, SignalType signal) => AvNode(
    id: id,
    label: id,
    model: '',
    pos: Offset.zero,
    locationId: locationId,
    ports: [
      AvPort(
        id: 'p1',
        label: 'P1',
        signal: signal,
        direction: PortDirection.bidirectional,
        side: PortSide.right,
      ),
    ],
  );

  /// A ceiling and a rack, both on the sheet, with a network run between them,
  /// a callout and a piece of notation.
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    final sheet = p.addFloorPlanSheet(name: 'Level 1');
    p.addAvLocation(
      const RoomLocation(
        id: 'LOC_1',
        name: 'Projector box',
        zone: RoomZone.ceiling,
      ),
    );
    p.addAvLocation(
      const RoomLocation(
        id: 'LOC_2',
        name: 'Equipment rack',
        zone: RoomZone.rack,
      ),
    );
    p.moveAvLocationMarker(sheet.id, 'LOC_1', const Offset(200, 200));
    p.moveAvLocationMarker(sheet.id, 'LOC_2', const Offset(600, 400));

    p.addAvNode(device('A', 'LOC_1', SignalType.network));
    p.addAvNode(device('B', 'LOC_2', SignalType.network));
    p.addAvCable(
      fromNodeId: 'A',
      fromPortId: 'p1',
      toNodeId: 'B',
      toPortId: 'p1',
      signal: SignalType.network,
    );

    p.addAvCallout(
      sheet.id,
      const FloorPlanCallout(
        id: '',
        tag: '1',
        pos: Offset(300, 300),
        target: CalloutTarget.location,
        targetId: 'LOC_2',
        workbookSheet: 'Racks',
      ),
    );
    p.addAvAnnotation(
      sheet.id,
      const PlanAnnotation(
        id: '',
        shape: PlanShape.arrow,
        start: Offset(100, 100),
        end: Offset(180, 160),
        text: 'Conduit up this wall',
      ),
    );
    return p;
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

  testWidgets('the key names the surfaces, the runs, the callouts and the '
      'notation', (tester) async {
    final p = room();
    await pump(tester, p);

    expect(find.textContaining('KEY — LEVEL 1'), findsOneWidget);
    // Only the surfaces actually on this sheet.
    expect(find.text('Ceiling'), findsOneWidget);
    expect(find.text('Rack'), findsOneWidget);
    expect(find.text('Wall'), findsNothing);
    // The runs, by what they say on the drawing.
    expect(find.text('1x Network'), findsWidgets);
    expect(find.text('Continues off this sheet'), findsOneWidget);
    // The callout, resolved to what it points at.
    expect(find.textContaining('Equipment rack'), findsWidgets);
    // The mark-up.
    expect(find.text('Conduit up this wall'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the key can be taken off the sheet, and stays off', (
    tester,
  ) async {
    final p = room();
    await pump(tester, p);
    expect(find.textContaining('KEY — LEVEL 1'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Key'));
    await tester.pumpAndSettle();

    expect(find.textContaining('KEY — LEVEL 1'), findsNothing);
    expect(p.activeFloorPlan!.keyHidden, isTrue);
    // And it is a property of the sheet, so it survives a reload.
    expect(FloorPlan.fromJson(p.activeFloorPlan!.toJson()).keyHidden, isTrue);
  });

  testWidgets('a sheet with nothing on it grows no key', (tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Bare'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addFloorPlanSheet(name: 'Level 1');
    await pump(tester, p);

    expect(find.textContaining('KEY —'), findsNothing);
  });

  testWidgets('the key travels with the sheet, not with the room', (
    tester,
  ) async {
    // A legend in the top-right of the furniture plan can be sitting on the
    // title block of the reflected ceiling plan.
    final p = room();
    final second = p.addFloorPlanSheet(name: 'Level 2');
    p.updateAvFloorPlan(second.copyWith(keyPos: const Offset(400, 300)));

    expect(p.avFloorPlans.first.keyPos, kDefaultPlanKeyPosition);
    expect(
      p.avFloorPlans.firstWhere((s) => s.id == second.id).keyPos,
      const Offset(400, 300),
    );
  });

  group('printing it', () {
    testWidgets('the print skin forces the light theme and drops the colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            body: printSkin(
              enabled: true,
              child: Builder(
                builder: (ctx) => Text(
                  Theme.of(ctx).brightness.name,
                  key: const ValueKey('probe'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // A dark-mode capture converted to grey is a black page with pale lines
      // on it, which a printer renders as a black page.
      expect(find.text('light'), findsOneWidget);
      expect(find.byType(ColorFiltered), findsOneWidget);
    });

    testWidgets('turned off it changes nothing at all', (tester) async {
      const child = Text('x');
      expect(identical(printSkin(enabled: false, child: child), child), isTrue);
    });

    testWidgets('the export menu offers the black-and-white sheet', (
      tester,
    ) async {
      final p = room();
      await pump(tester, p);

      // The button is inside an IgnorePointer so the PopupMenuButton behind it
      // takes the tap — which is the point, and is why the miss warning is
      // expected here.
      await tester.tap(
        find.widgetWithText(ElevatedButton, 'Export PNG'),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      expect(
        find.text('This view, black & white for print (.png)'),
        findsOneWidget,
      );
    });
  });
}
