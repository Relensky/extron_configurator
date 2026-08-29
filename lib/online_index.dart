import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'building_project.dart' show formatIsoDate, parseIsoDate;
import 'report_tools.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  WHAT IS IN THE FOLDER, AND WHAT BELONGS TO WHAT
/// ============================================================================
///  Publishing put a campus, its jobs and their rooms into one folder under
///  names that sort beside each other. That makes the folder browsable. It does
///  not make it READABLE: eleven jobs and ninety rooms is a hundred files, and
///  a person opening the folder cold has no way to tell which rooms are in
///  Bessey, which job is on which campus, or which of them was published in
///  March and forgotten.
///
///  So every publish also writes an INDEX: `index.json` for anything that wants
///  to read the folder, and `index.xlsx` for the person who opens it. One row
///  per document, saying what it is, what it belongs to, what it holds, when it
///  last went out, and which files are its own.
///
///  IT ACCUMULATES. Each publish reads what is already there, upserts its own
///  entry, and writes the whole thing back — so the index describes everything
///  ever published into the folder rather than only the last thing. A campus
///  published in March is still on it in June, with the date that says how old
///  it is.
///
///  THE LINK IS THE SOURCE PATH, not a name and not a file stem. A campus file
///  lists its projects by path and a project lists its rooms by path — those
///  are the joins the documents themselves already carry, and they are exact.
///  Names collide ("Room 101" in four buildings) and stems drift the moment
///  somebody renames a job; a path does neither.
///
///  A CHILD WITH NO ENTRY IS THE MOST USEFUL ROW ON THE SHEET. A job on the
///  campus that nobody has ever published, a room in the job that is not in the
///  folder — those are what somebody is looking for when they open the index
///  and cannot find what they were sent to read.
/// ============================================================================

/// The index's two files. Named so they sort to the top of the folder.
const String kOnlineIndexJson = 'index.json';
const String kOnlineIndexWorkbook = 'index.xlsx';

/// One published document, and what it is joined to.
typedef OnlineIndexEntry = ({
  /// 'campus', 'project' or 'room'.
  String kind,

  /// What to call it: 'Chico', 'Bessey Hall', 'BSS 103'.
  String name,

  /// The local path of the document this was published FROM — the campus file,
  /// the project file, the room config. The row's identity; see the note above
  /// on why the join is a path.
  String source,

  /// The path of the campus or job it belongs to, or '' when the publisher did
  /// not know. A room published on its own does not know its job; the job's own
  /// entry names the room, which is the same link read from the other end.
  String parent,

  /// The paths of the jobs or rooms it holds.
  List<String> children,

  /// The file names it wrote into the folder.
  List<String> files,

  /// One line of fact — '9 rooms', 'project number BSS-4412'.
  String note,

  /// When it was last published.
  DateTime at,
});

/// Paths compared the way the file system means them: a job listing
/// `C:\AV\Bessey\bss_project.json` and a campus listing
/// `C:/AV/Bessey/BSS_PROJECT.JSON` are the same document.
String normalizeSourcePath(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  return path.normalize(trimmed).replaceAll(r'\', '/').toLowerCase();
}

/// The index as it stands in [folder], or an empty list when there is none.
///
/// A file that cannot be read or parsed comes back EMPTY rather than throwing.
/// An index is a convenience built from the folder's own contents; a corrupt
/// one must never be the reason a publish fails, and the next publish rebuilds
/// what it knows.
List<OnlineIndexEntry> readOnlineIndex(String folder) {
  try {
    final file = File(path.join(folder, kOnlineIndexJson));
    if (!file.existsSync()) return [];
    final doc = jsonDecode(file.readAsStringSync());
    if (doc is! Map || doc['entries'] is! List) return [];
    final out = <OnlineIndexEntry>[];
    for (final raw in doc['entries'] as List) {
      if (raw is! Map) continue;
      final source = raw['source']?.toString() ?? '';
      if (source.isEmpty) continue;
      out.add((
        kind: raw['kind']?.toString() ?? '',
        name: raw['name']?.toString() ?? '',
        source: source,
        parent: raw['parent']?.toString() ?? '',
        children: [
          for (final c in (raw['children'] as List? ?? [])) c.toString(),
        ],
        files: [for (final f in (raw['files'] as List? ?? [])) f.toString()],
        note: raw['note']?.toString() ?? '',
        at: parseIsoDate(raw['at']) ?? DateTime.now(),
      ));
    }
    return out;
  } catch (_) {
    return [];
  }
}

/// [existing] with [fresh] written over it, matched on [OnlineIndexEntry.source].
///
/// WHAT THE NEW ENTRY DOES NOT KNOW, THE OLD ONE KEEPS. A room published on its
/// own cannot say which job it is in — and if that blanked the parent recorded
/// when the job was published, the index would lose links every time somebody
/// republished a single room. The same for children: a publisher that lists
/// none is one that was not asked, not one whose rooms have gone.
List<OnlineIndexEntry> mergeOnlineIndex(
  List<OnlineIndexEntry> existing,
  List<OnlineIndexEntry> fresh,
) {
  final out = [...existing];
  for (final entry in fresh) {
    final key = normalizeSourcePath(entry.source);
    if (key.isEmpty) continue;
    final at = out.indexWhere((e) => normalizeSourcePath(e.source) == key);
    if (at < 0) {
      out.add(entry);
      continue;
    }
    final was = out[at];
    out[at] = (
      kind: entry.kind.isEmpty ? was.kind : entry.kind,
      name: entry.name.isEmpty ? was.name : entry.name,
      source: entry.source,
      parent: entry.parent.isEmpty ? was.parent : entry.parent,
      children: entry.children.isEmpty ? was.children : entry.children,
      files: entry.files.isEmpty ? was.files : entry.files,
      note: entry.note.isEmpty ? was.note : entry.note,
      at: entry.at,
    );
  }
  return out;
}

/// The index as JSON, for anything that wants to read the folder.
String onlineIndexJson(List<OnlineIndexEntry> entries, {DateTime? at}) {
  final ordered = sortOnlineIndex(entries);
  return const JsonEncoder.withIndent('    ').convert({
    '__readme':
        'What is published in this folder and what belongs to what. Written '
        'by Room Config Builder every time something is published here. '
        'Documents are joined by "source", the path each was published from. '
        'Safe to delete: the next publish writes it again.',
    'generated': (at ?? DateTime.now()).toIso8601String(),
    'entries': [
      for (final e in ordered)
        {
          'kind': e.kind,
          'name': e.name,
          'source': e.source,
          if (e.parent.isNotEmpty) 'parent': e.parent,
          if (e.children.isNotEmpty) 'children': e.children,
          'files': e.files,
          if (e.note.isNotEmpty) 'note': e.note,
          'at': formatIsoDate(e.at),
        },
    ],
  });
}

/// Campus first, then the jobs on it, then the rooms in those — and whatever is
/// left over after them.
///
/// The order the folder is READ in. A flat list sorted by name would put a room
/// between two campuses and leave somebody working out the shape for
/// themselves.
List<OnlineIndexEntry> sortOnlineIndex(List<OnlineIndexEntry> entries) {
  final bySource = {
    for (final e in entries) normalizeSourcePath(e.source): e,
  };
  final used = <String>{};
  final out = <OnlineIndexEntry>[];

  void take(OnlineIndexEntry entry) {
    final key = normalizeSourcePath(entry.source);
    if (!used.add(key)) return;
    out.add(entry);
    for (final child in entry.children) {
      final found = bySource[normalizeSourcePath(child)];
      if (found != null) take(found);
    }
  }

  for (final kind in ['campus', 'project', 'room']) {
    for (final e in entries) {
      if (e.kind != kind) continue;
      // A job that belongs to a campus in this folder is reached through it,
      // so it is not started from here.
      final parent = bySource[normalizeSourcePath(e.parent)];
      if (parent != null && !used.contains(normalizeSourcePath(e.source))) {
        continue;
      }
      take(e);
    }
  }
  // Anything a parent claimed but the loop above never reached — a child whose
  // parent is not in this folder at all.
  for (final e in entries) {
    take(e);
  }
  return out;
}

/// The index as a sheet somebody can open.
XlsxSheet buildOnlineIndexSheet(
  List<OnlineIndexEntry> entries, {
  DateTime? at,
}) {
  final ordered = sortOnlineIndex(entries);
  final bySource = {
    for (final e in entries) normalizeSourcePath(e.source): e,
  };

  String nameOf(String source) {
    final found = bySource[normalizeSourcePath(source)];
    if (found != null) return found.name;
    return source.trim().isEmpty ? '' : path.basename(source);
  }

  String holds(OnlineIndexEntry e) {
    if (e.children.isEmpty) return '';
    final here = e.children
        .where((c) => bySource.containsKey(normalizeSourcePath(c)))
        .length;
    final what = e.kind == 'campus' ? 'job' : 'room';
    return here == e.children.length
        ? '${e.children.length} $what${e.children.length == 1 ? '' : 's'}'
        : '$here of ${e.children.length} '
              '$what${e.children.length == 1 ? '' : 's'} published';
  }

  final sections = <ReportSection>[
    (
      title: 'Published here (${ordered.length})',
      header: const [
        'Kind',
        'Name',
        'Belongs to',
        'Holds',
        'Published',
        'Files',
        'Notes',
      ],
      rows: [
        for (final e in ordered)
          [
            e.kind,
            e.name,
            nameOf(e.parent),
            holds(e),
            formatIsoDate(e.at),
            // The file NAMES rather than a link: a share link points at the
            // folder, and the name is what somebody picks out of the listing.
            e.files.join('\n'),
            e.note,
          ],
      ],
    ),
  ];

  // WHAT IS MISSING. A job on the campus that nobody ever published, a room in
  // the job that is not in this folder: the row somebody is looking for when
  // they cannot find what they were sent to read.
  final missing = <List<dynamic>>[];
  for (final e in ordered) {
    for (final child in e.children) {
      if (bySource.containsKey(normalizeSourcePath(child))) continue;
      missing.add([
        e.kind == 'campus' ? 'job' : 'room',
        path.basenameWithoutExtension(child),
        e.name,
        child,
      ]);
    }
  }
  if (missing.isNotEmpty) {
    sections.add((
      title: 'On the job but not in this folder (${missing.length})',
      header: const ['Kind', 'Name', 'Named by', 'Where it is'],
      rows: missing,
    ));
  }

  return buildStackedReportSheet(
    sheetName: 'Index',
    title: 'What is published in this folder',
    sections: sections,
    generated: at,
  );
}

/// The index workbook's bytes.
List<int> buildOnlineIndexWorkbook(
  List<OnlineIndexEntry> entries, {
  DateTime? at,
}) => buildXlsx([buildOnlineIndexSheet(entries, at: at)]);
