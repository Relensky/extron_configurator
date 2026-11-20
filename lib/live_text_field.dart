import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'cost_estimate.dart' show formatMoney;
import 'form_factor.dart' show isMobileDevice;
import 'print_mode.dart';
import 'responsive.dart';

/// A text field that edits live state without losing the cursor.
///
/// The tables on the Cost and Device Editor pages write every keystroke
/// straight into the provider, which rebuilds the whole page. A field that
/// took its text from the rebuilt value would reset the selection on each
/// character — so this one owns its controller and only re-reads [initial]
/// when [fieldId] says the row now holds something else entirely.
class LiveTextField extends StatefulWidget {
  /// Identifies WHAT is being edited (a line key, a fee id, a field name).
  /// Changing it is the one thing that replaces the text in the box.
  final String fieldId;
  final String initial;
  final ValueChanged<String> onChanged;

  /// Called on Enter / focus loss, for edits that shouldn't apply per
  /// keystroke (renaming a catalog entry).
  final ValueChanged<String>? onSubmitted;

  /// Called when an edit is over - Enter or focus loss - after [onChanged]
  /// has had the last of it. For a step that must not run per keystroke.
  /// May be called twice for one edit, so it should be idempotent.
  final VoidCallback? onDone;

  final String? label;
  final String? hint;

  /// Whether [hint] is the value this row RESOLVES TO, rather than an example
  /// of what could be typed here.
  ///
  /// IT DECIDES WHAT A BLANK BOX PRINTS. Two completely different things are
  /// written as a hint on this app's sheets:
  ///
  ///   * A FIGURE THE ROW ALREADY HAS. A price cell holds the room's own
  ///     override and shows the catalog's price behind it, so a blank box
  ///     means "the catalog's" - and on a photographed quote that number is
  ///     the price of the line. It has to print.
  ///   * AN EXAMPLE. 'e.g. Rack build and termination' is an instruction to
  ///     whoever is filling the sheet in. Printed, it reads as a line item
  ///     that somebody quoted, which is worse than a gap: a quote emailed with
  ///     'e.g. Freight' on it is a quote that has to be explained.
  ///
  /// So only a hint marked as a value survives the camera. Everything else
  /// prints as what it is - blank, because nobody typed anything.
  final bool hintIsValue;

  /// A colored outline round the box, e.g. a name nobody typed.
  final Color? outlineColor;

  /// [outlineColor] and [hintStyle] only while the box is empty - showing
  /// its hint - so they go the moment something is typed and come back if
  /// it is cleared.
  final bool outlineOnlyWhenEmpty;

  /// Laid over the theme's hint style.
  final TextStyle? hintStyle;

  final String? helper;
  final String? prefix;
  final String? suffix;

  /// Digits and a decimal point only, right-aligned.
  final bool numeric;

  /// A price: printed as money - [prefix] as the currency, thousands
  /// separated, two decimals - so "11948" prints as "$11,948.00".
  final bool money;

  /// A figure grouped in thousands as it is typed - "250000" shows as
  /// "250,000" - so a budget reads at a glance. Implies [numeric]. The
  /// commas are in the text handed to [onChanged]; the money parsers strip
  /// them.
  final bool thousands;

  /// Opens in a large editor to read and write in: a tap on the box does it
  /// on an iPad or iPhone, and a button on the box does it on a desktop. For
  /// notes, which outgrow a box a few lines tall.
  final bool expandable;

  final bool autofocus;
  final int maxLines;

  /// Set with a larger [maxLines] for a box that grows as it is typed in.
  final int? minLines;

  /// Shows an X that empties the box - for search and filter fields.
  final bool clearable;

  /// Draws the box in red - a value worth a second look, like a 0% tax rate.
  final bool warn;

  /// Waits until typing pauses before calling [onChanged], instead of calling
  /// it on every key.
  ///
  /// For a box whose value reprices or redraws a whole page: a name typed at
  /// speed was a rebuild per letter, and the letters lagged behind the
  /// fingers. What was typed is still committed at once on Enter, on clicking
  /// away, and when the box goes off screen - only the keystrokes in between
  /// are held.
  final bool lazy;

  /// How long a [lazy] box waits after the last key.
  static const Duration lazyPause = Duration(milliseconds: 400);

  const LiveTextField({
    super.key,
    required this.fieldId,
    required this.initial,
    required this.onChanged,
    this.onSubmitted,
    this.onDone,
    this.label,
    this.hint,
    this.hintIsValue = false,
    this.outlineColor,
    this.hintStyle,
    this.outlineOnlyWhenEmpty = false,
    this.helper,
    this.prefix,
    this.suffix,
    this.numeric = false,
    this.money = false,
    this.thousands = false,
    this.expandable = false,
    this.autofocus = false,
    this.maxLines = 1,
    this.minLines,
    this.clearable = false,
    this.warn = false,
    this.lazy = false,
  });

  @override
  State<LiveTextField> createState() => _LiveTextFieldState();
}

class _LiveTextFieldState extends State<LiveTextField> {
  late final TextEditingController _controller = TextEditingController(
    text: _shown(widget.initial),
  );

  /// [text] as this box shows it: grouped in thousands for a [thousands] box.
  String _shown(String text) =>
      widget.thousands ? groupThousands(text) : text;

  bool get _numeric => widget.numeric || widget.thousands;

  /// Owned here so the box can tell "somebody is typing in me" from "somebody
  /// changed this value from outside" — see [didUpdateWidget].
  final FocusNode _focus = FocusNode();

  /// What a [LiveTextField.lazy] box is holding, and the clock on it.
  Timer? _pause;
  String? _held;

  @override
  void initState() {
    super.initState();
    // Clicking or tabbing away commits what was typed.
    _focus.addListener(() {
      if (_focus.hasFocus) return;
      _flush();
      widget.onDone?.call();
    });
  }

  void _changed(String text) {
    if (!widget.lazy) {
      widget.onChanged(text);
      return;
    }
    _held = text;
    _pause?.cancel();
    _pause = Timer(LiveTextField.lazyPause, _flush);
  }

  /// Hands over whatever a lazy box is still holding.
  void _flush() {
    _pause?.cancel();
    _pause = null;
    final held = _held;
    if (held == null) return;
    _held = null;
    widget.onChanged(held);
  }

  @override
  void didUpdateWidget(covariant LiveTextField old) {
    super.didUpdateWidget(old);
    if (old.fieldId != widget.fieldId) {
      _controller.text = _shown(widget.initial);
      return;
    }
    // THE VALUE CHANGED UNDER AN IDLE BOX. A quantity nudged by the + and −
    // buttons beside it is still this field's value, and a box that kept
    // showing the old number would be the one thing on the row disagreeing
    // with the total. Only while the box is NOT being typed in: re-reading a
    // focused field is what this class exists to avoid, since the provider
    // normalizes what it is given ("3." comes back "3") and would eat the
    // keystroke.
    if (!_focus.hasFocus &&
        widget.initial != old.initial &&
        _shown(widget.initial) != _controller.text) {
      _controller.text = _shown(widget.initial);
    }
  }

  @override
  void dispose() {
    // Typed and then scrolled or tabbed away inside the pause: still an edit.
    // Handed over after this frame, because the tree is being torn down now.
    _pause?.cancel();
    final held = _held;
    if (held != null) {
      final commit = widget.onChanged;
      scheduleMicrotask(() => commit(held));
    }
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Being photographed: print the VALUE, not an input box round it. A blank
    // box falls back to the hint ONLY where the hint is the figure the row
    // resolved to — see [LiveTextField.hintIsValue]. Where it is an example
    // for whoever is filling the sheet in, a blank box prints blank: the
    // picture is of what this job says, not of what the app suggests.
    if (PrintMode.of(context)) {
      final shown = _controller.text.trim().isEmpty
          ? (widget.hintIsValue ? (widget.hint ?? '') : '')
          : _controller.text;
      // A word in a price box ("unpriced") prints as the word, unprefixed.
      final amount = widget.money
          ? double.tryParse(shown.replaceAll(',', '').trim())
          : null;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Text(
          amount != null
              ? formatMoney(amount, widget.prefix ?? '')
              : shown.isEmpty
              ? ''
              : widget.money
              ? shown
              : '${widget.prefix ?? ''}$shown${widget.suffix ?? ''}',
          textAlign: widget.numeric ? TextAlign.right : TextAlign.left,
          style: const TextStyle(fontSize: 13),
          maxLines: widget.maxLines,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    return _field();
  }

  /// The note in a large editor. Done writes it back as if it had been
  /// typed here; Cancel leaves the box as it was.
  Future<void> _openEditor() async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => _LargeTextEditor(
        title: widget.label ?? 'Note',
        initial: _controller.text,
        hint: widget.hint,
      ),
    );
    if (text == null || !mounted || text == _controller.text) return;
    _controller.text = text;
    _held = null;
    _pause?.cancel();
    widget.onChanged(text);
    widget.onSubmitted?.call(text);
    widget.onDone?.call();
  }

  OutlineInputBorder get _warnBorder => OutlineInputBorder(
    borderSide: BorderSide(color: Theme.of(context).colorScheme.error, width: 2),
  );

  Widget _field() => widget.outlineOnlyWhenEmpty && widget.outlineColor != null
      ? ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) =>
              _textField(outlined: value.text.trim().isEmpty),
        )
      : _textField(outlined: widget.outlineColor != null);

  Widget _textField({required bool outlined}) => TextField(
    controller: _controller,
    focusNode: _focus,
    // A note on an iPad or iPhone opens in the large editor rather than
    // being typed into a few lines of box under the keyboard.
    readOnly: widget.expandable && isMobileDevice,
    onTap: widget.expandable && isMobileDevice ? _openEditor : null,
    autofocus: widget.autofocus,
    maxLines: widget.maxLines,
    minLines: widget.minLines,
    style: const TextStyle(fontSize: 13),
    keyboardType: _numeric
        ? const TextInputType.numberWithOptions(decimal: true)
        : null,
    inputFormatters: widget.thousands
        ? [ThousandsInputFormatter()]
        : widget.numeric
        ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]
        : null,
    textAlign: _numeric ? TextAlign.right : TextAlign.left,
    decoration: InputDecoration(
      isDense: true,
      border: const OutlineInputBorder(),
      enabledBorder: widget.warn
          ? _warnBorder
          : !outlined
          ? null
          : OutlineInputBorder(
              borderSide: BorderSide(color: widget.outlineColor!, width: 1.5),
            ),
      focusedBorder: widget.warn ? _warnBorder : null,
      labelText: widget.label,
      // A box whose hint is the value it resolves to keeps its label up, so
      // that value shows without the box having to be clicked into.
      floatingLabelBehavior: widget.hintIsValue && widget.label != null
          ? FloatingLabelBehavior.always
          : null,
      hintText: widget.hint,
      hintStyle: widget.hintStyle == null || !outlined
          ? null
          : (Theme.of(context).inputDecorationTheme.hintStyle ??
                    const TextStyle())
                .merge(widget.hintStyle),
      helperText: widget.helper,
      helperMaxLines: 4,
      prefixText: widget.prefix,
      suffixText: widget.suffix,
      suffixIcon: widget.expandable && !isMobileDevice
          ? IconButton(
              key: const ValueKey('live_text_expand'),
              tooltip: 'Open in a larger box',
              icon: const Icon(Icons.open_in_full, size: 16),
              onPressed: _openEditor,
            )
          : widget.clearable
          ? ClearFieldButton(
              controller: _controller,
              onCleared: () {
                _held = null;
                _pause?.cancel();
                widget.onChanged('');
              },
            )
          : null,
    ),
    onChanged: _changed,
    onSubmitted: (text) {
      _flush();
      widget.onSubmitted?.call(text);
      widget.onDone?.call();
    },
    onTapOutside: (_) {
      _flush();
      // Committing on focus loss as well as on Enter: a rename typed and then
      // clicked away from is still a rename the user made.
      if (widget.onSubmitted != null) widget.onSubmitted!(_controller.text);
      FocusManager.instance.primaryFocus?.unfocus();
    },
  );
}


/// [text] with its whole part grouped in thousands: "250000.5" is
/// "250,000.5". Anything but digits, one point and a leading minus is
/// dropped, so a figure pasted as "$250,000" comes out "250,000".
String groupThousands(String text) {
  final negative = text.trimLeft().startsWith('-');
  var clean = text.replaceAll(RegExp(r'[^0-9.]'), '');
  final point = clean.indexOf('.');
  String whole = point < 0 ? clean : clean.substring(0, point);
  final fraction = point < 0
      ? null
      : clean.substring(point + 1).replaceAll('.', '');
  final grouped = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) grouped.write(',');
    grouped.write(whole[i]);
  }
  return '${negative ? '-' : ''}$grouped${fraction == null ? '' : '.$fraction'}';
}

/// Puts the commas in a figure as it is typed, keeping the cursor after the
/// same digit it was after - so typing in the middle of "1,250,000" or
/// deleting a digit next to a comma lands where the fingers expect.
class ThousandsInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    final formatted = groupThousands(text);
    if (formatted == text) return newValue;
    // How many characters that survive formatting sit before the cursor.
    final cursor = newValue.selection.baseOffset.clamp(0, text.length);
    var kept = 0;
    for (var i = 0; i < cursor; i++) {
      if (RegExp(r'[0-9.\-]').hasMatch(text[i])) kept++;
    }
    var at = 0;
    while (at < formatted.length && kept > 0) {
      if (formatted[at] != ',') kept--;
      at++;
    }
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: at),
    );
  }
}


/// A note in a box most of the screen tall, to read and write in. Returns the
/// text on Done, null on Cancel.
class _LargeTextEditor extends StatefulWidget {
  final String title;
  final String initial;
  final String? hint;

  const _LargeTextEditor({
    required this.title,
    required this.initial,
    this.hint,
  });

  @override
  State<_LargeTextEditor> createState() => _LargeTextEditorState();
}

class _LargeTextEditorState extends State<_LargeTextEditor> {
  late final TextEditingController _edit =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _edit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      key: const ValueKey('live_text_editor'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
      title: Text(widget.title),
      content: SizedBox(
        width: size.width < 640 ? size.width : 600,
        height: size.height * 0.6,
        child: TextField(
          key: const ValueKey('live_text_editor_box'),
          controller: _edit,
          autofocus: true,
          expands: true,
          maxLines: null,
          minLines: null,
          keyboardType: TextInputType.multiline,
          textAlignVertical: TextAlignVertical.top,
          style: const TextStyle(fontSize: 16, height: 1.4),
          decoration: InputDecoration(
            hintText: widget.hint,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('live_text_editor_done'),
          onPressed: () => Navigator.pop(context, _edit.text),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
