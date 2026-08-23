import 'dart:convert';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'conversion_colors.dart';

/// ============================================================================
///  CONVERSION PREVIEW
/// ============================================================================
///  Shown from the migration dialog after a legacy file is converted. Two
///  panes:
///
///    LEFT   the converted config, rendered as JSON and colored by where each
///           value came from — see [ConversionColors] for the three states and
///           what each one means. Properties the conversion DROPPED are shown
///           in place, struck through, with the reason (an ip_address on a
///           serial device and the like), so nothing disappears unseen.
///
///    RIGHT  every change as its own row with an accept/reject switch. Rejects
///           are applied together by [AppStateProvider.applyConversionChoices]
///           when the dialog is confirmed: a rejected "added" key is removed
///           again, a rejected "removed"/"changed" key gets the loaded file's
///           value back.
///
///  Nothing here touches disk — the working config stays in memory until the
///  user saves, exactly like the rest of the load pipeline.
/// ============================================================================

/// Opens the preview. Returns true when the user confirmed (choices applied),
/// false or null when they backed out and left the conversion untouched.
Future<bool?> showConversionPreviewDialog(
    BuildContext context, AppStateProvider provider) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => _ConversionPreviewDialog(provider: provider),
  );
}

class _ConversionPreviewDialog extends StatefulWidget {
  final AppStateProvider provider;
  const _ConversionPreviewDialog({required this.provider});

  @override
  State<_ConversionPreviewDialog> createState() =>
      _ConversionPreviewDialogState();
}

class _ConversionPreviewDialogState extends State<_ConversionPreviewDialog> {
  /// Local accept/reject state, keyed by change id. Seeded from the provider
  /// so re-opening the dialog remembers what was already decided, and only
  /// written back when the user confirms — closing with Cancel changes
  /// nothing.
  late final Map<String, bool> _accepted = {
    for (final c in widget.provider.conversionChanges) c.id: c.accepted,
  };

  /// Only show conflicts (the flagged drops) — off by default.
  bool _conflictsOnly = false;

  List<ConversionChange> get _changes => widget.provider.conversionChanges
      .where((c) => !_conflictsOnly || c.isConflict)
      .toList();

  int get _rejectedCount => _accepted.values.where((v) => !v).length;

  @override
  Widget build(BuildContext context) {
    final colors = ConversionColors.of(context);
    final int conflictCount =
        widget.provider.conversionChanges.where((c) => c.isConflict).length;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.compare_arrows, color: Colors.orange),
          const SizedBox(width: 10),
          const Text('Conversion Preview'),
          const Spacer(),
          _Legend(colors: colors),
        ],
      ),
      content: SizedBox(
        width: 980,
        height: 580,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              conflictCount == 0
                  ? 'Review what the conversion did. Reject anything you want '
                      'kept as it was in the loaded file.'
                  : '$conflictCount propert${conflictCount == 1 ? 'y was' : 'ies were'} '
                      'dropped as invalid where they sat - those are struck '
                      'through on the left and flagged on the right.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 3, child: _buildJsonPane(colors)),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: _buildChangePane(colors)),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.check, size: 18),
          label: Text(_rejectedCount == 0
              ? 'Accept All'
              : 'Apply ($_rejectedCount rejected)'),
          onPressed: () {
            for (final c in widget.provider.conversionChanges) {
              c.accepted = _accepted[c.id] ?? true;
            }
            widget.provider.applyConversionChoices();
            Navigator.of(context).pop(true);
          },
        ),
      ],
    );
  }

  // --- LEFT PANE: the converted config, colored by provenance --------------

  Widget _buildJsonPane(ConversionColors colors) {
    final provider = widget.provider;

    // Properties the conversion dropped, so they can be shown struck through
    // in the section they came from instead of just vanishing.
    final Map<String, List<ConversionChange>> removedBySection = {};
    for (final c in provider.conversionChanges) {
      if (c.kind != ConversionKind.removed) continue;
      removedBySection.putIfAbsent(c.section, () => []).add(c);
    }

    const mono = TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.5);
    final spans = <TextSpan>[];

    void punct(String text) =>
        spans.add(TextSpan(text: text, style: mono.copyWith(color: colors.punctuation)));

    final sectionKeys = <String>{
      ...provider.roomConfig.keys,
      ...removedBySection.keys,
    }.toList()
      ..sort();

    punct('{\n');
    for (final sectionKey in sectionKeys) {
      spans.add(TextSpan(
        text: '  "$sectionKey"',
        style: mono.copyWith(
            color: colors.sectionName, fontWeight: FontWeight.bold),
      ));
      punct(': ');

      final block = provider.roomConfig[sectionKey];
      if (block is! Map) {
        if (provider.roomConfig.containsKey(sectionKey)) {
          // A scalar at the root of the file. These ARE diffed now, so the
          // color means the same here as it does inside a section.
          spans.add(TextSpan(
            text: jsonEncode(block),
            style: mono.copyWith(
                color: colors.forOrigin(provider.originFor(sectionKey, '')) ??
                    colors.written),
          ));
        } else {
          // A section (or root scalar) the conversion dropped wholesale —
          // struck through rather than printed as a bare "null".
          spans.add(TextSpan(
            text: removedBySection[sectionKey]
                    ?.map((c) => jsonEncode(c.before))
                    .join(', ') ??
                'null',
            style: mono.copyWith(
              color: colors.legacy,
              decoration: TextDecoration.lineThrough,
            ),
          ));
          spans.add(TextSpan(
            text: '   // removed',
            style: mono.copyWith(
                color: colors.punctuation, fontStyle: FontStyle.italic),
          ));
        }
        punct(',\n');
        continue;
      }

      punct('{\n');
      final keys = block.keys.map((k) => k.toString()).toList()..sort();
      for (final key in keys) {
        final Color valueColor =
            colors.forOrigin(provider.originFor(sectionKey, key)) ??
                colors.written;
        punct('    ');
        spans.add(TextSpan(
            text: '"$key"', style: mono.copyWith(color: colors.propertyName)));
        punct(': ');
        spans.add(TextSpan(
          text: jsonEncode(block[key]),
          style: mono.copyWith(color: valueColor),
        ));
        punct(',\n');
      }

      // Dropped properties, struck through where they used to live
      for (final removed in removedBySection[sectionKey] ?? const <ConversionChange>[]) {
        punct('    ');
        spans.add(TextSpan(
          text: '"${removed.key}": ${jsonEncode(removed.before)}',
          style: mono.copyWith(
            color: colors.legacy,
            decoration: TextDecoration.lineThrough,
          ),
        ));
        spans.add(TextSpan(
          text: '   // removed'
              '${removed.conflictReason == null ? '' : ' — ${removed.conflictReason}'}',
          style: mono.copyWith(color: colors.punctuation, fontStyle: FontStyle.italic),
        ));
        punct('\n');
      }

      punct('  },\n');
    }
    punct('}');

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: SingleChildScrollView(
        child: SelectableText.rich(TextSpan(children: spans)),
      ),
    );
  }

  // --- RIGHT PANE: per-change accept/reject ---------------------------------

  Widget _buildChangePane(ConversionColors colors) {
    final changes = _changes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('${changes.length} change${changes.length == 1 ? '' : 's'}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() {
                for (final c in changes) {
                  _accepted[c.id] = true;
                }
              }),
              child: const Text('Accept all'),
            ),
            TextButton(
              onPressed: () => setState(() {
                for (final c in changes) {
                  _accepted[c.id] = false;
                }
              }),
              child: const Text('Reject all'),
            ),
          ],
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Conflicts only'),
          value: _conflictsOnly,
          onChanged: (v) => setState(() => _conflictsOnly = v),
        ),
        const Divider(height: 1),
        Expanded(
          child: changes.isEmpty
              ? const Center(child: Text('Nothing to review.'))
              : ListView.builder(
                  itemCount: changes.length,
                  itemBuilder: (context, i) {
                    final c = changes[i];
                    final bool accepted = _accepted[c.id] ?? true;
                    return CheckboxListTile(
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: accepted,
                      onChanged: (v) =>
                          setState(() => _accepted[c.id] = v ?? true),
                      title: Row(
                        children: [
                          if (c.isConflict) ...[
                            Icon(Icons.warning_amber_rounded,
                                size: 15, color: colors.conflict),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              c.label,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12.5,
                                // Struck through once rejected, so the list
                                // reads at a glance like the JSON pane does
                                decoration: accepted
                                    ? null
                                    : TextDecoration.lineThrough,
                                color: _kindColor(c, colors),
                              ),
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(c.description,
                          style: const TextStyle(fontSize: 11.5)),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// The row color, matching what the JSON pane does to the same value: an
  /// added key is written, a rewritten one is changed, and a removal keeps the
  /// old file's color because the old file's value is what it shows.
  Color _kindColor(ConversionChange c, ConversionColors colors) {
    if (c.isConflict) return colors.conflict;
    switch (c.kind) {
      case ConversionKind.added:
        return colors.written;
      case ConversionKind.changed:
        return colors.changed;
      case ConversionKind.removed:
        return colors.legacy;
    }
  }
}

/// The color key, shown in the dialog title so the coloring in both panes
/// (and on the Devices / System tabs) doesn't need explaining twice.
class _Legend extends StatelessWidget {
  final ConversionColors colors;
  const _Legend({required this.colors});

  @override
  Widget build(BuildContext context) {
    Widget swatch(Color color, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 11, height: 11, color: color),
            const SizedBox(width: 5),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (origin, label) in ConversionColors.legend) ...[
          swatch(colors.forOrigin(origin)!, label),
          const SizedBox(width: 14),
        ],
      ],
    );
  }
}
