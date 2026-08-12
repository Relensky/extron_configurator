import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_report.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/report_tools.dart';
import 'package:extron_configurator/room_locations.dart';
// Offset comes in via av_flow_model's material export; Size does not.
import 'package:flutter/painting.dart' show Size;

/// Where things are in the room, and the counts that get ordered against it:
/// jacks per location, cable runs per location per signal type, and the
/// source/destination each run actually goes between.
void main() {
  AvPort port(String id, String label, SignalType s, PortDirection d) => AvPort(
    id: id,
    label: label,
    signal: s,
    direction: d,
    side: d == PortDirection.output ? PortSide.right : PortSide.left,
  );

  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  ReportSection sectionNamed(List<ReportSection> all, String title) =>
      all.firstWhere((s) => s.title == title);

  Object? cell(ReportSection s, List<dynamic> row, String column) =>
      row[s.header.indexOf(column)];

  /// A room with a floor box and a rack, one HDMI and two network runs
  /// between them, so the per-location counts have something to count.
  ({AppStateProvider provider, String floorBox, String rack}) wiredRoom() {
    final p = room();
    final floorBox = p.addAvLocation(
      const RoomLocation(
        id: '',
        name: 'Front floor box',
        zone: RoomZone.floor,
        callout: 'B',
      ),
    );
    final rackLocation = p.addAvLocation(
      const RoomLocation(
        id: '',
        name: 'Equipment rack',
        zone: RoomZone.rack,
        callout: 'E',
      ),
    );

    p.addAvNode(
      AvNode(
        id: 'FB',
        label: 'Floor box',
        model: '3-jack field',
        pos: Offset.zero,
        kind: AvNodeKind.jackField,
        powerSource: PowerSource.none,
        locationId: floorBox.id,
        ports: [
          port('jack_1', '110001', SignalType.hdmi,
              PortDirection.bidirectional),
          port('jack_2', '110002', SignalType.network,
              PortDirection.bidirectional),
          port('jack_3', '110003', SignalType.network,
              PortDirection.bidirectional),
        ],
      ),
    );
    p.addAvNode(
      AvNode(
        id: 'SW',
        label: 'Switcher',
        model: 'Switcher Y',
        pos: const Offset(400, 0),
        locationId: rackLocation.id,
        ports: [
          port('in_hdmi_1', 'HDMI 1', SignalType.hdmi, PortDirection.input),
          port('io_lan_1', 'LAN', SignalType.network,
              PortDirection.bidirectional),
          port('io_lan_2', 'LAN 2', SignalType.network,
              PortDirection.bidirectional),
        ],
      ),
    );

    p.addAvCable(
      fromNodeId: 'FB',
      fromPortId: 'jack_1',
      toNodeId: 'SW',
      toPortId: 'in_hdmi_1',
      signal: SignalType.hdmi,
      label: 'AV-01',
    );
    p.addAvCable(
      fromNodeId: 'FB',
      fromPortId: 'jack_2',
      toNodeId: 'SW',
      toPortId: 'io_lan_1',
      signal: SignalType.network,
      label: 'NET-01',
    );
    p.addAvCable(
      fromNodeId: 'FB',
      fromPortId: 'jack_3',
      toNodeId: 'SW',
      toPortId: 'io_lan_2',
      signal: SignalType.network,
      label: 'NET-02',
    );

    return (provider: p, floorBox: floorBox.id, rack: rackLocation.id);
  }

  group('the cable schedule', () {
    test('names the source and the destination, and where each one is', () {
      final r = wiredRoom();
      final model = buildAvFlowModel(r.provider);
      final schedule = sectionNamed(
        avReportSections(r.provider, model),
        'Cable Schedule',
      );

      final hdmi = schedule.rows.firstWhere(
        (row) => cell(schedule, row, 'Label') == 'AV-01',
      );
      expect(cell(schedule, hdmi, 'Source device'), 'Floor box');
      expect(cell(schedule, hdmi, 'Source port'), '110001');
      expect(cell(schedule, hdmi, 'Source location'), '[B] Front floor box');
      expect(cell(schedule, hdmi, 'Destination device'), 'Switcher');
      expect(cell(schedule, hdmi, 'Destination port'), 'HDMI 1');
      expect(
        cell(schedule, hdmi, 'Destination location'),
        '[E] Equipment rack',
      );
    });

    test('leaves the location blank rather than guessing at it', () {
      final p = room();
      p.addAvNode(
        AvNode(
          id: 'A',
          label: 'A',
          model: '',
          pos: Offset.zero,
          ports: [port('out_1', 'OUT', SignalType.hdmi, PortDirection.output)],
        ),
      );
      p.addAvNode(
        AvNode(
          id: 'B',
          label: 'B',
          model: '',
          pos: const Offset(300, 0),
          ports: [port('in_1', 'IN', SignalType.hdmi, PortDirection.input)],
        ),
      );
      p.addAvCable(
        fromNodeId: 'A',
        fromPortId: 'out_1',
        toNodeId: 'B',
        toPortId: 'in_1',
        signal: SignalType.hdmi,
      );

      final schedule = sectionNamed(
        avReportSections(p, buildAvFlowModel(p)),
        'Cable Schedule',
      );
      expect(cell(schedule, schedule.rows.single, 'Source location'), '');
    });
  });

  group('per-location counts', () {
    test('jacks are counted per location and split by signal', () {
      final r = wiredRoom();
      final counts = sectionNamed(
        avReportSections(r.provider, buildAvFlowModel(r.provider)),
        'Jack Counts by Location',
      );

      final row = counts.rows.firstWhere(
        (r) => r.first.toString().contains('Front floor box'),
      );
      expect(cell(counts, row, 'Jacks'), 3);
      expect(cell(counts, row, 'Patched'), 3);
      expect(cell(counts, row, 'Spare'), 0);
      expect(cell(counts, row, 'By signal').toString(), contains('NET ×2'));
      expect(cell(counts, row, 'By signal').toString(), contains('HDMI ×1'));
    });

    test('a run counts at both ends when they are in different places', () {
      final r = wiredRoom();
      final counts = sectionNamed(
        avReportSections(r.provider, buildAvFlowModel(r.provider)),
        'Line Counts by Location',
      );

      final box = counts.rows.firstWhere(
        (row) => row.first.toString().contains('Front floor box'),
      );
      final rack = counts.rows.firstWhere(
        (row) => row.first.toString().contains('Equipment rack'),
      );
      // Three runs, both ends of each in a different location.
      expect(cell(counts, box, 'Total ends'), 3);
      expect(cell(counts, rack, 'Total ends'), 3);
      expect(cell(counts, box, 'NET'), 2);
      expect(cell(counts, box, 'HDMI'), 1);
    });

    test('a run with both ends in one place counts there once', () {
      final p = room();
      final rack = p.addAvLocation(
        const RoomLocation(id: '', name: 'Rack', zone: RoomZone.rack),
      );
      for (final id in ['A', 'B']) {
        p.addAvNode(
          AvNode(
            id: id,
            label: id,
            model: '',
            pos: Offset.zero,
            locationId: rack.id,
            ports: [
              port('out_1', 'OUT', SignalType.hdmi, PortDirection.output),
              port('in_1', 'IN', SignalType.hdmi, PortDirection.input),
            ],
          ),
        );
      }
      p.addAvCable(
        fromNodeId: 'A',
        fromPortId: 'out_1',
        toNodeId: 'B',
        toPortId: 'in_1',
        signal: SignalType.hdmi,
      );

      final counts = sectionNamed(
        avReportSections(p, buildAvFlowModel(p)),
        'Line Counts by Location',
      );
      expect(cell(counts, counts.rows.single, 'Total ends'), 1);
    });

    test('the on-screen strip agrees with the report', () {
      final r = wiredRoom();
      final model = buildAvFlowModel(r.provider);
      final strip = countLinesByLocation(model);
      final report = sectionNamed(
        avReportSections(r.provider, model),
        'Line Counts by Location',
      );

      for (final tally in strip) {
        final row = report.rows.firstWhere(
          (row) => row.first.toString() == tally.name,
        );
        expect(
          cell(report, row, 'Total ends'),
          tally.lines,
          reason: '${tally.name}: the strip and the report must not disagree',
        );
      }
    });
  });

  group('line counts by label', () {
    test('groups labels by their stem and counts the runs', () {
      final r = wiredRoom();
      final counts = sectionNamed(
        avReportSections(r.provider, buildAvFlowModel(r.provider)),
        'Line Counts by Label',
      );

      final net = counts.rows.firstWhere((row) => row.first == 'NET-');
      expect(cell(counts, net, 'Runs'), 2);
      // One label per line — the cell is a list somebody reads down, and the
      // .xlsx writes it wrapped rather than running them together.
      expect(cell(counts, net, 'Labels'), 'NET-01\nNET-02');

      final av = counts.rows.firstWhere((row) => row.first == 'AV-');
      expect(cell(counts, av, 'Runs'), 1);
    });

    test('unlabeled runs are counted and named as such', () {
      final p = room();
      p.addAvNode(
        AvNode(
          id: 'A',
          label: 'A',
          model: '',
          pos: Offset.zero,
          ports: [port('out_1', 'OUT', SignalType.hdmi, PortDirection.output)],
        ),
      );
      p.addAvNode(
        AvNode(
          id: 'B',
          label: 'B',
          model: '',
          pos: const Offset(300, 0),
          ports: [port('in_1', 'IN', SignalType.hdmi, PortDirection.input)],
        ),
      );
      p.addAvCable(
        fromNodeId: 'A',
        fromPortId: 'out_1',
        toNodeId: 'B',
        toPortId: 'in_1',
        signal: SignalType.hdmi,
      );

      final counts = sectionNamed(
        avReportSections(p, buildAvFlowModel(p)),
        'Line Counts by Label',
      );
      expect(counts.rows.single.first, '(no label)');
      expect(cell(counts, counts.rows.single, 'Runs'), 1);
    });

    test('the stem stops before the number', () {
      expect(cableLabelStem('AV-01'), 'AV-');
      expect(cableLabelStem('NET12'), 'NET');
      expect(cableLabelStem('HDMI-04 '), 'HDMI-');
      // Nothing but digits has no stem to take, so it groups under itself
      // rather than under the empty string.
      expect(cableLabelStem('12'), '12');
    });
  });

  group('screen and shade control runs', () {
    test('the report carries the start and the end of each run', () {
      final r = wiredRoom();
      final p = r.provider;
      final wall = p.addAvLocation(
        const RoomLocation(id: '', name: 'Front wall', zone: RoomZone.wall),
      );
      p.addAvScreenSwitch(
        ScreenSwitch(
          id: '',
          label: 'Front screen',
          startLocationId: r.floorBox,
          endLocationId: wall.id,
          cableType: '18/2 plenum',
          runFeet: 40,
        ),
      );

      final runs = sectionNamed(
        avReportSections(p, buildAvFlowModel(p)),
        'Screen / Shade Control Runs',
      );
      final row = runs.rows.single;
      expect(cell(runs, row, 'Controls'), 'Front screen');
      expect(cell(runs, row, 'Start (switch)'), '[B] Front floor box');
      expect(cell(runs, row, 'End (motor / screen)'), 'Front wall');
      expect(cell(runs, row, 'Cable'), '18/2 plenum');
      expect(cell(runs, row, 'Run (ft)'), 40);
    });

    test('an end with no location falls back to its description', () {
      final p = room();
      p.addAvScreenSwitch(
        const ScreenSwitch(
          id: '',
          label: 'Rear shades',
          startNote: 'By the corridor door',
          endNote: 'Shade tube, rear wall',
        ),
      );
      final runs = sectionNamed(
        avReportSections(p, buildAvFlowModel(p)),
        'Screen / Shade Control Runs',
      );
      expect(
        cell(runs, runs.rows.single, 'Start (switch)'),
        'By the corridor door',
      );
    });
  });

  group('removing a location', () {
    test('unsets it everywhere rather than leaving a dangling id', () {
      final r = wiredRoom();
      final p = r.provider;
      p.addAvScreenSwitch(
        ScreenSwitch(id: '', label: 'Screen', startLocationId: r.floorBox),
      );

      p.removeAvLocation(r.floorBox);

      expect(p.avLocationById(r.floorBox), isNull);
      expect(
        p.avNodes.firstWhere((n) => n.id == 'FB').locationId,
        kNoLocationId,
      );
      expect(p.avScreenSwitches.single.startLocationId, kNoLocationId);
    });
  });

  group('the sidecar', () {
    test('carries locations, control runs and floor plans through a save',
        () async {
      final dir = Directory.systemTemp.createTempSync('room_locations_test_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final configPath = path.join(dir.path, 'BSS103_config.json');
      File(configPath).writeAsStringSync('{}');

      final r = wiredRoom();
      final p = r.provider..currentConfigPath = configPath;
      p.addAvScreenSwitch(
        const ScreenSwitch(id: '', label: 'Front screen', runFeet: 30),
      );
      final plan = p.addAvFloorPlan(
        const FloorPlan(
          id: '',
          name: 'Level 1',
          imageFile: 'plan.png',
          imageSize: Size(2000, 1400),
        ),
      );
      p.addAvCallout(
        plan.id,
        const FloorPlanCallout(
          id: '',
          tag: '1',
          pos: Offset(100, 200),
          target: CalloutTarget.location,
          targetId: 'LOC_1',
          workbookSheet: 'Racks',
          workbookRef: 'Rack Inventory',
        ),
      );
      p.moveAvLocationMarker(plan.id, r.floorBox, const Offset(340, 120));

      expect(await p.saveAvFlow(), isNotEmpty);

      // Read it back the way opening the config does.
      final reopened = AppStateProvider(autoLoadSettings: false)
        ..currentConfigPath = configPath;
      reopened.loadAvFlowForCurrentConfig();

      expect(reopened.avLocations.length, 2);
      // The marker rides on the SHEET it was dropped on.
      expect(
        reopened.avFloorPlans.single.markerFor(r.floorBox),
        const Offset(340, 120),
      );
      expect(reopened.avScreenSwitches.single.runFeet, 30);
      expect(reopened.avFloorPlans.single.name, 'Level 1');
      expect(reopened.avFloorPlans.single.imageSize, const Size(2000, 1400));
      final callout = reopened.avFloorPlans.single.callouts.single;
      expect(callout.tag, '1');
      expect(callout.workbookSheet, 'Racks');
      expect(callout.target, CalloutTarget.location);
      // The node keeps the location it was saved with.
      expect(
        reopened.avNodes.firstWhere((n) => n.id == 'FB').locationId,
        r.floorBox,
      );
    });
  });

  /// A room that starts with the places gear actually lands in is a room where
  /// the location field gets used; one that starts with a blank list is a room
  /// where it stays blank.
  group('the locations a new room starts with', () {
    test('are the places a teaching space always has', () {
      expect(kDefaultRoomLocations.map((d) => d.name), [
        'Equipment rack',
        'Instructor station',
        'Projector box',
        'Projector screen',
        'Ceiling mic',
        'Instructor camera',
        'Audience camera',
        'Speaker 1',
        'Speaker 2',
        'Speaker 3',
        'Speaker 4',
        'Wall switch',
      ]);
      // Distinct callouts, because the plan points at them by letter.
      expect(
        kDefaultRoomLocations.map((d) => d.callout).toSet(),
        hasLength(kDefaultRoomLocations.length),
      );
      // I reads as a 1 beside a numbered marker, so the letters skip it.
      expect(kDefaultRoomLocations.map((d) => d.callout), isNot(contains('I')));
    });

    test('mount the new ones where the work actually happens', () {
      RoomZone zoneOf(String name) =>
          kDefaultRoomLocations.firstWhere((d) => d.name == name).zone;

      // The zone is what changes the work — a wall bracket and a back box for
      // the cameras and the switch plate, a ceiling drop for each speaker.
      expect(zoneOf('Instructor camera'), RoomZone.wall);
      expect(zoneOf('Audience camera'), RoomZone.wall);
      expect(zoneOf('Wall switch'), RoomZone.wall);
      for (var i = 1; i <= 4; i++) {
        expect(zoneOf('Speaker $i'), RoomZone.ceiling);
      }
    });

    test('are seeded once and never on top of a room that has some', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Fresh'},
        };
      p.loadAvFlowForCurrentConfig();

      expect(p.seedDefaultAvLocations(), kDefaultRoomLocations.length);
      expect(p.avLocations.map((l) => l.name).first, 'Equipment rack');
      // Seeding again would double the list.
      expect(p.seedDefaultAvLocations(), 0);
      expect(p.avLocations, hasLength(kDefaultRoomLocations.length));
    });
  });
}
