import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'av_flow_model.dart' show kCableLengthsFt, formatCableLength;

/// Feet read off what was typed: "12", "12ft", "12 ft", "12'". 0 for blank
/// or anything that is not a length.
double parseCableLength(String text) {
  final t = text.trim().toLowerCase().replaceAll(RegExp(r"(feet|foot|ft|')$"), '');
  final v = double.tryParse(t.trim()) ?? 0;
  return v > 0 ? v : 0;
}

/// A cable length in feet: typed, or picked from the stocked leads in the
/// menu at its end. 0 is "not set".
class CableLengthField extends StatefulWidget {
  const CableLengthField({
    super.key,
    required this.initial,
    required this.onChanged,
    this.label = 'Length (ft)',
    this.hint = 'Not set',
    this.dense = false,
  });

  final double initial;
  final ValueChanged<double> onChanged;
  final String? label;
  final String hint;

  /// Compact, for a row in a list.
  final bool dense;

  @override
  State<CableLengthField> createState() => _CableLengthFieldState();
}

class _CableLengthFieldState extends State<CableLengthField> {
  late final TextEditingController _text =
      TextEditingController(text: _show(widget.initial));

  static String _show(double ft) {
    if (ft <= 0) return '';
    return ft == ft.roundToDouble() ? '${ft.round()}' : ft.toStringAsFixed(1);
  }

  /// Follows a length set from outside - "Set every run to".
  @override
  void didUpdateWidget(CableLengthField old) {
    super.didUpdateWidget(old);
    if (widget.initial != parseCableLength(_text.text)) {
      _text.text = _show(widget.initial);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _pick(double ft) {
    setState(() => _text.text = _show(ft));
    widget.onChanged(ft);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _text,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r"[0-9.ftFT ']")),
      ],
      style: widget.dense ? const TextStyle(fontSize: 12) : null,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        suffixText: widget.dense ? null : 'ft',
        isDense: true,
        suffixIconConstraints: widget.dense
            ? const BoxConstraints(minWidth: 24, minHeight: 24)
            : null,
        suffixIcon: PopupMenuButton<double>(
          tooltip: 'Pick a stocked length',
          padding: EdgeInsets.zero,
          icon: Icon(Icons.arrow_drop_down, size: widget.dense ? 18 : 24),
          onSelected: _pick,
          itemBuilder: (_) => [
            const PopupMenuItem(value: 0.0, child: Text('Not set')),
            for (final ft in kCableLengthsFt)
              PopupMenuItem(value: ft, child: Text(formatCableLength(ft))),
          ],
        ),
      ),
      onChanged: (v) => widget.onChanged(parseCableLength(v)),
    );
  }
}
