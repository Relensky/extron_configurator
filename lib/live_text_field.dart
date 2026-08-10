import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  @override
  void didUpdateWidget(covariant LiveTextField old) {
    super.didUpdateWidget(old);
    if (old.fieldId != widget.fieldId) _controller.text = widget.initial;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
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
