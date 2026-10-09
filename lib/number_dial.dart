import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// A slider with its number beside it. Click the number to type one; Enter
/// or clicking away sets it, Escape leaves it as it was.
///
/// [onChanged] runs while the slider moves; [onChangeEnd] once it lets go,
/// and once for a typed number, right after [onChanged].
class NumberDial extends StatefulWidget {
  /// On the slider. The number takes the same key with '_number' on the end,
  /// and the field it turns into '_field'.
  final ValueKey<String>? sliderKey;
  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;

  /// The number as shown: '12 ft', '45°'.
  final String Function(double) format;

  /// The number as it starts in the field. Defaults to [format], so the
  /// field holds what the dial showed.
  final String Function(double)? editText;

  /// Reads what was typed. Defaults to the first number in it.
  final double? Function(String)? parse;

  /// How far a typed number may go; defaults to [min] and [max].
  final double? typedMin;
  final double? typedMax;

  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// Width of the slider; null fills the row.
  final double? sliderWidth;

  const NumberDial({
    super.key,
    this.sliderKey,
    this.label = '',
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.format,
    this.editText,
    this.parse,
    this.typedMin,
    this.typedMax,
    required this.onChanged,
    this.onChangeEnd,
    this.sliderWidth = 150,
  });

  @override
  State<NumberDial> createState() => _NumberDialState();
}

/// The first number in [text], or null.
double? firstNumber(String text) {
  final m = RegExp(r'-?\d+(?:\.\d+)?|-?\.\d+').firstMatch(text);
  return m == null ? null : double.tryParse(m.group(0)!);
}

class _NumberDialState extends State<NumberDial> {
  TextEditingController? _field;
  final _focus = FocusNode();

  /// What the field opened with; left as is, nothing changes.
  String _started = '';

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _field != null) _commit();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _field?.dispose();
    super.dispose();
  }

  void _start() {
    final text = (widget.editText ?? widget.format)(widget.value);
    _started = text;
    setState(() {
      _field = TextEditingController(text: text)
        ..selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    });
    _focus.requestFocus();
  }

  void _stop() {
    final f = _field;
    setState(() => _field = null);
    // After the frame that takes the field away.
    WidgetsBinding.instance.addPostFrameCallback((_) => f?.dispose());
  }

  void _commit() {
    final f = _field;
    if (f == null) return;
    final typed = f.text.trim();
    final v = (widget.parse ?? firstNumber)(typed);
    _stop();
    if (typed == _started.trim()) return;
    if (v == null || !v.isFinite) return;
    final kept = v
        .clamp(widget.typedMin ?? widget.min, widget.typedMax ?? widget.max)
        .toDouble();
    widget.onChanged(kept);
    widget.onChangeEnd?.call(kept);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final base = widget.sliderKey?.value;
    final field = _field;
    final number = field != null
        ? SizedBox(
            width: 76,
            child: Focus(
              onKeyEvent: (_, e) {
                if (e is KeyDownEvent &&
                    e.logicalKey == LogicalKeyboardKey.escape) {
                  _stop();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                key: base == null ? null : ValueKey('${base}_field'),
                controller: field,
                focusNode: _focus,
                style: small,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _commit(),
              ),
            ),
          )
        : Tooltip(
            message: 'Click to type a number',
            child: InkWell(
              key: base == null ? null : ValueKey('${base}_number'),
              borderRadius: BorderRadius.circular(4),
              onTap: _start,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  widget.format(widget.value),
                  style: small?.copyWith(
                    decoration: TextDecoration.underline,
                    decorationStyle: TextDecorationStyle.dotted,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
          );
    final slider = Slider(
      key: widget.sliderKey,
      value: widget.value.clamp(widget.min, widget.max).toDouble(),
      min: widget.min,
      max: widget.max,
      divisions: widget.divisions,
      onChanged: widget.onChanged,
      onChangeEnd: widget.onChangeEnd,
    );
    return Row(
      mainAxisSize: widget.sliderWidth == null
          ? MainAxisSize.max
          : MainAxisSize.min,
      children: [
        if (widget.label.isNotEmpty) Text(widget.label, style: small),
        number,
        if (widget.sliderWidth == null)
          Expanded(child: slider)
        else
          SizedBox(width: widget.sliderWidth, child: slider),
      ],
    );
  }
}
