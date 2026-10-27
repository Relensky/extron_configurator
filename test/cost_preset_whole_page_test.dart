import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cost_compare.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/labor_rates.dart';

/// A cost preset holds the whole cost page: the devices drawn on the AV Flow
/// as well as the lines typed by hand, with labor, fees, scope and notes.
/// LANG 300 had one typed line and two labor lines, and everything else
/// drawn; its preset kept only those three.
void main() {
  const drawn = AvFlowModel(
    nodes: [
      AvNode(
        id: 'AVNODE_1',
        label: 'Projector',
        model: 'EB-PU2010B',
        pos: Offset.zero,
        ports: [],
      ),
      AvNode(
        id: 'AVNODE_2',
        label: 'Projector',
        model: 'EB-PU2010B',
        pos: Offset(100, 0),
        ports: [],
      ),
      AvNode(
        id: 'AVNODE_3',
        label: 'PC',
        model: 'PC',
        pos: Offset(200, 0),
        ports: [],
      ),
    ],
    cables: [],
    racks: [],
    rackSlots: {},
    canvasSize: Size(0, 0),
    roomTitle: '',
    unplaced: [],
  );
  const empty = AvFlowModel(
    nodes: [],
    cables: [],
    racks: [],
    rackSlots: {},
    canvasSize: Size(0, 0),
    roomTitle: '',
    unplaced: [],
  );
  AvDeviceLibrary library() => AvDeviceLibrary.empty()
    ..upsert(const AvDeviceTemplate(
      model: 'EB-PU2010B',
      manufacturer: 'Epson',
      partNumber: 'V11HA94020',
      category: 'Projector',
      price: 6000,
      ports: [],
    ))
    ..upsert(const AvDeviceTemplate(
      model: 'PC',
      category: 'Computer',
      price: 1500,
      ports: [],
    ));

  /// LANG 300 in small: two drawn projectors at a room price, a drawn PC
  /// taken from stock, one typed lift, two crews and the scope.
  RoomCostSettings lang300(AvDeviceLibrary lib) {
    final s = RoomCostSettings(
      scopeOfWork: 'Throw - 15 ft; screens 8 ft (verify)',
      notes: 'Pricing good for 30 days.',
    )
      ..extraEquipment.add(const CostLineItem(
        id: 'EQP_1',
        description: 'Freedom One eLift 18RU',
        catalogModel: 'Freedom One eLift 18RU',
      ))
      ..labor.addAll(const [
        LaborLine(
            id: 'LABOR_5',
            rateId: 'tech',
            description: 'Mount screens',
            techs: 2,
            hours: 8),
        LaborLine(
            id: 'LABOR_6',
            rateId: 'tech',
            description: 'Pull P2P runs',
            techs: 2,
            hours: 24),
      ]);
    final e = computeRoomCost(model: drawn, library: lib, settings: s);
    final projector =
        e.equipment.firstWhere((l) => l.model == 'EB-PU2010B').key;
    final pc = e.equipment.firstWhere((l) => l.model == 'PC').key;
    s.priceOverrides[projector] = 5200;
    s.furnishedLines[pc] = 'stock';
    return s;
  }

  test('takes the drawn devices as well as the typed lines', () {
    final lib = library();
    final s = lang300(lib);
    final e = computeRoomCost(model: drawn, library: lib, settings: s);
    final set = CostItemSet.wholePage(s, e);

    expect(set.extraEquipment, hasLength(3));
    final projector =
        set.extraEquipment.firstWhere((i) => i.catalogModel == 'EB-PU2010B');
    expect(projector.qty, 2);
    expect(set.prices[projector.id], 5200);
    final pc = set.extraEquipment.firstWhere((i) => i.catalogModel == 'PC');
    expect(set.furnished[pc.id], 'stock');
    expect(set.labor, hasLength(2));
    expect(set.scopeOfWork, startsWith('Throw'));
    expect(set.notes, 'Pricing good for 30 days.');
    expect(set.summary, contains('3 equipment'));
    expect(set.summary, contains('scope of work'));
  });

  test('survives the preset file and lands whole in an empty room', () {
    final lib = library();
    final s = lang300(lib);
    final e = computeRoomCost(model: drawn, library: lib, settings: s);
    final set = CostItemSet.fromJson(CostItemSet.wholePage(s, e).toJson());

    final target = RoomCostSettings();
    var n = 0;
    addCostItems(target, set, (p) => '$p${++n}');
    final after = computeRoomCost(model: empty, library: lib, settings: target);

    final projector =
        after.equipment.firstWhere((l) => l.model == 'EB-PU2010B');
    expect(projector.qty, 2);
    expect(projector.unitPrice, 5200);
    final pc = after.equipment.firstWhere((l) => l.model == 'PC');
    expect(pc.furnishedBy, 'stock');
    expect(after.equipment, hasLength(3));
    expect(after.labor, hasLength(2));
    expect(target.scopeOfWork, startsWith('Throw'));
    expect(target.notes, 'Pricing good for 30 days.');
  });

  test('scope and notes go on under a room\'s own, not twice', () {
    const set = CostItemSet(scopeOfWork: 'Theirs', notes: 'Their notes');
    final target = RoomCostSettings(scopeOfWork: 'Ours');
    addCostItems(target, set, (p) => '${p}1');
    addCostItems(target, set, (p) => '${p}2');
    expect(target.scopeOfWork, 'Ours\n\nTheirs');
    expect(target.notes, 'Their notes');
  });

  test('a page of only words still saves', () {
    final s = RoomCostSettings(scopeOfWork: 'Survey only');
    final e = computeRoomCost(model: empty, library: library(), settings: s);
    expect(CostItemSet.wholePage(s, e).isEmpty, isFalse);
  });

  test('drawn-line settings fill in where the room has none', () {
    final from = RoomCostSettings()
      ..priceOverrides['model:pc'] = 1200
      ..qtyOverrides['model:pc'] = 0
      ..priceOverrides['EQP_1'] = 50;
    final into = RoomCostSettings()..priceOverrides['model:pc'] = 999;
    mergeDrawnLineSettings(into, from);
    expect(into.priceOverrides['model:pc'], 999);
    expect(into.qtyOverrides['model:pc'], 0);
    // A typed line's id means nothing in another room.
    expect(into.priceOverrides.containsKey('EQP_1'), isFalse);
  });
}
