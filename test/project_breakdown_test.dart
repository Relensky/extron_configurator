import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/labor_rates.dart';
import 'package:extron_configurator/project_breakdown.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_workbook.dart';

/// Buildings and departments: the filter on the project page and the
/// funding card's breakdowns.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_breakdown'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// A room in [building] whose only cost is [hours] of $100 labor.
  String writeRoom(String stem, String building, double hours) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {
        'gui_full_room_name': stem,
        'gve_bldg': building,
        'gve_room': stem,
      },
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({'nodes': []}));
    File(path.join(dir.path, '${stem}_config_cost.json')).writeAsStringSync(
      jsonEncode({
        'cost': RoomCostSettings(
          labor: [LaborLine(id: 'l1', customRate: 100, hours: hours)],
        ).toJson(),
      }),
    );
    return configPath;
  }

  late String projectPath;

  BuildingProject job() {
    projectPath = path.join(dir.path, 'job_project.json');
    final project = BuildingProject(name: 'Campus', building: 'BSS, holt, ARTS')
      ..budget = 10000;
    final rooms = [
      (writeRoom('101', 'bss', 10), 'Physics', 2000.0),
      (writeRoom('102', 'BSS', 5), 'physics', 1000.0),
      (writeRoom('201', 'HOLT', 20), 'Music', 3000.0),
    ];
    for (final (config, dept, target) in rooms) {
      project.rooms.add(ProjectRoomRef(
        id: project.nextRoomId(),
        configPath: BuildingProject.storePath(config, projectPath),
        department: dept,
        targetPrice: target,
      ));
    }
    final line = project.addManualRoom(name: 'HOLT 300');
    project.updateManualRoom(line.copyWith(replacementCost: 500));
    return project;
  }

  ProjectEstimate price(BuildingProject p, {Set<String> hidden = const {}}) =>
      computeProjectEstimate(
        project: p,
        projectPath: projectPath,
        library: AvDeviceLibrary.empty(),
        rates: LaborRateBook.builtIn(),
        hiddenBuildings: hidden,
      );

  test('buildings: typed codes and room codes, each with its total', () {
    final p = job();
    final buildings = projectBuildings(p, price(p));
    expect(buildings.map((b) => b.name), ['ARTS', 'BSS', 'HOLT']);
    final bss = buildings.firstWhere((b) => b.name == 'BSS');
    expect(bss.rooms, 2);
    expect(bss.total, 1500);
    final holt = buildings.firstWhere((b) => b.name == 'HOLT');
    // The line item is counted under the building its name starts with.
    expect(holt.rooms, 2);
    expect(holt.total, 2500);
    expect(buildings.first.rooms, 0);
  });

  test('a hidden building is left off the estimate', () {
    final p = job();
    final all = price(p);
    final bssOnly = price(p, hidden: {'HOLT'});
    expect(all.grandTotal, 3500);
    expect(bssOnly.grandTotal, 1500);
    expect(bssOnly.rooms.length, 2);
    expect(bssOnly.laborHours, 15);
  });

  test('departments group case-insensitively, with their share', () {
    final p = job();
    final groups = groupBudget(
      projectBudgetEntries(p, price(p)),
      (e) => e.department,
    );
    expect(groups.map((g) => g.name), ['Music', 'Physics', '']);
    final physics = groups[1];
    expect(physics.rooms, 2);
    expect(physics.target, 3000);
    expect(physics.total, 1500);
  });

  test('the department survives a save', () {
    final ref = job().rooms.first;
    final back = ProjectRoomRef.fromJson(ref.toJson());
    expect(back.department, 'Physics');
    final line = const ManualRoom(id: 'm', name: 'X', department: 'Art');
    expect(ManualRoom.fromJson(line.toJson()).department, 'Art');
  });

  test('the summary sheet has both breakdowns', () {
    final p = job();
    final titles = projectSummarySections(price(p)).map((s) => s.title);
    expect(titles, containsAll(['By building', 'By department']));
  });
}
