import 'dart:convert';
import 'dart:io';

import 'app_logger.dart';

/// ============================================================================
///  LABOR RATES
/// ============================================================================
///  What an hour of somebody's time costs, per job type, kept in a file of its
///  own (`labor_rates.json` in the Root Folder) rather than per room — a rate
///  is a fact about the organization and the year, and re-typing it per room
///  is how two estimates for the same building end up quoting different
///  numbers for the same work.
///
///  A room's estimate references a rate by id and stores its own HOURS and
///  TECH COUNT, because those are facts about the job. The rate itself can
///  then be revised once and every estimate re-costs from it.
///
///  The shipped defaults are the roles this shop actually bills:
///
///    * CTS III / CTS IV — certified AV technicians, the bulk of an install
///    * TSRV            — technical services / shop labor
///    * FMS             — facilities, a placeholder so a job that needs
///                        conduit, ceiling work or a lift can carry a figure
///                        instead of pretending it is free
///
///  Placeholder means placeholder: the FMS rate ships at 0 so it shows up as
///  "not set" rather than quietly costing a job at a number nobody agreed to.
/// ============================================================================

// ---------------------------------------------------------------------------
//  INITIALISMS
// ---------------------------------------------------------------------------

/// Words that carry no weight in a shorthand: nobody says "NACAII" for a
/// Network and Communications Analyst II.
const Set<String> _kInitialismSkip = {'and', 'of', 'the', 'for', 'or', 'a',
    'to', 'in', 'on'};

final RegExp _kRomanNumeral = RegExp(r'^[IVX]+$');

/// A leading class number off a published schedule ('0482', '18XX'), which is
/// an index rather than part of the role's name.
final RegExp _kClassCode = RegExp(r'^\d[\dA-Za-z]*$');

/// The role's shorthand: "TSSIII" for "0482 Technology Support Specialist III
/// — Non-state", "ACRM" for "Air Conditioning/Refrigeration Mechanic".
///
/// Derived rather than stored, so it is right for a rate somebody adds by hand
/// this afternoon as well as for the ones off a published schedule, and so
/// renaming a role can never leave a stale abbreviation behind it.
///
/// A leading class number and anything after the funding-tier dash are dropped
/// — both are about which ROW of the schedule this is, not about the job.
/// Roman numerals and numbers survive whole, because the level is the part of
/// "TSS III" that does the work.
String laborRateInitialism(String name, {bool dropSmallWords = true}) {
  var text = name.trim();
  // A HYPHEN FIRST, then the two dashes older rate cards were typed with.
  // These are not display text: they are what a rate NAME on somebody's own
  // labor_rates.json is split on, and a card written before the app stopped
  // using em dashes still has to read. Written as escapes so the house rule
  // against em dashes in app text can be checked by looking for the character
  // itself - see app_language_test.dart.
  for (final separator in const [' - ', ' \u2014 ', ' \u2013 ']) {
    final at = text.indexOf(separator);
    if (at > 0) {
      text = text.substring(0, at);
      break;
    }
  }
  final words = text.split(RegExp(r'\s+'));
  if (words.length > 1 && _kClassCode.hasMatch(words.first)) words.removeAt(0);

  final buffer = StringBuffer();
  for (final raw in words.join(' ').split(RegExp(r'[^A-Za-z0-9]+'))) {
    if (raw.isEmpty) continue;
    if (dropSmallWords && _kInitialismSkip.contains(raw.toLowerCase())) {
      continue;
    }
    final word = raw.toUpperCase();
    if (_kRomanNumeral.hasMatch(word) || int.tryParse(word) != null) {
      buffer.write(word);
    } else {
      buffer.write(word[0]);
    }
  }
  return buffer.toString();
}

class LaborRate {
  /// Stable key an estimate line references.
  final String id;
  final String name;

  /// Currency per hour. 0 means "not set" — an estimate says so rather than
  /// costing the line at nothing.
  final double hourlyRate;

  /// What this role covers, shown under the name in the picker.
  final String notes;

  /// Whether tax applies to this labor by default. Labor is untaxed in most
  /// US jurisdictions; the estimate can still override per line.
  final bool taxable;

  const LaborRate({
    required this.id,
    required this.name,
    this.hourlyRate = 0,
    this.notes = '',
    this.taxable = false,
  });

  bool get isSet => hourlyRate > 0;

  /// The shorthand people actually say for this role — TSSIII for a Technology
  /// Support Specialist III, ACRM for an Air Conditioning/Refrigeration
  /// Mechanic. Shown beside the name in the picker and matched by [matches].
  String get initialism => laborRateInitialism(name);

  /// True when [query] should find this rate.
  ///
  /// Three ways in, because a rate card off a published schedule is read three
  /// ways: by name ("electrician"), by what the schedule calls it (a class
  /// number, or the funding wording in the notes), and by the shorthand nobody
  /// writes down but everybody says. The last one is why this exists — a job
  /// type filed as "Technology Support Specialist III" is one people look for
  /// by typing "tss".
  bool matches(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    if (name.toLowerCase().contains(needle) ||
        notes.toLowerCase().contains(needle) ||
        id.toLowerCase().contains(needle)) {
      return true;
    }
    // Spaces and roman-numeral spacing are how people type an initialism, not
    // part of it: "tss", "tssIII" and "tss iii" are the same search.
    final squashed = needle.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (squashed.isEmpty) return false;
    return initialism.toLowerCase().startsWith(squashed) ||
        laborRateInitialism(
          name,
          dropSmallWords: false,
        ).toLowerCase().startsWith(squashed);
  }

  LaborRate copyWith({
    String? name,
    double? hourlyRate,
    String? notes,
    bool? taxable,
  }) => LaborRate(
    id: id,
    name: name ?? this.name,
    hourlyRate: hourlyRate ?? this.hourlyRate,
    notes: notes ?? this.notes,
    taxable: taxable ?? this.taxable,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'hourlyRate': hourlyRate,
    if (notes.isNotEmpty) 'notes': notes,
    'taxable': taxable,
  };

  factory LaborRate.fromJson(Map<String, dynamic> json) => LaborRate(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? 'Labor',
    hourlyRate: (json['hourlyRate'] as num?)?.toDouble() ?? 0,
    notes: json['notes']?.toString() ?? '',
    taxable: json['taxable'] == true,
  );
}

/// The rate card. Ships with the roles this shop bills; every one of them is
/// editable, and rooms reference them by id.
class LaborRateBook {
  final List<LaborRate> rates;

  /// Where it was read from / will be written to. Empty until resolved.
  String filePath;

  /// For the App Config hint and the Cost tab's footer.
  String source;

  LaborRateBook({List<LaborRate>? rates, this.filePath = '', this.source = ''})
    : rates = rates ?? [];

  static const List<LaborRate> defaults = [
    LaborRate(
      id: 'cts3',
      name: 'CTS III',
      notes: 'Certified AV technician, level III',
    ),
    LaborRate(
      id: 'cts4',
      name: 'CTS IV',
      notes: 'Certified AV technician, level IV - lead / commissioning',
    ),
    LaborRate(
      id: 'tsrv',
      name: 'TSRV',
      notes: 'Technical services / shop labor',
    ),
    LaborRate(
      id: 'fms',
      name: 'FMS',
      notes: 'Facilities - conduit, ceiling work, lifts. Placeholder: set a '
          'rate only when the job actually needs it.',
    ),
  ];

  factory LaborRateBook.builtIn() =>
      LaborRateBook(rates: List.of(defaults), source: 'Built-in defaults');

  LaborRate? byId(String id) {
    for (final r in rates) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// True when nobody has entered a single figure — the Cost tab says so
  /// rather than showing four zeroed roles as if they were priced.
  bool get allUnset => rates.every((r) => !r.isSet);

  void upsert(LaborRate rate) {
    final index = rates.indexWhere((r) => r.id == rate.id);
    if (index < 0) {
      rates.add(rate);
    } else {
      rates[index] = rate;
    }
  }

  void remove(String id) => rates.removeWhere((r) => r.id == id);

  /// A new id that isn't taken, derived from the name.
  String newId(String name) {
    final base = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    var id = base.isEmpty ? 'rate' : base;
    var n = 2;
    while (byId(id) != null) {
      id = '${base}_$n';
      n++;
    }
    return id;
  }

  Map<String, dynamic> toJson() => {
    '__readme':
        'Labor rates for the Room Config Builder cost estimate. One entry per '
        'job type; rooms reference these by id and store their own hours and '
        'tech counts, so revising a rate here re-costs every estimate that '
        'uses it. A rate of 0 means "not set" and is reported as missing '
        'rather than costed at nothing.',
    'rates': [for (final r in rates) r.toJson()],
  };

  /// Reads [path], falling back to the built-in roles when it isn't there.
  /// A broken file is logged and the built-ins stay active — a rate card is
  /// not worth taking the app down for.
  static Future<LaborRateBook> load(String path) async {
    if (path.isEmpty) return LaborRateBook.builtIn();
    try {
      final file = File(path);
      if (!await file.exists()) {
        return LaborRateBook.builtIn()
          ..filePath = path
          ..source = 'Built-in defaults (no file at $path yet)';
      }
      final doc = jsonDecode(await file.readAsString());
      if (doc is! Map) throw const FormatException('Root must be an object.');
      final book = LaborRateBook(filePath: path, source: path);
      for (final r in (doc['rates'] as List? ?? [])) {
        if (r is Map) {
          final rate = LaborRate.fromJson(Map<String, dynamic>.from(r));
          if (rate.id.isNotEmpty) book.rates.add(rate);
        }
      }
      // A file that parsed but held nothing useful still gets the roles, so
      // the Cost tab is never left with an empty picker.
      if (book.rates.isEmpty) book.rates.addAll(defaults);
      AppLogger.logInfo(
        'Labor rates loaded from $path (${book.rates.length} job types).',
      );
      return book;
    } catch (e, stack) {
      AppLogger.logError('Failed to load labor rates from $path', e, stack);
      return LaborRateBook.builtIn()
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
      AppLogger.logInfo('Labor rates saved to $target.');
      return target;
    } catch (e, stack) {
      AppLogger.logError('Failed to save labor rates to $target', e, stack);
      return '';
    }
  }
}

/// One crew on one job: which rate, how many of them, for how long.
///
/// Kept as rate × techs × hours rather than a single figure because that is
/// how the work is actually estimated and how it gets checked — "two CTS III
/// for three days" is arguable; "$4,560" is not.
class LaborLine {
  final String id;

  /// [LaborRate.id]; '' means the line carries its own rate instead.
  final String rateId;

  /// Used when [rateId] is empty, or when this job pays something other than
  /// the card rate.
  final double customRate;

  final String description;
  final double techs;
  final double hours;
  final bool taxable;

  const LaborLine({
    required this.id,
    this.rateId = '',
    this.customRate = 0,
    this.description = '',
    this.techs = 1,
    this.hours = 0,
    this.taxable = false,
  });

  LaborLine copyWith({
    String? rateId,
    double? customRate,
    String? description,
    double? techs,
    double? hours,
    bool? taxable,
  }) => LaborLine(
    id: id,
    rateId: rateId ?? this.rateId,
    customRate: customRate ?? this.customRate,
    description: description ?? this.description,
    techs: techs ?? this.techs,
    hours: hours ?? this.hours,
    taxable: taxable ?? this.taxable,
  );

  /// The hourly rate this line costs at: its own override when set, else the
  /// card's rate for [rateId].
  double rateFrom(LaborRateBook book) {
    if (customRate > 0) return customRate;
    return book.byId(rateId)?.hourlyRate ?? 0;
  }

  double totalHours() => techs * hours;

  double totalFrom(LaborRateBook book) => totalHours() * rateFrom(book);

  Map<String, dynamic> toJson() => {
    'id': id,
    if (rateId.isNotEmpty) 'rateId': rateId,
    if (customRate > 0) 'customRate': customRate,
    if (description.isNotEmpty) 'description': description,
    'techs': techs,
    'hours': hours,
    'taxable': taxable,
  };

  factory LaborLine.fromJson(Map<String, dynamic> json) => LaborLine(
    id: json['id']?.toString() ?? '',
    rateId: json['rateId']?.toString() ?? '',
    customRate: (json['customRate'] as num?)?.toDouble() ?? 0,
    description: json['description']?.toString() ?? '',
    techs: (json['techs'] as num?)?.toDouble() ?? 1,
    hours: (json['hours'] as num?)?.toDouble() ?? 0,
    taxable: json['taxable'] == true,
  );
}
