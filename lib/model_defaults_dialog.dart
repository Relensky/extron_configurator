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
/// Puts the driver-defaults question to the user, if there is one to put.
///
/// Separate from the acknowledgement dialog that calls it so the same review
/// can be reached again later without re-running a conversion — the answer
/// "not now" has to be recoverable, and the Devices tab's "Check module
/// defaults" button is the way back to it.
///
/// [onlySection] scopes the review to one device block. Pass it from the
/// Devices tab, where the question is about the device on screen; leave it off
/// after a conversion, where it is about the whole file.
///
/// [silentWhenClean] false says so when there is nothing to change — a button
/// that does nothing visible when pressed reads as a broken button.
Future<void> offerModelDefaults(
  BuildContext context,
  AppStateProvider provider, {
  bool silentWhenClean = true,
  String? onlySection,
}) async {
  final mismatches =
      auditModelDefaults(provider, onlySection: onlySection);
  final messenger = ScaffoldMessenger.of(context);
  if (mismatches.isEmpty) {
    if (!silentWhenClean) {
      messenger.showSnackBar(SnackBar(
        content: Text(
          onlySection == null
              ? 'Every device already matches its driver’s connection details.'
              : 'This device already matches its driver’s connection details.',
        ),
      ));
    }
    return;
  }
  final written = await showModelDefaultsDialog(context, provider, mismatches,
      onlySection: onlySection);
  if (written == 0) return;
  messenger.showSnackBar(SnackBar(
    content: Text(
      'Applied $written driver default${written == 1 ? '' : 's'}. '
      'Save the config to keep them.',
    ),
  ));
}

/// Returns the number of properties written, or 0 when nothing was.
Future<int> showModelDefaultsDialog(
  BuildContext context,
  AppStateProvider provider,
  List<ModelDefaultMismatch> mismatches, {
  /// Set when the review was opened for ONE device, which is what makes the
  /// connection picker meaningful: re-running the audit for another style is
  /// only a sensible question about a single block.
  String? onlySection,
}) async {
  if (mismatches.isEmpty) return 0;
  var shown = mismatches;
  // Which connection the driver is being asked about. Null means "whatever
  // each device is on", which is what the review answers by default.
  String? askingAbout;
  // section -> the keys ticked right now.
  var selection = <String, Set<String>>{
    for (final m in shown) m.sectionKey: {...m.defaultSelection},
  };

  // Every style any driver in this review publishes a block for, so a device
  // on a COM port can be asked what it would look like on the network.
  final styles = <String>{
    for (final m in shown) ...m.availableComTypes,
  }.toList()
    ..sort((a, b) => kComTypeStyleLabels.values
        .toList()
        .indexOf(a)
        .compareTo(kComTypeStyleLabels.values.toList().indexOf(b)));

  final bool? apply = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final theme = Theme.of(ctx);
        final int ticked =
            selection.values.fold(0, (sum, keys) => sum + keys.length);

        void askAbout(String? style) {
          setLocal(() {
            askingAbout = style;
            shown = auditModelDefaults(provider,
                onlySection: onlySection, comType: style);
            selection = {
              for (final m in shown) m.sectionKey: {...m.defaultSelection},
            };
          });
        }

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
                // The driver states its details PER CONNECTION. By default
                // each device is compared against the one it is on; this asks
                // what the same driver says about another, which is how you
                // see the baud rate before moving a device onto a COM port.
                if (styles.length > 1) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text('Compare against:',
                          style: theme.textTheme.bodySmall),
                      const SizedBox(width: 10),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SegmentedButton<String>(
                            style: const ButtonStyle(
                                visualDensity: VisualDensity.compact),
                            segments: [
                              const ButtonSegment(
                                value: '',
                                label: Text('Its own connection'),
                              ),
                              for (final s in styles)
                                ButtonSegment(value: s, label: Text(s)),
                            ],
                            selected: {askingAbout ?? ''},
                            onSelectionChanged: (v) => askAbout(
                                v.first.isEmpty ? null : v.first),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const Divider(height: 16),
                if (shown.every((m) => m.diffs.isEmpty))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      askingAbout == null
                          ? 'Every device already matches its driver on the '
                              'connection it is using. Pick a connection above '
                              'to see what the driver says about that one.'
                          : 'Nothing to change for a $askingAbout connection — '
                              'the block already says what the driver does.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final m in shown) ...[
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
                              // Which connection these figures describe. Worth
                              // saying on every row: the same driver answers
                              // differently for a COM port and a network port.
                              if (m.comType.isNotEmpty)
                                Text(
                                  '${m.comType}  ·  ',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.primary,
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
  // What is on SCREEN when Apply is pressed, not what the review opened with:
  // the connection picker can have replaced the whole list since then.
  for (final m in shown) {
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
