import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'recent_files.dart';

/// ============================================================================
///  OPEN RECENT
/// ============================================================================
///  The list kept in recent_files.dart, drawn in the two places somebody looks
///  for a document they have had open before: a menu beside Open in the title
///  bar, and a panel under the Open button on the start screen.
///
///  THREE LISTS, NOT ONE. The kinds are headed and kept apart, because "the
///  job I was quoting on Friday" and "the room I was drawing on Friday" are
///  two different questions, and thirty mixed lines answers neither of them at
///  a glance. See recent_files.dart.
///
///  A LINE POINTING AT NOTHING SAYS SO. Files get moved, renamed and archived,
///  and a menu that quietly failed - or worse, dropped the line the moment the
///  share was slow - would be a menu nobody trusted. A missing file is drawn
///  struck through, and choosing it offers to take it off the list rather than
///  pretending it opened.
/// ============================================================================

/// What one entry looks like on the two lists.
IconData recentKindIcon(RecentKind kind) => switch (kind) {
      RecentKind.room => Icons.meeting_room_outlined,
      RecentKind.project => Icons.account_tree_outlined,
      RecentKind.campus => Icons.location_city,
    };

/// Opens one entry, or explains why it cannot be opened.
///
/// [onOpen] is the app's ONE open pipeline - the same function the folder
/// button hands a picked file to. A recent file is not a special kind of open:
/// it is the same load, the same conversion notice, the same sidecar sync, and
/// anything less would make a room opened from this menu a different room from
/// the same file opened by hand.
Future<void> openRecentFile(
  BuildContext context,
  RecentKind kind,
  RecentFile entry,
  Future<void> Function(String file) onOpen,
) async {
  final provider = context.read<AppStateProvider>();
  if (!entry.stillThere) {
    final messenger = ScaffoldMessenger.of(context);
    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          '${entry.label} is not at ${entry.file} any more. It may have been '
          'moved, renamed or archived.',
        ),
        action: SnackBarAction(
          label: 'DROP IT',
          onPressed: () => provider.forgetRecentFile(kind, entry.file),
        ),
      ),
    );
    return;
  }
  await onOpen(entry.file);
}

/// The date on a line: today and yesterday by name, everything else by date.
/// A time of day is not worth the width - what somebody is placing is which
/// day they last had the file in front of them, not which hour.
String recentWhen(DateTime when, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final days = DateTime(today.year, today.month, today.day)
      .difference(DateTime(when.year, when.month, when.day))
      .inDays;
  if (days <= 0) return 'today';
  if (days == 1) return 'yesterday';
  if (days < 7) return '$days days ago';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${when.year}-${two(when.month)}-${two(when.day)}';
}

/// What a menu line or a panel row picked.
class _RecentChoice {
  const _RecentChoice.file(this.kind, this.entry);
  const _RecentChoice.clear()
      : kind = null,
        entry = null;

  final RecentKind? kind;
  final RecentFile? entry;
}

/// The title bar's Open Recent - a menu beside the folder button.
///
/// ITS OWN BUTTON RATHER THAN A MENU OVER OPEN. Open is one press and always
/// has been, and burying a file dialog one level down a menu to make room for
/// a list would cost every user a click forever to save some of them one. So
/// it is the split-button pair the Save group already uses: the act on the
/// left, the ways of doing it on the right.
///
/// Disabled on a cold install, and it says why - a grayed button with no
/// explanation is a button somebody keeps pressing.
class RecentFilesButton extends StatelessWidget {
  const RecentFilesButton({super.key, required this.onOpen});

  /// The app's open pipeline - see [openRecentFile].
  final Future<void> Function(String file) onOpen;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final recents = provider.recentFiles;
    final theme = Theme.of(context);

    if (recents.isEmpty) {
      return IconButton(
        key: const ValueKey('open_recent_empty'),
        icon: const Icon(Icons.history_toggle_off),
        tooltip: 'Open Recent - nothing has been opened or saved on this '
            'machine yet. Rooms, projects and campuses land here as they are '
            'opened, and as they are first written.',
        onPressed: null,
      );
    }

    return PopupMenuButton<_RecentChoice>(
      key: const ValueKey('open_recent'),
      icon: const Icon(Icons.schedule),
      tooltip: 'Open Recent - the last $kRecentFilesPerKind rooms, projects '
          'and campuses this app opened or saved',
      onSelected: (choice) {
        final entry = choice.entry;
        if (entry == null) {
          provider.clearRecentFiles();
          return;
        }
        // ignore: unawaited_futures
        openRecentFile(context, choice.kind!, entry, onOpen);
      },
      itemBuilder: (ctx) {
        final items = <PopupMenuEntry<_RecentChoice>>[];
        for (final kind in RecentKind.values) {
          final list = recents[kind];
          if (list.isEmpty) continue;
          if (items.isNotEmpty) items.add(const PopupMenuDivider());
          items.add(
            PopupMenuItem<_RecentChoice>(
              enabled: false,
              height: 30,
              child: Text(
                kind.heading.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.disabledColor,
                  letterSpacing: 1.1,
                ),
              ),
            ),
          );
          for (final entry in list) {
            items.add(
              PopupMenuItem<_RecentChoice>(
                value: _RecentChoice.file(kind, entry),
                child: _RecentLine(kind: kind, entry: entry),
              ),
            );
          }
        }
        items
          ..add(const PopupMenuDivider())
          ..add(
            PopupMenuItem<_RecentChoice>(
              key: const ValueKey('clear_recent'),
              value: const _RecentChoice.clear(),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.playlist_remove, size: 18),
                title: const Text('Clear the list'),
                subtitle: Text(
                  'Forgets all ${recents.length} of them. No file is touched.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.disabledColor),
                ),
              ),
            ),
          );
        return items;
      },
    );
  }
}

/// One document on the menu: what it is called, and the folder it is in.
///
/// THE FOLDER IS HALF THE LINE. Nine jobs out of ten have a room called
/// 'Conference Room', and a list of five of them with nothing to tell them
/// apart is a list somebody has to open one at a time.
class _RecentLine extends StatelessWidget {
  const _RecentLine({required this.kind, required this.entry});

  final RecentKind kind;
  final RecentFile entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gone = !entry.stillThere;
    final quiet =
        theme.textTheme.bodySmall?.copyWith(color: theme.disabledColor);
    return SizedBox(
      // The same width the save menu uses, so the two menus in the title bar
      // are the same shape rather than two different sizes of the same thing.
      width: 380,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 12),
            child: Icon(
              gone ? Icons.link_off : recentKindIcon(kind),
              size: 18,
              color: gone ? theme.disabledColor : null,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.label,
                        overflow: TextOverflow.ellipsis,
                        style: gone
                            ? TextStyle(
                                color: theme.disabledColor,
                                decoration: TextDecoration.lineThrough,
                              )
                            : null,
                      ),
                    ),
                    Text(recentWhen(entry.touchedAt), style: quiet),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  gone ? 'Not there any more - ${entry.folder}' : entry.folder,
                  style: quiet,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The start screen's half of the same list: the three kinds side by side,
/// under the Open button.
///
/// A MENU IS FOR SOMEBODY WHO KNOWS WHAT THEY WANT; a start screen is for
/// somebody who has just launched the app and is deciding. So here the three
/// lists are open on the page rather than one click behind an icon - the whole
/// question "what was I working on" is answered without pressing anything.
///
/// Nothing at all when nothing has ever been opened: three empty boxes on a
/// first launch would be three questions about a feature that has not had a
/// chance to do anything yet.
class RecentFilesPanel extends StatelessWidget {
  const RecentFilesPanel({super.key, required this.onOpen});

  /// The app's open pipeline - see [openRecentFile].
  final Future<void> Function(String file) onOpen;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final recents = provider.recentFiles;
    if (recents.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Column(
      key: const ValueKey('start_recent'),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Recent files', style: theme.textTheme.titleMedium),
            const SizedBox(width: 12),
            TextButton(
              key: const ValueKey('start_recent_clear'),
              onPressed: () => provider.clearRecentFiles(),
              child: const Text('Clear'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'The last $kRecentFilesPerKind of each that was opened or saved, '
          'most recent first. Opening one re-reads the file, so it is the '
          'document as it stands now.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.disabledColor),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 16,
          runSpacing: 16,
          children: [
            for (final kind in RecentKind.values)
              if (recents[kind].isNotEmpty)
                _RecentColumn(
                  kind: kind,
                  entries: recents[kind],
                  onOpen: onOpen,
                ),
          ],
        ),
      ],
    );
  }
}

/// One kind's column on the start screen.
class _RecentColumn extends StatelessWidget {
  const _RecentColumn({
    required this.kind,
    required this.entries,
    required this.onOpen,
  });

  final RecentKind kind;
  final List<RecentFile> entries;
  final Future<void> Function(String file) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      // Three of these fit a wide window side by side and wrap on a narrow
      // one, exactly like the two cards above them.
      width: 340,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Icon(recentKindIcon(kind),
                        size: 18, color: theme.disabledColor),
                    const SizedBox(width: 8),
                    Text(
                      kind.heading,
                      style: theme.textTheme.titleSmall,
                    ),
                  ],
                ),
              ),
              for (final entry in entries)
                _RecentRow(kind: kind, entry: entry, onOpen: onOpen),
            ],
          ),
        ),
      ),
    );
  }
}

/// One clickable line in a start-screen column.
class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.kind,
    required this.entry,
    required this.onOpen,
  });

  final RecentKind kind;
  final RecentFile entry;
  final Future<void> Function(String file) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gone = !entry.stillThere;
    return Tooltip(
      message: gone
          ? '${entry.file}\nNot there any more'
          : '${entry.file}\nLast used ${recentWhen(entry.touchedAt)}',
      child: InkWell(
        onTap: () => openRecentFile(context, kind, entry, onOpen),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                entry.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: gone
                    ? theme.textTheme.bodyMedium?.copyWith(
                        color: theme.disabledColor,
                        decoration: TextDecoration.lineThrough,
                      )
                    : theme.textTheme.bodyMedium,
              ),
              Text(
                gone ? 'Not there any more' : entry.folder,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.disabledColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
