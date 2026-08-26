import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'print_mode.dart';

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

  final String? helper;
  final String? prefix;
  final String? suffix;

  /// Digits and a decimal point only, right-aligned.
  final bool numeric;

  final bool autofocus;
  final int maxLines;

  const LiveTextField({
    super.key,
    required this.fieldId,
    required this.initial,
    required this.onChanged,
    this.onSubmitted,
    this.label,
    this.hint,
    this.hintIsValue = false,
    this.helper,
    this.prefix,
    this.suffix,
    this.numeric = false,
    this.autofocus = false,
    this.maxLines = 1,
  });

  @override
  State<LiveTextField> createState() => _LiveTextFieldState();
}

class _LiveTextFieldState extends State<LiveTextField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  /// Owned here so the box can tell "somebody is typing in me" from "somebody
  /// changed this value from outside" — see [didUpdateWidget].
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(covariant LiveTextField old) {
    super.didUpdateWidget(old);
    if (old.fieldId != widget.fieldId) {
      _controller.text = widget.initial;
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
        widget.initial != _controller.text) {
      _controller.text = widget.initial;
    }
  }

  @override
  void dispose() {
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
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Text(
          shown.isEmpty
              ? ''
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

  Widget _field() => TextField(
    controller: _controller,
    focusNode: _focus,
    autofocus: widget.autofocus,
    maxLines: widget.maxLines,
    style: const TextStyle(fontSize: 13),
    keyboardType: widget.numeric
        ? const TextInputType.numberWithOptions(decimal: true)
        : null,
    inputFormatters: widget.numeric
        ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]
        : null,
    textAlign: widget.numeric ? TextAlign.right : TextAlign.left,
    decoration: InputDecoration(
      isDense: true,
      border: const OutlineInputBorder(),
      labelText: widget.label,
      hintText: widget.hint,
      helperText: widget.helper,
      prefixText: widget.prefix,
      suffixText: widget.suffix,
    ),
    onChanged: widget.onChanged,
    onSubmitted: widget.onSubmitted,
    onTapOutside: (_) {
      // Committing on focus loss as well as on Enter: a rename typed and then
      // clicked away from is still a rename the user made.
      if (widget.onSubmitted != null) widget.onSubmitted!(_controller.text);
      FocusManager.instance.primaryFocus?.unfocus();
    },
  );
}
