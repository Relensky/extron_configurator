import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'app_paths.dart';

/// Utility class to handle local file logging for the application.
///
/// The log FILES are the record; the debugPrint calls below are only the
/// fallback for when writing one of those files is what failed (a read-only
/// folder, a locked file). Losing a log entry silently is the one thing a
/// logger must not do, so the message still has to land somewhere.
///
/// WHERE THEY LIVE. Under [logFolder], which is a folder the app owns and can
/// write to. They used to be opened by bare filename, which meant the process
/// WORKING DIRECTORY — and a packaged Windows build launched from a shortcut
/// has a working directory of C:\Windows\System32. Every log line the app
/// wrote in the field went to a file it had no permission to create, the
/// failure was swallowed by the catch blocks below, and the fallback
/// debugPrint went to a console that a double-clicked .exe does not have. The
/// logs this app asks people to send in were empty for exactly the
/// installations worth reading them from.
class AppLogger {
  /// Overrides [logFolder] for a test that wants to read back what was
  /// written without touching the developer's own profile.
  @visibleForTesting
  static set logFolderForTest(String folder) {
    _logFolder = folder;
    _folderReady = false;
  }

  static String? _logFolder;
  static bool _folderReady = false;

  /// The folder the three log files are written to.
  ///
  ///   * under `flutter test`, a fixed folder in the system temp directory —
  ///     not the repository (three tracked files that every test run modified)
  ///     and not the developer's profile;
  ///   * otherwise `<per-user app folder>/logs`, beside app_config.json and the
  ///     recovery copies;
  ///   * and only if the environment names no home at all, the working
  ///     directory, which is where they used to go unconditionally.
  static String get logFolder {
    final override = _logFolder;
    if (override != null) return override;
    return _logFolder = resolveLogFolder(
      underTest: runningUnderTest,
      userDir: userDataDirOrNull(),
      tempDir: Directory.systemTemp.path,
      workingDir: Directory.current.path,
    );
  }

  /// [logFolder]'s decision, with everything it reads from the environment
  /// passed in instead — so a test can ask what a packaged Windows build would
  /// do without being one.
  @visibleForTesting
  static String resolveLogFolder({
    required bool underTest,
    required String? userDir,
    required String tempDir,
    required String workingDir,
  }) {
    if (underTest) return path.join(tempDir, 'room_config_builder_test_logs');
    if (userDir != null) return path.join(userDir, 'logs');
    // The last resort, and what every log went to unconditionally before this.
    return workingDir;
  }

  /// The error log's full path. What a support request asks for, and what the
  /// App Config page and the undrawable-widget panel name.
  static String get errorLogPath => _pathFor('deployment_app_error_log.txt');

  /// The info log's full path.
  static String get infoLogPath => _pathFor('deployment_app_info_log.txt');

  /// The migration log's full path.
  static String get migrationLogPath =>
      _pathFor('deployment_app_migration_log.txt');

  static String _pathFor(String name) => path.join(logFolder, name);

  /// Makes sure [logFolder] exists before something tries to append into it.
  ///
  /// Once per run: a create call per log line would be a syscall per line, and
  /// the folder does not come and go. A failure here is left to the caller's
  /// own catch, which falls back to debugPrint like every other write failure.
  static void _ensureFolder() {
    if (_folderReady) return;
    final folder = logFolder;
    if (folder.isNotEmpty) Directory(folder).createSync(recursive: true);
    _folderReady = true;
  }

  /// Writes error messages and stack traces to a local error log file.
  static Future<void> logError(String message, [dynamic error, StackTrace? stackTrace]) async {
    try {
      _ensureFolder();
      final file = File(errorLogPath);
      final timestamp = DateTime.now().toIso8601String();

      final logEntry = StringBuffer();
      logEntry.writeln('[$timestamp] ERROR: $message');

      if (error != null) logEntry.writeln('Details: $error');
      if (stackTrace != null) logEntry.writeln('StackTrace:\n$stackTrace');
      logEntry.writeln('--------------------------------------------------');

      await file.writeAsString(logEntry.toString(), mode: FileMode.append);

      // Print to the debug console during development
      debugPrint(logEntry.toString());
    } catch (e) {
      // Fallback if writing to the log file fails (e.g., permissions)
      debugPrint("CRITICAL: Failed to write to log file. Error: $e");
    }
  }

  /// Writes a dedicated audit-trail entry every time a config is loaded,
  /// recording all schema changes that were added or flagged to make the
  /// file match the current template.
  static Future<void> logMigration(String configPath, List<String> changes) async {
    try {
      _ensureFolder();
      final file = File(migrationLogPath);
      final timestamp = DateTime.now().toIso8601String();

      final buffer = StringBuffer();
      buffer.writeln('[$timestamp] CONFIG LOADED: $configPath');
      if (changes.isEmpty) {
        buffer.writeln('  No schema changes required. Config matches current template.');
      } else {
        for (final change in changes) {
          buffer.writeln('  $change');
        }
      }
      buffer.writeln('--------------------------------------------------');

      await file.writeAsString(buffer.toString(), mode: FileMode.append);
    } catch (e) {
      debugPrint("Failed to write migration log: $e");
    }
  }

  /// Writes a standalone, human-readable change log for ONE config load,
  /// saved alongside that config's backup (e.g. BSS103_backup_log.txt).
  /// Contains the same details shown in the load acknowledgement dialog.
  ///
  /// [filePath] is chosen by the caller and is deliberately NOT under
  /// [logFolder]: this one belongs beside the room it describes, where whoever
  /// opens that folder will find it.
  static Future<void> writeChangeLog(
      String filePath, String sourceLabel, List<String> lines) async {
    try {
      final file = File(filePath);
      final timestamp = DateTime.now().toIso8601String();

      final buffer = StringBuffer();
      buffer.writeln('==================================================');
      buffer.writeln('CONFIG LOAD CHANGE LOG');
      buffer.writeln('Loaded:  $timestamp');
      buffer.writeln('Source:  $sourceLabel');
      buffer.writeln('==================================================');
      for (final line in lines) {
        buffer.writeln(line);
      }
      buffer.writeln();

      // Append so repeated loads of the same room build a history in one file
      await file.writeAsString(buffer.toString(), mode: FileMode.append);
    } catch (e) {
      debugPrint("Failed to write change log to $filePath: $e");
    }
  }

  /// Writes standard operational events to an info log file.
  static Future<void> logInfo(String message) async {
    try {
      _ensureFolder();
      final file = File(infoLogPath);
      final timestamp = DateTime.now().toIso8601String();
      await file.writeAsString('[$timestamp] INFO: $message\n', mode: FileMode.append);
    } catch (e) {
      debugPrint("Failed to write info log: $e");
    }
  }
}
