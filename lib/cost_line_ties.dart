import 'package:material_ui/material_ui.dart';

import 'cost_estimate.dart';

/// ============================================================================
///  TIED LINES ON THE COST TAB
/// ============================================================================
///  A mount goes with its display, a mic with its base. Tagged together from
///  the tag button, so taking one off the quote, replacing it or changing how
///  many are bought warns that the other one may have to follow. The ties are
///  kept in [RoomCostSettings.lineTies]; this file is the dialogs.
/// ============================================================================

/// Every line on [estimate] that can be tied, in page order.
List<CostLine> tieableLines(CostEstimate estimate) => [
  ...estimate.optional,
  ...estimate.equipment,
  ...estimate.extras,
  ...estimate.hardware,
  ...estimate.cabling,
];

/// What to call the line keyed [key]: its description, else its model.
/// A line no longer on the quote says so.
String tiedLineName(CostEstimate estimate, String key) {
  final line = tieableLines(estimate).where((l) => l.key == key).firstOrNull;
  if (line == null) return 'An item no longer on the quote';
  return costLineName(line);
}

/// A line's name for a message.
String costLineName(CostLine line) {
  final name = line.description.trim();
  if (name.isNotEmpty) return name;
  return line.model.trim().isEmpty ? 'This line' : line.model.trim();
}

/// Asks which line to tie [line] to. Null when canceled.
Future<String?> pickTieLine(
  BuildContext context, {
  required CostEstimate estimate,
  required CostLine line,
  required Set<String> tied,
}) {
  final choices = [
    for (final l in tieableLines(estimate))
      if (l.key != line.key && !tied.contains(l.key)) l,
  ];
  return showDialog<String>(
    context: context,
    builder: (ctx) => _TiePickerDialog(
      title: 'Tie ${costLineName(line)} to',
      choices: choices,
    ),
  );
}

class _TiePickerDialog extends StatefulWidget {
  final String title;
  final List<CostLine> choices;

  const _TiePickerDialog({required this.title, required this.choices});

  @override
  State<_TiePickerDialog> createState() => _TiePickerDialogState();
}

class _TiePickerDialogState extends State<_TiePickerDialog> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final words = _filter.toLowerCase().split(' ').where((w) => w.isNotEmpty);
    final shown = [
      for (final l in widget.choices)
        if (words.every((w) => [
              l.description,
              l.model,
              l.manufacturer,
              l.partNumber,
              l.category,
            ].join(' ').toLowerCase().contains(w)))
          l,
    ];
    return AlertDialog(
      key: const ValueKey('cost_tie_picker'),
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Removing, replacing or changing the count of either item '
              'will warn about the other.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('cost_tie_filter'),
              autofocus: true,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Filter by name, model or category',
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        widget.choices.isEmpty
                            ? 'No other items on the quote.'
                            : 'Nothing matches.',
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  : ListView(
                      children: [
                        for (final l in shown)
                          ListTile(
                            key: ValueKey('cost_tie_pick_${l.key}'),
                            dense: true,
                            leading: const Icon(Icons.link, size: 18),
                            title: Text(costLineName(l)),
                            subtitle: Text(
                              [
                                l.category,
                                l.manufacturer,
                                if (l.model != l.description) l.model,
                                'qty ${trimNumber(l.qty)}',
                              ].where((s) => s.trim().isNotEmpty).join(' - '),
                            ),
                            onTap: () => Navigator.of(context).pop(l.key),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// The warning line for a dialog about [key]'s line, or '' when it is tied
/// to nothing.
String tiedWarning(CostEstimate estimate, RoomCostSettings settings,
    String key) {
  final ties = settings.tiesOf(key);
  if (ties.isEmpty) return '';
  final names = [for (final k in ties) tiedLineName(estimate, k)];
  return 'Tied to ${names.join(', ')}. Check '
      '${ties.length == 1 ? 'it' : 'them'} too.';
}

/// Asks before [action] on a tied line. True when there are no ties, or
/// when the user goes ahead.
Future<bool> confirmTiedChange(
  BuildContext context, {
  required CostEstimate estimate,
  required RoomCostSettings settings,
  required String key,
  required String name,
  required String action,
}) async {
  final warning = tiedWarning(estimate, settings, key);
  if (warning.isEmpty) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('cost_tie_confirm'),
      icon: const Icon(Icons.link),
      title: Text('$name is tied to other items'),
      content: SizedBox(width: 440, child: Text(warning)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('cost_tie_confirm_go'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}
