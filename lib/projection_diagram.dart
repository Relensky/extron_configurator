import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'projection_calc.dart';

/// ============================================================================
///  PROJECTION DIAGRAM
/// ============================================================================
///  The calculator's answer drawn to scale: a side view of the wall, screen,
///  projector and beam, and a top view of the beam spreading to the image.
///  Lengths are in feet.
/// ============================================================================

/// What the diagram draws.
class ProjectionLayout {
  final ImageSize image;

  /// Lens to screen at the chosen zoom.
  final double distance;

  /// The zoom's shortest and longest throw for this image; equal for a
  /// fixed lens.
  final double minDistance;
  final double maxDistance;

  /// Image bottom off the floor.
  final double bottom;

  /// The heights the lens can sit at with its lens shift.
  final double lensLow;
  final double lensHigh;

  final double ceiling;

  /// How far the lens can sit to either side of the image center.
  final double sideReach;

  const ProjectionLayout({
    required this.image,
    required this.distance,
    required this.minDistance,
    required this.maxDistance,
    required this.bottom,
    required this.lensLow,
    required this.lensHigh,
    required this.ceiling,
    this.sideReach = 0,
  });

  /// Where the lens is drawn: as high as the shift allows, under the ceiling.
  double get lensHeight {
    final top = math.min(lensHigh, ceiling - 0.5);
    return top < lensLow ? lensLow : top;
  }
}

/// Side and top views, one above the other.
class ProjectionDiagram extends StatelessWidget {
  final ProjectionLayout layout;
  const ProjectionDiagram({super.key, required this.layout});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = _DiagramColors(
      ink: theme.colorScheme.onSurface,
      faint: theme.colorScheme.outlineVariant,
      beam: const Color(0xFFFFA000),
      screen: theme.colorScheme.primary,
      lens: const Color(0xFF2E7D32),
      paper: theme.colorScheme.surfaceContainerHighest,
    );
    Widget view(String title, CustomPainter painter, double height) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: CustomPaint(painter: painter),
          ),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        view('Side view', _SideView(layout, colors), 230),
        const SizedBox(height: 12),
        view('Top view', _TopView(layout, colors), 170),
      ],
    );
  }
}

class _DiagramColors {
  final Color ink, faint, beam, screen, lens, paper;
  const _DiagramColors({
    required this.ink,
    required this.faint,
    required this.beam,
    required this.screen,
    required this.lens,
    required this.paper,
  });
}

String _ft(double feet) => formatFeetInches(feet);

void _text(
  Canvas canvas,
  String s,
  Offset at,
  Color color, {
  bool center = true,
  double size = 11,
}) {
  final p = TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(fontSize: size, color: color),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  p.paint(canvas, center ? at - Offset(p.width / 2, p.height / 2) : at);
}

/// A dimension line with ticks at both ends and its length in the middle.
void _dimension(
  Canvas canvas,
  Offset a,
  Offset b,
  String label,
  Color color, {
  Offset labelNudge = Offset.zero,
}) {
  final ink = Paint()
    ..color = color
    ..strokeWidth = 1;
  canvas.drawLine(a, b, ink);
  final d = b - a;
  final len = d.distance;
  if (len < 1) return;
  final across = Offset(-d.dy, d.dx) / len * 4;
  canvas.drawLine(a - across, a + across, ink);
  canvas.drawLine(b - across, b + across, ink);
  _text(canvas, label, Offset.lerp(a, b, 0.5)! + labelNudge, color);
}

void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
  final d = b - a;
  final len = d.distance;
  if (len < 1) return;
  final step = d / len;
  for (var t = 0.0; t < len; t += 8) {
    canvas.drawLine(a + step * t, a + step * math.min(t + 4, len), paint);
  }
}

class _SideView extends CustomPainter {
  final ProjectionLayout l;
  final _DiagramColors c;
  const _SideView(this.l, this.c);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = c.paper);
    const left = 76.0, right = 40.0, top = 18.0, bottom = 34.0;
    final room = math.max(l.maxDistance, l.distance) * 1.08 + 1;
    final tall = math.max(l.ceiling, l.bottom + l.image.height + 0.5);
    final scale = math.min(
      (size.width - left - right) / room,
      (size.height - top - bottom) / tall,
    );
    final floorY = top + tall * scale;
    Offset at(double x, double y) => Offset(left + x * scale, floorY - y * scale);

    final line = Paint()
      ..color = c.ink
      ..strokeWidth = 1.5;
    final faint = Paint()
      ..color = c.faint
      ..strokeWidth = 1;
    // Floor, wall and ceiling.
    canvas.drawLine(at(0, 0), at(room, 0), line);
    canvas.drawLine(at(0, 0), at(0, tall), line);
    _dashed(canvas, at(0, l.ceiling), at(room, l.ceiling), faint);
    _text(canvas, 'Ceiling ${_ft(l.ceiling)}', at(0, l.ceiling) + const Offset(40, -8), c.ink, size: 10);

    // The screen on the wall.
    final screenTop = l.bottom + l.image.height;
    canvas.drawLine(
      at(0, l.bottom),
      at(0, screenTop),
      Paint()
        ..color = c.screen
        ..strokeWidth = 5,
    );
    _dimension(canvas, at(0, l.bottom) - const Offset(30, 0),
        at(0, screenTop) - const Offset(30, 0), '', c.ink);
    _text(canvas, _ft(l.image.height),
        Offset.lerp(at(0, l.bottom), at(0, screenTop), 0.5)! - const Offset(44, 0),
        c.ink, size: 10);
    if (l.bottom > 0.3) {
      _dimension(canvas, at(0, 0) + const Offset(10, 0),
          at(0, l.bottom) + const Offset(10, 0), '', c.faint);
      _text(canvas, _ft(l.bottom),
          Offset.lerp(at(0, 0), at(0, l.bottom), 0.5)! + const Offset(30, 0),
          c.ink, size: 10);
    }

    // The zoom's range along the floor.
    if (l.maxDistance > l.minDistance + 0.05) {
      final band = Rect.fromPoints(
        at(l.minDistance, 0) - const Offset(0, 6),
        at(l.maxDistance, 0),
      );
      canvas.drawRect(band, Paint()..color = c.beam.withValues(alpha: 0.45));
      _text(canvas, 'Zoom ${_ft(l.minDistance)} - ${_ft(l.maxDistance)}',
          band.topCenter - const Offset(0, 9), c.ink, size: 10);
    }

    // Where the lens can sit, from the lens shift.
    final lensX = l.distance;
    if (l.lensHigh - l.lensLow > 0.05) {
      canvas.drawLine(
        at(lensX, l.lensLow),
        at(lensX, math.min(l.lensHigh, tall)),
        Paint()
          ..color = c.lens.withValues(alpha: 0.6)
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round,
      );
    }

    // The beam.
    final lens = at(lensX, l.lensHeight);
    canvas.drawPath(
      Path()
        ..moveTo(lens.dx, lens.dy)
        ..lineTo(at(0, screenTop).dx, at(0, screenTop).dy)
        ..lineTo(at(0, l.bottom).dx, at(0, l.bottom).dy)
        ..close(),
      Paint()..color = c.beam.withValues(alpha: 0.25),
    );
    final edge = Paint()
      ..color = c.beam
      ..strokeWidth = 1.2;
    canvas.drawLine(lens, at(0, screenTop), edge);
    canvas.drawLine(lens, at(0, l.bottom), edge);

    // The projector.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: lens + const Offset(14, 0), width: 30, height: 14),
        const Radius.circular(3),
      ),
      Paint()..color = c.ink,
    );
    canvas.drawCircle(lens, 3.5, Paint()..color = c.beam);
    _text(canvas, 'Lens ${_ft(l.lensHeight)}', lens + const Offset(16, 16), c.ink, size: 10);

    // Throw distance along the bottom.
    _dimension(canvas, at(0, 0) + const Offset(0, 18), at(lensX, 0) + const Offset(0, 18), '', c.ink);
    _text(canvas, 'Throw ${_ft(l.distance)}',
        Offset.lerp(at(0, 0), at(lensX, 0), 0.5)! + const Offset(0, 26) ,
        c.ink);
  }

  @override
  bool shouldRepaint(_SideView old) => old.l != l;
}

class _TopView extends CustomPainter {
  final ProjectionLayout l;
  final _DiagramColors c;
  const _TopView(this.l, this.c);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = c.paper);
    const left = 76.0, right = 40.0, pad = 20.0;
    final room = math.max(l.maxDistance, l.distance) * 1.08 + 1;
    final across = math.max(l.image.width, l.sideReach * 2) + 1;
    final scale = math.min(
      (size.width - left - right) / room,
      (size.height - pad * 2) / across,
    );
    final midY = size.height / 2;
    Offset at(double x, double y) => Offset(left + x * scale, midY + y * scale);
    final half = l.image.width / 2;

    // The wall and the screen on it.
    canvas.drawLine(
      Offset(left, pad / 2),
      Offset(left, size.height - pad / 2),
      Paint()
        ..color = c.ink
        ..strokeWidth = 1.5,
    );
    canvas.drawLine(
      at(0, -half),
      at(0, half),
      Paint()
        ..color = c.screen
        ..strokeWidth = 5,
    );
    _text(canvas, _ft(l.image.width), at(0, 0) - const Offset(30, 0), c.ink, size: 10);

    // Sideways lens shift.
    if (l.sideReach > 0.05) {
      canvas.drawLine(
        at(l.distance, -l.sideReach),
        at(l.distance, l.sideReach),
        Paint()
          ..color = c.lens.withValues(alpha: 0.6)
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round,
      );
    }

    final lens = at(l.distance, 0);
    canvas.drawPath(
      Path()
        ..moveTo(lens.dx, lens.dy)
        ..lineTo(at(0, -half).dx, at(0, -half).dy)
        ..lineTo(at(0, half).dx, at(0, half).dy)
        ..close(),
      Paint()..color = c.beam.withValues(alpha: 0.25),
    );
    final edge = Paint()
      ..color = c.beam
      ..strokeWidth = 1.2;
    canvas.drawLine(lens, at(0, -half), edge);
    canvas.drawLine(lens, at(0, half), edge);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: lens + const Offset(14, 0), width: 30, height: 22),
        const Radius.circular(3),
      ),
      Paint()..color = c.ink,
    );
    canvas.drawCircle(lens, 3.5, Paint()..color = c.beam);
    _dashed(canvas, at(0, 0), lens, Paint()..color = c.faint);
  }

  @override
  bool shouldRepaint(_TopView old) => old.l != l;
}
