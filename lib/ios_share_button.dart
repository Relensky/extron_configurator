import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'collab/collab_controller.dart' show CollabDocKind;
import 'collab/collab_widgets.dart'
    show showMergeConflictDialog, showMergeReviewDialog;
import 'collab/json_merge.dart';
import 'mobile_sign_in.dart';
import 'services/ios_share.dart';
import 'services/share_sync.dart';
import 'team/team_presence.dart' show TeamIdentity;

// ============================================================================
//  [iOS SHARE BUTTON]: the CTS share and the offline copy, in the top bar
// ============================================================================
//  Only on an iPhone or iPad. The icon says where files are coming from -
//  the share, the copy kept on the device, or neither yet - with a dot while
//  edits made offline are waiting to go up. Pressed, it shows what the last
//  sync did and the few controls there are: connect, sync now, keep every job
//  offline, and who is signed in.
// ============================================================================

class IosShareButton extends StatelessWidget {
  const IosShareButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([IosShare.changes, ShareSync.status]),
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final status = ShareSync.status.value;
        final IconData icon;
        final String tip;
        Color? color;
        if (!IosShare.active) {
          icon = Icons.cloud_off_outlined;
          tip = 'Not connected to the CTS share';
          color = scheme.onSurfaceVariant;
        } else if (status.running) {
          icon = Icons.cloud_sync_outlined;
          tip = 'Syncing with the CTS share';
        } else if (IosShare.offline) {
          icon = Icons.cloud_off;
          tip = 'Working offline from the copy on this device';
          color = Colors.orange.shade700;
        } else {
          icon = Icons.cloud_done_outlined;
          tip = 'Connected to the CTS share';
          color = Colors.green.shade600;
        }
        return IconButton(
          key: const ValueKey('ios_share_button'),
          tooltip: tip,
          onPressed: () => showIosSharePanel(context),
          // Red: files waiting for a person to review the combine.
          // Otherwise the edits made here not yet on the share.
          icon: Badge(
            isLabelVisible: status.held.isNotEmpty || status.pending > 0,
            backgroundColor: status.held.isNotEmpty
                ? scheme.error
                : Colors.orange.shade700,
            label: Text(
              '${status.held.isNotEmpty ? status.held.length : status.pending}',
            ),
            child: Icon(icon, color: color),
          ),
        );
      },
    );
  }
}

Future<void> showIosSharePanel(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _SharePanel());

class _SharePanel extends StatefulWidget {
  const _SharePanel();

  @override
  State<_SharePanel> createState() => _SharePanelState();
}

class _SharePanelState extends State<_SharePanel> {
  String _message = '';
  bool _busy = false;

  /// Keeps the open job's every room and plan on this device and brings them
  /// down now - see [ShareSync.keepJobOffline].
  Future<void> _keepJob() async {
    final provider = context.read<AppStateProvider>();
    final files = provider.openJobFiles;
    setState(() {
      _busy = true;
      _message = 'Downloading ${provider.projectDisplayName}...';
    });
    try {
      final added = await ShareSync.keepJobOffline(files);
      if (!mounted) return;
      final rooms = provider.project.rooms.length;
      setState(() => _message = IosShare.offline
          ? 'Kept $added more folder${added == 1 ? '' : 's'} for this job; '
              'they come down when the share answers.'
          : '${provider.projectDisplayName} is on this device: the job, '
              '$rooms room${rooms == 1 ? '' : 's'} and its plans. Changes '
              'keep syncing.');
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not download the job: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() async {
    setState(() => _busy = true);
    final problem = await IosShare.pick();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message =
          problem ??
          'Connected. Close and reopen the app to load everything from '
              'the share.';
    });
    if (problem == null) await ShareSync.syncNow();
  }

  Future<void> _sync() async {
    setState(() {
      _busy = true;
      _message = '';
    });
    final ok = await IosShare.checkReachable();
    if (ok) await ShareSync.syncNow();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = ok
          ? ''
          : 'The share did not answer. On campus Wi-Fi or the VPN, open the '
                'Files app and tap the doit-files server to reconnect, then try '
                'again.';
    });
  }

  /// Throws away this device's unsent changes and takes the share's
  /// versions, after asking. The open job is read again, so nothing unsaved
  /// in it is saved back over them.
  Future<void> _discard() async {
    final provider = context.read<AppStateProvider>();
    final offline = IosShare.offline;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes and resync?'),
        content: Text(
          'Every change made on this device that the share hasn\'t got is '
          'thrown away${provider.hasOpenProject ? ', unsaved edits to the open job too' : ''}. '
          '${offline ? 'The share does not answer, so each file goes back to how it was last synced, and the newest versions come down when it answers.' : 'Each file is replaced with the share\'s version.'}'
          '\n\nA copy of this device\'s versions is kept on it, in case.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('ios_discard_confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _message = 'Discarding...';
    });
    try {
      final n = await ShareSync.discardChanges();
      if (provider.hasOpenProject && provider.currentProjectPath.isNotEmpty) {
        await provider.openProject(provider.currentProjectPath);
      }
      if (!mounted) return;
      setState(
        () => _message = n == 0
            ? (IosShare.offline
                  ? 'No changes here to discard. The share does not answer, '
                        'so nothing was synced.'
                  : 'No changes here to discard. Synced with the share.')
            : 'Discarded $n change${n == 1 ? '' : 's'}. '
                  '${IosShare.offline ? 'The newest versions come down when the share answers.' : 'This device matches the share.'}',
      );
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not discard: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A file changed here and on the share, decided by the person: a JSON
  /// file through the same Combine dialogs as two people's saves (every
  /// change coming in ticked or not, every place both changed chosen by
  /// hand), anything else kept as one side or both. Cancelling leaves it held.
  Future<void> _review(String rel) async {
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      final r = await ShareSync.loadReview(rel);
      if (!mounted) return;
      if (r == null) {
        setState(
          () => _message =
              'The share did not answer, so the file can\'t be reviewed now.',
        );
        return;
      }
      final name = rel.split('/').last;
      if (r.json && r.base != null) {
        await _reviewJson(r, name);
      } else {
        await _reviewWhole(r, name);
      }
    } on ShareChangedAgain catch (e) {
      if (mounted) setState(() => _message = e.toString());
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not finish the review: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewJson(ShareReview r, String name) async {
    final kind = name.toLowerCase().endsWith('_project.json')
        ? CollabDocKind.project
        : r.rel.contains('/Configurator_Files/')
        ? CollabDocKind.catalog
        : CollabDocKind.room;
    const who = 'The share';
    // What the share's version brings in, each change ticked to take it.
    final preview = mergeJson3(r.base, r.mine, r.theirs);
    var declined = <String>{};
    if (preview.changes.isNotEmpty) {
      final picked = await showMergeReviewDialog(
        context,
        kind: kind,
        who: who,
        preview: preview,
        doc: r.mine,
        name: name,
      );
      if (picked == null || !mounted) return;
      declined = picked;
    }
    // Every place both changed, decided one by one.
    Map<String, MergeSide>? choices;
    if (preview.conflicts.isNotEmpty) {
      choices = await showMergeConflictDialog(
        context,
        kind: kind,
        conflicts: preview.conflicts,
        who: who,
        doc: r.mine,
      );
      if (choices == null || !mounted) return;
    }
    final combined = mergeJson3(
      r.base,
      r.mine,
      r.theirs,
      resolve: (c) =>
          choices?[c.path] ?? (c.canKeepBoth ? MergeSide.both : MergeSide.mine),
      declined: declined,
    );
    await ShareSync.applyCombined(r, combined.merged);
    if (mounted) setState(() => _message = 'Combined $name.');
  }

  /// No common version to combine against (or not JSON): one side, or both.
  Future<void> _reviewWhole(ShareReview r, String name) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Keep which $name?'),
        content: Text(
          r.json
              ? 'It was made on this device and on the share separately, so '
                    'there is nothing to combine against - keep one, or both '
                    'side by side.'
              : 'This kind of file can\'t be combined - keep one, or both '
                    'side by side.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'theirs'),
            child: const Text("Keep the share's"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'mine'),
            child: const Text("Keep this device's"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'both'),
            child: const Text('Keep both'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'mine':
        await ShareSync.keepMine(r);
        if (mounted) setState(() => _message = "Kept this device's $name.");
      case 'theirs':
        await ShareSync.keepTheirs(r);
        if (mounted) setState(() => _message = "Kept the share's $name.");
      case 'both':
        final kept = await ShareSync.keepBoth(r);
        if (mounted) {
          setState(() => _message = "Kept both - this device's is $kept.");
        }
    }
  }

  String _ago(DateTime? at) {
    if (at == null) return 'never';
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${at.month}/${at.day} ${at.hour}:${at.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([IosShare.changes, ShareSync.status]),
      builder: (context, _) {
        final status = ShareSync.status.value;
        final where = !IosShare.active
            ? 'Not connected. The app is working from its own files on this '
                  'device.'
            : IosShare.offline
            ? IosShare.problem ??
                  'Working offline from the copy on this device.'
            : 'Connected to ${IosShare.uncRoot}.';
        return AlertDialog(
          title: const Text('CTS share'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(where),
                  if (IosShare.active && !IosShare.coversClassroomTechnology)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Team chat and presence need the Classroom Technology '
                        'folder (or above) picked - the folder picked holds '
                        'Projects only.',
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  if (IosShare.active) ...[
                    const SizedBox(height: 12),
                    Text('Offline copy', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      'Last synced ${_ago(status.lastSync)}'
                      '${status.message.isEmpty ? '' : ' - ${status.message}'}.',
                    ),
                    if (status.pending - status.held.length > 0)
                      Text(
                        '${status.pending - status.held.length} '
                        'file${status.pending - status.held.length == 1 ? '' : 's'} '
                        'changed on this device, waiting for the share.',
                        style: TextStyle(color: Colors.orange.shade800),
                      ),
                    if (status.held.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Changed here and on the share - nothing has been '
                        'combined. Review each one: until you do, the share '
                        'keeps its version and this device keeps yours.',
                        style: TextStyle(color: scheme.error),
                      ),
                      for (final rel in status.held)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.call_merge),
                          title: Text(rel.split('/').last),
                          subtitle: Text(
                            uncPath(
                              '${IosShare.mirrorRoot}/$rel',
                            ).replaceFirst(r'\\doit-files\ATEC\', ''),
                            style: theme.textTheme.bodySmall,
                          ),
                          trailing: FilledButton.tonal(
                            onPressed: _busy ? null : () => _review(rel),
                            child: const Text('Review'),
                          ),
                        ),
                    ],
                    Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: OutlinedButton.icon(
                          key: const ValueKey('ios_discard_changes'),
                          icon: const Icon(Icons.restore, size: 18),
                          label: const Text('Discard changes and resync'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: scheme.error,
                          ),
                          onPressed: _busy || status.running ? null : _discard,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      'Kept: Configurator_Files and every job opened here'
                      '${ShareSync.keptFolders.isEmpty ? '' : ' (${ShareSync.keptFolders.length} so far)'}.',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                    // THE OPEN JOB, ALL OF IT: its rooms and plans may be
                    // in other folders than the job's own, and only the
                    // job's folder is kept by opening it.
                    if (context.read<AppStateProvider>().hasOpenProject)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: FilledButton.tonalIcon(
                          key: const ValueKey('ios_keep_job'),
                          icon: const Icon(Icons.download_for_offline_outlined),
                          label: Text(
                            'Download all of '
                            '${context.read<AppStateProvider>().projectDisplayName}',
                            overflow: TextOverflow.ellipsis,
                          ),
                          onPressed: _busy ? null : _keepJob,
                        ),
                      ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Keep every job offline'),
                      subtitle: const Text(
                        'The whole Projects folder, not just the jobs '
                        'opened here. The first sync can take a while.',
                      ),
                      value: ShareSync.keepEveryJob,
                      onChanged: (on) =>
                          setState(() => ShareSync.keepEveryJob = on),
                    ),
                    SwitchListTile(
                      key: const ValueKey('ios_keep_manuals'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Keep device manuals offline'),
                      subtitle: const Text(
                        'The Dashboard\'s manuals folder, so a manual opens '
                        'with no network. Brought down only - never sent back.',
                      ),
                      value: ShareSync.keepManuals,
                      onChanged: (on) =>
                          setState(() => ShareSync.keepManuals = on),
                    ),
                  ],
                  if (_message.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_message),
                    ),
                  const Divider(height: 24),
                  Text(
                    'Signed in as ${TeamIdentity.userOverride ?? 'unknown'}'
                    ' on ${TeamIdentity.machineOverride ?? 'this device'}.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                signOutMobile();
                setState(
                  () => _message =
                      'Signed out. Close and reopen the app to sign in again.',
                );
              },
              child: const Text('Sign out'),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.dns_outlined, size: 18),
              label: Text(IosShare.active ? 'Pick again' : 'Connect'),
              onPressed: _busy ? null : _connect,
            ),
            if (IosShare.active)
              FilledButton.icon(
                icon: status.running || _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync, size: 18),
                label: const Text('Sync now'),
                onPressed: status.running || _busy ? null : _sync,
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}
