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
/// `Library/Application Support/RoomConfigBuilder` in the iOS sandbox,
/// `$XDG_CONFIG_HOME/.room_config_builder` (or `$HOME/...`) elsewhere.
///
/// Null when the environment names no home at all, which leaves it to the
/// caller to say what it wants to do instead — the two callers want different
/// things, and neither wants a path built on an empty string.
String? userDataDirOrNull() {
  final env = Platform.environment;
  // iOS: HOME is the app's sandbox container, whose top level cannot be
  // written. Library/Application Support is the place for the app's own
  // files, and the Files app does not show it.
  if (Platform.isIOS) {
    final home = _iosContainerOrNull();
    if (home == null) return null;
    return path.join(home, 'Library', 'Application Support', 'RoomConfigBuilder');
  }
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

/// iOS only: the app's Documents folder - writable, and shown in the Files
/// app under "On My iPad" (Info.plist turns that on). It is
/// the app's own folder on iOS, where the executable's folder is on the
/// desktop: the app bundle beside the executable is read-only. Null elsewhere.
String? iosDocumentsDirOrNull() {
  if (!Platform.isIOS) return null;
  final home = _iosContainerOrNull();
  return home == null ? null : path.join(home, 'Documents');
}

/// [p] moved into this run's app container when it names an older one.
///
/// iOS gives the app a new container folder (a new UUID in
/// `.../Data/Application/<UUID>/`) whenever it is reinstalled or updated, so an
/// absolute path remembered last week - a recent file, a project's room -
/// points into a folder that no longer exists. The file is still there, under
/// the new UUID. Anything else is returned as it was.
String rehomeIosContainerPath(String p) {
  if (!Platform.isIOS) return p;
  final home = _iosContainerOrNull();
  if (home == null) return p;
  final m = _kContainerPath.firstMatch(p);
  if (m == null) return p;
  final old = p.substring(0, m.end);
  if (old == home) return p;
  return '$home${p.substring(m.end)}';
}

final RegExp _kContainerPath = RegExp(
  r'^/.*/Data/Application/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-'
  r'[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(?=/|$)',
);

/// The app's sandbox container on iOS, the folder that holds Documents,
/// Library and tmp. A Flutter app on iOS gets no HOME in
/// [Platform.environment], so it comes from the temp folder, which iOS puts at
/// `<container>/tmp`. Cached: it cannot change during a run.
String? _iosContainerOrNull() => _iosContainer ??= () {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isNotEmpty) return home;
      try {
        final tmp = path.normalize(Directory.systemTemp.path);
        if (path.basename(tmp) != 'tmp') return null;
        return path.dirname(tmp);
      } catch (_) {
        return null;
      }
    }();
String? _iosContainer;
