import 'dart:io';

import 'package:flutter/foundation.dart';

/// Utility class to handle local file logging for the application.
///
/// The log FILES are the record; the debugPrint calls below are only the
/// fallback for when writing one of those files is what failed (a read-only
/// folder, a locked file). Losing a log entry silently is the one thing a
/// logger must not do, so the message still has to land somewhere.
class AppLogger {
  /// Writes error messages and stack traces to a local error log file.
  static Future<void> logError(String message, [dynamic error, StackTrace? stackTrace]) async {
    try {
      // Creates or appends to a log file in the application's execution directory
      final file = File('deployment_app_error_log.txt');
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
      final file = File('deployment_app_migration_log.txt');
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
      final file = File('deployment_app_info_log.txt');
      final timestamp = DateTime.now().toIso8601String();
      await file.writeAsString('[$timestamp] INFO: $message\n', mode: FileMode.append);
    } catch (e) {
      debugPrint("Failed to write info log: $e");
    }
  }
}