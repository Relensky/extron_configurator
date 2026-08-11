import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/cabling_schematic.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/room_locations.dart';

/// A cabling set is issued one trade at a time: the network contractor gets
/// the network sheet, the AV contractor gets theirs, and neither has to read
/// around the other's runs. So the plan draws the runs it knows about and can
/// show one cable type at a time.
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

  /// Two placed locations with a network run and a DTP run between them, plus
  /// a screen control run on the same pair.
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addFloorPlanSheet(name: 'Level 1');
    p.addAvLocation(
      const RoomLocation(
        id: 'LOC_1',
        name: 'Instructor station',
        planPos: Offset(200, 200),
      ),
    );
    p.addAvLocation(
      const RoomLocation(
        id: 'LOC_2',
        name: 'Equipment rack',
        planPos: Offset(600, 400),
      ),
    );

    for (final (i, signal) in [
      SignalType.network,
      SignalType.hdbaset,
    ].indexed) {
      p.addAvNode(device('A$i', 'LOC_1', signal));
      p.addAvNode(device('B$i', 'LOC_2', signal));
      p.addAvCable(
        fromNodeId: 'A$i',
        fromPortId: 'p1',
        toNodeId: 'B$i',
        toPortId: 'p1',
        signal: signal,
      );
    }

    p.addAvScreenSwitch(
      const ScreenSwitch(
        id: '',
        label: 'Front screen',
        startLocationId: 'LOC_1',
        endLocationId: 'LOC_2',
        cableType: 'Cat 5e',
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

  testWidgets('a layer chip per cable type that lands on the plan', (
    tester,
  ) async {
    final p = room();
    await pump(tester, p);

    expect(find.text('Cable runs'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'All'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Off'), findsOneWidget);
    // Named the way the cabling drawing names them.
    expect(find.byKey(const ValueKey('plan_layer_Network')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan_layer_AV cabling')), findsOneWidget);
    // The screen control run is cable somebody pulls too, and it is on the
    // sheet under whatever it was specified as.
    expect(find.byKey(const ValueKey('plan_layer_Cat 5e')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picking a layer leaves the others off the sheet', (
    tester,
  ) async {
    final p = room();
    await pump(tester, p);

    await tester.tap(find.byKey(const ValueKey('plan_layer_Network')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('plan_layer_Network')))
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('plan_layer_AV cabling')),
          )
          .selected,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a room with nothing placed grows no layer bar', (tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Bare'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addFloorPlanSheet(name: 'Level 1');
    await pump(tester, p);

    expect(find.text('Cable runs'), findsNothing);
  });

  testWidgets('runs whose ends are not on the plan are counted, not hidden', (
    tester,
  ) async {
    // A plan that quietly leaves out half the pulls is worse than one that
    // says how many it left out.
    final p = room();
    p.moveAvLocationMarker('LOC_2', Offset.zero);
    await pump(tester, p);

    expect(find.textContaining('not on the plan'), findsOneWidget);
  });

  test('the plan draws the same runs the cabling drawing does', () {
    // Both read the same call, so the sheet a contractor is handed and the
    // one-line drawing beside it cannot disagree about what runs where.
    final p = room();
    final drawing = p.cablingSchematic(buildAvFlowModel(p));
    expect(
      drawing.bundles.map((b) => b.cableType).toSet(),
      {'Network', 'AV cabling', 'Cat 5e'},
    );
    expect(
      drawing.bundles.firstWhere((b) => b.isControlRun).color,
      kCablingControlRunColor,
    );
  });
}
