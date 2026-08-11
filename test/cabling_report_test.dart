import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_report.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/cabling_schematic.dart';
import 'package:extron_configurator/report_tools.dart';
import 'package:extron_configurator/room_locations.dart';
import 'package:extron_configurator/room_workbook.dart';

/// The drawing on the Cabling tab is what the trades are handed; the schedule
/// is the same thing in a form somebody can price, order and check off. Both
/// come off the same call, so they cannot disagree about how many cables run
/// where.
void main() {
  AvNode device(String id, String locationId) => AvNode(
    id: id,
    label: id,
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
    ],
  );

  AppStateProvider room({int runs = 3}) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addAvLocation(const RoomLocation(id: 'LOC_1', name: 'Lectern'));
    p.addAvLocation(const RoomLocation(id: 'LOC_2', name: 'Rack'));
    for (int i = 0; i < runs; i++) {
      p.addAvNode(device('A$i', 'LOC_1'));
      p.addAvNode(device('B$i', 'LOC_2'));
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

  ReportSection sectionNamed(List<ReportSection> all, String title) =>
      all.firstWhere((s) => s.title == title);

  group('the cable run schedule', () {
    test('lists the runs with the counts read off the room', () {
      final p = room(runs: 3);
      final runs = sectionNamed(
        cablingSections(buildAvFlowModel(p)),
        'Cabling Runs',
      );
      expect(runs.rows, hasLength(1));
      final row = runs.rows.single;
      expect(row[0], 'Lectern');
      expect(row[1], 'Rack');
      expect(row[2], 3);
      expect(row[4], 'Counted off the signal flow');
    });

    test('says which figures were typed over', () {
      // A schedule that hides which of its numbers were overridden is a
      // schedule nobody can audit.
      final p = room(runs: 3);
      final bundle = p
          .cablingSchematic(buildAvFlowModel(p))
          .bundles
          .single;
      p.setCablingBundleCount(bundle.id, 13);

      final row = sectionNamed(
        cablingSections(buildAvFlowModel(p)),
        'Cabling Runs',
      ).rows.single;
      expect(row[2], 13);
      expect(row[4], 'Counted, then typed over');
    });

    test('marks a run somebody drew by hand as theirs', () {
      final p = room();
      final pull = p.addCablingBox(
        kind: CablingBoxKind.pullBox,
        label: 'AV pull box',
      );
      final lectern = p
          .cablingSchematic(buildAvFlowModel(p))
          .boxes
          .firstWhere((b) => b.isDerived);
      p.addCablingBundle(
        fromBoxId: lectern.id,
        toBoxId: pull.id,
        count: 2,
        cableType: 'Cat 6a',
      );

      final rows = sectionNamed(
        cablingSections(buildAvFlowModel(p)),
        'Cabling Runs',
      ).rows;
      final drawn = rows.firstWhere((r) => r[1] == 'AV pull box');
      expect(drawn[2], 2);
      expect(drawn[3], 'Cat 6a');
      expect(drawn[4], 'Added on the drawing');
    });

    test('totals per cable type — the line a PO is written against', () {
      final p = room(runs: 4);
      final pull = p.addCablingBox(kind: CablingBoxKind.pullBox, label: 'Pull');
      final lectern = p
          .cablingSchematic(buildAvFlowModel(p))
          .boxes
          .firstWhere((b) => b.isDerived);
      p.addCablingBundle(
        fromBoxId: lectern.id,
        toBoxId: pull.id,
        count: 2,
        cableType: 'Cat 6a',
      );

      final totals = sectionNamed(
        cablingSections(buildAvFlowModel(p)),
        'Cable Totals by Type',
      );
      final byType = {for (final r in totals.rows) r[0]: r[1]};
      expect(byType['Network'], 4);
      expect(byType['Cat 6a'], 2);
    });

    test('the boxes table counts what lands on each one', () {
      final p = room(runs: 5);
      final boxes = sectionNamed(
        cablingSections(buildAvFlowModel(p)),
        'Cabling Drawing — Boxes',
      );
      final lectern = boxes.rows.firstWhere((r) => r[0] == 'Lectern');
      expect(lectern[1], 'Location');
      expect(lectern[2], 5);
    });

    test('the scope notes are carried, not dropped', () {
      final p = room();
      p.addCablingBox(
        kind: CablingBoxKind.note,
        label: 'TSRV Scope',
        body: '13x Cat5e to SELV Telecom Room\nSome will require VLAN 500',
      );
      final boxes = sectionNamed(
        cablingSections(buildAvFlowModel(p)),
        'Cabling Drawing — Boxes',
      );
      final note = boxes.rows.firstWhere((r) => r[0] == 'TSRV Scope');
      expect(note[1], 'Notes');
      // Flattened onto one line for a table cell, not thrown away — they say
      // whose contract each part of the job is.
      expect(note[3], contains('13x Cat5e to SELV Telecom Room'));
      expect(note[3], contains('VLAN 500'));
      expect(note[3], isNot(contains('\n')));
    });

    test('a room with no drawing grows no tables', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Bare'},
        };
      p.loadAvFlowForCurrentConfig();
      expect(cablingSections(buildAvFlowModel(p)), isEmpty);
    });
  });

  group('in the documents', () {
    test('the AV report carries the schedule', () {
      final p = room();
      final titles = avReportSections(p, buildAvFlowModel(p))
          .map((s) => s.title);
      expect(titles, contains('Cabling Runs'));
      expect(titles, contains('Cable Totals by Type'));
    });

    test('the workbook has a Cabling sheet, in reading order', () {
      // Rough-in order: what is in the room, where it is, how it is cabled,
      // then what it is racked in and what it costs.
      expect(kRoomWorkbookSheets, [
        'Control',
        'AV Flow',
        'Locations',
        'Cabling',
        'Racks',
        'Cost Estimate',
      ]);
    });

    test('the workbook builds with the sheet in it', () {
      final p = room();
      final bytes = buildRoomWorkbookBytes(
        provider: p,
        av: buildAvFlowModel(p),
      );
      expect(bytes, isNotEmpty);
    });
  });
}
