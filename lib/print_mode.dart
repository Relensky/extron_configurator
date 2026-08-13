import 'package:flutter/material.dart';

/// ============================================================================
///  PRINT MODE
/// ============================================================================
///  A flag hung above a subtree that is about to be photographed.
///
///  The Cost tab is a workspace: every figure on it sits in an input box, every
///  row ends in a reset arrow and a delete bin, and every section has an Add
///  button over it. All of that is right on screen and wrong in a picture — an
///  emailed quote with a row of delete icons down the side of it is a picture
///  somebody has to apologize for.
///
///  Hiding them one control at a time would mean threading a boolean through
///  forty widgets and remembering to do it again for the forty-first. Instead
///  the two things almost every one of those controls is built from — the live
///  text field and the row icon button — ask this on the way past. Wrapping the
///  subtree switches the lot, and a control added later is covered without
///  anybody having to know this exists.
///
///  A field prints as its VALUE, not as an empty box: the price cells hold the
///  room's own override and show the resolved catalog figure as a placeholder,
///  so the placeholder is the number that has to end up on the page.
/// ============================================================================

class PrintMode extends InheritedWidget {
  /// True while the subtree is being rendered for an image.
  final bool printing;

  const PrintMode({
    super.key,
    required this.printing,
    required super.child,
  });

  /// False when there is no [PrintMode] above — the normal, on-screen case.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PrintMode>()?.printing ??
      false;

  @override
  bool updateShouldNotify(PrintMode oldWidget) =>
      oldWidget.printing != printing;
}

/// Drops [child] out of the layout entirely while printing. For the controls
/// that have no printed form at all — Add buttons, switches, tier pickers.
class PrintHide extends StatelessWidget {
  final Widget child;

  const PrintHide({super.key, required this.child});

  @override
  Widget build(BuildContext context) =>
      PrintMode.of(context) ? const SizedBox.shrink() : child;
}

/// A checkbox that prints as a word. "Taxable: ☐" means nothing on paper; the
/// column still has to say yes or no.
class PrintableCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool?>? onChanged;
  final bool dense;

  const PrintableCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    if (PrintMode.of(context)) {
      return Text(
        value ? 'Yes' : 'No',
        // Centred, because a checkbox is: on the estimate this sits in a
        // fixed-width cell under a centred "Taxable", and a word hard against
        // the left of it reads as belonging to the column before. Beside a
        // label — the fee rows — the Text is only as wide as the word, so
        // this changes nothing there.
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12),
      );
    }
    return Checkbox(
      value: value,
      onChanged: onChanged,
      visualDensity: dense ? VisualDensity.compact : null,
      materialTapTargetSize:
          dense ? MaterialTapTargetSize.shrinkWrap : null,
    );
  }
}
