import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_report.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/cabling_schematic.dart';
import 'package:extron_configurator/room_locations.dart';

/// The run that actually gets installed is rarely a straight line between two
/// pieces of gear: it leaves the projector box, lands in an AV pull box above
/// the ceiling and carries on to the equipment rack. Recording only the two
/// ends drew a line through the middle of the room, quoted a length nobody
/// could pull, and left the pull box — the thing the electrician has to
/// install — off the drawing entirely.
///
/// And the cable carries a NUMBER. The schedule says C-101, the label on the
/// cable says C-101, and a drawing that only says "1x Cat 6a" leaves whoever
/// is holding the end of it nothing to match against.
void main() {
  /// A room with the three places a real run passes through, and nothing else.
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addAvLocation(
      const RoomLocation(
        id: 'LOC_1',
        name: 'Projector box',
        zone: RoomZone.ceiling,
      ),
    );
    p.addAvLocation(
      const RoomLocation(
        id: 'LOC_2',
        name: 'AV pull box',
        zone: RoomZone.pullBox,
      ),
    );
    p.addAvLocation(
      const RoomLocation(
        id: 'LOC_3',
        name: 'Equipment rack',
        zone: RoomZone.rack,
      ),
    );
    p.addAvLocation(
      const RoomLocation(
        id: 'LOC_4',
        name: 'IDF 2B',
        zone: RoomZone.equipmentRoom,
      ),
    );
    return p;
  }

  CablingSchematic drawingOf(AppStateProvider p) =>
      p.cablingSchematic(buildAvFlowModel(p));

  group('the model', () {
    test('a plain run is one leg, end to end', () {
      const run = ScreenSwitch(
        id: 'SCRSW_1',
        label: 'Front screen',
        startLocationId: 'LOC_1',
        endLocationId: 'LOC_3',
      );
      expect(run.pathLocationIds, ['LOC_1', 'LOC_3']);
      expect(run.legs.length, 1);
    });

    test('a run through a pull box is two', () {
      const run = ScreenSwitch(
        id: 'SCRSW_1',
        label: 'Front screen',
        startLocationId: 'LOC_1',
        viaLocationIds: ['LOC_2'],
        endLocationId: 'LOC_3',
      );
      expect(run.pathLocationIds, ['LOC_1', 'LOC_2', 'LOC_3']);
      expect(run.legs, [
        (from: 'LOC_1', to: 'LOC_2'),
        (from: 'LOC_2', to: 'LOC_3'),
      ]);
    });

    test('a via that repeats the place before it is collapsed', () {
      const run = ScreenSwitch(
        id: 'SCRSW_1',
        label: 'x',
        startLocationId: 'LOC_1',
        viaLocationIds: ['LOC_1', 'LOC_2'],
        endLocationId: 'LOC_2',
      );
      // A zero-length leg is a line the drawing cannot draw and a row the
      // schedule should not print.
      expect(run.pathLocationIds, ['LOC_1', 'LOC_2']);
      expect(run.legs.length, 1);
    });

    test('the route survives a round trip through the sidecar', () {
      const run = ScreenSwitch(
        id: 'SCRSW_1',
        label: 'Front screen',
        startLocationId: 'LOC_1',
        viaLocationIds: ['LOC_2'],
        endLocationId: 'LOC_3',
        cableNumber: 'C-101',
        cableType: 'Control Cable Cat5e',
      );
      final back = ScreenSwitch.fromJson(run.toJson());
      expect(back.viaLocationIds, ['LOC_2']);
      expect(back.cableNumber, 'C-101');
      expect(back.cableType, 'Control Cable Cat5e');
    });
  });

  group('the cabling drawing', () {
    test('draws one bundle per leg, through the pull box', () {
      final p = room();
      p.addAvScreenSwitch(
        const ScreenSwitch(
          id: '',
          label: 'Front screen',
          startLocationId: 'LOC_1',
          viaLocationIds: ['LOC_2'],
          endLocationId: 'LOC_3',
          cableType: 'Control Cable Cat5e',
        ),
      );

      final drawing = drawingOf(p);
      final ends = [
        for (final b in drawing.bundles) '${b.fromBoxId}->${b.toBoxId}',
      ]..sort();
      expect(ends, ['loc:LOC_1->loc:LOC_2', 'loc:LOC_2->loc:LOC_3']);
      // And the pull box is a box on the sheet, not an implied waypoint.
      expect(
        drawing.boxById('loc:LOC_2')?.kind,
        CablingBoxKind.pullBox,
      );
    });

    test('the first leg keeps the id a two-end run always had', () {
      // So an override typed against the run — a recolour, a retyped count —
      // is not orphaned by somebody adding a pull box to the middle of it.
      final p = room();
      final run = p.addAvScreenSwitch(
        const ScreenSwitch(
          id: '',
          label: 'Front screen',
          startLocationId: 'LOC_1',
          endLocationId: 'LOC_3',
        ),
      );
      expect(
        drawingOf(p).bundles.single.id,
        '$kCablingScreenRunPrefix${run.id}',
      );

      p.updateAvScreenSwitch(run.copyWith(viaLocationIds: ['LOC_2']));
      final ids = [for (final b in drawingOf(p).bundles) b.id]..sort();
      expect(ids.first, '$kCablingScreenRunPrefix${run.id}');
      expect(ids.length, 2);
    });

    test('every leg is labelled with the same cable number', () {
      final p = room();
      p.addAvScreenSwitch(
        const ScreenSwitch(
          id: '',
          label: 'Front screen',
          startLocationId: 'LOC_1',
          viaLocationIds: ['LOC_2'],
          endLocationId: 'LOC_3',
          cableNumber: 'C-101',
          cableType: 'Control Cable Cat5e',
        ),
      );

      for (final b in drawingOf(p).bundles) {
        expect(b.tag, 'C-101');
        expect(b.label, 'C-101 · 1x Control Cable Cat5e');
      }
    });

    test('a run with no number reads exactly as it always did', () {
      final p = room();
      p.addAvScreenSwitch(
        const ScreenSwitch(
          id: '',
          label: 'Front screen',
          startLocationId: 'LOC_1',
          endLocationId: 'LOC_3',
          cableType: 'Cat 6',
        ),
      );
      expect(drawingOf(p).bundles.single.label, '1x Cat 6');
    });
  });

  group('off the sheet', () {
    test('a run to an equipment room is drawn as one that leaves', () {
      final p = room();
      p.addAvScreenSwitch(
        const ScreenSwitch(
          id: '',
          label: 'Network drop',
          startLocationId: 'LOC_3',
          endLocationId: 'LOC_4',
          cableType: 'Network to IDF Cat6a',
        ),
      );
      final drawing = drawingOf(p);
      expect(drawing.isOffSheet(drawing.bundles.single), isTrue);
    });

    test('a run between two places in the room is not', () {
      final p = room();
      p.addAvScreenSwitch(
        const ScreenSwitch(
          id: '',
          label: 'Front screen',
          startLocationId: 'LOC_1',
          endLocationId: 'LOC_3',
        ),
      );
      final drawing = drawingOf(p);
      expect(drawing.isOffSheet(drawing.bundles.single), isFalse);
    });
  });

  group('line styles', () {
    test('the first cable on the sheet is a plain solid line', () {
      final p = room();
      p.addAvScreenSwitch(
        const ScreenSwitch(
          id: '',
          label: 'Front screen',
          startLocationId: 'LOC_1',
          endLocationId: 'LOC_3',
        ),
      );
      final drawing = drawingOf(p);
      expect(
        drawing.bundleLineStyles[drawing.bundles.single.id],
        RunLineStyle.solid,
      );
    });

    test('each CABLE gets a pattern, so the key can name it', () {
      // Colour alone fails the moment the sheet is printed in black and white.
      // The pattern is keyed off the cable rather than the run's position in a
      // fan, so "Cat 6a is the dashed one" is true of every Cat 6a on the
      // sheet — which is the whole job of a legend.
      final p = room();
      for (final type in [
        'AV Point to Point Cat6a',
        'Control Cable Cat5e',
        'Network to IDF Cat6a',
      ]) {
        p.addAvScreenSwitch(
          ScreenSwitch(
            id: '',
            label: type,
            startLocationId: 'LOC_1',
            endLocationId: 'LOC_3',
            cableType: type,
          ),
        );
      }
      final drawing = drawingOf(p);
      expect(drawing.bundles.length, 3);
      expect(
        drawing.bundleLineStyles.values.toSet().length,
        3,
        reason: 'three cables, three patterns',
      );
      // And the key strikes each line the same way the drawing does.
      expect(
        [for (final e in drawing.key) e.style],
        drawing.bundles.map((b) => drawing.bundleLineStyles[b.id]).toList(),
      );
    });

    test('two runs of the SAME cable look alike - they are alike', () {
      // They are told apart by being fanned onto their own lanes, not by
      // being drawn as if they were different cables.
      final p = room();
      for (int i = 0; i < 2; i++) {
        p.addAvScreenSwitch(
          ScreenSwitch(
            id: '',
            label: 'Screen $i',
            startLocationId: 'LOC_1',
            endLocationId: 'LOC_3',
            cableType: 'Control Cable Cat5e',
          ),
        );
      }
      final drawing = drawingOf(p);
      expect(drawing.bundleLineStyles.values.toSet().length, 1);
      expect(drawing.bundleLanes.values.toSet().length, 2);
    });
  });

  group('the schedule', () {
    test('carries the cable number and the places it is routed through', () {
      final p = room();
      p.addAvScreenSwitch(
        const ScreenSwitch(
          id: '',
          label: 'Front screen',
          startLocationId: 'LOC_1',
          viaLocationIds: ['LOC_2'],
          endLocationId: 'LOC_3',
          cableNumber: 'C-101',
        ),
      );

      final section = locationSections(buildAvFlowModel(p)).firstWhere(
        (s) => s.title == 'Cable Runs',
      );
      expect(section.header, contains('Cable #'));
      expect(section.header, contains('Routed through'));
      final row = section.rows.single;
      expect(row[section.header.indexOf('Cable #')], 'C-101');
      expect(row[section.header.indexOf('Routed through')], 'AV pull box');
    });

    test('lists two pull boxes one per line, not run together', () {
      final p = room();
      p.addAvScreenSwitch(
        const ScreenSwitch(
          id: '',
          label: 'Front screen',
          startLocationId: 'LOC_1',
          viaLocationIds: ['LOC_2', 'LOC_3'],
          endLocationId: 'LOC_4',
        ),
      );
      final section = locationSections(buildAvFlowModel(p)).firstWhere(
        (s) => s.title == 'Cable Runs',
      );
      expect(
        section.rows.single[section.header.indexOf('Routed through')],
        'AV pull box\nEquipment rack',
      );
    });
  });

  group('the cable type lists', () {
    test('offer the three the office specifies most', () {
      for (final type in [
        'AV Point to Point Cat6a',
        'Control Cable Cat5e',
        'Network to IDF Cat6a',
      ]) {
        expect(kScreenSwitchCableTypes, contains(type));
        expect(kCablingCableTypes, contains(type));
      }
    });
  });
}
