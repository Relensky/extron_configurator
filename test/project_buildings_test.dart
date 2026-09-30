import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/save_actions.dart';

/// A job across several buildings, and rooms pasted in as line items.
void main() {
  const pasted = '''
ARTS 111
ARTS 112
AYRS 106
HOLT 170


GLNN 104
THMA 131


PAC 134

ARTS 306A
AJH 125A
ARTS 111
''';

  group('buildings', () {
    test('a typed line splits on commas, drops blanks and repeats', () {
      expect(splitBuildingList(' ARTS, holt ,, arts '), ['ARTS', 'holt']);
    });

    test('several buildings round-trip, and read as one line', () {
      final project = BuildingProject(building: 'ARTS, HOLT, PAC');
      expect(project.buildings, ['ARTS', 'HOLT', 'PAC']);
      final back = BuildingProject.fromJson(project.toJson());
      expect(back.buildings, ['ARTS', 'HOLT', 'PAC']);
      expect(back.building, 'ARTS, HOLT, PAC');
    });

    test('an old file keeps its one building whole, comma and all', () {
      final back = BuildingProject.fromJson({
        'name': 'Old job',
        'building': 'Science, North',
        'rooms': [],
      });
      expect(back.buildings, ['Science, North']);
    });

    test('the clone carries its own list', () {
      final project = BuildingProject(building: 'ARTS');
      final copy = project.clone();
      copy.buildings.add('HOLT');
      expect(project.buildings, ['ARTS']);
    });
  });

  group('a pasted room list', () {
    test('one name per line, blanks and repeats dropped', () {
      expect(parseRoomList(pasted), [
        'ARTS 111',
        'ARTS 112',
        'AYRS 106',
        'HOLT 170',
        'GLNN 104',
        'THMA 131',
        'PAC 134',
        'ARTS 306A',
        'AJH 125A',
      ]);
    });

    test('the building code comes off the front of the name', () {
      expect(buildingCodeOfRoom('ARTS 306A'), 'ARTS');
      expect(buildingCodeOfRoom('ajh 125B'), 'AJH');
      expect(buildingCodeOfRoom('Ground floor teaching lab'), '');
    });

    test('becomes line items, and its buildings join the job', () {
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.newProject(name: 'Fall refresh', building: 'ARTS');

      final result = provider.addProjectManualRoomList(pasted);

      expect(result.added, 9);
      expect(result.skipped, isEmpty);
      expect(provider.project.manualRooms.map((r) => r.name).toList(), [
        'ARTS 111',
        'ARTS 112',
        'AYRS 106',
        'HOLT 170',
        'GLNN 104',
        'THMA 131',
        'PAC 134',
        'ARTS 306A',
        'AJH 125A',
      ]);
      expect(provider.project.buildings, [
        'ARTS',
        'AYRS',
        'HOLT',
        'GLNN',
        'THMA',
        'PAC',
        'AJH',
      ]);
      expect(provider.projectDirty, isTrue);
    });

    test('pasting again skips the rooms already on the job', () {
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.newProject(name: 'Fall refresh');
      provider.addProjectManualRoomList(pasted);

      final again = provider.addProjectManualRoomList('arts 111\nYOLO 217');

      expect(again.added, 1);
      expect(again.skipped, ['arts 111']);
      expect(provider.project.manualRooms.last.name, 'YOLO 217');
      expect(provider.project.buildings.last, 'YOLO');
    });
  });

  group('priorities and funding', () {
    const sheet = 'ARTS 111\t4 projector 1 Cam 1 Mic\tCentral\t\$37,869\n'
        'PAC 144\t1 Projector 1 Cam\tDept\t\$25,487.50\n'
        '\n'
        'GLNN 104\t1 Proj 1 Cam 1 Mic\tDept\t26135\n'
        '\n\n'
        'AJH 125A\t1 Projector\tCentral\t\$5,000.00\n';

    test('columns are read by what they look like, groups by blank lines', () {
      final rows = parseRoomRows(sheet);
      expect(rows.map((r) => r.group), [1, 1, 2, 3]);
      expect(rows.first.roomType, '4 projector 1 Cam 1 Mic');
      expect(rows.first.funding, 'Central');
      expect(rows.first.targetPrice, 37869);
      expect(rows[1].targetPrice, 25487.5);
      expect(rows[2].targetPrice, 26135);
    });

    AppStateProvider fundedJob() {
      final provider = AppStateProvider(autoLoadSettings: false);
      provider.newProject(name: '600k refresh');
      provider.setProjectBudget(100000);
      provider.setProjectBudgetLocked(true);
      provider.addProjectManualRoomList(sheet, groupsArePriorities: true);
      return provider;
    }

    test('a pasted sheet becomes prioritized, funded line items', () {
      final provider = fundedJob();
      final lines = provider.project.manualRooms;
      expect(lines.map((r) => r.priority), [1, 1, 2, 3]);
      expect(lines.map((r) => r.funding), ['Central', 'Dept', 'Dept', 'Central']);
      expect(lines.first.sourceType, '4 projector 1 Cam 1 Mic');
      expect(provider.project.targetTotal, closeTo(94491.5, 0.001));
    });

    test('a paste after the last priority carries on numbering', () {
      final provider = fundedJob();
      provider.addProjectManualRoomList('YOLO 217', groupsArePriorities: true);
      expect(provider.project.manualRooms.last.priority, 4);
    });

    test('a target that would pass the maximum is refused', () {
      final provider = fundedJob();
      final glnn = provider.project.manualRooms[2];
      final error = provider.setRoomFunding(
        manualId: glnn.id,
        targetPrice: 40000,
      );
      expect(error, contains('over the budget'));
      expect(provider.project.manualRooms[2].targetPrice, 26135);
    });

    test('money moves between rooms inside the maximum', () {
      final provider = fundedJob();
      final lines = provider.project.manualRooms;
      expect(
        provider.setRoomFunding(manualId: lines[0].id, targetPrice: 27869),
        isEmpty,
      );
      expect(
        provider.setRoomFunding(manualId: lines[2].id, targetPrice: 36135),
        isEmpty,
      );
      expect(provider.project.targetTotal, closeTo(94491.5, 0.001));
    });

    test('a paste whose targets pass the maximum leaves those unset', () {
      final provider = fundedJob();
      final result = provider.addProjectManualRoomList(
        'YOLO 218\t\$9,000',
      );
      expect(result.overBudget, ['YOLO 218']);
      expect(provider.project.manualRooms.last.targetPrice, 0);
    });

    test('the locked maximum does not change until it is unlocked', () {
      final provider = fundedJob();
      provider.setProjectBudget(250000);
      expect(provider.project.budget, 100000);
      provider.setProjectBudgetLocked(false);
      provider.setProjectBudget(250000);
      expect(provider.project.budget, 250000);
    });

    test('everything round-trips through the project file', () {
      final provider = fundedJob();
      final back = BuildingProject.fromJson(provider.project.toJson());
      expect(back.budgetLocked, isTrue);
      expect(back.manualRooms.first.priority, 1);
      expect(back.manualRooms.first.roomType, '4 projector 1 Cam 1 Mic');
      expect(back.manualRooms.first.funding, 'Central');
      expect(back.manualRooms.first.targetPrice, 37869);
    });

    test('a line swapped for its room keeps its priority and money', () {
      final provider = fundedJob();
      final dir = Directory.systemTemp.createTempSync('funding_swap_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(path.join(dir.path, 'ARTS_111_config.json'))
        ..writeAsStringSync('{"SYSTEM_SETUP": {}}');
      final line = provider.project.manualRooms.first;

      expect(provider.swapManualRoomForConfig(line.id, file.path), isEmpty);

      final room = provider.project.rooms.single;
      expect(room.priority, 1);
      expect(room.funding, 'Central');
      expect(room.targetPrice, 37869);
      expect(provider.project.targetTotal, closeTo(94491.5, 0.001));
    });
  });

  group('building the line items into rooms', () {
    test('each line becomes a room file from its preset', () async {
      final dir = Directory.systemTemp.createTempSync('build_lines_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final provider = AppStateProvider(autoLoadSettings: false)
        ..rootFolderPath = Directory.current.path;
      await provider.loadUiSchema();
      await provider.loadKeyMap();
      await provider.loadAvDeviceLibrary();
      provider.newProject(name: 'Build test');
      provider.addProjectManualRoomList(
        'HOLT 170\t1 Projector\n'
        'LANG 300\t2 Projector 1 Cam 1 Mic\n'
        'PAC 999\tNo such type\n'
        'SCI 1',
      );

      final result = await buildLineItemRooms(
        provider,
        List.of(provider.project.manualRooms),
        dir.path,
      );

      expect(result.built, ['HOLT 170', 'LANG 300']);
      expect(result.noRoomType, ['PAC 999', 'SCI 1']);
      expect(provider.project.manualRooms.map((r) => r.name),
          ['PAC 999', 'SCI 1']);
      expect(provider.project.rooms, hasLength(2));
      expect(File(path.join(dir.path, 'HOLT_170', 'config.json')).existsSync(),
          isTrue);
      expect(provider.avNodes, isNotEmpty);
    });
  });

  group('adding and removing by priority', () {
    AppStateProvider job() {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Refresh');
      p.addProjectManualRoomList(
        'ARTS 111\nARTS 112\n\nGLNN 104',
        groupsArePriorities: true,
      );
      return p;
    }

    test('rooms go into an existing priority, whatever the blank lines say',
        () {
      final p = job();
      expect(p.projectHighestPriority, 2);
      p.addProjectManualRoomList('HOLT 170\n\nHOLT 171', priority: 1);
      final byName = {for (final r in p.project.manualRooms) r.name: r};
      expect(byName['HOLT 170']!.priority, 1);
      expect(byName['HOLT 171']!.priority, 1);
      expect(p.projectHighestPriority, 2);
    });

    test('and into a new one', () {
      final p = job();
      p.addProjectManualRoomList('PAC 134', priority: 3);
      expect(p.project.manualRooms.last.priority, 3);
      expect(p.projectHighestPriority, 3);
    });

    test('taking a room out of a priority leaves it on the job', () {
      final p = job();
      final glnn = p.project.manualRooms.last;
      expect(p.setRoomFunding(manualId: glnn.id, priority: 0), isEmpty);
      expect(p.project.manualRooms.last.priority, 0);
      expect(p.projectHighestPriority, 1);
    });

    test('a drawn room taken off the job comes back with Undo', () {
      final p = job();
      final dir = Directory.systemTemp.createTempSync('priority_undo_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(path.join(dir.path, 'ARTS_111_config.json'))
        ..writeAsStringSync('{"SYSTEM_SETUP": {}}');
      p.swapManualRoomForConfig(p.project.manualRooms.first.id, file.path);
      final id = p.project.rooms.single.id;
      // Two separate edits, as two clicks seconds apart are.
      p.recordUndoPoint();

      p.removeRoomFromProject(id);
      expect(p.project.rooms, isEmpty);
      p.undoProject();
      expect(p.project.rooms.map((r) => r.id), [id]);
      expect(p.project.rooms.single.priority, 1);
    });
  });
}
