import 'package:material_ui/material_ui.dart';

/// A pick-one row as chips that wrap, each label on one line with room
/// around it - for an iPhone, where a [SegmentedButton] squeezes its
/// segments until a word breaks in two ("All part / s").
class ChoiceChipsRow<T> extends StatelessWidget {
  /// Each choice and its label, in order.
  final Map<T, String> choices;
  final T selected;

  /// Null: the chips are shown but cannot be changed.
  final ValueChanged<T>? onChanged;

  /// Prefixes each chip's key: `keyPrefix_index`.
  final String keyPrefix;

  const ChoiceChipsRow({
    super.key,
    required this.choices,
    required this.selected,
    required this.onChanged,
    this.keyPrefix = 'choice',
  });

  @override
  Widget build(BuildContext context) {
    final entries = choices.entries.toList();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < entries.length; i++)
          ChoiceChip(
            key: ValueKey('${keyPrefix}_$i'),
            label: Text(entries[i].value, maxLines: 1, softWrap: false),
            labelPadding: const EdgeInsets.symmetric(horizontal: 10),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            showCheckmark: false,
            selected: entries[i].key == selected,
            onSelected: onChanged == null
                ? null
                : (_) => onChanged!(entries[i].key),
          ),
      ],
    );
  }
}
