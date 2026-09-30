import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/room_sidecar.dart';

/// The background room read: it stops at the first place a part is found, can
/// be told to read only some parts, and still reads what the plain read does.
void main() {
  late Directory dir;
  late String config;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('rcb_read_async');
    config = path.join(dir.path, 'r1_config.json');
    File(config).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': 'Room 1'},
    }));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void write(String file, Object doc) {
    File(file)
      ..createSync(recursive: true)
      ..writeAsStringSync(doc is String ? doc : jsonEncode(doc));
  }

  Map<String, dynamic> node(String id) => {
        'id': id,
        'label': id,
        'model': 'M',
        'x': 0,
        'y': 0,
        'ports': [],
      };

  test('reads what the plain read reads', () async {
    write(roomSidecarPath(config, RoomSidecarPart.flow), {
      'nodes': [node('a')],
    });
    write(roomSidecarPath(config, RoomSidecarPart.cost), {
      'cost': {
        'priceOverrides': {'k': 5},
      },
    });

    final sync = readRoomFromDisk(config);
    final async = await readRoomFromDiskAsync(config);

    expect(async.title, sync.title);
    expect(async.flowPath, sync.flowPath);
    expect(async.model.nodes.map((n) => n.id), ['a']);
    expect(async.settings.priceOverrides, sync.settings.priceOverrides);
  });

  test('a current file that will not parse falls back as the plain read does',
      () async {
    write(roomSidecarPath(config, RoomSidecarPart.flow), '{ not json');
    write(legacyRoomSidecarPath(config, RoomSidecarPart.flow), {
      'nodes': [node('old')],
    });

    final async = await readRoomFromDiskAsync(config);

    expect(async.model.nodes.map((n) => n.id), ['old']);
    expect(async.flowPath, readRoomFromDisk(config).flowPath);
  });

  test('only the parts asked for are read', () async {
    write(roomSidecarPath(config, RoomSidecarPart.flow), {
      'nodes': [node('a')],
    });
    write(roomSidecarPath(config, RoomSidecarPart.cost), {
      'cost': {
        'priceOverrides': {'k': 5},
      },
    });

    final costOnly = await readRoomFromDiskAsync(
      config,
      parts: {RoomSidecarPart.cost},
    );

    expect(costOnly.model.nodes, isEmpty);
    expect(costOnly.settings.priceOverrides, {'k': 5});
  });
}
