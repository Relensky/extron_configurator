import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';

/// Two things that make a diagram readable rather than merely correct: cables
/// go AROUND the boxes in their way, and the legend sits below the drawing
/// instead of on top of whatever is in the bottom-left corner.
void main() {
  AvNode box(String id, Offset pos) => AvNode(
    id: id,
    label: id,
    model: '',
    pos: pos,
    ports: const [
      AvPort(
        id: 'out_1',
        label: 'OUT',
        signal: SignalType.hdmi,
        direction: PortDirection.output,
        side: PortSide.right,
      ),
      AvPort(
        id: 'in_1',
        label: 'IN',
        signal: SignalType.hdmi,
        direction: PortDirection.input,
        side: PortSide.left,
      ),
    ],
  );

  const cable = AvCable(
    id: 'C1',
    fromNodeId: 'LEFT',
    fromPortId: 'out_1',
    toNodeId: 'RIGHT',
    toPortId: 'in_1',
    signal: SignalType.hdmi,
  );

  group('cable routing', () {
    test('a clear run is left exactly as it was', () {
      final from = box('LEFT', const Offset(0, 0));
      final to = box('RIGHT', const Offset(600, 0));

      final plain = routeCable(fromNode: from, toNode: to, cable: cable);
      final withNoObstacles = routeCable(
        fromNode: from,
        toNode: to,
        cable: cable,
        obstacles: const [],
      );
      expect(withNoObstacles, plain);
    });

    test('a run steps around a box sitting in its path', () {
      final from = box('LEFT', const Offset(0, 0));
      final to = box('RIGHT', const Offset(600, 0));
      // Straight between them, right where the vertical leg would fall.
      final blocker = box('MIDDLE', const Offset(280, -20));
      final obstacle = blocker.rect.inflate(10);

      final blocked = routeCable(fromNode: from, toNode: to, cable: cable);
      expect(
        polylineHitsAny(blocked, [obstacle]),
        isTrue,
        reason: 'the unaware route should cut through the box',
      );

      final routed = routeCable(
        fromNode: from,
        toNode: to,
        cable: cable,
        obstacles: [obstacle],
      );
      expect(polylineHitsAny(routed, [obstacle]), isFalse);
      // Still starts and ends on the same two ports.
      expect(routed.first, blocked.first);
      expect(routed.last, blocked.last);
    });

    test('a wall of boxes is cleared by going around the outside', () {
      final from = box('LEFT', const Offset(0, 300));
      final to = box('RIGHT', const Offset(700, 300));
      // A column of boxes spanning the whole corridor between them, so no
      // sideways nudge can get through.
      final wall = [
        for (int i = 0; i < 6; i++)
          box('W$i', Offset(300, 120.0 + i * 90)).rect.inflate(10),
      ];

      final routed = routeCable(
        fromNode: from,
        toNode: to,
        cable: cable,
        obstacles: wall,
      );
      expect(polylineHitsAny(routed, wall), isFalse);
    });

    test('manual bends are always respected, obstacles or not', () {
      final from = box('LEFT', const Offset(0, 0));
      final to = box('RIGHT', const Offset(600, 0));
      final bent = cable.copyWith(waypoints: const [Offset(300, 400)]);

      final routed = routeCable(
        fromNode: from,
        toNode: to,
        cable: bent,
        obstacles: [box('MIDDLE', const Offset(280, -20)).rect],
      );
      expect(routed.length, 3);
      expect(routed[1], const Offset(300, 400));
    });
  });

  group('the legend', () {
    testWidgets('sits below the lowest device, not over it', (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final provider = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      provider.loadAvFlowForCurrentConfig();
      // A device parked in the bottom-left, exactly where the legend used to
      // float.
      provider.addAvNode(box('LOW', const Offset(20, 420)));
      provider.addAvNode(box('RIGHT', const Offset(500, 60)));
      provider.addAvCable(
        fromNodeId: 'LOW',
        fromPortId: 'out_1',
        toNodeId: 'RIGHT',
        toPortId: 'in_1',
        signal: SignalType.hdmi,
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: AvFlowView())),
        ),
      );
      await tester.pumpAndSettle();

      final legend = find.text('Signal types');
      expect(legend, findsOneWidget);

      final legendTop = tester.getTopLeft(legend).dy;
      final deviceBottom = tester.getBottomLeft(find.text('LOW')).dy;
      expect(
        legendTop,
        greaterThan(deviceBottom),
        reason: 'the legend must clear the lowest device',
      );
    });

    test('the reserved height grows with the number of entries', () {
      final small = avLegendHeight(1, false);
      final large = avLegendHeight(6, false);
      expect(large, greaterThan(small));
      // The "some runs are coloured individually" note needs its own line.
      expect(avLegendHeight(3, true), greaterThan(avLegendHeight(3, false)));
    });
  });

  group('re-routing while devices move', () {
    testWidgets('a cable re-routes around a device dragged into its path', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final provider = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      provider.loadAvFlowForCurrentConfig();
      provider.addAvNode(box('LEFT', const Offset(20, 60)));
      provider.addAvNode(box('RIGHT', const Offset(620, 60)));
      // Parked well below the run between the two.
      provider.addAvNode(box('MOVER', const Offset(320, 460)));
      provider.addAvCable(
        fromNodeId: 'LEFT',
        fromPortId: 'out_1',
        toNodeId: 'RIGHT',
        toPortId: 'in_1',
        signal: SignalType.hdmi,
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: AvFlowView())),
        ),
      );
      await tester.pumpAndSettle();

      List<Offset> currentRoute() {
        final byId = {for (final n in provider.avNodes) n.id: n};
        final others = [
          for (final n in provider.avNodes)
            if (n.id != 'LEFT' && n.id != 'RIGHT') n.rect.inflate(10),
        ];
        return routeCable(
          fromNode: byId['LEFT']!,
          toNode: byId['RIGHT']!,
          cable: provider.avCables.single,
          obstacles: others,
        );
      }

      final before = currentRoute();

      // Drag MOVER up into the corridor between LEFT and RIGHT.
      await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('MOVER')),
      );
      for (int i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(0, -34));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final after = currentRoute();
      expect(
        after,
        isNot(before),
        reason: 'the run should have moved aside for the device',
      );

      // And it genuinely clears the device in its new position.
      final mover = provider.avNodeById('MOVER')!;
      expect(polylineHitsAny(after, [mover.rect.inflate(10)]), isFalse);
    });
  });
}
