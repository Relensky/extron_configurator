import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/labor_rates.dart';

/// Parts from our stock and labor given in kind: on the estimate at what they
/// are worth, and not in its total.
void main() {
  const empty = AvFlowModel(
    nodes: [],
    cables: [],
    racks: [],
    rackSlots: {},
    canvasSize: Size(0, 0),
    roomTitle: '',
    unplaced: [],
  );

  CostEstimate priced(RoomCostSettings s) => computeRoomCost(
    model: empty,
    library: AvDeviceLibrary.empty(),
    settings: s,
  );

  RoomCostSettings settings() => RoomCostSettings()
    ..extraEquipment.addAll(const [
      CostLineItem(id: 'EQP_1', description: 'Display', qty: 2, unitPrice: 1000),
      // Off the catalog, from the shelf.
      CostLineItem(id: 'EQP_2', description: 'Old mount', qty: 1, unitPrice: 150),
    ])
    ..labor.addAll(const [
      LaborLine(id: 'LABOR_1', description: 'Rack build', customRate: 100,
          techs: 2, hours: 4),
      LaborLine(id: 'LABOR_2', description: 'Install', customRate: 100,
          hours: 3),
    ]);

  test('nothing given, nothing listed', () {
    final e = priced(settings());
    expect(e.inKind, isEmpty);
    expect(e.inKindTotal, 0);
    expect(e.laborTotal, 1100);
  });

  test('labor in kind is worth its hours and costs the job nothing', () {
    final s = settings()..furnishedLines['LABOR_1'] = 'in kind';
    final e = priced(s);
    expect(e.laborTotal, 300);
    final labor = e.labor.firstWhere((l) => l.id == 'LABOR_1');
    expect(labor.total, 0);
    expect(labor.listTotal, 800);
    expect(e.inKind.single.section, 'Labor');
    expect(e.inKind.single.value, 800);
    expect(e.inKindBySource.single.source, 'Our labor and staff');
  });

  test('stock parts, some or all, are listed at their worth', () {
    final s = settings()
      ..furnishedLines['EQP_1'] = 'stock'
      ..furnishedQty['EQP_1'] = 1
      ..furnishedLines['EQP_2'] = 'stock'
      ..furnishedLines['LABOR_2'] = 'in kind';
    final e = priced(s);
    expect(e.equipmentTotal, 1000, reason: 'one display still bought');
    expect(e.inKindTotal, 1000 + 150 + 300);
    expect(
      {for (final x in e.inKindBySource) x.source: x.value},
      {'From our stock': 1150.0, 'Our labor and staff': 300.0},
    );
  });

  test('the report lists them and totals them apart', () {
    final s = settings()..furnishedLines['EQP_2'] = 'stock';
    final sections = costReportSections(priced(s));
    final inKind = sections.firstWhere((x) => x.title == 'In Kind');
    expect(inKind.rows.single.first, 'Old mount');
    final totals = sections.last.rows.map((r) => r.first).toList();
    expect(totals, contains('In-kind value (not in the total)'));
    expect(totals, contains('Project value with in kind'));
  });
}
