import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_layout.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_name_route.dart';
import 'package:extron_configurator/av_flow_place.dart';
import 'package:extron_configurator/av_flow_view.dart';

/// Changing the AV Flow never takes a device off the quote: Recreate keeps
/// boxes added by hand, removing a box keeps it on the Cost page, and Tidy
/// only moves boxes.
void main() {
  AvNode box(String id, String label, List<AvPort> ports,
          {bool fromConfig = false, Offset pos = const Offset(40, 60)}) =>
      AvNode(
        id: id,
        label: label,
        model: '',
        pos: pos,
        ports: ports,
        fromConfig: fromConfig,
      );

  const hdmiOut = AvPort(
    id: 'out',
    label: 'HDMI',
    signal: SignalType.hdmi,
    direction: PortDirection.output,
    side: PortSide.right,
  );
  const hdmiIn = AvPort(
    id: 'in',
    label: 'HDMI 1',
    signal: SignalType.hdmi,
    direction: PortDirection.input,
    side: PortSide.left,
  );

  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addAvNode(box('AVNODE_1', 'Decoder Station 1', [hdmiOut]));
    p.addAvNode(box('AVNODE_2', 'Station 1', [hdmiIn],
        pos: const Offset(500, 60)));
    return p;
  }

  test('removing a box keeps it on the Cost page, and putting it back takes '
      'the line off', () {
    final p = room();
    final line = p.removeAvNodeKeepCost('AVNODE_1');
    expect(line, isNotNull);
    expect(p.avNodeById('AVNODE_1'), isNull);
    expect(p.avCost.extraEquipment.single.description, 'Decoder Station 1');
    expect(p.avCost.extraEquipment.single.removedFrom, 'AVNODE_1');
    expect(undrawnQuotedLines(p), hasLength(1));

    expect(placeQuotedLineOnFlow(p, p.avCost.extraEquipment.single), 1);
    expect(p.avNodeById('AVNODE_1'), isNotNull);
    expect(p.avCost.extraEquipment, isEmpty);
  });

  test('a box kept off the estimate just goes', () {
    final p = room();
    p.updateAvNode(
        p.avNodeById('AVNODE_1')!.copyWith(excludeFromCost: true));
    expect(p.removeAvNodeKeepCost('AVNODE_1'), isNull);
    expect(p.avCost.extraEquipment, isEmpty);
  });

  test('Tidy layout only moves boxes', () {
    final p = room();
    final before = {for (final n in p.avNodes) n.id};
    p.arrangeAvNodes(tidyAvLayout(p.avNodes, p.avDeviceLibrary));
    expect({for (final n in p.avNodes) n.id}, before);
  });

  test('auto-route by name joins the boxes whose names end the same', () {
    final p = room();
    p.addAvNode(box('AVNODE_3', 'Station 2', [hdmiIn]));
    final runs = planNameRoutes(p);
    expect(runs, hasLength(1));
    expect(runs.single.fromNodeId, 'AVNODE_1');
    expect(runs.single.toNodeId, 'AVNODE_2');
    expect(namePlaceKey('NAV Decoder Station 01'), 'station 1');
    expect(namePlaceKey('Rack'), '');
  });

  testWidgets('Recreate from config keeps boxes added by hand and their '
      'cables', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final p = room();
    p.addAvCable(
      fromNodeId: 'AVNODE_1',
      fromPortId: 'out',
      toNodeId: 'AVNODE_2',
      toPortId: 'in',
      signal: SignalType.hdmi,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: AvFlowView())),
      ),
    );
    await tester.pumpAndSettle();

    final recreate = find.byKey(const ValueKey('av_flow_recreate'));
    await tester.ensureVisible(recreate);
    await tester.pumpAndSettle();
    await tester.tap(recreate);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Recreate'));
    await tester.pumpAndSettle();

    expect(p.avNodeById('AVNODE_1'), isNotNull);
    expect(p.avNodeById('AVNODE_2'), isNotNull);
    expect(p.avCables, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Place undrawn lists quoted lines and places the ticked ones', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final p = room();
    p.addAvCostExtraEquipment(description: 'Wall display', qty: 2);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: AvFlowView())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('av_place_undrawn')));
    await tester.pumpAndSettle();
    expect(find.text('Wall display'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('av_place_go')));
    await tester.pumpAndSettle();

    expect(p.avNodes.where((n) => n.label.startsWith('Wall display')),
        hasLength(2));
    expect(p.avCost.extraEquipment, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
