import 'dart:io';

import 'package:path/path.dart' as path;

/// ============================================================================
///  THE FILES THIS APP HAS OPENED OR WRITTEN
/// ============================================================================
///  Every document here is a .json in a folder somebody picked, and the folder
///  is usually four levels down a share. So the second time a room is wanted,
///  the work is not opening it - it is FINDING it again: the same drive, the
///  same building folder, the same guess at which of the eleven files is the
///  one from Tuesday. The file dialog remembers a folder; it does not remember
///  a document.
///
///  So the app does. Ten of each, most recent first, kept in app_config.json
///  beside every other setting - see [AppStateProvider.recentFiles].
///
///  OPENED OR SAVED, because half the documents in this app are never opened
///  at all: a room comes out of the wizard, a job out of New Project, an
///  estate out of a list somebody assembled by hand. Each of those becomes a
///  file at its first SAVE, and a list that only watched the open door would
///  have nothing to say about the room somebody built this morning.
///
///  BROKEN UP BY KIND, and that is the whole point of it. A room, a job and a
///  campus are three different documents that all live as .json in the same
///  folders, and one mixed list of thirty is a list somebody has to read
///  rather than glance at. Somebody looking for last week's estimate is
///  looking for a PROJECT, and the ten projects are where they can see them.
///
///  IT HOLDS PATHS, NOT CONTENT. An entry is a pointer and a name; opening one
///  re-reads the file off disk exactly as Open would, so a room edited by
///  somebody else since is that room as it is now. A file that has been moved
///  or deleted is not an error either - it stays on the list, drawn as gone,
///  until somebody either restores it or drops it.
/// ============================================================================

/// How many of each kind are kept.
///
/// Ten is a list that is READ AT A GLANCE - it fits a menu without scrolling
/// and it covers a working week. A longer list is an archive, and the place to
/// look for a document from last month is the folder it lives in.
const int kRecentFilesPerKind = 10;

/// The three documents this app opens and writes, which is the three lists it
/// keeps.
enum RecentKind {
  room,
  project,
  campus;

  /// What one of them is called mid-sentence.
  String get one => switch (this) {
        RecentKind.room => 'room',
        RecentKind.project => 'project',
        RecentKind.campus => 'campus',
      };

  /// The heading over a list of them.
  String get heading => switch (this) {
        RecentKind.room => 'Rooms',
        RecentKind.project => 'Projects',
        RecentKind.campus => 'Campuses',
      };
}

/// One document the app has had open: where it is, what it was called, and
/// when it was last touched.
class RecentFile {
  const RecentFile({
    required this.file,
    required this.name,
    required this.touchedAt,
  });

  /// Absolute path of the document.
  final String file;

  /// What the document called itself when it was read - the room's full name,
  /// the job's name, the campus's name. Blank for a document that had none.
  final String name;

  /// When the app last opened or wrote it. Sorting is by list position rather
  /// than by this, but it is what a list line can say out loud.
  final DateTime touchedAt;

  /// What the list shows. A document with no name of its own falls back to its
  /// file name, which is never blank.
  String get label {
    final trimmed = name.trim();
    return trimmed.isNotEmpty
        ? trimmed
        : path.basenameWithoutExtension(file);
  }

  /// The folder it sits in - the half that tells two rooms with the same name
  /// on two jobs apart.
  String get folder => path.dirname(file);

  /// False once the file has been moved, renamed or deleted out from under the
  /// list. Checked when the list is drawn rather than when it is written: a
  /// share that is offline for an afternoon must not empty somebody's history.
  bool get stillThere {
    try {
      return File(file).existsSync();
    } catch (_) {
      return false;
    }
  }

  Map<String, dynamic> toJson() => {
        'file': file,
        'name': name,
        'touchedAt': touchedAt.toIso8601String(),
      };

  /// Reads one line back, or null for anything that is not a usable entry -
  /// app_config.json is hand-editable, so a broken row is a row to skip rather
  /// than a startup failure.
  static RecentFile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final file = raw['file']?.toString().trim() ?? '';
    if (file.isEmpty) return null;
    return RecentFile(
      file: file,
      name: raw['name']?.toString() ?? '',
      touchedAt: DateTime.tryParse(raw['touchedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// The three lists, and the two things ever done to them: remember one, and
/// take one off.
class RecentFiles {
  RecentFiles();

  final Map<RecentKind, List<RecentFile>> _lists = {
    for (final kind in RecentKind.values) kind: <RecentFile>[],
  };

  /// The [kind] list, most recently touched first.
  List<RecentFile> operator [](RecentKind kind) =>
      List.unmodifiable(_lists[kind]!);

  /// True when nothing of any kind has been opened or saved yet - a cold
  /// install, and the one case where there is nothing to show anybody.
  bool get isEmpty =>
      RecentKind.values.every((kind) => _lists[kind]!.isEmpty);

  bool get isNotEmpty => !isEmpty;

  /// How many entries there are across all three.
  int get length =>
      RecentKind.values.fold(0, (sum, kind) => sum + _lists[kind]!.length);

  /// TWO SPELLINGS OF ONE FILE ARE ONE FILE. `C:\Jobs\bss.json` and
  /// `c:/jobs/./bss.json` are the same document, and a list that carried both
  /// would spend two of its ten lines on it. Windows is case-insensitive and
  /// [path.canonicalize] knows that; the original spelling is what gets stored
  /// and shown.
  static String _key(String file) {
    try {
      return path.canonicalize(file);
    } catch (_) {
      return file;
    }
  }

  /// Puts [file] at the top of the [kind] list - it has just been opened or
  /// written. Returns true when the list actually changed, so a caller can
  /// skip a save and a repaint for a room that was already the top line.
  ///
  /// [name] is what the document calls itself; blank keeps whatever name the
  /// entry already had rather than replacing it with nothing.
  bool remember(
    RecentKind kind,
    String file, {
    String name = '',
    DateTime? at,
  }) {
    final trimmed = file.trim();
    if (trimmed.isEmpty) return false;
    final list = _lists[kind]!;
    final key = _key(trimmed);
    final int was = list.indexWhere((entry) => _key(entry.file) == key);
    final RecentFile? previous = was < 0 ? null : list[was];
    final String label =
        name.trim().isNotEmpty ? name.trim() : (previous?.name ?? '');
    final bool unchanged = was == 0 &&
        previous!.file == trimmed &&
        previous.name == label;
    if (was >= 0) list.removeAt(was);
    list.insert(
      0,
      RecentFile(file: trimmed, name: label, touchedAt: at ?? DateTime.now()),
    );
    if (list.length > kRecentFilesPerKind) {
      list.removeRange(kRecentFilesPerKind, list.length);
    }
    return !unchanged;
  }

  /// Drops one entry. Returns true when there was one to drop.
  bool forget(RecentKind kind, String file) {
    final list = _lists[kind]!;
    final key = _key(file);
    final before = list.length;
    list.removeWhere((entry) => _key(entry.file) == key);
    return list.length != before;
  }

  /// Empties one list, or all three when [kind] is left out. Returns true when
  /// there was anything to empty.
  bool clear([RecentKind? kind]) {
    bool changed = false;
    for (final k in kind == null ? RecentKind.values : [kind]) {
      if (_lists[k]!.isEmpty) continue;
      _lists[k]!.clear();
      changed = true;
    }
    return changed;
  }

  Map<String, dynamic> toJson() => {
        for (final kind in RecentKind.values)
          kind.name: [for (final entry in _lists[kind]!) entry.toJson()],
      };

  /// Reads the lists back off app_config.json. Anything unreadable comes back
  /// as an empty list - a history is a convenience, and losing one must never
  /// be the reason the app will not start.
  factory RecentFiles.fromJson(Object? raw) {
    final store = RecentFiles();
    if (raw is! Map) return store;
    for (final kind in RecentKind.values) {
      final rows = raw[kind.name];
      if (rows is! List) continue;
      final list = store._lists[kind]!;
      for (final row in rows) {
        if (list.length >= kRecentFilesPerKind) break;
        final entry = RecentFile.fromJson(row);
        if (entry == null) continue;
        if (list.any((e) => _key(e.file) == _key(entry.file))) continue;
        list.add(entry);
      }
    }
    return store;
  }
}
