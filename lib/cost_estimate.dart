import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'base_costs.dart';
import 'labor_rates.dart';
import 'report_tools.dart';
import 'xlsx_writer.dart' show XlsxMoney;

/// ============================================================================
///  ROOM COST ESTIMATE
/// ============================================================================
///  What the room on the AV diagram costs to build. The quantities come from
///  the diagram itself — the same grouping the pack list uses, so the estimate
///  and the equipment order can never disagree — and the unit prices come from
///  the device catalog (av_devices.json), with a per-room override for the
///  price you were actually quoted.
///
///  On top of the equipment:
///
///    * FEES are percentages of the total before tax (freight, install,
///      contingency, overhead). Any number of them; each says whether it is
///      itself taxable, because a freight charge usually is and a labor line
///      usually isn't.
///    * LABOR is priced as rate x techs x hours, against the shared rate card
///      (labor_rates.dart) so revising a rate re-costs every estimate that
///      uses it.
///    * OTHER ITEMS are flat lines with their own quantity and unit price —
///      cable, plates, anything not a device on the canvas.
///    * TAX is one percentage applied to the taxable part of the estimate:
///      all equipment, plus the other items and fees marked taxable.
///
///  Everything here is pure data: the view (cost_estimate_view.dart) edits
///  [RoomCostSettings], and [computeRoomCost] turns settings + diagram +
///  catalog into the numbers the screen and the workbook both render.
/// ============================================================================

// ---------------------------------------------------------------------------
//  SETTINGS (persisted in the AV flow sidecar)
// ---------------------------------------------------------------------------

/// A percentage add-on, charged on the estimate's pre-tax total.
class CostFee {
  final String id;
  final String name;
  final double percent;

  /// Whether tax is charged on this fee as well. Freight normally is;
  /// labor normally isn't. Getting this wrong is a quiet few hundred
  /// dollars, so it is a per-fee answer rather than a global assumption.
  final bool taxable;

  const CostFee({
    required this.id,
    required this.name,
    required this.percent,
    this.taxable = true,
  });

  CostFee copyWith({String? name, double? percent, bool? taxable}) => CostFee(
    id: id,
    name: name ?? this.name,
    percent: percent ?? this.percent,
    taxable: taxable ?? this.taxable,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'percent': percent,
    'taxable': taxable,
  };

  factory CostFee.fromJson(Map<String, dynamic> json) => CostFee(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? 'Fee',
    percent: (json['percent'] as num?)?.toDouble() ?? 0,
    taxable: json['taxable'] != false,
  );
}

/// A line that isn't a device on the canvas: labor, cable, mounts, freight
/// quoted as a figure rather than a percentage.
class CostLineItem {
  final String id;
  final String description;
  final String category;
  final double qty;
  final double unitPrice;
  final bool taxable;

  /// Catalog model this line was picked from, or '' when it was typed by
  /// hand. When it is set, the catalog's current price at the active tier
  /// wins over [unitPrice] — so a part added to a quote picks up a price
  /// revision the same way a part on the diagram does.
  final String catalogModel;

  /// Bought for the shelf, not for this room's system.
  ///
  /// Everything else on the estimate is a thing the room HAS, and the app says
  /// so loudly: equipment with no control block behind it is flagged, because
  /// a device the processor cannot drive is normally a mistake. A spare is the
  /// case where it is not — the third projector lamp, the replacement panel in
  /// the store, the switcher held for the next failure. It is real money on
  /// the quote and it is not part of the room, so it is quoted and left off
  /// every "this is missing from the config" list.
  final bool spare;

  /// Quoted, in the room, and nothing here drives it.
  ///
  /// The line's version of [AvNode.excludeFromControl], and the case a spare
  /// does not cover: an owner-furnished display, a codec another department
  /// manages, the building's switch quoted on this job. It is part of the
  /// room, so calling it a spare would be a lie — it simply has no business
  /// having a device block, and saying so is what stops the estimate flagging
  /// it forever.
  final bool noControl;

  const CostLineItem({
    required this.id,
    required this.description,
    this.category = '',
    this.qty = 1,
    this.unitPrice = 0,
    this.taxable = true,
    this.catalogModel = '',
    this.spare = false,
    this.noControl = false,
  });

  double get total => qty * unitPrice;

  CostLineItem copyWith({
    String? description,
    String? category,
    double? qty,
    double? unitPrice,
    bool? taxable,
    String? catalogModel,
    bool? spare,
    bool? noControl,
  }) => CostLineItem(
    id: id,
    description: description ?? this.description,
    category: category ?? this.category,
    qty: qty ?? this.qty,
    unitPrice: unitPrice ?? this.unitPrice,
    taxable: taxable ?? this.taxable,
    catalogModel: catalogModel ?? this.catalogModel,
    spare: spare ?? this.spare,
    noControl: noControl ?? this.noControl,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    if (category.isNotEmpty) 'category': category,
    'qty': qty,
    'unitPrice': unitPrice,
    'taxable': taxable,
    if (catalogModel.isNotEmpty) 'catalogModel': catalogModel,
    if (spare) 'spare': true,
    if (noControl) 'noControl': true,
  };

  factory CostLineItem.fromJson(Map<String, dynamic> json) => CostLineItem(
    id: json['id']?.toString() ?? '',
    description: json['description']?.toString() ?? '',
    category: json['category']?.toString() ?? '',
    qty: (json['qty'] as num?)?.toDouble() ?? 1,
    unitPrice: (json['unitPrice'] as num?)?.toDouble() ?? 0,
    taxable: json['taxable'] != false,
    catalogModel: json['catalogModel']?.toString() ?? '',
    spare: json['spare'] == true,
    noControl: json['noControl'] == true,
  );
}

/// What order the equipment table lists its lines in.
///
/// A choice about the QUOTE rather than about the screen, so it is kept with
/// the estimate and every export reads it: a quote read on paper, in the
/// workbook and in the tab export lists its equipment the same way the person
/// who wrote it left it.
enum CostEquipmentSort {
  /// Devices off the diagram in name order, then anything racked, then the
  /// lines added by hand — how the estimate has always been built.
  standard,

  /// By manufacturer, then by name within each maker. What an order gets
  /// split into: one purchase order per vendor.
  manufacturer,
}

/// The stored name of each sort, and what the picker calls it.
const Map<CostEquipmentSort, String> kCostEquipmentSortLabels = {
  CostEquipmentSort.standard: 'Device name',
  CostEquipmentSort.manufacturer: 'Manufacturer',
};

/// The room's estimate settings. Lives in `<config>_av_flow.json` beside the
/// diagram it prices, because a negotiated price is a fact about this job,
/// not about the model.
class RoomCostSettings {
  String currency;
  String taxLabel;
  double taxPercent;
  final List<CostFee> fees;

  /// Line key (see [DeviceGroup.key]) -> the unit price for THIS room,
  /// overriding whatever the catalog says.
  final Map<String, double> priceOverrides;

  final List<CostLineItem> items;

  /// The crews on this job: which rate, how many techs, how many hours.
  final List<LaborLine> labor;

  /// What order [CostEstimate.equipment] comes back in — see
  /// [CostEquipmentSort]. Sorted where the estimate is BUILT rather than
  /// where it is drawn, so the screen, the screenshot, the workbook and the
  /// tab export cannot disagree about the order of a quote.
  CostEquipmentSort equipmentSort;

  /// Whether the cable runs drawn on the AV flow are priced into the estimate.
  /// On by default: a room's cabling is a real cost, and the diagram already
  /// says exactly how many runs of what there are.
  bool includeCabling;

  /// Equipment quoted on the job that is not a device on the diagram — a box
  /// somebody else is installing, a spare, a stand-in for a decision that has
  /// not been made yet, or a plain line with a price typed on it.
  ///
  /// The diagram is the right source for what a room contains, and a poor one
  /// for what an order contains: a quote regularly carries a figure for
  /// something nobody has drawn. Before this those went into "Other items",
  /// where they read as fees rather than as equipment and never showed up in
  /// the equipment total anybody was checking.
  final List<CostLineItem> extraEquipment;

  /// Rack hardware bought for the job but not placed in a frame — a spare
  /// shelf, a box of blanks, the plate that goes in somebody else's rack.
  /// Priced like placed hardware and listed with it, marked as not racked.
  final List<CostLineItem> extraHardware;

  /// Cable that is not a run on the diagram: a spool, a bag of patch leads,
  /// the drop somebody else is pulling. Counted by hand rather than off the
  /// drawing, which is exactly why it needs a home of its own — otherwise it
  /// gets typed into "Other items" where the cable schedule can never see it.
  final List<CostLineItem> extraCables;

  /// Equipment LINE KEY -> units to buy beyond the ones on the diagram.
  ///
  /// The same decision the cable spares box records, about the boxes instead
  /// of the leads: a job that buys four displays for a room with three of them
  /// drawn is buying a spare, and the fourth is real money that no drawing
  /// will ever account for. Before this the only way to quote it was a second
  /// line typed by hand, which read as a different product, priced itself
  /// separately, and drifted from the model on the diagram the moment anybody
  /// swapped it.
  ///
  /// Keyed per LINE, like [cableSpares], because that is what gets ordered:
  /// a spare 86" display and a spare switcher are two decisions at two prices.
  final Map<String, double> equipmentSpares;

  /// SIGNAL AND LENGTH -> the catalog entry that length is bought as, when
  /// somebody has said which one rather than letting the catalog decide. See
  /// [cableEntryKey].
  ///
  /// The estimate picks the shortest stock lead that reaches each run, which
  /// is right until it isn't: a room that is being cabled in plenum, or in the
  /// one brand a stakeholder will accept, buys a different lead for the same run
  /// and no length in the catalog says so. Keyed on the length rather than on
  /// the LINE key, because the line key is built out of the entry — it moves
  /// when this changes, and a decision that forgets itself the moment it is
  /// acted on is worse than no decision at all.
  final Map<String, String> cableEntries;

  /// LINE KEY -> where a line is coming from instead of this quote.
  ///
  /// FURNISHED FROM SOMEWHERE ELSE. Not every part in a room is bought on the
  /// job that installs it: the network department pulls and terminates the
  /// cat6, the displays come out of a campus stock order, the owner hands over
  /// a codec they already own. Those parts ARE in the room — they get racked,
  /// cabled, drawn and replaced on the same cycle as everything else — and
  /// they are not money on this quote.
  ///
  /// Deleting the line was the only way to say so, and it said too much: the
  /// part vanished from the pack list, from the cable schedule and from the
  /// replacement plan along with its price. So the line stays exactly where it
  /// is, with its quantity and its unit price, and contributes NOTHING to the
  /// total. See [CostLine.furnishedBy], which is what carries it onto the page
  /// and into the exports.
  ///
  /// The value is who is furnishing it — 'From stock', 'Campus IT', whatever
  /// somebody typed — or '' for "by others" with nobody named. Keyed per LINE
  /// like the spares and the price overrides, because that is the grain the
  /// decision is made at: the cat6 is somebody else's and the HDMI is not.
  final Map<String, String> furnishedLines;

  /// Cabling LINE KEY -> extra runs to buy beyond what the diagram shows.
  /// Spares are a decision, not a diagram fact, so they live here rather than
  /// being inferred: "three more HDMI leads because two always go missing" is
  /// the sort of thing a quote should say out loud.
  ///
  /// Keyed per LINE rather than per signal type, because a length is what gets
  /// ordered: two spare 3 ft patch leads and two spare 50 ft runs are two
  /// different decisions at two different prices, and one box against "HDMI"
  /// could only ever record one of them. Rooms saved before that read back
  /// under the type's own line — see [fromJson].
  final Map<String, double> cableSpares;

  RoomCostSettings({
    this.currency = r'$',
    this.taxLabel = 'Sales tax',
    this.taxPercent = 0,
    this.includeCabling = true,
    this.equipmentSort = CostEquipmentSort.standard,
    List<CostFee>? fees,
    Map<String, double>? priceOverrides,
    List<CostLineItem>? items,
    List<LaborLine>? labor,
    Map<String, double>? cableSpares,
    Map<String, String>? cableEntries,
    Map<String, double>? equipmentSpares,
    Map<String, String>? furnishedLines,
    List<CostLineItem>? extraEquipment,
    List<CostLineItem>? extraHardware,
    List<CostLineItem>? extraCables,
  }) : fees = fees ?? [],
       priceOverrides = priceOverrides ?? {},
       items = items ?? [],
       labor = labor ?? [],
       cableSpares = cableSpares ?? {},
       cableEntries = cableEntries ?? {},
       equipmentSpares = equipmentSpares ?? {},
       furnishedLines = furnishedLines ?? {},
       extraEquipment = extraEquipment ?? [],
       extraHardware = extraHardware ?? [],
       extraCables = extraCables ?? [];

  bool get isEmpty =>
      taxPercent == 0 &&
      equipmentSort == CostEquipmentSort.standard &&
      fees.isEmpty &&
      priceOverrides.isEmpty &&
      items.isEmpty &&
      labor.isEmpty &&
      cableSpares.isEmpty &&
      cableEntries.isEmpty &&
      equipmentSpares.isEmpty &&
      furnishedLines.isEmpty &&
      extraEquipment.isEmpty &&
      extraHardware.isEmpty &&
      extraCables.isEmpty;

  void clear() {
    currency = r'$';
    taxLabel = 'Sales tax';
    taxPercent = 0;
    includeCabling = true;
    equipmentSort = CostEquipmentSort.standard;
    fees.clear();
    priceOverrides.clear();
    items.clear();
    labor.clear();
    cableSpares.clear();
    cableEntries.clear();
    equipmentSpares.clear();
    furnishedLines.clear();
    extraEquipment.clear();
    extraHardware.clear();
    extraCables.clear();
  }

  Map<String, dynamic> toJson() => {
    'currency': currency,
    'taxLabel': taxLabel,
    'taxPercent': taxPercent,
    'includeCabling': includeCabling,
    if (equipmentSort != CostEquipmentSort.standard)
      'equipmentSort': equipmentSort.name,
    'fees': [for (final f in fees) f.toJson()],
    // Copied, not handed out live: the undo history snapshots the room by
    // calling this and empties the estimate before reading a snapshot back,
    // so a live map would be cleared a moment before it was read. See
    // CablingOverrides.toJson, which is the same requirement.
    'priceOverrides': Map<String, double>.of(priceOverrides),
    'items': [for (final i in items) i.toJson()],
    'labor': [for (final l in labor) l.toJson()],
    if (cableSpares.isNotEmpty)
      'cableSpares': Map<String, double>.of(cableSpares),
    if (cableEntries.isNotEmpty)
      'cableEntries': Map<String, String>.of(cableEntries),
    if (equipmentSpares.isNotEmpty)
      'equipmentSpares': Map<String, double>.of(equipmentSpares),
    if (furnishedLines.isNotEmpty)
      'furnishedLines': Map<String, String>.of(furnishedLines),
    if (extraEquipment.isNotEmpty)
      'extraEquipment': [for (final i in extraEquipment) i.toJson()],
    if (extraHardware.isNotEmpty)
      'extraHardware': [for (final i in extraHardware) i.toJson()],
    if (extraCables.isNotEmpty)
      'extraCables': [for (final i in extraCables) i.toJson()],
  };

  void readJson(Map<String, dynamic> json) {
    clear();
    currency = json['currency']?.toString() ?? r'$';
    taxLabel = json['taxLabel']?.toString() ?? 'Sales tax';
    taxPercent = (json['taxPercent'] as num?)?.toDouble() ?? 0;
    // Absent in files written before cabling was priced. On is the right
    // default there too: the cable types ship unpriced, so an older room gains
    // a cabling section that says what it needs and reports it as not yet
    // priced, rather than one that quietly adds money nobody entered.
    includeCabling = json['includeCabling'] != false;
    // An unknown name reads as the standard order rather than throwing: this
    // file is hand-editable, and a typo in it must not cost somebody a room.
    final sortName = json['equipmentSort']?.toString();
    equipmentSort = CostEquipmentSort.values.firstWhere(
      (s) => s.name == sortName,
      orElse: () => CostEquipmentSort.standard,
    );
    for (final f in (json['fees'] as List? ?? [])) {
      if (f is Map) fees.add(CostFee.fromJson(Map<String, dynamic>.from(f)));
    }
    final overrides = json['priceOverrides'];
    if (overrides is Map) {
      overrides.forEach((key, value) {
        final price = (value as num?)?.toDouble();
        if (price != null) priceOverrides[key.toString()] = price;
      });
    }
    for (final i in (json['items'] as List? ?? [])) {
      if (i is Map) {
        items.add(CostLineItem.fromJson(Map<String, dynamic>.from(i)));
      }
    }
    for (final l in (json['labor'] as List? ?? [])) {
      if (l is Map) {
        labor.add(LaborLine.fromJson(Map<String, dynamic>.from(l)));
      }
    }
    for (final i in (json['extraEquipment'] as List? ?? [])) {
      if (i is Map) {
        extraEquipment.add(CostLineItem.fromJson(Map<String, dynamic>.from(i)));
      }
    }
    for (final i in (json['extraHardware'] as List? ?? [])) {
      if (i is Map) {
        extraHardware.add(CostLineItem.fromJson(Map<String, dynamic>.from(i)));
      }
    }
    for (final i in (json['extraCables'] as List? ?? [])) {
      if (i is Map) {
        extraCables.add(CostLineItem.fromJson(Map<String, dynamic>.from(i)));
      }
    }
    final equipSpares = json['equipmentSpares'];
    if (equipSpares is Map) {
      equipSpares.forEach((key, value) {
        final qty = (value as num?)?.toDouble();
        if (qty == null || qty <= 0) return;
        equipmentSpares[key.toString()] = qty;
      });
    }
    final furnished = json['furnishedLines'];
    if (furnished is Map) {
      furnished.forEach((key, value) {
        // '' is a real value here — "by others, nobody named" — so only a
        // missing entry means the line is priced on this quote.
        if (value == null) return;
        furnishedLines[key.toString()] = value.toString().trim();
      });
    }
    final entries = json['cableEntries'];
    if (entries is Map) {
      entries.forEach((key, value) {
        final model = value?.toString().trim() ?? '';
        if (model.isEmpty) return;
        cableEntries[key.toString()] = model;
      });
    }
    final spares = json['cableSpares'];
    if (spares is Map) {
      spares.forEach((key, value) {
        final qty = (value as num?)?.toDouble();
        if (qty == null || qty <= 0) return;
        // A room saved when spares were per SIGNAL wrote the bare name
        // ('hdmi'). That is the type's own line, which is where those spares
        // have always sat, so it reads back onto it.
        final name = key.toString();
        cableSpares[name.startsWith('cable:') ? name : 'cable:$name'] = qty;
      });
    }
  }
}

// ---------------------------------------------------------------------------
//  GROUPING (shared with the pack list)
// ---------------------------------------------------------------------------

/// Devices on the diagram that count as "the same thing to order". Keyed on
/// model, so three identical displays are one line of quantity 3; a device
/// with no model stays on its own, because a pair of unnamed boxes merging
/// silently is how a pack list starts lying.
class DeviceGroup {
  final String key;
  final List<AvNode> nodes;

  const DeviceGroup({required this.key, required this.nodes});

  AvNode get first => nodes.first;
  int get qty => nodes.length;
  String get model => first.model.trim();

  /// True when these are drawn but not bought — see [AvNode.excludeFromCost].
  /// A group is all one or all the other, because the key says so.
  bool get excludeFromCost => first.excludeFromCost;

  /// One name, or every name when several devices share the model — the
  /// pack list is read to find the boxes, so the names have to be there.
  ///
  /// Comma-joined because this is also a line on the estimate PAGE, where a
  /// four-line cell would push the row apart. The pack list wants one name
  /// per line and builds that itself from [nodes].
  String get label =>
      nodes.length == 1 ? first.label : nodes.map((n) => n.label).join(', ');

  String get notes => nodes
      .map((n) => n.note)
      .where((n) => n.trim().isNotEmpty)
      .toSet()
      .join('; ');

  /// Watts for the whole group; 0 when nobody recorded a figure.
  double get watts => nodes.fold(0.0, (sum, n) => sum + n.powerWatts);

  bool get anyUnmetered => nodes.any((n) => n.powerWatts <= 0);
}

/// The diagram's devices, grouped for ordering. Jack fields are included:
/// a 12-port patch panel is a thing you buy.
List<DeviceGroup> groupDevices(AvFlowModel model) {
  final grouped = <String, List<AvNode>>{};
  for (final node in model.nodes) {
    final base = node.model.trim().isEmpty
        ? 'device:${node.id}'
        : 'model:${node.model.trim().toLowerCase()}';
    // Two of the same model where one is being bought and one is already in
    // the room are two lines, not one of quantity two — merging them would
    // put the existing unit on the quote or take the new one off it.
    final key = node.excludeFromCost ? 'nocost:$base' : base;
    grouped.putIfAbsent(key, () => []).add(node);
  }
  return [
    for (final e in grouped.entries) DeviceGroup(key: e.key, nodes: e.value),
  ];
}

/// Rack hardware of one kind, counted. Twelve 1U blanks are one order line of
/// twelve, not twelve lines — the same rule the device pack list follows.
class RackItemGroup {
  final String key;
  final String catalogModel;
  final String description;
  final String category;
  final double qty;

  /// The part number recorded on the placed items. Like [price], a copy of
  /// what the catalog said when the item went in — used only when the entry
  /// it came from has gone.
  final String partNumber;

  /// The unit price recorded on the placed items. Used only when the catalog
  /// entry it came from has gone.
  final double price;

  const RackItemGroup({
    required this.key,
    required this.catalogModel,
    required this.description,
    required this.category,
    required this.qty,
    this.partNumber = '',
    required this.price,
  });
}

/// Groups placed rack hardware for ordering. Items from the same catalog entry
/// merge; a one-off typed in by hand merges on its name, so "Blank plate" typed
/// twice is still one line of two.
/// Which quote line a placed piece of rack hardware belongs to.
///
/// Named rather than inlined because the estimate is read backwards as often
/// as forwards: a row on the quote is "replace this" or "reprice this", and
/// both have to find the items in the frames the row was built from.
String rackItemKey(RackItem item) => item.catalogModel.trim().isNotEmpty
    ? 'rackitem:model:${item.catalogModel.trim().toLowerCase()}'
    : 'rackitem:label:${item.label.trim().toLowerCase()}|${item.rackUnits}';

List<RackItemGroup> groupRackItems(List<RackItem> items) {
  final grouped = <String, List<RackItem>>{};
  for (final item in items) {
    grouped.putIfAbsent(rackItemKey(item), () => []).add(item);
  }
  final out = [
    for (final e in grouped.entries)
      RackItemGroup(
        key: e.key,
        catalogModel: e.value.first.catalogModel,
        description: e.value.first.label,
        category: e.value.first.category,
        partNumber: e.value.first.partNumber,
        qty: e.value.length.toDouble(),
        // The highest recorded price rather than the first: an item re-placed
        // after a price rise should not quote the room at the old figure.
        price: e.value.fold(0.0, (m, i) => i.price > m ? i.price : m),
      ),
  ];
  out.sort((a, b) => a.description.toLowerCase().compareTo(
    b.description.toLowerCase(),
  ));
  return out;
}

/// How many runs of each signal type the diagram has. This is the whole point
/// of drawing the cabling: the cable order is counted from the drawing rather
/// than guessed, so the two cannot disagree.
Map<SignalType, int> countCableRuns(AvFlowModel model) {
  final counts = <SignalType, int>{};
  final byId = model.nodesById;
  for (final cable in model.cables) {
    // A run whose ends no longer exist isn't a run — the same rule the canvas
    // uses when it declines to draw it.
    if (!AvFlowModel.cableIsResolvable(cable, byId)) continue;
    counts[cable.signal] = (counts[cable.signal] ?? 0) + 1;
  }
  return counts;
}

// ---------------------------------------------------------------------------
//  THE COMPUTED ESTIMATE
// ---------------------------------------------------------------------------

/// Where a line's unit price came from — shown in the table and the report so
/// a number can always be traced back to a decision.
enum PriceSource {
  override,
  catalog,

  /// The catalog priced it, but only at the OTHER tier — an education job
  /// costed off a list price, or the reverse. Called out separately because
  /// that is a number somebody needs to look at before it goes on a quote.
  catalogOtherTier,
  baseCost,
  none,
}

const Map<PriceSource, String> kPriceSourceLabels = {
  PriceSource.override: 'Room price',
  PriceSource.catalog: 'Catalog',
  PriceSource.catalogOtherTier: 'Catalog - other tier',
  PriceSource.baseCost: 'Base cost',
  PriceSource.none: 'Not priced',
};

/// The signal a counted-cable line belongs to, or null when [key] is not one.
///
/// Cabling lines are keyed `cable:<signal>` for the type's main line and
/// `cable:<signal>@<model>` for each stock length it is broken down into. The
/// estimate page reads the signal back out to put the type's spares box and
/// its color dot on the row.
SignalType? cableSignalOfKey(String key) {
  if (!key.startsWith('cable:')) return null;
  final rest = key.substring('cable:'.length);
  final at = rest.indexOf('@');
  final name = at < 0 ? rest : rest.substring(0, at);
  for (final s in SignalType.values) {
    if (s.name == name) return s;
  }
  return null;
}

/// The catalog model and run length a cabling line key names, both blank/zero
/// on the type's own line.
///
/// The inverse of the key [computeRoomCost] builds — `cable:hdmi@25ft`,
/// `cable:hdmi@HDMI 25@20ft` — so a spare typed against a line the diagram no
/// longer has can still be put back on a line of its own instead of vanishing
/// into the type.
({String model, double lengthFt}) cableKeyParts(String key) {
  final at = key.indexOf('@');
  if (!key.startsWith('cable:') || at < 0) return (model: '', lengthFt: 0);
  final parts = key.substring(at + 1).split('@');
  var lengthFt = 0.0;
  if (parts.isNotEmpty) {
    final last = parts.last;
    if (last.endsWith('ft')) {
      final ft = double.tryParse(last.substring(0, last.length - 2));
      if (ft != null) {
        lengthFt = ft;
        parts.removeLast();
      }
    }
  }
  return (model: parts.join('@'), lengthFt: lengthFt);
}

/// How [RoomCostSettings.cableEntries] files "buy this length as that lead".
///
/// Signal and length, never the line key: the line key carries the entry's own
/// name, so it changes the moment this decision is made — and a preference
/// that unfiles itself when it is acted on is worse than none.
String cableEntryKey(SignalType signal, double lengthFt) =>
    '${signal.name}@${formatCableLength(lengthFt)}';

/// True when the line is costed at a category average rather than a real
/// price. The estimate counts these separately: a budget built on base costs is
/// a budget, and should not be read as a quote.
bool isEstimatedSource(PriceSource s) => s == PriceSource.baseCost;

/// True when the figure came from the catalog at all, either tier.
bool isCatalogSource(PriceSource s) =>
    s == PriceSource.catalog || s == PriceSource.catalogOtherTier;

/// Orders two lines by who makes them, then by name — the comparator behind
/// [CostEquipmentSort.manufacturer]. The key is the last tiebreak because
/// Dart's sort is not stable, and a quote whose rows swap places on every
/// rebuild is one nobody can read.
int compareByManufacturer(CostLine a, CostLine b) {
  final makerA = a.manufacturer.trim();
  final makerB = b.manufacturer.trim();
  if (makerA.isEmpty != makerB.isEmpty) return makerA.isEmpty ? 1 : -1;
  final byMaker = makerA.toLowerCase().compareTo(makerB.toLowerCase());
  if (byMaker != 0) return byMaker;
  final byName = a.description.toLowerCase().compareTo(
    b.description.toLowerCase(),
  );
  return byName != 0 ? byName : a.key.compareTo(b.key);
}

class CostLine {
  final String key;
  final String description;
  final String model;

  /// Bought for the shelf rather than for this room — see
  /// [CostLineItem.spare]. Always false for a device counted off the diagram:
  /// a box that is drawn is in the room.
  final bool spare;

  /// How many of [qty] are spares typed on this line rather than things the
  /// diagram counts. 0 on every line but a device group with a spares figure.
  final double spareQty;

  /// What the diagram itself counts — [qty] less [spareQty].
  double get drawnQty => qty - spareQty;

  /// The manufacturer's ordering code, off the catalog entry. Carried on the
  /// line rather than looked up when the report is written, so the number on
  /// the estimate is the one the price came from.
  final String partNumber;

  /// Who makes it, off the catalog entry. Carried on the line for the same
  /// reason [partNumber] is — the estimate is sorted and split by vendor, and
  /// looking the maker up again when the report is written would let a
  /// catalog edit change a quote that was already written.
  final String manufacturer;

  final String category;
  final double qty;
  final double unitPrice;
  final bool taxable;
  final PriceSource source;

  /// Who is furnishing this line instead of this quote, or null when the quote
  /// is paying for it. '' means "by others" with nobody named. See
  /// [RoomCostSettings.furnishedLines].
  ///
  /// The line keeps its quantity and its unit price — the part is in the room,
  /// it goes on the pack list, and the replacement plan still budgets for the
  /// day it dies. What it does not do is add money to THIS job's total, which
  /// is what [total] returning zero says.
  final String? furnishedBy;

  const CostLine({
    required this.key,
    required this.description,
    this.model = '',
    this.partNumber = '',
    this.manufacturer = '',
    this.category = '',
    required this.qty,
    required this.unitPrice,
    this.taxable = true,
    this.source = PriceSource.none,
    this.spare = false,
    this.spareQty = 0,
    this.furnishedBy,
  });

  /// True when somebody else is buying this.
  bool get furnished => furnishedBy != null;

  /// What this line costs the job: nothing at all when somebody else is
  /// furnishing it. Zeroed HERE rather than at each total, so every figure
  /// derived from the estimate — the section subtotals, the tax, the fees, the
  /// project rollup and every export — agrees without being told twice.
  double get total => furnished ? 0 : qty * unitPrice;

  /// What the line would have cost if the job were buying it. The pack list
  /// and the "what is this room worth" figures want this; the quote does not.
  double get listTotal => qty * unitPrice;
}

/// What the "Price from" column says about [line] — the pricing ladder's own
/// answer, or who is furnishing it when the job is not buying it.
///
/// One function because three places print that column (the page, the report
/// and the workbook) and a line that reads "furnished by Campus IT" on screen
/// and "nothing, catalog price" in the exported quote is how a part gets
/// bought twice.
String priceFromLabel(CostLine line) {
  final by = line.furnishedBy;
  if (by == null) return kPriceSourceLabels[line.source] ?? '';
  return by.isEmpty ? 'Furnished by others' : 'Furnished by $by';
}

/// The note that goes on a furnished line's description, or '' when the job is
/// buying it. Kept out of [CostLine.description] itself so the name of the
/// part stays the name of the part — for matching, for sorting and for the box
/// on screen that edits it.
String furnishedNote(CostLine line) {
  final by = line.furnishedBy;
  if (by == null) return '';
  return by.isEmpty ? 'furnished by others' : 'furnished by $by';
}

/// One fee with the money it works out to.
typedef FeeAmount = ({CostFee fee, double amount});

/// A crew line, costed. The hours and head count are kept alongside the money
/// because "two CTS III for three days" is what gets checked; the total is
/// just what it comes to.
class LaborCostLine {
  final String id;
  final String roleName;
  final String description;
  final double techs;
  final double hours;
  final double hourlyRate;
  final bool taxable;

  /// True when the rate card has no figure for this role yet.
  final bool unrated;

  const LaborCostLine({
    required this.id,
    required this.roleName,
    required this.description,
    required this.techs,
    required this.hours,
    required this.hourlyRate,
    required this.taxable,
    required this.unrated,
  });

  double get totalHours => techs * hours;
  double get total => totalHours * hourlyRate;
}

class CostEstimate {
  final String currency;

  /// Which published price this estimate was costed from. Recorded on the
  /// estimate rather than assumed, so a quote read a year later says whether
  /// it was written at list or at education pricing.
  final PricingTier tier;
  final List<CostLine> equipment;

  /// Vent plates, blanks, shelves and drawers placed in the racks. Kept apart
  /// from [equipment] because a rack full of blanking plates is a real line on
  /// an order and a distracting one in a list of AV devices.
  final List<CostLine> hardware;

  /// Cable runs counted off the AV flow, one line per signal type, plus the
  /// spares asked for. Empty when cabling is switched off for this room.
  final List<CostLine> cabling;

  final List<CostLine> extras;

  /// Crews, priced from the rate card. Kept apart from [extras] because a
  /// quote is read as equipment + labor, and because the hours behind the
  /// figure are what get argued about.
  final List<LaborCostLine> labor;
  final List<FeeAmount> fees;
  final double equipmentTotal;
  final double hardwareTotal;
  final double cablingTotal;
  final double extrasTotal;
  final double laborTotal;
  final double laborHours;

  /// Labor lines whose rate is 0 — the rate card has no figure for that job
  /// type yet, so the hours are real but the money is missing.
  final int unratedLabor;

  /// Equipment + other items: the "total before taxes" every fee is a
  /// percentage of.
  final double subtotal;
  final double feeTotal;
  final double taxableBase;
  final double taxPercent;
  final String taxLabel;
  final double tax;
  final double grandTotal;

  /// Devices on the diagram with no price anywhere — the estimate is short by
  /// however much these cost, and says so instead of reading as complete.
  final int unpricedLines;
  final int unpricedDevices;

  /// Lines costed off the base-cost card rather than a real price. Counted so
  /// the total can be labeled a budget rather than a quote.
  final int estimatedLines;

  /// Devices on the diagram deliberately kept off this estimate — existing
  /// gear, owner-furnished kit, somebody else's contract. Reported rather than
  /// silent: a total that is short on purpose still has to say so, or the next
  /// person to read it goes looking for the missing switcher.
  final int excludedLines;
  final int excludedDevices;

  /// Lines the catalog could only price at the OTHER tier. Worth a look before
  /// the total goes anywhere: an education job with list prices in it reads
  /// high, and the reverse reads low.
  final int otherTierLines;

  const CostEstimate({
    required this.currency,
    this.tier = PricingTier.msrp,
    required this.equipment,
    required this.hardware,
    required this.cabling,
    required this.extras,
    required this.labor,
    required this.fees,
    required this.equipmentTotal,
    required this.hardwareTotal,
    required this.cablingTotal,
    required this.extrasTotal,
    required this.laborTotal,
    required this.laborHours,
    required this.unratedLabor,
    required this.subtotal,
    required this.feeTotal,
    required this.taxableBase,
    required this.taxPercent,
    required this.taxLabel,
    required this.tax,
    required this.grandTotal,
    required this.unpricedLines,
    required this.unpricedDevices,
    required this.estimatedLines,
    this.otherTierLines = 0,
    this.excludedLines = 0,
    this.excludedDevices = 0,
  });

  bool get isComplete => unpricedLines == 0 && unratedLabor == 0;

  /// True when some of the money on this page came off the base-cost card.
  bool get isBudgetary => estimatedLines > 0;

  /// The tier's short name, for a column heading or a report row.
  String get tierLabel => kPricingTierShort[tier] ?? tier.name;
}

/// Rounds to cents. Percentages of percentages otherwise leave a fraction of a
/// cent in the total, which is the kind of thing that gets a quote queried.
double _cents(double value) => (value * 100).roundToDouble() / 100;

/// Prices [model]'s devices against [library] and [settings].
CostEstimate computeRoomCost({
  required AvFlowModel model,
  required AvDeviceLibrary library,
  required RoomCostSettings settings,
  LaborRateBook? rates,
  BaseCostBook? baseCosts,
  /// Which of a catalog entry's two published prices to cost from.
  PricingTier tier = PricingTier.msrp,
}) {
  final book = rates ?? LaborRateBook.builtIn();
  final baseBook = baseCosts ?? BaseCostBook.builtIn();
  final equipment = <CostLine>[];
  int unpricedLines = 0;
  int unpricedDevices = 0;
  int estimatedLines = 0;
  int otherTierLines = 0;
  int excludedLines = 0;
  int excludedDevices = 0;

  final groups = groupDevices(model)
    ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));

  for (final group in groups) {
    // Drawn but not bought. Off the estimate entirely rather than listed at
    // zero: a line of nothing on a quote is a question, and the count below
    // answers it once instead of once per row.
    if (group.excludeFromCost) {
      excludedLines++;
      excludedDevices += group.qty;
      continue;
    }
    final catalog = library.templateForModel(group.model);
    final override = settings.priceOverrides[group.key];

    // The category a base cost would be looked up under: what the catalog
    // says this model is, or — for a device nobody has chosen a model for yet
    // — what its config section key makes it.
    final category = (catalog?.category.trim().isNotEmpty ?? false)
        ? catalog!.category.trim()
        : categoryForConfigKey(group.first.id);

    // TWO GOES AT THE BASE CARD, because a catalog category is not always one
    // of ours. The card knows 'Switcher'; an entry imported from Extron says
    // 'Matrix', and a screen controller imported from the same page says
    // 'Architectural'. [BaseCostBook.priceFor] translates the families that
    // mean one thing; for the rest, what the device does IN THIS ROOM is a
    // better answer than the aisle it was catalogd under — and it is the
    // answer this line would have got if the entry had carried no category at
    // all. Without this, a model the catalog knows but cannot price came out
    // WORSE than a model it has never heard of.
    var basePrice = baseBook.priceFor(category, tier);
    if (basePrice.price <= 0) {
      final byRole = categoryForConfigKey(group.first.id);
      if (byRole.isNotEmpty && byRole != category) {
        basePrice = baseBook.priceFor(byRole, tier);
      }
    }

    final catalogPrice = catalog?.priceForTier(tier);

    final double price;
    final PriceSource source;
    // A base cost entered at only one tier is still worth costing off, but the
    // line is flagged the same way a one-tier catalog entry is.
    var otherTier = false;
    if (override != null) {
      price = override;
      source = PriceSource.override;
    } else if (catalogPrice != null && catalogPrice.price > 0) {
      price = catalogPrice.price;
      otherTier = catalogPrice.fallback;
      source = catalogPrice.fallback
          ? PriceSource.catalogOtherTier
          : PriceSource.catalog;
    } else if (basePrice.price > 0) {
      // No model price anywhere, but the shop knows roughly what a camera
      // costs. Better than a hole in the total, as long as the line says so.
      price = basePrice.price;
      otherTier = basePrice.fallback;
      source = PriceSource.baseCost;
    } else {
      price = 0;
      source = PriceSource.none;
    }
    // SPARES ARE PART OF THE LINE, not a line of their own: a fourth display
    // for a room with three drawn is the same product at the same price, and
    // splitting it out is how a quote ends up with two prices for one box.
    final spares = settings.equipmentSpares[group.key] ?? 0;
    final qty = group.qty + (spares > 0 ? spares : 0.0);
    // A line somebody else is furnishing is not an unpriced line: it has no
    // figure on this quote BY DECISION, and counting it as a hole would leave
    // the page reporting work to do that is already done.
    final furnishedBy = settings.furnishedLines[group.key];
    if (source == PriceSource.none && furnishedBy == null) {
      unpricedLines++;
      unpricedDevices += qty.round();
    }
    if (isEstimatedSource(source) && furnishedBy == null) estimatedLines++;
    if (otherTier && furnishedBy == null) otherTierLines++;

    equipment.add(
      CostLine(
        key: group.key,
        description: group.label,
        model: group.model,
        partNumber: catalog?.partNumber ?? '',
        manufacturer: catalog?.manufacturer ?? '',
        category: category,
        qty: qty,
        spareQty: spares > 0 ? spares : 0,
        unitPrice: price,
        source: source,
        furnishedBy: furnishedBy,
      ),
    );
  }

  // --- what is in the frames ------------------------------------------------
  //  Two destinations, one pricing ladder. A plate, a shelf or a lacing bar is
  //  rack hardware; a Cisco switch racked on the same rail is equipment, and
  //  listing it under "Rack hardware" would hide a four-figure box in the
  //  section nobody totals. See [isRackHardwareCategory].
  final hardware = <CostLine>[];
  for (final line in groupRackItems(model.rackItems)) {
    final catalog = library.templateForModel(line.catalogModel);
    final override = settings.priceOverrides[line.key];

    final catalogPrice = catalog?.priceForTier(tier);

    final double price;
    final PriceSource source;
    if (override != null) {
      price = override;
      source = PriceSource.override;
    } else if (catalogPrice != null && catalogPrice.price > 0) {
      // The parts list is the live price; the copy on the placed item is what
      // it was when it went in, and only stands in when the entry is gone.
      price = catalogPrice.price;
      source = catalogPrice.fallback
          ? PriceSource.catalogOtherTier
          : PriceSource.catalog;
    } else if (line.price > 0) {
      price = line.price;
      source = PriceSource.override;
    } else {
      price = 0;
      source = PriceSource.none;
    }
    final furnishedBy = settings.furnishedLines[line.key];
    if (source == PriceSource.none && furnishedBy == null) {
      unpricedLines++;
      unpricedDevices += line.qty.toInt();
    }
    if (source == PriceSource.catalogOtherTier && furnishedBy == null) {
      otherTierLines++;
    }
    final costLine = CostLine(
      key: line.key,
      furnishedBy: furnishedBy,
      description: line.description,
      model: line.catalogModel,
      // The catalog's number, or — when the entry it came from is gone —
      // the one recorded on the placed item, same as its price.
      partNumber: catalog?.partNumber.isNotEmpty == true
          ? catalog!.partNumber
          : line.partNumber,
      manufacturer: catalog?.manufacturer ?? '',
      category: line.category,
      qty: line.qty,
      unitPrice: price,
      source: source,
    );
    if (isRackHardwareCategory(line.category)) {
      hardware.add(costLine);
    } else {
      equipment.add(costLine);
    }
  }

  // --- hardware and cable bought for the job but not on the drawing -------
  //  Same pricing ladder as everything else, so a spare shelf and a racked one
  //  cost the same and both follow a catalog revision.
  CostLine extraLine(CostLineItem item, String fallbackCategory) {
    final catalog = library.templateForModel(item.catalogModel);
    final catalogPrice = catalog?.priceForTier(tier);
    final override = settings.priceOverrides[item.id];

    final double price;
    final PriceSource source;
    if (override != null) {
      price = override;
      source = PriceSource.override;
    } else if (catalogPrice != null && catalogPrice.price > 0) {
      price = catalogPrice.price;
      source = catalogPrice.fallback
          ? PriceSource.catalogOtherTier
          : PriceSource.catalog;
    } else if (item.unitPrice > 0) {
      price = item.unitPrice;
      source = PriceSource.override;
    } else {
      price = 0;
      source = PriceSource.none;
    }
    final furnishedBy = settings.furnishedLines[item.id];
    if (source == PriceSource.none && furnishedBy == null) {
      unpricedLines++;
      unpricedDevices += item.qty.round();
    }
    if (source == PriceSource.catalogOtherTier && furnishedBy == null) {
      otherTierLines++;
    }

    return CostLine(
      key: item.id,
      furnishedBy: furnishedBy,
      description: item.description.trim().isEmpty
          ? (item.catalogModel.trim().isEmpty
                ? '(unnamed)'
                : item.catalogModel)
          : item.description,
      model: item.catalogModel,
      partNumber: catalog?.partNumber ?? '',
      manufacturer: catalog?.manufacturer ?? '',
      category: item.category.trim().isEmpty
          ? fallbackCategory
          : item.category,
      qty: item.qty,
      unitPrice: price,
      taxable: item.taxable,
      source: source,
      spare: item.spare,
    );
  }

  // Equipment quoted but not drawn, listed under the devices that are. It
  // lands in the equipment total rather than in "Other items" because that is
  // what it is, and because the equipment total is the figure people check.
  for (final item in settings.extraEquipment) {
    equipment.add(extraLine(item, ''));
  }

  for (final item in settings.extraHardware) {
    hardware.add(extraLine(item, kCategoryRackHardware));
  }

  // ONE PURCHASE ORDER PER VENDOR. Every line is on the list by now — drawn,
  // racked and typed — so the whole table reorders together rather than the
  // hand-typed Extron line sitting under the drawn ones.
  //
  // A line with no maker sorts LAST rather than first: an empty string sorts
  // above every letter, which would have put the boxes nobody has catalogd
  // yet at the top of a quote sorted by who makes them.
  if (settings.equipmentSort == CostEquipmentSort.manufacturer) {
    equipment.sort(compareByManufacturer);
  }

  // --- cabling: one line per lead the room buys, plus spares ---------------
  final cabling = <CostLine>[];
  if (settings.includeCabling) {
    final counts = countCableRuns(model);
    final nodesById = model.nodesById;
    // A spare for a type with no runs drawn is still a thing being bought, so
    // the two sets are merged rather than the spares only topping up runs.
    final types = <SignalType>{
      ...counts.keys,
      for (final key in settings.cableSpares.keys)
        if (cableSignalOfKey(key) != null) cableSignalOfKey(key)!,
    }.toList()..sort((a, b) => a.index.compareTo(b.index));

    for (final signal in types) {
      final drawn = (counts[signal] ?? 0).toDouble();
      // Every spare typed against any of this type's lines.
      final spareKeys = {
        for (final e in settings.cableSpares.entries)
          if (cableSignalOfKey(e.key) == signal && e.value > 0) e.key: e.value,
      };
      final spares =
          spareKeys.values.fold<double>(0, (sum, qty) => sum + qty);
      if (drawn + spares <= 0) continue;

      // WHICH LEAD EACH RUN IS BOUGHT AS. A room does not buy "HDMI cable",
      // it buys a 3 ft one and a 25 ft one at different prices — so runs are
      // grouped by the LENGTH TYPED ON THE DIAGRAM as well as by the catalog
      // entry they land on, and each group becomes a line of its own with its
      // own price box. A 25 ft run and a 50 ft run are two orders at two
      // prices even when the catalog has one entry for the type or none at
      // all, which is the usual case: the shipped catalog prices cable by the
      // made-up lead rather than by the signal, so before this every length
      // in the room collapsed onto one unpriceable line.
      final byGroup =
          <String, ({AvDeviceTemplate? entry, double lengthFt, double qty})>{};
      String groupId(AvDeviceTemplate? entry, double lengthFt) =>
          '${entry?.model ?? ''}|$lengthFt';
      void add(AvDeviceTemplate? entry, double lengthFt, double qty) {
        final id = groupId(entry, lengthFt);
        final at = byGroup[id];
        byGroup[id] = (
          entry: entry ?? at?.entry,
          lengthFt: lengthFt,
          qty: (at?.qty ?? 0) + qty,
        );
      }

      final options = library.cablesForSignal(signal);
      final splitByLength = options.where((t) => t.cableLengthFt > 0).length > 1;
      // The type's DEFAULT lead: the shortest stock length (bulk cable last).
      // Deterministic on purpose — it decides which line keeps the key
      // `cable:<signal>`, and therefore which line a price typed before
      // anybody measured a run still applies to.
      final defaultEntry =
          splitByLength ? options.first : library.cableForSignal(signal);

      /// Which lead a run of this length is bought as: whatever the room was
      /// told to buy it as, or the catalog's own answer. An override naming an
      /// entry that has since gone falls back rather than unpricing the line.
      AvDeviceTemplate? leadFor(double lengthFt) {
        final wanted = settings.cableEntries[cableEntryKey(signal, lengthFt)];
        final chosen =
            wanted == null ? null : library.templateForModel(wanted);
        if (chosen != null) return chosen;
        return splitByLength
            ? library.cableForRun(signal, lengthFt)
            : defaultEntry;
      }

      // Only the runs the canvas would actually draw, so these quantities add
      // up to the "drawn" figure instead of counting a cable whose ends have
      // been deleted.
      final runs = model.cables
          .where((c) =>
              c.signal == signal &&
              AvFlowModel.cableIsResolvable(c, nodesById))
          .toList();
      for (final c in runs) {
        add(leadFor(c.lengthFt), c.lengthFt, 1);
      }
      // Runs the diagram counts that are not cables on it go on the type's
      // default lead with no length, which is where the spares land too.
      final loose = drawn - runs.length.toDouble();
      if (loose > 0) add(leadFor(0), 0, loose);

      // THE TYPE'S MAIN LINE: the one keyed `cable:<signal>`, which carries
      // any price typed against the type before anybody measured a run. It is
      // the default lead's shortest group — the unmeasured one (length 0)
      // when there is one, since that is exactly the single line a room with
      // no lengths on its diagram has always had.
      String? mainId;
      var shortest = double.infinity;
      for (final e in byGroup.entries) {
        if ((e.value.entry?.model ?? '') != (defaultEntry?.model ?? '')) {
          continue;
        }
        if (e.value.lengthFt < shortest) {
          shortest = e.value.lengthFt;
          mainId = e.key;
        }
      }
      mainId ??= groupId(defaultEntry, 0);

      /// The line key a group is filed under, and what a spare typed against
      /// it is filed under too.
      String keyFor(String id, AvDeviceTemplate? entry, double lengthFt) {
        final parts = [
          if (entry != null &&
              entry.model.isNotEmpty &&
              entry.model != defaultEntry?.model)
            entry.model,
          if (lengthFt > 0) formatCableLength(lengthFt),
        ];
        return id == mainId || parts.isEmpty
            ? 'cable:${signal.name}'
            : 'cable:${signal.name}@${parts.join('@')}';
      }

      // SPARES ARE PER LINE, because a length is what gets ordered: two spare
      // 3 ft patch leads and two spare 50 ft runs are two decisions at two
      // prices. A spare typed against a length the diagram no longer has
      // still gets a line of its own rather than quietly joining the type's.
      final sparesByGroup = <String, double>{};
      for (final spare in spareKeys.entries) {
        var id = byGroup.keys.firstWhere(
          (id) => keyFor(id, byGroup[id]!.entry, byGroup[id]!.lengthFt) ==
              spare.key,
          orElse: () => '',
        );
        if (id.isEmpty) {
          final wanted = cableKeyParts(spare.key);
          final entry = wanted.model.isEmpty
              ? defaultEntry
              : (library.templateForModel(wanted.model) ?? defaultEntry);
          id = groupId(entry, wanted.lengthFt);
          add(entry, wanted.lengthFt, 0);
        }
        sparesByGroup[id] = (sparesByGroup[id] ?? 0) + spare.value;
        final at = byGroup[id]!;
        byGroup[id] = (
          entry: at.entry,
          lengthFt: at.lengthFt,
          qty: at.qty + spare.value,
        );
      }

      // The type's own line first, then shortest lead to longest: the order a
      // cable schedule is read in.
      final ordered = byGroup.entries.toList()
        ..sort((a, b) {
          if (a.key == mainId) return -1;
          if (b.key == mainId) return 1;
          final byLength = a.value.lengthFt.compareTo(b.value.lengthFt);
          return byLength != 0
              ? byLength
              : (a.value.entry?.model ?? '')
                  .toLowerCase()
                  .compareTo((b.value.entry?.model ?? '').toLowerCase());
        });

      for (final grouped in ordered) {
        final catalog = grouped.value.entry;
        final qty = grouped.value.qty;
        final runLengthFt = grouped.value.lengthFt;
        if (qty <= 0) continue;

        // The line key is what a typed price and a typed spare count are both
        // filed under, so the type's MAIN line keeps the key it has always
        // had — a room that priced its HDMI by hand keeps that price when
        // somebody later measures the runs. Every other group is keyed by
        // whatever makes it a separate order: the catalog entry, the run
        // length, or both.
        final key = keyFor(grouped.key, catalog, runLengthFt);
        final override = settings.priceOverrides[key];
        final catalogPrice = catalog?.priceForTier(tier);

        // THE LENGTH THIS LINE IS ABOUT: what the made-up lead is bought in,
        // or the run length the group was split on.
        final pricedLengthFt = (catalog?.cableLengthFt ?? 0) > 0
            ? catalog!.cableLengthFt
            : runLengthFt;
        final baseCable = baseBook.priceForCable(
          kSignalLabels[signal] ?? signal.name,
          pricedLengthFt,
          tier,
        );

        final double price;
        final PriceSource source;
        var otherTierCable = false;
        if (override != null) {
          price = override;
          source = PriceSource.override;
        } else if (catalogPrice != null && catalogPrice.price > 0) {
          price = catalogPrice.price;
          source = catalogPrice.fallback
              ? PriceSource.catalogOtherTier
              : PriceSource.catalog;
        } else if (baseCable.price > 0) {
          // The shop's own figure for a lead of this type and length. Same
          // rung as a device's base cost, and counted the same way: a total
          // built on these is a budget, and the page says so.
          price = baseCable.price;
          otherTierCable = baseCable.fallback;
          source = PriceSource.baseCost;
        } else {
          price = 0;
          source = PriceSource.none;
        }
        final furnishedBy = settings.furnishedLines[key];
        if (source == PriceSource.none && furnishedBy == null) {
          unpricedLines++;
          unpricedDevices += qty.round();
        }
        if (isEstimatedSource(source) && furnishedBy == null) estimatedLines++;
        if ((source == PriceSource.catalogOtherTier || otherTierCable) &&
            furnishedBy == null) {
          otherTierLines++;
        }

        // The runs behind this line, so it says what to order rather than
        // just how many. A group IS one length now, so this is that length
        // and how many of it; it is only worth printing next to a made-up
        // lead, where the lead's length and the run's are different facts.
        final drawnHere = runs.where((c) => c.lengthFt == runLengthFt).length;
        final showRuns = (catalog?.cableLengthFt ?? 0) > 0 &&
            runLengthFt > 0 &&
            drawnHere > 0;
        final lineSpares = sparesByGroup[grouped.key] ?? 0;

        cabling.add(
          CostLine(
            key: key,
            description: [
              catalog?.model.trim().isNotEmpty == true
                  ? catalog!.model
                  // "AV cabling (HDBaseT / DTP)" — the family a cable schedule
                  // files it under, then what it actually carries.
                  : [
                      cableTypeLabel(signal),
                      if (cableSignalSubLabel(signal).isNotEmpty)
                        '(${cableSignalSubLabel(signal)})',
                      'cable',
                    ].join(' '),
              // What the entry itself is bought in, when it is a made-up lead;
              // failing that the run length this line is for, which is the
              // only thing separating it from the type's other lines.
              if ((catalog?.cableLengthFt ?? 0) > 0)
                '- ${formatCableLength(catalog!.cableLengthFt)}'
              else if (runLengthFt > 0)
                '- ${formatCableLength(runLengthFt)}',
              if (showRuns) '[$drawnHere× ${formatCableLength(runLengthFt)}]',
              if (lineSpares > 0)
                '(${trimNumber(qty - lineSpares)} drawn + '
                    '${trimNumber(lineSpares)} spare)',
            ].join(' '),
            model: catalog?.model ?? '',
            partNumber: catalog?.partNumber ?? '',
            // Carried for the same reason the equipment lines carry it: a
            // cable order is split by who sells it like everything else, and
            // a line with no maker on it can only ever be tagged by hand.
            manufacturer: catalog?.manufacturer ?? '',
            category: kCategoryCable,
            qty: qty,
            unitPrice: price,
            source: source,
            furnishedBy: furnishedBy,
          ),
        );
      }
    }
  }

  // Miscellaneous cable is quoted whether or not the diagram's runs are —
  // it is a decision about the job, not a reading of the drawing.
  for (final item in settings.extraCables) {
    cabling.add(extraLine(item, kCategoryCable));
  }

  // Other items go through the same ladder as everything else, so a line
  // picked off the catalog (an AV/Misc entry, a license, a mount) follows a
  // catalog price revision instead of freezing whatever was typed the day it
  // was added. A line typed by hand has no catalog model and lands on its own
  // unit price exactly as before.
  final extras = [
    for (final item in settings.items) extraLine(item, ''),
  ];

  // --- labor: rate x techs x hours, off the shared rate card -------------
  final labor = <LaborCostLine>[];
  for (final line in settings.labor) {
    final rate = book.byId(line.rateId);
    final hourly = line.rateFrom(book);
    labor.add(
      LaborCostLine(
        id: line.id,
        roleName: rate?.name ?? (line.rateId.isEmpty ? 'Labor' : line.rateId),
        description: line.description,
        techs: line.techs,
        hours: line.hours,
        hourlyRate: hourly,
        taxable: line.taxable,
        // Hours with no rate behind them: real work, missing money.
        unrated: hourly <= 0 && line.totalHours() > 0,
      ),
    );
  }
  final laborTotal = _cents(labor.fold(0.0, (sum, l) => sum + l.total));
  final laborHours = labor.fold(0.0, (sum, l) => sum + l.totalHours);
  final unratedLabor = labor.where((l) => l.unrated).length;

  final equipmentTotal = _cents(
    equipment.fold(0.0, (sum, l) => sum + l.total),
  );
  final hardwareTotal = _cents(hardware.fold(0.0, (sum, l) => sum + l.total));
  final cablingTotal = _cents(cabling.fold(0.0, (sum, l) => sum + l.total));
  final extrasTotal = _cents(extras.fold(0.0, (sum, l) => sum + l.total));
  final subtotal = _cents(
    equipmentTotal + hardwareTotal + cablingTotal + extrasTotal + laborTotal,
  );

  // Every fee is a percentage of the SAME pre-tax subtotal — they don't
  // compound onto each other, because two 5% fees quoted on a job mean 10% of
  // the job, not 10.25%.
  final fees = <FeeAmount>[
    for (final fee in settings.fees)
      (fee: fee, amount: _cents(subtotal * fee.percent / 100)),
  ];
  final feeTotal = _cents(fees.fold(0.0, (sum, f) => sum + f.amount));

  final taxableExtras = _cents(
    extras.where((l) => l.taxable).fold(0.0, (sum, l) => sum + l.total),
  );
  final taxableLabor = _cents(
    labor.where((l) => l.taxable).fold(0.0, (sum, l) => sum + l.total),
  );
  final taxableFees = _cents(
    fees.where((f) => f.fee.taxable).fold(0.0, (sum, f) => sum + f.amount),
  );
  // Hardware and cable are goods like any other device: taxed on the same
  // terms as the equipment they go with.
  final taxableBase = _cents(
    equipmentTotal +
        hardwareTotal +
        cablingTotal +
        taxableExtras +
        taxableLabor +
        taxableFees,
  );
  final tax = _cents(taxableBase * settings.taxPercent / 100);

  return CostEstimate(
    currency: settings.currency,
    tier: tier,
    equipment: equipment,
    hardware: hardware,
    cabling: cabling,
    extras: extras,
    labor: labor,
    fees: fees,
    equipmentTotal: equipmentTotal,
    hardwareTotal: hardwareTotal,
    cablingTotal: cablingTotal,
    extrasTotal: extrasTotal,
    laborTotal: laborTotal,
    laborHours: laborHours,
    unratedLabor: unratedLabor,
    subtotal: subtotal,
    feeTotal: feeTotal,
    taxableBase: taxableBase,
    taxPercent: settings.taxPercent,
    taxLabel: settings.taxLabel,
    tax: tax,
    grandTotal: _cents(subtotal + feeTotal + tax),
    unpricedLines: unpricedLines,
    unpricedDevices: unpricedDevices,
    estimatedLines: estimatedLines,
    otherTierLines: otherTierLines,
    excludedLines: excludedLines,
    excludedDevices: excludedDevices,
  );
}

// ---------------------------------------------------------------------------
//  FORMATTING
// ---------------------------------------------------------------------------

/// "$12,480.00". Hand-rolled because the app carries no intl dependency and
/// an estimate with an unseparated five-figure number is hard to read.
String formatMoney(double value, [String currency = r'$']) {
  final negative = value < 0;
  final fixed = value.abs().toStringAsFixed(2);
  final parts = fixed.split('.');
  final digits = parts[0];
  final buffer = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return '${negative ? '-' : ''}$currency$buffer.${parts[1]}';
}

/// A number the way it should sit in a text field: "90", not "90.0", and
/// "12.5" kept as "12.5". Used for the watts and percentage fields, where a
/// trailing ".0" is noise the user then has to edit around.
String trimNumber(num value) {
  final fixed = value.toStringAsFixed(2);
  if (!fixed.contains('.')) return fixed;
  return fixed
      .replaceAll(RegExp(r'0+$'), '')
      .replaceAll(RegExp(r'\.$'), '');
}

/// Trims a percentage to something a quote would print: 8.25%, 3%, 0.5%.
String formatPercent(double value) => '${trimNumber(value)}%';

/// Money for a report cell: a NUMBER, so the workbook can be summed in Excel
/// rather than being text that merely looks like money, carrying the currency
/// format so the cell still READS as money — and its own formatted text, which
/// is what the plain-text report and the clipboard copy print.
XlsxMoney money(double value, [String currency = r'$']) {
  final rounded = _cents(value);
  return XlsxMoney(
    value: rounded,
    text: formatMoney(rounded, currency),
    symbol: currency,
  );
}

// ---------------------------------------------------------------------------
//  REPORT SECTIONS
// ---------------------------------------------------------------------------

/// The Cost Estimate sheet: what is being bought, what is being added on top,
/// and what it comes to.
List<ReportSection> costReportSections(CostEstimate estimate) {
  // Nothing priced, nothing added, no fees, no tax: a totals table of zeros
  // says less than nothing. The caller shows an explanation instead.
  if (estimate.equipment.isEmpty &&
      estimate.hardware.isEmpty &&
      estimate.cabling.isEmpty &&
      estimate.extras.isEmpty &&
      estimate.labor.isEmpty &&
      estimate.fees.isEmpty &&
      estimate.taxPercent == 0) {
    return const [];
  }

  final currency = estimate.currency;

  /// Every figure on the sheet, in the room's currency: a number Excel can
  /// sum, formatted so the cell says what it is. The columns no longer repeat
  /// the symbol in their headings because the cells now carry it.
  XlsxMoney cash(double value) => money(value, currency);

  final sections = <ReportSection>[
    (
      title: 'Equipment',
      header: const [
        'Device',
        'Model',
        // What actually goes on the purchase order — a model name is what the
        // room is designed around, a part number is what gets ordered.
        'Part number',
        'Qty',
        'Unit price',
        'Extended',
        'Price from',
      ],
      rows: [
        for (final line in estimate.equipment)
          [
            // The split, where there is one: a quote for four displays in a
            // room that draws three has to say which one nobody will find on
            // the drawing, or the count reads as a mistake.
            line.spareQty > 0
                ? '${line.description} '
                      '(${trimNumber(line.drawnQty)} drawn + '
                      '${trimNumber(line.spareQty)} spare)'
                : line.description,
            line.model,
            line.partNumber,
            line.qty,
            cash(line.unitPrice),
            cash(line.total),
            priceFromLabel(line),
          ],
      ],
    ),
    (
      title: 'Rack Hardware',
      header: const [
        'Item',
        'Kind',
        'Model',
        'Part number',
        'Qty',
        'Unit price',
        'Extended',
        'Price from',
      ],
      rows: [
        for (final line in estimate.hardware)
          [
            line.description,
            line.category,
            line.model,
            line.partNumber,
            line.qty,
            cash(line.unitPrice),
            cash(line.total),
            priceFromLabel(line),
          ],
      ],
    ),
    (
      title: 'Cabling',
      header: const [
        'Cable',
        'Part number',
        'Runs',
        'Unit price',
        'Extended',
        'Price from',
      ],
      rows: [
        for (final line in estimate.cabling)
          [
            line.description,
            line.partNumber,
            line.qty,
            cash(line.unitPrice),
            cash(line.total),
            priceFromLabel(line),
          ],
      ],
    ),
    (
      title: 'Labor',
      header: const [
        'Role',
        'Scope',
        'Techs',
        'Hours ea.',
        'Total hours',
        'Rate per hour',
        'Extended',
        'Taxable',
      ],
      rows: [
        for (final line in estimate.labor)
          [
            line.roleName,
            line.description,
            line.techs,
            line.hours,
            line.totalHours,
            line.unrated ? 'no rate set' : cash(line.hourlyRate),
            cash(line.total),
            line.taxable ? 'Yes' : 'No',
          ],
      ],
    ),
    (
      title: 'Other Items',
      header: const [
        'Description',
        'Category',
        'Part number',
        'Qty',
        'Unit price',
        'Extended',
        'Taxable',
      ],
      rows: [
        for (final line in estimate.extras)
          [
            line.description,
            line.category,
            line.partNumber,
            line.qty,
            cash(line.unitPrice),
            cash(line.total),
            line.taxable ? 'Yes' : 'No',
          ],
      ],
    ),
  ];

  final totals = <List<dynamic>>[
    ['Priced at', kPricingTierLabels[estimate.tier] ?? estimate.tier.name],
    ['Equipment', cash(estimate.equipmentTotal)],
    if (estimate.hardware.isNotEmpty)
      ['Rack hardware', cash(estimate.hardwareTotal)],
    if (estimate.cabling.isNotEmpty)
      ['Cabling', cash(estimate.cablingTotal)],
    if (estimate.labor.isNotEmpty) ...[
      [
        'Labor (${trimNumber(estimate.laborHours)} h)',
        cash(estimate.laborTotal),
      ],
    ],
    if (estimate.extras.isNotEmpty) ['Other items', cash(estimate.extrasTotal)],
    ['Subtotal (before fees and tax)', cash(estimate.subtotal)],
    for (final f in estimate.fees)
      [
        '${f.fee.name} (${formatPercent(f.fee.percent)} of subtotal)'
            '${f.fee.taxable ? '' : ' — not taxed'}',
        cash(f.amount),
      ],
    if (estimate.fees.length > 1) ['Fees total', cash(estimate.feeTotal)],
    if (estimate.taxPercent > 0) ...[
      ['Taxable amount', cash(estimate.taxableBase)],
      [
        '${estimate.taxLabel} (${formatPercent(estimate.taxPercent)})',
        cash(estimate.tax),
      ],
    ],
    ['TOTAL', cash(estimate.grandTotal)],
    if (estimate.unpricedLines > 0)
      [
        'Not included - devices with no price',
        '${estimate.unpricedDevices} device'
            '${estimate.unpricedDevices == 1 ? '' : 's'} '
            'on ${estimate.unpricedLines} line'
            '${estimate.unpricedLines == 1 ? '' : 's'}',
      ],
    if (estimate.excludedDevices > 0)
      [
        'Not quoted - on the drawing, not on this contract',
        '${estimate.excludedDevices} device'
            '${estimate.excludedDevices == 1 ? '' : 's'} '
            'on ${estimate.excludedLines} line'
            '${estimate.excludedLines == 1 ? '' : 's'} marked as existing, '
            'owner-furnished or by others',
      ],
    if (estimate.unratedLabor > 0)
      [
        'Not included - labor with no rate',
        '${estimate.unratedLabor} line'
            '${estimate.unratedLabor == 1 ? '' : 's'} of hours whose job type '
            'has no rate set on the rate card',
      ],
    if (estimate.otherTierLines > 0)
      [
        'Check before quoting - priced at the other tier',
        '${estimate.otherTierLines} line'
            '${estimate.otherTierLines == 1 ? '' : 's'} had no '
            '${kPricingTierShort[estimate.tier]} price in the catalog and were '
            'costed at the other one',
      ],
    if (estimate.estimatedLines > 0)
      [
        'Budget figure, not a quote',
        '${estimate.estimatedLines} line'
            '${estimate.estimatedLines == 1 ? '' : 's'} priced from the base '
            'cost for the category rather than a chosen model',
      ],
  ];

  sections.add((title: 'Totals', header: ['Item', 'Amount'], rows: totals));
  return sections.where((s) => s.rows.isNotEmpty).toList();
}
