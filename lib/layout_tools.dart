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
