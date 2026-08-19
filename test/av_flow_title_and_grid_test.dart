import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/layout_tools.dart';

/// ============================================================================
///  THE TITLE IS PART OF THE DRAWING, AND THE GRID IS HOW IT STAYS TIDY
/// ============================================================================
///  Two things a signal flow gets judged on that the router knew nothing
///  about. The room name sits at the top-left and goes out with the PNG, so a
///  run drawn over it is issued written across the room name — and the lane a
///  run takes to get over a block of boxes goes exactly there. And a box
///  dropped by hand lands wherever the mouse let go, which is never twice the
///  same y.
/// ============================================================================
void main() {
  AvNode node(String id, Offset pos) => AvNode(
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
    fromNodeId: 'A',
    fromPortId: 'out_1',
    toNodeId: 'B',
    toPortId: 'in_1',
    signal: SignalType.hdmi,
  );

  group('the room title', () {
    test('is measured where it is drawn', () {
      final rect = avRoomTitleRect('Sierra Hall 1200', null);
      // The margin is inside the rect, so it starts above and left of the text.
      expect(rect.left, lessThanOrEqualTo(kAvRoomTitleLeft));
      expect(rect.top, lessThanOrEqualTo(kAvRoomTitleTop));
      expect(rect.right, greaterThan(kAvRoomTitleLeft));
      expect(rect.bottom, greaterThan(kAvRoomTitleTop));

      // And it grows with the name: a fixed guess is a cable through the last
      // word of a long room name.
      expect(
        avRoomTitleRect('Sierra Hall 1200 — Active Learning', null).width,
        greaterThan(rect.width),
      );
    });

    test('an unnamed room still reserves the page heading', () {
      expect(avRoomTitleText(''), 'AV Signal Flow');
      expect(avRoomTitleText('Sierra Hall 1200'), 'Sierra Hall 1200');
    });

    test('a run routed over the top of a blockage keeps off it', () {
      // Two boxes near the top of the page with a tall rack of them between:
      // the nearest clear lane is over the top, which is where the title is.
      final from = node('A', const Offset(20, 90));
      final to = node('B', const Offset(700, 90));
      const blocker = Rect.fromLTWH(360, 60, 190, 700);
      final title = avRoomTitleRect(avRoomTitleText('Sierra Hall 1200'), null);

      List<Offset> route({required bool avoidTitle}) => routeCable(
            fromNode: from,
            toNode: to,
            cable: cable,
            obstacles: [
              blocker,
              from.rect.deflate(2),
              to.rect.deflate(2),
              if (avoidTitle) title,
            ],
          );

      // The case is real: without the title in the obstacle set the run is
      // drawn straight through the room name.
      expect(
        polylineHitsAny(route(avoidTitle: false), [title]),
        isTrue,
        reason: 'the geometry no longer reproduces the overlap',
      );
      // And with it, the run goes some other way — still without cutting
      // through the box it was detouring around.
      final avoided = route(avoidTitle: true);
      expect(polylineHitsAny(avoided, [title]), isFalse);
      expect(polylineHitsAny(avoided, [blocker]), isFalse);
    });
  });

  group('snap to grid', () {
    test('is off until somebody turns it on, and is remembered as a setting',
        () {
      final p = AppStateProvider(autoLoadSettings: false);
      expect(p.snapDiagramsToGrid, isFalse);
      p.setSnapDiagramsToGrid(true);
      expect(p.snapDiagramsToGrid, isTrue);
      expect(p.settingsAsJson()['snapDiagramsToGrid'], isTrue);
    });

    test('off leaves a drop exactly where it was made', () {
      const dropped = Offset(317, 244);
      expect(snapToGrid(dropped, enabled: false), dropped);
    });

    test('on pulls both axes to the nearest square', () {
      final at = snapToGrid(const Offset(317, 244), enabled: true);
      expect(at.dx % kDiagramGridStep, 0);
      expect(at.dy % kDiagramGridStep, 0);
      // The NEAREST square, not the one before it.
      expect(at, const Offset(320, 240));
    });

    test('two boxes dropped near each other land on the same lines', () {
      final a = snapToGrid(const Offset(103, 57), enabled: true);
      final b = snapToGrid(const Offset(97, 62), enabled: true);
      expect(a, b);
    });

    test('a box nudged off a neighbour stays on the grid', () {
      // The drop is snapped, then slid clear — and the slide steps in whole
      // squares, so the landing spot is still square with everything else.
      final desired = snapToGrid(const Offset(300, 300), enabled: true);
      final at = nonOverlappingPosition(
        desired: desired,
        size: const Size(200, 120),
        others: [const Rect.fromLTWH(280, 280, 220, 140)],
        step: kDiagramGridStep,
      );
      expect(at, isNot(desired));
      expect(at.dx % kDiagramGridStep, 0);
      expect(at.dy % kDiagramGridStep, 0);
    });
  });
}
