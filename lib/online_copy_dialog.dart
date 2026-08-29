import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import 'app_snack.dart';
import 'app_state.dart';
import 'contrast.dart';
import 'online_copy.dart';
import 'online_roundtrip.dart';

/// ============================================================================
///  PUBLISHING THE JOB WHERE OTHER PEOPLE CAN READ IT
/// ============================================================================
///  The box behind the Project tab's "Online copy" button. It asks for one
///  thing — which folder — and then does the same thing every time it is
///  pressed afterwards.
///
///  A FOLDER, NOT AN ACCOUNT. OneDrive and Google Drive both keep a folder on
///  this machine in step with the cloud, so a file written into one is a file
///  that opens in Excel Online or as a Google Sheet minutes later. That is why
///  there is nothing here to sign into, nothing to renew, and nothing that
///  stops working when somebody's password changes — see online_copy.dart.
///
///  IT SAYS OUT LOUD THAT IT ONLY GOES ONE WAY. The single thing a person can
///  reasonably assume about a spreadsheet in a shared folder is that typing in
///  it does something. Here it does not: the copy is overwritten on the next
///  publish, and this box says so before it writes anything, because finding
///  that out afterwards means finding it out by losing an afternoon of
///  somebody's edits.
/// ============================================================================

// ---------------------------------------------------------------------------
//  THE OTHER TWO SCOPES
// ---------------------------------------------------------------------------
//  A job is not the only thing somebody asks about. "What is in BSS 103" is a
//  room, and "what does the estate need replacing next year" is a campus — and
//  both were answerable only by somebody sitting at this machine.
//
//  All three publish into the SAME folder, under names that sort beside each
//  other: `<Campus>_campus.xlsx`, `<Job>_project.xlsx`, `BSS_103_room.xlsx`,
//  each with its .json next to it. That is what makes the folder read as one
//  set of records rather than three features' output — and because every file
//  in it is either a spreadsheet or plain JSON, it stays a set of records
//  anybody can open, edit and keep after this app is gone.

/// The folder everything publishes into, asking for one if the app has none.
///
/// Returns '' when the question was cancelled, which is a complete answer:
/// nothing is published and nothing is said.
Future<String> ensureOnlineFolder(
  BuildContext context,
  AppStateProvider provider,
) async {
  final known = provider.onlineFolder.trim();
  if (known.isNotEmpty) return known;
  final picked = await FilePicker.getDirectoryPath(
    dialogTitle: 'Which folder does OneDrive or Google Drive sync?',
  );
  if (picked == null) return '';
  provider.setOnlineFolder(picked);
  return picked;
}

/// Publishes the room that is open.
Future<void> publishRoomCopy(
  BuildContext context,
  AppStateProvider provider,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);
  final folder = await ensureOnlineFolder(context, provider);
  if (folder.isEmpty) return;

  final result = await provider.publishRoomOnlineCopy(folder: folder);
  _report(messenger, theme, provider, result, 'The room');
}

/// Publishes a campus sheet. The workbook is built by the campus screen, which
/// is the only thing holding the model and the picture it is drawn from.
Future<void> publishCampusCopy(
  BuildContext context,
  AppStateProvider provider, {
  required Uint8List workbook,
  required String stem,
  String campusFilePath = '',
  String name = '',
  List<({String path, String name})> jobs = const [],
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final theme = Theme.of(context);
  final folder = await ensureOnlineFolder(context, provider);
  if (folder.isEmpty) return;

  final result = await provider.publishCampusOnlineCopy(
    workbook: workbook,
    stem: stem,
    folder: folder,
    campusFilePath: campusFilePath,
    name: name,
    jobs: jobs,
  );
  _report(messenger, theme, provider, result, 'The campus sheet');
}

/// What a publish says afterwards, the same way for all three scopes.
void _report(
  ScaffoldMessengerState messenger,
  ThemeData theme,
  AppStateProvider provider,
  OnlineCopyResult result,
  String what,
) {
  if (result.written.isEmpty) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          '$what could not be published: ${result.failed.join('; ')}',
        ),
        backgroundColor: snackErrorFillOn(messenger),
      ),
    );
    return;
  }
  showSavedSnackBar(
    messenger: messenger,
    theme: theme,
    provider: provider,
    message: '$what is online in ${path.basename(result.folder)}',
    savedPath: result.folder,
    isFolder: true,
  );
}

/// Opens the publish box.
Future<void> showOnlineCopyDialog(
  BuildContext context,
  AppStateProvider provider,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _OnlineCopyDialog(provider: provider),
  );
}

class _OnlineCopyDialog extends StatefulWidget {
  final AppStateProvider provider;

  const _OnlineCopyDialog({required this.provider});

  @override
  State<_OnlineCopyDialog> createState() => _OnlineCopyDialogState();
}

class _OnlineCopyDialogState extends State<_OnlineCopyDialog> {
  late String _folder = widget.provider.project.onlineFolder;

  /// Write the project file beside the workbook.
  ///
  /// On by default: it is what makes the folder enough to OPEN the job on
  /// another machine rather than only enough to read a spreadsheet, and it
  /// costs one small file.
  bool _includeProject = true;

  bool _busy = false;
  String _result = '';
  bool _failed = false;

  Future<void> _pickFolder() async {
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: 'Which folder does OneDrive or Google Drive sync?',
    );
    if (picked == null || !mounted) return;
    setState(() => _folder = picked);
  }

  Future<void> _publish() async {
    if (_folder.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _result = '';
      _failed = false;
    });
    final result = await widget.provider.publishOnlineCopy(
      folder: _folder,
      includeProjectFile: _includeProject,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _failed = result.written.isEmpty;
      _result = result.written.isEmpty
          ? 'Nothing could be written: ${result.failed.join('; ')}'
          : result.failed.isEmpty
          ? '${result.written.join(' and ')} written.'
          : '${result.written.join(' and ')} written. '
                'Failed: ${result.failed.join('; ')}';
    });
  }

  /// Reads the published workbook back and offers what it would change.
  ///
  /// The published file when it is there, and a file picker when it is not —
  /// because the copy that comes back is not always the one in the folder. It
  /// is just as often the one somebody downloaded out of Excel Online and
  /// emailed, and refusing that would send them back to retyping it.
  Future<void> _pull() async {
    var file = _folder.trim().isEmpty
        ? ''
        : path.join(_folder.trim(), onlineWorkbookName(widget.provider.project));
    if (file.isEmpty || !File(file).existsSync()) {
      final picked = await FilePicker.pickFiles(
        dialogTitle: 'Which workbook has the updates in it?',
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
      );
      final chosen = picked?.files.singleOrNull?.path;
      if (chosen == null) return;
      file = chosen;
    }

    setState(() => _busy = true);
    ({OnlineImport read, List<OnlineChange> changes})? review;
    String? error;
    try {
      final bytes = await File(file).readAsBytes();
      review = widget.provider.reviewOnlineImport(bytes);
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() => _busy = false);

    if (error != null || review == null) {
      setState(() {
        _failed = true;
        _result = 'That file could not be read: $error';
      });
      return;
    }
    if (review.read.wrongFile) {
      setState(() {
        _failed = true;
        _result =
            'That workbook has no "$kEditableDeliveriesSheet" sheet in it, so '
            'there is nothing to read back. Publish this job first, and edit '
            'the copy that comes out.';
      });
      return;
    }

    final applied = await showDialog<int>(
      context: context,
      builder: (_) => _ImportReviewDialog(
        provider: widget.provider,
        read: review!.read,
        changes: review.changes,
        source: file,
      ),
    );
    if (!mounted || applied == null) return;
    setState(() {
      _failed = false;
      _result = applied == 0
          ? 'Nothing to bring back - the copy matches the job.'
          : '$applied change${applied == 1 ? '' : 's'} brought back in.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final project = widget.provider.project;
    final surface =
        theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface;
    final ready = _folder.trim().isNotEmpty && !_busy;

    return AlertDialog(
      key: const ValueKey('online_copy_dialog'),
      title: const Text('Online copy'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Writes the project workbook into a folder that OneDrive or '
                'Google Drive keeps in sync, so the job can be read in Excel '
                'Online or opened as a Google Sheet by anybody the folder is '
                'shared with.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              // The two things somebody has to know before they rely on it,
              // and both are easier to say now than to explain afterwards.
              _Point(
                icon: Icons.link,
                text: 'The same file name is rewritten every time, so a share '
                    'link sent once keeps opening the current figures.',
              ),
              _Point(
                icon: Icons.sync_alt,
                text: 'Two sheets in it - "$kEditableDeliveriesSheet" and '
                    '"$kEditablePosSheet" - can be typed in and pulled back '
                    'with the button below. Everything else is a picture of '
                    'the job and is overwritten on the next publish.',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Folder',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      child: Text(
                        _folder.trim().isEmpty
                            ? 'None picked yet'
                            : _folder.trim(),
                        key: const ValueKey('online_copy_folder'),
                        overflow: TextOverflow.ellipsis,
                        style: _folder.trim().isEmpty
                            ? theme.textTheme.bodyMedium?.copyWith(
                                fontStyle: FontStyle.italic,
                                color: muted,
                              )
                            : theme.textTheme.bodyMedium,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('online_copy_pick'),
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Choose'),
                    onPressed: _busy ? null : _pickFolder,
                  ),
                ],
              ),
              CheckboxListTile(
                key: const ValueKey('online_copy_include_project'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _includeProject,
                title: const Text('Put the project file there too'),
                subtitle: Text(
                  'A copy of ${onlineProjectFileName(project)}, so the job can '
                  'be opened from the folder on another machine as well as '
                  'read as a spreadsheet.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _includeProject = v ?? false),
              ),
              CheckboxListTile(
                key: const ValueKey('online_copy_auto'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: project.onlineAutoPublish,
                title: const Text('Update it every time the project is saved'),
                subtitle: Text(
                  _folder.trim().isEmpty
                      ? 'Pick a folder first - there would be nowhere to '
                            'write.'
                      : 'The copy people are reading is never older than your '
                            'last save.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
                onChanged: (_busy || _folder.trim().isEmpty)
                    ? null
                    : (v) => setState(() {
                        // The folder has to be on the job before the switch
                        // can mean anything, and it may only have been picked
                        // a moment ago in this box.
                        widget.provider.setProjectOnlineFolder(_folder);
                        widget.provider.setProjectOnlineAutoPublish(v ?? false);
                      }),
              ),
              const SizedBox(height: 8),
              Text(
                'Writes ${onlineWorkbookName(project)}'
                '${_includeProject ? ' and ${onlineProjectFileName(project)}' : ''}'
                '.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              const SizedBox(height: 4),
              Text(
                onlineFreshnessText(project.onlinePublishedAt),
                key: const ValueKey('online_copy_freshness'),
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              if (_result.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _result,
                  key: const ValueKey('online_copy_result'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _failed
                        ? errorTextOn(theme.colorScheme, surface)
                        : successOn(surface),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        // PULLING IS AS PROMINENT AS PUBLISHING, because the whole point of a
        // sheet somebody can type in is that what they typed comes back.
        OutlinedButton.icon(
          key: const ValueKey('online_copy_pull'),
          icon: const Icon(Icons.download_outlined, size: 18),
          label: const Text('Pull updates'),
          onPressed: _busy ? null : _pull,
        ),
        FilledButton.icon(
          key: const ValueKey('online_copy_publish'),
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_sync_outlined, size: 18),
          label: Text(
            project.onlinePublishedAt == null ? 'Publish' : 'Update it',
          ),
          onPressed: ready ? _publish : null,
        ),
      ],
    );
  }
}

/// What an import would do, before it does any of it.
///
/// SHOWN EVERY TIME, with no way to skip it. An import is somebody else's
/// typing arriving in your job: a list of exactly what it would change,
/// checked once, is the difference between a feature people use and one they
/// are right to be frightened of. Nothing here is written until Apply.
class _ImportReviewDialog extends StatefulWidget {
  final AppStateProvider provider;
  final OnlineImport read;
  final List<OnlineChange> changes;

  /// The file it came out of, so the box can say what it is looking at.
  final String source;

  const _ImportReviewDialog({
    required this.provider,
    required this.read,
    required this.changes,
    required this.source,
  });

  @override
  State<_ImportReviewDialog> createState() => _ImportReviewDialogState();
}

class _ImportReviewDialogState extends State<_ImportReviewDialog> {
  bool _busy = false;

  Future<void> _apply() async {
    setState(() => _busy = true);
    final touched = widget.provider.applyOnlineImport(widget.read);
    if (!mounted) return;
    Navigator.of(context).pop(touched);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final surface =
        theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface;
    final changes = widget.changes;
    final problems = widget.read.problems;

    return AlertDialog(
      key: const ValueKey('online_import_dialog'),
      title: Text(
        changes.isEmpty
            ? 'Nothing to bring back'
            : '${changes.length} change${changes.length == 1 ? '' : 's'} to '
                  'bring back',
      ),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'From ${path.basename(widget.source)}.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            if (changes.isEmpty)
              Text(
                'Every row in that copy already matches the job.',
                key: const ValueKey('online_import_nothing'),
                style: theme.textTheme.bodyMedium,
              )
            else
              Flexible(
                child: SizedBox(
                  height: 260,
                  child: ListView.builder(
                    key: const ValueKey('online_import_changes'),
                    itemCount: changes.length,
                    itemBuilder: (context, i) {
                      final c = changes[i];
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: Icon(
                          c.id.isEmpty ? Icons.add_circle_outline : Icons.edit,
                          size: 18,
                          color: muted,
                        ),
                        title: Text(c.name),
                        subtitle: Text(
                          '${c.kind} - ${c.what}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            if (problems.isNotEmpty) ...[
              const Divider(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber,
                    size: 16,
                    color: warningOn(surface),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      // NOT SILENTLY DROPPED. A cell this could not read left
                      // the record alone; saying which one, and why, is what
                      // lets somebody go and fix the sheet rather than wonder
                      // why their edit did not arrive.
                      problems.join('\n'),
                      key: const ValueKey('online_import_problems'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: warningOn(surface),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const Divider(height: 20),
            Text(
              'Nothing is ever deleted by an import: a row missing from the '
              'sheet is one somebody filtered or never scrolled to.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('online_import_apply'),
          onPressed: (changes.isEmpty || _busy) ? null : _apply,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
/// One line of "here is what this actually does", with its icon.
class _Point extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Point({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}
