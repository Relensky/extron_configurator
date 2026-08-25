import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/responsibility_matrix.dart';

/// Whose job each piece of scope is: the document that decides what the trades
/// find when they turn up, so what it counts and what it refuses to guess both
/// matter.
void main() {
  BuildingProject job() {
    final project = BuildingProject(name: 'Bessey refresh', building: 'BSS');
    for (final room in ['BSS 101', 'BSS 103']) {
      project.rooms.add(
        ProjectRoomRef(
          id: project.nextRoomId(),
          configPath: 'C:/rooms/${room.replaceAll(' ', '_')}_config.json',
          label: room,
        ),
      );
    }
    return project;
  }

  group('a line on the matrix', () {
    test('totals the quantities across the rooms', () {
      final project = job();
      final rooms = project.rooms.map((r) => r.id).toList();
      var item = project.addResponsibilityItem('Ceiling speakers');
      item = item.withRoomQty(rooms[0], 12).withRoomQty(rooms[1], 4);
      expect(item.total, 16);
    });

    test('a room with none of it is left off rather than stored as a zero', () {
      final project = job();
      final rooms = project.rooms.map((r) => r.id).toList();
      final item = project
          .addResponsibilityItem('Projection screen')
          .withRoomQty(rooms[0], 2)
          .withRoomQty(rooms[1], 0);
      expect(item.qtyByRoom.keys, [rooms[0]]);
      expect(item.total, 2);
    });

    test('a line with nobody named on it is flagged, not assumed', () {
      final settled = const ResponsibilityItem(
        id: 'resp1',
        scope: 'Screens',
        furnishedBy: 'Owner',
        installedBy: 'Contractor',
      );
      expect(settled.unassigned, isFalse);
      expect(
        const ResponsibilityItem(
          id: 'resp2',
          scope: 'Screens',
          furnishedBy: 'Owner',
        ).unassigned,
        isTrue,
      );
    });

    test('a count reads as a count, without a trailing decimal', () {
      expect(formatResponsibilityQty(12), '12');
      expect(formatResponsibilityQty(2.5), '2.5');
      expect(formatResponsibilityQty(0), '');
    });
  });

  group('the project', () {
    test('hands out an id per line and keeps the order it was given', () {
      final project = job();
      project.addResponsibilityItem('Screens');
      project.addResponsibilityItem('Speakers');
      expect(project.responsibility.map((r) => r.id), ['resp1', 'resp2']);
      expect(project.responsibility.map((r) => r.scope), [
        'Screens',
        'Speakers',
      ]);
    });

    test('a line can be moved up and down the sheet', () {
      final project = job();
      project.addResponsibilityItem('Screens');
      project.addResponsibilityItem('Speakers');
      project.addResponsibilityItem('Cameras');

      project.moveResponsibilityItem('resp3', -1);
      expect(project.responsibility.map((r) => r.scope), [
        'Screens',
        'Cameras',
        'Speakers',
      ]);
      // Off the end is a no-op rather than an error: a first line whose Up
      // button is pressed should stay where it is.
      project.moveResponsibilityItem('resp1', -1);
      expect(project.responsibility.first.scope, 'Screens');
    });

    test('a line added with no scope is named rather than refused', () {
      final project = job();
      final item = project.addResponsibilityItem('   ');
      expect(item.scope, 'Scope item 1');
    });

    test('the starter lines go on once, and top up a half-filled matrix', () {
      final project = job();
      expect(
        project.addStarterResponsibilityItems(),
        kStarterResponsibilityItems.length,
      );
      // Pressed again: nothing to add.
      expect(project.addStarterResponsibilityItems(), 0);

      project.removeResponsibilityItem(project.responsibility.first.id);
      expect(project.addStarterResponsibilityItems(), 1);
    });

    test('the room columns are the project rooms, in project order', () {
      final columns = job().responsibilityRoomColumns();
      expect(columns.map((c) => c.name), ['BSS 101', 'BSS 103']);
    });

    test('the code on the door beats the label and the file name', () {
      final project = BuildingProject(name: 'Bessey refresh');
      // A room nobody labelled: without a code it can only be named after the
      // file it is stored in, which is what the matrix used to print.
      project.rooms.add(
        ProjectRoomRef(
          id: project.nextRoomId(),
          configPath: 'C:/rooms/BSS_101_config.json',
        ),
      );
      // ...and one somebody typed a label onto.
      project.rooms.add(
        ProjectRoomRef(
          id: project.nextRoomId(),
          configPath: 'C:/rooms/BSS_103_config.json',
          label: 'The lecture hall',
        ),
      );

      final bare = project.responsibilityRoomColumns();
      expect(bare.first.name, isNot(contains(' ')),
          reason: 'with nothing else, the file stem is all there is');
      expect(bare.last.name, 'The lecture hall');

      // Given the codes read off the configs, they win over both.
      final coded = project.responsibilityRoomColumns(
        names: {'room1': 'BSS 101', 'room2': 'BSS 103'},
      );
      expect(coded.map((c) => c.name), ['BSS 101', 'BSS 103']);
    });

    test('a room whose config could not be read keeps its old name', () {
      final project = job();
      // Only the first room resolved; the second is on an offline share.
      final columns = project.responsibilityRoomColumns(
        names: {'room1': 'BSS 101A'},
      );
      expect(columns.map((c) => c.name), ['BSS 101A', 'BSS 103']);
    });
  });

  group('the file', () {
    test('carries the matrix through a save and a reload', () {
      final project = job();
      final rooms = project.rooms.map((r) => r.id).toList();
      project.addResponsibilityItem(
        'Ceiling speakers',
        furnishedBy: 'Owner',
        installedBy: 'Contractor',
        neededBy: 'With the rough-in',
        work: 'Install with slack wire and a cross tee.',
        productLink: 'https://example.invalid/sf228',
        notes: 'Tap sizes to confirm',
      );
      project.updateResponsibilityItem(
        project.responsibility.single.withRoomQty(rooms[0], 12),
      );

      final round = BuildingProject.fromJson(
        jsonDecode(jsonEncode(project.toJson())) as Map<String, dynamic>,
      );
      final item = round.responsibility.single;
      expect(item.id, 'resp1');
      expect(item.scope, 'Ceiling speakers');
      expect(item.furnishedBy, 'Owner');
      expect(item.installedBy, 'Contractor');
      expect(item.neededBy, 'With the rough-in');
      expect(item.qtyByRoom[rooms[0]], 12);
      expect(item.work, contains('cross tee'));
      expect(item.productLink, contains('sf228'));
      expect(item.notes, 'Tap sizes to confirm');
      // The counter came back too, so the next line does not reuse an id.
      expect(round.addResponsibilityItem('Cameras').id, 'resp2');
    });

    test('a job with no matrix writes no key for one', () {
      expect(job().toJson().containsKey('responsibility'), isFalse);
    });

    test('a project saved before this existed reads as an empty matrix', () {
      final round = BuildingProject.fromJson({'name': 'Old job'});
      expect(round.responsibility, isEmpty);
    });

    test('a hand-edited line with no scope is dropped', () {
      final round = BuildingProject.fromJson({
        'name': 'Old job',
        'responsibility': [
          {'id': 'resp1', 'scope': 'Screens'},
          {'id': 'resp2', 'scope': '  '},
          {'id': 'resp3'},
        ],
      });
      expect(round.responsibility.map((r) => r.scope), ['Screens']);
    });

    test('a quantity that is not a number is dropped, not read as zero', () {
      final round = BuildingProject.fromJson({
        'name': 'Old job',
        'responsibility': [
          {
            'id': 'resp1',
            'scope': 'Screens',
            'qtyByRoom': {'room1': '2 per room', 'room2': 3},
          },
        ],
      });
      final item = round.responsibility.single;
      expect(item.qtyByRoom.containsKey('room1'), isFalse);
      expect(item.qtyByRoom['room2'], 3);
    });
  });

  group('the sheet', () {
    test('is a row per line, a column per room, and totals both ways', () {
      final project = job();
      final rooms = project.rooms.map((r) => r.id).toList();
      project.addResponsibilityItem(
        'Screens',
        furnishedBy: 'Owner',
        installedBy: 'Contractor',
      );
      project.addResponsibilityItem(
        'Speakers',
        furnishedBy: 'Owner',
        installedBy: 'Contractor',
      );
      project.updateResponsibilityItem(
        project.responsibility[0].withRoomQty(rooms[0], 2),
      );
      project.updateResponsibilityItem(
        project.responsibility[1]
            .withRoomQty(rooms[0], 12)
            .withRoomQty(rooms[1], 4),
      );

      final grid = responsibilityMatrixSections(
        project.responsibility,
        roomNames: project.responsibilityRoomColumns(),
      ).firstWhere((s) => s.title == 'Roles and Responsibilities');

      expect(grid.header, [
        'Scope',
        'Furnished by',
        'Installed by',
        'Equipment needed by',
        'BSS 101',
        'BSS 103',
        'Total',
      ]);
      expect(grid.rows[0], ['Screens', 'Owner', 'Contractor', '', '2', '', '2']);
      expect(grid.rows[1], [
        'Speakers',
        'Owner',
        'Contractor',
        '',
        '12',
        '4',
        '16',
      ]);
      // The bid is checked against the bottom row.
      expect(grid.rows.last, ['Totals', '', '', '', '14', '4', '18']);
    });

    test('the prose is a table of its own', () {
      final project = job();
      project.addResponsibilityItem(
        'Screens',
        furnishedBy: 'Owner',
        installedBy: 'Contractor',
        work: 'Install 120V motorised screens.',
        notes: 'Sizes TBD',
      );
      final work = responsibilityMatrixSections(
        project.responsibility,
        roomNames: project.responsibilityRoomColumns(),
      ).firstWhere((s) => s.title == 'Description of Work');
      expect(work.rows.single, [
        'Screens',
        'Install 120V motorised screens.',
        '',
        '',
        'Sizes TBD',
      ]);
    });

    test('the cutsheet is named as well as linked', () {
      // The name is what somebody holding the printout searches the job folder
      // for; the path is routinely too long to read and useless on paper.
      final project = job();
      final item = project.addResponsibilityItem('Projector');
      project.updateResponsibilityItem(
        item.copyWith(productLink: r'cutsheets\NEC-P525UL.pdf'),
      );
      final work = responsibilityMatrixSections(
        project.responsibility,
        roomNames: project.responsibilityRoomColumns(),
      ).firstWhere((s) => s.title == 'Description of Work');
      expect(work.rows.single[2], 'NEC-P525UL.pdf');
      expect(work.rows.single[3], r'cutsheets\NEC-P525UL.pdf');
    });

    test('a web cutsheet is named by its host', () {
      final project = job();
      final item = project.addResponsibilityItem('Projector');
      project.updateResponsibilityItem(
        item.copyWith(productLink: 'https://www.extron.com/product/dtp3'),
      );
      final work = responsibilityMatrixSections(
        project.responsibility,
        roomNames: project.responsibilityRoomColumns(),
      ).firstWhere((s) => s.title == 'Description of Work');
      expect(work.rows.single[2], 'www.extron.com');
    });

    test('what nobody has claimed gets called out on its own', () {
      final project = job();
      project.addResponsibilityItem('Screens', furnishedBy: 'Owner');
      final sections = responsibilityMatrixSections(
        project.responsibility,
        roomNames: project.responsibilityRoomColumns(),
      );
      final open = sections.firstWhere((s) => s.title == 'Still To Be Agreed');
      expect(open.rows.single, ['Screens', 'Owner', 'NOT AGREED']);
    });

    test('a settled matrix has nothing outstanding to say', () {
      final project = job();
      project.addResponsibilityItem(
        'Screens',
        furnishedBy: 'Owner',
        installedBy: 'Contractor',
      );
      final titles = responsibilityMatrixSections(
        project.responsibility,
        roomNames: project.responsibilityRoomColumns(),
      ).map((s) => s.title);
      expect(titles, isNot(contains('Still To Be Agreed')));
    });

    test('an empty matrix renders nothing at all', () {
      expect(
        responsibilityMatrixSections(const [], roomNames: const []),
        isEmpty,
      );
    });
  });
}
