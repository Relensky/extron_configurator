import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

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

    test('the project\'s rate is saved with it', () {
      final json = BuildingProject(taxPercent: 8.5).toJson();
      expect(BuildingProject.fromJson(json).taxPercent, 8.5);
      expect(BuildingProject().toJson().containsKey('taxPercent'), isFalse);
    });
  });
}
