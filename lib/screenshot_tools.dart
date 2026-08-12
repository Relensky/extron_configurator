import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';

// ============================================================================
// [FEATURE - SCREENSHOTS + ANNOTATION]
// Shared screenshot tooling for every view in the app:
//   * captureBoundary()      - renders a RepaintBoundary (by GlobalKey) to PNG
//                              bytes, including content that is scrolled out
//                              of view inside a SingleChildScrollView.
//   * showAnnotationEditor() - full annotation editor (pen, highlighter,
//                              arrow, rectangle, text) over the captured
//                              image, with undo/clear and Save-as-PNG.
// ============================================================================

/// Renders the RepaintBoundary identified by [boundaryKey] into PNG bytes.
/// Returns null when the boundary isn't mounted or the capture fails.
Future<Uint8List?> captureBoundary(GlobalKey boundaryKey,
    {double pixelRatio = 2.0}) async {
  try {
    final ctx = boundaryKey.currentContext;
    if (ctx == null) return null;
    final boundary = ctx.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;

    final ui.Image image = await boundary.toImage(pixelRatio: pixelRatio);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

/// Wraps a drawing so it renders the way it should PRINT: light theme,
/// no colour.
///
/// A cabling sheet is a working document. It gets printed, photocopied, marked
/// up on a clipboard and faxed back, and none of that survives a drawing whose
/// only distinction between six Cat 6a and five Cat 5e is that one line is
/// blue. Forcing the light theme as well as dropping the colour matters
/// separately: a dark-mode capture converted to grey is a black page with pale
/// lines on it, which a printer renders as a black page.
///
/// This is why the runs carry a dash pattern as well as a colour — see
/// `run_painting.dart`. Take the colour away and the pattern is what is left.
///
/// [enabled] false returns [child] untouched, so the normal on-screen path
/// costs nothing.
Widget printSkin({required bool enabled, required Widget child}) {
  if (!enabled) return child;
  return Theme(
    // The drawings ask the theme whether they are in dark mode and pick their
    // label and backing-plate colours off the answer.
    data: ThemeData(brightness: Brightness.light, useMaterial3: true),
    child: ColorFiltered(colorFilter: kGreyscaleFilter, child: child),
  );
}

/// Rec. 709 luminance — the same weighting a printer's own colour conversion
/// uses, so what comes out of the app matches what comes out of the printer.
const ColorFilter kGreyscaleFilter = ColorFilter.matrix(<double>[
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// Captures [boundaryKey] and opens the annotation editor over the result.
/// Shows a snackbar when the capture fails.
Future<void> captureAndAnnotate(BuildContext context, GlobalKey boundaryKey,
    {String defaultFileName = 'screenshot.png',
    double pixelRatio = 2.0}) async {
  final bytes = await captureBoundary(boundaryKey, pixelRatio: pixelRatio);
  if (bytes == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Screenshot capture failed.')));
    }
    return;
  }
  if (!context.mounted) return;
  await showAnnotationEditor(context, bytes, defaultFileName: defaultFileName);
}

/// Opens the annotation editor dialog over [pngBytes].
Future<void> showAnnotationEditor(BuildContext context, Uint8List pngBytes,
    {String defaultFileName = 'screenshot.png'}) async {
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => Dialog(
      insetPadding: const EdgeInsets.all(24.0),
      child: AnnotationEditor(
        pngBytes: pngBytes,
        defaultFileName: defaultFileName,
      ),
    ),
  );
}

enum AnnotationTool { pen, highlighter, arrow, rect, text }

class _Annotation {
  final AnnotationTool tool;
  final Color color;
  final double strokeWidth;
  final List<Offset> points; // In IMAGE pixel coordinates.
  final String? text;

  _Annotation({
    required this.tool,
    required this.color,
    required this.strokeWidth,
    required this.points,
    this.text,
  });
}

class AnnotationEditor extends StatefulWidget {
  final Uint8List pngBytes;
  final String defaultFileName;

  const AnnotationEditor({
    super.key,
    required this.pngBytes,
    required this.defaultFileName,
  });

  @override
  State<AnnotationEditor> createState() => _AnnotationEditorState();
}

class _AnnotationEditorState extends State<AnnotationEditor> {
  ui.Image? _image;
  final List<_Annotation> _annotations = [];
  _Annotation? _active; // The annotation being drawn right now.

  AnnotationTool _tool = AnnotationTool.pen;
  Color _color = Colors.red;
  double _strokeWidth = 6.0;
  bool _saving = false;

  static const List<Color> _palette = [
    Colors.red,
    Colors.orange,
    Colors.yellow,
    Colors.green,
    Colors.blue,
    Colors.purple,
    Colors.black,
    Colors.white,
  ];

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  Future<void> _decodeImage() async {
    final codec = await ui.instantiateImageCodec(widget.pngBytes);
    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() => _image = frame.image);
    } else {
      frame.image.dispose();
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  // --------------------------------------------------------------------------
  // Gestures — local positions are divided by the display scale so every
  // annotation is stored in image-pixel coordinates (resolution independent).
  // --------------------------------------------------------------------------

  void _onPanStart(Offset imagePos) {
    if (_tool == AnnotationTool.text) return;
    setState(() {
      _active = _Annotation(
        tool: _tool,
        color: _color,
        strokeWidth: _strokeWidth,
        points: [imagePos, imagePos],
      );
    });
  }

  void _onPanUpdate(Offset imagePos) {
    final active = _active;
    if (active == null) return;
    setState(() {
      if (active.tool == AnnotationTool.pen ||
          active.tool == AnnotationTool.highlighter) {
        active.points.add(imagePos);
      } else {
        // Arrow / rectangle: only the end point moves.
        active.points[active.points.length - 1] = imagePos;
      }
    });
  }

  void _onPanEnd() {
    if (_active == null) return;
    setState(() {
      _annotations.add(_active!);
      _active = null;
    });
  }

  Future<void> _onTapForText(Offset imagePos) async {
    if (_tool != AnnotationTool.text) return;
    final controller = TextEditingController();
    final String? text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Text'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: 'Annotation text', border: OutlineInputBorder()),
          onSubmitted: (val) => Navigator.of(context).pop(val),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Add')),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    setState(() {
      _annotations.add(_Annotation(
        tool: AnnotationTool.text,
        color: _color,
        strokeWidth: _strokeWidth,
        points: [imagePos],
        text: text.trim(),
      ));
    });
  }

  // --------------------------------------------------------------------------
  // Save — composes the original image + annotations at full resolution.
  // --------------------------------------------------------------------------

  Future<void> _save() async {
    final image = _image;
    if (image == null || _saving) return;
    // Taken before anything is popped: the "saved" bar outlives this dialog,
    // so it cannot be built from a BuildContext that has gone with it.
    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    setState(() => _saving = true);

    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImage(image, Offset.zero, Paint());
      _paintAnnotationsOnCanvas(canvas, _annotations, null);
      final picture = recorder.endRecording();
      final ui.Image outImage =
          await picture.toImage(image.width, image.height);
      final byteData =
          await outImage.toByteData(format: ui.ImageByteFormat.png);
      outImage.dispose();
      if (byteData == null) throw Exception('PNG encode failed');

      String? outputFile = await FilePicker.saveFile(
        dialogTitle: 'Save Screenshot',
        fileName: widget.defaultFileName,
        type: FileType.custom,
        allowedExtensions: ['png'],
      );
      if (outputFile == null) return;
      if (!outputFile.toLowerCase().endsWith('.png')) outputFile += '.png';
      await File(outputFile).writeAsBytes(byteData.buffer.asUint8List());

      final saved = outputFile;
      if (mounted) Navigator.of(context).pop();
      showSavedSnackBar(
        messenger: messenger,
        theme: theme,
        provider: provider,
        message: 'Screenshot saved as ${p.basename(saved)}',
        savedPath: saved,
      );
    } catch (e) {
      showTimedSnackBar(
        messenger,
        SnackBar(content: Text('Failed to save screenshot: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // --------------------------------------------------------------------------
  // UI
  // --------------------------------------------------------------------------

  Widget _toolButton(AnnotationTool tool, IconData icon, String tooltip) {
    final bool selected = _tool == tool;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.0),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _tool = tool),
          child: Container(
            padding: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon,
                size: 20,
                color: selected
                    ? Theme.of(context).colorScheme.onPrimaryContainer
                    : null),
          ),
        ),
      ),
    );
  }

  Widget _colorSwatch(Color color) {
    final bool selected = _color == color;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.0),
      child: InkWell(
        onTap: () => setState(() => _color = color),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
                color: selected
                    ? (Theme.of(context).brightness == Brightness.dark
                        ? Colors.white
                        : Colors.black87)
                    : Colors.grey.withValues(alpha: 0.5),
                width: selected ? 2.5 : 1),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Column(
      children: [
        // ----- Toolbar -----
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.black26
                : Colors.grey[200],
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Row(
            children: [
              const Icon(Icons.photo_camera_outlined, size: 18),
              const SizedBox(width: 8),
              const Text('Annotate Screenshot',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 16),
              _toolButton(AnnotationTool.pen, Icons.edit, 'Pen'),
              _toolButton(AnnotationTool.highlighter, Icons.border_color,
                  'Highlighter'),
              _toolButton(
                  AnnotationTool.arrow, Icons.north_east, 'Arrow'),
              _toolButton(AnnotationTool.rect,
                  Icons.check_box_outline_blank, 'Rectangle'),
              _toolButton(
                  AnnotationTool.text, Icons.text_fields, 'Text (click to place)'),
              const SizedBox(width: 12),
              ..._palette.map(_colorSwatch),
              const SizedBox(width: 12),
              const Icon(Icons.line_weight, size: 16),
              SizedBox(
                width: 110,
                child: Slider(
                  value: _strokeWidth,
                  min: 2,
                  max: 20,
                  onChanged: (val) => setState(() => _strokeWidth = val),
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.undo, size: 20),
                tooltip: 'Undo last annotation',
                onPressed: _annotations.isEmpty
                    ? null
                    : () => setState(() => _annotations.removeLast()),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: 'Clear all annotations',
                onPressed: _annotations.isEmpty
                    ? null
                    : () => setState(() => _annotations.clear()),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save, size: 16),
                label: const Text('Save PNG'),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Close without saving',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        // ----- Canvas -----
        Expanded(
          child: Container(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.black45
                : Colors.grey[350],
            padding: const EdgeInsets.all(12.0),
            child: image == null
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(builder: (context, constraints) {
                    final double scale = [
                      constraints.maxWidth / image.width,
                      constraints.maxHeight / image.height,
                      1.0,
                    ].reduce((a, b) => a < b ? a : b);
                    final double dispW = image.width * scale;
                    final double dispH = image.height * scale;

                    Offset toImage(Offset local) => Offset(
                        (local.dx / scale).clamp(0, image.width.toDouble()),
                        (local.dy / scale).clamp(0, image.height.toDouble()));

                    return Center(
                      child: SizedBox(
                        width: dispW,
                        height: dispH,
                        child: MouseRegion(
                          cursor: _tool == AnnotationTool.text
                              ? SystemMouseCursors.text
                              : SystemMouseCursors.precise,
                          child: GestureDetector(
                            onTapUp: (d) => _onTapForText(
                                toImage(d.localPosition)),
                            onPanStart: (d) =>
                                _onPanStart(toImage(d.localPosition)),
                            onPanUpdate: (d) =>
                                _onPanUpdate(toImage(d.localPosition)),
                            onPanEnd: (_) => _onPanEnd(),
                            child: CustomPaint(
                              painter: _AnnotationPainter(
                                image: image,
                                annotations: _annotations,
                                active: _active,
                                scale: scale,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
          ),
        ),
      ],
    );
  }
}

// Paints [annotations] (given in image coordinates) on [canvas]. Pass a
// non-null [scale] to pre-scale the canvas for on-screen display; null keeps
// full image resolution (used when saving).
void _paintAnnotationsOnCanvas(
    Canvas canvas, List<_Annotation> annotations, double? scale) {
  if (scale != null) canvas.scale(scale);

  for (final a in annotations) {
    final paint = Paint()
      ..color = a.tool == AnnotationTool.highlighter
          ? a.color.withValues(alpha: 0.35)
          : a.color
      ..strokeWidth =
          a.tool == AnnotationTool.highlighter ? a.strokeWidth * 3 : a.strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = a.tool == AnnotationTool.highlighter
          ? StrokeCap.square
          : StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (a.tool) {
      case AnnotationTool.pen:
      case AnnotationTool.highlighter:
        if (a.points.length < 2) break;
        final path = Path()..moveTo(a.points.first.dx, a.points.first.dy);
        for (final p in a.points.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path, paint);
        break;

      case AnnotationTool.arrow:
        if (a.points.length < 2) break;
        final start = a.points.first;
        final end = a.points.last;
        canvas.drawLine(start, end, paint);
        // Arrowhead: two short lines back from the tip.
        final direction = (end - start);
        if (direction.distance > 1) {
          final unit = direction / direction.distance;
          final normal = Offset(-unit.dy, unit.dx);
          final double headLen = (a.strokeWidth * 3).clamp(10.0, 40.0);
          final base = end - unit * headLen;
          canvas.drawLine(end, base + normal * (headLen / 2), paint);
          canvas.drawLine(end, base - normal * (headLen / 2), paint);
        }
        break;

      case AnnotationTool.rect:
        if (a.points.length < 2) break;
        canvas.drawRect(Rect.fromPoints(a.points.first, a.points.last), paint);
        break;

      case AnnotationTool.text:
        if (a.points.isEmpty || a.text == null) break;
        final textPainter = TextPainter(
          text: TextSpan(
            text: a.text,
            style: TextStyle(
              color: a.color,
              fontSize: (a.strokeWidth * 4).clamp(16.0, 96.0),
              fontWeight: FontWeight.bold,
              shadows: const [
                Shadow(blurRadius: 3, color: Colors.black54),
              ],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        textPainter.paint(canvas, a.points.first);
        break;
    }
  }
}

class _AnnotationPainter extends CustomPainter {
  final ui.Image image;
  final List<_Annotation> annotations;
  final _Annotation? active;
  final double scale;

  _AnnotationPainter({
    required this.image,
    required this.annotations,
    required this.active,
    required this.scale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw the screenshot scaled to the display size.
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..filterQuality = FilterQuality.medium,
    );
    _paintAnnotationsOnCanvas(
        canvas, [...annotations, ?active], scale);
  }

  @override
  bool shouldRepaint(covariant _AnnotationPainter oldDelegate) => true;
}
