import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/collab/combine_details.dart';
import 'package:extron_configurator/collab/merge_labels.dart';
import 'package:extron_configurator/history_sources.dart';
import 'package:extron_configurator/room_sidecar.dart';

/// Other people's changes to rooms nobody here has open, read off disk, and
/// a combine naming a job's room by its folder rather than its id.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('history_sources');
  });
  tearDown(() => dir.delete(recursive: true));

  test("a room's log is read from its history file", () async {
    final config = path.join(dir.path, 'BSS_103', 'config.json');
    await File(config).create(recursive: true);
    await File(config).writeAsString('{}');
    final history = roomSidecarPath(config, RoomSidecarPart.history);
    await File(history).create(recursive: true);
    await File(history).writeAsString(jsonEncode({
      'roomHistory': [
        {
          'itemKey': 'device:PROJ',
          'itemName': 'Projector',
          'field': 'Model',
          'summary': 'was A, now B',
          'user': 'jsmith',
          'at': '2026-10-01T10:00:00Z',
        },
      ],
    }));

    final log = await readRoomLogFromDisk(config);
    expect(log.file, history);
    expect(log.edits.single.itemName, 'Projector');
    expect(log.edits.single.user, 'jsmith');
  });

  test('a room with no log reads as empty', () async {
    final log =
        await readRoomLogFromDisk(path.join(dir.path, 'X', 'config.json'));
    expect(log.edits, isEmpty);
    expect(log.file, '');
  });

  test("a job's room is named by its folder in a combine", () {
    final doc = {
      'rooms': [
        {'id': 'room10', 'configPath': r'BSS_103\config.json'},
      ],
    };
    expect(
      describeMergePlace('rooms[id=room10].included', doc),
      'Rooms > "BSS_103" (room10) > Included',
    );
  });

  test("a job's room is named by its label and id, in snapshots too", () {
    final doc = {
      'rooms': [
        {'id': 'room10', 'configPath': r'BSS_103\config.json', 'label': 'BSS 103'},
      ],
      'roomSnapshots': {
        'room10': {'total': 1.0},
      },
    };
    expect(
      describeMergePlace('roomSnapshots.room10.total', doc),
      'Room snapshots > "BSS 103" (room10) > Total',
    );
    expect(
      describeMergePlace('rooms[id=room10].included', doc),
      'Rooms > "BSS 103" (room10) > Included',
    );
  });

  test('changes group under their parent', () {
    expect(mergePlaceGroup('Settings > Projector > Model'),
        'Settings > Projector');
    expect(mergePlaceLeaf('Settings > Projector > Model'), 'Model');
    expect(mergePlaceGroup('Name'), '');
  });
}
