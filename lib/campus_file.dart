import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'building_project.dart';

/// ============================================================================
///  A CAMPUS, AS A FILE
/// ============================================================================
///  The campus view is assembled by hand: somebody picks eleven project files
///  out of four folders, waits for them to be read, and reads the one calendar
///  they add up to. Close it and that assembly is gone - the next person to
///  need the same estate does the same picking, from memory, and gets a
///  different eleven.
///
///  So the assembly is a document of its own. It holds NO figures: not a
///  total, not a year, not a room count. Every number on the campus sheet is
///  derived from the projects, and a file that cached them would be a file
///  that could disagree with the buildings it names - which is the exact drift
///  the whole lifecycle feature exists to remove. It holds the LIST, and
///  opening it re-reads every job off disk, so a campus saved in March and
///  opened in June shows June's plan.
///
///  Paths are stored relative to the campus file wherever the job sits under
///  it, exactly as a project stores its rooms - so a folder that is moved,
///  copied to a server or handed over on a stick still opens.
/// ============================================================================

/// What a campus file is called, after the name somebody gives it.
const String kCampusFileSuffix = '_campus.json';

/// The jobs on one campus sheet, and what that sheet is called.
class CampusFile {
  /// What this estate is called - 'Chico campus', 'North of the creek'. Shown
  /// on the sheet and used to name the file.
  final String name;

  /// The project files on the sheet, in the order they were added. Absolute,
  /// once loaded: what is on disk may be relative to the campus file, and
  /// resolving it is [load]'s job so nothing downstream has to care.
  final List<String> projects;

  /// Where it was read from or last written to, '' for one nobody has saved.
  /// Not part of the document - it is where the document IS.
  final String file;

  const CampusFile({
    required this.name,
    required this.projects,
    this.file = '',
  });

  /// The file this campus would be saved as, before the folder.
  String get fileStem {
    final clean = name
        .trim()
        .replaceAll(RegExp(r'[\/:*?"<>|]'), '')
        .replaceAll(RegExp(r'\s+'), '_');
    return clean.isEmpty ? 'campus' : clean;
  }

  /// True when [file] is a campus rather than a project or a room.
  ///
  /// The suffix this app writes answers it without touching the disk; a file
  /// somebody renamed is settled by the one key a campus cannot be without.
  /// Deliberately strict about `projects` being a list of strings: a project
  /// file has a `rooms` list of objects, and telling the two apart matters
  /// more than accepting a file that is nearly a campus.
  static bool looksLikeCampus(String file) {
    if (file.toLowerCase().endsWith(kCampusFileSuffix.toLowerCase())) {
      return true;
    }
    try {
      final doc = jsonDecode(File(file).readAsStringSync());
      return doc is Map &&
          doc['kind'] == 'campus' &&
          doc['projects'] is List;
    } catch (_) {
      return false;
    }
  }

  /// Reads the campus at [file], with every job path made absolute.
  ///
  /// Throws whatever the file system or the parser throws - the caller is a
  /// screen with somewhere to put the message, and a campus that silently
  /// opened empty would look like a campus that had been saved empty.
  static Future<CampusFile> load(String file) async {
    final doc = jsonDecode(await File(file).readAsString());
    if (doc is! Map) {
      throw const FormatException('That file is not a campus.');
    }
    final raw = doc['projects'];
    if (raw is! List) {
      throw const FormatException(
        'That file has no list of projects in it, so it is not a campus.',
      );
    }
    return CampusFile(
      file: file,
      name: doc['name']?.toString().trim().isNotEmpty == true
          ? doc['name'].toString().trim()
          // Named after the file when the file does not name itself, so a
          // campus always has something to be called on the sheet.
          : _nameFromFile(file),
      projects: [
        for (final p in raw)
          if (p is String && p.trim().isNotEmpty)
            BuildingProject.resolvePath(p.trim(), file),
      ],
    );
  }

  /// Writes this campus to [file], with the job paths stored relative to it
  /// wherever they sit underneath it.
  Future<void> save(String file) async {
    final doc = <String, dynamic>{
      '__readme':
          'A campus is a LIST OF JOBS, not a set of figures. Opening it '
              're-reads every project below off disk, so the plan is always '
              "today's. Paths are relative to this file where the job sits "
              'under it.',
      'kind': 'campus',
      'name': name,
      'saved': formatIsoDate(DateTime.now()),
      'projects': [
        for (final p in projects) BuildingProject.storePath(p, file),
      ],
    };
    await File(file).writeAsString(const JsonEncoder.withIndent('  ').convert(doc));
  }

  /// 'chico_campus.json' -> 'Chico'. What a file that names no campus is
  /// called, so the sheet has a heading either way.
  static String _nameFromFile(String file) {
    var stem = path.basenameWithoutExtension(file);
    if (stem.toLowerCase().endsWith('_campus')) {
      stem = stem.substring(0, stem.length - '_campus'.length);
    }
    final words = stem.replaceAll('_', ' ').trim();
    return words.isEmpty ? 'Campus' : words;
  }
}

/// ============================================================================
///  WHICH SHEET A JOB IS ON
/// ============================================================================
///  The link between a campus and its jobs used to run one way. The campus
///  named its projects; a project named nothing. So opening the campus from
///  inside a building gave a sheet of ONE building, and the other thirty-three
///  had to be found on disk again - every session, by whoever was in it.
///
///  The other direction is a single path written into each project file - see
///  [BuildingProject.campusFile]. It is a POINTER AND NOT A COPY: the campus
///  file is still the list, still re-read off disk, and a job whose campus has
///  been deleted falls back to the sheet of one rather than failing. Nothing
///  here caches a name, a job list or a figure, for the same reason the campus
///  itself caches none: a second copy of the list is a copy that can disagree.
/// ============================================================================

/// True when [projectPath] is one of the jobs on [campus].
///
/// Compared with [path.equals] rather than as strings: the same file reached
/// as `C:\jobs\AGYM_project.json` and `C:/jobs/./AGYM_project.json` is the same
/// job, and on Windows it is the same job in either case.
bool campusListsProject(CampusFile campus, String projectPath) {
  if (projectPath.trim().isEmpty) return false;
  for (final p in campus.projects) {
    if (path.equals(p, projectPath)) return true;
  }
  return false;
}

/// What [stampCampusIntoProjects] managed.
class CampusStampResult {
  /// Files written - jobs that did not already point at this campus.
  final int written;

  /// Jobs that already pointed here, so nothing was rewritten.
  final int unchanged;

  /// Jobs that could not be read or written, by file name.
  final List<String> failed;

  const CampusStampResult({
    this.written = 0,
    this.unchanged = 0,
    this.failed = const [],
  });
}

/// Writes [campusPath] into every project on it, so Campus opens this sheet
/// from any of them.
///
/// WHY THIS TOUCHES OTHER PEOPLE'S FILES AT ALL, and why only on save. Saving a
/// campus is the one moment somebody has said, deliberately and by name, that
/// these jobs are one estate. Doing it on open would stamp thirty-four files
/// for a glance; doing it never would mean the association only ever worked
/// from the job that happened to be open.
///
/// IT WRITES ONE KEY AND LEAVES THE REST OF THE FILE ALONE - each job is read,
/// given its pointer and written back through the same loader and saver the app
/// uses everywhere, so a project that is opened afterwards is the project that
/// was there before plus one line.
///
/// [skip] is the job that is OPEN in the session doing the saving. Its file on
/// disk is stale by definition - there may be unsaved work in front of it - and
/// writing underneath it would either lose that work or be lost by it. The
/// caller sets the pointer on the in-memory job instead.
Future<CampusStampResult> stampCampusIntoProjects({
  required String campusPath,
  required Iterable<String> projects,
  String skip = '',
}) async {
  var written = 0;
  var unchanged = 0;
  final failed = <String>[];

  for (final job in projects) {
    if (skip.trim().isNotEmpty && path.equals(job, skip)) continue;
    try {
      final project = await BuildingProject.load(job);
      final stored = BuildingProject.storeCampusPath(campusPath, job);
      if (project.campusFile == stored) {
        unchanged++;
        continue;
      }
      project.campusFile = stored;
      await project.save(job);
      written++;
    } catch (_) {
      // A job that cannot be read is a job that cannot be told. Named rather
      // than thrown: one unreadable file out of thirty-four must not undo the
      // thirty-three that were fine.
      failed.add(path.basename(job));
    }
  }

  return CampusStampResult(
    written: written,
    unchanged: unchanged,
    failed: failed,
  );
}
