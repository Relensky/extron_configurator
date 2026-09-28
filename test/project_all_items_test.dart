import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_workbook.dart';
import 'package:extron_configurator/save_actions.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// A priority that buys only projectors, and the master sheet that links to
/// every room's tab.
void main() {
  late Directory dir;
  late AppStateProvider provider;
  late String projectFile;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('all_items_');
    provider = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = Directory.current.path;
    await provider.loadUiSchema();
    await provider.loadKeyMap();
    await provider.loadAvDeviceLibrary();
    provider.newProject(name: 'Refresh');
    provider.addProjectManualRoomList(
      'LANG 300\t2 Projector 1 Cam 1 Mic\tCentral\t31671\n'
      '\n'
      'HOLT 171\t2 Projector\tCentral\t5000\n'
      '\n'
      'YOLO 999\tDept\t5000',
      groupsArePriorities: true,
    );
    projectFile = path.join(dir.path, 'Refresh_project.json');
    expect(await provider.saveProject(to: projectFile), isEmpty);
    final lines = provider.project.manualRooms.take(2).toList();
    final built = await buildLineItemRooms(provider, lines, dir.path);
    expect(built.built, ['LANG 300', 'HOLT 171']);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  ProjectEstimate price() => computeProjectEstimate(
    project: provider.project,
    projectPath: projectFile,
    library: provider.avDeviceLibrary,
  );

  ProjectRoomCost room(ProjectEstimate e, String name) =>
      e.rooms.firstWhere((r) => r.name == name);

  group('a priority that buys only projectors', () {
    test('only the projectors are on the job; the rest stays as existing',
        () {
      final full = room(price(), 'HOLT 171').estimate!;
      provider.setPriorityBuysOnly(2, ['Projector']);
      final holt = room(price(), 'HOLT 171').estimate!;

      expect(holt.equipment, isNotEmpty);
      expect(holt.equipment.every((l) => l.category == 'Projector'), isTrue);
      expect(holt.equipment.every((l) => l.total > 0), isTrue);
      expect(holt.hardware, isEmpty);
      expect(holt.cabling, isEmpty);
      expect(holt.extras, isEmpty);
      // Counted and said, not silently dropped.
      expect(holt.excludedLines, greaterThan(0));
      expect(
        holt.excludedLines,
        full.equipment.length +
            full.hardware.length +
            full.cabling.length +
            full.extras.length -
            holt.equipment.length,
      );
    });

    test('the room on its own still lists everything', () {
      provider.setPriorityBuysOnly(2, ['Projector']);
      final loaded = readRoomFromDisk(
        path.join(dir.path, 'HOLT_171_config.json'),
      );
      final own = computeRoomCost(
        model: loaded.model,
        library: provider.avDeviceLibrary,
        settings: loaded.settings,
      );
      expect(own.equipment.any((l) => l.category != 'Projector'), isTrue);
    });

    test('rooms at other priorities buy everything', () {
      final before = room(price(), 'LANG 300').total;
      provider.setPriorityBuysOnly(2, ['Projector']);
      expect(room(price(), 'LANG 300').total, before);
    });

    test('the room file itself is not changed', () {
      final cost = File(path.join(dir.path, 'HOLT_171_config_cost.json'));
      final before = cost.readAsStringSync();
      provider.setPriorityBuysOnly(2, ['Projector']);
      price();
      expect(cost.readAsStringSync(), before);
    });

    test('it is saved with the project', () {
      provider.setPriorityBuysOnly(2, ['Projector']);
      final back = BuildingProject.fromJson(provider.project.toJson());
      expect(back.buysOnlyFor(2), ['Projector']);
      expect(back.buysOnlyFor(1), isEmpty);
    });

    test('clearing it buys everything again', () {
      final full = room(price(), 'HOLT 171').total;
      provider.setPriorityBuysOnly(2, ['Projector']);
      expect(room(price(), 'HOLT 171').total, lessThan(full));
      provider.setPriorityBuysOnly(2, []);
      expect(room(price(), 'HOLT 171').total, full);
    });
  });

  group('the all-items sheet', () {
    test('lists every line with its room linked to that room\'s tab', () {
      provider.setPriorityBuysOnly(2, ['Projector']);
      final estimate = price();
      final sections = allItemsSections(
        estimate,
        roomTabs: {for (final r in estimate.rooms) r.ref.id: r.name},
      );
      final items = sections.first.rows;
      final holtRows = items
          .where((r) => r[1] is XlsxLink && r[1].text == 'HOLT 171');
      expect(holtRows, isNotEmpty);
      expect((holtRows.first[1] as XlsxLink).sheet, 'HOLT 171');
      // Only what the priority replaces is on the master list.
      expect(holtRows.every((r) => r[3] == 'Equipment'), isTrue);
      expect(holtRows.map((r) => r[4]).toSet(), {'PT-VMZ62BU8'});

      final totals = sections.last.rows;
      expect(totals.any((r) => '${r.first}'.startsWith('YOLO 999')), isTrue);
      expect(totals.last.first, 'Total');
    });

    test('the workbook links the master to each tab and back', () {
      final bytes = buildProjectWorkbookBytes(estimate: price());
      final archive = ZipDecoder().decodeBytes(bytes);
      String file(String name) =>
          utf8.decode(archive.findFile(name)!.content as List<int>);

      final book = file('xl/workbook.xml');
      final names = RegExp(r'<sheet name="([^"]+)"')
          .allMatches(book)
          .map((m) => m.group(1))
          .toList();
      expect(names.take(2), ['Summary', kProjectAllItemsSheet]);
      expect(names, containsAll(['LANG 300', 'HOLT 171']));

      final master = file('xl/worksheets/sheet2.xml');
      expect(master, contains('<hyperlinks>'));
      expect(master, contains("location=\"'HOLT 171'!A1\""));
      // The items stay in the grid rather than lifted onto lines of their own.
      expect(master, isNot(contains('Item:  ')));

      final holt = file('xl/worksheets/sheet${names.indexOf('HOLT 171') + 1}'
          '.xml');
      expect(
        holt,
        contains("location=\"'$kProjectAllItemsSheet'!A1\""),
      );
    });
  });
}
