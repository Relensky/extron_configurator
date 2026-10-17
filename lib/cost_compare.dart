import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'cost_estimate.dart';
import 'labor_rates.dart';

/// ============================================================================
///  COMPARING TWO ROOMS' COSTS, AND MOVING COST ITEMS BETWEEN ROOMS
/// ============================================================================
///  Two rooms of the same type should cost about the same. When they do not,
///  the question is which part or which price differs - so the comparison
///  matches lines by part number (else model, else name) and reports, per
///  part, what each room buys and at what price.
///
///  The lines typed on a cost page (equipment not drawn, rack hardware, cable,
///  other items, labor, fees) can be copied to another room, or saved as a
///  cost preset under `<root>/cost_presets/` for anybody to apply.
/// ============================================================================

/// How one part differs between the two rooms.
enum CostDiffKind { same, onlyHere, onlyThere, qty, price, qtyAndPrice }

/// One part, as each room buys it. "Here" is the open room, "there" the room
/// it is compared with.
class CostDiffRow {
  final String section;
  final String name;
  final String manufacturer;
  final String partNumber;
  final double qtyHere;
  final double qtyThere;
  final double unitHere;
  final double unitThere;
  final double totalHere;
  final double totalThere;

  /// The lines behind the row in each room, for copying it across.
  final List<CostLine> linesHere;
  final List<CostLine> linesThere;
  final List<LaborCostLine> laborHere;
  final List<LaborCostLine> laborThere;

  const CostDiffRow({
    required this.section,
    required this.name,
    this.manufacturer = '',
    this.partNumber = '',
    this.qtyHere = 0,
    this.qtyThere = 0,
    this.unitHere = 0,
    this.unitThere = 0,
    this.totalHere = 0,
    this.totalThere = 0,
    this.linesHere = const [],
    this.linesThere = const [],
    this.laborHere = const [],
    this.laborThere = const [],
  });

  bool get inHere => qtyHere > 0;
  bool get inThere => qtyThere > 0;

  CostDiffKind get kind {
    if (!inThere) return CostDiffKind.onlyHere;
    if (!inHere) return CostDiffKind.onlyThere;
    final qty = (qtyHere - qtyThere).abs() > 0.0001;
    final price = (unitHere - unitThere).abs() >= 0.005;
    if (qty && price) return CostDiffKind.qtyAndPrice;
    if (qty) return CostDiffKind.qty;
    if (price) return CostDiffKind.price;
    return CostDiffKind.same;
  }

  double get totalDifference => totalHere - totalThere;
}

/// A section's total in each room.
typedef SectionTotals = ({String section, double here, double there});

class CostComparison {
  final List<CostDiffRow> rows;
  final List<SectionTotals> sections;
  final double grandHere;
  final double grandThere;

  const CostComparison({
    required this.rows,
    required this.sections,
    required this.grandHere,
    required this.grandThere,
  });

  List<CostDiffRow> get differences =>
      [for (final r in rows) if (r.kind != CostDiffKind.same) r];
}

/// What a part is matched on across rooms: the part number, else the model,
/// else the name. Case and spacing are noise, and so is a part number's
/// punctuation: "60-1331-12" and "60 1331 12" are one SKU.
String costPartKey(String partNumber, String model, String name) {
  String fold(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), '');
  if (partNumber.trim().isNotEmpty) {
    return 'pn:${partNumber.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '')}';
  }
  if (model.trim().isNotEmpty) return 'm:${fold(model)}';
  return 'n:${fold(name)}';
}

/// "Technician - Rack build": a labor line as the comparison names it.
String laborLineName(LaborCostLine l) => [l.roleName, l.description]
    .where((s) => s.trim().isNotEmpty)
    .join(' - ');

class _Side {
  double qty = 0;
  double listTotal = 0;
  double total = 0;
  final lines = <CostLine>[];
  final labor = <LaborCostLine>[];
  double get unit => qty == 0 ? 0 : listTotal / qty;
}

class _Part {
  final String section;
  String name;
  String manufacturer;
  String partNumber;
  final here = _Side();
  final there = _Side();
  _Part(this.section, this.name, this.manufacturer, this.partNumber);
}

/// Every part in [here] and [there], matched, in section order and then by
/// maker and name.
CostComparison compareRoomCosts(CostEstimate here, CostEstimate there) {
  const sectionOrder = [
    'Equipment',
    'Rack hardware',
    'Cabling',
    'Other items',
    'Labor',
  ];
  final parts = <String, _Part>{};

  void addLines(String section, List<CostLine> lines, bool isHere) {
    for (final l in lines) {
      final key = '$section|${costPartKey(l.partNumber, l.model, l.description)}';
      final p = parts.putIfAbsent(
        key,
        () => _Part(section, l.description.trim().isEmpty ? l.model : l.description,
            l.manufacturer, l.partNumber),
      );
      if (p.manufacturer.isEmpty) p.manufacturer = l.manufacturer;
      if (p.partNumber.isEmpty) p.partNumber = l.partNumber;
      final side = isHere ? p.here : p.there;
      side.qty += l.qty;
      side.listTotal += l.listTotal;
      side.total += l.total;
      side.lines.add(l);
    }
  }

  void addLabor(List<LaborCostLine> lines, bool isHere) {
    for (final l in lines) {
      final name = laborLineName(l);
      final key = 'Labor|${costPartKey('', '', name)}';
      final p = parts.putIfAbsent(key, () => _Part('Labor', name, '', ''));
      final side = isHere ? p.here : p.there;
      side.qty += l.totalHours;
      side.listTotal += l.total;
      side.total += l.total;
      side.labor.add(l);
    }
  }

  for (final (estimate, isHere) in [(here, true), (there, false)]) {
    addLines('Equipment', estimate.equipment, isHere);
    addLines('Rack hardware', estimate.hardware, isHere);
    addLines('Cabling', estimate.cabling, isHere);
    addLines('Other items', estimate.extras, isHere);
    addLabor(estimate.labor, isHere);
  }

  final rows = [
    for (final p in parts.values)
      CostDiffRow(
        section: p.section,
        name: p.name,
        manufacturer: p.manufacturer,
        partNumber: p.partNumber,
        qtyHere: p.here.qty,
        qtyThere: p.there.qty,
        unitHere: p.here.unit,
        unitThere: p.there.unit,
        totalHere: p.here.total,
        totalThere: p.there.total,
        linesHere: p.here.lines,
        linesThere: p.there.lines,
        laborHere: p.here.labor,
        laborThere: p.there.labor,
      ),
  ]..sort((a, b) {
      final bySection = sectionOrder
          .indexOf(a.section)
          .compareTo(sectionOrder.indexOf(b.section));
      if (bySection != 0) return bySection;
      final byMaker =
          a.manufacturer.toLowerCase().compareTo(b.manufacturer.toLowerCase());
      if (byMaker != 0) return byMaker;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

  return CostComparison(
    rows: rows,
    sections: [
      (section: 'Equipment', here: here.equipmentTotal, there: there.equipmentTotal),
      (section: 'Rack hardware', here: here.hardwareTotal, there: there.hardwareTotal),
      (section: 'Cabling', here: here.cablingTotal, there: there.cablingTotal),
      (section: 'Other items', here: here.extrasTotal, there: there.extrasTotal),
      (section: 'Labor', here: here.laborTotal, there: there.laborTotal),
      (section: 'Fees', here: here.feeTotal, there: there.feeTotal),
      (section: 'Tax', here: here.tax, there: there.tax),
    ],
    grandHere: here.grandTotal,
    grandThere: there.grandTotal,
  );
}

// ---------------------------------------------------------------------------
//  COST ITEMS: the lines typed on a cost page, to copy or save as a preset
// ---------------------------------------------------------------------------

/// The lines a room's cost page carries that are not drawn on its diagram,
/// with the prices, spares and shipping typed against them.
class CostItemSet {
  final List<CostLineItem> extraEquipment;
  final List<CostLineItem> extraHardware;
  final List<CostLineItem> extraCables;
  final List<CostLineItem> items;
  final List<LaborLine> labor;
  final List<CostFee> fees;

  /// Item id -> the price, spares and shipping typed on that item's line.
  final Map<String, double> prices;
  final Map<String, double> spares;
  final Map<String, double> shipping;

  const CostItemSet({
    this.extraEquipment = const [],
    this.extraHardware = const [],
    this.extraCables = const [],
    this.items = const [],
    this.labor = const [],
    this.fees = const [],
    this.prices = const {},
    this.spares = const {},
    this.shipping = const {},
  });

  /// The cost items on [settings]. Only what is keyed to those items is
  /// taken: a price typed on a drawn device belongs to that room.
  factory CostItemSet.fromSettings(RoomCostSettings settings) {
    final ids = {
      for (final i in [
        ...settings.extraEquipment,
        ...settings.extraHardware,
        ...settings.extraCables,
        ...settings.items,
      ])
        i.id,
    };
    Map<String, double> only(Map<String, double> m) => {
      for (final e in m.entries)
        if (ids.contains(e.key)) e.key: e.value,
    };
    return CostItemSet(
      extraEquipment: [...settings.extraEquipment],
      extraHardware: [...settings.extraHardware],
      extraCables: [...settings.extraCables],
      items: [...settings.items],
      labor: [...settings.labor],
      fees: [...settings.fees],
      prices: only(settings.priceOverrides),
      spares: only(settings.equipmentSpares),
      shipping: only(settings.shippingEach),
    );
  }

  int get lineCount =>
      extraEquipment.length +
      extraHardware.length +
      extraCables.length +
      items.length +
      labor.length +
      fees.length;

  bool get isEmpty => lineCount == 0;

  /// "3 equipment, 2 labor, 1 fee" - what applying it adds.
  String get summary {
    final parts = [
      if (extraEquipment.isNotEmpty) '${extraEquipment.length} equipment',
      if (extraHardware.isNotEmpty) '${extraHardware.length} rack hardware',
      if (extraCables.isNotEmpty) '${extraCables.length} cable',
      if (items.isNotEmpty) '${items.length} other',
      if (labor.isNotEmpty) '${labor.length} labor',
      if (fees.isNotEmpty) '${fees.length} fee${fees.length == 1 ? '' : 's'}',
    ];
    return parts.isEmpty ? 'nothing' : parts.join(', ');
  }

  Map<String, dynamic> toJson() => {
    if (extraEquipment.isNotEmpty)
      'extraEquipment': [for (final i in extraEquipment) i.toJson()],
    if (extraHardware.isNotEmpty)
      'extraHardware': [for (final i in extraHardware) i.toJson()],
    if (extraCables.isNotEmpty)
      'extraCables': [for (final i in extraCables) i.toJson()],
    if (items.isNotEmpty) 'items': [for (final i in items) i.toJson()],
    if (labor.isNotEmpty) 'labor': [for (final l in labor) l.toJson()],
    if (fees.isNotEmpty) 'fees': [for (final f in fees) f.toJson()],
    if (prices.isNotEmpty) 'prices': prices,
    if (spares.isNotEmpty) 'spares': spares,
    if (shipping.isNotEmpty) 'shipping': shipping,
  };

  factory CostItemSet.fromJson(Map<String, dynamic> json) {
    List<CostLineItem> lines(String key) => [
      for (final e in (json[key] as List? ?? const []))
        if (e is Map) CostLineItem.fromJson(Map<String, dynamic>.from(e)),
    ];
    Map<String, double> amounts(String key) => {
      for (final e in ((json[key] as Map?) ?? const {}).entries)
        if (e.value is num) e.key.toString(): (e.value as num).toDouble(),
    };
    return CostItemSet(
      extraEquipment: lines('extraEquipment'),
      extraHardware: lines('extraHardware'),
      extraCables: lines('extraCables'),
      items: lines('items'),
      labor: [
        for (final e in (json['labor'] as List? ?? const []))
          if (e is Map) LaborLine.fromJson(Map<String, dynamic>.from(e)),
      ],
      fees: [
        for (final e in (json['fees'] as List? ?? const []))
          if (e is Map) CostFee.fromJson(Map<String, dynamic>.from(e)),
      ],
      prices: amounts('prices'),
      spares: amounts('spares'),
      shipping: amounts('shipping'),
    );
  }
}

/// The cost items that copy [rows] out of the room whose settings are
/// [source]: from the "there" side when [fromThere], else from "here".
///
/// A line typed on the source's cost page is copied as it is, with its
/// price, spares and shipping. A device drawn on its diagram - a projector,
/// a switcher - or a cable run it counts becomes an added line on the
/// target's quote, under the same catalog model at the same quantity, with
/// the source's room price when it has one.
CostItemSet costItemsFromRows(
  Iterable<CostDiffRow> rows, {
  required RoomCostSettings source,
  required bool fromThere,
}) {
  final equipment = <CostLineItem>[];
  final hardware = <CostLineItem>[];
  final cables = <CostLineItem>[];
  final items = <CostLineItem>[];
  final labor = <LaborLine>[];
  final prices = <String, double>{};
  final spares = <String, double>{};
  final shipping = <String, double>{};
  var drawn = 0;

  void take(CostLine l, List<CostLineItem> typedList, List<CostLineItem> out) {
    final own = typedList.where((i) => i.id == l.key).firstOrNull;
    final item = own ??
        CostLineItem(
          id: 'COPY_${++drawn}',
          description: l.description,
          category: l.category,
          qty: l.qty,
          unitPrice: l.unitPrice,
          taxable: l.taxable,
          catalogModel: l.model,
          manufacturer: l.manufacturer,
          partNumber: l.partNumber,
        );
    out.add(item);
    final price = source.priceOverrides[l.key];
    if (price != null) prices[item.id] = price;
    final spare = source.equipmentSpares[l.key];
    if (own != null && spare != null) spares[item.id] = spare;
    final ship = source.shippingEach[l.key];
    if (ship != null) shipping[item.id] = ship;
  }

  for (final r in rows) {
    for (final l in fromThere ? r.linesThere : r.linesHere) {
      switch (r.section) {
        case 'Equipment':
          take(l, source.extraEquipment, equipment);
        case 'Rack hardware':
          take(l, source.extraHardware, hardware);
        case 'Cabling':
          take(l, source.extraCables, cables);
        default:
          take(l, source.items, items);
      }
    }
    for (final l in fromThere ? r.laborThere : r.laborHere) {
      final own = source.labor.where((x) => x.id == l.id).firstOrNull;
      if (own != null) labor.add(own);
    }
  }
  return CostItemSet(
    extraEquipment: equipment,
    extraHardware: hardware,
    extraCables: cables,
    items: items,
    labor: labor,
    prices: prices,
    spares: spares,
    shipping: shipping,
  );
}

/// The keys an item can be matched on - part number, model and name - in
/// [section].
Set<String> _matchKeys(String section, String pn, String model, String name) =>
    {
      if (pn.trim().isNotEmpty) '$section|${costPartKey(pn, '', '')}',
      if (model.trim().isNotEmpty) '$section|${costPartKey('', model, '')}',
      if (name.trim().isNotEmpty) '$section|${costPartKey('', '', name)}',
    };

/// Every key a line in [estimate] can be matched on, per section. Lines
/// whose key is in [except] are left out.
Set<String> existingPartKeys(
  CostEstimate estimate, {
  Set<String> except = const {},
}) => {
  for (final (section, lines) in [
    ('Equipment', estimate.equipment),
    ('Rack hardware', estimate.hardware),
    ('Cabling', estimate.cabling),
    ('Other items', estimate.extras),
  ])
    for (final l in lines)
      if (!except.contains(l.key))
        ..._matchKeys(section, l.partNumber, l.model, l.description),
};

/// The ids of [lines] and [labor] as typed on [settings]' cost page, for
/// replacing them. Null when any is drawn on the diagram instead, which the
/// cost page cannot take off.
Set<String>? typedLineIds(
  RoomCostSettings settings,
  Iterable<CostLine> lines,
  Iterable<LaborCostLine> labor,
) {
  final typed = {
    for (final i in [
      ...settings.extraEquipment,
      ...settings.extraHardware,
      ...settings.extraCables,
      ...settings.items,
    ])
      i.id,
  };
  final typedLabor = {for (final l in settings.labor) l.id};
  final ids = <String>{};
  for (final l in lines) {
    if (!typed.contains(l.key)) return null;
    ids.add(l.key);
  }
  for (final l in labor) {
    if (!typedLabor.contains(l.id)) return null;
    ids.add(l.id);
  }
  return ids;
}

/// Gives [lineKey] the quantity [qty] in [settings]: a part typed on the
/// Cost tab takes it as its own, a line drawn on the AV Flow as the count
/// quoted. False when the line is neither - rack hardware or a cable run on
/// the drawing, whose count is the drawing's.
bool setCostLineQty(RoomCostSettings settings, String lineKey, double qty) {
  for (final list in [
    settings.extraEquipment,
    settings.extraHardware,
    settings.extraCables,
    settings.items,
  ]) {
    final i = list.indexWhere((item) => item.id == lineKey);
    if (i < 0) continue;
    list[i] = list[i].copyWith(qty: qty);
    return true;
  }
  if (drawnModelOfCostKey(lineKey) == null) return false;
  settings.qtyOverrides[lineKey] = qty;
  return true;
}

/// The model behind a line drawn on the AV Flow, lower case, or null for a
/// line typed on the Cost page. See [deviceGroupKey].
String? drawnModelOfCostKey(String key) {
  final k = key.startsWith('nocost:') ? key.substring(7) : key;
  return k.startsWith('model:') ? k.substring(6) : null;
}

/// Takes the lines with [ids] off [settings], with the price, spares and
/// shipping typed on them. Returns how many came off.
int removeCostItems(RoomCostSettings settings, Set<String> ids) {
  if (ids.isEmpty) return 0;
  var removed = 0;
  void drop<T>(List<T> list, String Function(T) id) {
    final before = list.length;
    list.removeWhere((x) => ids.contains(id(x)));
    removed += before - list.length;
  }

  drop(settings.extraEquipment, (i) => i.id);
  drop(settings.extraHardware, (i) => i.id);
  drop(settings.extraCables, (i) => i.id);
  drop(settings.items, (i) => i.id);
  drop(settings.labor, (l) => l.id);
  for (final id in ids) {
    settings.priceOverrides.remove(id);
    settings.equipmentSpares.remove(id);
    settings.shippingEach.remove(id);
  }
  return removed;
}

/// [set] less what the target already has: a part matching a line on
/// [targetEstimate], labor on the same rate with the same description, a fee
/// of the same name. Lines whose id is in [replacing] are about to come off
/// the target, so they do not count. Returns what is left and how many were
/// skipped.
(CostItemSet, int) withoutExisting(
  CostItemSet set, {
  required RoomCostSettings target,
  required CostEstimate targetEstimate,
  Set<String> replacing = const {},
}) {
  final existing = existingPartKeys(targetEstimate, except: replacing);
  var skipped = 0;
  List<CostLineItem> keep(String section, List<CostLineItem> list) {
    final out = <CostLineItem>[];
    for (final i in list) {
      final keys =
          _matchKeys(section, i.partNumber, i.catalogModel, i.description);
      if (keys.any(existing.contains)) {
        skipped++;
      } else {
        out.add(i);
        // Two of one part in the set are one part.
        existing.addAll(keys);
      }
    }
    return out;
  }

  String laborKey(LaborLine l) =>
      '${l.rateId}|${l.description.trim().toLowerCase()}';
  final labors = {
    for (final l in target.labor)
      if (!replacing.contains(l.id)) laborKey(l),
  };
  final keptLabor = <LaborLine>[];
  for (final l in set.labor) {
    if (labors.add(laborKey(l))) {
      keptLabor.add(l);
    } else {
      skipped++;
    }
  }
  final fees = {for (final f in target.fees) f.name.trim().toLowerCase()};
  final keptFees = <CostFee>[];
  for (final f in set.fees) {
    if (fees.add(f.name.trim().toLowerCase())) {
      keptFees.add(f);
    } else {
      skipped++;
    }
  }
  final kept = CostItemSet(
    extraEquipment: keep('Equipment', set.extraEquipment),
    extraHardware: keep('Rack hardware', set.extraHardware),
    extraCables: keep('Cabling', set.extraCables),
    items: keep('Other items', set.items),
    labor: keptLabor,
    fees: keptFees,
    prices: set.prices,
    spares: set.spares,
    shipping: set.shipping,
  );
  return (kept, skipped);
}

/// What [set] adds, by section, for the confirmation: "Equipment" ->
/// "2 x Epson EB-PU2010B".
Map<String, List<String>> costItemSections(
  CostItemSet set, {
  Map<String, String> rateNames = const {},
}) {
  String line(CostLineItem i) {
    final name = i.description.trim().isNotEmpty
        ? i.description.trim()
        : i.catalogModel;
    return i.qty == 1 ? name : '${trimNumber(i.qty)} x $name';
  }

  return {
    if (set.extraEquipment.isNotEmpty)
      'Equipment': [for (final i in set.extraEquipment) line(i)],
    if (set.extraHardware.isNotEmpty)
      'Rack hardware': [for (final i in set.extraHardware) line(i)],
    if (set.extraCables.isNotEmpty)
      'Cabling': [for (final i in set.extraCables) line(i)],
    if (set.items.isNotEmpty)
      'Other items': [for (final i in set.items) line(i)],
    if (set.labor.isNotEmpty)
      'Labor': [
        for (final l in set.labor)
          [
            rateNames[l.rateId] ?? '',
            l.description,
            '${trimNumber(l.techs * l.hours)} h',
          ].where((s) => s.trim().isNotEmpty).join(' - '),
      ],
    if (set.fees.isNotEmpty)
      'Fees': [
        for (final f in set.fees) '${f.name} (${formatPercent(f.percent)})',
      ],
  };
}

/// The highest number on any id in [settings], so ids handed out after it
/// cannot collide.
int highestCostId(RoomCostSettings settings) {
  var n = 0;
  for (final id in [
    for (final f in settings.fees) f.id,
    for (final i in settings.items) i.id,
    for (final i in settings.extraEquipment) i.id,
    for (final i in settings.extraHardware) i.id,
    for (final i in settings.extraCables) i.id,
    for (final l in settings.labor) l.id,
  ]) {
    final m = RegExp(r'_(\d+)$').firstMatch(id);
    if (m != null && int.parse(m[1]!) > n) n = int.parse(m[1]!);
  }
  return n;
}

/// Adds [set] to [settings], every line under a fresh id from [nextId] so it
/// cannot collide with a line the room already has. A fee the room already
/// has by name is skipped rather than charged twice. Returns how many lines
/// were added.
int addCostItems(
  RoomCostSettings settings,
  CostItemSet set,
  String Function(String prefix) nextId,
) {
  var added = 0;
  CostLineItem copy(CostLineItem item, String prefix) {
    final id = nextId(prefix);
    final price = set.prices[item.id];
    final spare = set.spares[item.id];
    final ship = set.shipping[item.id];
    if (price != null) settings.priceOverrides[id] = price;
    if (spare != null) settings.equipmentSpares[id] = spare;
    if (ship != null) settings.shippingEach[id] = ship;
    added++;
    return CostLineItem.fromJson({...item.toJson(), 'id': id});
  }

  settings.extraEquipment
      .addAll([for (final i in set.extraEquipment) copy(i, 'EQP_')]);
  settings.extraHardware
      .addAll([for (final i in set.extraHardware) copy(i, 'HW_')]);
  settings.extraCables.addAll([for (final i in set.extraCables) copy(i, 'CBL_')]);
  settings.items.addAll([for (final i in set.items) copy(i, 'ITEM_')]);
  for (final l in set.labor) {
    settings.labor
        .add(LaborLine.fromJson({...l.toJson(), 'id': nextId('LABOR_')}));
    added++;
  }
  final feeNames = {
    for (final f in settings.fees) f.name.trim().toLowerCase(),
  };
  for (final f in set.fees) {
    if (!feeNames.add(f.name.trim().toLowerCase())) continue;
    settings.fees.add(CostFee.fromJson({...f.toJson(), 'id': nextId('FEE_')}));
    added++;
  }
  return added;
}

// ---------------------------------------------------------------------------
//  COST PRESETS, as files on the shared root folder
// ---------------------------------------------------------------------------

/// The folder cost presets live in, under the root folder.
const String kCostPresetFolder = 'cost_presets';

/// The extension that marks one.
const String kCostPresetExtension = '.costpreset.json';

class CostPreset {
  final String name;
  final String description;
  final CostItemSet items;

  /// Who saved it, and when, for the picker.
  final String savedBy;
  final String savedAt;

  /// The file it was read from; '' for one not yet saved.
  final String file;

  const CostPreset({
    required this.name,
    required this.items,
    this.description = '',
    this.savedBy = '',
    this.savedAt = '',
    this.file = '',
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    if (description.trim().isNotEmpty) 'description': description.trim(),
    if (savedBy.isNotEmpty) 'savedBy': savedBy,
    if (savedAt.isNotEmpty) 'savedAt': savedAt,
    'items': items.toJson(),
  };

  factory CostPreset.fromJson(Map<String, dynamic> json, {String file = ''}) =>
      CostPreset(
        name: json['name']?.toString() ?? path.basename(file),
        description: json['description']?.toString() ?? '',
        savedBy: json['savedBy']?.toString() ?? '',
        savedAt: json['savedAt']?.toString() ?? '',
        items: json['items'] is Map
            ? CostItemSet.fromJson(Map<String, dynamic>.from(json['items']))
            : const CostItemSet(),
        file: file,
      );
}

/// A preset's file name: its name with anything a file system dislikes
/// turned into underscores.
String costPresetFileName(String name) =>
    '${name.trim().replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '_')}'
    '$kCostPresetExtension';

/// Every cost preset under [rootFolder], by name. Unreadable files are
/// logged and skipped.
Future<List<CostPreset>> loadCostPresets(String rootFolder) async {
  final dir = Directory(path.join(rootFolder, kCostPresetFolder));
  if (rootFolder.isEmpty || !await dir.exists()) return [];
  final out = <CostPreset>[];
  await for (final e in dir.list()) {
    if (e is! File ||
        !e.path.toLowerCase().endsWith(kCostPresetExtension)) {
      continue;
    }
    try {
      final doc = jsonDecode(await e.readAsString());
      if (doc is Map) {
        out.add(CostPreset.fromJson(Map<String, dynamic>.from(doc),
            file: e.path));
      }
    } catch (err) {
      AppLogger.logInfo('Cost preset ${e.path} could not be read: $err');
    }
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// [loadCostPresets] read straight away, for a page that lists them as it is
/// drawn. The folder holds a handful of small files.
List<CostPreset> loadCostPresetsSync(String rootFolder) {
  final dir = Directory(path.join(rootFolder, kCostPresetFolder));
  if (rootFolder.isEmpty || !dir.existsSync()) return [];
  final out = <CostPreset>[];
  for (final e in dir.listSync()) {
    if (e is! File ||
        !e.path.toLowerCase().endsWith(kCostPresetExtension)) {
      continue;
    }
    try {
      final doc = jsonDecode(e.readAsStringSync());
      if (doc is Map) {
        out.add(CostPreset.fromJson(Map<String, dynamic>.from(doc),
            file: e.path));
      }
    } catch (err) {
      AppLogger.logInfo('Cost preset ${e.path} could not be read: $err');
    }
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// Writes [preset] under [rootFolder], replacing one of the same name.
/// Returns the file written.
Future<String> saveCostPreset(String rootFolder, CostPreset preset) async {
  final dir = Directory(path.join(rootFolder, kCostPresetFolder));
  await dir.create(recursive: true);
  final file = File(path.join(dir.path, costPresetFileName(preset.name)));
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(preset.toJson()),
  );
  return file.path;
}
