import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import 'collab_controller.dart';
import 'json_merge.dart';
import 'merge_labels.dart';
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

/// True when [presence] has changed the document since opening it: work
/// not saved yet, or a save made after they opened it.
bool collabHasChanged(EditorPresence presence) =>
    presence.unsaved ||
    (presence.savedAt != null && presence.savedAt!.isAfter(presence.since));

/// How many editors get a chip of their own before the rest go in a list.
const int kCollabChipsShown = 3;

/// The editors past [kCollabChipsShown]: '+2', opening a list of who they
/// are and where.
class _MoreEditors extends StatelessWidget {
  final List<({EditorPresence presence, CollabDocKind kind})> editors;

  const _MoreEditors({super.key, required this.editors});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    return PopupMenuButton<void>(
      key: const ValueKey('collab_more_editors'),
      tooltip: '${editors.length} more editing',
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        for (final e in editors)
          PopupMenuItem<void>(
            enabled: false,
            child: ListTile(
              key: ValueKey('collab_more_${e.presence.user}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: CollabAvatarCircle(
                user: e.presence.user,
                picture: provider.avatarFileFor(e.presence.user),
              ),
              // The row is not pressable, but the name is not disabled.
              title: Text(
                e.presence.user,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              subtitle: Text(
                [
                  e.presence.whereText.isEmpty
                      ? 'the ${collabDocNoun(e.kind)}'
                      : e.presence.whereText,
                  if (e.presence.unsaved) 'unsaved changes',
                ].join(' - '),
              ),
            ),
          ),
      ],
      child: Chip(
        visualDensity: VisualDensity.compact,
        avatar: const Icon(Icons.group_outlined, size: 16),
        label: Text('+${editors.length}'),
      ),
    );
  }
}

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
        final chips = <Widget>[
          // The queue at work: merges and saves, one at a time.
          if (collab.queued > 0)
            _BusyChip(
              key: const ValueKey('collab_busy_chip'),
              waiting: collab.queued - 1,
            ),
        ];
        // Each person once, on the first document they are editing.
        final editors = <({EditorPresence presence, CollabDocKind kind})>[];
        final seen = <CollabIdentity>{};
        // A save to the open room or project is flagged on every tab, not
        // only the tab that edits it.
        final tabKinds = collabKindsForTab(tab);
        for (final kind in {
          ...tabKinds,
          CollabDocKind.room,
          CollabDocKind.project,
        }) {
          final incoming = collab.incomingOn(kind);
          if (incoming != null) {
            chips.add(_IncomingChip(
              key: ValueKey('collab_incoming_chip_${kind.name}'),
              kind: kind,
              incoming: incoming,
            ));
          }
        }
        for (final kind in tabKinds) {
          for (final other in collab.othersOn(kind)) {
            // Only somebody who has CHANGED it. A colleague who merely has
            // the file open is not editing it, and a chip for every reader
            // made every open file look like it was being worked on.
            if (!collabHasChanged(other)) continue;
            if (!seen.add(other.identity)) continue;
            editors.add((presence: other, kind: kind));
          }
        }
        // A FEW ON THE BAR, THE REST IN A LIST. Five people editing at once
        // is five chips the bar has no room for.
        for (final e in editors.take(kCollabChipsShown)) {
          chips.add(CollabEditorAvatar(
            key: ValueKey('collab_editor_chip_${e.presence.user}@${e.presence.machine}'),
            presence: e.presence,
            kind: e.kind,
          ));
        }
        if (editors.length > kCollabChipsShown) {
          chips.add(_MoreEditors(
            key: const ValueKey('collab_more_chip'),
            editors: editors.skip(kCollabChipsShown).toList(),
          ));
        }
        if (chips.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            key: const ValueKey('collab_presence_strip'),
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in chips)
                Padding(
                  // Keyed, so a chip keeps its place in the tree when the
                  // busy chip appears in front of it.
                  key: c.key,
                  padding: const EdgeInsets.only(left: 4),
                  child: c,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The theme's tooltip box with no see-through, so the page does not show
/// behind a tall hover box.
Decoration _solidTooltipBox(BuildContext context) {
  final themed = TooltipTheme.of(context).decoration;
  if (themed is BoxDecoration && themed.color != null) {
    return themed.copyWith(color: themed.color!.withValues(alpha: 1));
  }
  if (themed != null) return themed;
  // The stock tooltip colors, at full strength.
  final dark = Theme.of(context).brightness == Brightness.dark;
  return BoxDecoration(
    color: dark ? Colors.white : Colors.grey[700],
    borderRadius: const BorderRadius.all(Radius.circular(4)),
  );
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
    final picture = context.read<AppStateProvider>().avatarFileFor(
      presence.user,
    );
    final about = '${presence.user} on ${presence.machine} has this $noun '
        'open (since ${_clock(presence.since)}).'
        '${presence.whereText.isEmpty ? '' : '\nNow in ${presence.whereText}.'}'
        '${presence.unsaved ? '\nThey have changes they have not saved yet '
            '- when they save, you will be offered their changes to combine.' : ''}'
        '${presence.savedAt != null ? '\nLast saved at ${_clock(presence.savedAt!)}.' : ''}';
    return Tooltip(
      decoration: _solidTooltipBox(context),
      // Their picture, large, above the words - so who it is can be seen,
      // not only read.
      richMessage: picture == null
          ? TextSpan(text: about)
          : TextSpan(
              children: [
                WidgetSpan(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: CollabAvatarCircle(
                      key: ValueKey('collab_avatar_hover_${presence.user}'),
                      user: presence.user,
                      picture: picture,
                      radius: 48,
                    ),
                  ),
                ),
                TextSpan(text: '\n$about'),
              ],
            ),
      child: Chip(
        key: ValueKey('collab_editor_${presence.user}'),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        avatar: Stack(
          clipBehavior: Clip.none,
          children: [
            CollabAvatarCircle(user: presence.user, picture: picture),
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
        // The room they are in beside the name, when they are in one.
        label: Text(
          presence.room.trim().isEmpty
              ? presence.user
              : '${presence.user} · ${presence.room.trim()}',
          style: theme.textTheme.labelMedium,
        ),
        side: BorderSide(color: color, width: 1.5),
      ),
    );
  }
}

/// Shown while the queue of merges and saves is working, with how many are
/// waiting.
class _BusyChip extends StatelessWidget {
  final int waiting;

  const _BusyChip({super.key, required this.waiting});

  @override
  Widget build(BuildContext context) => Chip(
    key: const ValueKey('collab_busy'),
    visualDensity: VisualDensity.compact,
    avatar: const SizedBox(
      width: 14,
      height: 14,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
    label: Text(waiting > 0 ? 'Syncing ($waiting waiting)' : 'Syncing…'),
  );
}

/// Somebody's avatar: their picture when they have set one, else their
/// initials in their color.
class CollabAvatarCircle extends StatelessWidget {
  final String user;
  final String? picture;
  final double radius;

  const CollabAvatarCircle({
    super.key,
    required this.user,
    this.picture,
    this.radius = 12,
  });

  @override
  Widget build(BuildContext context) {
    final color = collabColorFor(user);
    final file = picture;
    if (file != null) {
      return CircleAvatar(
        key: ValueKey('collab_avatar_picture_$user'),
        radius: radius,
        backgroundColor: color,
        backgroundImage: FileImage(File(file)),
        // A picture that cannot be read shows the initials instead.
        onBackgroundImageError: (_, _) {},
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: color,
      child: Text(
        collabInitials(user),
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 0.85,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _IncomingChip extends StatelessWidget {
  final CollabDocKind kind;
  final IncomingChange incoming;

  const _IncomingChip({
    super.key,
    required this.kind,
    required this.incoming,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: '${incoming.who} saved this ${collabDocNoun(kind)} at '
          '${_clock(incoming.at)}. Press to combine their changes with '
          'yours now - nothing of either of yours is lost, and anything you '
          'both changed is shown for you to choose. Saving combines them too.',
      // The badge: a save is waiting to be brought in.
      child: Badge(
        key: ValueKey('collab_incoming_badge_${kind.name}'),
        smallSize: 10,
        backgroundColor: theme.colorScheme.error,
        child: ActionChip(
          key: ValueKey('collab_incoming_${kind.name}'),
          visualDensity: VisualDensity.compact,
          avatar: Icon(Icons.sync, color: theme.colorScheme.onTertiary),
          backgroundColor: theme.colorScheme.tertiary,
          label: Text(
            '${incoming.who} saved the ${collabDocNoun(kind)} - Combine',
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.onTertiary),
          ),
          onPressed: () => mergeIncomingNow(
            context,
            context.read<AppStateProvider>(),
            kind,
          ),
        ),
      ),
    );
  }
}

/// Brings somebody else's saved changes into this copy, asking about anything
/// both of you changed. Returns false when the person backed out.
///
/// Queued behind any other merge or save - see [CollabController.enqueue].
Future<bool> mergeIncomingNow(
  BuildContext context,
  AppStateProvider provider,
  CollabDocKind kind,
) {
  // The button pressed may be rebuilt away while the merge waits its turn,
  // so the dialog and the snack bar hang off the navigator, which stays.
  final host = Navigator.maybeOf(context, rootNavigator: true)?.context;
  final messenger = ScaffoldMessenger.maybeOf(context);
  return provider.collab.enqueue(() async {
    // Merged already while it waited - a second press, or a save that
    // folded it in. Nothing left to bring in.
    if (provider.collab.incomingOn(kind) == null) return true;
    // A frame for the busy chip before the work starts.
    await Future<void>.delayed(const Duration(milliseconds: 16));
    final on = host != null && host.mounted ? host : context;
    if (!on.mounted) return false;
    return _mergeNow(on, provider, kind, messenger: messenger);
  });
}

Future<bool> _mergeNow(
  BuildContext context,
  AppStateProvider provider,
  CollabDocKind kind, {
  bool beforeSave = false,
  ScaffoldMessengerState? messenger,
}) async {
  final collab = provider.collab;
  messenger ??= ScaffoldMessenger.maybeOf(context);
  // Read before the merge clears it.
  final who = collab.incomingOn(kind)?.who ?? 'the other editor';
  final preview = collab.previewMerge(kind);

  Map<String, MergeSide>? choices;
  if (preview != null && preview.conflicts.isNotEmpty) {
    choices = await showMergeConflictDialog(
      context,
      kind: kind,
      conflicts: preview.conflicts,
      who: collab.incomingOn(kind)?.who ?? 'Someone else',
      beforeSave: beforeSave,
      doc: collab.currentOf(kind),
    );
    if (choices == null) return false;
  }
  final outcome = await collab.mergeIncoming(
    kind,
    // Anything not asked about - the file moved again since the question was
    // put - keeps both where it can, so nobody's work goes unseen.
    resolve: (c) =>
        choices?[c.path] ??
        (c.canKeepBoth ? MergeSide.both : MergeSide.mine),
  );
  if (outcome.merged && messenger != null && messenger.mounted) {
    final n = outcome.takenFromTheirs;
    final parts = [
      if (n > 0) '$n change${n == 1 ? '' : 's'} from $who added',
      if (outcome.renumbered > 0)
        '${outcome.renumbered} item${outcome.renumbered == 1 ? '' : 's'} you '
            'both added kept as separate items',
      if (outcome.conflicts.isNotEmpty)
        '${outcome.conflicts.length} place'
            '${outcome.conflicts.length == 1 ? '' : 's'} you both changed '
            'settled as you chose',
    ];
    messenger.showSnackBar(SnackBar(
      content: Text(
        parts.isEmpty
            ? 'Combined with the saved ${collabDocNoun(kind)}.'
            : 'Combined with the saved ${collabDocNoun(kind)}: '
                  '${parts.join('; ')}.',
      ),
    ));
  }
  return true;
}

/// Before a save: if somebody else saved the file since this copy read it,
/// fold their changes in first so the save does not write over them. Returns
/// false when the person canceled. Called from inside the save's own place in
/// the queue - see [CollabController.enqueue].
Future<bool> reconcileBeforeSave(
  BuildContext context,
  AppStateProvider provider,
  CollabDocKind kind,
) async {
  final collab = provider.collab;
  if (!collab.enabled) return true;
  final preview = collab.previewMerge(kind);
  if (preview == null) return true;
  return _mergeNow(context, provider, kind, beforeSave: true);
}

/// Lists every place both people changed, in words, each with a choice.
/// Returns the choices by conflict path, or null when canceled.
///
/// NOBODY'S WORK GOES BY DEFAULT. Where both can be kept - two pieces of
/// text, or a thing one of you deleted and the other changed - Keep both is
/// already chosen. Where they cannot, nothing is chosen, and Combine waits
/// until each one has been decided by a person looking at both.
Future<Map<String, MergeSide>?> showMergeConflictDialog(
  BuildContext context, {
  required CollabDocKind kind,
  required List<MergeConflict> conflicts,
  required String who,
  bool beforeSave = false,
  Object? doc,
}) {
  final choices = <String, MergeSide?>{
    for (final c in conflicts) c.path: c.canKeepBoth ? MergeSide.both : null,
  };
  final noun = collabDocNoun(kind);
  return showDialog<Map<String, MergeSide>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final theme = Theme.of(ctx);
        final muted = theme.colorScheme.onSurfaceVariant;
        final undecided = choices.values.where((v) => v == null).length;

        String side(Object? value, String person) => value == null
            ? '$person deleted it'
            : '$person: ${describeMergeValue(value)}';

        return AlertDialog(
          key: const ValueKey('collab_conflict_dialog'),
          title: Text('$who saved this $noun while you were working on it'),
          content: SizedBox(
            width: 680,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Everything else from both of you is already combined - '
                  'new items either of you added are all kept. '
                  '${conflicts.length == 1 ? 'One thing was' : '${conflicts.length} '
                      'things were'} changed by both of you, differently. '
                  'Choose what to keep for '
                  '${conflicts.length == 1 ? 'it' : 'each'}.'
                  '${beforeSave ? ' Your save goes ahead once you combine.' : ''}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final c in conflicts)
                        Card(
                          key: ValueKey('collab_conflict_${c.path}'),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  describeMergePlace(c.path, doc),
                                  style: theme.textTheme.titleSmall,
                                ),
                                if (c.base != null)
                                  Text(
                                    'Before either of you changed it: '
                                    '${describeMergeValue(c.base)}',
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(color: muted),
                                  ),
                                RadioGroup<MergeSide>(
                                  groupValue: choices[c.path],
                                  onChanged: (v) =>
                                      setState(() => choices[c.path] = v),
                                  child: Column(
                                    children: [
                                      if (c.canKeepBoth)
                                        RadioListTile<MergeSide>(
                                          key: ValueKey(
                                            'collab_both_${c.path}',
                                          ),
                                          dense: true,
                                          value: MergeSide.both,
                                          title: const Text('Keep both'),
                                          subtitle: Text(
                                            c.mine == null || c.theirs == null
                                                ? 'Keeps it, with the change '
                                                      'that was made to it'
                                                : 'Keeps both versions, one '
                                                      'after the other',
                                          ),
                                        ),
                                      RadioListTile<MergeSide>(
                                        key: ValueKey('collab_mine_${c.path}'),
                                        dense: true,
                                        value: MergeSide.mine,
                                        title: Text(side(c.mine, 'Yours')),
                                      ),
                                      RadioListTile<MergeSide>(
                                        key: ValueKey(
                                          'collab_theirs_${c.path}',
                                        ),
                                        dense: true,
                                        value: MergeSide.theirs,
                                        title: Text(
                                          side(c.theirs, '$who\'s'),
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
                if (undecided > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '$undecided still to choose.',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(beforeSave ? 'Cancel the save' : 'Not now'),
            ),
            FilledButton(
              key: const ValueKey('collab_conflict_apply'),
              onPressed: undecided > 0
                  ? null
                  : () => Navigator.pop(ctx, {
                      for (final e in choices.entries) e.key: e.value!,
                    }),
              child: Text(beforeSave ? 'Combine and save' : 'Combine'),
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
