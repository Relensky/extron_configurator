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
/// in rings — nearest first — so a box nudged off a neighbour lands beside
/// where it was dropped rather than somewhere across the page.
Offset nonOverlappingPosition({
  required Offset desired,
  required Size size,
  required List<Rect> others,
  double gap = 12,
  double step = 16,
  int maxRings = 48,
}) {
  bool free(Offset at) {
    final candidate = Rect.fromLTWH(at.dx, at.dy, size.width, size.height)
        .inflate(gap / 2);
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
