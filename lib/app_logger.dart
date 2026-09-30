import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'app_paths.dart';
import 'changelog.dart' show kAppVersion;
import 'log_viewer/log_viewer_platform.dart' show describeOperatingSystem;

// ============================================================================
//  THE APPLICATION LOG
// ============================================================================
//  Set up the way the Extron debugger's log is, so the two read alike in the
//  log viewer:
//
//   * ONE FILE PER SESSION, `session_log_<date_time>_<pid>.txt`, kept 30 days.
//     Every line is `[<local time with UTC offset>] [CATEGORY] message`, and
//     each session opens with a header naming the version, OS, time zone and
//     machine, so a log sent in reads on its own.
//   * WRITTEN SYNCHRONOUSLY through one handle. The last seconds before a
//     crash are the only interesting part, and a buffered sink loses them.
//   * CRASH FORENSICS. A session that ends on purpose writes a clean-exit
//     marker; the next run reads the tail of the previous log and says so in
//     writing when the marker is missing, naming its last line and any scope
//     it died inside. A heartbeat records memory every minute, so a slow leak
//     shows as a curve. Native crashes, which no Dart code sees, are still
//     logged by windows/runner/crash_log.cpp into
//     deployment_app_error_log.txt in the default folder.
//
//  Categories: ACTION (default), NAV, UI, CONFIG, NET, DATA, PERF, SCOPE,
//  ERROR, INFO.
// ============================================================================

class AppLogger {
  AppLogger._();

  // --- where ---------------------------------------------------------------

  /// Overrides [logFolder] for a test that wants to read back what was
  /// written without touching the developer's own profile.
  @visibleForTesting
  static set logFolderForTest(String folder) {
    _closeSession(clean: true);
    _logFolder = folder;
    _folderReady = false;
  }

  static String? _logFolder;
  static bool _folderReady = false;

  /// Set from Settings; blank means [defaultLogFolder].
  static String _configuredFolder = '';

  /// The per-user default: `<per-user app folder>/logs`, where the native
  /// crash logger writes too.
  static String get defaultLogFolder => resolveLogFolder(
    underTest: runningUnderTest,
    userDir: userDataDirOrNull(),
    tempDir: Directory.systemTemp.path,
    workingDir: Directory.current.path,
  );

  /// The folder the session logs are written to.
  static String get logFolder {
    final override = _logFolder;
    if (override != null) return override;
    return _logFolder = _configuredFolder.trim().isNotEmpty
        ? _configuredFolder.trim()
        : defaultLogFolder;
  }

  /// [logFolder]'s default, with everything it reads from the environment
  /// passed in, so a test can ask what a packaged Windows build would do.
  @visibleForTesting
  static String resolveLogFolder({
    required bool underTest,
    required String? userDir,
    required String tempDir,
    required String workingDir,
  }) {
    if (underTest) return path.join(tempDir, 'room_config_builder_test_logs');
    if (userDir != null) return path.join(userDir, 'logs');
    return workingDir;
  }

  /// Moves logging to [folder] (blank = the default). The current session
  /// file is closed cleanly and a new one opened there.
  static void setLogFolder(String folder) {
    final next = folder.trim();
    final target = next.isEmpty ? defaultLogFolder : next;
    if (_logFolder != null && path.equals(_logFolder!, target)) {
      _configuredFolder = next;
      return;
    }
    if (_raf != null) {
      _always('Log continues in: $target', category: 'CONFIG');
    }
    _closeSession(clean: true);
    _configuredFolder = next;
    _logFolder = null;
    _folderReady = false;
  }

  /// This session's log file. What a support request asks for.
  static String get sessionLogPath {
    _ensureOpen();
    return _file?.path ?? path.join(logFolder, 'session_log.txt');
  }

  /// Where errors are written: this session's log.
  static String get errorLogPath => sessionLogPath;

  /// Where operational events are written: this session's log.
  static String get infoLogPath => sessionLogPath;

  /// Where config conversions are written: this session's log.
  static String get migrationLogPath => sessionLogPath;

  // --- the session ---------------------------------------------------------

  static File? _file;
  static RandomAccessFile? _raf;
  static Timer? _heartbeat;
  static final List<({String label, Stopwatch watch})> _openScopes = [];

  /// Written verbatim as the last line of a session that ended on purpose.
  static const String cleanExitMarker = '--- Application Closing (clean) ---';

  static const Duration logRetention = Duration(days: 30);

  /// Longest single line kept intact; the middle of a longer one is cut.
  static const int maxLineLength = 600;

  /// The most recent line logged (not counting heartbeats).
  static String lastMessage = '';

  /// Starts the session: opens the file, audits the previous one, prunes
  /// logs past [logRetention] and starts the heartbeat. Called from main().
  static void startSession({Duration heartbeat = const Duration(minutes: 1)}) {
    _ensureOpen();
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(heartbeat, (_) => logHeartbeat());
    logHeartbeat();
  }

  /// Ends the session on the record. The clean-exit marker is what stops the
  /// next run's audit from reporting this one as a crash.
  static void endSession() => _closeSession(clean: true);

  static void _ensureOpen() {
    if (_raf != null) return;
    try {
      final folder = logFolder;
      if (!_folderReady) {
        Directory(folder).createSync(recursive: true);
        _folderReady = true;
      }
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('T', '_')
          .split('.')
          .first;
      final file = File(path.join(folder, 'session_log_${stamp}_$pid.txt'));
      _file = file;
      _raf = file.openSync(mode: FileMode.append);
      _auditPreviousSession(Directory(folder), file);
      _writeHeader();
      purgeOldLogs(Directory(folder), keep: file);
    } catch (e) {
      debugPrint('Failed to open the session log: $e');
      _raf = null;
    }
  }

  static void _writeHeader() {
    _always('--- Application Started --- (version $kAppVersion, pid $pid)');
    try {
      _always('App version: $kAppVersion', category: 'CONFIG');
      // Not Platform.operatingSystemVersion: that says "Windows 10" on every
      // Windows 11 machine. See lib/log_viewer/os_name.dart.
      _always('OS: ${describeOperatingSystem()}', category: 'CONFIG');
      _always('Dart: ${Platform.version}', category: 'CONFIG');
      _always(timeZoneDescription(), category: 'CONFIG');
      _always(
        'Locale: ${Platform.localeName} | CPUs: ${Platform.numberOfProcessors}',
        category: 'CONFIG',
      );
      _always('Working directory: ${Directory.current.path}',
          category: 'CONFIG');
      _always('Memory at start: ${memorySnapshot()}', category: 'CONFIG');
      if (_file != null) _always('Log file: ${_file!.path}', category: 'CONFIG');
    } catch (e) {
      debugPrint('Failed to write the session header: $e');
    }
  }

  static void _closeSession({required bool clean}) {
    _heartbeat?.cancel();
    _heartbeat = null;
    if (_raf == null) return;
    if (clean) {
      _always('Memory at exit: ${memorySnapshot()}', category: 'CONFIG');
      _always(cleanExitMarker);
    }
    try {
      _raf?.flushSync();
      _raf?.closeSync();
    } catch (_) {}
    _raf = null;
    _file = null;
  }

  // --- audit and retention -------------------------------------------------

  static bool _isSessionLog(String name) =>
      name.startsWith('session_log_') && name.endsWith('.txt');

  static String _pathKey(FileSystemEntity f) =>
      f.absolute.path.replaceAll(r'\', '/').toLowerCase();

  /// Reads the tail of the newest other session log; no clean-exit marker
  /// means that session was killed, and this one says so.
  static void _auditPreviousSession(Directory dir, File current) {
    try {
      File? previous;
      DateTime? newest;
      for (final f in dir.listSync().whereType<File>()) {
        if (!_isSessionLog(path.basename(f.path))) continue;
        if (_pathKey(f) == _pathKey(current)) continue;
        final m = f.statSync().modified;
        if (newest == null || m.isAfter(newest)) {
          newest = m;
          previous = f;
        }
      }
      if (previous == null || newest == null) return;

      final length = previous.lengthSync();
      if (length == 0) return;
      final raf = previous.openSync();
      String tail;
      try {
        const window = 4096;
        final start = length > window ? length - window : 0;
        raf.setPositionSync(start);
        tail = utf8.decode(raf.readSync(length - start), allowMalformed: true);
      } finally {
        raf.closeSync();
      }
      if (tail.contains(cleanExitMarker)) return;

      final lines = tail
          .split('\n')
          .map((l) => l.trimRight())
          .where((l) => l.isNotEmpty)
          .toList();
      _always(
        '=============== PREVIOUS SESSION DID NOT EXIT CLEANLY ===============',
        category: 'ERROR',
      );
      _always('Previous log: ${previous.absolute.path}', category: 'ERROR');
      _always('Last written: ${logTimestamp(newest)}', category: 'ERROR');
      _always(
        'Last line: ${truncate(lines.isEmpty ? '(empty)' : lines.last)}',
        category: 'ERROR',
      );
      final scope = _lastUnclosedScope(lines);
      if (scope != null) _always('Died inside scope: $scope', category: 'ERROR');
      _always(
        'No clean-exit marker was written. Either that session crashed (a '
        'native crash runs no Dart handler) or it is a second copy of the app '
        'that is still open - compare the pid in its header.',
        category: 'ERROR',
      );
      _always(
        '=====================================================================',
        category: 'ERROR',
      );
    } catch (e) {
      debugPrint('Failed to audit the previous session log: $e');
    }
  }

  static String? _lastUnclosedScope(List<String> lines) {
    const openTag = '[SCOPE] >>> ';
    const closeTag = '[SCOPE] <<< ';
    final stack = <String>[];
    for (final line in lines) {
      final open = line.indexOf(openTag);
      if (open != -1) {
        stack.add(line.substring(open + openTag.length));
      } else if (line.contains(closeTag) && stack.isNotEmpty) {
        stack.removeLast();
      }
    }
    return stack.isEmpty ? null : stack.last;
  }

  /// Deletes session logs in [dir] last written more than [maxAge] ago.
  /// [keep] is never touched; a file another process holds is skipped.
  static int purgeOldLogs(
    Directory dir, {
    Duration maxAge = logRetention,
    DateTime? now,
    File? keep,
  }) {
    var removed = 0;
    try {
      if (!dir.existsSync()) return 0;
      final cutoff = (now ?? DateTime.now()).subtract(maxAge);
      final keepKey = keep == null ? null : _pathKey(keep);
      for (final f in dir.listSync().whereType<File>()) {
        if (!_isSessionLog(path.basename(f.path))) continue;
        if (keepKey != null && _pathKey(f) == keepKey) continue;
        try {
          if (f.statSync().modified.isBefore(cutoff)) {
            f.deleteSync();
            removed++;
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Failed to purge old logs in ${dir.path}: $e');
    }
    return removed;
  }

  // --- formatting ----------------------------------------------------------

  /// Local time with its UTC offset, e.g. `2026-09-29T11:05:30.316050-07:00`.
  static String logTimestamp(DateTime t) {
    final local = t.toLocal();
    final off = local.timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final mins = off.inMinutes.abs();
    return '${local.toIso8601String()}$sign'
        '${(mins ~/ 60).toString().padLeft(2, '0')}:'
        '${(mins % 60).toString().padLeft(2, '0')}';
  }

  /// How to read every timestamp in this file, stated once per session.
  static String timeZoneDescription([DateTime? at]) {
    final now = at ?? DateTime.now();
    final off = now.timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final mins = off.inMinutes.abs();
    final hh = (mins ~/ 60).toString().padLeft(2, '0');
    final mm = (mins % 60).toString().padLeft(2, '0');
    return 'Timestamps: local time with its UTC offset, ${now.timeZoneName} '
        '(UTC$sign$hh:$mm), taken when each line is written; UTC now is '
        '${now.toUtc().toIso8601String()}';
  }

  /// Cuts the middle out of an over-long line, so both ends still show.
  static String truncate(String message, [int max = maxLineLength]) {
    if (message.length <= max) return message;
    final keep = (max - 40) ~/ 2;
    return '${message.substring(0, keep)}'
        ' …[${message.length - keep * 2} chars omitted]… '
        '${message.substring(message.length - keep)}';
  }

  static String memorySnapshot() {
    try {
      String mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} MB';
      return 'rss=${mb(ProcessInfo.currentRss)} peak=${mb(ProcessInfo.maxRss)}';
    } catch (e) {
      return 'rss=unavailable ($e)';
    }
  }

  // --- writing -------------------------------------------------------------

  /// The one place bytes leave this class. [force] also flushes to disk, for
  /// crash and lifecycle records.
  static void _emit(String message, String category, {bool force = false}) {
    _ensureOpen();
    final line = '[${logTimestamp(DateTime.now())}] [$category] $message\n';
    if (!message.startsWith('heartbeat ')) {
      lastMessage =
          message.length > 200 ? '${message.substring(0, 200)}...' : message;
    }
    if (kDebugMode) debugPrint(line.trimRight());
    final raf = _raf;
    if (raf == null) return;
    try {
      // Another handle may have appended since (the native crash logger);
      // without the seek this line would land on top of theirs.
      final length = raf.lengthSync();
      if (raf.positionSync() != length) raf.setPositionSync(length);
      raf.writeStringSync(line);
      if (force) raf.flushSync();
    } catch (e) {
      debugPrint('Failed to write a log line: $e');
    }
  }

  static void _always(String message, {String category = 'ACTION'}) =>
      _emit(message, category, force: true);

  /// A user action or system event under [category].
  static void logAction(String message, {String category = 'ACTION'}) =>
      _emit(truncate(message), category);

  static void logNav(String message) => logAction(message, category: 'NAV');
  static void logUi(String message) => logAction(message, category: 'UI');
  static void logConfig(String message) =>
      logAction(message, category: 'CONFIG');
  static void logNet(String message) => logAction(message, category: 'NET');
  static void logData(String message) => logAction(message, category: 'DATA');

  /// An operational event.
  static Future<void> logInfo(String message) async =>
      _emit(truncate(message), 'INFO');

  /// An error, with its details and stack. Never shortened: the stack is
  /// the part someone needs.
  static Future<void> logError(
    String message, [
    dynamic error,
    StackTrace? stackTrace,
  ]) async {
    final b = StringBuffer(message);
    if (error != null) b.write('\nDetails: $error');
    if (stackTrace != null) b.write('\nStackTrace:\n$stackTrace');
    _emit(b.toString(), 'ERROR', force: true);
  }

  /// A crash the global handlers caught: the error, memory, open scopes and
  /// stack, flushed straight to disk.
  static void logCrash(Object error, StackTrace stackTrace) {
    final scopes = _openScopes.isEmpty
        ? '(none)'
        : _openScopes.map((s) => s.label).join(' > ');
    _emit(
      '================= CRASH REPORT =================\n'
      '$error\n'
      '[MEMORY]: ${memorySnapshot()}\n'
      '[OPEN SCOPES]: $scopes\n'
      '[STACK TRACE]:\n$stackTrace\n'
      '================================================',
      'ERROR',
      force: true,
    );
  }

  /// The audit trail for one config load: every schema change it made.
  static Future<void> logMigration(
    String configPath,
    List<String> changes,
  ) async {
    final b = StringBuffer('CONFIG LOADED: $configPath');
    if (changes.isEmpty) {
      b.write('\n  No schema changes required. Config matches current '
          'template.');
    } else {
      for (final change in changes) {
        b.write('\n  $change');
      }
    }
    _emit(b.toString(), 'DATA');
  }

  /// Writes a standalone, human-readable change log for ONE config load,
  /// saved in that room's folder (e.g. BSS103_backup_log.txt). Not in the
  /// session log: this one belongs with the room it describes.
  static Future<void> writeChangeLog(
    String filePath,
    String sourceLabel,
    List<String> lines,
  ) async {
    try {
      final buffer = StringBuffer()
        ..writeln('==================================================')
        ..writeln('CONFIG LOAD CHANGE LOG')
        ..writeln('Loaded:  ${logTimestamp(DateTime.now())}')
        ..writeln('Source:  $sourceLabel')
        ..writeln('==================================================');
      for (final line in lines) {
        buffer.writeln(line);
      }
      buffer.writeln();
      // Appended, so repeated loads of one room build a history in one file.
      await File(filePath).writeAsString(
        buffer.toString(),
        mode: FileMode.append,
      );
    } catch (e) {
      debugPrint('Failed to write change log to $filePath: $e');
    }
  }

  // --- scopes and heartbeat -------------------------------------------------

  /// Opens a scope around work that could take the process down. The line is
  /// on disk BEFORE the work runs; pair with [endScope] in a `finally`.
  static void beginScope(String label, {String? detail}) {
    _openScopes.add((label: label, watch: Stopwatch()..start()));
    _always('>>> $label${detail == null ? '' : ' - $detail'}',
        category: 'SCOPE');
  }

  static void endScope(String label, {String? detail}) {
    final i = _openScopes.lastIndexWhere((s) => s.label == label);
    var elapsed = '';
    if (i != -1) {
      elapsed = ' (${_openScopes[i].watch.elapsedMilliseconds} ms)';
      _openScopes.removeAt(i);
    }
    _always('<<< $label$elapsed${detail == null ? '' : ' - $detail'}',
        category: 'SCOPE');
  }

  /// Runs [action] inside a scope, closing it even when [action] throws.
  static Future<T> inScope<T>(
    String label,
    Future<T> Function() action, {
    String? detail,
  }) async {
    beginScope(label, detail: detail);
    try {
      return await action();
    } finally {
      endScope(label);
    }
  }

  /// One memory reading, plus any scope still open.
  static void logHeartbeat({String? note}) {
    final parts = <String>[memorySnapshot()];
    if (_openScopes.isNotEmpty) {
      parts.add('openScopes=[${_openScopes.map((s) => s.label).join(', ')}]');
    }
    if (note != null) parts.add(note);
    _emit('heartbeat ${parts.join(' | ')}', 'PERF');
  }
}
