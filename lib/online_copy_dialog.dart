import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;

import 'file_dialogs.dart';
import 'app_snack.dart';
import 'in_app_browser.dart';
import 'app_state.dart';
import 'contrast.dart';
import 'cost_estimate.dart' show formatMoney;
import 'google_sheets_live.dart';
import 'online_copy.dart';
import 'online_pull_history.dart';
import 'online_roundtrip.dart';
import 'online_sheet_merge.dart';

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
///  MOST OF IT GOES ONE WAY, AND IT SAYS SO. The single thing a person can
///  reasonably assume about a spreadsheet in a shared folder is that typing in
///  it does something. On most of these sheets it does not: the copy is
///  overwritten on the next publish, and this box says so before it writes
///  anything, because finding that out afterwards means finding it out by
///  losing an afternoon of somebody's edits.
///
///  THE EXCEPTION IS THE TWO SHEETS THAT COME BACK — the delivery log and the
///  purchase orders, which are a form rather than a report (see
///  online_roundtrip.dart). Typing in those does do something, and a publish
///  that would write over it stands down and asks first: see
///  [offerHeldOnlineEdits] at the foot of this file.
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
/// Returns '' when the question was canceled, which is a complete answer:
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

  /// The Sheet's link or id, as typed. Blank has the publish make one.
  late final TextEditingController _sheetText = TextEditingController(
    text: widget.provider.project.onlineSheetId.isEmpty
        ? ''
        : liveSheetUrl(widget.provider.project.onlineSheetId),
  );

  bool get _toFolder => !widget.provider.project.onlineFolderOff;
  bool get _toSheet => widget.provider.project.onlineSheetOn;
  bool get _hasGoogleClient => widget.provider.hasGoogleClient;

  /// Somewhere to write: a folder that is picked, or the Sheet.
  bool get _hasDestination =>
      (_toFolder && _folder.trim().isNotEmpty) || _toSheet;

  /// The folder, typed or picked. Editable, so a long path can be read and
  /// fixed in place.
  late final TextEditingController _folderText =
      TextEditingController(text: _folder);

  @override
  void dispose() {
    _folderText.dispose();
    _sheetText.dispose();
    super.dispose();
  }

  /// Where the folder picker opens: the job's folder when it exists, else the
  /// folder the project file is in.
  String? get _startFolder {
    final typed = _folder.trim();
    if (typed.isNotEmpty && Directory(typed).existsSync()) return typed;
    final projectPath = widget.provider.currentProjectPath;
    return projectPath.isEmpty ? null : path.dirname(projectPath);
  }

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
      initialDirectory: _startFolder,
    );
    if (picked == null || !mounted) return;
    _folderText.text = picked;
    setState(() => _folder = picked);
  }

  Future<void> _publish() async {
    if (!_hasDestination) return;
    setState(() {
      _busy = true;
      _result = '';
      _failed = false;
    });
    final toFolder = _toFolder && _folder.trim().isNotEmpty;
    if (_toSheet) widget.provider.setProjectOnlineSheet(_sheetText.text);
    if (!await _mergeBeforePublish()) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failed = true;
        _result = 'Not published: the online copy has edits in it that were '
            'not dealt with. Nothing was written over.';
      });
      return;
    }
    if (!mounted) return;
    final result = await widget.provider.publishOnlineCopy(
      folder: toFolder ? _folder : null,
      includeProjectFile: _includeProject,
      // Pressed by a person, so the Google sign-in may open the browser.
      interactive: true,
    );
    if (!mounted) return;
    // A Sheet made just now has a link to show.
    final id = widget.provider.project.onlineSheetId;
    if (id.isNotEmpty) _sheetText.text = liveSheetUrl(id);
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
    // The Sheet first when the job has one, then the file as before.
    final id = widget.provider.project.onlineSheetId.trim();
    if (_toSheet && id.isNotEmpty) {
      await _pullSheet();
      if (!mounted || !_toFolder || _folder.trim().isEmpty) return;
    }
    var file = _folder.trim().isEmpty
        ? ''
        : path.join(_folder.trim(), onlineWorkbookName(widget.provider.project));
    if (file.isEmpty || !File(file).existsSync()) {
      final picked = await pickFilesCompat(
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
      // The three tabs that are read back, and what was typed in the others.
      review = widget.provider.reviewOnlineWorkbook(bytes);
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

    await _offer(review, file);
  }

  /// Shows what [review] would change and says what came of it.
  Future<void> _offer(
    ({OnlineImport read, List<OnlineChange> changes}) review,
    String source,
  ) async {
    final applied = await showDialog<int>(
      context: context,
      builder: (_) => _ImportReviewDialog(
        provider: widget.provider,
        read: review.read,
        changes: review.changes,
        source: source,
      ),
    );
    if (!mounted || applied == null) return;
    final listed = listedOnlyChanges(review.changes).length;
    setState(() {
      _failed = false;
      _result = [
        if (applied > 0)
          '$applied change${applied == 1 ? '' : 's'} brought back in.',
        if (listed > 0)
          '$listed edit${listed == 1 ? '' : 's'} in other tabs listed in the '
              'history file - make ${listed == 1 ? 'it' : 'them'} in the app.',
        if (applied == 0 && listed == 0)
          'Nothing to bring back - the copy matches the job.',
      ].join(' ');
    });
  }

  /// NOTHING IS WRITTEN OVER UNSEEN. Before a publish pressed by hand, both
  /// copies are checked for typing since the last one, exactly as a save
  /// checks them; whatever is found is listed, brought in or kept in the
  /// history, and only then written over. False when the person backed out.
  Future<bool> _mergeBeforePublish() async {
    final provider = widget.provider;
    final toFolder = _toFolder && _folder.trim().isNotEmpty;
    for (final sheet in [true, false]) {
      if (sheet ? !_toSheet : !toFolder) continue;
      final held = await provider.findHeldOnlineEdits(
        folder: sheet ? null : _folder,
        folderCopy: !sheet,
        sheetCopy: sheet,
      );
      if (held == null) continue;
      if (!mounted) return false;
      final applied = await showDialog<int>(
        context: context,
        builder: (_) => _ImportReviewDialog(
          provider: provider,
          read: held.read,
          changes: held.changes,
          source: held.sheet ? kOnlineSheetLabel : held.file,
          beforePublish: true,
        ),
      );
      if (applied == null) return false;
    }
    return true;
  }

  /// Reads the live Google Sheet back and offers what it would change.
  Future<void> _pullSheet() async {
    setState(() => _busy = true);
    ({OnlineImport read, List<OnlineChange> changes})? review;
    String? error;
    try {
      // The three tabs that are read back, and what was typed in the others.
      review = await widget.provider.reviewLiveSheet();
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (review == null) {
      setState(() {
        _failed = true;
        _result = 'The Google Sheet could not be read: $error';
      });
      return;
    }
    if (review.read.wrongFile) {
      setState(() {
        _failed = true;
        _result = 'That Sheet has no "$kEditableDeliveriesSheet" tab in it, '
            'so there is nothing to read back. Publish this job to it first.';
      });
      return;
    }
    await _offer(review, kOnlineSheetLabel);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final project = widget.provider.project;
    final surface =
        theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface;
    final ready = _hasDestination && !_busy;

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
                'Puts the project workbook where other people can read it: a '
                'folder that OneDrive or Google Drive keeps in sync, one '
                'Google Sheet kept current, or both.',
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
              const SizedBox(height: 8),
              // THE TWO PLACES IT CAN GO. Either, or both at once.
              CheckboxListTile(
                key: const ValueKey('online_copy_to_folder'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _toFolder,
                title: const Text('A synced folder (OneDrive or Google Drive)'),
                subtitle: Text(
                  'An .xlsx that opens in Excel Online, rewritten in place.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
                onChanged: _busy
                    ? null
                    : (v) => setState(
                        () => widget.provider.setProjectOnlineToFolder(
                          v ?? false,
                        ),
                      ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('online_copy_folder'),
                      controller: _folderText,
                      enabled: !_busy && _toFolder,
                      decoration: const InputDecoration(
                        labelText: 'Folder',
                        hintText: 'None picked yet - type a path or choose one',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (v) => setState(() => _folder = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('online_copy_pick'),
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Choose'),
                    onPressed: _busy || !_toFolder ? null : _pickFolder,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                key: const ValueKey('online_copy_to_sheet'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _toSheet,
                title: const Text('A live Google Sheet'),
                subtitle: Text(
                  _hasGoogleClient
                      ? 'One Sheet, written cell by cell. Everybody who opens '
                            'this job publishes to the same one - share it '
                            'with them in Google as editors.'
                      : 'Needs Google sign-in, which this copy lacks - App '
                            'Config > Working together > Advanced.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
                onChanged: _busy || (!_hasGoogleClient && !_toSheet)
                    ? null
                    : (v) => setState(
                        () => widget.provider.setProjectOnlineToSheet(
                          v ?? false,
                        ),
                      ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('online_copy_sheet'),
                      controller: _sheetText,
                      enabled: !_busy && _toSheet,
                      decoration: const InputDecoration(
                        labelText: 'Sheet link',
                        hintText: 'Blank - a new Sheet is made on the first '
                            'publish',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('online_copy_sheet_open'),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Open'),
                    onPressed: project.onlineSheetId.isEmpty
                        ? null
                        : () => openWebLink(
                            context,
                            liveSheetUrl(project.onlineSheetId),
                            title: 'Google Sheet',
                          ),
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
                onChanged: _busy || !_toFolder
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
                  !_hasDestination
                      ? 'Pick a folder or the Sheet first - there would be '
                            'nowhere to write.'
                      : 'The copy people are reading is never older than your '
                            'last save.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
                onChanged: (_busy || !_hasDestination)
                    ? null
                    : (v) => setState(() {
                        // The folder has to be on the job before the switch
                        // can mean anything, and it may only have been picked
                        // a moment ago in this box.
                        if (_toFolder && _folder.trim().isNotEmpty) {
                          widget.provider.setProjectOnlineFolder(_folder);
                        }
                        widget.provider.setProjectOnlineAutoPublish(v ?? false);
                      }),
              ),
              const SizedBox(height: 8),
              Text(
                [
                  if (_toFolder && _folder.trim().isNotEmpty)
                    'Writes ${onlineWorkbookName(project)}'
                        '${_includeProject ? ' and ${onlineProjectFileName(project)}' : ''}'
                        '.',
                  if (_toSheet)
                    project.onlineSheetId.isEmpty
                        ? 'Makes a Google Sheet and opens a Google sign-in '
                              'the first time.'
                        : 'Updates the Google Sheet.',
                ].join(' '),
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
/// "Also update the catalog?" after a pull changed parts on the job.
class _CatalogOffersDialog extends StatefulWidget {
  final List<CatalogOffer> offers;
  final String currency;

  const _CatalogOffersDialog({required this.offers, required this.currency});

  @override
  State<_CatalogOffersDialog> createState() => _CatalogOffersDialogState();
}

class _CatalogOffersDialogState extends State<_CatalogOffersDialog> {
  late final Set<int> _ticked = {
    for (var i = 0; i < widget.offers.length; i++) i,
  };

  String _describe(CatalogOffer o) => switch (o.kind) {
    CatalogOfferKind.price =>
      '${o.model}: price ${formatMoney(o.price ?? 0, widget.currency)}',
    CatalogOfferKind.partNumber =>
      '${o.model}: part number '
          '${(o.partNumber ?? '').isEmpty ? '(blank)' : o.partNumber}',
    CatalogOfferKind.addModel =>
      'Add ${o.model} to the catalog, copied from ${o.from}, and swap it in '
          'across the job'
          '${o.price == null ? '' : ' at ${formatMoney(o.price!, widget.currency)}'}',
  };

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('catalog_offers_dialog'),
    title: const Text('Update the catalog too?'),
    content: SizedBox(
      width: 560,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'The job has these changes now. Ticked ones also go into the '
            'catalog, so other jobs and new rooms use them.',
          ),
          const SizedBox(height: 8),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (var i = 0; i < widget.offers.length; i++)
                  CheckboxListTile(
                    key: ValueKey('catalog_offer_$i'),
                    dense: true,
                    value: _ticked.contains(i),
                    onChanged: (v) => setState(
                      () => v == true ? _ticked.add(i) : _ticked.remove(i),
                    ),
                    title: Text(_describe(widget.offers[i])),
                    subtitle: Text(widget.offers[i].label),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        key: const ValueKey('catalog_offers_skip'),
        onPressed: () => Navigator.pop(context, const <CatalogOffer>[]),
        child: const Text('Just this job'),
      ),
      FilledButton(
        key: const ValueKey('catalog_offers_apply'),
        onPressed: _ticked.isEmpty
            ? null
            : () => Navigator.pop(context, [
                for (final i in _ticked.toList()..sort()) widget.offers[i],
              ]),
        child: const Text('Update the catalog'),
      ),
    ],
  );
}

class _ImportReviewDialog extends StatefulWidget {
  final AppStateProvider provider;
  final OnlineImport read;
  final List<OnlineChange> changes;

  /// The file it came out of, so the box can say what it is looking at.
  final String source;

  /// Shown on the way to writing the copy over, rather than on a pull.
  final bool beforePublish;

  const _ImportReviewDialog({
    required this.provider,
    required this.read,
    required this.changes,
    required this.source,
    this.beforePublish = false,
  });

  @override
  State<_ImportReviewDialog> createState() => _ImportReviewDialogState();
}

class _ImportReviewDialogState extends State<_ImportReviewDialog> {
  bool _busy = false;

  Future<void> _apply() async {
    setState(() => _busy = true);
    final provider = widget.provider;
    // Worked out first, while the parts still go by the keys the workbook
    // knew them by.
    final offers = provider.catalogOffersFor(widget.read.master);
    var touched = provider.applyOnlineImport(widget.read);
    touched += await provider.applyMasterEdits(widget.read.master);
    // Counts changed on rooms' tabs, into each room's estimate.
    touched += await provider.applyPendingRoomEdits();
    // KEPT IN A FILE AS WELL. The list on screen is gone when this box
    // closes; the same lines go beside the project - see
    // online_pull_history.dart. The edits that could only be listed are the
    // ones that most need it: the next publish writes over them.
    if (widget.changes.isNotEmpty) {
      final sheet = widget.source == kOnlineSheetLabel;
      await recordOnlinePull(
        projectFile: provider.currentProjectPath,
        project: provider.projectDisplayName,
        source: sheet
            ? '$kOnlineSheetLabel '
                '${liveSheetUrl(provider.project.onlineSheetId.trim())}'
            : widget.source,
        changes: widget.changes,
      );
    }
    if (!mounted) return;
    // THE CATALOG IS ASKED ABOUT, not written. The pull changed this job;
    // whether every job should follow is a separate decision.
    if (offers.isNotEmpty) {
      final chosen = await showDialog<List<CatalogOffer>>(
        context: context,
        builder: (_) => _CatalogOffersDialog(
          offers: offers,
          currency: provider.project.currency,
        ),
      );
      if (chosen != null && chosen.isNotEmpty) {
        final error = await provider.applyCatalogOffers(chosen);
        if (error.isNotEmpty && mounted) {
          final messenger = ScaffoldMessenger.of(context);
          showTimedSnackBar(
            messenger,
            SnackBar(
              content: Text('The catalog could not be saved: $error'),
              backgroundColor: snackErrorFillOn(messenger),
            ),
          );
        }
      }
    }
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
    // What Apply acts on, and what it can only list - see
    // online_sheet_merge.dart.
    final applicable = appliedChanges(changes).length;
    final listed = changes.length - applicable;
    String count(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

    return AlertDialog(
      key: const ValueKey('online_import_dialog'),
      title: Text(
        changes.isEmpty
            ? 'Nothing to bring back'
            : applicable == 0
                ? '${count(listed, 'edit')} found in the online copy'
                : listed == 0
                    ? '${count(applicable, 'change')} to bring back'
                    : '${count(applicable, 'change')} to bring back, '
                        '${count(listed, 'edit')} to make by hand',
      ),
      content: SizedBox(
        width: 720,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'From ${path.basename(widget.source)}.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            if (changes.isEmpty && problems.isEmpty)
              Text(
                'Every row in that copy already matches the job.',
                key: const ValueKey('online_import_nothing'),
                style: theme.textTheme.bodyMedium,
              )
            else
              // THE WHOLE PICTURE BEFORE ANYTHING MOVES: every change that
              // will be merged into the job, and every edit that will be
              // dropped - not brought in, and written over by the next
              // publish - each in full.
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.55,
                  ),
                  child: ListView(
                    key: const ValueKey('online_import_changes'),
                    shrinkWrap: true,
                    children: [
                      _ReviewHeading(
                        key: const ValueKey('online_import_merged_heading'),
                        icon: Icons.merge_type,
                        color: successOn(surface),
                        text: applicable == 0
                            ? 'Nothing will be merged into the job'
                            : 'Merged into the job - '
                                '${count(applicable, 'change')}',
                      ),
                      for (final c in appliedChanges(changes))
                        _ReviewLine(
                          icon: c.id.isEmpty
                              ? Icons.add_circle_outline
                              : Icons.edit,
                          title: c.name,
                          detail: '${c.kind} - ${c.what}',
                        ),
                      if (listed > 0 || problems.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _ReviewHeading(
                          key: const ValueKey('online_import_dropped_heading'),
                          icon: Icons.warning_amber,
                          color: warningOn(surface),
                          text: 'Dropped - '
                              '${count(listed + problems.length, 'edit')} not '
                              'brought in',
                        ),
                        for (final c in listedOnlyChanges(changes))
                          _ReviewLine(
                            icon: Icons.back_hand_outlined,
                            color: warningOn(surface),
                            title: c.name,
                            detail: '${c.what} - make it in the app; the '
                                'next publish writes over it',
                          ),
                        for (final problem in problems)
                          _ReviewLine(
                            key: const ValueKey('online_import_problems'),
                            icon: Icons.block,
                            color: warningOn(surface),
                            title: 'Could not be read',
                            detail: problem,
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            if (listed > 0) ...[
              const Divider(height: 20),
              Text(
                // SAID PLAINLY, because the next publish writes over them.
                '${count(listed, 'edit')} ${listed == 1 ? 'is' : 'are'} in '
                'tabs the app writes but cannot read back - anything on a '
                'room\'s tab but its Qty, for one. '
                '${listed == 1 ? 'It is' : 'They are'} not brought '
                'in: make ${listed == 1 ? 'it' : 'them'} in the app. Apply '
                'keeps the whole list in the history file beside the project'
                '${widget.beforePublish ? ', and the copy is then written over' : ''}.',
                key: const ValueKey('online_import_listed_only'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: warningOn(surface),
                ),
              ),
            ],
            const Divider(height: 20),
            Text(
              'Deliveries and purchase orders are never deleted by an '
              'import: a row missing from those sheets is one somebody '
              'filtered or never scrolled to. A line deleted from a room\'s '
              'tab comes off that room\'s estimate.',
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
          child: Text(
            applicable == 0
                ? (widget.beforePublish
                    ? 'Keep in history and publish'
                    : 'Keep in history')
                : (widget.beforePublish ? 'Apply and publish' : 'Apply'),
          ),
        ),
      ],
    );
  }
}
/// A section heading in the pull review: what is merged, what is dropped.
class _ReviewHeading extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _ReviewHeading({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
          ],
        ),
      );
}

/// One change in the pull review, shown in full.
class _ReviewLine extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final String title;
  final String detail;

  const _ReviewLine({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(left: 26, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color ?? muted),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$title\n',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(text: detail, style: TextStyle(color: muted)),
                ],
              ),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
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

// ---------------------------------------------------------------------------
//  WHEN THE PUBLISH STOOD DOWN
// ---------------------------------------------------------------------------
//  Publish-on-save used to overwrite the workbook whatever was in it. Two of
//  its sheets are a form other people fill in, so that quietly destroyed work
//  - the technician who logged three deliveries in Excel Online at eight, and
//  the person here who pressed Ctrl+S at nine, both found out never.
//
//  Now the save stands the publish down and the app asks. The order matters:
//  their typing comes IN before ours goes OUT, because the only way to
//  overwrite a copy without losing anything is to be holding what was in it.

/// Offers back the edits a held publish found, and then publishes.
///
/// Called from the project save path once the file itself is written - see
/// save_actions.dart. Does nothing when no publish was held, so the caller can
/// call it after every save without asking first.
Future<void> offerHeldOnlineEdits(
  BuildContext context,
  AppStateProvider provider,
) async {
  final hold = provider.onlineHold;
  if (hold == null) return;

  final choice = await showDialog<String>(
    context: context,
    builder: (_) => _HeldPublishDialog(hold: hold),
  );
  if (choice == null || !context.mounted) return;

  if (choice == 'review') {
    final applied = await showDialog<int>(
      context: context,
      builder: (_) => _ImportReviewDialog(
        provider: provider,
        read: hold.read,
        changes: hold.changes,
        source: hold.sheet ? kOnlineSheetLabel : hold.file,
        beforePublish: true,
      ),
    );
    // Backed out at the review: nothing came in, so nothing goes out. The hold
    // stands and the next save asks again, which is the right nag - the copy
    // people are reading is stale until somebody decides about it.
    if (applied == null || !context.mounted) return;

    // THE OTHER COPY MAY HAVE BEEN TYPED IN AS WELL. The save below goes over
    // both, so what is in the second one is brought in first too.
    final other = await provider.findHeldOnlineEdits(
      folderCopy: hold.sheet,
      sheetCopy: !hold.sheet,
    );
    if (!context.mounted) return;
    if (other != null) {
      final more = await showDialog<int>(
        context: context,
        builder: (_) => _ImportReviewDialog(
          provider: provider,
          read: other.read,
          changes: other.changes,
          source: other.sheet ? kOnlineSheetLabel : other.file,
          beforePublish: true,
        ),
      );
      if (more == null || !context.mounted) return;
    }

    // SAVED AGAIN, not just published. Applying the import changed the job, so
    // the file written a moment ago is already behind it; publishing without
    // saving would put figures online that are in no file anywhere.
    final error = await provider.saveProject(overwriteOnlineCopy: true);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 5),
        content: Text(
          error.isNotEmpty
              ? error
              : applied == 0
                  ? 'The online copy has been updated.'
                  : '$applied change${applied == 1 ? '' : 's'} brought in, '
                      'and the online copy updated.',
        ),
        backgroundColor: error.isNotEmpty ? snackErrorFillOn(messenger) : null,
      ),
    );
    return;
  }

  // 'overwrite' - told to go over it anyway, in front of the list of what that
  // costs. Only the copy is rewritten: the job on disk is already current.
  final result = await provider.publishOnlineCopy();
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  showTimedSnackBar(
    messenger,
    SnackBar(
      duration: const Duration(seconds: 5),
      content: Text(
        result.written.isEmpty
            ? 'Nothing could be written: ${result.failed.join('; ')}'
            : 'The online copy has been overwritten.',
      ),
      backgroundColor:
          result.written.isEmpty ? snackErrorFillOn(messenger) : null,
    ),
  );
}

/// What was found in the published copy, before anything is written over it.
///
/// THREE ANSWERS, and the middle one is not "OK". Somebody who has just
/// pressed Save wants the save to have happened - it has, the job is on disk -
/// and this box is about a different document. So it says whose typing is at
/// stake and how much of it, and the way out that loses nothing is the one
/// offered first.
class _HeldPublishDialog extends StatelessWidget {
  final OnlineHold hold;

  const _HeldPublishDialog({required this.hold});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final surface =
        theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface;
    final count = hold.changes.length;

    return AlertDialog(
      key: const ValueKey('online_hold_dialog'),
      title: const Text('Somebody has edited the online copy'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The job has been saved. The online copy has NOT been updated, '
              'because '
              '${hold.sheet ? 'the Google Sheet' : path.basename(hold.file)} '
              'has been typed in since '
              'this app last wrote it - updating it now would write over '
              '$count change${count == 1 ? '' : 's'}.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            // A Sheet does not say when it was last typed in.
            if (!hold.sheet)
              _Point(
                icon: Icons.schedule_outlined,
                text:
                    'That file was last edited ${_editedWhen(hold.modified)}.',
              ),
            const _Point(
              icon: Icons.download_outlined,
              text: 'Bringing the changes in first costs nothing: every one is '
                  'listed and checked before it is applied.',
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: surface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: muted.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final c in hold.changes.take(4))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '${c.name} - ${c.what}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  if (count > 4)
                    Text(
                      'and ${count - 4} more.',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('online_hold_leave'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Leave it for now'),
        ),
        TextButton(
          key: const ValueKey('online_hold_overwrite'),
          onPressed: () => Navigator.of(context).pop('overwrite'),
          child: const Text('Overwrite it'),
        ),
        FilledButton(
          key: const ValueKey('online_hold_review'),
          onPressed: () => Navigator.of(context).pop('review'),
          child: const Text('Bring the changes in'),
        ),
      ],
    );
  }
}

/// 'today', 'yesterday', 'on 2026-04-20' - how long that file has been sitting
/// there with somebody's work in it.
///
/// Said the same way as the freshness line on the Project tab, because the two
/// answer the same question from opposite ends: how old is the copy, and how
/// new is what is in it.
String _editedWhen(DateTime at, {DateTime? asOf}) {
  final now = asOf ?? DateTime.now();
  final days = DateTime(now.year, now.month, now.day)
      .difference(DateTime(at.year, at.month, at.day))
      .inDays;
  return switch (days) {
    <= 0 => 'today',
    1 => 'yesterday',
    < 14 => '$days days ago',
    _ => 'on ${at.toIso8601String().split('T').first}',
  };
}
