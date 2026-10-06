import 'av_device_library.dart';

/// ============================================================================
///  CATALOG FILTERS: WARRANTIES AND OTHER MARKETS
/// ============================================================================
///  The price lists bring in service plans and the drawings bring in every
///  market's version of a product. Both are real catalog entries, but neither
///  is something you pick when specifying a US room, so the catalog can hide
///  them. Read off the name only: a switcher whose notes mention "DTP
///  Extension" is not a warranty.
/// ============================================================================

final _warranty = RegExp(
  r'warrant|service support|unit exchange|return for repair|'
  r'shipping upgrade|loaner|service plan|protection plan',
  caseSensitive: false,
);

/// True when [t] is a warranty extension or service plan rather than a
/// product.
bool isWarrantyItem(AvDeviceTemplate t) =>
    _warrantyCache[t] ??= _warranty.hasMatch(t.model);

// Remembered per entry, like the search keys: the catalog list asks about
// every entry on every keystroke, and an edited entry is a new object.
final Expando<bool> _warrantyCache = Expando('warranty items');
final Expando<String> _marketCache = Expando('entry markets');

// A market word on its own in the name: "AC 102 UK", "DTP3 T 202 EU/MK".
final _marketWord = RegExp(r'(^|[\s/(,-])(UK|EU|AUS|CN|JP|MK)($|[\s/),-])');

// Panasonic projectors carry the market at the end: C or CL China, E or EA
// Europe, T Taiwan, A Asia, D and the like after the B/W color letter.
final _panasonicMarket = RegExp(r'^PT-[A-Z]+\d+[A-Z]*?(?:C|CL|E|EA|ZE)$');
final _panasonicColorMarket = RegExp(r'^PT-[A-Z]+\d+[BW]?(?:A|D|T|E)$');

/// Which market [t] is made for when that is not the US: 'China', 'Europe',
/// 'UK' and so on. Null when it is a US model or nothing says otherwise.
String? nonUsMarket(AvDeviceTemplate t) {
  // '' marks "worked out, and US".
  final cached = _marketCache[t] ??= _market(t) ?? '';
  return cached.isEmpty ? null : cached;
}

String? _market(AvDeviceTemplate t) {
  final model = t.model.trim();
  final maker = t.manufacturer.trim().toLowerCase();
  final word = _marketWord.firstMatch(model)?.group(2);
  if (word != null) {
    return const {
      'UK': 'UK',
      'EU': 'Europe',
      'AUS': 'Australia',
      'CN': 'China',
      'JP': 'Japan',
      'MK': 'UK / Middle East',
    }[word];
  }
  if (maker == 'epson') {
    final m = model.toUpperCase();
    if (m.startsWith('CB-')) return 'Asia';
    // EB-PU and EB-PQ are sold in the US under that name.
    if (m.startsWith('EB-') &&
        !m.startsWith('EB-PU') &&
        !m.startsWith('EB-PQ')) {
      return 'Europe';
    }
  }
  if (maker == 'panasonic') {
    final m = model.toUpperCase();
    if (_panasonicMarket.hasMatch(m)) {
      return m.endsWith('C') || m.endsWith('CL') ? 'China' : 'Europe / Asia';
    }
    if (_panasonicColorMarket.hasMatch(m)) return 'Asia';
  }
  return null;
}
