import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/safe_write.dart';

/// A save that stops partway must leave the old file whole, never a 0-byte
/// room that will not open.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('safe_write_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('replaces the file and leaves nothing beside it', () async {
    final file = path.join(dir.path, 'room.json');
    File(file).writeAsStringSync('{"old": true}');
    await writeFileSafely(file, '{"new": true}');
    expect(File(file).readAsStringSync(), '{"new": true}');
    expect(dir.listSync().map((e) => path.basename(e.path)), ['room.json']);
  });

  test('creates a file that is not there yet', () async {
    final file = path.join(dir.path, 'new.json');
    await writeFileSafely(file, '{}');
    expect(File(file).readAsStringSync(), '{}');
  });

  test('a write that fails leaves the old file as it was', () async {
    final file = path.join(dir.path, 'room.json');
    File(file).writeAsStringSync('{"old": true}');
    // Something in the way of the new copy: the write cannot happen.
    Directory('$file.saving').createSync();
    await expectLater(writeFileSafely(file, '{"new": true}'), throwsA(anything));
    expect(File(file).readAsStringSync(), '{"old": true}');
  });

  test('the sync version does the same', () {
    final file = path.join(dir.path, 'room.json');
    File(file).writeAsStringSync('{"old": true}');
    writeFileSafelySync(file, '{"new": true}');
    expect(File(file).readAsStringSync(), '{"new": true}');
    expect(File('$file.saving').existsSync(), isFalse);
  });
}
