import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/layout_tools.dart';
import 'package:extron_configurator/schematic_view.dart';

/// Boxes that land on top of each other hide both, and a cable that cuts
/// through the very device it plugs into is worse than no diagram. Plus the
/// Control Schematic's own line-colour picker.
void main() {
  group('boxes do not land on top of each other', () {
    const size = Size(190, 78);

    test('a clear spot is left exactly where it was dropped', () {
      const desired = Offset(400, 300);
      final at = nonOverlappingPosition(
        desired: desired,
        size: size,
        others: const [Rect.fromLTWH(0, 0, 190, 78)],
      );
      expect(at, desired);
    });

    test('a drop onto another box slides to the nearest free spot', () {
      const occupied = Rect.fromLTWH(400, 300, 190, 78);
      final at = nonOverlappingPosition(
        desired: const Offset(410, 310),
        size: size,
        others: const [occupied],
      );

      expect(at, isNot(const Offset(410, 310)));
      expect(
        Rect.fromLTWH(at.dx, at.dy, size.width, size.height).overlaps(occupied),
        isFalse,
      );
    });

    test('it never pushes a box off the top-left of the canvas', () {
      final at = nonOverlappingPosition(
        desired: Offset.zero,
        size: size,
        others: const [Rect.fromLTWH(0, 0, 190, 78)],
      );
      expect(at.dx, greaterThanOrEqualTo(0));
      expect(at.dy, greaterThanOrEqualTo(0));
    });

    test('it threads into a gap between two boxes', () {
      const left = Rect.fromLTWH(0, 0, 190, 78);
      const right = Rect.fromLTWH(600, 0, 190, 78);
      final at = nonOverlappingPosition(
        desired: const Offset(10, 10),
        size: size,
        others: const [left, right],
      );
      final placed = Rect.fromLTWH(at.dx, at.dy, size.width, size.height);
      expect(placed.overlaps(left), isFalse);
      expect(placed.overlaps(right), isFalse);
    });
  });

  group('a cable never cuts through the device it lands on', () {
    AvNode crosspoint(Offset pos) => AvNode(
      id: 'DTP',
      label: 'DTP CrossPoint',
      model: 'DTP CrossPoint 84',
      pos: pos,
      ports: const [
        AvPort(
          id: 'in_hdmi_1',
          label: 'HDMI IN 1',
          signal: SignalType.hdmi,
          direction: PortDirection.input,
          side: PortSide.left,
        ),
        AvPort(
          id: 'out_hdmi_1',
          label: 'HDMI OUT 1',
          signal: SignalType.hdmi,
          direction: PortDirection.output,
          side: PortSide.right,
        ),
      ],
    );

    AvNode source(Offset pos) => AvNode(
      id: 'SRC',
      label: 'Source',
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
      ],
    );

    const cable = AvCable(
      id: 'C1',
      fromNodeId: 'SRC',
      fromPortId: 'out_1',
      toNodeId: 'DTP',
      toPortId: 'in_hdmi_1',
      signal: SignalType.hdmi,
    );

    /// The obstacle set the canvas builds: other devices inflated, and the
    /// run's own two devices barely deflated so the ports stay reachable.
    List<Rect> obstaclesFor(List<AvNode> nodes) =>
        [for (final n in nodes) n.rect.deflate(2)];

    test('the normal left-to-right case is unaffected', () {
      final src = source(const Offset(0, 0));
      final dtp = crosspoint(const Offset(500, 0));

      final route = routeCable(
        fromNode: src,
        toNode: dtp,
        cable: cable,
        obstacles: obstaclesFor([src, dtp]),
      );
      expect(polylineHitsAny(route, obstaclesFor([src, dtp])), isFalse);
    });

    test('dragging the source PAST the device makes the run go around it', () {
      // The source now sits to the RIGHT of the CrossPoint, but the cable
      // still lands on the input on the CrossPoint's LEFT face. Without the
      // destination counting as an obstacle the line ran straight through it.
      final src = source(const Offset(700, 0));
      final dtp = crosspoint(const Offset(200, 0));
      final obstacles = obstaclesFor([src, dtp]);

      final route = routeCable(
        fromNode: src,
        toNode: dtp,
        cable: cable,
        obstacles: obstacles,
      );

      expect(
        polylineHitsAny(route, obstacles),
        isFalse,
        reason: 'the run must wrap around the CrossPoint, not cross it',
      );
    });

    test('the run still terminates on the right ports', () {
      final src = source(const Offset(700, 0));
      final dtp = crosspoint(const Offset(200, 0));

      final route = routeCable(
        fromNode: src,
        toNode: dtp,
        cable: cable,
        obstacles: obstaclesFor([src, dtp]),
      );
      expect(route.first, src.anchorOf('out_1'));
      expect(route.last, dtp.anchorOf('in_hdmi_1'));
    });
  });

  group('the control schematic line colors', () {
    AppStateProvider room() => AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {
          'gui_full_room_name': 'Test Room',
          'processor1': 'MainProcessor',
          'dev_projectors': '1',
        },
        'PROJECTORDEVICE_1': {
          'name': 'Projector 1',
          'model': 'VPL-PHZ60',
          'com_type': 'Network',
          'ip_address': '10.0.0.5',
          'protocol': 'TCP',
        },
      };

    test('an override moves the category, and only that category', () {
      final p = room();
      expect(connColor(ConnType.network, p), kConnColors[ConnType.network]);

      const pink = Color(0xFFEC407A);
      p.setSchematicConnColor(ConnType.network.index, pink);

      expect(connColor(ConnType.network, p), pink);
      expect(connColor(ConnType.serial, p), kConnColors[ConnType.serial]);

      p.setSchematicConnColor(ConnType.network.index, null);
      expect(connColor(ConnType.network, p), kConnColors[ConnType.network]);
    });

    test('the whole diagram follows, lines included', () {
      final p = room();
      const pink = Color(0xFFEC407A);
      p.setSchematicConnColor(ConnType.network.index, pink);

      final model = SchematicModel.build(p);
      final networkEdges =
          model.edges.where((e) => e.kind == ConnType.network).toList();
      expect(networkEdges, isNotEmpty);
      for (final e in networkEdges) {
        expect(e.color, pink);
      }
    });

    testWidgets('the toolbar offers a Colors button', (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final p = room();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: SchematicView())),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Colors'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Line colors'), findsOneWidget);
      // Every category is listed by its legend name.
      expect(find.text('Network (via IDF)'), findsWidgets);
    });
  });
}
