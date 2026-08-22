import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app_snack.dart';
import 'app_state.dart';

/// ============================================================================
///  "THE APP CLOSED WITH WORK IN IT" — THE PROMPT ON THE WAY BACK IN
/// ============================================================================
///  The recovery copy the autosave keeps (see the AUTOSAVE section of
///  app_state.dart) only survives a session that ended badly: a save deletes
///  it, and so does closing the app deliberately without saving. So finding one
///  beside a file that has just been opened means something specific — the app
///  went away mid-edit — and the honest thing to do is say so and show exactly
///  what the difference is.
///
///  It is shown the way the conversion log is shown: a list of every property
///  that would change, in the file's own language, BEFORE anything changes.
///  "Restore your unsaved work?" with a Yes and a No is not enough information
///  to answer with — the two candidates are somebody's afternoon and somebody
///  else's last known-good file, and which is which is the whole question.
///
///  Restoring puts the copy into MEMORY. The file is not touched until Save,
///  which means the answer to this dialog is never irreversible.
/// ============================================================================

/// One line of the difference list, written from the FILE's point of view:
/// what accepting the recovery copy would do to what is on screen now.
///
/// [ConfigDelta.summary] says the same thing in the Undo dialog's language
/// ("added by the save, would be removed"), which is the wrong story here — the
/// two dialogs compare different pairs of documents.
String recoveryLine(ConfigDelta delta) {
  String show(dynamic v) {
    if (v == null) return 'nothing';
    if (v is Map) return '{${v.length} propert${v.length == 1 ? 'y' : 'ies'}}';
    if (v is List) return '[${v.length} item${v.length == 1 ? '' : 's'}]';
    return v is String ? '"$v"' : v.toString();
  }

  switch (delta.kind) {
    case DeltaKind.added:
      return '${delta.label} — not in the file, would be added: '
          '${show(delta.after)}';
    case DeltaKind.removed:
      return '${delta.label} — in the file, would be removed: '
          '${show(delta.before)}';
    case DeltaKind.changed:
      return '${delta.label} — ${show(delta.before)} would become '
          '${show(delta.after)}';
  }
}

/// How long ago the copy was taken, in the only unit anybody wants at that
/// moment.
String recoveryAge(DateTime takenAt) {
  final gap = DateTime.now().difference(takenAt);
  if (gap.inMinutes < 1) return 'less than a minute ago';
  if (gap.inMinutes < 60) {
    return '${gap.inMinutes} minute${gap.inMinutes == 1 ? '' : 's'} ago';
  }
  if (gap.inHours < 24) {
    return '${gap.inHours} hour${gap.inHours == 1 ? '' : 's'} ago';
  }
  final days = gap.inDays;
  return '$days day${days == 1 ? '' : 's'} ago';
}

/// Shows the pending recovery copy and acts on the answer.
///
/// Three answers, and none of them writes to the user's file:
///
///   * **Restore** loads the copy into the editor and leaves the room dirty,
///     so the next Save is a deliberate one.
///   * **Keep the file** throws the copy away for good — the answer for
///     somebody who knows the file is the version they want.
///   * **Not now** leaves both alone. The copy is still there next time, which
///     is the right default for a dialog somebody wants to think about.
Future<void> showRecoveryDialog(
  BuildContext context,
  AppStateProvider provider,
) async {
  final found = provider.pendingRecovery;
  if (found == null) return;

  final messenger = ScaffoldMessenger.of(context);
  final name = found.origin.isEmpty ? found.noun : p.basename(found.origin);

  final answer = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('recovery_dialog'),
      title: Row(children: [
        const Icon(Icons.restore_page, color: Colors.orange),
        const SizedBox(width: 10),
        Expanded(
          child: Text('Unsaved work found for this $name',
              style: Theme.of(ctx).textTheme.titleLarge),
        ),
      ]),
      content: SizedBox(
        width: 640,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The app closed while this ${found.noun} had unsaved changes. '
              'A working copy from ${recoveryAge(found.takenAt)} is still '
              'here, and it differs from the file in ${found.deltas.length} '
              'place${found.deltas.length == 1 ? '' : 's'}:',
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Theme.of(ctx).dividerColor),
                ),
                child: Scrollbar(
                  child: ListView.builder(
                    itemCount: found.deltas.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        recoveryLine(found.deltas[i]),
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Restoring puts the copy on screen — ${found.origin.isEmpty ? 'the '
                  'file' : p.basename(found.origin)} is not written until you '
                  'press Save.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('recovery_later'),
          onPressed: () => Navigator.pop(ctx, 'later'),
          child: const Text('Not now'),
        ),
        TextButton(
          key: const ValueKey('recovery_discard'),
          onPressed: () => Navigator.pop(ctx, 'discard'),
          child: const Text('Keep the file'),
        ),
        FilledButton.icon(
          key: const ValueKey('recovery_restore'),
          icon: const Icon(Icons.restore, size: 18),
          label: const Text('Restore the unsaved work'),
          onPressed: () => Navigator.pop(ctx, 'restore'),
        ),
      ],
    ),
  );

  switch (answer) {
    case 'restore':
      provider.applyRecovery(found);
      showTimedSnackBar(
        messenger,
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            'Recovered work is on screen. $name has NOT been written yet — '
            'check it, then press Save.',
          ),
        ),
      );
    case 'discard':
      provider.discardPendingRecovery();
      showTimedSnackBar(
        messenger,
        const SnackBar(content: Text('Recovery copy discarded.')),
      );
    default:
      // 'later', and anything else: leave the copy where it is.
      provider.dismissPendingRecovery();
  }
}
