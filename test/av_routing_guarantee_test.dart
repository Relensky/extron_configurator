import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/layout_tools.dart';

/// The router must never draw a run through a device. The quick shapes handle
/// the easy cases; when they all fail the lattice search takes over. These
/// hammer the awkward geometry — enclosed ports, ports facing away from each
/// other, dense fields of boxes — and assert the invariant every time.
void main() {
  AvNode node(String id, Offset pos, {List<AvPort>? ports}) => AvNode(
    id: id,
    label: id,
    model: '',
    pos: pos,
    ports:
        ports ??
        const [
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

  /// The obstacle set the canvas builds: other devices inflated, the run's own
  /// two barely deflated so the ports stay reachable.
  List<Rect> obstaclesFor(List<AvNode> all, String fromId, String toId) => [
    for (final n in all)
      if (n.id == fromId || n.id == toId) n.rect.deflate(2) else n.rect.inflate(10),
  ];

  group('the exact blocking test', () {
    const box = Rect.fromLTWH(100, 100, 100, 100);

    test('a line straight through is blocked', () {
      expect(
        segmentHitsRect(const Offset(0, 150), const Offset(300, 150), box),
        isTrue,
      );
    });

    test('a line running along an edge is allowed', () {
      expect(
        segmentHitsRect(const Offset(0, 100), const Offset(300, 100), box),
        isFalse,
      );
    });

    test('a line clearing the box is allowed', () {
      expect(
        segmentHitsRect(const Offset(0, 90), const Offset(300, 90), box),
        isFalse,
      );
    });

    test('a segment that stops short is allowed', () {
      expect(
        segmentHitsRect(const Offset(0, 150), const Offset(90, 150), box),
        isFalse,
      );
    });

    test('a diagonal clipping a corner is caught', () {
      // A sampled test can step right over this; the exact one cannot.
      expect(
        segmentHitsRect(const Offset(90, 190), const Offset(190, 90), box),
        isTrue,
      );
    });
  });

  group('routes never cross a device', () {
    test('source dragged to the far side of its destination', () {
      final a = node('A', const Offset(700, 0));
      final b = node('B', const Offset(200, 0));
      final all = [a, b];
      final obstacles = obstaclesFor(all, 'A', 'B');

      final route = routeCable(
        fromNode: a,
        toNode: b,
        cable: cable,
        obstacles: obstacles,
      );
      expect(polylineHitsAny(route, obstacles), isFalse);
    });

    test('a destination boxed in on three sides', () {
      final a = node('A', const Offset(0, 300));
      final b = node('B', const Offset(600, 300));
      // Walls above, below and to the right of B, leaving only its own input
      // face open on the left.
      final walls = [
        node('W1', const Offset(600, 180)),
        node('W2', const Offset(600, 420)),
        node('W3', const Offset(830, 300)),
      ];
      final all = [a, b, ...walls];
      final obstacles = obstaclesFor(all, 'A', 'B');

      final route = routeCable(
        fromNode: a,
        toNode: b,
        cable: cable,
        obstacles: obstacles,
      );
      expect(polylineHitsAny(route, obstacles), isFalse);
    });

    test('a dense field of devices between the two ends', () {
      final a = node('A', const Offset(0, 400));
      final b = node('B', const Offset(1400, 400));
      final field = <AvNode>[
        for (int col = 0; col < 5; col++)
          for (int row = 0; row < 6; row++)
            node('F${col}_$row', Offset(250 + col * 220, 120 + row * 130)),
      ];
      final all = [a, b, ...field];
      final obstacles = obstaclesFor(all, 'A', 'B');

      final route = routeCable(
        fromNode: a,
        toNode: b,
        cable: cable,
        obstacles: obstacles,
      );
      expect(polylineHitsAny(route, obstacles), isFalse);
      expect(route.first, a.anchorOf('out_1'));
      expect(route.last, b.anchorOf('in_1'));
    });

    test('every run in 200 random layouts stays clear', () {
      // Fixed seed: a failure has to be reproducible, not a rumour.
      final rng = Random(20260809);
      int routed = 0;

      for (int trial = 0; trial < 200; trial++) {
        final count = 2 + rng.nextInt(7);
        final nodes = <AvNode>[
          for (int i = 0; i < count; i++)
            node(
              'N$i',
              Offset(rng.nextDouble() * 900, rng.nextDouble() * 700),
            ),
        ];
        // Two distinct endpoints.
        final fromIndex = rng.nextInt(nodes.length);
        int toIndex = rng.nextInt(nodes.length);
        if (toIndex == fromIndex) toIndex = (toIndex + 1) % nodes.length;

        final from = nodes[fromIndex], to = nodes[toIndex];
        final run = AvCable(
          id: 'C$trial',
          fromNodeId: from.id,
          fromPortId: 'out_1',
          toNodeId: to.id,
          toPortId: 'in_1',
          signal: SignalType.hdmi,
        );
        final obstacles = obstaclesFor(nodes, from.id, to.id);

        final route = routeCable(
          fromNode: from,
          toNode: to,
          cable: run,
          obstacles: obstacles,
        );

        // Random placement drops boxes on top of each other, which can bury a
        // port inside a neighbor — no route out of that exists for anyone to
        // find. The canvas prevents it by keeping devices apart (see
        // nonOverlappingPosition), so those layouts are out of scope.
        bool buried(Offset p) => obstacles.any(
          (r) => p.dx > r.left && p.dx < r.right && p.dy > r.top && p.dy < r.bottom,
        );
        if (buried(from.anchorOf('out_1')) || buried(to.anchorOf('in_1'))) {
          continue;
        }
        if (buried(route[1]) || buried(route[route.length - 2])) continue;

        routed++;
        expect(
          polylineHitsAny(route, obstacles),
          isFalse,
          reason: 'trial $trial: ${from.id} -> ${to.id} crossed a device',
        );
      }

      // Make sure the loop actually exercised the router.
      expect(routed, greaterThan(120));
    });
  });

  group('the lattice search itself', () {
    test('finds a way round a single wall', () {
      const wall = Rect.fromLTWH(200, 0, 60, 400);
      final route = latticeRoute(
        const Offset(100, 200),
        const Offset(400, 200),
        const [wall],
      );
      expect(route, isNotNull);
      expect(polylineHitsAny(route!, const [wall]), isFalse);
    });

    test('returns null when the target is completely walled off', () {
      // A closed box around the goal, with no gap at all.
      const goal = Offset(500, 500);
      final cage = <Rect>[
        const Rect.fromLTWH(400, 380, 200, 40), // above
        const Rect.fromLTWH(400, 580, 200, 40), // below
        const Rect.fromLTWH(380, 380, 40, 240), // left
        const Rect.fromLTWH(580, 380, 40, 240), // right
      ];
      expect(latticeRoute(const Offset(100, 500), goal, cage), isNull);
    });

    test('a straight shot comes back straight, with no invented bends', () {
      final route = latticeRoute(
        const Offset(0, 100),
        const Offset(400, 100),
        const [Rect.fromLTWH(0, 300, 100, 100)],
      );
      expect(route, isNotNull);
      expect(route!.length, 2);
    });
  });

  test('a busy page routes fast enough to drag through', () {
    // Routing runs on every build, including each frame of a drag, so the
    // pathfinder has to stay cheap on a realistically busy diagram.
    final nodes = <AvNode>[
      for (int col = 0; col < 6; col++)
        for (int row = 0; row < 5; row++)
          node('D${col}_$row', Offset(60 + col * 300, 60 + row * 190)),
    ];
    final runs = <AvCable>[
      for (int i = 0; i < nodes.length - 1; i++)
        AvCable(
          id: 'C$i',
          fromNodeId: nodes[i].id,
          fromPortId: 'out_1',
          toNodeId: nodes[i + 1].id,
          toPortId: 'in_1',
          signal: SignalType.hdmi,
        ),
    ];

    final watch = Stopwatch()..start();
    for (final run in runs) {
      final from = nodes.firstWhere((n) => n.id == run.fromNodeId);
      final to = nodes.firstWhere((n) => n.id == run.toNodeId);
      final obstacles = obstaclesFor(nodes, from.id, to.id);
      final route = routeCable(
        fromNode: from,
        toNode: to,
        cable: run,
        obstacles: obstacles,
      );
      expect(polylineHitsAny(route, obstacles), isFalse);
    }
    watch.stop();

    expect(
      watch.elapsedMilliseconds,
      lessThan(400),
      reason: '30 devices and ${runs.length} runs took '
          '${watch.elapsedMilliseconds}ms — too slow to drag through',
    );
  });

  group('manual bends', () {
    test('a clear leg is kept exactly as the user drew it, diagonal and all',
        () {
      final a = node('A', const Offset(0, 0));
      final b = node('B', const Offset(600, 0));
      final far = node('FAR', const Offset(0, 900));
      final all = [a, b, far];
      final obstacles = obstaclesFor(all, 'A', 'B');

      final bent = cable.copyWith(waypoints: const [Offset(300, 400)]);
      final route = routeCable(
        fromNode: a,
        toNode: b,
        cable: bent,
        obstacles: obstacles,
      );

      // Nothing is in the way, so the bend is honoured untouched.
      expect(route.length, 3);
      expect(route[1], const Offset(300, 400));
    });

    test('a blocked leg routes around instead of cutting through', () {
      final a = node('A', const Offset(0, 0));
      final b = node('B', const Offset(900, 0));
      // Sits between the bend and B.
      final blocker = node('MID', const Offset(500, 320));
      final all = [a, b, blocker];
      final obstacles = obstaclesFor(all, 'A', 'B');

      final bent = cable.copyWith(waypoints: const [Offset(200, 380)]);
      final route = routeCable(
        fromNode: a,
        toNode: b,
        cable: bent,
        obstacles: obstacles,
      );

      expect(
        polylineHitsAny(route, obstacles),
        isFalse,
        reason: 'a hand-drawn bend still must not drag the line through a box',
      );
      // The bend the user placed is still on the route.
      expect(
        route.any((p) => (p - const Offset(200, 380)).distance < 0.01),
        isTrue,
        reason: 'the bend itself should be preserved',
      );
    });

    test('several bends each keep their place while blocked legs detour', () {
      final a = node('A', const Offset(0, 0));
      final b = node('B', const Offset(1200, 0));
      final blockers = [
        node('M1', const Offset(400, 300)),
        node('M2', const Offset(800, 300)),
      ];
      final all = [a, b, ...blockers];
      final obstacles = obstaclesFor(all, 'A', 'B');

      const bends = [Offset(250, 500), Offset(650, 520), Offset(1050, 500)];
      final bent = cable.copyWith(waypoints: bends);
      final route = routeCable(
        fromNode: a,
        toNode: b,
        cable: bent,
        obstacles: obstacles,
      );

      expect(polylineHitsAny(route, obstacles), isFalse);
      for (final bend in bends) {
        expect(
          route.any((p) => (p - bend).distance < 0.01),
          isTrue,
          reason: 'bend $bend was dropped',
        );
      }
    });

    test('a bend dropped inside a device is pushed clear of it', () {
      const box = Rect.fromLTWH(100, 100, 200, 100);
      // Dead center of the box: the shortest way out wins.
      final out = pushOutOfRects(const Offset(200, 150), const [box]);
      expect(
        out.dx > box.right || out.dx < box.left ||
            out.dy > box.bottom || out.dy < box.top,
        isTrue,
      );

      // Near the top edge, so it should pop out of the top.
      final nearTop = pushOutOfRects(const Offset(200, 110), const [box]);
      expect(nearTop.dy, lessThan(box.top));
      expect(nearTop.dx, 200);
    });

    test('a point already outside is left alone', () {
      const box = Rect.fromLTWH(100, 100, 200, 100);
      const p = Offset(50, 50);
      expect(pushOutOfRects(p, const [box]), p);
    });
  });
}
