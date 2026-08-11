import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/cabling_schematic.dart';
import 'package:extron_configurator/room_locations.dart';

/// The cabling drawing is DERIVED from the room and then EDITED by hand. The
/// point of keeping those apart is that re-cabling the room moves the counts
/// while everything anybody typed stays exactly where they put it.
void main() {
  AvNode device(String id, String label, String locationId) => AvNode(
    id: id,
    label: label,
    model: '',
    pos: Offset.zero,
    locationId: locationId,
    ports: const [
      AvPort(
        id: 'p1',
        label: 'P1',
        signal: SignalType.network,
        direction: PortDirection.bidirectional,
        side: PortSide.right,
      ),
      AvPort(
        id: 'p2',
        label: 'P2',
        signal: SignalType.network,
        direction: PortDirection.bidirectional,
        side: PortSide.left,
      ),
    ],
  );

  /// A lectern and a rack with cables between them.
  AppStateProvider room({int runs = 2}) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addAvLocation(const RoomLocation(id: 'LOC_1', name: 'Lectern'));
    p.addAvLocation(const RoomLocation(id: 'LOC_2', name: 'Rack'));
    for (int i = 0; i < runs; i++) {
      p.addAvNode(device('A$i', 'Lectern box $i', 'LOC_1'));
      p.addAvNode(device('B$i', 'Rack box $i', 'LOC_2'));
      p.addAvCable(
        fromNodeId: 'A$i',
        fromPortId: 'p1',
        toNodeId: 'B$i',
        toPortId: 'p1',
        signal: SignalType.network,
      );
    }
    return p;
  }

  CablingSchematic drawingOf(AppStateProvider p) =>
      p.cablingSchematic(buildAvFlowModel(p));

  group('what the room draws', () {
    test('a box per place that has something in it', () {
      final drawing = drawingOf(room());
      expect(
        drawing.boxes.map((b) => b.label).toSet(),
        {'Lectern', 'Rack'},
      );
      expect(drawing.boxes.every((b) => b.isDerived), isTrue);
    });

    test('a place with nothing in it is not drawn', () {
      final p = room();
      p.addAvLocation(const RoomLocation(id: 'LOC_9', name: 'Nowhere'));
      expect(
        drawingOf(p).boxes.map((b) => b.label),
        isNot(contains('Nowhere')),
      );
    });

    test('a pull box is drawn on the strength of existing', () {
      // Nothing terminates in one, so waiting for a device to name it would
      // keep it off the drawing forever.
      final p = room();
      p.addAvLocation(
        const RoomLocation(
          id: 'LOC_P',
          name: 'AV pull box',
          zone: RoomZone.pullBox,
        ),
      );
      final drawing = drawingOf(p);
      final pull = drawing.boxes.firstWhere((b) => b.label == 'AV pull box');
      expect(pull.kind, CablingBoxKind.pullBox);
    });

    test('the bundle count is read off the cables, not typed', () {
      expect(drawingOf(room(runs: 3)).bundles.single.count, 3);
      expect(drawingOf(room(runs: 3)).bundles.single.label, '3x Network');

      // Re-cable the room and the drawing follows.
      expect(drawingOf(room(runs: 7)).bundles.single.count, 7);
    });

    test('a run within one place is not a run between places', () {
      final p = room(runs: 0);
      p.addAvNode(device('A', 'One', 'LOC_1'));
      p.addAvNode(device('B', 'Two', 'LOC_1'));
      p.addAvCable(
        fromNodeId: 'A',
        fromPortId: 'p1',
        toNodeId: 'B',
        toPortId: 'p1',
        signal: SignalType.network,
      );
      // Otherwise every rack would have a bundle to itself.
      expect(drawingOf(p).bundles, isEmpty);
    });

    test('direction does not split one bundle into two', () {
      final p = room(runs: 0);
      p.addAvNode(device('A', 'One', 'LOC_1'));
      p.addAvNode(device('B', 'Two', 'LOC_2'));
      p.addAvCable(
        fromNodeId: 'A',
        fromPortId: 'p1',
        toNodeId: 'B',
        toPortId: 'p1',
        signal: SignalType.network,
      );
      // Drawn back the other way — still the same bundle. (Different ports:
      // the same pair cannot be cabled twice, which is a separate rule.)
      p.addAvCable(
        fromNodeId: 'B',
        fromPortId: 'p2',
        toNodeId: 'A',
        toPortId: 'p2',
        signal: SignalType.network,
      );
      expect(drawingOf(p).bundles.single.count, 2);
    });
  });

  group('then edited by hand', () {
    test('a box stays where it was dragged', () {
      final p = room();
      final id = drawingOf(p).boxes.first.id;
      p.setCablingBoxPosition(id, const Offset(500, 400));
      expect(drawingOf(p).boxById(id)!.pos, const Offset(500, 400));
    });

    test('a typed count wins, and is badged as a disagreement', () {
      final p = room(runs: 3);
      final bundle = drawingOf(p).bundles.single;
      expect(bundle.count, 3);

      p.setCablingBundleCount(bundle.id, 13);
      final edited = drawingOf(p);
      expect(edited.bundles.single.count, 13);
      expect(edited.bundles.single.label, '13x Network');
      // The one place the drawing and the room disagree, visible rather than
      // buried.
      expect(edited.overridden, contains(bundle.id));

      // And there is a way back to what the room says.
      p.setCablingBundleCount(bundle.id, null);
      expect(drawingOf(p).bundles.single.count, 3);
      expect(drawingOf(p).overridden, isEmpty);
    });

    test('a renamed box is badged too', () {
      final p = room();
      final id = drawingOf(p).boxes.first.id;
      p.setCablingBoxLabel(id, 'Instructor station');
      final drawing = drawingOf(p);
      expect(drawing.boxById(id)!.label, 'Instructor station');
      expect(drawing.overridden, contains(id));
    });

    test('a hand-added box and run join the drawing', () {
      final p = room();
      final pull = p.addCablingBox(
        kind: CablingBoxKind.pullBox,
        label: 'AV pull box',
      );
      final lectern = drawingOf(p).boxes.firstWhere((b) => b.isDerived);

      final run = p.addCablingBundle(
        fromBoxId: lectern.id,
        toBoxId: pull.id,
        count: 2,
        cableType: 'Cat 6a',
      )!;

      final drawing = drawingOf(p);
      expect(drawing.boxById(pull.id), isNotNull);
      expect(drawing.bundles.map((b) => b.id), contains(run.id));
      expect(
        drawing.bundles.firstWhere((b) => b.id == run.id).label,
        '2x Cat 6a',
      );
      // Hand-drawn, so it is not a disagreement with anything.
      expect(drawing.overridden, isEmpty);
    });

    test('a run to nowhere is dropped rather than drawn', () {
      final p = room();
      final pull = p.addCablingBox(kind: CablingBoxKind.pullBox);
      final lectern = drawingOf(p).boxes.firstWhere((b) => b.isDerived);
      p.addCablingBundle(fromBoxId: lectern.id, toBoxId: pull.id);

      p.removeCablingItem(pull.id);
      expect(drawingOf(p).boxById(pull.id), isNull);
      // A line to nowhere is worse than a missing line.
      expect(drawingOf(p).bundles.every((b) => b.toBoxId != pull.id), isTrue);
    });

    test('a derived box is hidden, not deleted — it would only come back', () {
      final p = room();
      final id = drawingOf(p).boxes.first.id;
      p.removeCablingItem(id);
      expect(drawingOf(p).boxById(id), isNull);
      expect(p.avCabling.hidden, contains(id));

      p.restoreCablingItem(id);
      expect(drawingOf(p).boxById(id), isNotNull);
    });

    test('a bundle whose box was hidden goes with it', () {
      final p = room(runs: 2);
      expect(drawingOf(p).bundles, hasLength(1));
      p.removeCablingItem(drawingOf(p).boxes.first.id);
      expect(drawingOf(p).bundles, isEmpty);
    });

    test('reset throws the edits away and keeps the room', () {
      final p = room(runs: 3);
      final bundle = drawingOf(p).bundles.single;
      p.setCablingBundleCount(bundle.id, 99);
      p.addCablingBox(kind: CablingBoxKind.note, label: 'Scope');

      p.resetCablingSchematic();
      final drawing = drawingOf(p);
      expect(drawing.bundles.single.count, 3);
      expect(drawing.boxes.every((b) => b.isDerived), isTrue);
      expect(p.avCabling.isEmpty, isTrue);
    });
  });

  group('on disk', () {
    test('only the edits are saved, and they come back on top', () async {
      final dir = Directory.systemTemp.createTempSync('cabling_schematic_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final configPath = path.join(dir.path, 'BSS103_config.json');
      File(configPath).writeAsStringSync('{}');

      final p = room(runs: 4)..currentConfigPath = configPath;
      final bundle = drawingOf(p).bundles.single;
      p.setCablingBundleCount(bundle.id, 13);
      p.setCablingBoxPosition(drawingOf(p).boxes.first.id, const Offset(9, 9));
      final note = p.addCablingBox(
        kind: CablingBoxKind.note,
        label: 'TSRV Scope',
        body: '13x Cat5e to SELV Telecom Room',
      );
      await p.saveAvFlow();

      // In the cabling file, with the screen switches.
      final cablingFile =
          File(path.join(dir.path, 'BSS103_config_cabling.json'));
      expect(cablingFile.readAsStringSync(), contains('TSRV Scope'));
      // And NOT in the flow file, which carries the room, not the drawing.
      expect(
        File(path.join(dir.path, 'BSS103_config_av_flow.json'))
            .readAsStringSync(),
        isNot(contains('TSRV Scope')),
      );

      final back = AppStateProvider(autoLoadSettings: false)
        ..currentConfigPath = configPath
        ..loadAvFlowForCurrentConfig();
      final drawing = back.cablingSchematic(buildAvFlowModel(back));

      // The derived part came from the room; the edits came from the file.
      expect(drawing.bundles.single.count, 13);
      expect(drawing.overridden, contains(bundle.id));
      expect(drawing.boxById(note.id)!.body, '13x Cat5e to SELV Telecom Room');

      // A hand-added box after the reload does not reuse a saved id.
      final fresh = back.addCablingBox(kind: CablingBoxKind.pullBox);
      expect(fresh.id, isNot(note.id));
    });

    test('a room with no edits writes no drawing at all', () {
      final p = room();
      expect(p.avFlowAsJson().containsKey('cablingSchematic'), isFalse);
    });
  });
}
