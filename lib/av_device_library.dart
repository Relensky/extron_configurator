import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'av_flow_model.dart';
import 'search_match.dart';

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
///        "leadTimeDays": 42, "lifeYears": 8,
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
///  `lifeYears` is how long the product lasts before it wants replacing, which
///  is what the room's Lifecycle tab and the building's replacement plan are
///  built from. Recorded here so every room that specifies the model inherits
///  it; a position that genuinely differs overrides it on the box itself. 0 or
///  absent means nobody has recorded one, and the plan falls back to the
///  default cycle.
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

// ---------------------------------------------------------------------------
//  THE CATEGORIES THAT TRACK TO THE MODULES
// ---------------------------------------------------------------------------
//  A category is free text and always will be — a catalog can say whatever it
//  likes, and an importer says whatever the price list said. What that got the
//  catalog was thirty-one different words for eighteen kinds of box: 'Fox
//  Systems', 'XTP Systems', 'Scalers Switchers', 'Audio', 'DA', 'Matrix' —
//  aisles of a manufacturer's web shop, filed as though they described the
//  product.
//
//  THE APP ONLY UNDERSTANDS ONE VOCABULARY, and it is this one. A room's
//  config holds a SWITCHERDEVICE_1 block with a python module behind it, and
//  the words the app maps that block onto — for a base price, for a control
//  module, for the replacement plan's grouping — are the words below. See
//  categoryForConfigKey() in base_costs.dart, which is the mapping itself, and
//  BaseCostBook.defaults, which prices exactly these.
//
//  A catalog entry filed under 'Fox Systems' therefore prices at nothing and
//  groups under nothing, silently, with a perfectly reasonable-looking word in
//  the column. So these are what the pickers offer, what a tidy-up retags onto
//  (see the Device Editor's "Tidy categories"), and what a new entry should
//  normally be given.
//
//  NOT A CLOSED SET. Anything can still be typed, and a site with a kind of
//  product this list has no word for should invent one — the cost of a
//  category the app does not track is that it prices off the room's config
//  section instead, which is a fallback and not a failure.

/// The device categories a room's own config sections map onto — the ones the
/// base-cost card prices and the control prefill reads.
///
/// Kept in the same order as [BaseCostBook.defaults], which is roughly the
/// order a rack is read in rather than alphabetical: a picker sorted A-Z puts
/// 'Amplifier' above 'Camera' above 'Control processor' and buries the
/// switcher everybody is looking for in the middle.
const List<String> kTrackedCategories = [
  'Switcher',
  'Camera',
  'DSP',
  'Amplifier',
  'Display',
  'Projector',
  'Screen',
  'USB interface',
  'Wireless presentation',
  'Recorder / streamer',
  'Control processor',
  'Touch panel',
  'Power controller',
  'Network switch',
  'Microphone',
  'Speaker',
  'Transmitter / receiver',
  'Mount / bracket',
];

/// True when [category] is one of the words the app itself understands —
/// either a tracked device kind or one of the four it keys behaviour off.
bool isTrackedCategory(String category) {
  final needle = category.trim().toLowerCase();
  if (needle.isEmpty) return false;
  for (final c in kWellKnownCategories) {
    if (c.toLowerCase() == needle) return true;
  }
  return false;
}

/// What a catalog category that is NOT one of ours most likely meant, or ''
/// when nothing here can honestly say.
///
/// SILENCE IS AN ANSWER. 'Matrix' is a switcher and nothing else, so it is
/// filled in. 'Audio' holds DSPs, amplifiers, microphones and loudspeakers,
/// and a guess there would retag a $90 mic as a $4,000 processor — so it is
/// left blank and the person doing the tidy-up picks, or leaves it alone. The
/// families deliberately absent are the manufacturer's aisles that hold more
/// than one kind of box: Audio, Control Systems, DTP Systems, XTP Systems, Fox
/// Systems, Architectural, Collaboration Systems, Streaming Systems.
String catalogCategorySuggestion(String category) =>
    kCatalogCategorySuggestions[category.trim().toLowerCase()] ?? '';

/// The translations above, lower-cased. Deliberately short: every entry on it
/// has to be true of EVERY product filed under the word.
const Map<String, String> kCatalogCategorySuggestions = {
  'matrix': 'Switcher',
  'matrix switcher': 'Switcher',
  'presentation switcher': 'Switcher',
  'switchers': 'Switcher',
  'videowall processors': 'Switcher',
  'scaler': 'Switcher',
  'cameras': 'Camera',
  'ptz camera': 'Camera',
  'audio processor': 'DSP',
  'dsps': 'DSP',
  'amplifiers': 'Amplifier',
  'amp': 'Amplifier',
  'flat panel': 'Display',
  'flat panels': 'Display',
  'monitor': 'Display',
  'monitors': 'Display',
  'displays': 'Display',
  'projectors': 'Projector',
  'screens': 'Screen',
  'usb': 'USB interface',
  'usb extender': 'USB interface',
  'usb interfaces': 'USB interface',
  'wireless': 'Wireless presentation',
  'wireless presentation systems': 'Wireless presentation',
  'streaming': 'Recorder / streamer',
  'recorder': 'Recorder / streamer',
  'encoder / decoder': 'Recorder / streamer',
  'control processor': 'Control processor',
  'control processors': 'Control processor',
  'touch panels': 'Touch panel',
  'touchpanel': 'Touch panel',
  'power': 'Power controller',
  'power controllers': 'Power controller',
  'network switches': 'Network switch',
  'switch': 'Network switch',
  'microphones': 'Microphone',
  'mics': 'Microphone',
  'speakers': 'Speaker',
  'loudspeaker': 'Speaker',
  'loudspeakers': 'Speaker',
  'transmitter': 'Transmitter / receiver',
  'receiver': 'Transmitter / receiver',
  'extender': 'Transmitter / receiver',
  'extenders': 'Transmitter / receiver',
  'mount': 'Mount / bracket',
  'mounts': 'Mount / bracket',
  'bracket': 'Mount / bracket',
  'brackets': 'Mount / bracket',
  'cables': kCategoryCable,
  'cabling': kCategoryCable,
  'consumables': kCategoryConsumable,
  'misc': kCategoryMisc,
  'miscellaneous': kCategoryMisc,
  'other': kCategoryMisc,
  'accessory': kCategoryMisc,
  'accessories': kCategoryMisc,
};

/// The categories offered even when nothing is filed under them yet: the kinds
/// the app tracks, then the rack parts, then the three it keys behaviour off.
///
/// The rack kinds are listed individually ('Vent plate', 'Shelf', ...) because
/// that is how the rack editor groups its parts list — "Rack hardware" as a
/// single bucket would put a drawer and a blanking plate in the same drawer.
const List<String> kWellKnownCategories = [
  ...kTrackedCategories,
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

  /// WHAT YOU WOULD BUY INSTEAD. The model that replaces this one, by name,
  /// blank when nobody has said or the product is still current.
  ///
  /// ============================================================================
  ///  A RETIRED PRICE IS THE WRONG PRICE, AND IT IS WRONG SILENTLY
  /// ============================================================================
  ///  Retiring an entry kept it out of the pickers, which is right, and left
  ///  every room that already held one being budgeted at the price of a product
  ///  nobody can buy. A campus refresh plan is read four years out and priced
  ///  entirely off that number: forty rooms holding a 2016 projector were being
  ///  planned at its 2016 list, and the actual replacement had gone up by a
  ///  third. Nothing on any screen said so, because the figure was a real price
  ///  for a real catalog entry.
  ///
  ///  So a retired entry can name its successor, and everything that asks what
  ///  it costs to replace this position asks the SUCCESSOR - see
  ///  [AvDeviceLibrary.successorFor], which follows the chain as far as it
  ///  goes. A 2012 model replaced by a 2016 one replaced by a 2024 one prices
  ///  at the 2024 one, because that is what the purchase order would say.
  ///
  ///  BY MODEL NAME, the same way [AvNode.model] points at a catalog entry and
  ///  a vendor rule names a manufacturer. A name that no longer resolves is a
  ///  chain that stops there, which is the same answer as no successor at all -
  ///  never a crash and never a zero.
  final String replacedBy;

  /// NOTHING WILL EVER DRIVE THIS. A USB capture stick, a passive splitter, a
  /// wall plate: real equipment, on the drawing and on the quote, with no
  /// control interface of any kind.
  ///
  /// On the ENTRY rather than on each box placed from it, because it is a fact
  /// about the product — the AverMedia interface is uncontrollable in every
  /// room anybody puts one in — and ticking the same box on every drawing is
  /// how the reports fill up with gaps somebody has to re-decide about.
  ///
  /// What reads it: the control-gap report, the estimate's config flag and the
  /// prefill that writes config blocks for drawn boxes. See
  /// [AppStateProvider.avNodeIsUncontrolled], which is where the per-box
  /// [AvNode.excludeFromControl] and this meet.
  final bool neverControlled;

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

  /// How long this product takes to arrive, in calendar days. Null when nobody
  /// has recorded one.
  ///
  /// A FACT ABOUT THE PRODUCT, which is why it belongs here beside the price
  /// and the part number rather than only on a job. The same projector is six
  /// weeks out on every job that specifies it, and a lead time that lives only
  /// on the project is one that gets retyped per project — which in practice
  /// means it stops getting typed at all.
  ///
  /// A JOB CAN STILL DISAGREE. What a vendor quotes this quarter beats what
  /// the catalog remembers from last year, so a figure recorded against the
  /// part on the project wins over this one; see [BuildingProject.partLeadTimes]
  /// and the resolution order in project_schedule.dart.
  ///
  /// NULL AND ZERO ARE DIFFERENT ANSWERS, the same way they are on a job: null
  /// is "nobody has asked", zero is "it is on the shelf". Folding them together
  /// would make every product nobody has checked look immediately available,
  /// which is the one direction this must not be wrong in.
  final int? leadTimeDays;

  /// How long this product lasts before it wants replacing, in years. 0 when
  /// nobody has recorded one.
  ///
  /// A FACT ABOUT THE PRODUCT, beside the lead time and for the same reason. A
  /// laser projector runs for eight years and a lamp one for four; a lectern PC
  /// is on the desktop refresh at five whatever room it is in; a ceiling
  /// speaker outlives two of everything else around it. Recorded once here and
  /// every room that specifies the model inherits it, rather than being typed
  /// per box — which in practice means it stops getting typed at all and every
  /// room falls back to one blanket figure.
  ///
  /// A ROOM CAN STILL DISAGREE. What somebody knows about THIS position beats
  /// what the catalog says about the product in general — a display in a
  /// boardroom nobody books outlives the same display in a lecture hall running
  /// eight hours a day — so [AvNode.lifeYears] wins over this, and this wins
  /// over [kDefaultEquipmentLifeYears]. See `buildRoomLifecycle`.
  ///
  /// Zero is "nobody has recorded one", not "it lasts no time": there is no
  /// sensible reading of a nought-year life, so the two do not have to be told
  /// apart the way null and zero do on [leadTimeDays].
  final int lifeYears;

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
    this.replacedBy = '',
    this.neverControlled = false,
    this.cableSignal,
    this.cableLengthFt = 0,
    this.url = '',
    this.leadTimeDays,
    this.lifeYears = 0,
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
    String? replacedBy,
    bool? neverControlled,
    SignalType? cableSignal,
    double? cableLengthFt,
    bool clearCableSignal = false,
    String? url,
    int? leadTimeDays,
    // Null means "leave it alone" on every other field here, so taking a lead
    // time back OFF an entry needs its own flag.
    bool clearLeadTime = false,
    int? lifeYears,
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
    replacedBy: replacedBy ?? this.replacedBy,
    neverControlled: neverControlled ?? this.neverControlled,
    cableSignal: clearCableSignal ? null : (cableSignal ?? this.cableSignal),
    cableLengthFt: cableLengthFt ?? this.cableLengthFt,
    url: url ?? this.url,
    leadTimeDays: clearLeadTime ? null : (leadTimeDays ?? this.leadTimeDays),
    lifeYears: lifeYears ?? this.lifeYears,
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
    if (replacedBy.trim().isNotEmpty) 'replacedBy': replacedBy.trim(),
    if (neverControlled) 'neverControlled': true,
    if (cableSignal != null) 'cableSignal': cableSignal!.name,
    if (cableLengthFt > 0) 'cableLengthFt': cableLengthFt,
    if (url.isNotEmpty) 'url': url,
    if (leadTimeDays != null) 'leadTimeDays': leadTimeDays,
    if (lifeYears > 0) 'lifeYears': lifeYears,
    if (notes.isNotEmpty) 'notes': notes,
    'ports': ports.map((p) => p.toJson()).toList(),
  };

  /// A lead time off a catalog file, or null when there is not a usable one.
  ///
  /// Zero is kept — "in stock" is an answer somebody checked. A negative
  /// figure, or text somebody typed where a number belongs ("6-8 weeks"), is
  /// dropped, because the alternative is a product that silently reads as
  /// available tomorrow.
  static int? _leadTimeFromJson(Object? raw) {
    if (raw == null) return null;
    final days = raw is num ? raw.toInt() : int.tryParse(raw.toString().trim());
    return (days == null || days < 0) ? null : days;
  }

  /// A life off a catalog file, or 0 when there is not a usable one.
  ///
  /// Text where a number belongs ('about 8 years'), a negative, or a figure so
  /// large it is plainly a typo all read as unrecorded rather than being
  /// honoured — a product with a 600-year life would sit green on the
  /// replacement plan for ever, which is the one direction this must not be
  /// wrong in.
  static int _lifeYearsFromJson(Object? raw) {
    if (raw == null) return 0;
    final years = raw is num ? raw.toInt() : int.tryParse(raw.toString().trim());
    if (years == null || years <= 0 || years > 100) return 0;
    return years;
  }

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
    replacedBy: json['replacedBy']?.toString().trim() ?? '',
    neverControlled: json['neverControlled'] == true,
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
    // Anything that is not a whole number of days reads as "nobody has asked"
    // rather than as zero: a catalog hand-edited to say "6-8 weeks" must not
    // turn the product into one that is on the shelf.
    leadTimeDays: _leadTimeFromJson(json['leadTimeDays']),
    // Anything that is not a positive whole number of years reads as "nobody
    // has recorded one" - see [lifeYears] on why zero and unrecorded are the
    // same answer here.
    lifeYears: _lifeYearsFromJson(json['lifeYears']),
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
  // Reduced ONCE. This runs over the whole catalog on every keystroke, and
  // re-splitting the same query for each of sixteen hundred entries was most
  // of what the search box was doing between one character and the next.
  final q = SearchQuery(query);
  final matched = <AvDeviceTemplate>[
    for (final e in entries)
      if (AvDeviceLibrary.matchesQuery(e, q)) e,
  ];
  final needle = AvDeviceLibrary.normalizeModel(query);
  final terms = q.terms;
  if (needle.isNotEmpty) {
    int rank(String model) {
      if (model == needle) return 0;
      if (model.startsWith(needle)) return 1;
      if (model.contains(needle)) return 2;
      // A MULTI-WORD query almost never appears in a model name as one run of
      // characters, so without this every hit landed on the same rung and the
      // list came back alphabetical — "Epson PowerLite" putting an Epson
      // document camera above every PowerLite. Rank on how much of what was
      // typed the MODEL ITSELF carries: one word of the query is usually the
      // maker, which is a column rather than part of the name, so a model with
      // the other word in it is the thing being asked for.
      return 3 + terms.where((t) => !model.contains(t)).length;
    }

    // Ranked once per entry rather than once per COMPARISON. A comparison
    // sort asks the comparator O(n log n) times, and each of those calls was
    // normalizing a model name again — thirty thousand string rebuilds to put
    // sixteen hundred rows in order.
    final ordered = <({AvDeviceTemplate entry, int rank, String name})>[
      for (final e in matched)
        (
          entry: e,
          rank: rank(AvDeviceLibrary.normalizeModel(e.model)),
          name: e.model.toLowerCase(),
        ),
    ];
    ordered.sort((a, b) {
      final byRank = a.rank.compareTo(b.rank);
      return byRank != 0 ? byRank : a.name.compareTo(b.name);
    });
    matched
      ..clear()
      ..addAll([for (final o in ordered) o.entry]);
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

/// One part number and every catalog entry wearing it.
class DuplicatePartGroup {
  /// As the first entry spells it — the comparison ignores case and spacing,
  /// but the warning should read the way the catalog does.
  final String partNumber;

  /// Two or more entries, in catalog order.
  final List<AvDeviceTemplate> entries;

  const DuplicatePartGroup({required this.partNumber, required this.entries});

  /// "IN1608, IN1608 xi" — the group in one line.
  String get modelList => entries.map((t) => t.model).join(', ');
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

  /// The custom entries EXACTLY as the file held them the last time this copy
  /// read or wrote it, keyed the same way as [_byModel]. Empty when nothing
  /// has been read from a file.
  ///
  /// This is the third side of the merge that makes a shared catalog safe —
  /// see [_reconcileWithDisk]. Without it a save cannot tell "I changed this"
  /// from "somebody else changed this", and the only available answer is to
  /// overwrite everything.
  final Map<String, AvDeviceTemplate> _baseline = {};

  /// Remembers the current custom entries as the state of the file on disk.
  void _markBaseline() {
    _baseline
      ..clear()
      ..addEntries(
        _byModel.entries.where((e) => e.value.custom),
      );
  }

  // -------------------------------------------------------------------------
  //  THE WHOLE CATALOG, AS ONE VALUE
  // -------------------------------------------------------------------------
  //  What Undo on the Device Editor records and puts back. NOT the same
  //  document [save] writes: that one holds only the entries that belong to
  //  the user, because a built-in the app ships is not something to write into
  //  somebody's file. A history has the opposite requirement — it has to be
  //  able to restore EXACTLY what was on screen, built-ins included, or an
  //  undo would quietly promote a shipped entry into a user one, or lose an
  //  override and leave the built-in showing in its place.

  /// Every entry and every family default, as a value that can be put back.
  Map<String, dynamic> toDoc() => {
        'entries': [
          for (final t in _byModel.values)
            {
              // Which side of the line an entry is on is not in its own JSON —
              // the file format has no need of it, since everything in the
              // file is the user's by definition. Here it has to be carried.
              if (t.custom) 'custom': true,
              ...t.toJson(),
            },
        ],
        'familyDefaults': {
          for (final e in _familyDefaults.entries)
            e.key: e.value.toJson()..remove('model'),
        },
      };

  /// Replaces every entry with what [doc] holds.
  ///
  /// Wholesale rather than a merge: this is a restore, and a restore that
  /// layered onto what is already there could not remove an entry somebody
  /// had added — which is half of what Undo is for.
  void applyDoc(Map<String, dynamic> doc) {
    _byModel.clear();
    _familyDefaults.clear();
    for (final d in (doc['entries'] as List? ?? [])) {
      if (d is! Map) continue;
      final json = Map<String, dynamic>.from(d);
      final t = AvDeviceTemplate.fromJson(json, custom: json['custom'] == true);
      if (t.model.isEmpty) continue;
      _byModel[_norm(t.model)] = t;
    }
    final families = doc['familyDefaults'];
    if (families is Map) {
      families.forEach((prefix, value) {
        if (value is! Map) return;
        final t = AvDeviceTemplate.fromJson({
          'model': prefix.toString(),
          ...Map<String, dynamic>.from(value),
        });
        if (t.ports.isNotEmpty) _familyDefaults[prefix.toString()] = t;
      });
    }
    _invalidate();
    // THE BASELINE IS LEFT ALONE. It records what the FILE held when this copy
    // last read or wrote it, which an undo in memory does not change - and
    // moving it would make the next save think another editor's entries were
    // this one's to overwrite. See [_reconcileWithDisk].
  }

  int get modelCount => _byModel.length;

  /// Entries that belong to the user — loaded from av_devices.json or edited
  /// in the Device Editor. Only these are written back, so an untouched
  /// built-in can still be improved by a later app build.
  int get customCount => _customCount ??=
      _byModel.values.where((t) => t.custom).length;

  /// Sorted view of [_byModel], rebuilt only when the catalog changes.
  /// The Device Editor reads [all] on every keystroke of its search box, and
  /// re-sorting a thousand entries per character is a thousand entries of
  /// work nobody asked for.
  List<AvDeviceTemplate>? _sorted;

  /// Cached for the same reason [_sorted] is: the Device Editor asks on every
  /// keystroke of its search box, and this walks the whole catalog.
  List<DuplicatePartGroup>? _duplicates;

  // EVERYTHING THE DEVICE EDITOR'S TOOLBAR ASKS FOR, held the same way.
  //
  // That toolbar is rebuilt on every character typed into the search box, and
  // each of these walks all sixteen hundred entries — two of them sort what
  // they find. Five full passes of the catalog per keystroke, to redraw a
  // count and fill a dropdown that only change when the catalog does.
  int? _customCount;
  int? _retiredCount;
  List<String>? _categories;
  List<({String category, int count})>? _categoryCounts;
  List<AvDeviceTemplate>? _active;

  /// The unmodifiable view handed out by [familyDefaults], held rather than
  /// rebuilt: the wrapper is a copy, and the map behind it is already ours.
  Map<String, AvDeviceTemplate>? _familyDefaultsView;

  void _invalidate() {
    _sorted = null;
    _duplicates = null;
    _customCount = null;
    _retiredCount = null;
    _categories = null;
    _categoryCounts = null;
    _active = null;
    _familyDefaultsView = null;
  }

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
      _familyDefaultsView ??= Map.unmodifiable(_familyDefaults);

  /// Categories in use, for the catalog filter and the "new device" form.
  ///
  /// The ones the app keys off ([kWellKnownCategories]) are always offered
  /// even when nothing is filed under them yet — a picker that hides
  /// "Consumable" until a consumable exists is a picker you cannot create the
  /// first consumable with.
  List<String> get categories {
    final cached = _categories;
    if (cached != null) return cached;
    final set = <String>{
      ...kWellKnownCategories,
      for (final t in _byModel.values)
        if (t.category.trim().isNotEmpty) t.category.trim(),
    };
    final list = set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return _categories = List.unmodifiable(list);
  }

  /// How many entries are filed under each category actually IN the catalog,
  /// most-used first.
  ///
  /// The count is the whole point of the tidy-up screen: 'Fox Systems' with
  /// eighty-nine products behind it and 'Matrix' with six are the same kind of
  /// mistake and nothing like the same amount of it, and a list sorted A-Z
  /// says nothing about which one is worth a decision. Unlike [categories]
  /// this offers only what is there — a category nothing is filed under has
  /// nothing to retag.
  List<({String category, int count})> get categoryCounts {
    final cached = _categoryCounts;
    if (cached != null) return cached;
    final counts = <String, int>{};
    final spelling = <String, String>{};
    for (final t in _byModel.values) {
      final name = t.category.trim();
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      counts[key] = (counts[key] ?? 0) + 1;
      spelling.putIfAbsent(key, () => name);
    }
    final list = [
      for (final entry in counts.entries)
        (category: spelling[entry.key]!, count: entry.value),
    ]..sort((a, b) {
        final byCount = b.count.compareTo(a.count);
        return byCount != 0
            ? byCount
            : a.category.toLowerCase().compareTo(b.category.toLowerCase());
      });
    return _categoryCounts = List.unmodifiable(list);
  }

  /// The models filed under [category], for saying what a category actually
  /// HOLDS before somebody retags all of it. Capped: three examples answer
  /// "is this one kind of thing", and eighty-nine do not.
  List<String> examplesIn(String category, {int limit = 3}) {
    final needle = category.trim().toLowerCase();
    final names = <String>[];
    for (final t in all) {
      if (t.category.trim().toLowerCase() != needle) continue;
      names.add(t.model);
      if (names.length >= limit) break;
    }
    return names;
  }

  /// Everything still current — what the pickers that specify NEW work offer.
  /// Retired entries stay in [all] so rooms that already use them still
  /// resolve their ports and prices.
  List<AvDeviceTemplate> get active => _active ??=
      List.unmodifiable(all.where((t) => !t.retired));

  int get retiredCount => _retiredCount ??=
      _byModel.values.where((t) => t.retired).length;

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

  static final RegExp _modelSeparators = RegExp(r'[\s_\-]+');

  static String _norm(String model) {
    // Every model lookup in the app comes through here, and the catalog
    // search ranks its hits with it, so this is measured in thousands of
    // calls per keystroke rather than one. Plain ASCII — which every model
    // name is — folds in one pass over the code units; anything else falls
    // back to the lowercase-and-strip this has always been, because Unicode
    // lowercasing is not a per-character operation.
    final length = model.length;
    final units = <int>[];
    for (var i = 0; i < length; i++) {
      final c = model.codeUnitAt(i);
      if (c > 0x7f) {
        return model.trim().toLowerCase().replaceAll(_modelSeparators, '');
      }
      // Space, tab, newline, vertical tab, form feed, carriage return,
      // underscore and hyphen are the separators; the trim() the old form
      // began with is subsumed by dropping whitespace wherever it appears.
      if (c == 0x20 || (c >= 0x09 && c <= 0x0d) || c == 0x5f || c == 0x2d) {
        continue;
      }
      units.add(c >= 0x41 && c <= 0x5a ? c + 0x20 : c);
    }
    return String.fromCharCodes(units);
  }

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
  ///
  /// EVERY WORD, ANYWHERE. A search is typed by somebody thinking about the
  /// product, not about which column each half of the name lives in: "Epson
  /// PowerLite" is a maker and a product line, and no single field holds them
  /// in that order — the model says "PowerLite L630U" and the manufacturer
  /// says "Epson". Squashing the whole query into one token asked for
  /// "epsonpowerlite" as one run of characters and found nothing, on the most
  /// natural way there is to look that projector up. Each WORD is required, so
  /// adding words still narrows.
  static bool matchesSearch(AvDeviceTemplate entry, String query) =>
      matchesQuery(entry, SearchQuery(query));

  /// [matchesSearch] against a query that has already been reduced — what a
  /// search over the WHOLE catalog wants, so the query is split once per
  /// keystroke instead of once per entry.
  static bool matchesQuery(AvDeviceTemplate entry, SearchQuery query) =>
      query.isEmpty || query.matchesKey(searchHaystack(entry));

  /// The four fields a search reads, reduced to letters and digits, and
  /// remembered per entry.
  ///
  /// The catalog is immutable once loaded and the reduced form of an entry
  /// never changes, so computing it for every entry on every keystroke was
  /// rebuilding the same sixteen hundred strings a few times a second. An
  /// [Expando] rather than a field because [AvDeviceTemplate] is const and its
  /// entries are shared; an entry that is replaced in the catalog is a new
  /// object and gets its own answer, and a dropped one takes its cache with it.
  static String searchHaystack(AvDeviceTemplate entry) {
    final cached = _searchHaystacks[entry];
    if (cached != null) return cached;
    final built = searchKey(
      '${entry.model} ${entry.manufacturer} ${entry.partNumber} '
      '${entry.category}',
    );
    _searchHaystacks[entry] = built;
    return built;
  }

  static final Expando<String> _searchHaystacks = Expando<String>(
    'catalog search keys',
  );

  // -------------------------------------------------------------------------
  //  ONE PART NUMBER, ONE ENTRY
  // -------------------------------------------------------------------------
  //  The catalog is keyed by MODEL, and a model name is whatever the page it
  //  was imported from called it. Two imports of the same box — "IN1608" from
  //  the price list and "IN1608 xi" from the product site — are two entries,
  //  each with half the facts, and the only thing that says they are one box
  //  is the part number they share. Left alone they drift: a price typed onto
  //  one, connectors drawn on the other, and a room quoted off whichever name
  //  the engineer happened to pick.
  //
  //  So the catalog reports them, and the Device Editor offers to fold them
  //  into one entry.

  /// A part number for comparison: case and spacing are noise on a SKU.
  static final RegExp _runsOfSpace = RegExp(r'\s+');
  static final RegExp _anyDigit = RegExp(r'[0-9]');

  static String normalizePartNumber(String partNumber) =>
      partNumber.trim().toUpperCase().replaceAll(_runsOfSpace, ' ');

  /// Whether [partNumber] identifies a specific product, rather than standing
  /// in for one that hasn't got a SKU.
  ///
  /// A real SKU has a digit in it. 'Custom' is on four Quantum Ultra frames
  /// and means "quoted per job" — reporting those four as duplicates of each
  /// other would be noise, and merging them would be wrong.
  static bool isRealPartNumber(String partNumber) =>
      partNumber.trim().isNotEmpty && partNumber.contains(_anyDigit);

  /// Every part number that is on more than one entry, most entries first.
  /// Empty when the catalog is clean, which is what the Device Editor checks
  /// before it says anything.
  List<DuplicatePartGroup> get duplicateParts {
    final cached = _duplicates;
    if (cached != null) return cached;
    final byPart = <String, List<AvDeviceTemplate>>{};
    for (final t in all) {
      if (!isRealPartNumber(t.partNumber)) continue;
      byPart.putIfAbsent(normalizePartNumber(t.partNumber), () => []).add(t);
    }
    final groups = [
      for (final entry in byPart.entries)
        if (entry.value.length > 1)
          DuplicatePartGroup(
            partNumber: entry.value.first.partNumber.trim(),
            entries: List.unmodifiable(entry.value),
          ),
    ];
    groups.sort((a, b) {
      final byCount = b.entries.length.compareTo(a.entries.length);
      return byCount != 0
          ? byCount
          : a.partNumber.toLowerCase().compareTo(b.partNumber.toLowerCase());
    });
    return _duplicates = List.unmodifiable(groups);
  }

  /// The other entries carrying [partNumber] — what the part number field
  /// warns about while somebody is typing one in.
  List<AvDeviceTemplate> othersWithPartNumber(
    String partNumber, {
    String exceptModel = '',
  }) {
    if (!isRealPartNumber(partNumber)) return const [];
    final needle = normalizePartNumber(partNumber);
    final skip = _norm(exceptModel);
    return [
      for (final t in all)
        if (normalizePartNumber(t.partNumber) == needle &&
            _norm(t.model) != skip)
          t,
    ];
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

  /// Refiles every entry whose category is a key of [mapping] under that
  /// key's value. Returns how many entries moved.
  ///
  /// THE CATALOG IS TIDIED A CATEGORY AT A TIME, not an entry at a time. An
  /// import files two hundred products under 'Fox Systems' in one go, and
  /// undoing that one entry at a time is two hundred edits nobody makes — so
  /// the mess arrives in blocks and has to leave in blocks. See
  /// [kTrackedCategories] for what it is being tidied ONTO, and
  /// [catalogCategorySuggestion] for why the app will not guess at the
  /// families that hold more than one kind of box.
  ///
  /// Keys are matched trimmed and case-insensitively, the way a person reads
  /// them: 'usb', 'USB' and 'USB ' are one category. A mapping onto a blank
  /// value, or onto the name it already has, is skipped rather than treated as
  /// an edit — a tidy-up dialog offers every category it found, and most of
  /// them are usually being left alone.
  ///
  /// Entries touched are marked custom, like every other edit: the tidy-up is
  /// this site's decision about its own catalog, and it belongs in the file
  /// this site saves rather than being lost on the next build.
  int retagCategories(Map<String, String> mapping) {
    final rules = <String, String>{};
    for (final entry in mapping.entries) {
      final from = entry.key.trim().toLowerCase();
      final to = entry.value.trim();
      if (from.isEmpty || to.isEmpty || from == to.toLowerCase()) continue;
      rules[from] = to;
    }
    if (rules.isEmpty) return 0;

    var moved = 0;
    for (final key in _byModel.keys.toList()) {
      final entry = _byModel[key]!;
      final to = rules[entry.category.trim().toLowerCase()];
      if (to == null) continue;
      _byModel[key] = entry.copyWith(category: to, custom: true);
      moved++;
    }
    if (moved > 0) _invalidate();
    return moved;
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
    _invalidate();
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
      // Whoever else has been in the file since this copy read it keeps their
      // work — a catalog on a share is edited by more than one person and a
      // full-file rewrite would silently undo them.
      //
      // BEFORE the power inlets are normalized, not after: normalizing adds a
      // POWER connector to entries that need one, and a merge cannot tell
      // that from something the person at this keyboard drew. Run the other
      // way round it counted every entry as locally edited and threw away the
      // other editor's connectors.
      final adopted = rebind ? await _reconcileWithDisk(target) : 0;
      // Nothing inconsistent reaches the file: the catalog in memory is
      // brought into line first, so what is on disk and what the editor shows
      // are the same entries.
      final reconciled = normalizePowerInlets();
      final custom = all.where((t) => t.custom).toList();
      const encoder = JsonEncoder.withIndent('  ');
      await File(target).parent.create(recursive: true);
      await _writeAtomically(
        target,
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
        // What is now on disk is what the next save has to measure against.
        _markBaseline();
      }
      AppLogger.logInfo(
        'AV device catalog saved to $target (${custom.length} entries'
        '${reconciled > 0 ? ', $reconciled power inlet(s) reconciled' : ''}'
        '${adopted > 0 ? ', $adopted entr${adopted == 1 ? 'y' : 'ies'} kept '
            'from another editor' : ''}).',
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

  /// Folds anybody else's edits into this catalog before it is written over
  /// the top of theirs. Returns how many entries were taken from the file.
  ///
  /// A SHARED CATALOG IS EDITED BY MORE THAN ONE PERSON. Everybody's Save
  /// rewrites the whole file, so whoever pressed it last used to erase every
  /// price the other had typed since — silently, because the file it wrote
  /// was perfectly valid.
  ///
  /// So the file is read back immediately before writing and settled FIELD BY
  /// FIELD against [_baseline], the entries as they were when this copy last
  /// read or wrote it:
  ///
  ///   * unchanged on disk — nobody else touched it, mine is written;
  ///   * changed on disk, mine still at the baseline — theirs, and it lives;
  ///   * both moved — mine, because this is the save being pressed.
  ///
  /// Two people pricing different models both keep their work, and so do one
  /// pricing a switcher and another drawing its connectors. Only the same
  /// field of the same model, edited by two people in the same window, is a
  /// contest — and there the one who saved second wins, which for a price
  /// revision is the right answer anyway.
  ///
  /// A model on disk this copy has never seen is somebody's new entry and is
  /// kept. A model missing from disk is not treated as a deletion: the merge
  /// adds and updates and never deletes, the same rule the Device Editor's
  /// merge dialog follows.
  Future<int> _reconcileWithDisk(String target) async {
    // Nothing to measure against: this is a first save, or an export to a
    // file this copy has never read. Overwriting is the only thing it could
    // mean.
    if (_baseline.isEmpty) return 0;
    late final AvDeviceLibrary disk;
    try {
      if (!await File(target).exists()) return 0;
      disk = await readFile(target);
    } catch (e, stack) {
      // A file that cannot be read cannot be merged with. Saving over it is
      // still better than refusing to save, but it is worth a line in the log.
      AppLogger.logError(
        'Could not re-read $target before saving, so another editor\'s '
        'changes (if any) could not be kept.',
        e,
        stack,
      );
      return 0;
    }

    var adopted = 0;
    for (final theirs in disk.all) {
      final key = _norm(theirs.model);
      final base = _baseline[key];
      final mine = _byModel[key];

      // Theirs alone: a model somebody else added since this copy read the
      // file. Nothing of mine to weigh it against, so it stays.
      if (base == null) {
        if (mine == null) {
          _byModel[key] = theirs;
          adopted++;
        }
        continue;
      }
      // I deleted it and they did not. Mine is the edit being saved.
      if (mine == null) continue;

      final merged = _mergeFields(base: base, mine: mine, theirs: theirs);
      if (merged == null) continue;
      _byModel[key] = merged;
      adopted++;
    }

    // Family defaults are a whole-entry decision — a fallback port set is one
    // fact, not ten — so one somebody else added is kept and anything this
    // copy holds a view on stays as it is.
    var tookFamily = false;
    for (final e in disk._familyDefaults.entries) {
      if (_familyDefaults.containsKey(e.key)) continue;
      _familyDefaults[e.key] = e.value;
      tookFamily = true;
    }

    // A fallback taken from disk is a change even when no ENTRY moved, and
    // [familyDefaults] is handed out from a held view now. Counting only
    // [adopted] here would leave that view showing the set we arrived with.
    if (adopted > 0 || tookFamily) _invalidate();
    return adopted;
  }

  /// One entry settled field by field, or null when nothing of theirs is
  /// worth taking.
  ///
  /// Compared through [AvDeviceTemplate.toJson] rather than field by hand, so
  /// a field added to the template later is merged without anybody having to
  /// remember this function exists. The encoding matters: `toJson` leaves a
  /// default OUT, so a key's absence is a value like any other.
  static AvDeviceTemplate? _mergeFields({
    required AvDeviceTemplate base,
    required AvDeviceTemplate mine,
    required AvDeviceTemplate theirs,
  }) {
    final baseJson = base.toJson();
    final mineJson = mine.toJson();
    final theirsJson = theirs.toJson();

    final out = Map<String, dynamic>.from(mineJson);
    var took = 0;
    for (final field in {
      ...baseJson.keys,
      ...mineJson.keys,
      ...theirsJson.keys,
    }) {
      final atBase = jsonEncode(baseJson[field]);
      // They left it where it was, so there is nothing of theirs to take.
      if (jsonEncode(theirsJson[field]) == atBase) continue;
      // I moved it too. This is my save.
      if (jsonEncode(mineJson[field]) != atBase) continue;
      if (theirsJson.containsKey(field)) {
        out[field] = theirsJson[field];
      } else {
        out.remove(field);
      }
      took++;
    }
    if (took == 0) return null;
    return AvDeviceTemplate.fromJson(out, custom: true);
  }

  /// Writes [contents] to [target] through a temporary file, so a reader on
  /// the share never opens a half-written catalog.
  static Future<void> _writeAtomically(String target, String contents) async {
    final temp = File('$target.tmp');
    await temp.writeAsString(contents, flush: true);
    try {
      await temp.rename(target);
    } catch (_) {
      // Some network shares refuse a rename over an existing file. Falling
      // back to a plain write is the behavior this has always had.
      await File(target).writeAsString(contents, flush: true);
      try {
        await temp.delete();
      } catch (_) {}
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
    library._markBaseline();
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
        // ONCE, AFTER THE WHOLE FILE. Nothing reads a derived view partway
        // through a load, and this was being called sixteen hundred times to
        // clear caches that had not been rebuilt in between.
        library._invalidate();
        library.filePath = candidate;
        library.source = candidate;
        // What the file held when it was read, which is what a later save
        // measures another editor's changes against.
        library._markBaseline();
        AppLogger.logInfo(
          'AV device library loaded from $candidate ($added models, '
          '${library._familyDefaults.length} family defaults).',
        );
        return library;
      } catch (e, stack) {
        AppLogger.logError(
          'Failed to load av_devices.json from $candidate - using built-in '
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

  /// How far a replacement chain is followed before it is treated as broken.
  ///
  /// A chain longer than this is not a product history, it is a mistake -
  /// somebody has pointed two entries at each other, or built a loop through a
  /// third. Six is more product generations than any AV model has, and a cap
  /// is what makes this safe to call from a grid cell.
  static const int kMaxSuccessorHops = 6;

  /// WHAT YOU WOULD ACTUALLY BUY to fill this position today.
  ///
  /// Follows [AvDeviceTemplate.replacedBy] from [model] to the end of the
  /// chain and returns what it lands on. Null when [model] is not in the
  /// catalog at all.
  ///
  /// THE END OF THE CHAIN IS WHERE IT STOPS BEING RETIRED, or where the names
  /// stop resolving, or where a loop is detected, whichever comes first. Each
  /// of those is the same answer to the caller - "this is the newest thing the
  /// catalog knows about in this line" - and the entry it returns is a real
  /// entry with a real price either way.
  ///
  /// A CURRENT MODEL IS ITS OWN SUCCESSOR. An entry that is not retired
  /// returns itself, so a caller never has to ask twice or special-case the
  /// commonest answer.
  AvDeviceTemplate? successorFor(String model) {
    var current = templateForModel(model);
    if (current == null) return null;
    final seen = <String>{_norm(current.model)};
    for (var hop = 0; hop < kMaxSuccessorHops; hop++) {
      if (!current!.retired) return current;
      final next = current.replacedBy.trim();
      if (next.isEmpty) return current;
      final key = _norm(next);
      // A loop, or a name pointing back at somewhere already visited. The
      // entry in hand is the best answer there is.
      if (!seen.add(key)) return current;
      final template = _byModel[key];
      // A name the catalog does not have. The chain stops here, and the
      // retired entry it stopped on is still a real price - see
      // [AvDeviceTemplate.replacedBy].
      if (template == null) return current;
      current = template;
    }
    return current;
  }

  /// True when [model] is a retired entry that names something else to buy -
  /// which is the one case where the price on screen is not the price of the
  /// thing on the drawing, and has to say so.
  bool hasSuccessor(String model) {
    final template = templateForModel(model);
    if (template == null || !template.retired) return false;
    final successor = successorFor(model);
    return successor != null && _norm(successor.model) != _norm(template.model);
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
      // The Toggle's shape, which is what goes in every build: the room's
      // peripherals arrive on the DEVICE ports and the machines that can take
      // them hang off the HOST ports. Named the other way round, this fallback
      // contradicted both the catalog entry and the leads the routing draws —
      // the doc cam ended up plugged into something called HOST 2.
      return AvDeviceTemplate(
        model: model,
        ports: [
          for (int i = 1; i <= 3; i++)
            AvPort(
              id: 'in_usb_$i',
              label: 'USB DEVICE $i',
              signal: SignalType.usbData,
              direction: PortDirection.input,
              side: PortSide.left,
            ),
          for (int i = 1; i <= 2; i++)
            AvPort(
              id: 'out_usb_$i',
              label: 'USB HOST $i',
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
      // The AV Bridge 2x1's shape: two HDMI inputs, a loop-through out and
      // the USB the room's conferencing actually runs on. A recorder block
      // with no model on it yet is one of these until somebody says
      // otherwise — it is what goes in every build — and giving the fallback
      // one HDMI input meant the second camera or the second source had
      // nowhere to land on the drawing.
      return AvDeviceTemplate(
        model: model,
        rackUnits: 1,
        ports: [
          _videoIn('in_hdmi_1', 'HDMI IN 1', SignalType.hdmi),
          _videoIn('in_hdmi_2', 'HDMI IN 2', SignalType.hdmi),
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
      notes: 'Powered - set its watts on the catalog entry',
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
