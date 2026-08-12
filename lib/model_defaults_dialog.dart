import 'package:flutter/material.dart';

import 'app_state.dart';
import 'model_defaults_audit.dart';

/// The post-conversion review: every device whose block disagrees with the
/// driver its model names, and the chance to take the driver's answer.
///
/// Asked rather than applied. A converted room is somebody's working document
/// — the addresses are real, the names have been agreed, and a tool that
/// quietly rewrote a port because a driver file says so would be a tool nobody
/// converts with twice. The connection and keep-alive keys come up ticked
/// because they are facts about the model; the driver's naming comes up
/// unticked because the room already has names.
///
/// Returns the number of properties written, or 0 when nothing was.
Future<int> showModelDefaultsDialog(
  BuildContext context,
  AppStateProvider provider,
  List<ModelDefaultMismatch> mismatches,
) async {
  if (mismatches.isEmpty) return 0;
  // section -> the keys ticked right now.
  final selection = <String, Set<String>>{
    for (final m in mismatches) m.sectionKey: {...m.defaultSelection},
  };

  final bool? apply = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final theme = Theme.of(ctx);
        final int ticked =
            selection.values.fold(0, (sum, keys) => sum + keys.length);
        return AlertDialog(
          title: const Text('Use the driver’s connection details?'),
          content: SizedBox(
            width: 720,
            height: 460,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'These devices name a model whose python driver states how '
                  'it is reached. The conversion filled them from the family '
                  'defaults instead, which is right for most of the family and '
                  'wrong for the exceptions.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Connection and keep-alive settings are ticked; the driver’s '
                  'own naming is not, because this room is already named.',
                  style: theme.textTheme.bodySmall,
                ),
                const Divider(height: 16),
                Expanded(
                  child: ListView(
                    children: [
                      for (final m in mismatches) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 2),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${m.name}  ·  ${m.model}',
                                  style: theme.textTheme.titleSmall,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                m.sectionKey,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.disabledColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                        for (final d in m.diffs)
                          CheckboxListTile(
                            key: ValueKey('model_default_${m.sectionKey}_${d.key}'),
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: selection[m.sectionKey]!.contains(d.key),
                            onChanged: (v) => setLocal(() {
                              if (v == true) {
                                selection[m.sectionKey]!.add(d.key);
                              } else {
                                selection[m.sectionKey]!.remove(d.key);
                              }
                            }),
                            title: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: d.key,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  TextSpan(
                                    text: '   ${d.currentText}  →  '
                                        '${d.proposedText}',
                                    style: TextStyle(
                                      color: theme.textTheme.bodySmall?.color,
                                    ),
                                  ),
                                ],
                              ),
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Keep what the file has'),
            ),
            ElevatedButton(
              key: const ValueKey('model_defaults_apply'),
              onPressed: ticked == 0
                  ? null
                  : () => Navigator.of(ctx).pop(true),
              child: Text('Apply $ticked change${ticked == 1 ? '' : 's'}'),
            ),
          ],
        );
      },
    ),
  );

  if (apply != true) return 0;

  int written = 0;
  for (final m in mismatches) {
    final keys = selection[m.sectionKey] ?? const <String>{};
    if (keys.isEmpty) continue;
    written += provider
        .applyModelDefaultValues(m.sectionKey, {
          for (final d in m.diffs)
            if (keys.contains(d.key)) d.key: d.fromModule,
        })
        .length;
  }
  return written;
}
