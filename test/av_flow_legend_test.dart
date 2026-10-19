import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/room_locations.dart';

/// The AV Flow's key: every row on one edge, a note, and moved by hand.
void main() {
  AvPort port(String id, SignalType s, PortDirection d) => AvPort(
    id: id,
    label: id.toUpperCase(),
    signal: s,
    direction: d,
    side: d == PortDirection.input ? PortSide.left : PortSide.right,
  );

  AppStateProvider seeded() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addAvNode(AvNode(
      id: 'AVNODE_1',
      label: 'Source',
      model: '',
      pos: const Offset(40, 60),
      ports: [
        port('hdmi', SignalType.hdmi, PortDirection.output),
        port('dtp', SignalType.hdbaset, PortDirection.output),
        port('lan', SignalType.network, PortDirection.output),
      ],
    ));
    p.addAvNode(AvNode(
      id: 'AVNODE_2',
      label: 'Sink',
      model: '',
      pos: const Offset(600, 60),
      ports: [
        port('hdmi', SignalType.hdmi, PortDirection.input),
        port('dtp', SignalType.hdbaset, PortDirection.input),
        port('lan', SignalType.network, PortDirection.input),
      ],
    ));
    for (final (id, s) in [
      ('hdmi', SignalType.hdmi),
      ('dtp', SignalType.hdbaset),
      ('lan', SignalType.network),
    ]) {
      p.addAvCable(
        fromNodeId: 'AVNODE_1',
        fromPortId: id,
        toNodeId: 'AVNODE_2',
        toPortId: id,
        signal: s,
      );
    }
    return p;
  }

  Future<void> pumpTab(WidgetTester tester, AppStateProvider provider) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: AvFlowView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  final legend = find.byKey(const ValueKey('av_legend'));

  testWidgets('AV cabling, network and the rest line up in the key', (
    tester,
  ) async {
    await pumpTab(tester, seeded());
    final swatches = find.descendant(
      of: legend,
      matching: find.byWidgetPredicate(
        (w) => w is Container && w.constraints?.maxWidth == 22,
      ),
    );
    expect(swatches, findsNWidgets(3));
    final lefts = {
      for (final e in swatches.evaluate())
        tester.getTopLeft(find.byWidget(e.widget)).dx,
    };
    expect(lefts, hasLength(1), reason: 'every swatch on the same edge');
    // "Network" is not printed twice, as a heading over itself.
    expect(
      find.descendant(of: legend, matching: find.text('Network')),
      findsOneWidget,
    );
  });

  testWidgets('the key takes a note and can be dragged and put back', (
    tester,
  ) async {
    final p = seeded();
    await pumpTab(tester, p);
    await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('av_legend_edit')));
    // Past the wait for a double-click on the key.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('av_legend_note')), 'All runs plenum rated');
    await tester.tap(find.byKey(const ValueKey('av_legend_save')));
    await tester.pumpAndSettle();
    expect(find.text('All runs plenum rated'), findsOneWidget);
    expect(p.avFlowAsJson()['flowLegend'], {'note': 'All runs plenum rated'});

    final before = tester.getTopLeft(legend);
    final gesture = await tester.startGesture(
        tester.getTopLeft(legend) + const Offset(30, 30));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(p.avFlowLegend.offset.dx, greaterThan(200));
    expect(tester.getTopLeft(legend).dx, greaterThan(before.dx + 200));

    await tester.tap(find.byKey(const ValueKey('av_legend_edit')));
    // Past the wait for a double-click on the key.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('av_legend_reset')));
    await tester.pumpAndSettle();
    expect(p.avFlowLegend.offset, Offset.zero);
    expect(p.avFlowLegend.note, 'All runs plenum rated');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a box says where it is on a line of its header', (
    tester,
  ) async {
    final p = seeded();
    final rack = p.addAvLocation(const RoomLocation(id: '', name: 'Rack'));
    final before = p.avNodeById('AVNODE_1')!;
    p.setAvNodeLocation('AVNODE_1', rack.id);
    final after = p.avNodeById('AVNODE_1')!;
    // A line taller, and the connectors move down with it.
    expect(after.height, before.height + kAvNodeLocationLine);
    expect(after.localAnchorOf('hdmi').dy,
        before.localAnchorOf('hdmi').dy + kAvNodeLocationLine);

    await pumpTab(tester, p);
    final line = find.byKey(const ValueKey('av_node_location_AVNODE_1'));
    expect(line, findsOneWidget);
    expect(tester.widget<Text>(line).data, 'Rack');
    expect(find.byKey(const ValueKey('av_node_location_AVNODE_2')),
        findsNothing);
    expect(tester.takeException(), isNull);
  });
}
