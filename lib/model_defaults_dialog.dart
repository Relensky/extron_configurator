import 'dart:math' as math;

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
  // Before anything is measured: the "Original File" comparison reads the
  // pre-conversion copy, and on a room converted in an earlier session that
  // copy is a file beside the config rather than something in memory.
  await provider.ensureOriginalFileConfig();
  if (!context.mounted) return;
  final mismatches =
      auditModelDefaults(provider, onlySection: onlySection);
  final messenger = ScaffoldMessenger.of(context);
  if (mismatches.isEmpty &&
      auditOriginalFile(provider, onlySection: onlySection).isEmpty) {
    if (!silentWhenClean) {
      messenger.showSnackBar(SnackBar(
        content: Text(
          onlySection == null
              ? 'Every device already matches its python module’s connection '
                  'settings.'
              : 'This device already matches its python module’s connection '
                  'settings.',
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
      'Applied $written setting${written == 1 ? '' : 's'}. '
      'Save the config to keep them.',
    ),
  ));
}

/// ============================================================================
///  THE DRIVER CHANGED. CHECK THE ROOM AGAINST IT AGAIN.
/// ============================================================================
///  Every python driver is parsed once and the answer kept — see
///  [AppStateProvider.reloadModules] for why. Which means the person who
///  maintains the drivers, editing one in the next window, is looking at an
///  app that still believes the file it read at startup: the new Update method
///  is not in the keep-alive dropdown, the port DEVICE_INFO now publishes is
///  not what the room is measured against, and nothing on screen says so.
///  Restarting the app was the only way to pick it up.
///
///  This is that, as a button. The drivers are re-read from disk and then the
///  open room is put back to them — the same review the conversion offers,
///  asked again against the files as they are now.
///
///  IT ALWAYS SAYS SOMETHING. A room that agrees with the freshly-read drivers
///  reports how many were read and that nothing moved; a button that goes
///  quiet when pressed reads as a broken button, and this one is pressed
///  precisely when somebody is unsure whether their edit landed.
///
///  NOTHING IS WRITTEN by the reload itself. The review applies only what is
///  ticked, exactly as it does after a conversion.
Future<void> offerModuleRecheck(
  BuildContext context,
  AppStateProvider provider, {
  String? onlySection,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final found = await provider.reloadModules();
  if (!context.mounted) return;

  // WITH NO ROOM OPEN there is nothing to check against, and saying "every
  // device matches" about no devices would be a lie of omission.
  if (provider.roomConfig.isEmpty) {
    messenger.showSnackBar(SnackBar(
      content: Text(
        'Re-read $found python module${found == 1 ? '' : 's'} from '
        '${provider.effectiveModulesPath}. Open a config to check it against '
        'them.',
      ),
    ));
    return;
  }

  final before = auditModelDefaults(provider, onlySection: onlySection).length;
  messenger.showSnackBar(SnackBar(
    content: Text(
      'Re-read $found python module${found == 1 ? '' : 's'}. '
      '${before == 0 ? 'Nothing in this config disagrees with them.' : '$before device${before == 1 ? '' : 's'} now disagree${before == 1 ? 's' : ''} with a driver.'}',
    ),
  ));
  if (!context.mounted) return;
  // The snack has said the count; the review says which, and is the only
  // thing that can change anything.
  await offerModelDefaults(
    context,
    provider,
    onlySection: onlySection,
  );
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
  var shown = mismatches;
  // Which connection the module is being asked about. Null means "whatever
  // each device is on", which is what the review answers by default;
  // [kOriginalFileComparison] means the pre-conversion file rather than the
  // module at all.
  String? askingAbout;
  // section -> the keys ticked right now.
  var selection = <String, Set<String>>{
    for (final m in shown) m.sectionKey: {...m.defaultSelection},
  };

  // Every style any driver in scope publishes a block for, so a device on a
  // COM port can be asked what it would look like on the network.
  final styles = comparableComTypes(provider, onlySection: onlySection);

  // Only offered when this room HAS a pre-conversion copy to read — either the
  // one this session parsed, or the `_old_config.json` the conversion left in
  // the folder. A button that opens an empty list is a button that reads as a
  // fault.
  final bool hasOriginal = provider.originalLoadedConfig.isNotEmpty &&
      auditOriginalFile(provider, onlySection: onlySection).isNotEmpty;

  if (shown.isEmpty && !hasOriginal) return 0;

  final bool? apply = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final theme = Theme.of(ctx);
        final media = MediaQuery.of(ctx);
        // The app-wide Text Size from App Config arrives as a text scaler, so
        // this is the same number the type is being multiplied by.
        final textScale = media.textScaler.scale(1.0).clamp(1.0, 2.0);
        final int ticked =
            selection.values.fold(0, (sum, keys) => sum + keys.length);

        void askAbout(String? style) {
          setLocal(() {
            askingAbout = style;
            shown = style == kOriginalFileComparison
                // A different question entirely — what the file said before
                // the conversion — answered by a different audit.
                ? auditOriginalFile(provider, onlySection: onlySection)
                : auditModelDefaults(provider,
                    onlySection: onlySection, comType: style);
            selection = {
              for (final m in shown) m.sectionKey: {...m.defaultSelection},
            };
          });
        }

        final bool onOriginal = askingAbout == kOriginalFileComparison;

        return AlertDialog(
          title: const Text(
            'Use the python module’s default connection settings?',
          ),
          // SIZED TO THE WINDOW AND TO THE TEXT, not to two numbers.
          //
          // 720x460 was fixed, so at 130% text the connection picker ran past
          // the right-hand edge and the last connection — usually Network —
          // was simply not reachable. The box now grows with the text scale
          // and stops at what the window can actually show, so a bigger type
          // size makes the dialog bigger rather than making the end of it
          // disappear.
          content: SizedBox(
            key: const ValueKey('model_defaults_content'),
            width: math.min(720 * textScale, media.size.width - 96),
            height: math.min(460 * textScale, media.size.height - 220),
            // ONE SCROLLING LIST, header and all.
            //
            // The explanation, the picker and the divider used to sit above an
            // Expanded list, which meant they took their full height first and
            // the list got whatever was left — and on a small window at 150%
            // text there was nothing left, so the header itself overflowed the
            // box. Everything is a row of the same list now, so the dialog can
            // be any size at any text scale and the worst case is a scroll
            // rather than a stripe.
            child: ListView(
              children: [
                Text(
                  'You can compare the current application device '
                  'configuration against the preset values in the python '
                  'module. Use the check boxes to transfer settings.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  onOriginal
                      ? 'Showing what the original file said before the '
                          'conversion. Nothing is ticked - the converted value '
                          'is usually the right one, so this is a list to read '
                          'before it is a list to take.'
                      : 'Connection and keep-alive settings are ticked; the '
                          'module’s own naming is not, because this room is '
                          'already named.',
                  style: theme.textTheme.bodySmall,
                ),
                // The module states its details PER CONNECTION. By default
                // each device is compared against the one it is on; this asks
                // what the same module says about another, which is how you
                // see the baud rate before moving a device onto a COM port.
                //
                // Original File comes last, after every connection, because it
                // is not one of them: it is the file this room was converted
                // FROM.
                if (styles.isNotEmpty || hasOriginal) ...[
                  const SizedBox(height: 10),
                  // A WRAP OF CHIPS, not a SegmentedButton.
                  //
                  // A segmented button lays its segments in one row and will
                  // not wrap, so the only way to fit seven of them in a fixed
                  // width was to put the row in a horizontal scroll view — and
                  // a scroll view with no visible scrollbar does not read as
                  // "there is more over here", it reads as a button that has
                  // been cut in half. Chips wrap onto a second line instead,
                  // which is the one arrangement where every connection is
                  // visible at every text size.
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text('Compare against:',
                            style: theme.textTheme.bodySmall),
                      ),
                      for (final option in <({String value, String label})>[
                        (value: '', label: 'As configured'),
                        for (final s in styles) (value: s, label: s),
                        if (hasOriginal)
                          (
                            value: kOriginalFileComparison,
                            label: kOriginalFileComparison,
                          ),
                      ])
                        ChoiceChip(
                          key: ValueKey('compare_${option.value}'),
                          label: Text(option.label),
                          visualDensity: VisualDensity.compact,
                          selected: (askingAbout ?? '') == option.value,
                          onSelected: (_) => askAbout(
                              option.value.isEmpty ? null : option.value),
                        ),
                    ],
                  ),
                ],
                const Divider(height: 16),
                if (shown.every((m) => m.diffs.isEmpty))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      onOriginal
                          ? 'Nothing here differs from the original file.'
                          : askingAbout == null
                              ? 'Every device already matches its python module '
                                  'on the connection it is using. Pick a '
                                  'connection above to see what the module says '
                                  'about that one.'
                              : 'Nothing to change for a $askingAbout '
                                  'connection - the block already says what the '
                                  'module does.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                for (final m in shown) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 2),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  m.model.isEmpty
                                      ? m.name
                                      : '${m.name}  ·  ${m.model}',
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
