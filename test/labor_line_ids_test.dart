import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/cost_compare.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/labor_rates.dart';

/// LANG 300: a room whose only cost line was LABOR_2 handed out LABOR_1 and
/// then LABOR_2 again. Two lines under one id edited each other, so adding
/// crew to one looked like it reverted.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_labor_ids'));
  tearDown(() => dir.deleteSync(recursive: true));

  AppStateProvider open(List<Map<String, dynamic>> labor) {
    final configPath = path.join(dir.path, 'a_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': 'Room A'},
    }));
    File(path.join(dir.path, 'a_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({'nodes': []}));
    File(path.join(dir.path, 'a_config_cost.json')).writeAsStringSync(
        jsonEncode({
          'cost': {'labor': labor},
        }));
    final p = AppStateProvider(autoLoadSettings: false)
      ..currentConfigPath = configPath
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Room A'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  test('a new labor line never takes the id of one already there', () {
    final p = open([
      {'id': 'LABOR_2', 'rateId': 'c0400_state', 'techs': 1.0},
    ]);
    final a = p.addAvCostLabor();
    final b = p.addAvCostLabor();
    final ids = p.avCost.labor.map((l) => l.id).toList();
    expect(ids.toSet(), hasLength(3), reason: '$ids');
    expect([a.id, b.id], everyElement(isNot('LABOR_2')));

    // Adding crew to the new line changes that line, not the old one.
    p.updateAvCostLabor(b.copyWith(techs: 3));
    expect(p.avCost.labor.firstWhere((l) => l.id == b.id).techs, 3);
    expect(p.avCost.labor.firstWhere((l) => l.id == 'LABOR_2').techs, 1);
  });

  test('a room saved with two lines under one id opens with two ids', () {
    final p = open([
      {'id': 'LABOR_2', 'rateId': 'c6476_state', 'techs': 1.0},
      {'id': 'LABOR_2', 'rateId': 'c0400_state', 'techs': 1.0},
    ]);
    final lines = p.avCost.labor;
    expect(lines.map((l) => l.id).toSet(), hasLength(2));
    expect(lines.map((l) => l.rateId), ['c6476_state', 'c0400_state']);

    // Each now edits and removes on its own.
    p.updateAvCostLabor(lines[1].copyWith(techs: 4));
    expect(p.avCost.labor[0].techs, 1);
    expect(p.avCost.labor[1].techs, 4);
    p.removeAvCostLabor(p.avCost.labor[0].id);
    expect(p.avCost.labor.single.rateId, 'c0400_state');
  });

  test('repairCostIds leaves unique ids alone and fixes blank ones', () {
    final s = RoomCostSettings();
    s.labor.addAll(const [
      LaborLine(id: 'LABOR_1'),
      LaborLine(id: ''),
      LaborLine(id: 'LABOR_1'),
    ]);
    var n = 5;
    expect(repairCostIds(s, (prefix) => '$prefix${++n}'), 2);
    expect(s.labor.map((l) => l.id), ['LABOR_1', 'LABOR_6', 'LABOR_7']);
    expect(repairCostIds(s, (prefix) => '$prefix${++n}'), 0);
  });
}
