import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/project_estimate.dart';

/// The tax rate: set on the app, then the project, then the room.
void main() {
  group('a room\'s own rate', () {
    RoomCostSettings read(Map<String, dynamic> json) =>
        RoomCostSettings()..readJson(json);

    test('an older file at 0 follows the base', () {
      final s = read({'taxPercent': 0});
      expect(s.ownTaxRate, isFalse);
      s.followBaseTax(7.25);
      expect(s.taxPercent, 7.25);
    });

    test('an older file above 0 keeps its rate', () {
      final s = read({'taxPercent': 8});
      expect(s.ownTaxRate, isTrue);
      s.followBaseTax(7.25);
      expect(s.taxPercent, 8);
    });

    test('a room set to 0 on purpose stays at 0', () {
      final s = read(
        (RoomCostSettings(taxPercent: 0, ownTaxRate: true)).toJson(),
      );
      expect(s.ownTaxRate, isTrue);
      s.followBaseTax(7.25);
      expect(s.taxPercent, 0);
    });

    test('taking the base rate does not change what the room saves', () {
      // Or opening a room on a job with a rate would mark it changed.
      final room = RoomCostSettings();
      final before = jsonEncode(room.toJson());
      room.followBaseTax(9.25);
      expect(room.taxPercent, 9.25);
      expect(jsonEncode(room.toJson()), before);
      // A room's own rate is still saved.
      final own = RoomCostSettings(taxPercent: 5);
      expect(own.toJson()['taxPercent'], 5);
    });

    test('the base rate it was saved at travels with the room', () {
      final saved = RoomCostSettings()
        ..followBaseTax(9)
        ..fileBaseTax = 9;
      final s = read(saved.toJson());
      expect(s.ownTaxRate, isFalse);
      expect(s.fileBaseTax, 9);
      // A room with its own rate needs no base.
      final own = RoomCostSettings(taxPercent: 5)..fileBaseTax = 9;
      expect(own.toJson().containsKey('taxBase'), isFalse);
    });

    test('a following room saved at the base still follows it', () {
      final saved = RoomCostSettings()..followBaseTax(7.25);
      final s = read(saved.toJson());
      expect(s.ownTaxRate, isFalse);
      s.followBaseTax(9);
      expect(s.taxPercent, 9);
    });
  });

  group('the project rollup', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('rcb_tax_test'));
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    String writeRoom(String stem, RoomCostSettings settings) {
      final configPath = path.join(dir.path, '${stem}_config.json');
      File(configPath).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gui_full_room_name': stem},
      }));
      File(path.join(dir.path, '${stem}_config_av_flow.json'))
          .writeAsStringSync(jsonEncode({
        'nodes': [
          AvNode(
            id: 'n1',
            label: 'Panel',
            model: 'Big Panel 86',
            pos: Offset.zero,
            ports: const [],
          ).toJson(),
        ],
        'cables': <dynamic>[],
      }));
      File(path.join(dir.path, '${stem}_config_cost.json'))
          .writeAsStringSync(jsonEncode({'cost': settings.toJson()}));
      return configPath;
    }

    ProjectEstimate price(BuildingProject project, {double appRate = 0}) {
      final library = AvDeviceLibrary.empty()
        ..upsert(const AvDeviceTemplate(
          model: 'Big Panel 86',
          manufacturer: 'Samsung',
          partNumber: 'QM86R',
          category: 'Display',
          price: 1000,
          ports: [],
        ));
      final projectPath = path.join(dir.path, 'job_project.json');
      for (final (stem, settings) in [
        ('follows', RoomCostSettings()),
        ('own', RoomCostSettings(taxPercent: 5)),
        ('exempt', RoomCostSettings(taxPercent: 0, ownTaxRate: true)),
      ]) {
        project.rooms.add(ProjectRoomRef(
          id: stem,
          configPath:
              BuildingProject.storePath(writeRoom(stem, settings), projectPath),
        ));
      }
      return computeProjectEstimate(
        project: project,
        projectPath: projectPath,
        library: library,
        defaultTaxPercent: appRate,
      );
    }

    Map<String, double> ratesOf(ProjectEstimate e) => {
      for (final r in e.rooms) r.ref.id: r.estimate!.taxPercent,
    };

    test('rooms without their own rate take the project\'s', () {
      final e = price(BuildingProject(taxPercent: 8), appRate: 6);
      expect(ratesOf(e), {'follows': 8, 'own': 5, 'exempt': 0});
    });

    test('a project without a rate falls back to the app\'s', () {
      final e = price(BuildingProject(), appRate: 6);
      expect(ratesOf(e), {'follows': 6, 'own': 5, 'exempt': 0});
    });

    test('no rate on the job or this PC: the rate the room was saved at', () {
      final project = BuildingProject();
      final projectPath = path.join(dir.path, 'job_project.json');
      final saved = RoomCostSettings()..fileBaseTax = 7;
      project.rooms.add(ProjectRoomRef(
        id: 'shared',
        configPath: BuildingProject.storePath(
          writeRoom('shared', saved),
          projectPath,
        ),
      ));
      final e = computeProjectEstimate(
        project: project,
        projectPath: projectPath,
        library: AvDeviceLibrary.empty(),
      );
      expect(e.rooms.single.estimate!.taxPercent, 7);
    });

    test('a job with no rate takes the default of whoever has one', () async {
      // Made on a PC with no default: unset, not 0 on purpose.
      final p = AppStateProvider(autoLoadSettings: false)
        ..defaultTaxPercent = 0;
      p.newProject(name: 'Job');
      expect(p.project.taxPercent, isNull);
      final file = path.join(dir.path, 'job_project.json');
      expect(await p.saveProject(to: file), '');
      expect(p.project.taxPercent, isNull);

      // Saved on a PC with one: written into the job for everybody.
      p.defaultTaxPercent = 9.25;
      expect(await p.saveProject(), '');
      expect(BuildingProject.fromJson(
        jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>,
      ).taxPercent, 9.25);

      // A job set to 0 on purpose keeps it.
      p.setProjectTaxPercent(0);
      p.defaultTaxPercent = 6;
      await p.saveProject();
      expect(p.project.taxPercent, 0);
    });

    test('the project\'s rate is saved with it', () {
      final json = BuildingProject(taxPercent: 8.5).toJson();
      expect(BuildingProject.fromJson(json).taxPercent, 8.5);
      expect(BuildingProject().toJson().containsKey('taxPercent'), isFalse);
    });
  });
}
