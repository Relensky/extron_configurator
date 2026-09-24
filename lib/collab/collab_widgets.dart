import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'collab_controller.dart';
import 'json_merge.dart';
import 'presence.dart';

/// ============================================================================
///  WHO ELSE IS IN HERE - on screen
/// ============================================================================
///  A person icon with the Windows sign-in name for everybody else who has the
///  document open, and - when one of them has saved - a button that brings
///  their work in. Save does the same merge on its own; the button is for
///  seeing it now rather than at the next save.
/// ============================================================================

/// The documents a page edits, most specific first.
List<CollabDocKind> collabKindsForTab(AppTab tab) => switch (tab) {
      AppTab.project => const [CollabDocKind.project],
      AppTab.deviceEditor => const [CollabDocKind.catalog],
      AppTab.appConfig ||
      AppTab.schemaEditor ||
      AppTab.flowRules =>
        const [],
      _ => const [CollabDocKind.room, CollabDocKind.project],
    };

/// The initials drawn in the avatar: `jsmith` -> `JS`, `Jane.Smith` -> `JS`.
String collabInitials(String user) {
  final parts = user
      .split(RegExp(r'[\s._\\-]+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    final p = parts.first;
    return (p.length >= 2 ? p.substring(0, 2) : p).toUpperCase();
  }
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

/// A steady color per person, so the same colleague is the same color on
/// every machine.
Color collabColorFor(String user) {
  const palette = [
    Color(0xFF1565C0),
    Color(0xFF2E7D32),
    Color(0xFF6A1B9A),
    Color(0xFFC62828),
    Color(0xFF00838F),
    Color(0xFFEF6C00),
    Color(0xFF4E342E),
    Color(0xFFAD1457),
  ];
  var h = 0;
  for (final c in user.toLowerCase().codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return palette[h % palette.length];
}

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// The people and pending saves for the page on screen, on the banner.
class CollabPresenceStrip extends StatelessWidget {
  final AppTab tab;

  const CollabPresenceStrip({super.key, required this.tab});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final collab = provider.collab;
    return ListenableBuilder(
      listenable: collab,
      builder: (context, _) {
        if (!collab.enabled) return const SizedBox.shrink();
        final chips = <Widget>[];
        for (final kind in collabKindsForTab(tab)) {
          final incoming = collab.incomingOn(kind);
          if (incoming != null) {
            chips.add(_IncomingChip(kind: kind, incoming: incoming));
          }
          for (final other in collab.othersOn(kind)) {
            chips.add(CollabEditorAvatar(presence: other, kind: kind));
          }
        }
        if (chips.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            key: const ValueKey('collab_presence_strip'),
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in chips)
                Padding(padding: const EdgeInsets.only(left: 4), child: c),
            ],
          ),
        );
      },
    );
  }
}

/// One other editor: their initials in a colored circle, and their Windows
/// user name beside it.
class CollabEditorAvatar extends StatelessWidget {
  final EditorPresence presence;
  final CollabDocKind kind;

  const CollabEditorAvatar({
    super.key,
    required this.presence,
    required this.kind,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = collabColorFor(presence.user);
    final noun = collabDocNoun(kind);
    return Tooltip(
      message: '${presence.user} on ${presence.machine} has this $noun open '
          '(since ${_clock(presence.since)}).'
          '${presence.unsaved ? '\nThey have changes they have not saved yet '
              '- when they save, you will be offered their changes to merge.' : ''}'
          '${presence.savedAt != null ? '\nLast saved at ${_clock(presence.savedAt!)}.' : ''}',
      child: Chip(
        key: ValueKey('collab_editor_${presence.user}'),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        avatar: Stack(
          clipBehavior: Clip.none,
          children: [
            CircleAvatar(
              backgroundColor: color,
              child: Text(
                collabInitials(presence.user),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (presence.unsaved)
              Positioned(
                right: -2,
                bottom: -2,
                child: Icon(
                  Icons.edit,
                  size: 11,
                  color: theme.colorScheme.tertiary,
                ),
              ),
          ],
        ),
        label: Text(
          presence.user,
          style: theme.textTheme.labelMedium,
        ),
        side: BorderSide(color: color, width: 1.5),
      ),
    );
  }
}

class _IncomingChip extends StatelessWidget {
  final CollabDocKind kind;
  final IncomingChange incoming;

  const _IncomingChip({required this.kind, required this.incoming});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: '${incoming.who} saved this ${collabDocNoun(kind)} at '
          '${_clock(incoming.at)}. Merge brings their changes in now; anything '
          'you both changed is shown for you to choose. Saving merges too.',
      child: ActionChip(
        key: ValueKey('collab_incoming_${kind.name}'),
        visualDensity: VisualDensity.compact,
        avatar: Icon(Icons.merge_type, color: theme.colorScheme.onTertiary),
        backgroundColor: theme.colorScheme.tertiary,
        label: Text(
          '${incoming.who} saved - Merge',
          style: theme.textTheme.labelMedium
              ?.copyWith(color: theme.colorScheme.onTertiary),
        ),
        onPressed: () => mergeIncomingNow(
          context,
          context.read<AppStateProvider>(),
          kind,
        ),
      ),
    );
  }
}

/// Brings somebody else's saved changes into this copy, asking about anything
/// both of you changed. Returns false when the person backed out.
Future<bool> mergeIncomingNow(
  BuildContext context,
  AppStateProvider provider,
  CollabDocKind kind, {
  bool beforeSave = false,
}) async {
  final collab = provider.collab;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final preview = collab.previewMerge(kind);

  Map<String, MergeSide>? choices;
  if (preview != null && preview.conflicts.isNotEmpty) {
    choices = await showMergeConflictDialog(
      context,
      kind: kind,
      conflicts: preview.conflicts,
      who: collab.incomingOn(kind)?.who ?? 'Someone else',
      beforeSave: beforeSave,
    );
    if (choices == null) return false;
  }
  final outcome = await collab.mergeIncoming(
    kind,
    resolve: choices == null
        ? null
        : (c) => choices![c.path] ?? MergeSide.mine,
  );
  if (outcome.merged && messenger != null) {
    final n = outcome.takenFromTheirs;
    messenger.showSnackBar(SnackBar(
      content: Text(
        'Merged the saved ${collabDocNoun(kind)}'
        '${n > 0 ? ': $n change${n == 1 ? '' : 's'} taken from the file' : ''}'
        '${outcome.conflicts.isNotEmpty ? ', ${outcome.conflicts.length} '
            'conflict${outcome.conflicts.length == 1 ? '' : 's'} settled as you '
            'chose' : ''}.',
      ),
    ));
  }
  return true;
}

/// Before a save: if somebody else saved the file since this copy read it,
/// fold their changes in first so the save does not write over them. Returns
/// false when the person canceled.
Future<bool> reconcileBeforeSave(
  BuildContext context,
  AppStateProvider provider,
  CollabDocKind kind,
) async {
  final collab = provider.collab;
  if (!collab.enabled) return true;
  final preview = collab.previewMerge(kind);
  if (preview == null) return true;
  return mergeIncomingNow(context, provider, kind, beforeSave: true);
}

/// Lists every place both people changed, each with a Mine / Theirs choice.
/// Returns the choices by conflict path, or null when canceled.
Future<Map<String, MergeSide>?> showMergeConflictDialog(
  BuildContext context, {
  required CollabDocKind kind,
  required List<MergeConflict> conflicts,
  required String who,
  bool beforeSave = false,
}) {
  final choices = {for (final c in conflicts) c.path: MergeSide.mine};
  return showDialog<Map<String, MergeSide>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          key: const ValueKey('collab_conflict_dialog'),
          title: Text('You and $who both changed this ${collabDocNoun(kind)}'),
          content: SizedBox(
            width: 640,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Everything only one of you changed is merged already. '
                  'These ${conflicts.length} place'
                  '${conflicts.length == 1 ? ' was' : 's were'} changed by '
                  'both - pick which to keep.'
                  '${beforeSave ? ' The save continues once you apply.' : ''}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => setState(() {
                        for (final k in choices.keys) {
                          choices[k] = MergeSide.mine;
                        }
                      }),
                      child: const Text('Keep all mine'),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        for (final k in choices.keys) {
                          choices[k] = MergeSide.theirs;
                        }
                      }),
                      child: Text('Take all of $who\'s'),
                    ),
                  ],
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final c in conflicts)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SelectableText(
                                  c.path,
                                  style: theme.textTheme.titleSmall,
                                ),
                                Text(
                                  'Was: ${describeJsonValue(c.base)}',
                                  style: theme.textTheme.bodySmall,
                                ),
                                RadioGroup<MergeSide>(
                                  groupValue: choices[c.path],
                                  onChanged: (v) => setState(
                                    () => choices[c.path] = v ?? MergeSide.mine,
                                  ),
                                  child: Column(
                                    children: [
                                      RadioListTile<MergeSide>(
                                        dense: true,
                                        value: MergeSide.mine,
                                        title: Text(
                                          'Mine: ${describeJsonValue(c.mine)}',
                                        ),
                                      ),
                                      RadioListTile<MergeSide>(
                                        dense: true,
                                        value: MergeSide.theirs,
                                        title: Text(
                                          '$who: ${describeJsonValue(c.theirs)}',
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('collab_conflict_apply'),
              onPressed: () => Navigator.pop(ctx, choices),
              child: Text(beforeSave ? 'Merge and save' : 'Merge'),
            ),
          ],
        );
      },
    ),
  );
}

/// Shows the controller's notices - somebody opened this, somebody saved -
/// as snack bars. Wrapped once round the page.
class CollabNoticeListener extends StatefulWidget {
  final Widget child;

  const CollabNoticeListener({super.key, required this.child});

  @override
  State<CollabNoticeListener> createState() => _CollabNoticeListenerState();
}

class _CollabNoticeListenerState extends State<CollabNoticeListener> {
  StreamSubscription<CollabNotice>? _sub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sub ??= context.read<AppStateProvider>().collab.notices.listen((n) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Row(
            children: [
              const Icon(Icons.people_alt_outlined, color: Colors.white70),
              const SizedBox(width: 12),
              Expanded(child: Text(n.message)),
            ],
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
