import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';

/// A room that will not open says why, and an empty one says where the room
/// still is.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('open_failure_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('an empty file names the backup beside it', () async {
    final file = path.join(dir.path, 'KNDL106C_Example.json');
    File(file).writeAsStringSync('');
    File(path.join(dir.path, 'KNDL106C_Example_previous.json'))
        .writeAsStringSync('{}');

    final p = AppStateProvider(autoLoadSettings: false);
    expect(await p.openConfigAtPath(file, remember: false), isFalse);
    expect(p.lastOpenError, contains('KNDL106C_Example.json is empty'));
    expect(p.lastOpenError, contains('KNDL106C_Example_previous.json'));
  });

  test('an empty file with no backup says where to look', () {
    final file = path.join(dir.path, 'room.json');
    File(file).writeAsStringSync('  \n');
    final message = AppStateProvider.describeOpenFailure(
        file, const FormatException('Unexpected end of input'));
    expect(message, contains('room.json is empty'));
    expect(message, contains('_previous.json'));
  });

  test('broken JSON says so', () {
    final file = path.join(dir.path, 'room.json');
    File(file).writeAsStringSync('{"a": ');
    final message = AppStateProvider.describeOpenFailure(
        file, const FormatException('Unexpected end of input'));
    expect(message, 'room.json is not a valid room file: '
        'Unexpected end of input.');
  });

  test('a missing file says so', () {
    final message = AppStateProvider.describeOpenFailure(
        path.join(dir.path, 'gone.json'), const FileSystemException('x'));
    expect(message, 'gone.json is not there any more.');
  });
}
