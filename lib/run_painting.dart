import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// ============================================================================
///  HOW A CABLE RUN IS DRAWN
/// ============================================================================
///  Geometry and stroke rules shared by the Cabling drawing and the Floor Plan,
///  so a run looks the same on both and a change is made once.
///
///  Three things a drawing with more than one run on it has to do, and none of
///  them is about colour:
///
///    * TELL THE RUNS APART. Colour alone fails the moment the sheet is
///      printed, photocopied or read by somebody who cannot distinguish red
///      from green — and it fails hardest exactly where it matters, on the
///      three parallel lines between the same two boxes. Each run on an edge
///      therefore also gets a DASH PATTERN of its own ([RunLineStyle]).
///
///    * SAY WHICH LINE CROSSES WHICH. Two lines meeting at a point is, on a
///      cabling drawing, indistinguishable from two lines joining at a point.
///      The convention is a HOP: the line on top steps over the one beneath.
///
///    * ADMIT WHEN A RUN LEAVES. A cable to the IDF does not stop at the edge
///      of the page, and a line that simply ends there reads as a cable that
///      simply ends there. The convention is a SQUIGGLE — a break symbol
///      saying "continues off sheet".
/// ============================================================================

// ---------------------------------------------------------------------------
//  LINE STYLES
// ---------------------------------------------------------------------------

/// How a run's line is stroked, over and above its colour.
enum RunLineStyle { solid, dashed, dotted, dashDot, longDash }

const Map<RunLineStyle, String> kRunLineStyleLabels = {
  RunLineStyle.solid: 'solid',
  RunLineStyle.dashed: 'dashed',
  RunLineStyle.dotted: 'dotted',
  RunLineStyle.dashDot: 'dash-dot',
  RunLineStyle.longDash: 'long dash',
};

/// The order styles are handed out in, most legible first: the single run on
/// an edge stays a plain solid line, which is what a drawing with nothing to
/// disambiguate should look like.
const List<RunLineStyle> kRunLineStyleCycle = [
  RunLineStyle.solid,
  RunLineStyle.dashed,
  RunLineStyle.dotted,
  RunLineStyle.dashDot,
  RunLineStyle.longDash,
];

/// The style for the [index]-th run sharing an edge. Wraps rather than running
/// out: six runs on one edge is rare, and two of them alike is still better
/// than one of them invisible.
RunLineStyle runLineStyleForIndex(int index) =>
    kRunLineStyleCycle[index % kRunLineStyleCycle.length];

/// The on/off lengths a style is stroked with, or null for a solid line.
List<double>? dashPatternOf(RunLineStyle style) => switch (style) {
  RunLineStyle.solid => null,
  RunLineStyle.dashed => const [9, 5],
  RunLineStyle.dotted => const [1.5, 4],
  RunLineStyle.dashDot => const [11, 4, 1.5, 4],
  RunLineStyle.longDash => const [18, 6],
};

/// [source] broken into the on-segments of [pattern].
///
/// Flutter strokes whole paths, so a dashed line has to be built as a path of
/// dashes. Walked with [ui.PathMetrics] rather than per-segment arithmetic, so
/// the pattern carries on across a corner curve instead of restarting at every
/// bend — a dash that resets at each vertex makes a routed run look like a
/// different cable on each leg.
Path dashPath(Path source, List<double> pattern) {
  if (pattern.isEmpty) return source;
  final out = Path();
  for (final metric in source.computeMetrics()) {
    double distance = 0;
    int index = 0;
    while (distance < metric.length) {
      final step = pattern[index % pattern.length];
      final end = math.min(distance + step, metric.length);
      if (index.isEven) {
        out.addPath(metric.extractPath(distance, end), Offset.zero);
      }
      distance = end;
      index++;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
//  THE PATH ITSELF
// ---------------------------------------------------------------------------

/// The path a run is drawn along: [route] as a polyline, with its bends
/// rounded and a hop arced over every point in [hops].
///
/// [cornerRadius] 0 leaves the bends square — the Floor Plan draws over an
/// architectural background where a rounded corner reads as an arc of
/// something, while the Cabling sheet is a schematic where cable that turns a
/// right angle in a ceiling is the thing that looks wrong.
///
/// A hop is skipped when it would overlap the one before it or run off either
/// end of its leg: two hops sharing an arc is a shape that means nothing, and
/// a hop half-inside a box is a line the box then hides.
Path buildRunPath(
  List<Offset> route, {
  List<Offset> hops = const [],
  double hopRadius = 6.5,
  double cornerRadius = 0,
}) {
  final path = Path();
  if (route.length < 2) return path;

  var cursor = route.first;
  path.moveTo(cursor.dx, cursor.dy);

  for (int i = 1; i < route.length; i++) {
    final corner = route[i];
    final bool last = i == route.length - 1;
    final Offset legEnd = (last || cornerRadius <= 0)
        ? corner
        : _stepBack(corner, cursor, cornerRadius);

    _hoppedLine(path, cursor, legEnd, hops, hopRadius);

    if (!last && cornerRadius > 0) {
      final outOf = _stepBack(corner, route[i + 1], cornerRadius);
      path.quadraticBezierTo(corner.dx, corner.dy, outOf.dx, outOf.dy);
      cursor = outOf;
    } else {
      cursor = legEnd;
    }
  }
  return path;
}

/// A point [radius] back from [corner] towards [towards]. Never more than half
/// the leg, so a short one cannot overshoot into the corner beyond it.
Offset _stepBack(Offset corner, Offset towards, double radius) {
  final d = towards - corner;
  final length = d.distance;
  if (length == 0) return corner;
  final r = radius > length / 2 ? length / 2 : radius;
  return corner + d / length * r;
}

/// Extends [path] from [a] to [b], arcing over any of [hops] that lie on the
/// way.
void _hoppedLine(
  Path path,
  Offset a,
  Offset b,
  List<Offset> hops,
  double radius,
) {
  final d = b - a;
  final length = d.distance;
  if (length == 0) return;
  final u = d / length;

  final along = <double>[];
  for (final hop in hops) {
    final v = hop - a;
    final t = v.dx * u.dx + v.dy * u.dy; // how far along the leg it sits
    if (t <= radius || t >= length - radius) continue; // too near an end
    if ((v - u * t).distance > 1.5) continue; // not actually on this leg
    along.add(t);
  }
  along.sort();

  var reached = 0.0;
  for (final t in along) {
    if (t - radius < reached) continue; // overlapping the hop before it
    final start = a + u * (t - radius);
    final end = a + u * (t + radius);
    path.lineTo(start.dx, start.dy);
    path.arcToPoint(end, radius: Radius.circular(radius), clockwise: true);
    reached = t + radius;
  }
  path.lineTo(b.dx, b.dy);
}

// ---------------------------------------------------------------------------
//  CROSSINGS
// ---------------------------------------------------------------------------

/// Where [route] crosses any of [others].
///
/// Crossings within [clearOfEnds] of either polyline's ends are left out: runs
/// converge on the box they land in, so the last few pixels of every one of
/// them crosses every other, and hopping there would put a pile of arcs on top
/// of the one place the drawing most needs to be readable.
List<Offset> routeCrossings(
  List<Offset> route,
  Iterable<List<Offset>> others, {
  double clearOfEnds = 20,
}) {
  final out = <Offset>[];
  if (route.length < 2) return out;

  bool nearAnEnd(List<Offset> line, Offset at) =>
      (at - line.first).distance < clearOfEnds ||
      (at - line.last).distance < clearOfEnds;

  for (int i = 0; i < route.length - 1; i++) {
    for (final other in others) {
      if (other.length < 2) continue;
      for (int j = 0; j < other.length - 1; j++) {
        final hit = segmentIntersection(
          route[i],
          route[i + 1],
          other[j],
          other[j + 1],
        );
        if (hit == null) continue;
        if (nearAnEnd(route, hit) || nearAnEnd(other, hit)) continue;
        // The same two runs can cross twice; a duplicate would draw two arcs
        // in one place.
        if (out.any((p) => (p - hit).distance < 2)) continue;
        out.add(hit);
      }
    }
  }
  return out;
}

/// Where segments a-b and c-d cross, or null when they don't (parallel lines
/// and touching endpoints included — neither is a crossing a hop explains).
Offset? segmentIntersection(Offset a, Offset b, Offset c, Offset d) {
  final r = b - a;
  final s = d - c;
  final denominator = r.dx * s.dy - r.dy * s.dx;
  if (denominator.abs() < 1e-9) return null; // parallel or degenerate
  final t = ((c.dx - a.dx) * s.dy - (c.dy - a.dy) * s.dx) / denominator;
  final u = ((c.dx - a.dx) * r.dy - (c.dy - a.dy) * r.dx) / denominator;
  // Strictly inside both segments: an endpoint landing on another line is two
  // runs meeting, which is exactly what a hop must not be drawn over.
  if (t <= 0.001 || t >= 0.999 || u <= 0.001 || u >= 0.999) return null;
  return a + r * t;
}

// ---------------------------------------------------------------------------
//  OFF THE SHEET
// ---------------------------------------------------------------------------

/// [route] redrawn as a squiggle — the break symbol a drawing uses for a run
/// that carries on past the edge of the page, to the IDF or the next floor.
///
/// A straight line that stops at the border reads as a cable that stops at the
/// border, which is how a pull to the telecom room ends up quoted at the
/// length of the room it starts in.
Path squigglePath(
  List<Offset> route, {
  double amplitude = 4.5,
  double wavelength = 14,
}) {
  final path = Path();
  if (route.length < 2 || wavelength <= 0) return path;

  // Walked as one continuous line so the wave carries across a bend rather
  // than restarting, the same reason [dashPath] walks metrics.
  var total = 0.0;
  for (int i = 0; i < route.length - 1; i++) {
    total += (route[i + 1] - route[i]).distance;
  }
  if (total <= 0) return path;

  const stepsPerWave = 8;
  final steps = math.max(8, (total / wavelength * stepsPerWave).round());
  for (int s = 0; s <= steps; s++) {
    final travelled = total * s / steps;
    final at = _pointAt(route, travelled);
    final dir = _directionAt(route, travelled);
    final normal = Offset(-dir.dy, dir.dx);
    // Flat at both ends, so the squiggle joins its box cleanly rather than
    // arriving at an angle.
    final ease = math.sin(math.pi * (s / steps)).clamp(0.0, 1.0);
    final wave =
        math.sin(travelled / wavelength * 2 * math.pi) * amplitude * ease;
    final p = at + normal * wave;
    if (s == 0) {
      path.moveTo(p.dx, p.dy);
    } else {
      path.lineTo(p.dx, p.dy);
    }
  }
  return path;
}

Offset _pointAt(List<Offset> route, double distance) {
  var left = distance;
  for (int i = 0; i < route.length - 1; i++) {
    final leg = (route[i + 1] - route[i]).distance;
    if (leg >= left) {
      return leg == 0
          ? route[i]
          : route[i] + (route[i + 1] - route[i]) * (left / leg);
    }
    left -= leg;
  }
  return route.last;
}

Offset _directionAt(List<Offset> route, double distance) {
  var left = distance;
  for (int i = 0; i < route.length - 1; i++) {
    final d = route[i + 1] - route[i];
    final leg = d.distance;
    if (leg >= left && leg > 0) return d / leg;
    left -= leg;
  }
  final d = route.last - route[route.length - 2];
  final leg = d.distance;
  return leg == 0 ? const Offset(1, 0) : d / leg;
}

// ---------------------------------------------------------------------------
//  STROKING
// ---------------------------------------------------------------------------

/// Strokes one run: [route], in [color], in [style], hopping over [hops], and
/// squiggled when the run leaves the drawing.
///
/// The single entry point both drawings call, so a run cannot come out looking
/// like two different conventions on two sheets of the same set.
void paintRun({
  required Canvas canvas,
  required List<Offset> route,
  required Color color,
  double strokeWidth = 2.4,
  RunLineStyle style = RunLineStyle.solid,
  List<Offset> hops = const [],
  double cornerRadius = 0,
  bool offSheet = false,
}) {
  if (route.length < 2) return;
  final Path base = offSheet
      ? squigglePath(route)
      : buildRunPath(route, hops: hops, cornerRadius: cornerRadius);
  final pattern = dashPatternOf(style);
  canvas.drawPath(
    pattern == null ? base : dashPath(base, pattern),
    Paint()
      ..style = PaintingStyle.stroke
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round,
  );
}

/// The short specimen of a run drawn beside its name in a key: the same
/// colour, the same dash pattern, so the legend and the drawing cannot come
/// apart.
void paintRunSpecimen({
  required Canvas canvas,
  required Offset from,
  required Offset to,
  required Color color,
  RunLineStyle style = RunLineStyle.solid,
  double strokeWidth = 3,
  bool offSheet = false,
}) {
  paintRun(
    canvas: canvas,
    route: [from, to],
    color: color,
    strokeWidth: strokeWidth,
    style: style,
    offSheet: offSheet,
  );
}
