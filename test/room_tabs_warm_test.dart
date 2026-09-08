import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';

/// ============================================================================
///  THE ROOM IS WORKED OUT WHEN IT ARRIVES, NOT WHEN A TAB IS OPENED
/// ============================================================================
///  Every drawing tab reads the same three things off the room: the AV model,
///  the cabling sheet built over it, and the estimate priced off that. Each is
///  a walk of the whole room, and each used to be worked out again inside the
///  build() of whichever page was being opened — so changing tabs paid for
///  arithmetic that had already been done, and paid for it again on the way
///  back.
///
///  Two halves are checked here:
///
///    * ONE ANSWER, SHARED. The pages get the same object until something
///      actually changes, so a tab switch spends nothing.
///    * WORKED OUT AT THE DOOR. Opening a room leaves all three in hand, so
///      even the first page opened has nothing left to compute.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_warm'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// A room on disk with one device drawn on it.
  String writeRoom(String stem) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': 'Room $stem'},
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [
        AvNode(
          id: 'n1',
          label: 'Display',
          model: 'Display X',
          pos: Offset.zero,
          ports: const [],
        ).toJson(),
      ],
    }));
    return configPath;
  }

  AppStateProvider provider() => AppStateProvider(autoLoadSettings: false)
    ..rootFolderPath = dir.path
    ..avDeviceLibrary = (AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'Display X',
        manufacturer: 'Generic',
        category: 'Display',
        price: 1000,
        ports: [],
      )));

  // -------------------------------------------------------------------------
  //  ONE ANSWER, SHARED
  // -------------------------------------------------------------------------

  group('what the tabs derive is worked out once', () {
    test('two reads with nothing between them are the same object', () async {
      final p = provider();
      await p.openConfigAtPath(writeRoom('a'));
      p.loadAvFlowForCurrentConfig();

      expect(identical(p.avFlowModel, p.avFlowModel), isTrue);
      expect(identical(p.cablingDrawing, p.cablingDrawing), isTrue);
      expect(identical(p.roomCost, p.roomCost), isTrue);
    });

    test('an edit to the room drops all three', () async {
      final p = provider();
      await p.openConfigAtPath(writeRoom('a'));
      p.loadAvFlowForCurrentConfig();

      final model = p.avFlowModel;
      final drawing = p.cablingDrawing;
      final cost = p.roomCost;

      p.addAvNode(AvNode(
        id: 'n2',
        label: 'Camera',
        model: 'Camera Y',
        pos: const Offset(100, 0),
        ports: const [],
      ));

      expect(identical(p.avFlowModel, model), isFalse);
      expect(identical(p.cablingDrawing, drawing), isFalse);
      expect(identical(p.roomCost, cost), isFalse);
      expect(p.avFlowModel.nodes, hasLength(2));
    });

    test('the cached model is the one a fresh build would give', () async {
      final p = provider();
      await p.openConfigAtPath(writeRoom('a'));
      p.loadAvFlowForCurrentConfig();

      final fresh = buildAvFlowModel(p);
      expect(p.avFlowModel.nodes.map((n) => n.id),
          fresh.nodes.map((n) => n.id));
      expect(p.avFlowModel.cables.map((c) => c.id),
          fresh.cables.map((c) => c.id));
    });
  });

  // -------------------------------------------------------------------------
  //  WORKED OUT AT THE DOOR
  // -------------------------------------------------------------------------

  group('opening a room works its tabs out', () {
    test('the model, the sheet and the price are all in hand', () async {
      final p = provider();
      await p.openConfigAtPath(writeRoom('a'));
      p.loadAvFlowForCurrentConfig();

      // Nothing is asked for here: if the load left them empty, the getters
      // would build them and this would pass for the wrong reason. The count
      // of what the room holds is read off the model that is already there.
      expect(p.roomTabsAreWarm, isTrue,
          reason: 'the first tab opened should have nothing left to compute');
    });

    test('the same is true switching rooms on a project', () async {
      final p = provider();
      p.newProject(name: 'Warm test');
      p.addRoomToProject(writeRoom('a'));
      p.addRoomToProject(writeRoom('b'));

      await p.openProjectRoomRef(p.project.rooms.last);

      expect(p.roomTabsAreWarm, isTrue);
    });

    test('a room switch does not leave the last room cached', () async {
      final p = provider();
      p.newProject(name: 'Warm test');
      p.addRoomToProject(writeRoom('a'));
      p.addRoomToProject(writeRoom('b'));

      await p.openProjectRoomRef(p.project.rooms.first);
      final first = p.avFlowModel;
      await p.openProjectRoomRef(p.project.rooms.last);

      expect(identical(p.avFlowModel, first), isFalse,
          reason: "the previous room's model must not linger");
    });
  });
}
