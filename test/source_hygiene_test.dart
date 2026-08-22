import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Things about the SOURCE rather than about the app.
///
/// One check so far, and it earned its place the hard way: three sentinel
/// constants in floor_plan_view.dart were written with a literal NUL byte in
/// them, which makes the whole file binary as far as every tool is concerned.
/// `grep` answers "binary file matches" instead of the line, so any search
/// across the project silently skipped the largest file in it — and nothing
/// failed, which is exactly why it survived so long.
///
/// The values are unchanged; they are written as an escape now. This is what
/// stops the next one being typed.
void main() {
  Iterable<File> dartFiles() sync* {
    for (final dir in ['lib', 'test']) {
      for (final f in Directory(dir).listSync(recursive: true)) {
        if (f is File && f.path.endsWith('.dart')) yield f;
      }
    }
  }

  test('no source file contains a NUL byte', () {
    final offenders = <String>[];
    for (final f in dartFiles()) {
      final count = f.readAsBytesSync().where((b) => b == 0).length;
      if (count > 0) offenders.add('${f.path} ($count)');
    }
    expect(
      offenders,
      isEmpty,
      reason: 'NUL bytes make a file binary to grep and every other tool — '
          'write the escape rather than the byte',
    );
  });

  test('every source file is valid UTF-8', () {
    final offenders = <String>[];
    for (final f in dartFiles()) {
      try {
        f.readAsStringSync();
      } catch (e) {
        offenders.add('${f.path}: $e');
      }
    }
    expect(offenders, isEmpty);
  });
}
