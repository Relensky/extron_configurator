// ============================================================================
// LOG VIEWER — shared types
//
// lib/log_viewer/ is shared, unchanged, by the five CTS apps (the Dashboard,
// the Extron Configurator, Instructor Contact, GeoGuesser and Quizzer), the
// same way lib/updater/ is. A fix here is copied to the other four. Each app
// says where its logs are with [LogSource]s and nothing else.
//
// No dart:io in this file or in log_viewer.dart: the file work lives behind
// log_viewer_platform.dart, so an app with a web build still compiles.
//
// No em or en dashes in any string the viewer shows or copies
// ============================================================================

/// Somewhere an app keeps log files: a folder and which of its files count,
/// or one file.
class LogSource {
  /// What these logs are, shown beside each file ("Debug log", "Crash").
  final String label;

  /// A folder to list. Only files directly in it are read.
  final String? folder;

  /// One file, for an app whose log is a single fixed file.
  final String? file;

  /// Which files in [folder] are logs, by file name. Every file when null.
  final bool Function(String fileName)? include;

  const LogSource.folder(
    String this.folder, {
    required this.label,
    this.include,
  }) : file = null;

  const LogSource.file(String this.file, {required this.label})
      : folder = null,
        include = null;
}

/// One log file found on disk.
class LogFileInfo {
  final String path;
  final String name;

  /// The [LogSource.label] it was found under.
  final String label;
  final DateTime modified;
  final int bytes;

  /// The file this session is writing to.
  final bool isCurrent;

  const LogFileInfo({
    required this.path,
    required this.name,
    required this.label,
    required this.modified,
    required this.bytes,
    this.isCurrent = false,
  });
}

/// What was read from one log file.
class LogText {
  final String text;

  /// The file's whole size, which is more than [text] when [truncated].
  final int totalBytes;

  /// True when only the end of the file was read.
  final bool truncated;

  /// Why nothing could be read, or null.
  final String? error;

  const LogText({
    required this.text,
    required this.totalBytes,
    this.truncated = false,
    this.error,
  });
}
