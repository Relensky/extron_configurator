import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/equipment_lifecycle.dart';

/// ============================================================================
///  THE PLAN AS LINE ITEMS
/// ============================================================================
///  A building can be on the refresh plan without one room having been drawn:
///  the RYG imports are exactly that. Those jobs were readable and not
///  editable: the plan drew them, the totals counted them, and the only way to
///  correct a date was a dialog on the campus sheet, a screen up and one
///  building sideways from where the wrong date was being read.
///
///  What is held here: that a row with no config file behind it says so, that
///  its date, its years in service and its cost are edited on the open job and
///  written by the job's own Save, and that swapping the real room in is ONE
///  action — because doing it as two is how a room ends up on its building's
///  plan twice, at a figure that looks entirely plausible.
/// ============================================================================
void main() {
  final asOf = DateTime(2026, 6, 15);

  group('a row knows whether it came from a config file', () {
    test('a typed room carries its own id, so it can be edited in place', () {
      final row = buildManualRoomLifecycle(
        room: ManualRoom(
          id: 'manual3',
          name: 'AGYM 129',
          installedOn: DateTime(2015, 7, 1),
          replacementCost: 24434.6,
        ),
        asOf: asOf,
      );
      expect(row.manualRoomId, 'manual3');
    });

    test('a drawn room carries none, and is edited where its dates are', () {
      final row = buildRoomLifecycle(
        model: const AvFlowModel(
          nodes: [],
          cables: [],
          racks: [],
          rackSlots: {},
          canvasSize: Size.zero,
          roomTitle: 'BSS 214',
          unplaced: [],
        ),
        roomName: 'BSS 214',
        asOf: asOf,
      );
      expect(row.manualRoomId, isEmpty);
    });
  });

  group('editing a line item on the open job', () {
    late AppStateProvider provider;

    setUp(() {
      provider = AppStateProvider(autoLoadSettings: false);
      provider.newProject(name: 'Acker Gymnasium refresh', building: 'AGYM');
    });

    ManualRoom seed() => provider.addProjectManualRoom(
      name: 'AGYM 129',
      installedOn: DateTime(2015, 7, 1),
      lifeYears: 8,
      replacementCost: 24434.6,
    );

    test('the date, the years in service and the cost all move', () {
      final line = seed();
      provider.updateProjectManualRoom(
        line.copyWith(
          installedOn: DateTime(2018, 7, 1),
          lifeYears: 12,
          replacementCost: 31000,
        ),
      );

      final after = provider.project.manualRooms.single;
      expect(after.id, line.id, reason: 'the same line, not a second one');
      expect(after.installedOn, DateTime(2018, 7, 1));
      expect(after.lifeYears, 12);
      expect(after.replacementCost, 31000);
      expect(provider.projectDirty, isTrue);
    });

    test('the plan re-ages off the edited figures', () {
      final line = seed();
      var plan = buildProjectLifecycle(
        estimate: provider.priceProject(),
        asOf: asOf,
      );
      expect(plan.rooms.single.firstDueYear, 2023);

      provider.updateProjectManualRoom(line.copyWith(lifeYears: 15));
      plan = buildProjectLifecycle(
        estimate: provider.priceProject(),
        asOf: asOf,
      );
      expect(plan.rooms.single.firstDueYear, 2030);
    });

    test('what moved is what the history says moved', () {
      final line = seed();
      provider.updateProjectManualRoom(line.copyWith(replacementCost: 31000));
      expect(
        provider.project.history.map((h) => h.field),
        contains('Cost to do again'),
      );
      expect(
        provider.project.history.map((h) => h.field),
        isNot(contains('Years in service')),
        reason: 'nothing else changed',
      );
    });

    test('a removed line comes back with its id, for the undo', () {
      final line = seed();
      final second = provider.addProjectManualRoom(name: 'AGYM 202');
      final at = provider.projectManualRoomIndex(line.id);

      final removed = provider.removeProjectManualRoom(line.id);
      expect(removed, isNotNull);
      expect(provider.project.manualRooms.map((r) => r.id), [second.id]);

      provider.restoreProjectManualRoom(removed!, at: at);
      expect(provider.project.manualRooms.map((r) => r.id), [
        line.id,
        second.id,
      ]);
      expect(provider.project.manualRooms.first.replacementCost, 24434.6);
    });

    test('restoring twice does not put the line on the plan twice', () {
      final line = seed();
      final removed = provider.removeProjectManualRoom(line.id)!;
      provider.restoreProjectManualRoom(removed);
      provider.restoreProjectManualRoom(removed);
      expect(provider.project.manualRooms, hasLength(1));
    });
  });

  group('substituting the real room', () {
    late Directory dir;
    late AppStateProvider provider;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('rcb_lines');
      provider = AppStateProvider(autoLoadSettings: false);
      provider.newProject(name: 'Acker Gymnasium refresh', building: 'AGYM');
    });
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    String config(String stem) {
      final file = path.join(dir.path, '$stem.json');
      File(file).writeAsStringSync(jsonEncode({'roomName': stem}));
      return file;
    }

    test('the room goes on under the line name, and the line goes off', () {
      final line = provider.addProjectManualRoom(
        name: 'AGYM 129',
        installedOn: DateTime(2015, 7, 1),
        replacementCost: 24434.6,
      );
      final file = config('acker_129_config');

      expect(provider.swapManualRoomForConfig(line.id, file), isEmpty);
      expect(provider.project.manualRooms, isEmpty);
      expect(provider.project.rooms, hasLength(1));
      // The code on the door, not the file stem: the plan is read by room
      // number and a config is as likely to be called 'copy of lecture hall'.
      expect(provider.project.rooms.single.label, 'AGYM 129');
    });

    test('a swap that fails leaves the estimate on the plan', () {
      final line = provider.addProjectManualRoom(name: 'AGYM 129');
      final missing = path.join(dir.path, 'nothing_here.json');

      final error = provider.swapManualRoomForConfig(line.id, missing);
      expect(error, isNotEmpty);
      // The line is the ONLY record of that room. Losing it to a failed swap
      // would take the room off the building's budget altogether.
      expect(provider.project.manualRooms.single.id, line.id);
      expect(provider.project.rooms, isEmpty);
    });

    test('the room is never counted twice', () {
      final line = provider.addProjectManualRoom(name: 'AGYM 129');
      final file = config('acker_129_config');
      provider.swapManualRoomForConfig(line.id, file);

      // Same room, offered again: refused, and the plan is left as it is.
      final second = provider.addProjectManualRoom(name: 'AGYM 129 again');
      expect(
        provider.swapManualRoomForConfig(second.id, file),
        contains('already on this project'),
      );
      expect(provider.project.rooms, hasLength(1));
      expect(provider.project.manualRooms.single.id, second.id);
    });
  });

  test('line items survive the trip to disk with the job', () async {
    final dir = Directory.systemTemp.createTempSync('rcb_lines_io');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    final provider = AppStateProvider(autoLoadSettings: false);
    provider.newProject(name: 'Acker Gymnasium refresh');
    provider.addProjectManualRoom(
      name: 'AGYM 129',
      installedOn: DateTime(2015, 7, 1),
      lifeYears: 8,
      replacementCost: 24434.6,
    );

    final file = path.join(dir.path, 'AGYM_project.json');
    expect(await provider.saveProject(to: file), isEmpty);

    final back = await BuildingProject.load(file);
    expect(back.manualRooms.single.name, 'AGYM 129');
    expect(back.manualRooms.single.lifeYears, 8);
    expect(back.manualRooms.single.replacementCost, 24434.6);
  });
}
