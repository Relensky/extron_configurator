import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:printing/printing.dart';

import 'pdf_export.dart';

/// The kind of mark being drawn.
enum AnnotationTool { pen, line, arrow, rect, highlight, text }

/// One drawn mark. For [pen], [points] is the full freehand trail; for
/// line/arrow/rect/highlight it is exactly [start, end]; for [text] it is a
/// single anchor point and [text] holds the label.
class Annotation {
  final AnnotationTool tool;
  final List<Offset> points;
  final Color color;
  final double strokeWidth;
  final String? text;

  Annotation({
    required this.tool,
    required this.points,
    required this.color,
    required this.strokeWidth,
    this.text,
  });
}

/// Full-screen editor that shows a captured screenshot, lets the user mark it
/// up (pen / line / arrow / rectangle / highlight / text) and exports the
/// annotated result to a PDF (or sends it to the printer).
class ScreenshotAnnotatorView extends StatefulWidget {
  /// PNG bytes of the captured app content area.
  final Uint8List imageBytes;

  const ScreenshotAnnotatorView({Key? key, required this.imageBytes})
      : super(key: key);

  @override
  State<ScreenshotAnnotatorView> createState() =>
      _ScreenshotAnnotatorViewState();
}

class _ScreenshotAnnotatorViewState extends State<ScreenshotAnnotatorView> {
  final GlobalKey _exportKey = GlobalKey();

  final List<Annotation> _annotations = [];
  Annotation? _current; // in-progress drag

  AnnotationTool _tool = AnnotationTool.pen;
  Color _color = Colors.red;
  double _strokeWidth = 4;

  double? _imgW, _imgH; // intrinsic image size, for the aspect ratio
  bool _busy = false;

  static const List<Color> _palette = [
    Colors.red,
    Colors.orange,
    Colors.yellow,
    Colors.green,
    Colors.blue,
    Colors.black,
    Colors.white,
  ];

  @override
  void initState() {
    super.initState();
    _decodeSize();
  }

  Future<void> _decodeSize() async {
    final codec = await ui.instantiateImageCodec(widget.imageBytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() {
      _imgW = frame.image.width.toDouble();
      _imgH = frame.image.height.toDouble();
    });
  }

  // --- drawing gestures ------------------------------------------------------
  void _onPanStart(DragStartDetails d) {
    if (_tool == AnnotationTool.text) return; // text is placed via tap
    setState(() {
      _current = Annotation(
        tool: _tool,
        points: _tool == AnnotationTool.pen
            ? [d.localPosition]
            : [d.localPosition, d.localPosition],
        color: _color,
        strokeWidth: _strokeWidth,
      );
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    if (_current == null) return;
    setState(() {
      if (_current!.tool == AnnotationTool.pen) {
        _current!.points.add(d.localPosition);
      } else {
        _current!.points[1] = d.localPosition;
      }
    });
  }

  void _onPanEnd(DragEndDetails d) {
    if (_current == null) return;
    setState(() {
      _annotations.add(_current!);
      _current = null;
    });
  }

  Future<void> _onTapUp(TapUpDetails d) async {
    if (_tool != AnnotationTool.text) return;
    final text = await _promptForText();
    if (text == null || text.isEmpty) return;
    setState(() {
      _annotations.add(Annotation(
        tool: AnnotationTool.text,
        points: [d.localPosition],
        color: _color,
        strokeWidth: _strokeWidth,
        text: text,
      ));
    });
  }

  Future<String?> _promptForText() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add text label'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Label text'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('Add')),
        ],
      ),
    );
  }

  // --- export / print --------------------------------------------------------
  Future<Uint8List?> _captureAnnotatedPng() async {
    final boundary =
        _exportKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  Future<void> _exportPdf() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final png = await _captureAnnotatedPng();
      if (png == null) {
        messenger.showSnackBar(
            const SnackBar(content: Text('Could not capture the image.')));
        return;
      }
      final pdfBytes = await buildPdfFromImage(png);
      final savePath = await FilePicker.saveFile(
        dialogTitle: 'Save annotated screenshot as PDF',
        fileName: 'screenshot.pdf',
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      if (savePath == null) return; // cancelled
      final outPath =
          savePath.toLowerCase().endsWith('.pdf') ? savePath : '$savePath.pdf';
      await File(outPath).writeAsBytes(pdfBytes);
      messenger
          .showSnackBar(SnackBar(content: Text('Saved $outPath')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _printPdf() async {
    setState(() => _busy = true);
    try {
      final png = await _captureAnnotatedPng();
      if (png == null) return;
      final pdfBytes = await buildPdfFromImage(png);
      await Printing.layoutPdf(onLayout: (_) async => pdfBytes);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // --- UI --------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Annotate screenshot'),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: 'Undo',
            onPressed: _annotations.isEmpty
                ? null
                : () => setState(() => _annotations.removeLast()),
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Clear all',
            onPressed: _annotations.isEmpty
                ? null
                : () => setState(_annotations.clear),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            icon: const Icon(Icons.print),
            label: const Text('Print'),
            onPressed: _busy ? null : _printPdf,
          ),
          FilledButton.icon(
            icon: const Icon(Icons.picture_as_pdf),
            label: const Text('Export PDF'),
            onPressed: _busy ? null : _exportPdf,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          _buildToolbar(),
          const Divider(height: 1),
          Expanded(
            child: Container(
              color: Colors.grey.shade800,
              padding: const EdgeInsets.all(16),
              child: Center(
                child: _imgW == null
                    ? const CircularProgressIndicator()
                    : AspectRatio(
                        aspectRatio: _imgW! / _imgH!,
                        child: RepaintBoundary(
                          key: _exportKey,
                          child: GestureDetector(
                            onPanStart: _onPanStart,
                            onPanUpdate: _onPanUpdate,
                            onPanEnd: _onPanEnd,
                            onTapUp: _onTapUp,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Image.memory(widget.imageBytes,
                                    fit: BoxFit.fill),
                                CustomPaint(
                                  painter: _AnnotationPainter([
                                    ..._annotations,
                                    if (_current != null) _current!,
                                  ]),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            // Tools
            _toolButton(AnnotationTool.pen, Icons.gesture, 'Pen'),
            _toolButton(AnnotationTool.line, Icons.remove, 'Line'),
            _toolButton(AnnotationTool.arrow, Icons.north_east, 'Arrow'),
            _toolButton(
                AnnotationTool.rect, Icons.crop_square, 'Rectangle'),
            _toolButton(
                AnnotationTool.highlight, Icons.highlight, 'Highlight'),
            _toolButton(AnnotationTool.text, Icons.title, 'Text'),
            const SizedBox(width: 16),
            const VerticalDivider(),
            const SizedBox(width: 16),
            // Colors
            for (final c in _palette) _colorSwatch(c),
            const SizedBox(width: 16),
            const VerticalDivider(),
            const SizedBox(width: 16),
            // Stroke width
            const Icon(Icons.line_weight, size: 18),
            SizedBox(
              width: 140,
              child: Slider(
                min: 1,
                max: 16,
                value: _strokeWidth,
                label: _strokeWidth.round().toString(),
                divisions: 15,
                onChanged: (v) => setState(() => _strokeWidth = v),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolButton(AnnotationTool tool, IconData icon, String tip) {
    final selected = _tool == tool;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton.filledTonal(
        isSelected: selected,
        icon: Icon(icon),
        tooltip: tip,
        style: selected
            ? IconButton.styleFrom(
                backgroundColor:
                    Theme.of(context).colorScheme.primaryContainer)
            : null,
        onPressed: () => setState(() => _tool = tool),
      ),
    );
  }

  Widget _colorSwatch(Color c) {
    final selected = _color.toARGB32() == c.toARGB32();
    return GestureDetector(
      onTap: () => setState(() => _color = c),
      child: Container(
        width: 26,
        height: 26,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.blueAccent : Colors.grey,
            width: selected ? 3 : 1,
          ),
        ),
      ),
    );
  }
}

/// Paints every [Annotation] onto the screenshot in display coordinates.
class _AnnotationPainter extends CustomPainter {
  final List<Annotation> annotations;
  _AnnotationPainter(this.annotations);

  @override
  void paint(Canvas canvas, Size size) {
    for (final a in annotations) {
      final paint = Paint()
        ..color = a.color
        ..strokeWidth = a.strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      switch (a.tool) {
        case AnnotationTool.pen:
          if (a.points.length < 2) {
            if (a.points.isNotEmpty) {
              canvas.drawPoints(ui.PointMode.points, a.points,
                  paint..strokeCap = StrokeCap.round);
            }
            break;
          }
          final path = Path()..moveTo(a.points.first.dx, a.points.first.dy);
          for (final p in a.points.skip(1)) {
            path.lineTo(p.dx, p.dy);
          }
          canvas.drawPath(path, paint);
          break;
        case AnnotationTool.line:
          canvas.drawLine(a.points[0], a.points[1], paint);
          break;
        case AnnotationTool.arrow:
          _drawArrow(canvas, a.points[0], a.points[1], paint);
          break;
        case AnnotationTool.rect:
          canvas.drawRect(
              Rect.fromPoints(a.points[0], a.points[1]), paint);
          break;
        case AnnotationTool.highlight:
          final fill = Paint()
            ..color = a.color.withValues(alpha: 0.3)
            ..style = PaintingStyle.fill;
          canvas.drawRect(Rect.fromPoints(a.points[0], a.points[1]), fill);
          break;
        case AnnotationTool.text:
          _drawText(canvas, a);
          break;
      }
    }
  }

  void _drawArrow(Canvas canvas, Offset start, Offset end, Paint paint) {
    canvas.drawLine(start, end, paint);
    final angle = math.atan2(end.dy - start.dy, end.dx - start.dx);
    final headLen = 8 + paint.strokeWidth * 2;
    const headAngle = math.pi / 7;
    final p1 = Offset(
      end.dx - headLen * math.cos(angle - headAngle),
      end.dy - headLen * math.sin(angle - headAngle),
    );
    final p2 = Offset(
      end.dx - headLen * math.cos(angle + headAngle),
      end.dy - headLen * math.sin(angle + headAngle),
    );
    canvas.drawLine(end, p1, paint);
    canvas.drawLine(end, p2, paint);
  }

  void _drawText(Canvas canvas, Annotation a) {
    final tp = TextPainter(
      text: TextSpan(
        text: a.text ?? '',
        style: TextStyle(
          color: a.color,
          fontSize: 12 + a.strokeWidth * 2,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 400);
    tp.paint(canvas, a.points.first);
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter oldDelegate) => true;
}
