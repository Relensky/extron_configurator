import 'dart:io';

/// Utility class to handle local file logging for the application.
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
      print(logEntry.toString());
    } catch (e) {
      // Fallback if writing to the log file fails (e.g., permissions)
      print("CRITICAL: Failed to write to log file. Error: $e");
    }
  }

  /// Writes standard operational events to an info log file.
  static Future<void> logInfo(String message) async {
    try {
      final file = File('deployment_app_info_log.txt');
      final timestamp = DateTime.now().toIso8601String();
      await file.writeAsString('[$timestamp] INFO: $message\n', mode: FileMode.append);
    } catch (e) {
      print("Failed to write info log: $e");
    }
  }
}