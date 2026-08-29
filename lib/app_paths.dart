import 'dart:io';

import 'package:path/path.dart' as path;

/// ============================================================================
///  THE ONE PLACE THAT KNOWS WHERE THIS APP MAY WRITE
/// ============================================================================
///  [Directory.current] is not it. A packaged Windows build launched from a
///  shortcut or the Start menu often has a working directory of
///  C:\Windows\System32 — a folder the app cannot write to, and one nobody
///  would think to look in for a log. Anything the app writes for ITSELF, as
///  opposed to a document the user chose a place for, belongs under here.
///
///  Two callers share it: app_config.json and the recovery copies
///  (app_state.dart), and the log files (app_logger.dart). It lives in its own
///  file because app_logger.dart is imported by app_state.dart and cannot
///  import it back.
/// ============================================================================

/// The per-user folder this app owns: `%APPDATA%\RoomConfigBuilder` on Windows,
/// `$XDG_CONFIG_HOME/.room_config_builder` (or `$HOME/...`) elsewhere.
///
/// Null when the environment names no home at all, which leaves it to the
/// caller to say what it wants to do instead — the two callers want different
/// things, and neither wants a path built on an empty string.
String? userDataDirOrNull() {
  final env = Platform.environment;
  final String base = Platform.isWindows
      ? (env['APPDATA'] ?? env['LOCALAPPDATA'] ?? '')
      : (env['XDG_CONFIG_HOME'] ?? env['HOME'] ?? '');
  if (base.isEmpty) return null;
  return path.join(
      base, Platform.isWindows ? 'RoomConfigBuilder' : '.room_config_builder');
}

/// True while the process is running under `flutter test`.
///
/// The test runner sets this. It is worth knowing because the things this app
/// writes for itself should not land in the developer's own profile — or, as
/// they used to, in three checked-in files at the root of the repository that
/// every test run left modified.
bool get runningUnderTest => Platform.environment['FLUTTER_TEST'] == 'true';
