import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_logger.dart';
import 'package:extron_configurator/app_paths.dart';
import 'package:extron_configurator/app_state.dart';

/// ============================================================================
///  THE LOGS GO SOMEWHERE THE APP CAN ACTUALLY WRITE
/// ============================================================================
///  The three log files used to be opened by bare filename, which means the
///  process WORKING DIRECTORY. app_state.dart already says why that is the
///  wrong place — a packaged Windows build launched from a shortcut or the
///  Start menu has a working directory of C:\Windows\System32 — but AppLogger
///  had never been told. Every log line written in the field went to a file the
///  app had no permission to create; AppLogger's own catch blocks swallowed the
///  failure, and the fallback debugPrint went to a console a double-clicked
///  .exe does not have. The log this app asks people to send in was empty for
///  exactly the installations worth reading one from.
///
///  So the folder is checked here rather than assumed, in all three of the
///  cases it can land in, and the two callers that share the per-user folder
///  are checked to still agree on where it is.
/// ============================================================================
void main() {
  group('where the logs go', () {
    test('a packaged build writes under the folder it owns, not the '
        'working directory', () {
      const userDir = r'C:\Users\somebody\AppData\Roaming\RoomConfigBuilder';
      final resolved = AppLogger.resolveLogFolder(
        underTest: false,
        userDir: userDir,
        tempDir: r'C:\Temp',
        workingDir: r'C:\Windows\System32',
      );

      expect(resolved, path.join(userDir, 'logs'));
      // The whole point.
      expect(resolved, isNot(contains('System32')));
    });

    test('with no home in the environment it still has somewhere to go', () {
      // The last resort, and what every log went to unconditionally before.
      // Worth keeping: a folder the app cannot write to is still better than
      // deciding not to log at all.
      expect(
        AppLogger.resolveLogFolder(
          underTest: false,
          userDir: null,
          tempDir: r'C:\Temp',
          workingDir: r'C:\App',
        ),
        r'C:\App',
      );
    });

    test('a test run writes to neither the repository nor the developer', () {
      final resolved = AppLogger.resolveLogFolder(
        underTest: true,
        userDir: r'C:\Users\somebody\AppData\Roaming\RoomConfigBuilder',
        tempDir: r'C:\Temp',
        workingDir: r'C:\GitHub\extron_configurator',
      );
      expect(resolved, startsWith(r'C:\Temp'));
      expect(resolved, isNot(contains('extron_configurator')));
      expect(resolved, isNot(contains('AppData')));
    });

    test('and this very run is not writing into the checked-out repository',
        () {
      // The regression itself, asked of the live process: three tracked files
      // at the root of the repo that every test run left modified.
      expect(
        path.equals(AppLogger.logFolder, Directory.current.path),
        isFalse,
        reason: 'logs are being written into ${Directory.current.path}',
      );
    });
  });

  group('the session log', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('log_location_test_');
      AppLogger.logFolderForTest = dir.path;
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('all go to the session log, in the log folder', () {
      for (final p in [
        AppLogger.errorLogPath,
        AppLogger.infoLogPath,
        AppLogger.migrationLogPath,
      ]) {
        expect(p, AppLogger.sessionLogPath);
        expect(path.dirname(p), path.dirname(path.join(dir.path, 'x')));
      }
      expect(path.basename(AppLogger.sessionLogPath),
          matches(RegExp(r'^session_log_[\d_-]+_\d+\.txt$')));
    });

    test('opens with a header, and every line carries its UTC offset', () {
      final text = File(AppLogger.sessionLogPath).readAsStringSync();
      expect(text, contains('App version: '));
      expect(text, contains('Timestamps: local time with its UTC offset'));
      for (final line in const LineSplitter().convert(text.trim())) {
        expect(line, matches(RegExp(r'^\[\S+[+-]\d\d:\d\d\] \[[A-Z]+\] ')));
      }
    });

    test('a session that did not close says so in the next one', () async {
      // A run that ended without its clean-exit marker...
      File(path.join(dir.path, 'session_log_2026-01-01_00-00-00_1.txt'))
          .writeAsStringSync('[x] [INFO] the last thing before the crash\r\n');
      // ...and the next one starting.
      AppLogger.logFolderForTest = dir.path;
      final next = File(AppLogger.sessionLogPath).readAsStringSync();
      expect(next, contains('PREVIOUS SESSION DID NOT EXIT CLEANLY'));
      expect(next, contains('the last thing before the crash'));
    });

    test('a session that closed on purpose is not reported', () async {
      await AppLogger.logInfo('work');
      AppLogger.endSession();
      final next = File(AppLogger.sessionLogPath).readAsStringSync();
      expect(next, isNot(contains('DID NOT EXIT CLEANLY')));
    });

    test('logs older than 30 days are removed, newer ones kept', () {
      final old = File(path.join(dir.path, 'session_log_old_1.txt'))
        ..writeAsStringSync('x')
        ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 31)));
      final recent = File(path.join(dir.path, 'session_log_recent_2.txt'))
        ..writeAsStringSync('x');
      final crash = File(path.join(dir.path, 'deployment_app_error_log.txt'))
        ..writeAsStringSync('x')
        ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 90)));
      expect(AppLogger.purgeOldLogs(dir), 1);
      expect(old.existsSync(), isFalse);
      expect(recent.existsSync(), isTrue);
      expect(crash.existsSync(), isTrue, reason: 'the native log is not ours');
    });

    test('a folder that does not exist yet is created to write into',
        () async {
      final fresh = path.join(dir.path, 'not', 'there', 'yet');
      AppLogger.logFolderForTest = fresh;
      expect(Directory(fresh).existsSync(), isFalse);

      await AppLogger.logError('a first error on a fresh install');

      expect(File(AppLogger.errorLogPath).readAsStringSync(),
          contains('a first error on a fresh install'));
    });

    test('each kind is tagged with its category', () async {
      await AppLogger.logError('an error line');
      await AppLogger.logInfo('an info line');
      await AppLogger.logMigration('a_room.json', ['a migration line']);

      final text = File(AppLogger.sessionLogPath).readAsStringSync();
      expect(text, contains('[ERROR] an error line'));
      expect(text, contains('[INFO] an info line'));
      expect(text, contains('[DATA] CONFIG LOADED: a_room.json'));
      expect(text, contains('a migration line'));
    });

    test('an over-long line keeps both ends', () async {
      await AppLogger.logInfo('start ${'x' * 5000} end');
      final text = File(AppLogger.sessionLogPath).readAsStringSync();
      expect(text, contains('chars omitted'));
      expect(text, contains(' end'));
    });

    test('the change log written beside a room is left where the caller put it',
        () async {
      // This one is not an app log: it belongs in the folder of the room it
      // describes, where whoever opens that folder will find it.
      final beside = path.join(dir.path, 'BSS103_backup_log.txt');
      await AppLogger.writeChangeLog(beside, 'BSS103_config.json', ['a change']);
      expect(File(beside).readAsStringSync(), contains('a change'));
    });
  });

  group('the per-user folder', () {
    test('is named after this app', () {
      final dir = userDataDirOrNull();
      // Null only on a machine whose environment names no home at all, which a
      // development machine is not.
      expect(dir, isNotNull);
      expect(
        path.basename(dir!),
        Platform.isWindows ? 'RoomConfigBuilder' : '.room_config_builder',
      );
    });

    test('is the same one app_config.json lives in', () {
      // The two callers used to hold a copy each of the environment lookup.
      // They now share one, and this is what says so.
      final dir = userDataDirOrNull();
      expect(
        path.equals(
          path.dirname(AppStateProvider.resolvedSettingsFilePath()),
          dir!,
        ),
        isTrue,
        reason: 'settings went to '
            '${AppStateProvider.resolvedSettingsFilePath()}, user folder is $dir',
      );
    });
  });
}
