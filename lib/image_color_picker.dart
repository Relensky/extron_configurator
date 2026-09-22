import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'contrast.dart' show readableOn;

/// An image decoded to RGBA bytes, for sampling colors out of.
class DecodedImage {
  final int width;
  final int height;

  /// Four bytes per pixel, row by row.
  final Uint8List rgba;

  const DecodedImage(this.width, this.height, this.rgba);

  /// The color at pixel ([x], [y]), clamped to the image.
  Color pixel(int x, int y) {
    final cx = x.clamp(0, width - 1);
    final cy = y.clamp(0, height - 1);
    final i = (cy * width + cx) * 4;
    return Color.fromARGB(rgba[i + 3], rgba[i], rgba[i + 1], rgba[i + 2]);
  }
}

/// Decodes PNG or JPEG [bytes], or null when they are not an image.
Future<DecodedImage?> decodeImageForPicking(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final decoded = data == null
        ? null
        : DecodedImage(image.width, image.height, data.buffer.asUint8List());
    image.dispose();
    codec.dispose();
    return decoded;
  } catch (_) {
    return null;
  }
}

/// The most common colors in [image], most common first, at most [count].
///
/// Transparent pixels and near-white and near-black are left out: they are
/// the logo's background and outline, not its brand color. Similar shades are
/// counted together.
List<Color> dominantColors(DecodedImage image, {int count = 6}) {
  final counts = <int, int>{};
  final sums = <int, List<int>>{};
  // Every pixel of a small logo, a sample of a large one.
  final step = math.max(1, math.sqrt(image.width * image.height / 40000).floor());
  for (var y = 0; y < image.height; y += step) {
    for (var x = 0; x < image.width; x += step) {
      final i = (y * image.width + x) * 4;
      final r = image.rgba[i], g = image.rgba[i + 1], b = image.rgba[i + 2];
      if (image.rgba[i + 3] < 128) continue;
      final hi = math.max(r, math.max(g, b));
      final lo = math.min(r, math.min(g, b));
      if (lo > 235 || hi < 20) continue;
      // Grays that are not near-black or near-white still count - a charcoal
      // wordmark is a real brand color.
      final key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
      counts[key] = (counts[key] ?? 0) + 1;
      final sum = sums.putIfAbsent(key, () => [0, 0, 0]);
      sum[0] += r;
      sum[1] += g;
      sum[2] += b;
    }
  }
  final keys = counts.keys.toList()
    ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  final out = <Color>[];
  for (final key in keys) {
    final n = counts[key]!;
    final sum = sums[key]!;
    final color = Color.fromARGB(255, sum[0] ~/ n, sum[1] ~/ n, sum[2] ~/ n);
    // Skip a shade too close to one already offered.
    final near = out.any((c) {
      final dr = (c.r - color.r) * 255, dg = (c.g - color.g) * 255;
      final db = (c.b - color.b) * 255;
      return dr * dr + dg * dg + db * db < 40 * 40;
    });
    if (near) continue;
    out.add(color);
    if (out.length >= count) break;
  }
  return out;
}

/// Opens [bytes] and lets the user click a color out of it. Returns the color
/// picked, or null when the dialog is canceled or the image cannot be read.
Future<Color?> pickColorFromImage(
  BuildContext context,
  Uint8List bytes, {
  String title = 'Pick a color from the logo',
}) async {
  final image = await decodeImageForPicking(bytes);
  if (image == null || !context.mounted) return null;
  return showDialog<Color>(
    context: context,
    builder: (ctx) => _ImageColorDialog(
      image: image,
      bytes: bytes,
      title: title,
    ),
  );
}

class _ImageColorDialog extends StatefulWidget {
  final DecodedImage image;
  final Uint8List bytes;
  final String title;

  const _ImageColorDialog({
    required this.image,
    required this.bytes,
    required this.title,
  });

  @override
  State<_ImageColorDialog> createState() => _ImageColorDialogState();
}

class _ImageColorDialogState extends State<_ImageColorDialog> {
  late final List<Color> _suggested = dominantColors(widget.image);
  Color? _picked;
  Color? _hover;

  static String hexOf(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// The pixel under [local] in a box of [size] showing the image fitted.
  Color? _sample(Offset local, Size size) {
    final img = widget.image;
    final scale = math.min(size.width / img.width, size.height / img.height);
    final shown = Size(img.width * scale, img.height * scale);
    final origin = Offset(
      (size.width - shown.width) / 2,
      (size.height - shown.height) / 2,
    );
    final p = (local - origin) / scale;
    if (p.dx < 0 || p.dy < 0 || p.dx >= img.width || p.dy >= img.height) {
      return null;
    }
    final c = img.pixel(p.dx.floor(), p.dy.floor());
    // A transparent pixel is the background, not a color to brand with.
    return c.a < 0.5 ? null : c.withAlpha(255);
  }

  Widget _chip(Color c, {bool selected = false}) => Tooltip(
    message: hexOf(c),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: () => setState(() => _picked = c),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Colors.black26,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? Icon(Icons.check, size: 16, color: readableOn(c))
            : null,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = _hover ?? _picked;
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: math.min(520, size.width - 120),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Click anywhere on the image to take its color, or pick one '
                'of the main colors below it.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Container(
                height: (size.height - 360).clamp(120.0, 260.0),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: theme.dividerColor),
                ),
                child: LayoutBuilder(
                  builder: (context, box) => MouseRegion(
                    cursor: SystemMouseCursors.precise,
                    onHover: (e) => setState(
                      () => _hover = _sample(e.localPosition, box.biggest),
                    ),
                    onExit: (_) => setState(() => _hover = null),
                    child: GestureDetector(
                      key: const ValueKey('image_color_area'),
                      onTapDown: (d) {
                        final c = _sample(d.localPosition, box.biggest);
                        if (c != null) setState(() => _picked = c);
                      },
                      child: Image.memory(
                        widget.bytes,
                        width: box.maxWidth,
                        height: box.maxHeight,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.none,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_suggested.isNotEmpty) ...[
                Text('Main colors', style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in _suggested)
                      _chip(c, selected: _picked == c),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 28,
                    decoration: BoxDecoration(
                      color: shown,
                      border: Border.all(color: theme.dividerColor),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    shown == null
                        ? 'Nothing picked yet'
                        : '${hexOf(shown)}${_hover != null && _hover != _picked ? ' (under the pointer)' : ''}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('image_color_use'),
          onPressed:
              _picked == null ? null : () => Navigator.of(context).pop(_picked),
          child: const Text('Use this color'),
        ),
      ],
    );
  }
}
