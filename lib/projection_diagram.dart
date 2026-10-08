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

  /// The units the throw side and the image are labeled in.
  final LengthUnit distanceUnit;
  final LengthUnit sizeUnit;

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
    this.distanceUnit = LengthUnit.feet,
    this.sizeUnit = LengthUnit.feet,
  });

  /// A throw-side length, labeled.
  String len(double feet) => formatLength(feet, distanceUnit);

  /// An image dimension, labeled.
  String sz(double feet) => formatLength(feet, sizeUnit);

  /// Where the lens is drawn: as high as the shift allows, under the ceiling.
  double get lensHeight {
    final top = math.min(lensHigh, ceiling - 0.5);
    return top < lensLow ? lensLow : top;
  }
}

/// A perspective view of the projector and screen, then side and top views.
/// With [onDistanceChanged], the projector can be dragged in the perspective
/// view to change the throw.
class ProjectionDiagram extends StatefulWidget {
  final ProjectionLayout layout;
  final ValueChanged<double>? onDistanceChanged;
  const ProjectionDiagram({
    super.key,
    required this.layout,
    this.onDistanceChanged,
  });

  @override
  State<ProjectionDiagram> createState() => _ProjectionDiagramState();
}

class _ProjectionDiagramState extends State<ProjectionDiagram> {
  /// The feet across the perspective view, held while dragging so the
  /// projector tracks the pointer as the image resizes.
  double? _room;

  @override
  Widget build(BuildContext context) {
    final layout = widget.layout;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final colors = _DiagramColors(
      ink: theme.colorScheme.onSurface,
      faint: theme.colorScheme.outlineVariant,
      beam: const Color(0xFFFFA000),
      screen: theme.colorScheme.primary,
      lens: dark ? const Color(0xFF81C784) : const Color(0xFF2E7D32),
      paper: theme.colorScheme.surfaceContainerHighest,
      accent: dark ? const Color(0xFF64B5F6) : const Color(0xFF2E86C8),
      body: dark ? const Color(0xFF9E9E9E) : const Color(0xFF555555),
      face: dark ? const Color(0xFF2A2D31) : Colors.white,
    );
    final drag = widget.onDistanceChanged;
    final perspective = SizedBox(
      key: const ValueKey('projection_perspective'),
      height: 250,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, box) {
          final paint = CustomPaint(
            painter: _PerspectiveView(layout, colors, _room),
          );
          if (drag == null) return paint;
          final f = _PerspectiveFrame(layout, Size(box.maxWidth, 250), _room);
          void move(Offset p) => drag(f.distanceAt(p.dx));
          return MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            child: GestureDetector(
              onTapDown: (d) => move(d.localPosition),
              onHorizontalDragStart: (_) => setState(() => _room = f.room),
              onHorizontalDragUpdate: (d) => move(d.localPosition),
              onHorizontalDragEnd: (_) => setState(() => _room = null),
              onHorizontalDragCancel: () => setState(() => _room = null),
              child: paint,
            ),
          );
        },
      ),
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
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: ColoredBox(color: colors.face, child: perspective),
        ),
        if (drag != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Drag the projector to change the throw.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: 12),
        view('Side view', _SideView(layout, colors), 230),
        const SizedBox(height: 12),
        view('Top view', _TopView(layout, colors), 170),
      ],
    );
  }
}

class _DiagramColors {
  final Color ink, faint, beam, screen, lens, paper;

  /// Dimension figures, projector body and the screen face in perspective.
  final Color accent, body, face;
  const _DiagramColors({
    required this.ink,
    required this.faint,
    required this.beam,
    required this.screen,
    required this.lens,
    required this.paper,
    required this.accent,
    required this.body,
    required this.face,
  });
}


void _text(
  Canvas canvas,
  String s,
  Offset at,
  Color color, {
  bool center = true,
  double size = 11,
  bool bold = false,
}) {
  final p = TextPainter(
    text: TextSpan(
      text: s,
      style: TextStyle(
        fontSize: size,
        color: color,
        fontWeight: bold ? FontWeight.w700 : null,
      ),
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
    _text(canvas, 'Ceiling ${l.len(l.ceiling)}', at(0, l.ceiling) + const Offset(40, -8), c.ink, size: 10);

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
    _text(canvas, l.sz(l.image.height),
        Offset.lerp(at(0, l.bottom), at(0, screenTop), 0.5)! - const Offset(44, 0),
        c.ink, size: 10);
    if (l.bottom > 0.3) {
      _dimension(canvas, at(0, 0) + const Offset(10, 0),
          at(0, l.bottom) + const Offset(10, 0), '', c.faint);
      _text(canvas, l.len(l.bottom),
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
      _text(canvas, 'Zoom ${l.len(l.minDistance)} - ${l.len(l.maxDistance)}',
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
    _text(canvas, 'Lens ${l.len(l.lensHeight)}', lens + const Offset(16, 16), c.ink, size: 10);

    // Throw distance along the bottom.
    _dimension(canvas, at(0, 0) + const Offset(0, 18), at(lensX, 0) + const Offset(0, 18), '', c.ink);
    _text(canvas, 'Throw ${l.len(l.distance)}',
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
    _text(canvas, l.sz(l.image.width), at(0, 0) - const Offset(30, 0), c.ink, size: 10);

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

/// Where things sit in the perspective view: the screen fixed at the right,
/// the projector sliding along the throw line to its left.
class _PerspectiveFrame {
  final ProjectionLayout l;
  final Size size;
  final double? fixedRoom;
  _PerspectiveFrame(this.l, this.size, [this.fixedRoom]);

  /// The screen grows with the image, gently: about 80px plus 0.16px per
  /// inch of diagonal, the way the spec sites draw it. 1.0 at 250".
  double get grow =>
      ((80 + 0.16 * l.image.diagonal * 12) / 120).clamp(0.5, 1.35).toDouble();

  /// Half heights of the screen's near (left) and far (right) edges.
  double get nearHalf => 41 * grow;
  double get farHalf => 55 * grow;
  double get centerY => 112;
  double get depth =>
      (farHalf * 2 * l.image.width / l.image.height * 0.55).clamp(70.0, 150.0);
  double get farX => size.width - 80;
  double get nearX => farX - depth;

  /// Lens x at zero throw, and the run of the line to the left edge.
  double get zeroX => nearX - 24;
  double get span => math.max(40, zeroX - 80);
  double get room =>
      fixedRoom ?? math.max(l.maxDistance, l.distance) * 1.15 + 1;

  double lensX(double distance) => zeroX - distance / room * span;

  double distanceAt(double x) =>
      ((zeroX - x) / span * room).clamp(0.5, room).toDouble();

  /// Feet to pixels up and down, at the middle of the screen.
  double get perFoot => (nearHalf + farHalf) / l.image.height;

  double get imageCenter => l.bottom + l.image.height / 2;

  double get lensY => (centerY - (l.lensHeight - imageCenter) * perFoot)
      .clamp(18.0, size.height - 46);
}

class _PerspectiveView extends CustomPainter {
  final ProjectionLayout l;
  final _DiagramColors c;
  final double? room;
  const _PerspectiveView(this.l, this.c, this.room);

  void _projector(
    Canvas canvas,
    Offset lens,
    Paint fill, {
    required bool hung,
    Paint? barrel,
  }) {
    final body = RRect.fromRectAndRadius(
      Rect.fromLTRB(lens.dx - 64, lens.dy - 11, lens.dx - 6, lens.dy + 11),
      const Radius.circular(2),
    );
    canvas.drawRRect(body, fill);
    if (barrel != null) {
      canvas.drawRect(
        Rect.fromLTRB(lens.dx - 7, lens.dy - 7, lens.dx, lens.dy + 7),
        barrel,
      );
      // Feet, or a ceiling mount when the lens sits above the image.
      final feetY = hung ? lens.dy - 14 : lens.dy + 11;
      for (final x in [lens.dx - 58, lens.dx - 18]) {
        canvas.drawRect(Rect.fromLTWH(x, feetY, 6, 3), barrel);
      }
      if (hung) {
        canvas.drawLine(
          Offset(lens.dx - 35, lens.dy - 14),
          Offset(lens.dx - 35, 0),
          barrel..strokeWidth = 3,
        );
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final f = _PerspectiveFrame(l, size, room);
    final cy = f.centerY;
    final x1 = f.nearX, x2 = f.farX;
    final n = f.nearHalf, fr = f.farHalf;
    final tl = Offset(x1, cy - n), bl = Offset(x1, cy + n);
    final tr = Offset(x2, cy - fr), br = Offset(x2, cy + fr);
    final lensY = f.lensY;
    final lens = Offset(f.lensX(l.distance), lensY);
    final hung = l.lensHeight > f.imageCenter + 0.25;
    final dash = Paint()
      ..color = c.faint
      ..strokeWidth = 1.5;

    // The zoom's reach along the throw line, with the projector outlined at
    // each end.
    if (l.maxDistance > l.minDistance + 0.05) {
      final a = Offset(f.lensX(l.maxDistance), lensY);
      final b = Offset(f.lensX(l.minDistance), lensY);
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = c.accent.withValues(alpha: 0.3)
          ..strokeWidth = 6
          ..strokeCap = StrokeCap.round,
      );
      final outline = Paint()
        ..color = c.faint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      for (final (p, label) in [(a, 'Telephoto'), (b, 'Wide')]) {
        if ((p.dx - lens.dx).abs() < 70) continue;
        _projector(canvas, p, outline, hung: hung);
        _text(canvas, label, p + const Offset(-35, -22), c.ink.withValues(alpha: 0.6), size: 9);
      }
    }

    // Throw line from the lens to the screen.
    final mid = Offset((x1 + x2) / 2, lensY);
    _dashed(canvas, lens, mid, dash);

    // The screen, angled away.
    final face = Path()
      ..moveTo(tl.dx, tl.dy)
      ..lineTo(tr.dx, tr.dy)
      ..lineTo(br.dx, br.dy)
      ..lineTo(bl.dx, bl.dy)
      ..close();
    canvas.drawPath(face, Paint()..color = c.face);
    canvas.drawPath(
      face,
      Paint()
        ..color = c.ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // Where the lens line meets the screen plane, and how far that is from
    // the image's bottom edge.
    final bottomMid = Offset(mid.dx, cy + (n + fr) / 2);
    final cross = Paint()
      ..color = c.faint
      ..strokeWidth = 1.5;
    canvas.drawLine(mid - const Offset(5, 0), mid + const Offset(5, 0), cross);
    canvas.drawLine(mid - const Offset(0, 5), mid + const Offset(0, 5), cross);
    _dashed(canvas, mid, bottomMid, dash);
    final offset = l.bottom - l.lensHeight;
    _text(
      canvas,
      '${offset < 0 ? '-' : '+'} ${l.len(offset.abs())}',
      Offset(mid.dx, math.max(bottomMid.dy, lensY) + 14),
      c.accent,
      bold: true,
    );

    // Width along the top, height down the right, diagonal off the corner.
    const lift = Offset(0, -12);
    _dashed(canvas, tl + lift, tr + lift, dash);
    for (final p in [tl, tr]) {
      canvas.drawLine(p + lift - const Offset(0, 4), p + lift + const Offset(0, 4), dash);
    }
    _text(canvas, l.sz(l.image.width), Offset.lerp(tl, tr, 0.5)! + const Offset(0, -26),
        c.accent, bold: true);
    final side = Offset(x2 + 12, 0);
    _dashed(canvas, tr + side, br + side, dash);
    _text(canvas, l.sz(l.image.height), Offset(x2 + 18, cy - 7), c.accent,
        center: false, bold: true);
    _dashed(canvas, tr + const Offset(4, -4), tr + const Offset(18, -18), dash);
    _text(canvas, '${l.sz(l.image.diagonal)} diag', tr + const Offset(20, -30),
        c.accent, center: false, bold: true);

    // The projector, with its throw beneath.
    _projector(
      canvas,
      lens,
      Paint()..color = c.body,
      hung: hung,
      barrel: Paint()..color = c.ink,
    );
    final labelY = hung ? lensY + 22 : lensY + 30;
    _text(canvas, 'Throw distance', Offset(lens.dx - 35, labelY), c.ink, bold: true, size: 12);
    _text(canvas, l.len(l.distance), Offset(lens.dx - 35, labelY + 16), c.accent, bold: true);
  }

  @override
  bool shouldRepaint(_PerspectiveView old) => true;
}
