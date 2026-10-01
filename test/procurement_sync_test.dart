import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/procurement_log.dart';
import 'package:extron_configurator/procurement_sync.dart';
import 'package:extron_configurator/project_estimate.dart';

/// The procurement log follows the rooms: names, and what is on it.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_proc_sync'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// A room with one mic, quoted as a line, named [micName].
  ProjectEstimate job(BuildingProject project, String micName) {
    final config = path.join(dir.path, 'a_config.json');
    File(config).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': 'HIL 101'},
    }));
    File(path.join(dir.path, 'a_config_av_flow.json')).writeAsStringSync(
      jsonEncode({
        'nodes': [
          const AvNode(
            id: 'n1',
            label: 'Projector',
            model: 'PT-1',
            pos: Offset.zero,
            ports: [],
          ).toJson(),
        ],
        'cables': <dynamic>[],
      }),
    );
    File(path.join(dir.path, 'a_config_cost.json')).writeAsStringSync(
      jsonEncode({
        'cost': RoomCostSettings(
          extraEquipment: [
            CostLineItem(
              id: 'EQP_1',
              description: micName,
              manufacturer: 'Shure',
              qty: 5,
              unitPrice: 4000,
            ),
          ],
        ).toJson(),
      }),
    );
    final projectPath = path.join(dir.path, 'job_project.json');
    if (project.rooms.isEmpty) {
      project.rooms.add(ProjectRoomRef(
        id: 'room1',
        configPath: BuildingProject.storePath(config, projectPath),
      ));
    }
    return computeProjectEstimate(
      project: project,
      projectPath: projectPath,
      library: AvDeviceLibrary.empty(),
    );
  }

  test('every room line is on the log before anyone has touched it', () {
    final project = BuildingProject();
    final live = liveProcurement(project, job(project, 'MXA920 ceiling mic'));
    expect(live.map((e) => e.device), contains('Shure MXA920 ceiling mic'));
    expect(live.every(procurementIsAuto), isTrue);
    expect(live.every((e) => e.linked), isTrue);
    expect(project.procurement, isEmpty, reason: 'looking stores nothing');
  });

  test('a linked line takes the name the room has now', () {
    final project = BuildingProject(
      procurement: const [
        ProcurementEntry(
          id: 'proc1',
          room: 'HIL 101',
          device: 'Shure MXA 920 Ceiling Microphone',
          status: ProcurementStatus.submitted,
          statusTo: 'DPR',
          roomId: 'room1',
          lineKey: 'EQP_1',
        ),
      ],
    );
    // The mic was changed to the 925 on the room.
    final live = liveProcurement(project, job(project, 'MXA925 ceiling mic'));
    final mic = live.firstWhere((e) => e.id == 'proc1');
    expect(mic.device, 'Shure MXA925 ceiling mic');
    expect(mic.statusText, 'Submitted to DPR', reason: 'tracking is kept');
    // Not listed a second time as a new line.
    expect(live.where((e) => e.lineKey == 'EQP_1'), hasLength(1));
  });

  test('a line whose item left the room is flagged, not dropped', () {
    final project = BuildingProject(
      procurement: const [
        ProcurementEntry(
          id: 'proc1',
          device: 'Old amplifier',
          roomId: 'room1',
          lineKey: 'EQP_99',
        ),
      ],
    );
    final estimate = job(project, 'Mic');
    final live = liveProcurement(project, estimate);
    final old = live.firstWhere((e) => e.id == 'proc1');
    expect(old.device, 'Old amplifier');
    expect(procurementIsOrphan(old, estimate), isTrue);
  });

  test('a line taken off the log does not come back by itself', () {
    final project = BuildingProject(
      procurement: const [
        ProcurementEntry(
          id: 'proc1',
          roomId: 'room1',
          lineKey: 'EQP_1',
          excluded: true,
        ),
      ],
    );
    final live = liveProcurement(project, job(project, 'Mic'));
    expect(live.where((e) => e.lineKey == 'EQP_1'), isEmpty);
    // Kept in the file.
    final back = BuildingProject.fromJson(project.toJson());
    expect(back.procurement.single.excluded, isTrue);
    expect(back.procurement.single.linked, isTrue);
  });
}
