import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/labor_rates.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_labor.dart';
import 'package:extron_configurator/project_workbook.dart';

/// The project's Labor pane and tab: room by room, by rate, by who provides.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_project_labor'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String writeRoom(String stem, String name, RoomCostSettings cost) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({'nodes': []}));
    File(path.join(dir.path, '${stem}_config_cost.json'))
        .writeAsStringSync(jsonEncode({'cost': cost.toJson()}));
    return configPath;
  }

  final rates = LaborRateBook(rates: const [
    LaborRate(id: 'cts3', name: 'CTS III', hourlyRate: 100),
    LaborRate(id: 'fms', name: 'FMS', hourlyRate: 80),
  ]);

  ProjectEstimate job({bool excludeB = false}) {
    final a = writeRoom(
      'a',
      'Room A',
      RoomCostSettings(
        labor: [
          const LaborLine(id: 'l1', rateId: 'cts3', techs: 2, hours: 8),
          const LaborLine(id: 'l2', rateId: 'fms', techs: 1, hours: 4),
        ],
        furnishedLines: {'l2': 'another department'},
      ),
    );
    final b = writeRoom(
      'b',
      'Room B',
      RoomCostSettings(
        labor: [
          const LaborLine(id: 'l1', rateId: 'cts3', techs: 1, hours: 10),
          const LaborLine(
            id: 'l2',
            customRate: 150,
            description: 'Programmer',
            techs: 1,
            hours: 2,
          ),
        ],
      ),
    );
    final projectPath = path.join(dir.path, 'job_project.json');
    final project = BuildingProject(name: 'Labor job', building: 'BSS');
    for (final c in [a, b]) {
      project.rooms.add(ProjectRoomRef(
        id: project.nextRoomId(),
        configPath: BuildingProject.storePath(c, projectPath),
      ));
    }
    if (excludeB) {
      project.rooms[1] = project.rooms[1].copyWith(included: false);
    }
    return computeProjectEstimate(
      project: project,
      projectPath: projectPath,
      library: AvDeviceLibrary.empty(),
      rates: rates,
    );
  }

  test('rooms, rates and providers add up to the job\'s labor', () {
    final estimate = job();
    final s = projectLaborSummary(estimate);

    expect(s.rooms.map((r) => r.total), [1600, 1300]);
    expect(s.total, estimate.laborTotal);
    expect(s.hours, estimate.laborHours);
    expect(s.inKindValue, 320);

    final cts = s.rates.firstWhere((r) => r.rateId == 'cts3');
    expect(cts.hours, 26);
    expect(cts.total, 2600);
    expect(cts.hoursByRoom.length, 2);
    final own = s.rates.firstWhere((r) => r.customRate);
    expect(own.hourlyRate, 150);

    expect(s.providers.first.label, 'Paid by this job');
    expect(s.providers.first.cost, 2900);
    final dept = s.providers.firstWhere(
      (p) => p.label == 'Another department',
    );
    expect(dept.cost, 0);
    expect(dept.value, 320);
    expect(dept.hoursByRate['FMS'], 4);
  });

  test('an excluded room is listed but not counted', () {
    final s = projectLaborSummary(job(excludeB: true));
    expect(s.rooms.length, 2);
    expect(s.rooms[1].included, isFalse);
    expect(s.total, 1600);
    expect(s.rates.every((r) => r.hoursByRoom.length == 1), isTrue);
  });

  test('rooms sort by name and by priority', () {
    final estimate = job();
    final rooms = projectLaborSummary(estimate).rooms;
    final a = rooms[0], b = rooms[1];
    ProjectLaborRoom withPriority(ProjectLaborRoom r, int p) =>
        ProjectLaborRoom(
          room: ProjectRoomCost(
            ref: r.room.ref.copyWith(priority: p),
            room: r.room.room,
            estimate: r.room.estimate,
          ),
          lines: r.lines,
        );

    // Unprioritized last, then priority 1 before 2.
    final ranked = sortLaborRooms([
      withPriority(a, 0),
      withPriority(b, 2),
      withPriority(a, 1),
    ], LaborRoomSort.priority);
    expect(ranked.map((r) => r.room.ref.priority), [1, 2, 0]);

    expect(
      sortLaborRooms([b, a], LaborRoomSort.name).map((r) => r.room.name),
      ['Room A', 'Room B'],
    );
    expect(
      sortLaborRooms([b, a], LaborRoomSort.project).map((r) => r.room.name),
      ['Room B', 'Room A'],
    );
    // A: $1,600 plus $320 in kind; B: $1,300.
    expect(
      sortLaborRooms([b, a], LaborRoomSort.amount).map((r) => r.room.name),
      ['Room A', 'Room B'],
    );
  });

  test('the workbook has a Labor tab', () {
    final archive = ZipDecoder()
        .decodeBytes(buildProjectWorkbookBytes(estimate: job()));
    final workbook = utf8.decode(
      archive.files.firstWhere((f) => f.name == 'xl/workbook.xml').content
          as List<int>,
    );
    expect(workbook, contains('name="$kProjectLaborSheet"'));

    final titles = projectLaborSections(job()).map((s) => s.title).toList();
    expect(titles, contains('Labor by room'));
    expect(titles, contains('By job type (department / contractor)'));
    expect(titles, contains('By who provides it'));
  });

  test('no labor, no tab', () {
    expect(
      projectLaborSections(
        computeProjectEstimate(
          project: BuildingProject(name: 'Empty'),
          projectPath: path.join(dir.path, 'e_project.json'),
          library: AvDeviceLibrary.empty(),
        ),
      ),
      isEmpty,
    );
  });
}
