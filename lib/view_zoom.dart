import 'dart:math' as math;

import 'package:flutter/material.dart';

/// ============================================================================
///  FIT TO VIEW
/// ============================================================================
///  Every diagram in this app lives inside an unconstrained [InteractiveViewer]
///  — the canvas is as big as the drawing needs and the window shows a piece of
///  it. That is right for working on one corner of a rack and wrong for the
///  question people ask most often, which is "what does the whole thing look
///  like?". Pinching back out to find it is a fiddle, and on a 42U elevation or
///  a twenty-device flow it is a long fiddle.
///
///  So each of those tabs gets one button, and all three share this: measure
///  what is actually drawn, measure the hole it is being looked at through, and
///  set the transform so the first fits inside the second.
///
///  Measuring the RENDERED content rather than a size the view calculates for
///  itself is deliberate. The three canvases size themselves three different
///  ways, and a fit computed from a stale or slightly-wrong number is worse
///  than no fit at all: it lands somewhere that looks almost right, which is
///  harder to recover from than a view that plainly did nothing.
/// ============================================================================

/// The rendered size of whatever [key] is attached to, or null when it has not
/// been laid out yet (the very first frame, or a tab that has never been on
/// screen).
Size? renderedSize(GlobalKey key) {
  final box = key.currentContext?.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  final size = box.size;
  if (size.width <= 0 || size.height <= 0) return null;
  return size;
}

/// Zooms and pans [controller] so everything drawn under [contentKey] fits
/// inside [viewportKey], centered, with [padding] px of air around it.
///
/// Returns false when either widget has not been laid out yet, so the caller
/// can say so instead of leaving the user looking at an unchanged view and
/// wondering whether the button works.
///
/// [maxScale] defaults to 1: fitting a small diagram should show it at its
/// natural size, not blow a two-device drawing up to fill a 4K monitor.
bool fitToViewport({
  required TransformationController controller,
  required GlobalKey contentKey,
  required GlobalKey viewportKey,
  double padding = 28,
  double maxScale = 1.0,
  double minScale = 0.05,
}) {
  final content = renderedSize(contentKey);
  final viewport = renderedSize(viewportKey);
  if (content == null || viewport == null) return false;

  final availableWidth = viewport.width - padding * 2;
  final availableHeight = viewport.height - padding * 2;
  if (availableWidth <= 0 || availableHeight <= 0) return false;

  final scale = math
      .min(availableWidth / content.width, availableHeight / content.height)
      .clamp(minScale, maxScale);

  // Center what is left over. The transform maps canvas coordinates into the
  // viewport, so the translation is applied after the scale.
  final dx = (viewport.width - content.width * scale) / 2;
  final dy = (viewport.height - content.height * scale) / 2;

  controller.value = Matrix4.identity()
    ..translateByDouble(dx, dy, 0, 1)
    ..scaleByDouble(scale, scale, 1, 1);
  return true;
}

/// Back to 1:1 at the top-left — the counterpart to a fit, for when the answer
/// to "show me everything" is "now show me it properly".
void resetZoom(TransformationController controller) {
  controller.value = Matrix4.identity();
}
