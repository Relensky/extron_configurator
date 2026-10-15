import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('room_photos_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('an unsaved room has no photos folder', () async {
    final p = AppStateProvider(autoLoadSettings: false);
    expect(p.roomPhotosFolder, '');
    expect(await p.listRoomPhotos(), isEmpty);
    expect(await p.addRoomPhotos(['x.jpg']), 0);
  });

  test('photos are copied beside config.json, numbered, newest first',
      () async {
    final room = Directory(path.join(dir.path, 'BSS_103'))..createSync();
    final p = AppStateProvider(autoLoadSettings: false)
      ..currentConfigPath = path.join(room.path, 'config.json');
    expect(p.roomPhotosFolder, path.join(room.path, 'photos'));

    final src = Directory(path.join(dir.path, 'camera'))..createSync();
    final a = File(path.join(src.path, 'front.jpg'))..writeAsBytesSync([1]);
    final notes = File(path.join(src.path, 'notes.txt'))
      ..writeAsStringSync('x');

    expect(await p.addRoomPhotos([a.path, a.path]), 2);
    // A non-picture copied in by hand is not listed.
    await notes.copy(path.join(p.roomPhotosFolder, 'notes.txt'));

    final names = [
      for (final f in await p.listRoomPhotos()) path.basename(f.path),
    ];
    expect(names.toSet(), {'front.jpg', 'front_2.jpg'});

    final first = path.join(p.roomPhotosFolder, 'front.jpg');
    expect(await p.deleteRoomPhoto(first), isTrue);
    expect(File(first).existsSync(), isFalse);
    // Nothing outside the photos folder is ever deleted.
    expect(await p.deleteRoomPhoto(a.path), isFalse);
    expect(a.existsSync(), isTrue);
  });
}
