import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// ============================================================================
///  COLOR WHEEL PICKER
/// ============================================================================
///  A self-contained HSV picker for the diagram tabs: hue and saturation on a
///  wheel, brightness on a slider, plus a hex box for matching an existing
///  drawing exactly. No package — the app ships without a colour-picker
///  dependency and one widget is cheaper than adding one.
/// ============================================================================

/// Opens the wheel and returns the chosen colour, or null if cancelled.
Future<Color?> showColorWheelDialog(
  BuildContext context, {
  required Color initial,
  String title = 'Custom color',
}) {
  return showDialog<Color>(
    context: context,
    builder: (ctx) => _ColorWheelDialog(initial: initial, title: title),
  );
}

class _ColorWheelDialog extends StatefulWidget {
  final Color initial;
  final String title;

  const _ColorWheelDialog({required this.initial, required this.title});

  @override
  State<_ColorWheelDialog> createState() => _ColorWheelDialogState();
}

class _ColorWheelDialogState extends State<_ColorWheelDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);
  late final TextEditingController _hex = TextEditingController(
    text: _hexOf(widget.initial),
  );

  static String _hexOf(Color c) =>
      (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  Color get _color => _hsv.toColor();

  void _setFromWheel(HSVColor next) {
    setState(() {
      _hsv = next;
      _hex.text = _hexOf(next.toColor());
    });
  }

  void _setFromHex(String raw) {
    final cleaned = raw.replaceAll('#', '').trim();
    if (cleaned.length != 6) return;
    final value = int.tryParse(cleaned, radix: 16);
    if (value == null) return;
    setState(() => _hsv = HSVColor.fromColor(Color(0xFF000000 | value)));
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 220,
              child: _ColorWheel(
                hsv: _hsv,
                onChanged: _setFromWheel,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const SizedBox(
                  width: 74,
                  child: Text('Brightness', style: TextStyle(fontSize: 12)),
                ),
                Expanded(
                  child: Slider(
                    value: _hsv.value,
                    onChanged: (v) =>
                        _setFromWheel(_hsv.withValue(v.clamp(0.05, 1.0))),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Container(
                  width: 46,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _color,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Theme.of(context).dividerColor),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _hex,
                    decoration: const InputDecoration(
                      labelText: 'Hex',
                      prefixText: '#',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      LengthLimitingTextInputFormatter(6),
                      FilteringTextInputFormatter.allow(
                        RegExp('[0-9a-fA-F]'),
                      ),
                    ],
                    onChanged: _setFromHex,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(_color),
          child: const Text('Use this color'),
        ),
      ],
    );
  }
}

/// Hue around the wheel, saturation from the middle out. Brightness is the
/// slider's job — putting it on the wheel too would make every point
/// ambiguous.
class _ColorWheel extends StatelessWidget {
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  const _ColorWheel({required this.hsv, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final size = math.min(constraints.maxWidth, constraints.maxHeight);
        final radius = size / 2;
        final centre = Offset(radius, radius);

        void handle(Offset local) {
          final v = local - centre;
          final distance = v.distance;
          // Clamp to the rim rather than ignoring the drag, so sliding off
          // the edge keeps tracking the hue instead of sticking.
          final saturation = (distance / radius).clamp(0.0, 1.0);
          var hue = math.atan2(v.dy, v.dx) * 180 / math.pi;
          if (hue < 0) hue += 360;
          onChanged(hsv.withHue(hue).withSaturation(saturation));
        }

        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: GestureDetector(
              onPanDown: (d) => handle(d.localPosition),
              onPanUpdate: (d) => handle(d.localPosition),
              child: CustomPaint(
                painter: _WheelPainter(hsv),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WheelPainter extends CustomPainter {
  final HSVColor hsv;

  const _WheelPainter(this.hsv);

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.width / 2;
    final centre = Offset(radius, radius);
    final rect = Rect.fromCircle(center: centre, radius: radius);

    // Hue around, at the current brightness so the wheel previews what the
    // slider will actually give you.
    final hues = <Color>[
      for (int i = 0; i <= 360; i += 10)
        HSVColor.fromAHSV(1, i.toDouble() % 360, 1, hsv.value).toColor(),
    ];
    canvas.drawCircle(
      centre,
      radius,
      Paint()..shader = SweepGradient(colors: hues).createShader(rect),
    );

    // Saturation falls off towards the middle.
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            HSVColor.fromAHSV(1, 0, 0, hsv.value).toColor(),
            HSVColor.fromAHSV(0, 0, 0, hsv.value).toColor(),
          ],
        ).createShader(rect),
    );

    // The current pick.
    final angle = hsv.hue * math.pi / 180;
    final marker = centre +
        Offset(math.cos(angle), math.sin(angle)) * (hsv.saturation * radius);
    canvas.drawCircle(
      marker,
      9,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawCircle(
      marker,
      9,
      Paint()
        ..color = Colors.black54
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _WheelPainter old) => old.hsv != hsv;
}

/// A colour chip with an unmistakable selected state: a heavy ring, a lift,
/// and a tick in a contrasting colour. The old version only thickened the
/// border, which was easy to miss against a row of similar swatches.
class ColorSwatchButton extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final String? tooltip;

  /// Drawn instead of the tick — used by the "follow the signal type" chip.
  final IconData? badge;

  final double width;
  final double height;

  const ColorSwatchButton({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
    this.tooltip,
    this.badge,
    this.width = 34,
    this.height = 28,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
            ? Colors.white
            : Colors.black87;

    final chip = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: selected ? theme.colorScheme.primary : theme.dividerColor,
          width: selected ? 3 : 1,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.55),
                  blurRadius: 7,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      alignment: Alignment.center,
      child: selected
          ? Icon(Icons.check, size: 16, color: onColor)
          : (badge == null ? null : Icon(badge, size: 13, color: onColor)),
    );

    final tappable = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      // A little breathing room so neighbouring rings never touch.
      child: Padding(padding: const EdgeInsets.all(2), child: chip),
    );

    return tooltip == null || tooltip!.isEmpty
        ? tappable
        : Tooltip(message: tooltip!, child: tappable);
  }
}
