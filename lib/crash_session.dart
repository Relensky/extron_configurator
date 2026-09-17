import 'dart:io';

import 'package:path/path.dart' as path;

import 'app_logger.dart';

/// The Windows runner (windows/runner/crash_log.cpp) leaves this file while
/// the app is open and deletes it on a normal close. One still there at the
/// next start is logged as a session that did not close normally.
String crashSessionMarkerPath(String logFolder, int processId) =>
    path.join(logFolder, 'session_$processId.running');

/// Marks this session as closed normally, for exits that skip the runner's
/// own cleanup - installing an update ends the process with exit(0).
void endCrashSession({String? logFolder, int? processId}) {
  try {
    final marker = File(
      crashSessionMarkerPath(logFolder ?? AppLogger.logFolder, processId ?? pid),
    );
    if (marker.existsSync()) marker.deleteSync();
  } catch (_) {
    // A marker left behind only costs one false entry in the log.
  }
}
