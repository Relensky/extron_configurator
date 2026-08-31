import 'dart:convert';
import 'dart:io';

import 'app_logger.dart';
import 'av_device_library.dart' show PricingTier;
import 'building_project.dart' show formatIsoDate, parseIsoDate;

/// ============================================================================
///  BASE COSTS
/// ============================================================================
///  What a switcher costs when nobody has said which switcher yet.
///
///  The catalog prices MODELS. That is the right answer once a room is
///  specified, and no answer at all during the hour when it isn't: a budget
///  drawn up from a room sketch has "a camera" and "a DSP" in it, not an
///  AVer TR311HW. So this is a second, coarser rate card — one figure per
///  device CATEGORY — kept in a file of its own (`base_costs.json` in the Root
///  Folder) exactly like the labor rates, and for the same reason: a typical
///  price is a fact about the year and the supplier, not about one room.
///
///  Precedence in the estimate is narrowest-first, and every line says which
///  rung it landed on:
///
///    1. the room's own quoted price (typed on the Cost tab)
///    2. the catalog price for that model
///    3. the base cost for its category  <- this file
///    4. the base cost for the category its config section makes it <- ditto
///    5. nothing, and the estimate reports the line as unpriced
///
///  Rungs 3 and 4 are two rungs because they read two different vocabularies.
///  This card is written in the app's words — Switcher, DSP, Screen — while a
///  catalog entry imported from a manufacturer's site carries THEIR product
///  family: a DTP CrossPoint is filed under "Matrix", a screen controller
///  under "Architectural". [kCategoryAliases] translates the families that
///  mean exactly one thing; the ones that don't (an "Audio" that is a DSP, an
///  amplifier or a loudspeaker depending on the box) are left alone and caught
///  by rung 4, which asks what the device DOES IN THIS ROOM rather than what
///  aisle of the catalog it came from.
///
///  A base cost of 0 means "not set" and is skipped rather than costing a
///  camera at nothing — the same rule the rate card uses for an unfilled role.
///
///  Each category carries BOTH published prices, exactly as a catalog entry
///  does: the list price and the education price. A budget drawn up before the
///  models are chosen still gets quoted at one tier or the other, and a card
///  with only one figure on it would have every early estimate reading high or
///  low depending on which way the job went.
/// ============================================================================

class BaseCost {
  /// The catalog category this prices ('Switcher', 'Camera', 'DSP'). Matched
  /// case-insensitively against [AvDeviceTemplate.category].
  final String category;

  /// Typical unit price at list (MSRP). 0 means "not set". Kept under the
  /// plain name `price` so cards written before there were two tiers still
  /// read, the same spelling the device catalog uses.
  final double price;

  /// Typical unit price at education / institutional pricing. 0 = not set.
  final double educationPrice;

  /// What this figure assumes — the spec level it was priced at.
  final String notes;

  /// THE MODEL THIS CATEGORY IS BENCHMARKED ON, by name, blank when nobody has
  /// said.
  ///
  /// ============================================================================
  ///  A TYPICAL PRICE NOBODY CAN ARGUE WITH IS A TYPICAL PRICE NOBODY TRUSTS
  /// ============================================================================
  ///  "A projector is about $4,200" is the figure a four-year refresh plan for
  ///  forty rooms is built on, and until now it was a number somebody typed
  ///  once with nothing beside it saying which projector, at what spec, in
  ///  which year. A finance office asked to sign off eleven of those wants to
  ///  know what they are eleven OF, and the honest answer was in whoever typed
  ///  it's head.
  ///
  ///  So the card can name the model it was priced on and the day it was
  ///  priced. Both come from the estate's own catalog when the figure is set
  ///  from the campus report's current-models tab, which is the whole point of
  ///  that tab: pick this year's projector, see what forty of them come to,
  ///  and make that the number the plan is built on.
  ///
  ///  IT DOES NOT DRIVE THE PRICE. The figures above are still the figures -
  ///  this says where they came from, so a card set on a 2022 model in 2026
  ///  can be SEEN to be four years stale rather than having to be remembered
  ///  to be.
  final String standardModel;

  /// The day [standardModel] and the figures beside it were last set from the
  /// catalog. Null when nobody has, which is every card written by hand.
  final DateTime? standardSetOn;

  const BaseCost({
    required this.category,
    this.price = 0,
    this.educationPrice = 0,
    this.notes = '',
    this.standardModel = '',
    this.standardSetOn,
  });

  /// How many whole years old the benchmark is as of [asOf]. Null when there
  /// is no benchmark to age.
  int? standardAgeYears(DateTime asOf) {
    final set = standardSetOn;
    if (set == null) return null;
    final years = asOf.year - set.year;
    final beforeAnniversary =
        asOf.month < set.month || (asOf.month == set.month && asOf.day < set.day);
    return (beforeAnniversary ? years - 1 : years).clamp(0, 99);
  }

  /// True when either tier has a figure — one price is still a price.
  bool get isSet => price > 0 || educationPrice > 0;

  /// The figure for [tier], and whether it had to fall back to the other tier
  /// because the one asked for was never entered. Same ladder, and the same
  /// reporting, as [AvDeviceTemplate.priceForTier].
  ({double price, bool fallback}) priceForTier(PricingTier tier) {
    final wanted = tier == PricingTier.education ? educationPrice : price;
    if (wanted > 0) return (price: wanted, fallback: false);
    final other = tier == PricingTier.education ? price : educationPrice;
    if (other > 0) return (price: other, fallback: true);
    return (price: 0, fallback: false);
  }

  BaseCost copyWith({
    String? category,
    double? price,
    double? educationPrice,
    String? notes,
    String? standardModel,
    DateTime? standardSetOn,
    /// Null cannot be told from "leave it alone", and on this the two mean
    /// opposite things: a card gone back to hand-typed, and a card whose
    /// price was edited without touching its benchmark.
    bool clearStandard = false,
  }) => BaseCost(
    category: category ?? this.category,
    price: price ?? this.price,
    educationPrice: educationPrice ?? this.educationPrice,
    notes: notes ?? this.notes,
    standardModel: clearStandard ? '' : (standardModel ?? this.standardModel),
    standardSetOn:
        clearStandard ? null : (standardSetOn ?? this.standardSetOn),
  );

  Map<String, dynamic> toJson() => {
    'category': category,
    'price': price,
    'educationPrice': educationPrice,
    if (notes.isNotEmpty) 'notes': notes,
    if (standardModel.trim().isNotEmpty) 'standardModel': standardModel.trim(),
    if (standardSetOn != null) 'standardSetOn': formatIsoDate(standardSetOn!),
  };

  factory BaseCost.fromJson(Map<String, dynamic> json) => BaseCost(
    category: json['category']?.toString() ?? '',
    price: (json['price'] as num?)?.toDouble() ?? 0,
    // 'eduPrice' is read as an alias for the same reason the catalog reads it:
    // it is what a hand-written card tends to say.
    educationPrice:
        (json['educationPrice'] as num?)?.toDouble() ??
        (json['eduPrice'] as num?)?.toDouble() ??
        0,
    notes: json['notes']?.toString() ?? '',
    standardModel: json['standardModel']?.toString().trim() ?? '',
    standardSetOn: parseIsoDate(json['standardSetOn']),
  );
}

/// The category rate card. Ships with the families this app already knows
/// about — the ones the UI schema's device_types cover — all at 0, so the Cost
/// tab shows them as "not set" rather than quoting a room at made-up numbers.
/// The category a length of cable is priced under on the base-cost card —
/// "Cable: HDMI 25ft", or "Cable: HDMI" for the type's any-length figure.
///
/// A NAME rather than a new kind of record, so a cable figure is edited,
/// exported, saved and shared by everything that already handles this card.
/// The estimate builds the same string from the line it is pricing, which is
/// what makes a figure entered once reach every room.
String cableBaseCategory(String signalName, double lengthFt) {
  final label = signalName.trim().isEmpty ? 'cable' : signalName.trim();
  if (lengthFt <= 0) return 'Cable: $label';
  final feet = lengthFt == lengthFt.roundToDouble()
      ? '${lengthFt.round()}ft'
      : '${lengthFt.toStringAsFixed(1)}ft';
  return 'Cable: $label $feet';
}

/// True when [category] is one of the cable figures rather than a device one.
bool isCableBaseCategory(String category) =>
    category.trim().toLowerCase().startsWith('cable:');

class BaseCostBook {
  final List<BaseCost> costs;

  /// Where it was read from / will be written to. Empty until resolved.
  String filePath;

  /// For the App Config hint and the Cost tab's footer.
  String source;

  BaseCostBook({List<BaseCost>? costs, this.filePath = '', this.source = ''})
    : costs = costs ?? [];

  static const List<BaseCost> defaults = [
    BaseCost(category: 'Switcher', notes: 'Matrix / presentation switcher'),
    BaseCost(category: 'Camera', notes: 'PTZ or auto-tracking camera'),
    BaseCost(category: 'DSP', notes: 'Audio processor'),
    BaseCost(category: 'Amplifier'),
    BaseCost(category: 'Display', notes: 'Flat panel'),
    BaseCost(category: 'Projector'),
    BaseCost(category: 'Screen'),
    BaseCost(category: 'USB interface', notes: 'USB / soft-codec bridge'),
    BaseCost(category: 'Wireless presentation'),
    BaseCost(category: 'Recorder / streamer'),
    BaseCost(category: 'Control processor'),
    BaseCost(category: 'Touch panel'),
    BaseCost(category: 'Power controller'),
    BaseCost(category: 'Network switch'),
    BaseCost(category: 'Microphone'),
    BaseCost(category: 'Speaker'),
    BaseCost(category: 'Transmitter / receiver', notes: 'DTP / HDBaseT pair'),
    BaseCost(category: 'Mount / bracket'),
  ];

  factory BaseCostBook.builtIn() =>
      BaseCostBook(costs: List.of(defaults), source: 'Built-in defaults');

  /// Nobody has entered a single figure — the Cost tab says so rather than
  /// showing a column of zeroes as if they were prices.
  bool get allUnset => costs.every((c) => !c.isSet);

  int get setCount => costs.where((c) => c.isSet).length;

  static String _key(String category) => category.trim().toLowerCase();

  /// Extra catalog-category translations read from the file, on top of
  /// [kCategoryAliases]. Keyed like everything else here — trimmed and
  /// lower-cased — and pointing at a category name on this card.
  ///
  /// In the file rather than only in the code because the catalog's
  /// vocabulary is whatever the last import wrote, and a site that imports a
  /// second manufacturer should be able to teach the card its words without
  /// waiting for an app build.
  final Map<String, String> aliases = {};

  /// The category on this card that [category] means, or [category] itself
  /// when nothing translates it. File aliases win over the built-in table, so
  /// a site can correct one.
  String resolveCategory(String category) {
    final needle = _key(category);
    if (needle.isEmpty) return category;
    if (byCategory(category) != null) return category; // it is one of ours
    return aliases[needle] ?? kCategoryAliases[needle] ?? category;
  }

  /// Exact, case-insensitive. Aliases are deliberately NOT applied here: this
  /// is what the Base Costs editor adds to, renames and deletes, and an
  /// editor that quietly edited 'Switcher' when asked for 'Matrix' would be
  /// unusable.
  BaseCost? byCategory(String category) {
    final needle = _key(category);
    if (needle.isEmpty) return null;
    for (final c in costs) {
      if (_key(c.category) == needle) return c;
    }
    return null;
  }

  /// The figure to price a [category] device at, at [tier], and whether it
  /// fell back to the other tier. 0 when the category has no figure at all.
  ///
  /// [category] may be spelled the catalog's way ('Matrix') as well as this
  /// card's ('Switcher') — see [resolveCategory].
  ({double price, bool fallback}) priceFor(String category, PricingTier tier) =>
      byCategory(resolveCategory(category))?.priceForTier(tier) ??
      (price: 0.0, fallback: false);

  /// What a length of cable costs when the catalog does not price it.
  ///
  /// CABLE IS THE HOLE IN EVERY EARLY ESTIMATE. The runs are counted off the
  /// diagram exactly, and then priced at nothing, because the catalog ships
  /// with made-up leads for a handful of types and a room's real order is "a
  /// 25 ft HDMI and a 50 ft HDMI". Before this, the only way to put a figure
  /// on those was to type one on the room — which is a fact about the shop's
  /// supplier, not about the room, so it got retyped for every job and drifted
  /// between them.
  ///
  /// Filed as ordinary categories on this same card ([cableBaseCategory]), so
  /// they are edited, saved and shared exactly like the device figures.
  /// Longest-to-shortest match: the length asked for, then the type's own
  /// figure for any length.
  ({double price, bool fallback}) priceForCable(
    String signalName,
    double lengthFt,
    PricingTier tier,
  ) {
    if (lengthFt > 0) {
      final exact = byCategory(cableBaseCategory(signalName, lengthFt));
      if (exact != null && exact.isSet) return exact.priceForTier(tier);
    }
    final any = byCategory(cableBaseCategory(signalName, 0));
    if (any != null && any.isSet) return any.priceForTier(tier);
    return (price: 0.0, fallback: false);
  }

  void upsert(BaseCost cost) {
    final index = costs.indexWhere(
      (c) => _key(c.category) == _key(cost.category),
    );
    if (index < 0) {
      costs.add(cost);
    } else {
      costs[index] = cost;
    }
  }

  void remove(String category) =>
      costs.removeWhere((c) => _key(c.category) == _key(category));

  Map<String, dynamic> toJson() => {
    '__readme':
        'Base costs for the Room Config Builder: one typical unit price per '
        'device category at each of the two published tiers - "price" is MSRP '
        '(list) and "educationPrice" is the education price - used when a room '
        'has a switcher on the diagram but no model chosen yet. A model with a '
        'catalog price, or a price typed on the room, always wins over the '
        'figure here. 0 means "not set" and is reported as an unpriced line '
        'rather than costed at nothing. "aliases" translates a device '
        'catalog\'s own category names onto the categories below - '
        '"Matrix": "Switcher" - for families the app does not already know; '
        'leave a family out when it holds more than one kind of device, and '
        'the estimate will price it from the room\'s config section instead. '
        '"standardModel" and "standardSetOn" record WHICH product a '
        'category\'s figure was benchmarked on and when, so a refresh plan can '
        'say what its projectors are eleven OF; they are set from the campus '
        'report and never change a price themselves.',
    'costs': [for (final c in costs) c.toJson()],
    if (aliases.isNotEmpty) 'aliases': Map<String, String>.of(aliases),
  };

  /// Reads [path], falling back to the built-in categories when it isn't
  /// there. A broken file is logged and the built-ins stay active — a price
  /// list is not worth taking the app down for.
  static Future<BaseCostBook> load(String path) async {
    if (path.isEmpty) return BaseCostBook.builtIn();
    try {
      final file = File(path);
      if (!await file.exists()) {
        return BaseCostBook.builtIn()
          ..filePath = path
          ..source = 'Built-in defaults (no file at $path yet)';
      }
      final doc = jsonDecode(await file.readAsString());
      if (doc is! Map) throw const FormatException('Root must be an object.');
      final book = BaseCostBook(filePath: path, source: path);
      for (final c in (doc['costs'] as List? ?? [])) {
        if (c is Map) {
          final cost = BaseCost.fromJson(Map<String, dynamic>.from(c));
          if (cost.category.trim().isNotEmpty) book.costs.add(cost);
        }
      }
      // Categories the app knows about but the file predates: added back so a
      // book saved last year still offers this year's families.
      for (final d in defaults) {
        if (book.byCategory(d.category) == null) book.costs.add(d);
      }
      final aliases = doc['aliases'];
      if (aliases is Map) {
        for (final entry in aliases.entries) {
          final from = entry.key.toString().trim().toLowerCase();
          final to = entry.value?.toString().trim() ?? '';
          if (from.isNotEmpty && to.isNotEmpty) book.aliases[from] = to;
        }
      }
      AppLogger.logInfo(
        'Base costs loaded from $path (${book.costs.length} categories, '
        '${book.setCount} priced).',
      );
      return book;
    } catch (e, stack) {
      AppLogger.logError('Failed to load base costs from $path', e, stack);
      return BaseCostBook.builtIn()
        ..filePath = path
        ..source = 'Built-in defaults (failed to load $path: $e)';
    }
  }

  /// Writes the card. Returns the file written, or '' on failure.
  Future<String> save({String toPath = ''}) async {
    final target = toPath.isNotEmpty ? toPath : filePath;
    if (target.isEmpty) return '';
    try {
      const encoder = JsonEncoder.withIndent('  ');
      await File(target).parent.create(recursive: true);
      await File(target).writeAsString(encoder.convert(toJson()));
      filePath = target;
      source = target;
      AppLogger.logInfo('Base costs saved to $target.');
      return target;
    } catch (e, stack) {
      AppLogger.logError('Failed to save base costs to $target', e, stack);
      return '';
    }
  }
}

/// Catalog categories that mean exactly one thing on this card, lower-cased.
///
/// The test for being on this list is strict, because being wrong here is
/// worse than being absent: EVERY entry filed under the catalog category has
/// to be the kind of device the base cost describes. 'Matrix' passes — all
/// thirty entries are DTP CrossPoint matrix switchers. 'Scalers Switchers'
/// does not: it holds IN1608 presentation switchers next to a $200 EDID
/// emulator, and quoting the emulator at a switcher's price would put four
/// figures of nonsense in a budget with nothing on the line to say so.
///
/// The families deliberately left off — DTP Systems (transmitters AND
/// matrices), XTP Systems, Audio (DSPs, amplifiers, loudspeakers), Control
/// Systems (processors AND touch panels), Architectural (cable cubbies and
/// AC outlets, not screens), Fox Systems, Streaming, Collaboration Systems —
/// are priced instead off what the device is doing in the room, by
/// [categoryForConfigKey]. A room's SCREENDEVICE_1 is a screen whatever aisle
/// its controller was imported from.
const Map<String, String> kCategoryAliases = {
  'matrix': 'Switcher',
  'presentation switcher': 'Switcher',
  'usb': 'USB interface',
  'audio processor': 'DSP',
  'flat panel': 'Display',
  'monitor': 'Display',
};

/// The category a config device belongs to when the catalog has nothing to say
/// about its model — read off the section key, which is the one thing every
/// config device has.
///
/// Deliberately the same words as [BaseCostBook.defaults], so a room built
/// entirely from un-modeled devices still prices off the base card.
String categoryForConfigKey(String configKey) {
  final key = configKey.toUpperCase();
  const families = {
    'SWITCHERDEVICE_': 'Switcher',
    'CAMERADEVICE_': 'Camera',
    'DSPDEVICE_': 'DSP',
    'AMPDEVICE_': 'Amplifier',
    'PROJECTORDEVICE_': 'Projector',
    'DISPLAYDEVICE_': 'Display',
    'MONITORDEVICE_': 'Display',
    'SCREENDEVICE_': 'Screen',
    'USBDEVICE_': 'USB interface',
    'MEDIAPORTDEVICE_': 'USB interface',
    'WIRELESSDEVICE_': 'Wireless presentation',
    'RECORDERDEVICE_': 'Recorder / streamer',
    'STREAMDEVICE_': 'Recorder / streamer',
    'CONTROLDEVICE_': 'Control processor',
    'TOUCHDEVICE_': 'Touch panel',
    'PANELDEVICE_': 'Touch panel',
    'POWERDEVICE_': 'Power controller',
    'SWITCHDEVICE_': 'Network switch',
    'MICDEVICE_': 'Microphone',
    'SPEAKERDEVICE_': 'Speaker',
  };
  for (final entry in families.entries) {
    if (key.startsWith(entry.key)) return entry.value;
  }
  return '';
}
