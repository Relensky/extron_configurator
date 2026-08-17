import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'av_flow_model.dart';

/// ============================================================================
///  AV DEVICE LIBRARY
/// ============================================================================
///  Answers the one question config.json cannot: "what connectors does this
///  box actually have?" Ports for a node are resolved in this order:
///
///    1. Per-node overrides saved in the `<config>_av_flow.json` sidecar (the
///       port editor's output) — handled by the caller, not here.
///    2. An exact model match in an external `av_devices.json`.
///    3. An exact model match in the built-in table below.
///    4. A family-generic fallback derived from the config section prefix,
///       with the port COUNT inferred from the model number where the naming
///       makes that possible (a "CrossPoint 108" is 10 in / 8 out).
///
///  The external file follows the same convention as ui_schema.json — drop
///  `av_devices.json` in the Root Folder and it wins over the built-ins, so
///  a new model can be described without rebuilding the app:
///
///  {
///    "devices": [
///      { "model": "DTP CrossPoint 108 4K IPCP MA 70",
///        "manufacturer": "Extron", "partNumber": "60-1439-13",
///        "category": "Switcher", "rackUnits": 2,
///        "clearanceAboveU": 1, "clearanceBelowU": 0,
///        "powerWatts": 90, "price": 8500,
///        "ports": [
///          {"id":"in_hdmi_1","label":"HDMI IN 1","signal":"hdmi","direction":"input"},
///          {"id":"out_dtp_1","label":"DTP OUT 1","signal":"hdbaset","direction":"output"}
///        ] }
///    ],
///    "familyDefaults": {
///      "CAMERADEVICE_": { "rackUnits": 0, "ports": [ ... ] }
///    }
///  }
///
///  `cableSignal` + `cableLengthFt` are how a cable type is broken down: one
///  entry per made-up length (3 ft, 6 ft, 25 ft), each with its own model and
///  price, and the estimate buys every drawn run the shortest one that reaches
///  it. A cable entry with no length is bulk off a spool.
///
///  `clearanceAboveU` / `clearanceBelowU` are the rails this model wants left
///  EMPTY around it in a frame — the amplifier that vents upwards, the drawer
///  whose lid opens. The rack elevation shades them light red as a warning and
///  still allows the placement; see [AvDeviceTemplate.clearanceAboveU].
///
///  `powerWatts` and `price` are what the power estimate and the room cost
///  estimate are built from; both default to 0, meaning "not recorded", and
///  the reports say how many devices are still missing them rather than
///  totalling a blank as free and cold. The **Device Editor** tab writes this
///  file, so none of it has to be typed by hand — and can merge another
///  engineer's copy of it into yours, one difference at a time.
///
///  "signal" accepts any [SignalType] name plus the friendly aliases in
///  [signalFromName] (dtp, hdbt, dp, aes, rs232, ...). "direction" is
///  input/output/bidirectional; "side" is optional and defaults to left for
///  inputs and right for outputs.
///
///  THE BUILT-IN TABLE IS A STARTING POINT, NOT A SPEC SHEET. It covers the
///  models present in the shipped config.json with a sensible connector set
///  so the tab is usable out of the box. Correct anything that doesn't match
///  your hardware in av_devices.json (or in the per-node port editor, which
///  can export a ready-made entry).
/// ============================================================================

// ---------------------------------------------------------------------------
//  CATEGORIES THE APP ITSELF KEYS OFF
// ---------------------------------------------------------------------------
//  Category is free text — a catalog can say whatever it likes — but three
//  values have behavior attached, so they are named once here rather than
//  spelled out at every call site:
//
//    * RACK HARDWARE is what the rack editor's parts list offers: vent plates,
//      blanks, shelves, drawers. Entries carry a rack height and a price and no
//      connectors, because none of it carries signal.
//    * CONSUMABLE is the box of things a job eats — velcro, ties, screws,
//      labels — priced per unit and added by quantity rather than drawn.
//    * CABLE entries carry a [AvDeviceTemplate.cableSignal], which is how the
//      estimate prices the runs on the AV flow: one line per signal type, the
//      quantity counted off the diagram, plus whatever spares are asked for.
//    * AV / MISC is the catch-all for things a job is billed for that are not
//      a box on a diagram and not one of the above: a mount, a licence, a
//      subscription, a rental, a trip charge somebody quoted as a figure. They
//      carry a price and nothing else, and the estimate's "Other items" card
//      picks them off the catalog so a price agreed once is not retyped per
//      room.

const String kCategoryRackHardware = 'Rack hardware';
const String kCategoryConsumable = 'Consumable';
const String kCategoryCable = 'Cable';
const String kCategoryMisc = 'AV / Misc';

// ---------------------------------------------------------------------------
//  PRICING TIERS
// ---------------------------------------------------------------------------
//  Every entry carries TWO published prices, because every quote gets written
//  against one of two numbers: the manufacturer's list price, and the
//  education price the institution actually pays. Keeping both on the entry —
//  rather than one price and a discount percentage somewhere else — means an
//  estimate can be switched between them without re-entering anything, and a
//  year later it is still clear which one a given quote was written at.
//
//  Neither is a room's negotiated price. That still lives on the room (see
//  RoomCostSettings.priceOverrides) and wins over both.

enum PricingTier { msrp, education }

const Map<PricingTier, String> kPricingTierLabels = {
  PricingTier.msrp: 'MSRP (list price)',
  PricingTier.education: 'Education price',
};

/// Short form for a table column or a report line.
const Map<PricingTier, String> kPricingTierShort = {
  PricingTier.msrp: 'MSRP',
  PricingTier.education: 'Edu',
};

/// Currency symbols offered in App Config. Not a complete list of the world's
/// currencies — the field beside it takes anything typed — just the ones worth
/// a click.
const List<String> kCurrencySymbols = [r'$', '€', '£', '¥', 'CHF', 'kr', 'CA\$',
    'A\$', 'NZ\$', 'R', '₹', '₩', '₽', 'R\$'];

const Map<String, String> kCurrencyNames = {
  r'$': 'US dollar',
  '€': 'Euro',
  '£': 'Pound sterling',
  '¥': 'Yen / Yuan',
  'CHF': 'Swiss franc',
  'kr': 'Krone / Krona',
  'CA\$': 'Canadian dollar',
  'A\$': 'Australian dollar',
  'NZ\$': 'New Zealand dollar',
  'R': 'Rand',
  '₹': 'Rupee',
  '₩': 'Won',
  '₽': 'Ruble',
  'R\$': 'Real',
};

PricingTier pricingTierFromName(String? name) =>
    name?.trim().toLowerCase() == 'education'
    ? PricingTier.education
    : PricingTier.msrp;

/// The categories offered even when nothing is filed under them yet. The rack
/// kinds are listed individually ('Vent plate', 'Shelf', ...) because that is
/// how the rack editor groups its parts list — "Rack hardware" as a single
/// bucket would put a drawer and a blanking plate in the same drawer.
const List<String> kWellKnownCategories = [
  ...kRackItemCategories,
  kCategoryConsumable,
  kCategoryCable,
  kCategoryMisc,
];

/// A model's connector set, and everything else about the box that the room
/// config never records: how tall it is, what it draws, and what it costs.
///
/// [powerWatts] and [price] are estimates a room is planned from, not
/// measurements — 0 means "nobody has filled this in", which is why the
/// reports count unpriced and unmetered devices instead of quietly totalling
/// them as free and cold.
class AvDeviceTemplate {
  final String model;
  final String manufacturer;

  /// Manufacturer part / SKU, so a price list line can be matched to a quote.
  final String partNumber;

  /// Free-text grouping for the catalog list and the cost estimate
  /// ('Switcher', 'Camera', 'Cable & connectivity', ...).
  final String category;

  final int rackUnits;

  /// Rails this model wants kept EMPTY above and below it, and 0 when it does
  /// not care.
  ///
  /// A rack elevation says what fits; it says nothing about what should not be
  /// touching. An amplifier that vents upwards, a shelf whose lid opens, a
  /// projector-style intake on the top cover — all of them fit perfectly well
  /// under the next box and all of them fail on site. The catalog is where that
  /// belongs, because it is a fact about the MODEL: whoever records the rack
  /// height knows the clearance at the same moment, and every room that racks
  /// the part inherits it.
  ///
  /// A WARNING and not a rule. The rack shades the rails light red and lets
  /// anything be dropped there anyway — the person in front of the frame knows
  /// things the catalog does not, and a tool that refuses a placement somebody
  /// has decided on is a tool they stop recording placements in.
  final int clearanceAboveU;
  final int clearanceBelowU;

  /// Typical draw in watts; 0 = not recorded.
  final double powerWatts;

  /// Published heat output in BTU/hr; 0 = derive it from [powerWatts].
  final double btuPerHour;

  /// How the box takes power. Every entry has an inlet unless it is genuinely
  /// passive, and [PowerInput.poe] is the toggle for gear fed off the network
  /// switch rather than the room's circuit.
  final PowerInput powerInput;

  /// Manufacturer's list price (MSRP) in the catalog's currency; 0 = not
  /// priced. Kept under the plain name `price` so catalogs written before
  /// there were two tiers still read.
  final double price;

  /// The education / institutional price; 0 = not recorded. See [PricingTier].
  final double educationPrice;

  /// End-of-life: still in the catalog so old rooms keep resolving their
  /// connectors and prices, but kept out of the pickers that specify NEW work.
  /// Deleting the entry instead would silently strip the ports and the price
  /// from every room that already used it.
  final bool retired;

  /// For a [kCategoryCable] entry: which signal type this cable carries, so
  /// the estimate can count the runs of that type on the AV flow and price
  /// them. Null on everything else.
  final SignalType? cableSignal;

  /// For a cable entry: the length it is BOUGHT in, in feet. 0 means the entry
  /// is not a made-up lead — bulk cable off a spool, or a type nobody has
  /// broken down yet.
  ///
  /// A room does not buy "HDMI cable", it buys a 3 ft one and a 25 ft one at
  /// different prices, and quoting every run at one figure is wrong in both
  /// directions at once. Several entries can share a [cableSignal] and differ
  /// only in this: the estimate then puts each drawn run on the shortest stock
  /// length that reaches, and prices it at that entry.
  final double cableLengthFt;

  /// The page this entry's figures were read off — the manufacturer's product
  /// page for the Extron gear, projectorcentral.com for the projectors. A
  /// price, a wattage and a heat figure all came from somewhere, and next year
  /// somebody has to check whether they still hold; keeping the link on the
  /// entry is the difference between re-checking a spec and hunting for it.
  /// Empty when nobody has recorded one.
  final String url;

  final String notes;

  final List<AvPort> ports;

  /// True when this entry came from av_devices.json or was edited in the
  /// Device Editor — i.e. it is the user's, and gets written back on save.
  /// Built-in entries stay false so a later app build can still improve them.
  final bool custom;

  const AvDeviceTemplate({
    required this.model,
    this.manufacturer = '',
    this.partNumber = '',
    this.category = '',
    this.rackUnits = 0,
    this.clearanceAboveU = 0,
    this.clearanceBelowU = 0,
    this.powerWatts = 0,
    this.btuPerHour = 0,
    this.powerInput = PowerInput.mains,
    this.price = 0,
    this.educationPrice = 0,
    this.retired = false,
    this.cableSignal,
    this.cableLengthFt = 0,
    this.url = '',
    this.notes = '',
    required this.ports,
    this.custom = false,
  });

  /// True when this entry is a length of cable rather than a box.
  bool get isCable => category.trim() == kCategoryCable;

  /// True when this entry is a billable line rather than a piece of equipment
  /// — a licence, a mount, a trip charge. It has a price and no connectors,
  /// and never appears in a picker that puts something on a diagram.
  bool get isMiscItem => category.trim() == kCategoryMisc;

  /// True when this belongs on the rack editor's parts list — a vent plate, a
  /// blank, a shelf, a drawer, anything in [kRackItemCategories].
  bool get isRackHardware => kRackItemCategories.contains(category.trim());

  bool get isConsumable => category.trim() == kCategoryConsumable;

  /// The price for [tier], and whether it had to fall back to the other tier
  /// because the one asked for was never recorded.
  ///
  /// Falling back rather than reporting nothing is deliberate: a catalog part
  /// way through being priced should still produce a usable estimate. Saying
  /// so is the other half — the line reports which number it used, so nobody
  /// quotes an education job at list without noticing.
  ({double price, bool fallback}) priceForTier(PricingTier tier) {
    final wanted = tier == PricingTier.education ? educationPrice : price;
    if (wanted > 0) return (price: wanted, fallback: false);
    final other = tier == PricingTier.education ? price : educationPrice;
    if (other > 0) return (price: other, fallback: true);
    return (price: 0, fallback: false);
  }

  /// True when both tiers are blank.
  bool get isUnpriced => price <= 0 && educationPrice <= 0;

  /// Heat this model puts into a rack: its published figure when there is
  /// one, otherwise the watts converted.
  double get effectiveBtu =>
      btuPerHour > 0 ? btuPerHour : powerWatts * kWattsToBtu;

  /// Signal connectors only — the power inlet is not something you patch, so
  /// counting it as an input would overstate every device by one.
  int get inputCount => ports
      .where((p) => p.direction != PortDirection.output && !p.isPowerInlet)
      .length;
  int get outputCount =>
      ports.where((p) => p.direction != PortDirection.input).length;

  AvDeviceTemplate copyWith({
    String? model,
    String? manufacturer,
    String? partNumber,
    String? category,
    int? rackUnits,
    int? clearanceAboveU,
    int? clearanceBelowU,
    double? powerWatts,
    double? btuPerHour,
    PowerInput? powerInput,
    double? price,
    double? educationPrice,
    bool? retired,
    SignalType? cableSignal,
    double? cableLengthFt,
    bool clearCableSignal = false,
    String? url,
    String? notes,
    List<AvPort>? ports,
    bool? custom,
  }) => AvDeviceTemplate(
    model: model ?? this.model,
    manufacturer: manufacturer ?? this.manufacturer,
    partNumber: partNumber ?? this.partNumber,
    category: category ?? this.category,
    rackUnits: rackUnits ?? this.rackUnits,
    clearanceAboveU: clearanceAboveU ?? this.clearanceAboveU,
    clearanceBelowU: clearanceBelowU ?? this.clearanceBelowU,
    powerWatts: powerWatts ?? this.powerWatts,
    btuPerHour: btuPerHour ?? this.btuPerHour,
    powerInput: powerInput ?? this.powerInput,
    price: price ?? this.price,
    educationPrice: educationPrice ?? this.educationPrice,
    retired: retired ?? this.retired,
    cableSignal: clearCableSignal ? null : (cableSignal ?? this.cableSignal),
    cableLengthFt: cableLengthFt ?? this.cableLengthFt,
    url: url ?? this.url,
    notes: notes ?? this.notes,
    ports: ports ?? this.ports,
    custom: custom ?? this.custom,
  );

  Map<String, dynamic> toJson() => {
    'model': model,
    if (manufacturer.isNotEmpty) 'manufacturer': manufacturer,
    if (partNumber.isNotEmpty) 'partNumber': partNumber,
    if (category.isNotEmpty) 'category': category,
    'rackUnits': rackUnits,
    if (clearanceAboveU > 0) 'clearanceAboveU': clearanceAboveU,
    if (clearanceBelowU > 0) 'clearanceBelowU': clearanceBelowU,
    if (powerWatts > 0) 'powerWatts': powerWatts,
    if (btuPerHour > 0) 'btuPerHour': btuPerHour,
    if (powerInput != PowerInput.mains) 'powerInput': powerInput.name,
    if (price > 0) 'price': price,
    if (educationPrice > 0) 'educationPrice': educationPrice,
    if (retired) 'retired': true,
    if (cableSignal != null) 'cableSignal': cableSignal!.name,
    if (cableLengthFt > 0) 'cableLengthFt': cableLengthFt,
    if (url.isNotEmpty) 'url': url,
    if (notes.isNotEmpty) 'notes': notes,
    'ports': ports.map((p) => p.toJson()).toList(),
  };

  factory AvDeviceTemplate.fromJson(
    Map<String, dynamic> json, {
    bool custom = false,
  }) => AvDeviceTemplate(
    model: json['model']?.toString() ?? '',
    manufacturer: json['manufacturer']?.toString() ?? '',
    partNumber: json['partNumber']?.toString() ?? '',
    category: json['category']?.toString() ?? '',
    rackUnits: (json['rackUnits'] as num?)?.toInt() ?? 0,
    clearanceAboveU: (json['clearanceAboveU'] as num?)?.toInt() ?? 0,
    clearanceBelowU: (json['clearanceBelowU'] as num?)?.toInt() ?? 0,
    // 'watts' and 'cost' are read as aliases: they are what people write by
    // hand in a price list before they see the documented spelling.
    powerWatts:
        (json['powerWatts'] as num?)?.toDouble() ??
        (json['watts'] as num?)?.toDouble() ??
        0,
    btuPerHour:
        (json['btuPerHour'] as num?)?.toDouble() ??
        (json['btu'] as num?)?.toDouble() ??
        0,
    powerInput: powerInputFromName(json['powerInput']?.toString()),
    price:
        (json['price'] as num?)?.toDouble() ??
        (json['cost'] as num?)?.toDouble() ??
        0,
    educationPrice:
        (json['educationPrice'] as num?)?.toDouble() ??
        (json['eduPrice'] as num?)?.toDouble() ??
        0,
    retired: json['retired'] == true,
    cableSignal: json['cableSignal'] == null
        ? null
        : signalFromName(json['cableSignal'].toString()),
    // 'lengthFt' is read as an alias for the same reason 'watts' and 'cost'
    // are: it is what a hand-written entry tends to say.
    cableLengthFt: (json['cableLengthFt'] as num?)?.toDouble() ??
        (json['lengthFt'] as num?)?.toDouble() ??
        0,
    // 'link' is read as an alias for the same reason 'watts' and 'cost' are:
    // it is what a hand-written entry tends to say.
    url: (json['url'] ?? json['link'])?.toString() ?? '',
    notes: json['notes']?.toString() ?? '',
    ports: [
      for (final p in (json['ports'] as List? ?? []))
        if (p is Map) AvPort.fromJson(Map<String, dynamic>.from(p)),
    ],
    custom: custom,
  );
}

/// Catalog entries matching a typed search, best first: an exact-ish model
/// match above a match that only landed on the part number or the maker.
List<AvDeviceTemplate> searchCatalog(
  List<AvDeviceTemplate> entries,
  String query, {
  int limit = 300,
}) {
  final matched = entries
      .where((e) => AvDeviceLibrary.matchesSearch(e, query))
      .toList();
  final needle = AvDeviceLibrary.normalizeModel(query);
  if (needle.isNotEmpty) {
    int rank(AvDeviceTemplate e) {
      final model = AvDeviceLibrary.normalizeModel(e.model);
      if (model == needle) return 0;
      if (model.startsWith(needle)) return 1;
      if (model.contains(needle)) return 2;
      return 3;
    }

    matched.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      return byRank != 0
          ? byRank
          : a.model.toLowerCase().compareTo(b.model.toLowerCase());
    });
  }
  return matched.length > limit ? matched.sublist(0, limit) : matched;
}

/// Whether two port lists say the same thing. [AvPort] has no value equality,
/// and a rebuilt-but-identical inlet must not read as an edit.
bool _samePorts(List<AvPort> a, List<AvPort> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id ||
        a[i].label != b[i].label ||
        a[i].signal != b[i].signal ||
        a[i].direction != b[i].direction ||
        a[i].side != b[i].side) {
      return false;
    }
  }
  return true;
}

class AvDeviceLibrary {
  /// Model (normalized) -> template.
  final Map<String, AvDeviceTemplate> _byModel = {};

  /// Config section prefix ('CAMERADEVICE_') -> template used when no model
  /// matches. Overrides the built-in family fallbacks.
  final Map<String, AvDeviceTemplate> _familyDefaults = {};

  /// Where the library came from, for the App Config / toolbar hint.
  String source = 'Built-in defaults';

  /// The av_devices.json this library was READ from, or '' when nothing but
  /// the built-ins is loaded. [save] writes here when it is set.
  String filePath = '';

  int get modelCount => _byModel.length;

  /// Entries that belong to the user — loaded from av_devices.json or edited
  /// in the Device Editor. Only these are written back, so an untouched
  /// built-in can still be improved by a later app build.
  int get customCount => _byModel.values.where((t) => t.custom).length;

  /// Sorted view of [_byModel], rebuilt only when the catalog changes.
  /// The Device Editor reads [all] on every keystroke of its search box, and
  /// re-sorting a thousand entries per character is a thousand entries of
  /// work nobody asked for.
  List<AvDeviceTemplate>? _sorted;

  void _invalidate() => _sorted = null;

  /// Every entry, ordered the way the catalog list reads: manufacturer, then
  /// model.
  List<AvDeviceTemplate> get all {
    final cached = _sorted;
    if (cached != null) return cached;
    final list = _byModel.values.toList();
    list.sort((a, b) {
      final byMaker = a.manufacturer.toLowerCase().compareTo(
        b.manufacturer.toLowerCase(),
      );
      return byMaker != 0
          ? byMaker
          : a.model.toLowerCase().compareTo(b.model.toLowerCase());
    });
    return _sorted = List.unmodifiable(list);
  }

  /// The family fallbacks read from the file, kept so a save round-trips
  /// them instead of quietly dropping the block.
  Map<String, AvDeviceTemplate> get familyDefaults =>
      Map.unmodifiable(_familyDefaults);

  /// Every known model name, for the "add custom device" model picker.
  List<String> get knownModels {
    final names = _byModel.values.map((t) => t.model).toList();
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  /// Categories in use, for the catalog filter and the "new device" form.
  ///
  /// The three the app keys off are always offered even when nothing is filed
  /// under them yet — a picker that hides "Consumable" until a consumable
  /// exists is a picker you cannot create the first consumable with.
  List<String> get categories {
    final set = <String>{
      ...kWellKnownCategories,
      for (final t in _byModel.values)
        if (t.category.trim().isNotEmpty) t.category.trim(),
    };
    final list = set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  /// Everything still current — what the pickers that specify NEW work offer.
  /// Retired entries stay in [all] so rooms that already use them still
  /// resolve their ports and prices.
  List<AvDeviceTemplate> get active =>
      all.where((t) => !t.retired).toList();

  int get retiredCount => _byModel.values.where((t) => t.retired).length;

  /// The rack editor's parts list: vent plates, blanks, shelves and drawers,
  /// shortest first so a 1U blank is the first thing offered.
  List<AvDeviceTemplate> get rackHardware {
    final list = active.where((t) => t.isRackHardware).toList()
      ..sort((a, b) {
        final byU = a.rackUnits.compareTo(b.rackUnits);
        return byU != 0
            ? byU
            : a.model.toLowerCase().compareTo(b.model.toLowerCase());
      });
    return list;
  }

  /// The boxes — everything that is a piece of equipment rather than a cable,
  /// a rack part, a consumable or a billable line. What the estimate offers
  /// when a device is being quoted without appearing on any diagram.
  List<AvDeviceTemplate> get equipment => active
      .where(
        (t) =>
            !t.isCable &&
            !t.isMiscItem &&
            !t.isRackHardware &&
            !t.isConsumable,
      )
      .toList();

  List<AvDeviceTemplate> get consumables =>
      active.where((t) => t.isConsumable).toList();

  List<AvDeviceTemplate> get cables => active.where((t) => t.isCable).toList();

  /// The billable lines that are not equipment — licences, mounts, trip
  /// charges — by name, since the list is read as a rate card.
  List<AvDeviceTemplate> get miscItems {
    final list = active.where((t) => t.isMiscItem).toList()
      ..sort((a, b) => a.model.toLowerCase().compareTo(b.model.toLowerCase()));
    return list;
  }

  /// The cable entry priced for [signal], or null when the catalog has none —
  /// which the estimate reports as an unpriced run rather than costing at
  /// nothing.
  AvDeviceTemplate? cableForSignal(SignalType signal) {
    AvDeviceTemplate? retiredMatch;
    for (final t in all) {
      if (!t.isCable || t.cableSignal != signal) continue;
      if (!t.retired) return t;
      // A retired cable type is still better than pricing the run at nothing,
      // but only once nothing current matches.
      retiredMatch ??= t;
    }
    return retiredMatch;
  }

  /// Every cable entry for [signal], shortest first, with the ones that carry
  /// no length last.
  ///
  /// This is how a cable type is broken down: HDMI at 3 ft, 6 ft and 25 ft are
  /// three entries with three prices, and the estimate puts each drawn run on
  /// the shortest one that reaches it. An entry with no length is the fallback
  /// — bulk cable, or a type nobody has priced by the foot yet — so it sorts
  /// to the end where it is only reached when nothing else fits.
  ///
  /// Retired entries are left out unless they are all there is, for the same
  /// reason [cableForSignal] falls back to one: a run priced at nothing is
  /// worse than a run priced at a discontinued lead.
  List<AvDeviceTemplate> cablesForSignal(SignalType signal) {
    final live = <AvDeviceTemplate>[];
    final retired = <AvDeviceTemplate>[];
    for (final t in all) {
      if (!t.isCable || t.cableSignal != signal) continue;
      (t.retired ? retired : live).add(t);
    }
    final out = live.isEmpty ? retired : live;
    out.sort((a, b) {
      // No length sorts last, whatever it costs.
      if ((a.cableLengthFt <= 0) != (b.cableLengthFt <= 0)) {
        return a.cableLengthFt <= 0 ? 1 : -1;
      }
      final byLength = a.cableLengthFt.compareTo(b.cableLengthFt);
      return byLength != 0
          ? byLength
          : a.model.toLowerCase().compareTo(b.model.toLowerCase());
    });
    return out;
  }

  /// The cable entry a run of [signal] and [lengthFt] should be bought as: the
  /// shortest stock length that reaches.
  ///
  /// Falls back to the LONGEST when nothing reaches — a 40 ft run in a room
  /// whose longest stock HDMI is 25 ft is quoted at the 25, and the estimate
  /// says so rather than dropping the run — and to whatever the type has when
  /// no lengths are recorded at all, which is exactly what happened before any
  /// of this existed.
  AvDeviceTemplate? cableForRun(SignalType signal, double lengthFt) {
    final options = cablesForSignal(signal);
    if (options.isEmpty) return null;
    if (lengthFt <= 0) return options.first;
    for (final t in options) {
      if (t.cableLengthFt > 0 && t.cableLengthFt >= lengthFt) return t;
    }
    // Nothing long enough: the longest made-up length, else the bulk entry.
    final withLength = options.where((t) => t.cableLengthFt > 0).toList();
    return withLength.isEmpty ? options.first : withLength.last;
  }

  static String _norm(String model) =>
      model.trim().toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');

  /// The key an entry is stored under — exposed so callers comparing two
  /// libraries agree with this one on what "the same model" means.
  static String normalizeModel(String model) => _norm(model);

  /// Whether [entry] matches a typed search, ignoring spaces, dashes,
  /// underscores and case.
  ///
  /// Extron model names are exactly the sort people mistype — "DTP CrossPoint
  /// 108", "DTPCrossPoint108" and "dtp-crosspoint-108" are the same box — so
  /// an exact-substring search finds nothing about half the time. Both sides
  /// are squashed to letters and digits before comparing, and the part number
  /// and manufacturer are searched too.
  static bool matchesSearch(AvDeviceTemplate entry, String query) {
    final needle = _norm(query);
    if (needle.isEmpty) return true;
    final haystack = _norm(
      '${entry.model} ${entry.manufacturer} ${entry.partNumber} '
      '${entry.category}',
    );
    return haystack.contains(needle);
  }

  AvDeviceLibrary.builtIn() {
    for (final t in _builtInTemplates) {
      _byModel[_norm(t.model)] = t;
    }
    _invalidate();
  }

  /// An empty library — the starting point when reading somebody else's file
  /// for a merge, where built-ins would masquerade as their entries.
  AvDeviceLibrary.empty();

  // -------------------------------------------------------------------------
  //  EDITING
  // -------------------------------------------------------------------------

  /// Adds or replaces an entry, marking it as the user's so it is saved.
  /// [previousModel] renames: the old key is dropped rather than left behind
  /// as a duplicate under its former name.
  ///
  /// Ports are stored exactly as handed over — reconciling them against
  /// [AvDeviceTemplate.powerInput] happens on [save]. See
  /// [normalizePowerInlets] for why it cannot happen here.
  void upsert(AvDeviceTemplate template, {String previousModel = ''}) {
    if (template.model.trim().isEmpty) return;
    if (previousModel.isNotEmpty &&
        _norm(previousModel) != _norm(template.model)) {
      _byModel.remove(_norm(previousModel));
    }
    _byModel[_norm(template.model)] = template.copyWith(custom: true);
    _invalidate();
  }

  /// Forgets an entry. A built-in comes back on the next launch — the file is
  /// a layer over the built-ins, not a replacement for them.
  void remove(String model) {
    _byModel.remove(_norm(model));
    _invalidate();
  }

  /// Brings every user entry's connectors back in step with its power input:
  /// one inlet on a powered model, labelled for mains or PoE, none at all on a
  /// passive one. Returns how many entries had to change.
  ///
  /// This runs on [save] rather than on [upsert] because the Device Editor
  /// upserts on every keystroke, and [withPowerInlet] puts the inlet at the
  /// END of the list: normalizing per edit would yank the POWER row out from
  /// under somebody dragging the connectors into panel order, and would undo
  /// a deliberate placement of it as soon as the next character was typed. The
  /// write is where it actually has to hold — an entry saved as mains with no
  /// inlet is a box the drawing and the rack load both forget is plugged in,
  /// which is how the AP7900B reached av_devices.json without one.
  ///
  /// Built-ins are left alone: they declare no inlet on purpose and are given
  /// one when they are placed, and nothing writes them to the file anyway.
  int normalizePowerInlets() {
    var changed = 0;
    for (final key in _byModel.keys.toList()) {
      final entry = _byModel[key]!;
      if (!entry.custom) continue;
      final ports = withPowerInlet(entry.ports, entry.powerInput);
      if (_samePorts(ports, entry.ports)) continue;
      _byModel[key] = entry.copyWith(ports: ports);
      changed++;
    }
    if (changed > 0) _invalidate();
    return changed;
  }

  /// Replaces the family fallbacks (the Device Editor round-trips these).
  void setFamilyDefault(String prefix, AvDeviceTemplate? template) {
    if (template == null) {
      _familyDefaults.remove(prefix);
    } else {
      _familyDefaults[prefix] = template;
    }
  }

  /// Writes the user's entries to [toPath] (defaults to [filePath]). Returns
  /// the file written, or '' when there was nowhere to write / the write
  /// failed.
  ///
  /// [rebind] false writes a COPY without adopting it: handing your catalog
  /// to a colleague shouldn't quietly repoint your own saves at their folder.
  Future<String> save({String toPath = '', bool rebind = true}) async {
    final target = toPath.isNotEmpty ? toPath : filePath;
    if (target.isEmpty) return '';
    try {
      // Nothing inconsistent reaches the file: the catalog in memory is
      // brought into line first, so what is on disk and what the editor shows
      // are the same entries.
      final reconciled = normalizePowerInlets();
      final custom = all.where((t) => t.custom).toList();
      const encoder = JsonEncoder.withIndent('  ');
      await File(target).parent.create(recursive: true);
      await File(target).writeAsString(
        encoder.convert({
          '__readme':
              'AV device catalog for the Room Config Builder: connectors, '
              'rack height, estimated power draw and unit price per model. '
              'Edited on the Device Editor tab; entries here override the '
              "app's built-in models.",
          'devices': [for (final t in custom) t.toJson()],
          if (_familyDefaults.isNotEmpty)
            'familyDefaults': {
              for (final e in _familyDefaults.entries)
                e.key: e.value.toJson()..remove('model'),
            },
        }),
      );
      if (rebind) {
        filePath = target;
        source = target;
      }
      AppLogger.logInfo(
        'AV device catalog saved to $target (${custom.length} entries'
        '${reconciled > 0 ? ', $reconciled power inlet(s) reconciled' : ''}).',
      );
      return target;
    } catch (e, stack) {
      AppLogger.logError(
        'Failed to save the AV device catalog to $target',
        e,
        stack,
      );
      return '';
    }
  }

  /// Reads a catalog file on its own, with no built-ins underneath — what a
  /// merge needs, since a built-in in the other engineer's copy would
  /// otherwise read as something they had filled in.
  static Future<AvDeviceLibrary> readFile(String filePath) async {
    final library = AvDeviceLibrary.empty();
    final doc = jsonDecode(await File(filePath).readAsString());
    if (doc is! Map) {
      throw const FormatException('Root of the catalog file must be an object.');
    }
    for (final d in (doc['devices'] as List? ?? [])) {
      if (d is! Map) continue;
      final t = AvDeviceTemplate.fromJson(
        Map<String, dynamic>.from(d),
        custom: true,
      );
      if (t.model.isEmpty) continue;
      library._byModel[_norm(t.model)] = t;
    }
    library._invalidate();
    library.filePath = filePath;
    library.source = filePath;
    return library;
  }

  /// Loads `av_devices.json`, layering it over the built-ins. Mirrors
  /// [UiSchema.load]: an explicit path wins, otherwise the working directory
  /// then the executable's folder are searched.
  static Future<AvDeviceLibrary> load({String explicitPath = ''}) async {
    final library = AvDeviceLibrary.builtIn();

    final List<String> candidates = [];
    if (explicitPath.isNotEmpty) {
      candidates.add(explicitPath);
    } else {
      candidates.add(path.join(Directory.current.path, 'av_devices.json'));
      try {
        candidates.add(
          path.join(
            File(Platform.resolvedExecutable).parent.path,
            'av_devices.json',
          ),
        );
      } catch (_) {}
    }

    for (final candidate in candidates) {
      try {
        final file = File(candidate);
        if (!await file.exists()) continue;

        final doc = jsonDecode(await file.readAsString());
        if (doc is! Map) {
          throw const FormatException(
            'Root of av_devices.json must be an object.',
          );
        }
        int added = 0;
        for (final d in (doc['devices'] as List? ?? [])) {
          if (d is! Map) continue;
          final t = AvDeviceTemplate.fromJson(
            Map<String, dynamic>.from(d),
            custom: true,
          );
          // A priced entry with no connectors is still worth keeping: a price
          // list is filled in long before anybody draws that model's ports.
          if (t.model.isEmpty) continue;
          library._byModel[_norm(t.model)] = t;
          library._invalidate();
          added++;
        }
        final families = doc['familyDefaults'];
        if (families is Map) {
          families.forEach((prefix, value) {
            if (value is! Map) return;
            final t = AvDeviceTemplate.fromJson({
              'model': prefix.toString(),
              ...Map<String, dynamic>.from(value),
            });
            if (t.ports.isNotEmpty) {
              library._familyDefaults[prefix.toString()] = t;
            }
          });
        }
        library.filePath = candidate;
        library.source = candidate;
        AppLogger.logInfo(
          'AV device library loaded from $candidate ($added models, '
          '${library._familyDefaults.length} family defaults).',
        );
        return library;
      } catch (e, stack) {
        AppLogger.logError(
          'Failed to load av_devices.json from $candidate — using built-in '
          'defaults.',
          e,
          stack,
        );
        library.source = 'Built-in defaults (failed to load $candidate: $e)';
        return library;
      }
    }

    if (explicitPath.isNotEmpty) {
      library.source = 'Built-in defaults (file not found: $explicitPath)';
    }
    return library;
  }

  /// Exact model lookup, or null.
  AvDeviceTemplate? templateForModel(String model) {
    if (model.trim().isEmpty) return null;
    return _byModel[_norm(model)];
  }

  /// The connector set for a device: its model's template when one exists,
  /// otherwise a family-generic set sized from the model number when that is
  /// readable. [configKey] is the section key ('SWITCHERDEVICE_1') and drives
  /// the family fallback.
  AvDeviceTemplate resolve({required String configKey, required String model}) {
    final exact = templateForModel(model);
    if (exact != null) return exact;

    for (final entry in _familyDefaults.entries) {
      if (configKey.startsWith(entry.key)) {
        return entry.value.copyWith(model: model.isEmpty ? entry.key : model);
      }
    }
    return _familyFallback(configKey, model);
  }

  // -------------------------------------------------------------------------
  //  FAMILY FALLBACKS
  // -------------------------------------------------------------------------

  /// Generic connectors by device family. Sizes matrix switchers from the
  /// model number when it reads as one ("CrossPoint 108" -> 10x8, "SW4" -> 4
  /// in / 1 out) and otherwise picks a conservative default.
  static AvDeviceTemplate _familyFallback(String configKey, String model) {
    if (configKey.startsWith('SWITCHERDEVICE_')) {
      final (ins, outs) = switcherSize(model);
      return AvDeviceTemplate(
        model: model,
        rackUnits: ins > 4 ? 2 : 1,
        ports: [
          for (int i = 1; i <= ins; i++)
            AvPort(
              id: 'in_$i',
              label: 'IN $i',
              signal: SignalType.hdmi,
              direction: PortDirection.input,
              side: PortSide.left,
            ),
          for (int i = 1; i <= outs; i++)
            AvPort(
              id: 'out_$i',
              label: 'OUT $i',
              signal: SignalType.hdmi,
              direction: PortDirection.output,
              side: PortSide.right,
            ),
          _audioIn('in_aud_1', 'AUDIO IN'),
          _audioOut('out_aud_1', 'AUDIO OUT'),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('CAMERADEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        ports: [
          _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
          AvPort(
            id: 'out_usb_1',
            label: 'USB',
            signal: SignalType.usbData,
            direction: PortDirection.output,
            side: PortSide.right,
          ),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('PROJECTORDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        ports: [
          _videoIn('in_hdmi_1', 'HDMI 1', SignalType.hdmi),
          _videoIn('in_hdmi_2', 'HDMI 2', SignalType.hdmi),
          _videoIn('in_hdbt_1', 'HDBaseT', SignalType.hdbaset),
          _audioIn('in_aud_1', 'AUDIO IN'),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('DSPDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        rackUnits: 1,
        ports: [
          for (int i = 1; i <= 6; i++) _micIn('in_mic_$i', 'MIC/LINE $i'),
          for (int i = 1; i <= 4; i++) _audioOut('out_aud_$i', 'OUT $i'),
          _dante(),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('USBDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        ports: [
          for (int i = 1; i <= 2; i++)
            AvPort(
              id: 'in_usb_$i',
              label: 'HOST $i',
              signal: SignalType.usbData,
              direction: PortDirection.input,
              side: PortSide.left,
            ),
          for (int i = 1; i <= 2; i++)
            AvPort(
              id: 'out_usb_$i',
              label: 'DEVICE $i',
              signal: SignalType.usbData,
              direction: PortDirection.output,
              side: PortSide.right,
            ),
        ],
      );
    }
    if (configKey.startsWith('MEDIAPORTDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        ports: [
          _videoIn('in_hdmi_1', 'HDMI IN', SignalType.hdmi),
          _audioIn('in_aud_1', 'AUDIO IN'),
          AvPort(
            id: 'out_usb_1',
            label: 'USB OUT',
            signal: SignalType.usbData,
            direction: PortDirection.output,
            side: PortSide.right,
          ),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('WIRELESSDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        rackUnits: 1,
        ports: [
          _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
          AvPort(
            id: 'out_usb_1',
            label: 'USB',
            signal: SignalType.usbData,
            direction: PortDirection.bidirectional,
            side: PortSide.right,
          ),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('RECORDERDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        ports: [
          _videoIn('in_hdmi_1', 'HDMI IN', SignalType.hdmi),
          _audioIn('in_aud_1', 'AUDIO IN'),
          _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
          AvPort(
            id: 'out_usb_1',
            label: 'USB OUT',
            signal: SignalType.usbData,
            direction: PortDirection.output,
            side: PortSide.right,
          ),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('POWERDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        rackUnits: 1,
        ports: [
          for (int i = 1; i <= 8; i++)
            AvPort(
              id: 'out_pwr_$i',
              label: 'OUTLET $i',
              signal: SignalType.power,
              direction: PortDirection.output,
              side: PortSide.right,
            ),
          _lan(),
        ],
      );
    }
    if (configKey.startsWith('SCREENDEVICE_')) {
      return AvDeviceTemplate(
        model: model,
        ports: [
          AvPort(
            id: 'in_ctrl_1',
            label: 'CONTROL',
            signal: SignalType.serial,
            direction: PortDirection.input,
            side: PortSide.left,
          ),
        ],
      );
    }
    // Unknown family: one in, one out, so it can at least be cabled.
    return AvDeviceTemplate(
      model: model,
      ports: [
        _videoIn('in_1', 'IN 1', SignalType.hdmi),
        _videoOut('out_1', 'OUT 1', SignalType.hdmi),
      ],
    );
  }

  /// Reads an input/output count out of a switcher model name.
  ///
  /// Extron matrix naming packs the size into one number — "CrossPoint 108"
  /// is 10x8, "CrossPoint 84" is 8x4 — so a 3-digit group splits 2+1 and a
  /// 2-digit group splits 1+1. "SW4", "IN1804" and similar name only their
  /// input count, which lands on the single-output default.
  ///
  /// Public because it answers a question the connector labels cannot: how
  /// many outputs the box HAS. A catalog entry that labels an 84's two DTP
  /// sockets "DTP OUT 1" and "DTP OUT 2" is counting connectors of that type,
  /// not outputs, and only the model number says those are outputs 3 and 4 —
  /// which is what `output_proj_1: "3B"` has to land on. See
  /// av_flow_routing.dart.
  static (int, int) switcherSize(String model) {
    final upper = model.toUpperCase();

    final crossPoint = RegExp(r'CROSS\s*POINT\s+(\d{2,3})').firstMatch(upper);
    if (crossPoint != null) {
      final digits = crossPoint.group(1)!;
      if (digits.length == 3) {
        return (int.parse(digits.substring(0, 2)), int.parse(digits[2]));
      }
      return (int.parse(digits[0]), int.parse(digits[1]));
    }

    // "SW4 HD 4K PLUS", "SW6" — the digit right after SW is the input count.
    final sw = RegExp(r'\bSW\s*(\d{1,2})\b').firstMatch(upper);
    if (sw != null) return (int.parse(sw.group(1)!), 1);

    // "IN1804" — an input-series scaler; the trailing digit is the inputs.
    final inSeries = RegExp(r'\bIN\s*\d{2}(\d)\d\b').firstMatch(upper);
    if (inSeries != null) {
      final n = int.parse(inSeries.group(1)!);
      return (n == 0 ? 4 : n, 2);
    }

    return (4, 1);
  }

  // --- port shorthands, so the built-in table stays readable ---------------

  static AvPort _videoIn(String id, String label, SignalType s) => AvPort(
    id: id,
    label: label,
    signal: s,
    direction: PortDirection.input,
    side: PortSide.left,
  );

  static AvPort _videoOut(String id, String label, SignalType s) => AvPort(
    id: id,
    label: label,
    signal: s,
    direction: PortDirection.output,
    side: PortSide.right,
  );

  static AvPort _audioIn(String id, String label) => AvPort(
    id: id,
    label: label,
    signal: SignalType.analogAudio,
    direction: PortDirection.input,
    side: PortSide.left,
  );

  static AvPort _audioOut(String id, String label) => AvPort(
    id: id,
    label: label,
    signal: SignalType.analogAudio,
    direction: PortDirection.output,
    side: PortSide.right,
  );

  static AvPort _micIn(String id, String label) => AvPort(
    id: id,
    label: label,
    signal: SignalType.micLine,
    direction: PortDirection.input,
    side: PortSide.left,
  );

  static AvPort _usbOut(String id, String label) => AvPort(
    id: id,
    label: label,
    signal: SignalType.usbData,
    direction: PortDirection.output,
    side: PortSide.right,
  );

  static AvPort _dante() => const AvPort(
    id: 'dante_1',
    label: 'DANTE',
    signal: SignalType.dante,
    direction: PortDirection.bidirectional,
    side: PortSide.bottom,
  );

  static AvPort _lan() => const AvPort(
    id: 'lan_1',
    label: 'LAN',
    signal: SignalType.network,
    direction: PortDirection.bidirectional,
    side: PortSide.bottom,
  );

  // -------------------------------------------------------------------------
  //  BUILT-IN MODELS
  // -------------------------------------------------------------------------
  //  Covers the models in the shipped config.json. Treat these as a head
  //  start, not gospel — override in av_devices.json where your hardware
  //  differs.

  static final List<AvDeviceTemplate> _builtInTemplates = [
    // --- Extron matrix switchers ---
    AvDeviceTemplate(
      model: 'DTP CrossPoint 108 4K IPCP MA 70',
      manufacturer: 'Extron',
      rackUnits: 3,
      ports: [
        for (int i = 1; i <= 6; i++)
          _videoIn('in_hdmi_$i', 'HDMI IN $i', SignalType.hdmi),
        for (int i = 1; i <= 4; i++)
          _videoIn('in_dtp_$i', 'DTP IN $i', SignalType.hdbaset),
        for (int i = 1; i <= 2; i++)
          _videoOut('out_hdmi_$i', 'HDMI OUT $i', SignalType.hdmi),
        for (int i = 1; i <= 4; i++)
          _videoOut('out_dtp_$i', 'DTP OUT $i', SignalType.hdbaset),
        for (int i = 1; i <= 4; i++) _micIn('in_mic_$i', 'MIC $i'),
        for (int i = 1; i <= 2; i++) _audioIn('in_aud_$i', 'LINE IN $i'),
        for (int i = 1; i <= 4; i++) _audioOut('out_aud_$i', 'AUDIO OUT $i'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'DTP CrossPoint 84 4K IPCP MA 70',
      manufacturer: 'Extron',
      rackUnits: 2,
      ports: [
        for (int i = 1; i <= 5; i++)
          _videoIn('in_hdmi_$i', 'HDMI IN $i', SignalType.hdmi),
        for (int i = 1; i <= 3; i++)
          _videoIn('in_dtp_$i', 'DTP IN $i', SignalType.hdbaset),
        for (int i = 1; i <= 2; i++)
          _videoOut('out_hdmi_$i', 'HDMI OUT $i', SignalType.hdmi),
        for (int i = 1; i <= 2; i++)
          _videoOut('out_dtp_$i', 'DTP OUT $i', SignalType.hdbaset),
        for (int i = 1; i <= 4; i++) _micIn('in_mic_$i', 'MIC $i'),
        for (int i = 1; i <= 4; i++) _audioOut('out_aud_$i', 'AUDIO OUT $i'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'IN1804',
      manufacturer: 'Extron',
      rackUnits: 1,
      ports: [
        _videoIn('in_hdmi_1', 'HDMI IN 1', SignalType.hdmi),
        _videoIn('in_hdmi_2', 'HDMI IN 2', SignalType.hdmi),
        _videoIn('in_hdmi_3', 'HDMI IN 3', SignalType.hdmi),
        _videoIn('in_vga_1', 'VGA IN', SignalType.vga),
        _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
        _videoOut('out_dtp_1', 'DTP OUT', SignalType.hdbaset),
        _audioIn('in_aud_1', 'AUDIO IN'),
        _audioOut('out_aud_1', 'AUDIO OUT'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'SW4 HD 4K PLUS',
      manufacturer: 'Extron',
      rackUnits: 1,
      ports: [
        for (int i = 1; i <= 4; i++)
          _videoIn('in_hdmi_$i', 'HDMI IN $i', SignalType.hdmi),
        _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
      ],
    ),

    // --- DSPs ---
    AvDeviceTemplate(
      model: 'DMP 64 Plus C AT',
      manufacturer: 'Extron',
      rackUnits: 1,
      ports: [
        for (int i = 1; i <= 6; i++) _micIn('in_mic_$i', 'MIC/LINE $i'),
        for (int i = 1; i <= 4; i++) _audioOut('out_aud_$i', 'OUT $i'),
        _dante(),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'DMP 128 Plus C AT',
      manufacturer: 'Extron',
      rackUnits: 1,
      ports: [
        for (int i = 1; i <= 12; i++) _micIn('in_mic_$i', 'MIC/LINE $i'),
        for (int i = 1; i <= 8; i++) _audioOut('out_aud_$i', 'OUT $i'),
        _dante(),
        _lan(),
      ],
    ),

    // --- USB / streaming interfaces ---
    AvDeviceTemplate(
      model: 'MediaPort 200',
      manufacturer: 'Extron',
      rackUnits: 1,
      ports: [
        _videoIn('in_hdmi_1', 'HDMI IN', SignalType.hdmi),
        _audioIn('in_aud_1', 'AUDIO IN'),
        _videoOut('out_hdmi_1', 'HDMI LOOP', SignalType.hdmi),
        _usbOut('out_usb_1', 'USB OUT'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'ShareLink Pro 2000',
      manufacturer: 'Extron',
      rackUnits: 1,
      ports: [
        _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
        _audioOut('out_aud_1', 'AUDIO OUT'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'AV Bridge',
      manufacturer: 'Vaddio',
      rackUnits: 1,
      ports: [
        _videoIn('in_hdmi_1', 'HDMI IN', SignalType.hdmi),
        _micIn('in_mic_1', 'MIC IN 1'),
        _micIn('in_mic_2', 'MIC IN 2'),
        _audioOut('out_aud_1', 'AUDIO OUT'),
        _usbOut('out_usb_1', 'USB OUT'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'Toggle',
      manufacturer: 'iGen',
      ports: [
        AvPort(
          id: 'in_usb_1',
          label: 'HOST 1',
          signal: SignalType.usbData,
          direction: PortDirection.input,
          side: PortSide.left,
        ),
        AvPort(
          id: 'in_usb_2',
          label: 'HOST 2',
          signal: SignalType.usbData,
          direction: PortDirection.input,
          side: PortSide.left,
        ),
        _usbOut('out_usb_1', 'DEVICE OUT'),
      ],
    ),

    // --- Cameras ---
    AvDeviceTemplate(
      model: 'TR311HW',
      manufacturer: 'AVer',
      ports: [
        _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
        _usbOut('out_usb_1', 'USB'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'Cam570',
      manufacturer: 'AVer',
      ports: [
        _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
        _usbOut('out_usb_1', 'USB'),
        _lan(),
      ],
    ),

    // --- Displays / projectors ---
    AvDeviceTemplate(
      model: 'VPL-PHZ60',
      manufacturer: 'Sony',
      ports: [
        _videoIn('in_hdmi_1', 'HDMI 1', SignalType.hdmi),
        _videoIn('in_hdmi_2', 'HDMI 2', SignalType.hdmi),
        _videoIn('in_hdbt_1', 'HDBaseT', SignalType.hdbaset),
        _videoIn('in_vga_1', 'VGA', SignalType.vga),
        _audioIn('in_aud_1', 'AUDIO IN'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'PowerLite L610U',
      manufacturer: 'Epson',
      ports: [
        _videoIn('in_hdmi_1', 'HDMI 1', SignalType.hdmi),
        _videoIn('in_hdmi_2', 'HDMI 2', SignalType.hdmi),
        _videoIn('in_hdbt_1', 'HDBaseT', SignalType.hdbaset),
        _videoIn('in_vga_1', 'COMPUTER', SignalType.vga),
        _audioIn('in_aud_1', 'AUDIO IN'),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'LC-90LE657U',
      manufacturer: 'Sharp',
      ports: [
        for (int i = 1; i <= 4; i++)
          _videoIn('in_hdmi_$i', 'HDMI $i', SignalType.hdmi),
        _audioOut('out_aud_1', 'AUDIO OUT'),
      ],
    ),

    // --- Power / screen control ---
    AvDeviceTemplate(
      model: 'AP7900B',
      manufacturer: 'APC',
      rackUnits: 1,
      ports: [
        for (int i = 1; i <= 8; i++)
          AvPort(
            id: 'out_pwr_$i',
            label: 'OUTLET $i',
            signal: SignalType.power,
            direction: PortDirection.output,
            side: PortSide.right,
          ),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'SCB-100',
      manufacturer: 'Extron',
      ports: [
        AvPort(
          id: 'in_ctrl_1',
          label: 'CONTROL',
          signal: SignalType.serial,
          direction: PortDirection.input,
          side: PortSide.left,
        ),
      ],
    ),

    // --- Common room gear the control config never sees, offered when
    //     adding a device by hand. ---
    AvDeviceTemplate(
      model: 'Display (generic)',
      ports: [
        _videoIn('in_hdmi_1', 'HDMI 1', SignalType.hdmi),
        _videoIn('in_hdmi_2', 'HDMI 2', SignalType.hdmi),
        _audioOut('out_aud_1', 'AUDIO OUT'),
      ],
    ),
    AvDeviceTemplate(
      model: 'Laptop / BYOD input',
      ports: [
        _videoOut('out_hdmi_1', 'HDMI', SignalType.hdmi),
        _videoOut('out_usbc_1', 'USB-C', SignalType.usbC),
      ],
    ),
    AvDeviceTemplate(
      model: 'Room PC',
      ports: [
        _videoOut('out_hdmi_1', 'HDMI', SignalType.hdmi),
        _videoOut('out_dp_1', 'DisplayPort', SignalType.displayPort),
        AvPort(
          id: 'in_usb_1',
          label: 'USB',
          signal: SignalType.usbData,
          direction: PortDirection.input,
          side: PortSide.left,
        ),
        _lan(),
      ],
    ),
    AvDeviceTemplate(
      model: 'Wall plate / TX',
      ports: [
        _videoIn('in_hdmi_1', 'HDMI IN', SignalType.hdmi),
        _videoOut('out_dtp_1', 'DTP OUT', SignalType.hdbaset),
      ],
    ),
    AvDeviceTemplate(
      model: 'Receiver / RX',
      ports: [
        _videoIn('in_dtp_1', 'DTP IN', SignalType.hdbaset),
        _videoOut('out_hdmi_1', 'HDMI OUT', SignalType.hdmi),
      ],
    ),
    AvDeviceTemplate(
      model: 'Amplifier',
      rackUnits: 1,
      ports: [
        _audioIn('in_aud_1', 'LINE IN L'),
        _audioIn('in_aud_2', 'LINE IN R'),
        AvPort(
          id: 'out_spk_1',
          label: 'SPKR OUT L',
          signal: SignalType.speaker,
          direction: PortDirection.output,
          side: PortSide.right,
        ),
        AvPort(
          id: 'out_spk_2',
          label: 'SPKR OUT R',
          signal: SignalType.speaker,
          direction: PortDirection.output,
          side: PortSide.right,
        ),
      ],
    ),
    AvDeviceTemplate(
      model: 'Speaker',
      ports: [
        AvPort(
          id: 'in_spk_1',
          label: 'SPKR IN',
          signal: SignalType.speaker,
          direction: PortDirection.input,
          side: PortSide.left,
        ),
      ],
    ),
    AvDeviceTemplate(
      model: 'Ceiling microphone',
      ports: [
        _audioOut('out_mic_1', 'MIC OUT').copyWith(signal: SignalType.micLine),
        _dante(),
      ],
    ),
    AvDeviceTemplate(
      model: 'Network switch',
      rackUnits: 1,
      ports: [
        for (int i = 1; i <= 8; i++)
          AvPort(
            id: 'lan_$i',
            label: 'PORT $i',
            signal: SignalType.network,
            direction: PortDirection.bidirectional,
            side: i <= 4 ? PortSide.left : PortSide.right,
          ),
      ],
    ),
    AvDeviceTemplate(
      model: 'Patch panel',
      rackUnits: 1,
      ports: [
        for (int i = 1; i <= 12; i++)
          AvPort(
            id: 'p_$i',
            label: 'P$i',
            signal: SignalType.network,
            direction: PortDirection.bidirectional,
            // A panel's outlets run in one horizontal row along the bottom
            // edge — see AvNodeKind.patchPanel.
            side: PortSide.bottom,
          ),
      ],
    ),

    // --- RACK HARDWARE -----------------------------------------------------
    //  The parts list the rack editor offers. No connectors and no power: a
    //  blank plate is a thing you buy and a thing that occupies a rail, and
    //  nothing else. Prices ship at 0 — "not priced" — because what a plate
    //  costs is a fact about your supplier, not about the app.
    ..._rackHardware,

    // --- CONSUMABLES -------------------------------------------------------
    ..._consumables,

    // --- CABLE ------------------------------------------------------------
    ..._cableTypes,
  ];

  /// One rack accessory: no ports, no power, a height and a price. [category]
  /// is the specific kind ('Vent plate', 'Drawer'), which is how the rack
  /// editor groups the parts list.
  static AvDeviceTemplate _hardware(
    String model,
    String category,
    int rackUnits, {
    String notes = '',
  }) => AvDeviceTemplate(
    model: model,
    category: category,
    rackUnits: rackUnits,
    powerInput: PowerInput.none,
    notes: notes,
    ports: const [],
  );

  static final List<AvDeviceTemplate> _rackHardware = [
    for (final u in [1, 2, 3, 4])
      _hardware('Blank plate ${u}U', 'Blank plate', u),
    for (final u in [1, 2, 3])
      _hardware(
        'Vent plate ${u}U',
        'Vent plate',
        u,
        notes: 'Perforated, passive',
      ),
    _hardware(
      'Fan panel 1U',
      'Vent plate',
      1,
      notes: 'Powered — set its watts on the catalog entry',
    ),
    _hardware('Rack shelf 1U', 'Shelf', 1, notes: 'Fixed'),
    _hardware('Rack shelf 2U', 'Shelf', 2, notes: 'Fixed'),
    _hardware(
      'Clamping shelf 1U',
      'Clamping shelf',
      1,
      notes: 'Holds a half-rack box down by the sides',
    ),
    _hardware('Clamping shelf 2U', 'Clamping shelf', 2),
    _hardware('Vented shelf 2U', 'Shelf', 2, notes: 'Perforated'),
    _hardware('Rack drawer 2U', 'Drawer', 2),
    _hardware('Rack drawer 3U', 'Drawer', 3),
    _hardware('Lacing bar 1U', 'Cable management', 1),
    _hardware('Cable management panel 1U', 'Cable management', 1),
    _hardware('Rack rail screws (pack)', 'Rack hardware', 0),
  ];

  static AvDeviceTemplate _consumable(String model, String notes) =>
      AvDeviceTemplate(
        model: model,
        category: kCategoryConsumable,
        powerInput: PowerInput.none,
        notes: notes,
        ports: const [],
      );

  static final List<AvDeviceTemplate> _consumables = [
    _consumable('Hook & loop tie roll', 'Per roll'),
    _consumable('Cable ties (bag of 100)', 'Per bag'),
    _consumable('Cable labels (sheet)', 'Per sheet'),
    _consumable('Heat shrink assortment', 'Per pack'),
    _consumable('Phoenix connectors (bag)', 'Per bag'),
    _consumable('Rack screws & cage nuts (bag)', 'Per bag'),
  ];

  /// A priced cable type. [signal] is what ties it to the runs on the AV flow:
  /// every cable of that signal type on the diagram is quoted at this price.
  static AvDeviceTemplate _cable(String model, SignalType signal) =>
      AvDeviceTemplate(
        model: model,
        category: kCategoryCable,
        powerInput: PowerInput.none,
        cableSignal: signal,
        notes: 'Priced per run; the quantity comes off the AV flow diagram.',
        ports: const [],
      );

  static final List<AvDeviceTemplate> _cableTypes = [
    _cable('HDMI cable', SignalType.hdmi),
    _cable('Shielded twisted pair (HDBaseT / DTP)', SignalType.hdbaset),
    _cable('DisplayPort cable', SignalType.displayPort),
    _cable('USB-C cable', SignalType.usbC),
    _cable('SDI / coax cable', SignalType.sdi),
    _cable('VGA cable', SignalType.vga),
    _cable('Analog audio cable', SignalType.analogAudio),
    _cable('Digital audio cable (AES/SPDIF)', SignalType.digitalAudio),
    _cable('Dante / AES67 patch lead', SignalType.dante),
    _cable('Mic / line cable', SignalType.micLine),
    _cable('Speaker cable', SignalType.speaker),
    _cable('USB cable / extender', SignalType.usbData),
    _cable('Network patch lead', SignalType.network),
    _cable('IR emitter cable', SignalType.ir),
    _cable('RS-232 cable', SignalType.serial),
    _cable('IEC power lead', SignalType.power),
  ];
}
