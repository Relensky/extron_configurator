import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// ============================================================================
///  COLOR WHEEL PICKER
/// ============================================================================
///  A self-contained HSV picker for the diagram tabs: hue and saturation on a
///  wheel, brightness on a slider, plus a hex box for matching an existing
///  drawing exactly. No package — the app ships without a color-picker
///  dependency and one widget is cheaper than adding one.
/// ============================================================================

/// Opens the wheel and returns the chosen color, or null if canceled.
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
        final center = Offset(radius, radius);

        void handle(Offset local) {
          final v = local - center;
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
    final center = Offset(radius, radius);
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Hue around, at the current brightness so the wheel previews what the
    // slider will actually give you.
    final hues = <Color>[
      for (int i = 0; i <= 360; i += 10)
        HSVColor.fromAHSV(1, i.toDouble() % 360, 1, hsv.value).toColor(),
    ];
    canvas.drawCircle(
      center,
      radius,
      Paint()..shader = SweepGradient(colors: hues).createShader(rect),
    );

    // Saturation falls off towards the middle.
    canvas.drawCircle(
      center,
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
    final marker = center +
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

/// The mark on the chosen swatch: a checkbox drawn ON the colour.
///
/// It used to sit in a solid square of its own — a little white or black tile
/// laid over the swatch — which read clearly enough but hid the very thing
/// the row is for: on a 24x20 chip the tile covered most of the colour, so
/// the selected swatch was the one you could no longer see. The checkbox
/// keeps its outline and its tick, both in whichever of white/near-black
/// reads on that swatch, and the swatch's own colour stays its ground.
///
/// Sized off the swatch so the small chips on the cable and signal dialogs
/// (24x20) get one that fits, and the full-size ones get one that is worth
/// seeing.
class _SelectedTick extends StatelessWidget {
  /// The colour that reads on the swatch — white on a dark one, near-black on
  /// a light one. The checkbox outline AND the tick are both drawn in it; the
  /// ground behind them is the swatch.
  final Color onColor;

  final double width;
  final double height;

  const _SelectedTick({
    required this.onColor,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    final side = math.min(width, height).clamp(0.0, 40.0) - 6;
    final box = side.clamp(11.0, 18.0);
    return Container(
      width: box,
      height: box,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: onColor.withValues(alpha: 0.9), width: 1.2),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.check, size: box - 3, color: onColor),
    );
  }
}

/// A colour chip marked as chosen by A CHECKBOX ON THE COLOUR AND A GLOW
/// BEHIND IT.
///
/// THE BOX AROUND IT IS WHAT WENT. It used to draw a three-pixel ring in the
/// theme's primary as well, and a ring is a second colour laid hard against
/// the one being chosen - on a palette of twelve, the chosen swatch was the
/// one you could no longer judge, because it was being read through a thick
/// border of a completely different hue.
///
/// The glow stays, and is the reason the ring is not missed. It sits BEHIND
/// the chip rather than on top of it, so it says "this one" from across the
/// row without touching the colour itself, and being a shadow it costs no
/// layout - the row does not reflow when the choice moves along it.
///
/// The tick is the other half: [_SelectedTick], drawn in whichever of white or
/// near-black reads on that colour, with the colour itself as its ground. It
/// is what still answers the question in a screenshot, on a monochrome
/// display, or for anybody who cannot pick the glow out.
///
/// Every swatch keeps the same hairline edge whether it is chosen or not - a
/// white swatch on a white card needs one, and an edge every chip has is a
/// cell boundary rather than a selection mark.
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
        // THE SAME HAIRLINE ON EVERY CHIP. It is there so a pale swatch has an
        // edge at all, not to say which one is chosen - the glow and the tick
        // say that.
        border: Border.all(color: theme.dividerColor),
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
          ? _SelectedTick(onColor: onColor, width: width, height: height)
          : (badge == null ? null : Icon(badge, size: 13, color: onColor)),
    );

    final tappable = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      // A little breathing room so neighboring rings never touch.
      child: Padding(padding: const EdgeInsets.all(2), child: chip),
    );

    return tooltip == null || tooltip!.isEmpty
        ? tappable
        : Tooltip(message: tooltip!, child: tappable);
  }
}
