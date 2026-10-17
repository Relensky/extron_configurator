import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/labor_rates.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_labor.dart';
import 'package:extron_configurator/project_workbook.dart';

/// Cost lines charged with a crew: their own section, a total that counts
/// them or not, and the project's Labor tab.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_labor_charge'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  const emptyModel = AvFlowModel(
    nodes: [],
    cables: [],
    racks: [],
    rackSlots: {},
    canvasSize: Size.zero,
    roomTitle: '',
    unplaced: [],
  );

  final rates = LaborRateBook(rates: const [
    LaborRate(id: 'fms', name: 'FMS', hourlyRate: 80),
  ]);

  /// $320 of FMS labor, $200 of lumber charged with it, and a $50 untagged
  /// item. No tax.
  RoomCostSettings settings({bool include = true}) => RoomCostSettings(
    labor: [const LaborLine(id: 'crew', rateId: 'fms', hours: 4)],
    items: [
      const CostLineItem(id: 'lumber', description: 'Lumber', qty: 4,
          unitPrice: 50),
      const CostLineItem(id: 'misc', description: 'Misc', unitPrice: 50),
    ],
  )
    ..laborCharges['lumber'] = 'crew'
    ..includeLaborCharges = include;

  CostEstimate room({bool include = true}) => computeRoomCost(
    model: emptyModel,
    library: AvDeviceLibrary.empty(),
    settings: settings(include: include),
    rates: rates,
  );

  test('a charged line leaves its section for its own', () {
    final e = room();
    expect(e.extras.map((l) => l.key), ['misc']);
    expect(e.laborCharges.single.line.key, 'lumber');
    expect(e.laborCharges.single.crew, 'FMS');
    expect(e.laborChargesTotal, 200);
    expect(e.extrasTotal, 50);
    expect(e.grandTotal, 570);
    expect(e.grandWithLaborCharges, 570);
    expect(e.grandWithoutLaborCharges, 370);
  });

  test('toggled off, the total leaves them out but lists them', () {
    final e = room(include: false);
    expect(e.grandTotal, 370);
    expect(e.laborCharges, hasLength(1));
    final totals = costReportSections(e).last.rows.map((r) => r.first);
    expect(totals, contains('Labor charges (not in the total)'));
  });

  test('the report has a Labor Charges section and totals row', () {
    final sections = costReportSections(room());
    expect(sections.map((s) => s.title), contains(kLaborChargesSection));
    final totals = sections.last.rows.map((r) => r.first);
    expect(totals, contains(kLaborChargesTotalLabel));
  });

  test('a charge to a crew that is gone is an ordinary line', () {
    final s = settings()..laborCharges['misc'] = 'nobody';
    final e = computeRoomCost(
      model: emptyModel,
      library: AvDeviceLibrary.empty(),
      settings: s,
      rates: rates,
    );
    expect(e.extras.map((l) => l.key), ['misc']);
  });

  test('the setting survives a save', () {
    final back = RoomCostSettings()..readJson(settings(include: false).toJson());
    expect(back.laborCharges, {'lumber': 'crew'});
    expect(back.includeLaborCharges, isFalse);
  });

  group('on the project', () {
    late String projectPath;

    BuildingProject job() {
      final configPath = path.join(dir.path, 'a_config.json');
      File(configPath).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gui_full_room_name': 'Room A'},
      }));
      File(path.join(dir.path, 'a_config_av_flow.json'))
          .writeAsStringSync(jsonEncode({'nodes': []}));
      File(path.join(dir.path, 'a_config_cost.json'))
          .writeAsStringSync(jsonEncode({'cost': settings().toJson()}));
      projectPath = path.join(dir.path, 'job_project.json');
      return BuildingProject(name: 'Job')
        ..rooms.add(ProjectRoomRef(
          id: 'r1',
          configPath: BuildingProject.storePath(configPath, projectPath),
        ));
    }

    ProjectEstimate price(BuildingProject p) => computeProjectEstimate(
      project: p,
      projectPath: projectPath,
      library: AvDeviceLibrary.empty(),
      rates: rates,
    );

    test('the project toggle follows into every room', () {
      final p = job();
      expect(price(p).grandTotal, 570);
      expect(price(p).laborChargesTotal, 200);
      p.includeLaborCharges = false;
      final off = price(p);
      expect(off.grandTotal, 370);
      expect(off.laborChargesEffect, 200);
      expect(
        BuildingProject.fromJson(p.toJson()).includeLaborCharges,
        isFalse,
      );
    });

    test('the Labor tab lists the fees under the crew', () {
      final s = projectLaborSummary(price(job()));
      expect(s.feesTotal, 200);
      expect(s.rooms.single.fees.single.name, 'Lumber');
      final fms = s.rates.single;
      expect(fms.fees, 200);
      expect(s.providers.single.feesByRate['FMS'], 200);
      final titles = projectLaborSections(price(job())).map((x) => x.title);
      expect(titles, contains('Fees charged with labor'));
    });

    test('a charged part stays on the master list while counted', () {
      expect(price(job()).master.map((m) => m.description), contains('Lumber'));
    });
  });
}
