import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/room_sidecar.dart';

/// The signal flow used to be able to show ONE picture behind it — the room's
/// floor plan, on a toggle. That was the wrong picture nearly every time: a
/// flow is laid out by signal, not by geometry, so a plan behind it lines up
/// with nothing, and a title block or a marked-up revision could not get back
/// there at all. Now it is any image, and it belongs to the flow.
void main() {
  group('the backdrop', () {
    test('a fresh room has none', () {
      final p = AppStateProvider(autoLoadSettings: false);
      expect(p.avFlowBackground.hasImage, isFalse);
      // And writes nothing, so a room without one has no key for it on disk.
      expect(p.avFlowAsJson().containsKey('flowBackground'), isFalse);
    });

    test('setting one records the file and its natural size', () {
      final p = AppStateProvider(autoLoadSettings: false);
      p.setAvFlowBackgroundImage('room_flow_background.png', const Size(800, 600));

      expect(p.avFlowBackground.hasImage, isTrue);
      expect(p.avFlowBackground.imageSize, const Size(800, 600));
      // Faint by default: it is there to be referred to, not looked at.
      expect(p.avFlowBackground.opacity, lessThan(1.0));
    });

    test('opacity and size are set without disturbing the image', () {
      final p = AppStateProvider(autoLoadSettings: false);
      p.setAvFlowBackgroundImage('bg.png', const Size(800, 600));
      p.setAvFlowBackgroundView(opacity: 0.8, scale: 0.5);

      expect(p.avFlowBackground.imageFile, 'bg.png');
      expect(p.avFlowBackground.opacity, 0.8);
      expect(p.avFlowBackground.scale, 0.5);
    });

    test('removing it is undoable, like every other edit to the room', () {
      final p = AppStateProvider(autoLoadSettings: false);
      p.setAvFlowBackgroundImage('bg.png', const Size(800, 600));
      p.clearAvFlowBackground();
      expect(p.avFlowBackground.hasImage, isFalse);

      p.undoAvFlow(AvUndoScope.flow);
      expect(p.avFlowBackground.imageFile, 'bg.png');
    });

    test('it belongs to the flow file, not to the floor plans', () {
      // Which picture is behind THIS drawing is a property of this drawing.
      final p = AppStateProvider(autoLoadSettings: false);
      p.setAvFlowBackgroundImage('bg.png', const Size(800, 600));

      final parts = splitRoomSidecar(p.avFlowAsJson());
      expect(parts[RoomSidecarPart.flow]!['flowBackground'], isNotNull);
      expect(
        parts[RoomSidecarPart.floorPlans]!.containsKey('flowBackground'),
        isFalse,
      );
    });
  });

  group('on disk', () {
    late Directory dir;
    late String configPath;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('flow_background_');
      configPath = path.join(dir.path, 'BSS103_config.json');
      File(configPath).writeAsStringSync('{}');
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('the room opens again with its backdrop', () async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..currentConfigPath = configPath;
      p.setAvFlowBackgroundImage('bg.png', const Size(640, 480));
      p.setAvFlowBackgroundView(opacity: 0.6, scale: 0.75);
      expect(await p.saveAvFlow(), isNotEmpty);

      final back = AppStateProvider(autoLoadSettings: false)
        ..currentConfigPath = configPath
        ..loadAvFlowForCurrentConfig();

      expect(back.avFlowBackground.imageFile, 'bg.png');
      expect(back.avFlowBackground.imageSize, const Size(640, 480));
      expect(back.avFlowBackground.opacity, 0.6);
      expect(back.avFlowBackground.scale, 0.75);
    });

    test('an imported picture is copied in beside the config', () async {
      // A room folder is the unit that gets zipped and mailed; a backdrop
      // referenced off somebody's desktop is a broken picture the moment it
      // leaves this machine.
      final source = File(path.join(dir.path, 'somewhere_else.png'))
        ..writeAsBytesSync(const [1, 2, 3, 4]);
      final p = AppStateProvider(autoLoadSettings: false)
        ..currentConfigPath = configPath;

      final stored = await p.importRoomImage(source.path, 'flow_background');
      expect(path.isAbsolute(stored), isFalse, reason: 'stored by NAME');
      expect(stored, contains('flow_background'));
      expect(File(path.join(dir.path, stored)).existsSync(), isTrue);
      expect(p.resolveFloorPlanImage(stored), path.join(dir.path, stored));
    });

    test('a second import does not overwrite the first', () async {
      final source = File(path.join(dir.path, 'src.png'))
        ..writeAsBytesSync(const [1, 2, 3, 4]);
      final p = AppStateProvider(autoLoadSettings: false)
        ..currentConfigPath = configPath;

      final one = await p.importRoomImage(source.path, 'flow_background');
      final two = await p.importRoomImage(source.path, 'flow_background');
      expect(one, isNot(two));
    });
  });
}
