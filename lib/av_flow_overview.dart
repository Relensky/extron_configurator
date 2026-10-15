import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:material_ui/material_ui.dart';

/// ============================================================================
///  ZOOM, AND A MAGNIFIER FOR A DRAWING ZOOMED OUT TO FIT
/// ============================================================================
///  The AV Flow's zoom bar - out, the percentage, in, fit all, actual size -
///  the same furniture the screenshot tool has, and its magnifier: a square
///  lens following the pointer that shows that part of the drawing at full
///  size, with a minimap in its corner saying where in the room it is.
///
///  The lens and its minimap are drawn from a SNAPSHOT of the drawing taken at
///  full size - not a second live copy of the canvas (which drew black), and
///  not the pixels on screen (which are a blur at 5%).
/// ============================================================================

/// Most pixels along either side of a snapshot - about 64 MB at most.
const double kSnapshotMaxSide = 4096;

/// The drawing under [key] as a picture, at full size or as near as
/// [kSnapshotMaxSide] allows, with the ratio it was taken at. Null when it
/// has not been painted yet.
Future<({ui.Image image, double ratio})?> snapshotDrawing(GlobalKey key) async {
  // Everything inside the try: a boundary not painted yet throws, and a
  // failure here must come back as "try again", never as an exception.
  // (No debugNeedsPaint check - that is debug-only and throws in a release
  // build, which is what kept the magnifier from ever showing.)
  try {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderRepaintBoundary || !box.hasSize) return null;
    final size = box.size;
    if (size.isEmpty) return null;
    final ratio =
        math.min(1.0, kSnapshotMaxSide / math.max(size.width, size.height));
    final image = await box.toImage(pixelRatio: ratio);
    return (image: image, ratio: ratio);
  } catch (_) {
    return null;
  }
}

/// Zooms [controller] by [factor] about the middle of a viewport of
/// [viewport] size, between [minScale] and [maxScale].
void zoomAboutCenter(
  TransformationController controller,
  Size viewport,
  double factor, {
  required double minScale,
  required double maxScale,
}) {
  final scale = controller.value.getMaxScaleOnAxis();
  final next = (scale * factor).clamp(minScale, maxScale);
  setZoomAboutCenter(controller, viewport, next);
}

/// Sets [controller]'s zoom to [scale], keeping what is in the middle of the
/// viewport in the middle.
void setZoomAboutCenter(
  TransformationController controller,
  Size viewport,
  double scale,
) {
  final current = controller.value.getMaxScaleOnAxis();
  if (current <= 0) return;
  final factor = scale / current;
  final focal = controller.toScene(viewport.center(Offset.zero));
  controller.value = controller.value.clone()
    ..translateByDouble(focal.dx, focal.dy, 0, 1)
    // All three axes: the zoom is read back as the largest of them, so a
    // depth left at 1 read every zoom-out as 100%.
    ..scaleByDouble(factor, factor, factor, 1)
    ..translateByDouble(-focal.dx, -focal.dy, 0, 1);
}

/// The zoom bar over the drawing: out, percentage, in, fit, actual size and
/// the magnifier.
class AvZoomBar extends StatelessWidget {
  const AvZoomBar({
    super.key,
    required this.controller,
    required this.onOut,
    required this.onIn,
    required this.onFit,
    required this.onActual,
    required this.magnifier,
    required this.onMagnifier,
  });

  final TransformationController controller;
  final VoidCallback onOut;
  final VoidCallback onIn;
  final VoidCallback onFit;
  final VoidCallback onActual;
  final bool magnifier;
  final ValueChanged<bool> onMagnifier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget button(String key, IconData icon, String tip, VoidCallback tap,
            {bool on = false}) =>
        IconButton(
          key: ValueKey('av_zoom_$key'),
          icon: Icon(icon, size: 18),
          tooltip: tip,
          isSelected: on,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
          onPressed: tap,
        );
    return Material(
      elevation: 2,
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            button('out', Icons.zoom_out, 'Zoom out', onOut),
            SizedBox(
              width: 48,
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  final pct = controller.value.getMaxScaleOnAxis() * 100;
                  return Text(
                    pct < 10
                        ? '${pct.toStringAsFixed(1)}%'
                        : '${pct.round()}%',
                    key: const ValueKey('av_zoom_level'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall,
                  );
                },
              ),
            ),
            button('in', Icons.zoom_in, 'Zoom in', onIn),
            const SizedBox(width: 2),
            button('fit', Icons.fit_screen, 'Fit the whole drawing on screen',
                onFit),
            button('actual', Icons.crop_free, 'Actual size (100%)', onActual),
            const SizedBox(width: 2),
            button(
              'magnifier',
              magnifier ? Icons.search_off : Icons.search,
              magnifier
                  ? 'Turn the magnifier off'
                  : 'Magnifier - a square lens over the drawing, at full '
                      'size, with a minimap of where it is',
              () => onMagnifier(!magnifier),
              on: magnifier,
            ),
          ],
        ),
      ),
    );
  }
}

/// The magnifier's square: [snapshot] around [scene] (a point on the
/// drawing) at [zoom], with a minimap of the whole drawing in its corner.
class AvMagnifierLens extends StatelessWidget {
  const AvMagnifierLens({
    super.key,
    required this.image,
    required this.ratio,
    required this.scene,
    this.zoom = 1.0,
    this.paintLive,
    this.repaint,
  });

  final ui.Image image;
  final double ratio;
  final Offset scene;
  final double zoom;

  /// Paints what moves - the selected run's chevrons - over the picture, in
  /// drawing coordinates. The snapshot is a still, so they are drawn live.
  final void Function(Canvas canvas)? paintLive;

  /// Repaints the lens on every tick of [paintLive]'s animation.
  final Listenable? repaint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('av_magnifier_lens'),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.primary, width: 2),
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 12)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CustomPaint(
          painter: _LensPainter(
            image: image,
            ratio: ratio,
            scene: scene,
            zoom: zoom,
            frame: scheme.primary,
            paper: scheme.surface,
            paintLive: paintLive,
            repaint: repaint,
          ),
        ),
      ),
    );
  }
}

class _LensPainter extends CustomPainter {
  _LensPainter({
    required this.image,
    required this.ratio,
    required this.scene,
    required this.zoom,
    required this.frame,
    required this.paper,
    this.paintLive,
    super.repaint,
  });

  final ui.Image image;
  final double ratio;
  final Offset scene;
  final double zoom;
  final Color frame;
  final Color paper;
  final void Function(Canvas canvas)? paintLive;

  @override
  void paint(Canvas canvas, Size size) {
    final whole = Rect.fromLTWH(
        0, 0, image.width.toDouble(), image.height.toDouble());
    // The part of the drawing the lens covers, in the snapshot's pixels.
    final src = Rect.fromCenter(
      center: scene * ratio,
      width: size.width / zoom * ratio,
      height: size.height / zoom * ratio,
    );
    canvas.drawRect(Offset.zero & size, Paint()..color = paper);
    final shown = src.intersect(whole);
    if (!shown.isEmpty) {
      // Only the part of the lens that is over the drawing.
      final dst = Rect.fromLTRB(
        (shown.left - src.left) / src.width * size.width,
        (shown.top - src.top) / src.height * size.height,
        (shown.right - src.left) / src.width * size.width,
        (shown.bottom - src.top) / src.height * size.height,
      );
      canvas.drawImageRect(
          image, shown, dst, Paint()..filterQuality = FilterQuality.medium);
    }

    // What moves, live and at the lens's zoom: [scene] at the lens center.
    final live = paintLive;
    if (live != null) {
      canvas.save();
      canvas.clipRect(Offset.zero & size);
      canvas.translate(
          size.width / 2 - scene.dx * zoom, size.height / 2 - scene.dy * zoom);
      canvas.scale(zoom);
      live(canvas);
      canvas.restore();
    }

    // The minimap: the whole drawing in the corner, the lens on it.
    const most = 84.0;
    final aspect = whole.width / whole.height;
    final mapSize = aspect >= 1
        ? Size(most, most / aspect)
        : Size(most * aspect, most);
    final map = Rect.fromLTWH(size.width - mapSize.width - 6,
        size.height - mapSize.height - 6, mapSize.width, mapSize.height);
    canvas.drawRect(map.inflate(2), Paint()..color = paper);
    canvas.drawImageRect(
        image, whole, map, Paint()..filterQuality = FilterQuality.low);
    canvas.drawRect(
      map.inflate(2),
      Paint()
        ..color = frame.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke,
    );
    final k = map.width / whole.width;
    canvas.drawRect(
      Rect.fromLTWH(map.left + src.left * k, map.top + src.top * k,
              src.width * k, src.height * k)
          .intersect(map),
      Paint()
        ..color = frame
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_LensPainter old) =>
      old.image != image ||
      old.scene != scene ||
      old.zoom != zoom ||
      old.ratio != ratio ||
      old.frame != frame ||
      old.paintLive != paintLive;
}
