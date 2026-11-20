import 'online_room_edits.dart' show kRoomLineKind;
import 'online_roundtrip.dart' show OnlineChange, kMasterSheet;
import 'online_sheet_merge.dart' show kSheetEditKind;

/// ============================================================================
///  A PULL, BY ROOM AND BY PART OF THE JOB
/// ============================================================================
///  A pull can find hundreds of edits. Listed one after another they read as
///  one long wall; grouped, the review says which rooms and which parts of
///  the job (parts, deliveries, purchase orders, a report tab) changed, and
///  what was added to each.
/// ============================================================================

/// The changes a pull found in one room or one part of the job.
class OnlineChangeGroup {
  /// `room:<id>`, 'parts', 'deliveries', 'purchase orders', `tab:<name>`.
  final String key;

  /// What the reader calls it: the room's name, 'Deliveries', a tab's name.
  final String title;

  /// True for a room.
  final bool room;

  final List<OnlineChange> changes;

  OnlineChangeGroup({
    required this.key,
    required this.title,
    required this.changes,
    this.room = false,
  });

  /// Changes an import acts on.
  int get applied => changes.where((c) => c.kind != kSheetEditKind).length;

  /// Changes only listed, to be made by hand.
  int get byHand => changes.length - applied;

  /// The names of what was added: new deliveries and POs, rows added to a
  /// tab.
  List<String> get added => [
        for (final c in changes)
          if (onlineChangeIsAdd(c)) onlineChangeLabel(c, this),
      ];

  /// How many lines were removed.
  int get removed => changes.where(onlineChangeIsRemove).length;

  /// '2 added, 1 removed, 3 changed'.
  String get summary {
    final add = added.length, gone = removed;
    final changed = changes.length - add - gone;
    return [
      if (add > 0) '$add added',
      if (gone > 0) '$gone removed',
      if (changed > 0) '$changed changed',
    ].join(', ');
  }
}

/// True for a change that adds something.
bool onlineChangeIsAdd(OnlineChange c) =>
    c.what.startsWith('added') || c.what.startsWith('row added');

/// True for a change that takes something away.
bool onlineChangeIsRemove(OnlineChange c) =>
    c.what.startsWith('row removed') ||
    c.what.startsWith('row deleted') ||
    c.what.endsWith('line removed');

/// What one change is called inside its group, the group's name left off:
/// 'Projector' rather than 'Room 101: Projector'.
String onlineChangeLabel(OnlineChange c, OnlineChangeGroup group) {
  final name = c.name.trim();
  if (c.kind == kSheetEditKind && c.what.startsWith('row ')) {
    // 'row added or changed to: Projector | 1 | ...' - the row's first cells.
    final colon = c.what.indexOf(': ');
    if (colon > 0) {
      final cells = c.what
          .substring(colon + 2)
          .split(' | ')
          .where((s) => s.trim().isNotEmpty)
          .take(2)
          .join(' - ');
      if (cells.isNotEmpty) return cells;
    }
  }
  for (final prefix in ['${group.title}: ', '${group.title}, ']) {
    if (name.startsWith(prefix)) return name.substring(prefix.length);
  }
  // A report tab's row: 'All Items, row 4 (...)' -> 'row 4 (...)'.
  if (c.kind == kSheetEditKind && c.id.isNotEmpty && name.startsWith('${c.id}, ')) {
    return name.substring(c.id.length + 2);
  }
  return name.isEmpty ? c.kind : name;
}

/// [changes] by room, then parts, deliveries, purchase orders, then every
/// other tab, each in the order first met.
///
/// [roomTabs] is each room's tab in the published copy: tab -> the room's id
/// and name.
List<OnlineChangeGroup> groupOnlineChanges(
  List<OnlineChange> changes, {
  Map<String, ({String id, String name})> roomTabs = const {},
}) {
  final roomName = {for (final r in roomTabs.values) r.id: r.name};
  final rooms = <String, OnlineChangeGroup>{};
  final fixed = <String, OnlineChangeGroup>{};
  final tabs = <String, OnlineChangeGroup>{};

  void room(String id, String name, OnlineChange c) => (rooms['room:$id'] ??=
          OnlineChangeGroup(
              key: 'room:$id', title: name, room: true, changes: []))
      .changes
      .add(c);

  void section(String key, String title, OnlineChange c) =>
      (fixed[key] ??= OnlineChangeGroup(key: key, title: title, changes: []))
          .changes
          .add(c);

  for (final c in changes) {
    switch (c.kind) {
      case kRoomLineKind:
        final id = c.id.split('|').first;
        final colon = c.name.indexOf(': ');
        final name = roomName[id] ??
            (colon > 0 ? c.name.substring(0, colon) : 'A room');
        room(id, name, c);
      case 'part':
        section('parts', 'Parts ($kMasterSheet)', c);
      case 'delivery':
        section('deliveries', 'Deliveries', c);
      case 'purchase order':
        section('purchase orders', 'Purchase orders', c);
      case kSheetEditKind:
        final r = roomTabs[c.id];
        if (r != null) {
          room(r.id, r.name, c);
        } else {
          // No tab: a note such as 'Room quantities' - named as it is.
          final tab = c.id.isEmpty ? c.name : c.id;
          (tabs['tab:$tab'] ??= OnlineChangeGroup(
                  key: 'tab:$tab',
                  title: c.id.isEmpty ? tab : '$tab tab',
                  changes: []))
              .changes
              .add(c);
        }
      default:
        section(c.kind, c.kind, c);
    }
  }
  return [
    ...rooms.values,
    for (final k in ['parts', 'deliveries', 'purchase orders'])
      ?fixed[k],
    for (final e in fixed.entries)
      if (!const {'parts', 'deliveries', 'purchase orders'}.contains(e.key))
        e.value,
    ...tabs.values,
  ];
}
