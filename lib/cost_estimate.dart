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

  const CostLineItem({
    required this.id,
    required this.description,
    this.category = '',
    this.qty = 1,
    this.unitPrice = 0,
    this.taxable = true,
    this.catalogModel = '',
  });

  double get total => qty * unitPrice;

  CostLineItem copyWith({
    String? description,
    String? category,
    double? qty,
    double? unitPrice,
    bool? taxable,
    String? catalogModel,
  }) => CostLineItem(
    id: id,
    description: description ?? this.description,
    category: category ?? this.category,
    qty: qty ?? this.qty,
    unitPrice: unitPrice ?? this.unitPrice,
    taxable: taxable ?? this.taxable,
    catalogModel: catalogModel ?? this.catalogModel,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'description': description,
    if (category.isNotEmpty) 'category': category,
    'qty': qty,
    'unitPrice': unitPrice,
    'taxable': taxable,
    if (catalogModel.isNotEmpty) 'catalogModel': catalogModel,
  };

  factory CostLineItem.fromJson(Map<String, dynamic> json) => CostLineItem(
    id: json['id']?.toString() ?? '',
    description: json['description']?.toString() ?? '',
    category: json['category']?.toString() ?? '',
    qty: (json['qty'] as num?)?.toDouble() ?? 1,
    unitPrice: (json['unitPrice'] as num?)?.toDouble() ?? 0,
    taxable: json['taxable'] != false,
    catalogModel: json['catalogModel']?.toString() ?? '',
  );
}

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

  /// Signal type name -> extra runs to buy beyond what the diagram shows.
  /// Spares are a decision, not a diagram fact, so they live here rather than
  /// being inferred: "three more HDMI leads because two always go missing" is
  /// the sort of thing a quote should say out loud.
  final Map<String, double> cableSpares;

  RoomCostSettings({
    this.currency = r'$',
    this.taxLabel = 'Sales tax',
    this.taxPercent = 0,
    this.includeCabling = true,
    List<CostFee>? fees,
    Map<String, double>? priceOverrides,
    List<CostLineItem>? items,
    List<LaborLine>? labor,
    Map<String, double>? cableSpares,
    List<CostLineItem>? extraEquipment,
    List<CostLineItem>? extraHardware,
    List<CostLineItem>? extraCables,
  }) : fees = fees ?? [],
       priceOverrides = priceOverrides ?? {},
       items = items ?? [],
       labor = labor ?? [],
       cableSpares = cableSpares ?? {},
       extraEquipment = extraEquipment ?? [],
       extraHardware = extraHardware ?? [],
       extraCables = extraCables ?? [];

  bool get isEmpty =>
      taxPercent == 0 &&
      fees.isEmpty &&
      priceOverrides.isEmpty &&
      items.isEmpty &&
      labor.isEmpty &&
      cableSpares.isEmpty &&
      extraEquipment.isEmpty &&
      extraHardware.isEmpty &&
      extraCables.isEmpty;

  void clear() {
    currency = r'$';
    taxLabel = 'Sales tax';
    taxPercent = 0;
    includeCabling = true;
    fees.clear();
    priceOverrides.clear();
    items.clear();
    labor.clear();
    cableSpares.clear();
    extraEquipment.clear();
    extraHardware.clear();
    extraCables.clear();
  }

  Map<String, dynamic> toJson() => {
    'currency': currency,
    'taxLabel': taxLabel,
    'taxPercent': taxPercent,
    'includeCabling': includeCabling,
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
    final spares = json['cableSpares'];
    if (spares is Map) {
      spares.forEach((key, value) {
        final qty = (value as num?)?.toDouble();
        if (qty != null && qty > 0) cableSpares[key.toString()] = qty;
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
List<RackItemGroup> groupRackItems(List<RackItem> items) {
  final grouped = <String, List<RackItem>>{};
  for (final item in items) {
    final key = item.catalogModel.trim().isNotEmpty
        ? 'rackitem:model:${item.catalogModel.trim().toLowerCase()}'
        : 'rackitem:label:${item.label.trim().toLowerCase()}|${item.rackUnits}';
    grouped.putIfAbsent(key, () => []).add(item);
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
  PriceSource.catalogOtherTier: 'Catalog — other tier',
  PriceSource.baseCost: 'Base cost',
  PriceSource.none: 'Not priced',
};

/// True when the line is costed at a category average rather than a real
/// price. The estimate counts these separately: a budget built on base costs is
/// a budget, and should not be read as a quote.
bool isEstimatedSource(PriceSource s) => s == PriceSource.baseCost;

/// True when the figure came from the catalog at all, either tier.
bool isCatalogSource(PriceSource s) =>
    s == PriceSource.catalog || s == PriceSource.catalogOtherTier;

class CostLine {
  final String key;
  final String description;
  final String model;

  /// The manufacturer's ordering code, off the catalog entry. Carried on the
  /// line rather than looked up when the report is written, so the number on
  /// the estimate is the one the price came from.
  final String partNumber;
  final String category;
  final double qty;
  final double unitPrice;
  final bool taxable;
  final PriceSource source;

  const CostLine({
    required this.key,
    required this.description,
    this.model = '',
    this.partNumber = '',
    this.category = '',
    required this.qty,
    required this.unitPrice,
    this.taxable = true,
    this.source = PriceSource.none,
  });

  double get total => qty * unitPrice;
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
    final basePrice = baseBook.priceFor(category, tier);

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
    if (source == PriceSource.none) {
      unpricedLines++;
      unpricedDevices += group.qty;
    }
    if (isEstimatedSource(source)) estimatedLines++;
    if (otherTier) otherTierLines++;

    equipment.add(
      CostLine(
        key: group.key,
        description: group.label,
        model: group.model,
        partNumber: catalog?.partNumber ?? '',
        category: category,
        qty: group.qty.toDouble(),
        unitPrice: price,
        source: source,
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
    if (source == PriceSource.none) {
      unpricedLines++;
      unpricedDevices += line.qty.toInt();
    }
    if (source == PriceSource.catalogOtherTier) otherTierLines++;
    final costLine = CostLine(
      key: line.key,
      description: line.description,
      model: line.catalogModel,
      // The catalog's number, or — when the entry it came from is gone —
      // the one recorded on the placed item, same as its price.
      partNumber: catalog?.partNumber.isNotEmpty == true
          ? catalog!.partNumber
          : line.partNumber,
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
    if (source == PriceSource.none) {
      unpricedLines++;
      unpricedDevices += item.qty.round();
    }
    if (source == PriceSource.catalogOtherTier) otherTierLines++;

    return CostLine(
      key: item.id,
      description: item.description.trim().isEmpty
          ? (item.catalogModel.trim().isEmpty
                ? '(unnamed)'
                : item.catalogModel)
          : item.description,
      model: item.catalogModel,
      partNumber: catalog?.partNumber ?? '',
      category: item.category.trim().isEmpty
          ? fallbackCategory
          : item.category,
      qty: item.qty,
      unitPrice: price,
      taxable: item.taxable,
      source: source,
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

  // --- cabling: one line per signal type on the diagram, plus spares -------
  final cabling = <CostLine>[];
  if (settings.includeCabling) {
    final counts = countCableRuns(model);
    // A spare for a type with no runs drawn is still a thing being bought, so
    // the two sets are merged rather than the spares only topping up runs.
    final types = <SignalType>{
      ...counts.keys,
      for (final name in settings.cableSpares.keys) signalFromName(name),
    }.toList()..sort((a, b) => a.index.compareTo(b.index));

    for (final signal in types) {
      final drawn = (counts[signal] ?? 0).toDouble();
      final spares = settings.cableSpares[signal.name] ?? 0;
      final qty = drawn + spares;
      if (qty <= 0) continue;

      final key = 'cable:${signal.name}';
      final catalog = library.cableForSignal(signal);
      final override = settings.priceOverrides[key];

      final catalogPrice = catalog?.priceForTier(tier);

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
      } else {
        price = 0;
        source = PriceSource.none;
      }
      if (source == PriceSource.none) {
        unpricedLines++;
        unpricedDevices += qty.round();
      }
      if (source == PriceSource.catalogOtherTier) otherTierLines++;

      // The lead lengths this type is drawn in, so the line says what to order
      // rather than just how many. Runs with no length set are left out of the
      // note — they are counted in the quantity either way.
      final byLength = <double, int>{};
      for (final c in model.cables) {
        if (c.signal != signal || c.lengthFt <= 0) continue;
        byLength[c.lengthFt] = (byLength[c.lengthFt] ?? 0) + 1;
      }
      final lengths = (byLength.keys.toList()..sort())
          .map((ft) => '${byLength[ft]}× ${formatCableLength(ft)}')
          .join(', ');

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
            if (lengths.isNotEmpty) '[$lengths]',
            if (spares > 0)
              '(${trimNumber(drawn)} drawn + ${trimNumber(spares)} spare)',
          ].join(' '),
          model: catalog?.model ?? '',
          partNumber: catalog?.partNumber ?? '',
          category: kCategoryCable,
          qty: qty,
          unitPrice: price,
          source: source,
        ),
      );
    }
  }

  // Miscellaneous cable is quoted whether or not the diagram's runs are —
  // it is a decision about the job, not a reading of the drawing.
  for (final item in settings.extraCables) {
    cabling.add(extraLine(item, kCategoryCable));
  }

  // Other items go through the same ladder as everything else, so a line
  // picked off the catalog (an AV/Misc entry, a licence, a mount) follows a
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
            line.description,
            line.model,
            line.partNumber,
            line.qty,
            cash(line.unitPrice),
            cash(line.total),
            kPriceSourceLabels[line.source] ?? '',
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
            kPriceSourceLabels[line.source] ?? '',
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
            kPriceSourceLabels[line.source] ?? '',
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
        'Not included — devices with no price',
        '${estimate.unpricedDevices} device'
            '${estimate.unpricedDevices == 1 ? '' : 's'} '
            'on ${estimate.unpricedLines} line'
            '${estimate.unpricedLines == 1 ? '' : 's'}',
      ],
    if (estimate.excludedDevices > 0)
      [
        'Not quoted — on the drawing, not on this contract',
        '${estimate.excludedDevices} device'
            '${estimate.excludedDevices == 1 ? '' : 's'} '
            'on ${estimate.excludedLines} line'
            '${estimate.excludedLines == 1 ? '' : 's'} marked as existing, '
            'owner-furnished or by others',
      ],
    if (estimate.unratedLabor > 0)
      [
        'Not included — labor with no rate',
        '${estimate.unratedLabor} line'
            '${estimate.unratedLabor == 1 ? '' : 's'} of hours whose job type '
            'has no rate set on the rate card',
      ],
    if (estimate.otherTierLines > 0)
      [
        'Check before quoting — priced at the other tier',
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
