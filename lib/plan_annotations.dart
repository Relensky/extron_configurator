import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'room_locations.dart';

/// ============================================================================
///  DRAWING THE NOTATION
/// ============================================================================
///  Painting, hit-testing and handle geometry for the arrows, boxes and text on
///  a floor plan sheet. Kept apart from the page so the shape maths can be
///  checked without pumping a frame, and so the same layer can be dropped onto
///  any other canvas that grows notation later.
///
///  Everything here works in the PLAN IMAGE'S coordinates. The page draws the
///  layer at the image's natural size inside the zooming viewport, so no scale
///  factor reaches this file — which is the reason a marked-up sheet stays
///  marked up in the same places at any zoom.
/// ============================================================================

/// How close a click has to land to count as hitting a line, in plan pixels.
const double kAnnotationHitSlop = 8;

/// The square grab handles on a selected shape.
const double kAnnotationHandleSize = 9;

/// Which part of a selected annotation a drag has taken hold of.
enum AnnotationGrip { none, start, end, body }

/// Distance from [p] to the segment a–b. The whole of the line hit-tests, not
/// just its ends — an arrow is grabbed wherever it is pointed at.
double distanceToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lengthSquared == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / lengthSquared)
      .clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// True when [point] lands on [note].
///
/// A box and an ellipse are grabbed by their EDGE rather than their middle:
/// they are drawn round something, and a filled hit area would make whatever
/// is inside them — the markers and callouts the box was drawn to group —
/// unclickable.
bool annotationHit(PlanAnnotation note, Offset point) {
  switch (note.shape) {
    case PlanShape.arrow:
    case PlanShape.line:
      return distanceToSegment(point, note.start, note.end) <=
          kAnnotationHitSlop + note.strokeWidth;
    case PlanShape.text:
      return note.bounds.inflate(kAnnotationHitSlop).contains(point);
    case PlanShape.rectangle:
    case PlanShape.ellipse:
      final r = note.bounds;
      if (!r.inflate(kAnnotationHitSlop).contains(point)) return false;
      return !r.deflate(kAnnotationHitSlop).contains(point);
  }
}

/// The topmost annotation under [point], or null. Later ones are on top, so
/// the list is searched backwards — the same rule the eye uses.
PlanAnnotation? annotationAt(List<PlanAnnotation> notes, Offset point) {
  for (int i = notes.length - 1; i >= 0; i--) {
    if (annotationHit(notes[i], point)) return notes[i];
  }
  return null;
}

/// Which grip [point] has taken hold of on [note].
AnnotationGrip gripAt(PlanAnnotation note, Offset point) {
  final reach = kAnnotationHandleSize;
  if ((point - note.start).distance <= reach) return AnnotationGrip.start;
  if ((point - note.end).distance <= reach) return AnnotationGrip.end;
  return annotationHit(note, point) ? AnnotationGrip.body : AnnotationGrip.none;
}

/// Applies a drag of [delta] to whichever grip is held.
PlanAnnotation dragAnnotation(
  PlanAnnotation note,
  AnnotationGrip grip,
  Offset delta,
) => switch (grip) {
  AnnotationGrip.start => note.copyWith(start: note.start + delta),
  AnnotationGrip.end => note.copyWith(end: note.end + delta),
  AnnotationGrip.body => note.shifted(delta),
  AnnotationGrip.none => note,
};

/// Paints a sheet's notation, plus the shape being dragged out right now.
class PlanAnnotationPainter extends CustomPainter {
  final List<PlanAnnotation> notes;

  /// The shape under the pointer mid-draw, drawn like the rest so what you see
  /// while dragging is what you get when you let go.
  final PlanAnnotation? draft;

  final String selectedId;

  const PlanAnnotationPainter({
    required this.notes,
    this.draft,
    this.selectedId = '',
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final note in notes) {
      _paintOne(canvas, note, selected: note.id == selectedId);
    }
    if (draft != null) _paintOne(canvas, draft!, selected: false);
  }

  void _paintOne(Canvas canvas, PlanAnnotation note, {required bool selected}) {
    final color = Color(note.color);
    final stroke = Paint()
      ..color = color
      ..strokeWidth = note.strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    switch (note.shape) {
      case PlanShape.arrow:
        canvas.drawLine(note.start, note.end, stroke);
        _paintArrowHead(canvas, note, color);
      case PlanShape.line:
        canvas.drawLine(note.start, note.end, stroke);
      case PlanShape.rectangle:
        canvas.drawRect(note.bounds, stroke);
      case PlanShape.ellipse:
        canvas.drawOval(note.bounds, stroke);
      case PlanShape.text:
        break;
    }

    if (note.text.trim().isNotEmpty) _paintText(canvas, note, color);
    if (selected) _paintSelection(canvas, note);
  }

  void _paintArrowHead(Canvas canvas, PlanAnnotation note, Color color) {
    final v = note.end - note.start;
    if (v.distance < 0.5) return;
    final angle = math.atan2(v.dy, v.dx);
    // Scaled off the stroke so a heavy arrow gets a head to match rather than
    // a thick shaft with a pinhead on the end of it.
    final len = math.max(12.0, note.strokeWidth * 4);
    const spread = 0.42;
    final path = Path()
      ..moveTo(note.end.dx, note.end.dy)
      ..lineTo(
        note.end.dx - len * math.cos(angle - spread),
        note.end.dy - len * math.sin(angle - spread),
      )
      ..lineTo(
        note.end.dx - len * math.cos(angle + spread),
        note.end.dy - len * math.sin(angle + spread),
      )
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _paintText(Canvas canvas, PlanAnnotation note, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: note.text,
        style: TextStyle(
          color: color,
          fontSize: math.max(11.0, note.strokeWidth * 4.5),
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
    );
    // A text block wraps to the box it was dragged out; a label on a line or a
    // box gets as much room as it needs on one run.
    final r = note.bounds;
    painter.layout(
      maxWidth: note.shape == PlanShape.text && r.width > 20
          ? r.width
          : double.infinity,
    );

    final Offset at;
    switch (note.shape) {
      case PlanShape.text:
        at = r.topLeft;
      case PlanShape.rectangle:
      case PlanShape.ellipse:
        // Sat on the top edge, out of the way of whatever is ringed.
        at = Offset(r.left, r.top - painter.height - 4);
      case PlanShape.arrow:
      case PlanShape.line:
        // Beside the middle of the run, lifted clear of the stroke.
        final mid = (note.start + note.end) / 2;
        at = Offset(mid.dx + 6, mid.dy - painter.height - 4);
    }

    // A pad behind it, because a red note over a black drawing is otherwise
    // unreadable exactly where the drawing is busiest.
    final box = Rect.fromLTWH(at.dx, at.dy, painter.width, painter.height)
        .inflate(3);
    canvas.drawRRect(
      RRect.fromRectAndRadius(box, const Radius.circular(3)),
      Paint()..color = const Color(0xE6FFFFFF),
    );
    painter.paint(canvas, at);
  }

  void _paintSelection(Canvas canvas, PlanAnnotation note) {
    final marker = Paint()
      ..color = const Color(0xFF1E88E5)
      ..style = PaintingStyle.fill;
    final outline = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    for (final p in [note.start, note.end]) {
      final r = Rect.fromCenter(
        center: p,
        width: kAnnotationHandleSize,
        height: kAnnotationHandleSize,
      );
      canvas.drawRect(r, marker);
      canvas.drawRect(r, outline);
    }

    if (note.shape == PlanShape.rectangle ||
        note.shape == PlanShape.ellipse ||
        note.shape == PlanShape.text) {
      canvas.drawRect(
        note.bounds.inflate(2),
        Paint()
          ..color = const Color(0x661E88E5)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(PlanAnnotationPainter old) =>
      old.notes != notes ||
      old.draft != draft ||
      old.selectedId != selectedId;
}
