import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

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

/// A drawing's text at drawing size, whatever Text Size is set to.
///
/// Boxes, port rows and cable routes are laid out in fixed drawing units, so
/// text scaled past them spilled out of its box and under the cables. The
/// zoom makes a drawing bigger instead, and an export no longer depends on
/// the Text Size of whoever saved it.
Widget drawingText(Widget child) => MediaQuery.withNoTextScaling(child: child);

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
    // All three axes: InteractiveViewer reads the zoom as the largest of
    // them, and a depth left at 1 read every fit below 100% as 100% - which
    // then threw out the wheel's zoom limits.
    ..scaleByDouble(scale, scale, scale, 1);
  return true;
}

/// Pans [controller] so [target] (canvas coordinates) sits in the middle of a
/// viewport of [viewport] size. Zooms in to [readableScale] when the view is
/// further out than that, and out when the target would not fit.
void centerOnRect(
  TransformationController controller,
  Size viewport,
  Rect target, {
  double readableScale = 0.8,
  double padding = 40,
  double minScale = 0.05,
}) {
  final fit = math.min(
    (viewport.width - padding * 2) / target.width,
    (viewport.height - padding * 2) / target.height,
  );
  final current = controller.value.getMaxScaleOnAxis();
  final scale =
      math.max(math.min(math.max(current, readableScale), fit), minScale);
  final dx = viewport.width / 2 - target.center.dx * scale;
  final dy = viewport.height / 2 - target.center.dy * scale;
  controller.value = Matrix4.identity()
    ..translateByDouble(dx, dy, 0, 1)
    ..scaleByDouble(scale, scale, scale, 1);
}

/// Back to 1:1 at the top-left — the counterpart to a fit, for when the answer
/// to "show me everything" is "now show me it properly".
void resetZoom(TransformationController controller) {
  controller.value = Matrix4.identity();
}
