import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// ============================================================================
///  SHARED DIAGRAM LAYOUT HELPERS
/// ============================================================================
///  Geometry both diagram tabs need. Kept out of either tab's model so the
///  Control Schematic doesn't have to depend on the AV one to reuse it.
/// ============================================================================

/// The closest spot to [desired] where a box of [size] doesn't overlap any of
/// [others], leaving [gap] between boxes.
///
/// Returns [desired] untouched when it's already clear, so a drop that lands
/// somewhere sensible is never second-guessed. Otherwise it searches outward
/// in rings — nearest first — so a box nudged off a neighbor lands beside
/// where it was dropped rather than somewhere across the page.
/// [gap] is the clearance actually guaranteed between two boxes. The AV
/// router treats devices as obstacles inflated by 10px and runs its cable
/// stubs off the box faces, so the gap has to stay comfortably above that or
/// a port anchor ends up buried inside a neighbor's obstacle and there is
/// no clean route out of it.
Offset nonOverlappingPosition({
  required Offset desired,
  required Size size,
  required List<Rect> others,
  double gap = 26,
  double step = 16,
  int maxRings = 48,
}) {
  bool free(Offset at) {
    final candidate = Rect.fromLTWH(
      at.dx,
      at.dy,
      size.width,
      size.height,
    ).inflate(gap);
    for (final other in others) {
      if (candidate.overlaps(other)) return false;
    }
    return true;
  }

  if (free(desired)) return desired;

  // Eight directions per ring, expanding outward. Right and down come first
  // so a nudged box drifts the way a reading eye expects.
  const directions = <Offset>[
    Offset(1, 0),
    Offset(0, 1),
    Offset(-1, 0),
    Offset(0, -1),
    Offset(1, 1),
    Offset(-1, 1),
    Offset(1, -1),
    Offset(-1, -1),
  ];

  for (int ring = 1; ring <= maxRings; ring++) {
    final distance = ring * step;
    for (final d in directions) {
      final at = Offset(
        math.max(0, desired.dx + d.dx * distance),
        math.max(0, desired.dy + d.dy * distance),
      );
      if (free(at)) return at;
    }
  }
  // Nothing within reach — leave it where the user put it rather than
  // teleporting it somewhere arbitrary.
  return desired;
}

/// The grid a diagram's boxes line up on when "Snap to grid" is on.
///
/// A drawing is read by eye, and the eye picks up a box sitting four pixels
/// below its neighbour long before anybody can say why the sheet looks wrong.
/// Dragging with a mouse cannot land the same y twice, so the two ways to get
/// a tidy drawing are a full auto-arrange — which throws away every deliberate
/// placement — or a grid. 20 divides into the column pitch and the row gap the
/// automatic layouts use, so a hand-placed box lands in line with the ones
/// those passes put down.
const double kDiagramGridStep = 20;

/// [p] pulled onto the [step] grid, or returned untouched when [enabled] is
/// false.
///
/// The flag is a parameter rather than the caller's `if` so that a page can
/// route every placement through one line and the setting cannot be honoured
/// in the drag preview but forgotten on the drop — which is the bug that makes
/// a snap feel broken: the box jumps somewhere other than where it was shown.
Offset snapToGrid(
  Offset p, {
  required bool enabled,
  double step = kDiagramGridStep,
}) {
  if (!enabled || step <= 0) return p;
  return Offset((p.dx / step).roundToDouble() * step,
      (p.dy / step).roundToDouble() * step);
}

/// How close a dragged bend has to come to lining up with its neighbour
/// before it is pulled square with it.
///
/// Cable in a building runs along walls, trays and corridors, so the bends
/// somebody puts in a run are nearly always meant to be square — and hitting
/// an exact right angle by dragging a dot with a mouse is a thing nobody can
/// do. Small enough that a deliberately diagonal leg is left alone.
const double kRightAngleSnap = 9;

/// [point] pulled square with whichever of [neighbours] it has come close to.
///
/// Each axis is considered separately, so a bend can end up square with the
/// point before it horizontally and the one after it vertically — which is
/// exactly the corner an L-shaped route is made of.
Offset snapToRightAngle(
  Offset point,
  Iterable<Offset> neighbours, {
  double tolerance = kRightAngleSnap,
}) {
  var x = point.dx;
  var y = point.dy;
  var bestX = tolerance;
  var bestY = tolerance;
  for (final n in neighbours) {
    final dx = (point.dx - n.dx).abs();
    if (dx <= bestX) {
      bestX = dx;
      x = n.dx;
    }
    final dy = (point.dy - n.dy).abs();
    if (dy <= bestY) {
      bestY = dy;
      y = n.dy;
    }
  }
  return Offset(x, y);
}

/// The corner that turns the straight leg [a] -> [b] into two square legs.
///
/// Goes the LONG way first — horizontally when the leg is wider than it is
/// tall — because that is the way cable actually runs: along the wall, then
/// across. The other corner is a right angle too, and it is the one that
/// reads as a detour.
Offset rightAngleCorner(Offset a, Offset b) =>
    (b.dx - a.dx).abs() >= (b.dy - a.dy).abs()
        ? Offset(b.dx, a.dy)
        : Offset(a.dx, b.dy);

/// The bends that put a right-angle turn into the leg [a] -> [b].
///
/// TWO answers, because a leg has two shapes:
///
///   * a DIAGONAL leg becomes an L with one corner — along, then across, which
///     is how cable is actually pulled;
///   * a leg that is ALREADY square has nothing to straighten, so a single
///     corner would land on top of one of its ends. What that leg wants is a
///     JOG: out to one side by [jog], along, and back — the shape a run takes
///     to get round a beam or into a different tray, and four right angles
///     rather than none.
List<Offset> rightAngleTurn(Offset a, Offset b, {double jog = 44}) {
  final dx = (b.dx - a.dx).abs();
  final dy = (b.dy - a.dy).abs();
  const flat = 1.0; // a leg within a pixel of square IS square
  if (dx > flat && dy > flat) return [rightAngleCorner(a, b)];

  final mid = (a + b) / 2;
  // Out to the side the leg is not already running along.
  final out = dx <= flat ? Offset(jog, 0) : Offset(0, jog);
  // A quarter of the way along and three quarters, so the jog is a jog rather
  // than a single kink at the middle.
  final quarter = (b - a) / 4;
  return [mid - quarter + out, mid + quarter + out];
}

/// Moves [p] just outside any of [rects] it has landed inside, leaving
/// [margin] clearance and taking the shortest way out.
///
/// A cable bend dropped inside a device is the one case the router can't
/// honour — there is no path out of a solid box — so the bend is nudged clear
/// as it's dragged rather than left somewhere that forces a line through the
/// device.
Offset pushOutOfRects(Offset p, List<Rect> rects, {double margin = 10}) {
  var out = p;
  // A couple of passes, because sliding clear of one box can put it inside
  // its neighbor.
  for (int pass = 0; pass < 3; pass++) {
    var moved = false;
    for (final r in rects) {
      if (out.dx <= r.left ||
          out.dx >= r.right ||
          out.dy <= r.top ||
          out.dy >= r.bottom) {
        continue;
      }
      // Shortest way out of this box.
      final toLeft = out.dx - r.left;
      final toRight = r.right - out.dx;
      final toTop = out.dy - r.top;
      final toBottom = r.bottom - out.dy;
      final least = math.min(
        math.min(toLeft, toRight),
        math.min(toTop, toBottom),
      );
      if (least == toLeft) {
        out = Offset(r.left - margin, out.dy);
      } else if (least == toRight) {
        out = Offset(r.right + margin, out.dy);
      } else if (least == toTop) {
        out = Offset(out.dx, r.top - margin);
      } else {
        out = Offset(out.dx, r.bottom + margin);
      }
      moved = true;
    }
    if (!moved) break;
  }
  return out;
}
