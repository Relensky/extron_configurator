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

  /// "Six Cat 6a and five Cat 5e from the lectern to the pathway" is two lines
  /// of cable on one route. The drawing has to say both, tell them apart, and
  /// let either be clicked.
  group('more than one cable type on one route', () {
    test('two runs share an edge and are fanned apart', () {
      final p = room(runs: 0);
      final a = p.addCablingBox(kind: CablingBoxKind.pullBox, label: 'Lectern');
      final b = p.addCablingBox(kind: CablingBoxKind.pathway, label: 'Pathway');
      final six = p.addCablingBundle(
        fromBoxId: a.id,
        toBoxId: b.id,
        count: 6,
        cableType: 'Cat 6a',
      )!;
      final five = p.addCablingBundle(
        fromBoxId: a.id,
        toBoxId: b.id,
        count: 5,
        cableType: 'Cat 5e',
      )!;

      final drawing = drawingOf(p);
      expect(drawing.bundlesBetween(a.id, b.id), hasLength(2));
      expect(drawing.bundles.map((x) => x.label),
          containsAll(['6x Cat 6a', '5x Cat 5e']));

      // Fanned either side of where a single run would sit, so one cannot
      // hide the other.
      final lanes = drawing.bundleLanes;
      expect(lanes[six.id], isNot(lanes[five.id]));
      expect(lanes[six.id]! + lanes[five.id]!, 0);

      // And they are drawn on different lines.
      final one = drawing.endsOf(drawing.bundles.first, lanes[six.id]!)!;
      final two = drawing.endsOf(drawing.bundles.last, lanes[five.id]!)!;
      expect(one.from, isNot(two.from));
    });

    test('a single run is not pushed off centre for no reason', () {
      final p = room(runs: 0);
      final a = p.addCablingBox(kind: CablingBoxKind.pullBox);
      final b = p.addCablingBox(kind: CablingBoxKind.pathway);
      final only = p.addCablingBundle(fromBoxId: a.id, toBoxId: b.id)!;
      expect(drawingOf(p).bundleLanes[only.id], 0);
    });
  });

  group('colour: one per cable, not one per signal', () {
    /// A room whose two places are joined by network runs AND by HDBaseT and
    /// Dante runs — the two signals that both get filed as "AV cabling".
    AppStateProvider mixedRoom() {
      final p = room(runs: 1);
      for (final (i, signal) in [
        SignalType.hdbaset,
        SignalType.dante,
      ].indexed) {
        p.addAvNode(
          AvNode(
            id: 'X$i',
            label: 'X$i',
            model: '',
            pos: Offset.zero,
            locationId: 'LOC_1',
            ports: [
              AvPort(
                id: 'p1',
                label: 'P1',
                signal: signal,
                direction: PortDirection.bidirectional,
                side: PortSide.right,
              ),
            ],
          ),
        );
        p.addAvNode(
          AvNode(
            id: 'Y$i',
            label: 'Y$i',
            model: '',
            pos: Offset.zero,
            locationId: 'LOC_2',
            ports: [
              AvPort(
                id: 'p1',
                label: 'P1',
                signal: signal,
                direction: PortDirection.bidirectional,
                side: PortSide.left,
              ),
            ],
          ),
        );
        p.addAvCable(
          fromNodeId: 'X$i',
          fromPortId: 'p1',
          toNodeId: 'Y$i',
          toPortId: 'p1',
          signal: signal,
        );
      }
      return p;
    }

    test('two signals filed as the same cable are drawn as one cable', () {
      // HDBaseT and Dante are both "AV cabling" and both come off the same
      // reel. Drawing them in two colours told whoever was pulling them they
      // were two different things.
      final drawing = drawingOf(mixedRoom());
      final av = drawing.bundles.where((b) => b.cableType == 'AV cabling');
      expect(av, hasLength(2));
      expect(av.map((b) => b.color).toSet(), hasLength(1));
    });

    test('a different category of the same cable is a different colour', () {
      // The example the rule exists for: AV Cat 6a and network Cat 6a are two
      // pulls, by two contractors, to two test standards.
      final p = mixedRoom();
      final drawing = drawingOf(p);
      final av = drawing.bundles.firstWhere((b) => b.cableType == 'AV cabling');
      final net = drawing.bundles.firstWhere((b) => b.cableType == 'Network');

      p.setCablingBundleType(av.id, 'Cat 6a');
      p.setCablingBundleType(net.id, 'Cat 6a');

      final after = drawingOf(p);
      final avAfter = after.bundles.firstWhere((b) => b.id == av.id);
      final netAfter = after.bundles.firstWhere((b) => b.id == net.id);
      expect(avAfter.cableType, 'Cat 6a');
      expect(netAfter.cableType, 'Cat 6a');
      expect(avAfter.color, isNot(netAfter.color));
    });

    test('the same cable typed two ways is still one colour', () {
      // "Cat6a" and "CAT 6A" are one line on a purchase order and one line on
      // the drawing.
      final p = mixedRoom();
      final drawing = drawingOf(p);
      final av = drawing.bundles.where((b) => b.cableType == 'AV cabling')
          .toList();
      p.setCablingBundleType(av[0].id, 'Cat6a');
      p.setCablingBundleType(av[1].id, 'CAT 6A');

      final after = drawingOf(p);
      expect(
        after.bundles.where((b) => av.any((x) => x.id == b.id))
            .map((b) => b.color)
            .toSet(),
        hasLength(1),
      );
    });

    test('a run can be recoloured by hand, and put back', () {
      final p = room(runs: 2);
      final bundle = drawingOf(p).bundles.single;
      final fromKey = bundle.color;
      p.setCablingBundleColor(bundle.id, 0xFF00FF00);
      expect(drawingOf(p).bundles.single.color, 0xFF00FF00);

      // Recolouring is how the sheet is DRAWN, not a disagreement with what
      // the room counted — so it does not badge the run as edited.
      expect(drawingOf(p).overridden, isEmpty);

      p.setCablingBundleColor(bundle.id, null);
      expect(drawingOf(p).bundles.single.color, fromKey);
    });

    test('the colour goes to disk with the other edits', () {
      final p = room(runs: 2);
      p.setCablingBundleColor(drawingOf(p).bundles.single.id, 0xFF123456);

      final back = CablingOverrides()..readJson(p.avCabling.toJson());
      expect(back.colors.values.single, 0xFF123456);
    });
  });

  group('the key', () {
    test('one line per cable, with what there is of it', () {
      final p = room(runs: 3);
      final key = drawingOf(p).key;
      expect(key, hasLength(1));
      expect(key.single.type, 'Network');
      expect(key.single.count, 3);
      expect(key.single.runs, 1);
      // Nothing else claims "Network", so the category would only be noise.
      expect(key.single.categoryMatters, isFalse);
    });

    test('the key line and the runs it names carry the same colour', () {
      // Derived from the same bundles, which is the whole reason not to let
      // anybody maintain a legend by hand.
      final drawing = drawingOf(room(runs: 2));
      expect(drawing.key.single.color, drawing.bundles.single.color);
    });

    test('an empty drawing has no key to print', () {
      expect(drawingOf(room(runs: 0)).key, isEmpty);
    });
  });

  /// A screen switch and the motor it drives are two places in this room with
  /// cable between them. Before this they lived only in a table at the back of
  /// the report, which is exactly why they turned up as a surprise at rough-in.
  group('screen and shade control runs', () {
    AppStateProvider withScreenRun({String cableType = ''}) {
      final p = room(runs: 0);
      p.addAvScreenSwitch(
        const ScreenSwitch(
          id: '',
          label: 'Front screen',
          startLocationId: 'LOC_1',
          endLocationId: 'LOC_2',
        ),
      );
      if (cableType.isNotEmpty) {
        final s = p.avScreenSwitches.single;
        p.updateAvScreenSwitch(s.copyWith(cableType: cableType));
      }
      return p;
    }

    test('it is drawn as a run between the two places', () {
      final drawing = drawingOf(withScreenRun());
      final run = drawing.bundles.single;
      expect(run.isControlRun, isTrue);
      expect(run.count, 1);
      // Both ends earn a box, even though neither is a device on the flow.
      expect(drawing.boxes.map((b) => b.label), containsAll(['Lectern', 'Rack']));
    });

    test('it says what cable it is, and takes a typed one', () {
      expect(drawingOf(withScreenRun()).bundles.single.cableType,
          kCablingControlRunType);
      // The point of the field: somebody types Cat 5e and the drawing says so.
      expect(
        drawingOf(withScreenRun(cableType: 'Cat 5e')).bundles.single.cableType,
        'Cat 5e',
      );
    });

    test('it is drawn in the control colour, not the signal palette', () {
      // A control run landed on a data switch is the mistake this colour
      // exists to prevent.
      expect(drawingOf(withScreenRun()).bundles.single.color,
          kCablingControlRunColor);
    });

    test('it is the room\'s, so the drawing hides it rather than deleting it',
        () {
      final p = withScreenRun();
      final id = drawingOf(p).bundles.single.id;
      p.removeCablingItem(id);
      expect(drawingOf(p).bundles, isEmpty);
      expect(p.avCabling.hidden, contains(id));
      p.restoreCablingItem(id);
      expect(drawingOf(p).bundles, hasLength(1));
    });

    test('a run with only one end recorded is not drawn', () {
      final p = room(runs: 0);
      p.addAvScreenSwitch(
        const ScreenSwitch(
          id: '',
          label: 'Rear shade',
          startLocationId: 'LOC_1',
          endNote: 'somewhere above the whiteboard',
        ),
      );
      // A line to nowhere is worse than a missing line.
      expect(drawingOf(p).bundles, isEmpty);
    });
  });

  group('the sheet reads', () {
    test('a notes block grows to hold what is in it', () {
      const short = CablingBox(
        id: 'box:1',
        label: 'Scope',
        kind: CablingBoxKind.note,
        body: 'One line',
      );
      final long = CablingBox(
        id: 'box:2',
        label: 'Scope',
        kind: CablingBoxKind.note,
        body: List.filled(20, 'A line of scope note text').join('\n'),
      );
      expect(long.size.height, greaterThan(short.size.height));
      // Same column width either way — a notes block down the side of a sheet
      // is a column, not a paragraph that reflows.
      expect(long.size.width, short.size.width);
    });

    test('a label sits halfway along the run, not between its ends', () {
      // A run detouring around a rack has a straight-line middle that can be
      // well off the line it is supposed to be labelling.
      const dogleg = [Offset(0, 0), Offset(0, 100), Offset(100, 100)];
      expect(polylineMidpoint(dogleg), const Offset(0, 100));
      expect(
        polylineMidpoint(const [Offset(0, 0), Offset(10, 0)]),
        const Offset(5, 0),
      );
      expect(polylineMidpoint(const []), Offset.zero);
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
