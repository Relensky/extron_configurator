import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/crash_session.dart';

/// The marker the Windows runner leaves while a session is open.
void main() {
  test('the marker name matches the one crash_log.cpp writes', () {
    expect(
      path.basename(crashSessionMarkerPath('logs', 4242)),
      'session_4242.running',
    );
  });

  test('ending the session removes only this process marker', () {
    final folder = Directory.systemTemp.createTempSync('crash_session_');
    addTearDown(() => folder.deleteSync(recursive: true));
    final mine = File(crashSessionMarkerPath(folder.path, 11))
      ..writeAsStringSync('started');
    final other = File(crashSessionMarkerPath(folder.path, 22))
      ..writeAsStringSync('started');

    endCrashSession(logFolder: folder.path, processId: 11);

    expect(mine.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);
  });

  test('a missing marker is not an error', () {
    final folder = Directory.systemTemp.createTempSync('crash_session_');
    addTearDown(() => folder.deleteSync(recursive: true));
    endCrashSession(logFolder: folder.path, processId: 33);
  });

  test('the runner and AppLogger write to the same folder', () {
    final cpp = File('windows/runner/crash_log.cpp').readAsStringSync();
    // Doubled backslashes: this reads the C++ source, not the string it makes.
    expect(cpp, contains(r'\\RoomConfigBuilder\\logs'));
    expect(cpp, contains('deployment_app_error_log.txt'));
    expect(cpp, contains(r'\\session_'));
    expect(cpp, contains('.running'));
  });
}
