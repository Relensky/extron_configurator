import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/run_painting.dart';

/// Three things a drawing with more than one run on it has to do, and none of
/// them is about colour: tell the runs apart when the sheet is printed in
/// black and white, say which line crosses which, and admit when a run leaves
/// the page. This is the geometry behind all three.
void main() {
  group('where two runs cross', () {
    test('segments that cross report the point', () {
      final hit = segmentIntersection(
        const Offset(0, 0),
        const Offset(100, 100),
        const Offset(0, 100),
        const Offset(100, 0),
      );
      expect(hit, isNotNull);
      expect(hit!.dx, closeTo(50, 0.001));
      expect(hit.dy, closeTo(50, 0.001));
    });

    test('parallel segments do not', () {
      expect(
        segmentIntersection(
          const Offset(0, 0),
          const Offset(100, 0),
          const Offset(0, 10),
          const Offset(100, 10),
        ),
        isNull,
      );
    });

    test('segments that only meet at an endpoint do not', () {
      // Two runs JOINING at a point is exactly what a hop must not be drawn
      // over — the arc would say they pass, when they meet.
      expect(
        segmentIntersection(
          const Offset(0, 0),
          const Offset(50, 50),
          const Offset(50, 50),
          const Offset(100, 0),
        ),
        isNull,
      );
    });

    test('segments that miss each other do not', () {
      expect(
        segmentIntersection(
          const Offset(0, 0),
          const Offset(10, 10),
          const Offset(90, 0),
          const Offset(100, 10),
        ),
        isNull,
      );
    });
  });

  group('routeCrossings', () {
    test('finds a crossing in the middle of two long runs', () {
      final hits = routeCrossings(
        const [Offset(0, 100), Offset(400, 100)],
        const [
          [Offset(200, 0), Offset(200, 300)],
        ],
      );
      expect(hits.length, 1);
      expect(hits.single.dx, closeTo(200, 0.001));
    });

    test('ignores crossings near either run\'s ends', () {
      // Runs converge on the box they land in, so the last few pixels of every
      // one of them crosses every other. Hopping there would pile arcs on the
      // one place the drawing most needs to be readable.
      final hits = routeCrossings(
        const [Offset(0, 100), Offset(400, 100)],
        const [
          [Offset(8, 0), Offset(8, 300)],
        ],
      );
      expect(hits, isEmpty);
    });

    test('two runs crossing in almost the same spot get one hop', () {
      // Two arcs a pixel apart is a shape that means nothing.
      final hits = routeCrossings(
        const [Offset(0, 100), Offset(400, 100)],
        const [
          [Offset(200, 0), Offset(200, 300)],
          [Offset(200, 0), Offset(201, 300)],
        ],
      );
      expect(hits.length, 1);
    });
  });

  group('line styles', () {
    test('the first run drawn is solid, and the rest are not', () {
      expect(runLineStyleForIndex(0), RunLineStyle.solid);
      expect(runLineStyleForIndex(1), isNot(RunLineStyle.solid));
      expect(dashPatternOf(RunLineStyle.solid), isNull);
      expect(dashPatternOf(RunLineStyle.dashed), isNotNull);
    });

    test('the cycle wraps rather than running out', () {
      expect(
        runLineStyleForIndex(kRunLineStyleCycle.length),
        RunLineStyle.solid,
      );
    });

    test('every style has a name for the key to print', () {
      for (final style in RunLineStyle.values) {
        expect(kRunLineStyleLabels[style], isNotNull);
      }
    });

    test('a dashed path is shorter than the line it dashes', () {
      final solid = buildRunPath(const [Offset(0, 0), Offset(200, 0)]);
      final dashed = dashPath(solid, dashPatternOf(RunLineStyle.dashed)!);

      double lengthOf(Path p) =>
          p.computeMetrics().fold(0.0, (sum, m) => sum + m.length);

      expect(lengthOf(solid), closeTo(200, 0.5));
      expect(lengthOf(dashed), lessThan(lengthOf(solid)));
      expect(lengthOf(dashed), greaterThan(0));
    });
  });

  group('the path', () {
    test('a plain route is the straight line it looks like', () {
      final path = buildRunPath(const [Offset(0, 0), Offset(100, 0)]);
      expect(path.getBounds().width, closeTo(100, 0.001));
      expect(path.getBounds().height, closeTo(0, 0.001));
    });

    test('a hop lifts the line off the straight', () {
      final flat = buildRunPath(const [Offset(0, 0), Offset(100, 0)]);
      final hopped = buildRunPath(
        const [Offset(0, 0), Offset(100, 0)],
        hops: const [Offset(50, 0)],
      );
      expect(flat.getBounds().height, closeTo(0, 0.001));
      expect(hopped.getBounds().height, greaterThan(4));
    });

    test('a hop too near the end of its leg is skipped', () {
      final path = buildRunPath(
        const [Offset(0, 0), Offset(100, 0)],
        hops: const [Offset(2, 0)],
      );
      expect(path.getBounds().height, closeTo(0, 0.001));
    });

    test('a point that is not on the leg is not hopped over', () {
      final path = buildRunPath(
        const [Offset(0, 0), Offset(100, 0)],
        hops: const [Offset(50, 40)],
      );
      expect(path.getBounds().height, closeTo(0, 0.001));
    });

    test('an empty or single-point route draws nothing', () {
      expect(buildRunPath(const []).computeMetrics().isEmpty, isTrue);
      expect(
        buildRunPath(const [Offset(1, 1)]).computeMetrics().isEmpty,
        isTrue,
      );
    });
  });

  group('leaving the page', () {
    test('a squiggle waves either side of the line it replaces', () {
      final squiggle = squigglePath(const [Offset(0, 50), Offset(120, 50)]);
      final bounds = squiggle.getBounds();
      expect(bounds.height, greaterThan(3),
          reason: 'a break symbol that is flat is just a line');
      expect(bounds.width, closeTo(120, 2));
    });

    test('it starts and ends on the line, so it joins its box cleanly', () {
      final squiggle = squigglePath(const [Offset(0, 50), Offset(120, 50)]);
      final metric = squiggle.computeMetrics().first;
      expect(metric.getTangentForOffset(0)!.position.dy, closeTo(50, 0.5));
      expect(
        metric.getTangentForOffset(metric.length)!.position.dy,
        closeTo(50, 0.5),
      );
    });

    test('a degenerate route squiggles nothing', () {
      expect(squigglePath(const [Offset(5, 5)]).computeMetrics().isEmpty, isTrue);
      expect(
        squigglePath(const [Offset(5, 5), Offset(5, 5)])
            .computeMetrics()
            .isEmpty,
        isTrue,
      );
    });
  });
}
