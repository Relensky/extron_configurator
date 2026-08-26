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
