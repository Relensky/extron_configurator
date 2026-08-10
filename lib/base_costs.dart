import 'dart:convert';
import 'dart:io';

import 'app_logger.dart';
import 'av_device_library.dart' show PricingTier;

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
///    4. nothing, and the estimate reports the line as unpriced
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

  const BaseCost({
    required this.category,
    this.price = 0,
    this.educationPrice = 0,
    this.notes = '',
  });

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
  }) => BaseCost(
    category: category ?? this.category,
    price: price ?? this.price,
    educationPrice: educationPrice ?? this.educationPrice,
    notes: notes ?? this.notes,
  );

  Map<String, dynamic> toJson() => {
    'category': category,
    'price': price,
    'educationPrice': educationPrice,
    if (notes.isNotEmpty) 'notes': notes,
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
  );
}

/// The category rate card. Ships with the families this app already knows
/// about — the ones the UI schema's device_types cover — all at 0, so the Cost
/// tab shows them as "not set" rather than quoting a room at made-up numbers.
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
  ({double price, bool fallback}) priceFor(String category, PricingTier tier) =>
      byCategory(category)?.priceForTier(tier) ??
      (price: 0.0, fallback: false);

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
        'device category at each of the two published tiers — "price" is MSRP '
        '(list) and "educationPrice" is the education price — used when a room '
        'has a switcher on the diagram but no model chosen yet. A model with a '
        'catalog price, or a price typed on the room, always wins over the '
        'figure here. 0 means "not set" and is reported as an unpriced line '
        'rather than costed at nothing.',
    'costs': [for (final c in costs) c.toJson()],
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
