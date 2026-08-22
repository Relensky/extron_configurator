import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'av_device_library.dart' show AvDeviceLibrary;

/// ============================================================================
///  THE BUILDING PROJECT
/// ============================================================================
///  A room is one config and its sidecars. A JOB is usually a building: eight
///  classrooms, two conference rooms and a lecture hall, quoted together,
///  ordered together, and installed by the same crew over the same fortnight.
///
///  Nothing in the app knew that. Every room priced itself in isolation, so the
///  number anybody actually needed — what the building costs — was arrived at
///  by opening nine rooms in turn and adding up nine screenshots. And the
///  ORDER was worse: nine separate equipment lists, each with its own two
///  Extron switchers on it, sent to a vendor who then quotes eighteen line
///  items for a building that needs eighteen switchers spread across nine
///  rooms and would rather buy them as one line.
///
///  A project fixes both by being a THIN thing. It is a list of room config
///  paths and some job metadata — it does not own the rooms, copy them, or
///  lock them. Each room stays exactly the file it was: openable on its own,
///  editable on its own, and able to belong to two projects at once (a
///  building-wide refresh and a departmental sub-job frequently want the same
///  classroom). Re-pricing a project re-reads the rooms off disk, so a price
///  fixed in a room this morning is in the building total this afternoon
///  without anybody re-importing anything.
///
///  VENDORS are the other half. Which company quotes a part is a fact about
///  the JOB, not about the product — the same 86" display goes through the
///  manufacturer on one contract and a reseller on the next — so the tags live
///  here rather than in the catalog. They are assigned two ways:
///
///    * BY RULE. A vendor lists the manufacturers it quotes, and every part by
///      those makers tags itself. One line of setup covers "all Extron to
///      Extron Direct" for the whole building.
///    * BY HAND. Any part on the master list can be pinned to a vendor,
///      overriding the rules. Stored per PART rather than per room-line,
///      because that is the decision being made: "we buy the ceiling mics from
///      the integrator" is true of the whole job at once.
///
///  See project_estimate.dart for the rollup that turns this plus the rooms on
///  disk into per-room totals, a master parts list and per-vendor packages.
/// ============================================================================

// ---------------------------------------------------------------------------
//  VENDORS
// ---------------------------------------------------------------------------

/// How a part came by the vendor it is tagged with — shown on the master list
/// so a tag can be argued with. "Why is the projector going to the reseller?"
/// has three different answers and three different fixes, and a bare vendor
/// name gives none of them.
enum VendorTagSource {
  /// Somebody pinned this part by hand. Beats every rule.
  pinned,

  /// A vendor's manufacturer list claims the maker.
  manufacturerRule,

  /// A vendor's category list claims the kind of part.
  categoryRule,

  /// Nothing claims it — it lands in the untagged package, which is the
  /// project's to-do list rather than a vendor.
  none,
}

const Map<VendorTagSource, String> kVendorTagSourceLabels = {
  VendorTagSource.pinned: 'Pinned',
  VendorTagSource.manufacturerRule: 'By manufacturer',
  VendorTagSource.categoryRule: 'By category',
  VendorTagSource.none: 'Untagged',
};

/// A company the job buys from, and what it is assumed to quote.
class ProjectVendor {
  final String id;
  final String name;

  /// Who the RFQ goes to. Written onto the vendor's own quote sheet, because
  /// the file gets emailed and the person emailing it should not have to go
  /// looking for the address in a different system.
  final String contact;

  /// Anything the quote request should say — contract number, terms, the fact
  /// that this one needs a delivery date before it can be approved.
  final String notes;

  /// The makers this vendor quotes, matched case-insensitively against a
  /// part's manufacturer.
  final List<String> manufacturers;

  /// The catalog categories this vendor quotes — 'Camera', 'Display',
  /// 'USB Extender'. The other half of the rule, and the half the split is
  /// usually described with: "everything Extron" is a maker, but "cameras,
  /// screens and USB interfaces" is three categories from four different
  /// makers, and no list of manufacturers expresses it without naming every
  /// brand anybody might ever specify.
  ///
  /// Matched case-insensitively, and by PREFIX as well as in full, because
  /// the catalog's categories are finer than a purchasing split is: a rule
  /// for 'Camera' should claim 'Camera - PTZ' without the buyer having to
  /// enumerate the variants a catalog import invented.
  final List<String> categories;

  /// Both lists empty = assigned by hand only, which is a legitimate setup:
  /// an integrator quoting a mixed bag of parts has nothing about the parts
  /// themselves that identifies it.
  bool get hasRules => manufacturers.isNotEmpty || categories.isNotEmpty;

  const ProjectVendor({
    required this.id,
    required this.name,
    this.contact = '',
    this.notes = '',
    this.manufacturers = const [],
    this.categories = const [],
  });

  ProjectVendor copyWith({
    String? name,
    String? contact,
    String? notes,
    List<String>? manufacturers,
    List<String>? categories,
  }) => ProjectVendor(
    id: id,
    name: name ?? this.name,
    contact: contact ?? this.contact,
    notes: notes ?? this.notes,
    manufacturers: manufacturers ?? this.manufacturers,
    categories: categories ?? this.categories,
  );

  /// True when this vendor's manufacturer rules claim [manufacturer].
  bool quotesManufacturer(String manufacturer) {
    final needle = manufacturer.trim().toLowerCase();
    if (needle.isEmpty) return false;
    for (final m in manufacturers) {
      if (m.trim().toLowerCase() == needle) return true;
    }
    return false;
  }

  /// True when this vendor's category rules claim [category], in full or as
  /// the head of a finer one ('Camera' claims 'Camera - PTZ').
  bool quotesCategory(String category) {
    final needle = category.trim().toLowerCase();
    if (needle.isEmpty) return false;
    for (final c in categories) {
      final rule = c.trim().toLowerCase();
      if (rule.isEmpty) continue;
      if (needle == rule) return true;
      // Only on a word boundary: a 'Mic' rule must not swallow 'Microwave
      // link', and a 'Camera' rule must not swallow 'Cameraman kit'.
      if (needle.startsWith(rule) &&
          RegExp(r'[^a-z0-9]').hasMatch(needle[rule.length])) {
        return true;
      }
    }
    return false;
  }

  /// True when either rule claims the part. Manufacturer is checked first
  /// only for reporting — for the answer itself, either is enough.
  bool quotes({String manufacturer = '', String category = ''}) =>
      quotesManufacturer(manufacturer) || quotesCategory(category);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (contact.isNotEmpty) 'contact': contact,
    if (notes.isNotEmpty) 'notes': notes,
    if (manufacturers.isNotEmpty) 'manufacturers': manufacturers,
    if (categories.isNotEmpty) 'categories': categories,
  };

  factory ProjectVendor.fromJson(Map<String, dynamic> json) {
    List<String> list(String key) => [
      for (final m in (json[key] as List? ?? []))
        if (m.toString().trim().isNotEmpty) m.toString().trim(),
    ];
    return ProjectVendor(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Vendor',
      contact: json['contact']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      manufacturers: list('manufacturers'),
      categories: list('categories'),
    );
  }
}

// ---------------------------------------------------------------------------
//  ROOMS IN THE PROJECT
// ---------------------------------------------------------------------------

/// One room on the job: where its config lives, and whether it counts.
class ProjectRoomRef {
  final String id;

  /// The room's config.json, stored RELATIVE to the project file whenever it
  /// sits under the same folder tree — see [resolvePath] and
  /// [BuildingProject.storePath].
  ///
  /// A building's rooms and its project file travel together: onto a laptop,
  /// into a backup, across to whoever is covering next week. Absolute paths
  /// break every one of those moves, and break them silently — the project
  /// opens, the rooms are all "missing", and the total reads as zero rather
  /// than as an error.
  final String configPath;

  /// What to call this room when the config's own name is wrong or absent.
  /// Blank means "read it from the config", which is what almost every room
  /// wants — renaming the room should rename it on the quote.
  final String label;

  /// Off the rollup without being removed from the job.
  ///
  /// An alternate is a real thing on a real bid: two versions of the same
  /// lecture hall, one with the camera package and one without, both priced,
  /// one of them chosen. Deleting the loser loses the work; leaving it in the
  /// total makes the building read double.
  final bool included;

  /// Free text on the row — "phase 2", "waiting on the ceiling survey".
  final String notes;

  const ProjectRoomRef({
    required this.id,
    required this.configPath,
    this.label = '',
    this.included = true,
    this.notes = '',
  });

  ProjectRoomRef copyWith({
    String? configPath,
    String? label,
    bool? included,
    String? notes,
  }) => ProjectRoomRef(
    id: id,
    configPath: configPath ?? this.configPath,
    label: label ?? this.label,
    included: included ?? this.included,
    notes: notes ?? this.notes,
  );

  /// The name to show before the room has been read off disk — the label if
  /// there is one, otherwise the file's own name, which is nearly always the
  /// room ("BSS_101_config.json").
  String get fallbackName {
    if (label.trim().isNotEmpty) return label.trim();
    final base = path.basenameWithoutExtension(configPath);
    return base.isEmpty ? configPath : base;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'configPath': configPath,
    if (label.isNotEmpty) 'label': label,
    if (!included) 'included': false,
    if (notes.isNotEmpty) 'notes': notes,
  };

  factory ProjectRoomRef.fromJson(Map<String, dynamic> json) => ProjectRoomRef(
    id: json['id']?.toString() ?? '',
    configPath: json['configPath']?.toString() ?? '',
    label: json['label']?.toString() ?? '',
    included: json['included'] != false,
    notes: json['notes']?.toString() ?? '',
  );
}

// ---------------------------------------------------------------------------
//  THE MASTER-LIST PART KEY
// ---------------------------------------------------------------------------

/// What makes two lines in two different rooms THE SAME PART on one order.
///
/// The estimate's own line key cannot do this job. It is built for a single
/// room — a model-less device is keyed on its node id, a cable line on the
/// length it happens to be cut to — so the same product in two rooms can key
/// two different ways, and merging on it would put four displays on one line
/// in one room and four separate lines in the building.
///
/// So the merge runs down the identifiers in the order a purchasing department
/// would use them:
///
///   1. PART NUMBER, when it is a real one. Two entries that order under
///      60-1439-13 are one line however they are named on two drawings, and
///      this is the only identifier the vendor's own system shares with ours.
///   2. MODEL, for a part the catalog has no ordering code for yet. Still
///      unambiguous within a maker's range.
///   3. MAKER AND DESCRIPTION, for a hand-typed line with neither. Two rooms
///      that both typed "Ceiling speaker pair" merge; a room that typed
///      "Ceiling speakers" does not, and that is the honest outcome — the app
///      cannot know they are the same thing and guessing would quietly halve
///      an order.
///
/// [kind] is part of the key so a cable and a device that happen to share a
/// description never merge across the section boundary the quote is read by.
String masterPartKey({
  required String kind,
  String partNumber = '',
  String model = '',
  String manufacturer = '',
  String description = '',
}) {
  if (AvDeviceLibrary.isRealPartNumber(partNumber)) {
    return '$kind|pn:${AvDeviceLibrary.normalizePartNumber(partNumber)}';
  }
  final m = model.trim().toLowerCase();
  if (m.isNotEmpty) return '$kind|model:$m';
  final maker = manufacturer.trim().toLowerCase();
  final desc = description.trim().toLowerCase();
  return '$kind|desc:$maker~$desc';
}

// ---------------------------------------------------------------------------
//  THE PROJECT
// ---------------------------------------------------------------------------

/// A building's worth of rooms, quoted as one job.
class BuildingProject {
  /// What the job is called on the front of the quote.
  String name;

  /// The building, as a code from buildings.json or as a name typed in. Not
  /// resolved here: the project is written and read with no app around it, and
  /// a code that cannot be looked up should still come back out unchanged.
  String building;

  String jobNumber;
  String client;
  String notes;

  /// The symbol every figure in the rollup is written in. Rooms carry their
  /// own — a project total can only be one number, so the project's symbol
  /// wins and a room quoted in something else is flagged rather than silently
  /// added (see ProjectEstimate.mixedCurrency).
  String currency;

  final List<ProjectRoomRef> rooms;
  final List<ProjectVendor> vendors;

  /// Master part key (see [masterPartKey]) -> vendor id, for the parts
  /// somebody has pinned by hand. Beats the manufacturer rules; an entry whose
  /// vendor has since been deleted resolves to untagged rather than to a
  /// dangling name.
  final Map<String, String> partVendors;

  /// Counters behind [nextRoomId] / [nextVendorId], persisted so ids stay
  /// unique across sessions — a reused id would re-point somebody's hand
  /// vendor tags at a different room.
  int _roomCounter;
  int _vendorCounter;

  BuildingProject({
    this.name = '',
    this.building = '',
    this.jobNumber = '',
    this.client = '',
    this.notes = '',
    this.currency = r'$',
    List<ProjectRoomRef>? rooms,
    List<ProjectVendor>? vendors,
    Map<String, String>? partVendors,
    int roomCounter = 0,
    int vendorCounter = 0,
  }) : rooms = rooms ?? [],
       vendors = vendors ?? [],
       partVendors = partVendors ?? {},
       _roomCounter = roomCounter,
       _vendorCounter = vendorCounter;

  bool get isEmpty =>
      rooms.isEmpty &&
      vendors.isEmpty &&
      partVendors.isEmpty &&
      name.trim().isEmpty &&
      building.trim().isEmpty &&
      jobNumber.trim().isEmpty &&
      client.trim().isEmpty &&
      notes.trim().isEmpty;

  /// The rooms that count toward the total.
  List<ProjectRoomRef> get includedRooms =>
      [for (final r in rooms) if (r.included) r];

  String nextRoomId() => 'room${++_roomCounter}';
  String nextVendorId() => 'vendor${++_vendorCounter}';

  ProjectVendor? vendorById(String id) {
    if (id.isEmpty) return null;
    for (final v in vendors) {
      if (v.id == id) return v;
    }
    return null;
  }

  ProjectRoomRef? roomById(String id) {
    for (final r in rooms) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Which vendor quotes a part, and why.
  ///
  /// The hand pin first — it exists precisely to beat the rules. Then the
  /// MANUFACTURER rules before the CATEGORY ones, because that is the
  /// stronger statement: "we buy Extron direct" is a purchasing relationship,
  /// while "the reseller does screens" is a default for everything nobody has
  /// a relationship for. A job that buys Extron direct and screens from a
  /// reseller must not send the Extron display to the reseller just because
  /// it is a screen — and without this ordering, whichever vendor happened to
  /// be created first would decide.
  ///
  /// Within a tier, the first matching vendor wins. That is deliberate and the
  /// UI says so: two vendors both claiming Extron is a setup mistake, and
  /// picking the earlier one gives a stable, explainable answer instead of an
  /// arbitrary one that moves when a vendor is renamed.
  ({ProjectVendor? vendor, VendorTagSource source}) vendorForPart(
    String partKey, {
    String manufacturer = '',
    String category = '',
  }) {
    final pinnedId = partVendors[partKey];
    if (pinnedId != null && pinnedId.isNotEmpty) {
      final v = vendorById(pinnedId);
      // A pin to a vendor that has been deleted is dead, not sticky: fall
      // through to the rules so the part lands somewhere real.
      if (v != null) return (vendor: v, source: VendorTagSource.pinned);
    }
    for (final v in vendors) {
      if (v.quotesManufacturer(manufacturer)) {
        return (vendor: v, source: VendorTagSource.manufacturerRule);
      }
    }
    for (final v in vendors) {
      if (v.quotesCategory(category)) {
        return (vendor: v, source: VendorTagSource.categoryRule);
      }
    }
    return (vendor: null, source: VendorTagSource.none);
  }

  /// Vendors whose rules overlap — the setup mistake [vendorForPart] resolves
  /// by order. Surfaced so it can be fixed rather than lived with.
  ///
  /// Only LIKE rules collide. A manufacturer rule and a category rule that
  /// both cover the same part are not a mistake, they are the normal case the
  /// tier ordering exists for, and reporting them would bury the real
  /// conflicts under noise on every project.
  List<({String rule, String kind, List<ProjectVendor> vendors})>
  get vendorConflicts {
    final out = <({String rule, String kind, List<ProjectVendor> vendors})>[];

    void collide(String kind, List<String> Function(ProjectVendor) rulesOf) {
      final byRule = <String, List<ProjectVendor>>{};
      final display = <String, String>{};
      for (final v in vendors) {
        for (final r in rulesOf(v)) {
          final key = r.trim().toLowerCase();
          if (key.isEmpty) continue;
          display.putIfAbsent(key, () => r.trim());
          byRule.putIfAbsent(key, () => []).add(v);
        }
      }
      byRule.forEach((key, vs) {
        if (vs.length > 1) {
          out.add((rule: display[key] ?? key, kind: kind, vendors: vs));
        }
      });
    }

    collide('Manufacturer', (v) => v.manufacturers);
    collide('Category', (v) => v.categories);
    out.sort((a, b) {
      final byKind = a.kind.compareTo(b.kind);
      return byKind != 0
          ? byKind
          : a.rule.toLowerCase().compareTo(b.rule.toLowerCase());
    });
    return out;
  }

  /// Pins [partKey] to [vendorId], or clears the pin when it is blank.
  void pinPart(String partKey, String vendorId) {
    if (vendorId.isEmpty) {
      partVendors.remove(partKey);
    } else {
      partVendors[partKey] = vendorId;
    }
  }

  /// Drops a vendor and every pin that named it. Leaving the pins would make
  /// the parts unreachable — tagged to a vendor with no row to click.
  void removeVendor(String id) {
    vendors.removeWhere((v) => v.id == id);
    partVendors.removeWhere((_, v) => v == id);
  }

  // -------------------------------------------------------------------------
  //  PATHS
  // -------------------------------------------------------------------------

  /// A stored room path made absolute, against the folder the project file is
  /// in. An absolute stored path is returned as-is, so a room deliberately
  /// kept somewhere else still resolves.
  static String resolvePath(String stored, String projectPath) {
    if (stored.isEmpty) return '';
    if (path.isAbsolute(stored)) return path.normalize(stored);
    if (projectPath.isEmpty) return path.normalize(stored);
    return path.normalize(
      path.join(path.dirname(projectPath), stored),
    );
  }

  /// How a room path should be WRITTEN into a project saved at [projectPath]:
  /// relative when the room is under the project's folder, absolute otherwise.
  ///
  /// The condition matters. Relativising a path that climbs out of the folder
  /// produces `..\..\..\other_building\room_config.json`, which is both
  /// unreadable and fragile — it breaks the moment the project file moves,
  /// which is the exact thing relative paths were supposed to survive.
  static String storePath(String absolute, String projectPath) {
    if (absolute.isEmpty || projectPath.isEmpty) return absolute;
    final root = path.dirname(projectPath);
    final rel = path.relative(absolute, from: root);
    if (rel.startsWith('..') || path.isAbsolute(rel)) return absolute;
    return rel;
  }

  /// This project's rooms as absolute config paths, in project order.
  List<String> resolvedRoomPaths(String projectPath) => [
    for (final r in rooms) resolvePath(r.configPath, projectPath),
  ];

  // -------------------------------------------------------------------------
  //  PERSISTENCE
  // -------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
    '__readme':
        'Room Config Builder project: a building quoted as one job. The '
        'rooms are references to config.json files, not copies — editing a '
        'room edits it here too. Paths are relative to this file when the '
        'room sits under the same folder.',
    'version': 1,
    'name': name,
    'building': building,
    if (jobNumber.isNotEmpty) 'jobNumber': jobNumber,
    if (client.isNotEmpty) 'client': client,
    if (notes.isNotEmpty) 'notes': notes,
    'currency': currency,
    'rooms': [for (final r in rooms) r.toJson()],
    'vendors': [for (final v in vendors) v.toJson()],
    if (partVendors.isNotEmpty) 'partVendors': partVendors,
    'roomCounter': _roomCounter,
    'vendorCounter': _vendorCounter,
  };

  factory BuildingProject.fromJson(Map<String, dynamic> json) {
    final rooms = [
      for (final r in (json['rooms'] as List? ?? []))
        if (r is Map) ProjectRoomRef.fromJson(Map<String, dynamic>.from(r)),
    ];
    final vendors = [
      for (final v in (json['vendors'] as List? ?? []))
        if (v is Map) ProjectVendor.fromJson(Map<String, dynamic>.from(v)),
    ];
    final pins = <String, String>{};
    final rawPins = json['partVendors'];
    if (rawPins is Map) {
      rawPins.forEach((k, v) => pins[k.toString()] = v.toString());
    }

    // Counters are rebuilt from the ids present as well as read from the file:
    // a project hand-edited to add a room (which is a supported thing to do —
    // see the readme key) has ids the stored counter has never seen, and
    // handing out one of them again would silently merge two rooms.
    int highest(Iterable<String> ids, String prefix) {
      var best = 0;
      for (final id in ids) {
        if (!id.startsWith(prefix)) continue;
        final n = int.tryParse(id.substring(prefix.length));
        if (n != null && n > best) best = n;
      }
      return best;
    }

    return BuildingProject(
      name: json['name']?.toString() ?? '',
      building: json['building']?.toString() ?? '',
      jobNumber: json['jobNumber']?.toString() ?? '',
      client: json['client']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      currency: json['currency']?.toString().isNotEmpty == true
          ? json['currency'].toString()
          : r'$',
      rooms: rooms,
      vendors: vendors,
      partVendors: pins,
      roomCounter: [
        (json['roomCounter'] as num?)?.toInt() ?? 0,
        highest(rooms.map((r) => r.id), 'room'),
      ].reduce((a, b) => a > b ? a : b),
      vendorCounter: [
        (json['vendorCounter'] as num?)?.toInt() ?? 0,
        highest(vendors.map((v) => v.id), 'vendor'),
      ].reduce((a, b) => a > b ? a : b),
    );
  }

  /// Reads a project file. Throws with a readable message rather than a
  /// decoder error, because this path is one file-picker click from a user
  /// who picked the wrong json.
  static Future<BuildingProject> load(String file) async {
    final text = await File(file).readAsString();
    final doc = jsonDecode(text);
    if (doc is! Map) {
      throw const FormatException(
        'That file is not a project — its root is not an object.',
      );
    }
    final map = Map<String, dynamic>.from(doc);
    if (!map.containsKey('rooms')) {
      throw const FormatException(
        'That file has no "rooms" list, so it is not a project file. A room '
        'config is opened with Open Config instead.',
      );
    }
    return BuildingProject.fromJson(map);
  }

  Future<void> save(String file) async {
    const encoder = JsonEncoder.withIndent('    ');
    await File(file).writeAsString(encoder.convert(toJson()));
  }

  /// A deep-enough copy for the undo of a destructive edit (removing a room,
  /// deleting a vendor) — every collection this class mutates is fresh, and
  /// the entries themselves are immutable.
  BuildingProject clone() => BuildingProject(
    name: name,
    building: building,
    jobNumber: jobNumber,
    client: client,
    notes: notes,
    currency: currency,
    rooms: List<ProjectRoomRef>.from(rooms),
    vendors: List<ProjectVendor>.from(vendors),
    partVendors: Map<String, String>.from(partVendors),
    roomCounter: _roomCounter,
    vendorCounter: _vendorCounter,
  );
}

/// The file suffix a project is saved under, so the picker and the "is this a
/// project?" check agree on one spelling.
const String kProjectFileSuffix = '_project.json';

/// The vendor split nearly every job starts from: the control line bought
/// direct from its manufacturer, and the room hardware — cameras, screens,
/// USB — bought from whoever resells it.
///
/// Offered on a new project rather than imposed, and expressed the way the
/// split is actually described: ONE manufacturer rule for the direct line,
/// CATEGORY rules for the rest. Naming categories rather than brands is what
/// makes the second vendor survive contact with a real room — a job that
/// specifies a camera brand nobody listed still tags it, instead of landing
/// in the untagged pile for somebody to notice.
///
/// The manufacturer rule is on the FIRST vendor deliberately: an Extron
/// display is bought direct, not from the reseller who does screens, and
/// [BuildingProject.vendorForPart] resolves that by tier rather than by luck.
List<ProjectVendor> starterVendors(BuildingProject project) => [
  ProjectVendor(
    id: project.nextVendorId(),
    name: 'Extron Direct',
    notes: 'Everything Extron makes, bought on the direct account.',
    manufacturers: const ['Extron'],
  ),
  ProjectVendor(
    id: project.nextVendorId(),
    name: 'AV Reseller',
    notes: 'Cameras, screens, USB and the mounting hardware that goes with '
        'them.',
    categories: const [
      'Camera',
      'Display',
      'Projector',
      'Screen',
      'Mount',
      'USB',
      'Speaker',
      'Microphone',
    ],
  ),
];
