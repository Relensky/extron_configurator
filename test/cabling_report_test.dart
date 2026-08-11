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
      expect(row[3], 'Network');
      expect(row[5], 'Counted off the signal flow');
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
      expect(row[5], 'Counted, then typed over');
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
      expect(drawn[5], 'Added on the drawing');
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
      final byType = {for (final r in totals.rows) r[0]: r[2]};
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

  /// A DTP run and a Dante run are both AV cabling to whoever pulls them, and
  /// different things to whoever lands them — so every sheet says the family
  /// and then says the signal, and the two can never drift apart.
  group('AV cabling and the signal under it', () {
    AppStateProvider mixedRoom() {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Mixed'},
        };
      p.loadAvFlowForCurrentConfig();
      p.addAvLocation(const RoomLocation(id: 'LOC_1', name: 'Lectern'));
      p.addAvLocation(const RoomLocation(id: 'LOC_2', name: 'Rack'));
      var n = 0;
      void run(SignalType signal, double feet) {
        n++;
        p.addAvNode(device('A$n', 'LOC_1'));
        p.addAvNode(device('B$n', 'LOC_2'));
        final cable = p.addAvCable(
          fromNodeId: 'A$n',
          fromPortId: 'p1',
          toNodeId: 'B$n',
          toPortId: 'p1',
          signal: signal,
        )!;
        if (feet > 0) p.setAvCableLength(cable.id, feet);
      }

      run(SignalType.hdbaset, 25);
      run(SignalType.hdbaset, 25);
      run(SignalType.dante, 6);
      run(SignalType.network, 0);
      return p;
    }

    test('the drawing files a DTP run under AV cabling', () {
      final p = mixedRoom();
      final bundles = p.cablingSchematic(buildAvFlowModel(p)).bundles;
      final dtp = bundles.firstWhere((b) => b.signal == SignalType.hdbaset);
      expect(dtp.label, '2x AV cabling');
      // The family on the line, the signal under it.
      expect(dtp.signalSubLabel, 'HDBaseT / DTP');

      final dante = bundles.firstWhere((b) => b.signal == SignalType.dante);
      expect(dante.cableType, 'AV cabling');
      expect(dante.signalSubLabel, 'Dante / AES67');

      // Network is already its own name — printing it twice says nothing.
      final net = bundles.firstWhere((b) => b.signal == SignalType.network);
      expect(net.cableType, 'Network');
      expect(net.signalSubLabel, '');
    });

    test('the counts split AV cabling from network, per type and length', () {
      final p = mixedRoom();
      final counts = sectionNamed(
        cablingSections(buildAvFlowModel(p)),
        'Cable Counts by Type and Length',
      );

      // A column per length actually in use, plus one for the runs nobody has
      // decided about — folding those into the shortest lead would be a guess.
      expect(counts.header, contains('6ft'));
      expect(counts.header, contains('25ft'));
      expect(counts.header, contains('No length set'));
      expect(counts.header, isNot(contains('15ft')));

      final byRow = {for (final r in counts.rows) '${r[0]}|${r[1]}': r};
      // The family totals, then what is in it.
      expect(byRow['— AV cabling —|']![2], 3);
      expect(byRow['AV cabling|HDBaseT / DTP']![2], 2);
      expect(byRow['AV cabling|Dante / AES67']![2], 1);
      expect(byRow['— Network —|']![2], 1);
      expect(byRow['All cabling|']![2], 4);

      // The exact number of each type in each length.
      final lengthAt = counts.header.indexOf('25ft');
      expect(byRow['AV cabling|HDBaseT / DTP']![lengthAt], 2);
      expect(byRow['— Network —|']![counts.header.indexOf('No length set')], 1);
    });

    test('the cable schedule carries the family, the signal and the length', () {
      final p = mixedRoom();
      final schedule = sectionNamed(
        avReportSections(p, buildAvFlowModel(p)),
        'Cable Schedule',
      );
      final type = schedule.header.indexOf('Cable type');
      final length = schedule.header.indexOf('Length');
      final dtp = schedule.rows.firstWhere((r) => r[type] == 'AV cabling');
      expect(dtp[schedule.header.indexOf('Signal')], 'HDBT');
      expect(dtp[length], '25ft');
    });

    test('a room cabled but not yet drawn still counts', () {
      // The counts come off the signal flow, so the sheet somebody orders from
      // does not wait for anybody to lay out a drawing.
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Undrawn'},
        };
      p.loadAvFlowForCurrentConfig();
      p.addAvNode(device('A', ''));
      p.addAvNode(device('B', ''));
      p.addAvCable(
        fromNodeId: 'A',
        fromPortId: 'p1',
        toNodeId: 'B',
        toPortId: 'p1',
        signal: SignalType.network,
      );
      final titles = cablingSections(buildAvFlowModel(p)).map((s) => s.title);
      expect(titles, contains('Cable Counts by Type and Length'));
      // Nothing was drawn, so there are no runs or boxes to tabulate.
      expect(titles, isNot(contains('Cabling Runs')));
    });
  });

  group('lengths', () {
    test('one call sets every run, and only the ones that need it', () {
      final p = room(runs: 3);
      expect(p.setAllAvCableLengths(15), 3);
      expect(p.avCables.every((c) => c.lengthFt == 15), isTrue);
      // Already there: nothing to do, and nothing on the undo stack.
      expect(p.setAllAvCableLengths(15), 0);
    });

    test('a length survives the round trip to disk', () {
      final p = room(runs: 2);
      p.setAvCableLength(p.avCables.first.id, 7);

      final written = p.avCables.first.toJson();
      expect(AvCable.fromJson(written).lengthFt, 7);

      // Unset is written as nothing and read back as nothing, so a room saved
      // before lengths existed does not open as a rack full of 1ft leads.
      final unset = p.avCables.last.toJson();
      expect(unset.containsKey('lengthFt'), isFalse);
      expect(AvCable.fromJson(unset).lengthFt, 0);
    });
  });

  group('in the documents', () {
    test('the AV report carries the schedule', () {
      final p = room();
      final titles = avReportSections(p, buildAvFlowModel(p))
          .map((s) => s.title);
      expect(titles, contains('Cabling Runs'));
      expect(titles, contains('Cable Totals by Type'));
      expect(titles, contains('Cable Counts by Type and Length'));
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
