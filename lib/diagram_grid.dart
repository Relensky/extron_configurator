import 'package:flutter/material.dart';

import 'layout_tools.dart';
import 'screenshot_tools.dart';

/// ============================================================================
///  THE ALIGNMENT GRID
/// ============================================================================
///  Snapping puts a dragged box on the grid; this is what lets somebody SEE
///  the grid it is going onto. Without it a snap is a box that jumps a few
///  pixels for no visible reason, and there is no way to tell by eye whether
///  two boxes on different parts of the sheet are on the same line.
///
///  It is drawn for the person arranging the drawing and for nobody else. A
///  sheet issued to a contractor with graph paper behind it looks like a
///  draft, so the grid takes itself off the page while a picture is being
///  taken — see [capturingDiagram], which every export comes through.
/// ============================================================================

/// A faint square grid, painted behind a diagram's contents.
///
/// Wrap it in a [Positioned.fill] inside the canvas [Stack] so it covers the
/// whole sheet and sits under everything drawn on it.
class DiagramGrid extends StatelessWidget {
  final double step;

  const DiagramGrid({super.key, this.step = kDiagramGridStep});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: ValueListenableBuilder<bool>(
        valueListenable: capturingDiagram,
        builder: (context, capturing, _) => capturing
            ? const SizedBox.shrink()
            : CustomPaint(
                size: Size.infinite,
                painter: _GridPainter(
                  step: step,
                  // Faint enough to read the drawing straight through, and a
                  // touch stronger every fifth line so the eye has something
                  // to count in without the sheet turning into graph paper.
                  line: dark ? const Color(0x14FFFFFF) : const Color(0x11000000),
                  major:
                      dark ? const Color(0x26FFFFFF) : const Color(0x1F000000),
                ),
              ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  final double step;
  final Color line;
  final Color major;

  /// Every fifth line is the stronger one — 100px at the default step, which
  /// is the distance the eye can actually judge across a wide sheet.
  static const int _majorEvery = 5;

  const _GridPainter({
    required this.step,
    required this.line,
    required this.major,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (step <= 0 || !size.width.isFinite || !size.height.isFinite) return;
    // A canvas dragged out to something absurd would otherwise be thousands of
    // lines per frame. Past this the grid stops being drawn rather than
    // stalling the repaint — the snapping still works.
    if (size.width / step + size.height / step > 4000) return;

    final thin = Paint()
      ..color = line
      ..strokeWidth = 1;
    final thick = Paint()
      ..color = major
      ..strokeWidth = 1;

    int i = 0;
    for (double x = 0; x <= size.width; x += step, i++) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        i % _majorEvery == 0 ? thick : thin,
      );
    }
    i = 0;
    for (double y = 0; y <= size.height; y += step, i++) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        i % _majorEvery == 0 ? thick : thin,
      );
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.step != step || old.line != line || old.major != major;
}
