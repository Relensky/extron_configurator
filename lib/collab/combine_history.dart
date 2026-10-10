import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../safe_write.dart';

/// ============================================================================
///  COMBINE HISTORY
/// ============================================================================
///  Every time somebody combines another person's save into theirs, the
///  combine is logged: which room, which project and campus, who, when, and
///  each line it touched - approved or left out.
///
///     <folder>/combine_history.json          the log
///     <folder>/combine_history.backup.json   its backup, checked after writes
///     <folder>/backups/                      timestamped copies of the log
///                                            and of each file combined over
///
///  Several people write the log on a share, so each write re-reads the log
///  and its backup and keeps every entry either holds (by id).
/// ============================================================================

const String kCombineHistoryFile = 'combine_history.json';
const String kCombineHistoryBackupFile = 'combine_history.backup.json';

/// How many timestamped copies of the log are kept.
const int kCombineHistorySnapshots = 30;

/// One line of a combine: a change from their save, or a place both changed.
class CombineHistoryItem {
  /// The place in words: `Job list > "chase Extron" > Text`.
  final String place;

  /// The place as the merge names it: `todos[id=todo7].text`.
  final String path;
  final String before;
  final String after;

  /// False when the line was left out.
  final bool approved;

  /// True for a place both people changed; [after] is what was kept.
  final bool conflict;

  const CombineHistoryItem({
    required this.place,
    required this.path,
    this.before = '',
    this.after = '',
    this.approved = true,
    this.conflict = false,
  });

  Map<String, dynamic> toJson() => {
        'place': place,
        'path': path,
        if (before.isNotEmpty) 'before': before,
        if (after.isNotEmpty) 'after': after,
        'approved': approved,
        if (conflict) 'conflict': true,
      };

  static CombineHistoryItem fromJson(Map json) => CombineHistoryItem(
        place: json['place']?.toString() ?? '',
        path: json['path']?.toString() ?? '',
        before: json['before']?.toString() ?? '',
        after: json['after']?.toString() ?? '',
        approved: json['approved'] != false,
        conflict: json['conflict'] == true,
      );
}

/// One combine.
class CombineHistoryEntry {
  final String id;
  final DateTime at;

  /// Who combined: login, name, machine.
  final String user;
  final String name;
  final String machine;

  /// Whose save was brought in.
  final String from;

  /// 'room' or 'project'.
  final String document;
  final String room;
  final String project;
  final String campus;

  /// The file combined.
  final String file;

  /// A timestamped copy of [file] as it was on disk before the combine.
  final String backup;

  final List<CombineHistoryItem> items;

  const CombineHistoryEntry({
    required this.id,
    required this.at,
    this.user = '',
    this.name = '',
    this.machine = '',
    this.from = '',
    this.document = 'room',
    this.room = '',
    this.project = '',
    this.campus = '',
    this.file = '',
    this.backup = '',
    this.items = const [],
  });

  String get who => name.trim().isEmpty ? user : name.trim();
  int get approvedCount => items.where((i) => i.approved).length;
  int get declinedCount => items.where((i) => !i.approved).length;

  Map<String, dynamic> toJson() => {
        'id': id,
        'at': at.toUtc().toIso8601String(),
        if (user.isNotEmpty) 'user': user,
        if (name.isNotEmpty) 'name': name,
        if (machine.isNotEmpty) 'machine': machine,
        if (from.isNotEmpty) 'from': from,
        'document': document,
        if (room.isNotEmpty) 'room': room,
        if (project.isNotEmpty) 'project': project,
        if (campus.isNotEmpty) 'campus': campus,
        if (file.isNotEmpty) 'file': file,
        if (backup.isNotEmpty) 'backup': backup,
        'items': [for (final i in items) i.toJson()],
      };

  static CombineHistoryEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id']?.toString() ?? '';
    final at = DateTime.tryParse(json['at']?.toString() ?? '');
    if (id.isEmpty || at == null) return null;
    return CombineHistoryEntry(
      id: id,
      at: at.toLocal(),
      user: json['user']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      machine: json['machine']?.toString() ?? '',
      from: json['from']?.toString() ?? '',
      document: json['document']?.toString() ?? 'room',
      room: json['room']?.toString() ?? '',
      project: json['project']?.toString() ?? '',
      campus: json['campus']?.toString() ?? '',
      file: json['file']?.toString() ?? '',
      backup: json['backup']?.toString() ?? '',
      items: [
        for (final i in (json['items'] as List? ?? const []))
          if (i is Map) CombineHistoryItem.fromJson(i),
      ],
    );
  }
}

/// How the log and its backup compare.
class CombineHistoryCheck {
  final int mainCount;
  final int backupCount;

  /// Entry ids in only one of the two.
  final List<String> onlyInMain;
  final List<String> onlyInBackup;

  const CombineHistoryCheck({
    required this.mainCount,
    required this.backupCount,
    this.onlyInMain = const [],
    this.onlyInBackup = const [],
  });

  bool get matches => onlyInMain.isEmpty && onlyInBackup.isEmpty;
}

/// How the history screen groups entries.
enum CombineHistoryScope { room, project, campus }

/// [entries] grouped by [scope], each group newest first, groups by their
/// newest entry. Entries with no room/project/campus fall under ''.
Map<String, List<CombineHistoryEntry>> groupCombineHistory(
  List<CombineHistoryEntry> entries,
  CombineHistoryScope scope,
) {
  final out = <String, List<CombineHistoryEntry>>{};
  for (final e in entries) {
    final key = switch (scope) {
      CombineHistoryScope.room => e.room,
      CombineHistoryScope.project => e.project,
      CombineHistoryScope.campus => e.campus,
    };
    out.putIfAbsent(key, () => []).add(e);
  }
  for (final list in out.values) {
    list.sort((a, b) => b.at.compareTo(a.at));
  }
  final keys = out.keys.toList()
    ..sort((a, b) => out[b]!.first.at.compareTo(out[a]!.first.at));
  return {for (final k in keys) k: out[k]!};
}

/// `20261009_143005`.
String combineStamp(DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${at.year}${two(at.month)}${two(at.day)}_'
      '${two(at.hour)}${two(at.minute)}${two(at.second)}';
}

class CombineHistoryStore {
  final String folder;
  const CombineHistoryStore(this.folder);

  String get mainPath => path.join(folder, kCombineHistoryFile);
  String get backupPath => path.join(folder, kCombineHistoryBackupFile);
  String get snapshotFolder => path.join(folder, 'backups');

  static Future<List<CombineHistoryEntry>> _read(String file) async {
    try {
      final f = File(file);
      if (!await f.exists()) return const [];
      final json = jsonDecode(await f.readAsString());
      final list = json is Map ? json['entries'] : json;
      if (list is! List) return const [];
      return [
        for (final e in list)
          ?CombineHistoryEntry.fromJson(e),
      ];
    } catch (_) {
      return const [];
    }
  }

  static List<CombineHistoryEntry> _union(
    List<CombineHistoryEntry> a,
    List<CombineHistoryEntry> b,
  ) {
    final byId = <String, CombineHistoryEntry>{
      for (final e in a) e.id: e,
    };
    for (final e in b) {
      byId.putIfAbsent(e.id, () => e);
    }
    return byId.values.toList()..sort((x, y) => x.at.compareTo(y.at));
  }

  /// The log and its backup combined, oldest first.
  Future<List<CombineHistoryEntry>> load() async =>
      _union(await _read(mainPath), await _read(backupPath));

  /// Compares the log with its backup.
  Future<CombineHistoryCheck> check() async {
    final main = await _read(mainPath);
    final backup = await _read(backupPath);
    final m = {for (final e in main) e.id};
    final b = {for (final e in backup) e.id};
    return CombineHistoryCheck(
      mainCount: main.length,
      backupCount: backup.length,
      onlyInMain: [for (final id in m) if (!b.contains(id)) id],
      onlyInBackup: [for (final id in b) if (!m.contains(id)) id],
    );
  }

  static String _encode(List<CombineHistoryEntry> entries) =>
      const JsonEncoder.withIndent('  ').convert({
        'entries': [for (final e in entries) e.toJson()],
      });

  /// Writes the log and its backup from both combined, plus a timestamped
  /// copy, then checks the two match. Returns '' or what went wrong.
  Future<String> repair() => _write(const []);

  /// Adds [entry]. Returns '' or what went wrong.
  Future<String> append(CombineHistoryEntry entry) => _write([entry]);

  Future<String> _write(List<CombineHistoryEntry> add) async {
    try {
      await Directory(snapshotFolder).create(recursive: true);
      final all = _union(await load(), add);
      final text = _encode(all);
      await writeFileSafely(mainPath, text);
      await writeFileSafely(backupPath, text);
      final stamp = combineStamp(DateTime.now());
      await writeFileSafely(
        path.join(snapshotFolder, 'combine_history_$stamp.json'),
        text,
      );
      _pruneSnapshots();
      // The backup has to say what the log says.
      var check = await this.check();
      if (!check.matches) {
        final merged = _encode(await load());
        await writeFileSafely(mainPath, merged);
        await writeFileSafely(backupPath, merged);
        check = await this.check();
      }
      if (!check.matches) {
        return 'The combine history and its backup do not match '
            '(${check.mainCount} and ${check.backupCount} entries).';
      }
      return '';
    } catch (e) {
      return 'The combine history could not be saved: $e';
    }
  }

  void _pruneSnapshots() {
    try {
      final copies = Directory(snapshotFolder)
          .listSync()
          .whereType<File>()
          .where((f) =>
              path.basename(f.path).startsWith('combine_history_') &&
              f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final old in copies.skip(kCombineHistorySnapshots)) {
        old.deleteSync();
      }
    } catch (_) {}
  }

  /// Copies [file] to the backups folder as `<name>_<stamp>.json`. Returns
  /// the copy, or '' when it could not be made.
  Future<String> backupDocument(String file, {DateTime? at}) async {
    try {
      final source = File(file);
      if (!await source.exists()) return '';
      await Directory(snapshotFolder).create(recursive: true);
      final stem = path.basenameWithoutExtension(file);
      final target = path.join(
        snapshotFolder,
        '${stem}_${combineStamp(at ?? DateTime.now())}${path.extension(file)}',
      );
      await source.copy(target);
      return target;
    } catch (_) {
      return '';
    }
  }
}
