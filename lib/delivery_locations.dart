import 'dart:convert';
import 'dart:io';

import 'app_logger.dart';

/// ============================================================================
///  DELIVERY LOCATIONS
/// ============================================================================
///  The docks a truck can back up to, and the rooms kit is held in until it
///  goes up. Kept in a file of its own (`delivery_locations.json` in the Root
///  Folder) rather than per job, for the reason the rate card is: a loading
///  dock is a fact about the ESTATE, and retyping "MLIB basement, rack 3" on
///  every delivery is how one shelf becomes four spellings that no filter can
///  put back together.
///
///  SHARED, LIKE THE CATALOG. Point the path at a drive everybody reads and
///  the whole shop logs deliveries against the same names, which is what makes
///  "everything at Central Stores" a question a job can answer.
///
///  STILL NOT A LIST TO PICK FROM. A delivery row's location is free text and
///  stays free text - the delivery that matters is the one that went somewhere
///  nobody had listed. This is what the picker OFFERS, not what it allows.
/// ============================================================================

/// What a place is for. A dock takes deliveries, a store holds gear, and most
/// of the useful ones do both.
enum DeliveryLocationUse {
  /// Somewhere a truck delivers to.
  delivery('Delivery point', 'takes deliveries'),

  /// Somewhere gear is held until it goes in.
  storage('Storage', 'holds gear'),

  /// Both, which is what a loading dock with a cage behind it actually is.
  both('Delivery and storage', 'takes deliveries and holds gear');

  /// What the dropdown reads.
  final String label;

  /// The half-sentence form, for a row that reads as prose.
  final String phrase;

  const DeliveryLocationUse(this.label, this.phrase);

  /// True when this place should be offered for holding gear.
  bool get holds => this != DeliveryLocationUse.delivery;

  /// True when this place should be offered as somewhere a truck delivers to.
  bool get receives => this != DeliveryLocationUse.storage;
}

/// A [DeliveryLocationUse] by name, defaulting to [DeliveryLocationUse.both].
///
/// Tolerant because the file is a supported thing to hand edit, and "it is
/// both" is the safe reading of a use this build does not know: the place is
/// still offered rather than quietly disappearing out of the picker.
DeliveryLocationUse deliveryLocationUseFromName(Object? raw) {
  final name = raw?.toString().trim().toLowerCase() ?? '';
  for (final u in DeliveryLocationUse.values) {
    if (u.name.toLowerCase() == name) return u;
  }
  return DeliveryLocationUse.both;
}

/// One place kit can be delivered to or held at.
class DeliveryLocation {
  /// Stable key. Nothing references it yet - a delivery row stores the NAME,
  /// because the row has to keep reading right after the place is renamed or
  /// dropped off the list - but an editor needs something to edit against
  /// while the name is being typed over.
  final String id;

  /// WHAT GOES ON THE DELIVERY ROW: 'MLIB loading dock', 'Central Stores'.
  /// This is the text the picker writes, so it is worth it being the whole
  /// answer rather than a shorthand.
  final String name;

  /// The street address, dock number, or room. Shown under the name in the
  /// picker and never written onto a row - a delivery log reads better with
  /// short places on it, and the address is looked up here when somebody
  /// actually has to drive there.
  final String address;

  final DeliveryLocationUse use;

  /// Anything the person delivering needs: the hours, who to ring, which door.
  final String notes;

  const DeliveryLocation({
    required this.id,
    required this.name,
    this.address = '',
    this.use = DeliveryLocationUse.both,
    this.notes = '',
  });

  /// True when [query] should find this place.
  bool matches(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    return name.toLowerCase().contains(needle) ||
        address.toLowerCase().contains(needle) ||
        notes.toLowerCase().contains(needle);
  }

  /// The line under the name in a picker: the address, else the notes, else
  /// what the place is for. Never blank, because a menu of bare names with one
  /// gap in it reads as a broken row.
  String get detail {
    if (address.trim().isNotEmpty) return address.trim();
    if (notes.trim().isNotEmpty) return notes.trim();
    return use.phrase;
  }

  DeliveryLocation copyWith({
    String? name,
    String? address,
    DeliveryLocationUse? use,
    String? notes,
  }) => DeliveryLocation(
    id: id,
    name: name ?? this.name,
    address: address ?? this.address,
    use: use ?? this.use,
    notes: notes ?? this.notes,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name.trim(),
    if (address.trim().isNotEmpty) 'address': address.trim(),
    'use': use.name,
    if (notes.trim().isNotEmpty) 'notes': notes.trim(),
  };

  factory DeliveryLocation.fromJson(Map<String, dynamic> json) =>
      DeliveryLocation(
        id: json['id']?.toString().trim() ?? '',
        name: json['name']?.toString().trim() ?? '',
        address: json['address']?.toString().trim() ?? '',
        use: deliveryLocationUseFromName(json['use']),
        notes: json['notes']?.toString().trim() ?? '',
      );
}

/// The list of places, and the file it came from.
///
/// Starts EMPTY rather than with built-in defaults. Every other card in this
/// app can ship a sensible starting point; a loading dock cannot - there is no
/// address that is right for somebody else's campus, and a list that arrives
/// with three invented places on it is a list people delete before they use.
class DeliveryLocationBook {
  final List<DeliveryLocation> places;

  /// The file this was read from or last written to. '' when it has never
  /// been saved anywhere.
  String filePath;

  /// What to show on screen about where these came from.
  String source;

  DeliveryLocationBook({
    List<DeliveryLocation>? places,
    this.filePath = '',
    this.source = '',
  }) : places = places ?? [];

  bool get isEmpty => places.isEmpty;

  int get count => places.length;

  DeliveryLocation? byId(String id) {
    for (final p in places) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// The place called [name], ignoring case and surrounding space - which is
  /// the only spelling difference worth forgiving on a name somebody types.
  DeliveryLocation? byName(String name) {
    final needle = name.trim().toLowerCase();
    if (needle.isEmpty) return null;
    for (final p in places) {
      if (p.name.trim().toLowerCase() == needle) return p;
    }
    return null;
  }

  /// The places worth offering for one side of the question: somewhere a
  /// truck delivers to, or somewhere gear is held.
  List<DeliveryLocation> forUse({required bool storage}) => [
    for (final p in places)
      if (storage ? p.use.holds : p.use.receives) p,
  ];

  /// Everything matching [query], in list order.
  List<DeliveryLocation> search(String query) => [
    for (final p in places)
      if (p.matches(query)) p,
  ];

  /// An id nothing else on the list is using, derived from the name so a
  /// hand-edited file reads as something rather than as `loc7`.
  String nextId(String name) {
    final stem = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    var id = stem.isEmpty ? 'place' : stem;
    var n = 1;
    while (byId(id) != null) {
      id = '${stem.isEmpty ? 'place' : stem}_${++n}';
    }
    return id;
  }

  /// Adds a place and returns it. A blank name is refused - a nameless row
  /// writes nothing onto a delivery and sits in the file looking like a
  /// mistake.
  DeliveryLocation? add({
    required String name,
    String address = '',
    DeliveryLocationUse use = DeliveryLocationUse.both,
    String notes = '',
  }) {
    if (name.trim().isEmpty) return null;
    final place = DeliveryLocation(
      id: nextId(name),
      name: name.trim(),
      address: address.trim(),
      use: use,
      notes: notes.trim(),
    );
    places.add(place);
    return place;
  }

  /// Replaces the place with [place.id], or appends it when there is none.
  void upsert(DeliveryLocation place) {
    final at = places.indexWhere((p) => p.id == place.id);
    if (at >= 0) {
      places[at] = place;
    } else {
      places.add(place);
    }
  }

  void remove(String id) => places.removeWhere((p) => p.id == id);

  /// Moves a place one step up or down the list. The order is the order the
  /// picker offers them in, and the two places most deliveries go to belong at
  /// the top of it.
  void move(String id, {required bool up}) {
    final at = places.indexWhere((p) => p.id == id);
    if (at < 0) return;
    final to = up ? at - 1 : at + 1;
    if (to < 0 || to >= places.length) return;
    places.insert(to, places.removeAt(at));
  }

  Map<String, dynamic> toJson() => {
    '__readme':
        'Delivery and storage locations for the Room Config Builder. One '
        'entry per place a truck can deliver to or gear can be held at; the '
        'name is what gets written onto a delivery row, and the address is '
        'looked up here rather than typed onto every row. Put this file on a '
        'shared drive to give the whole shop one set of names. A delivery can '
        'still be logged to a place that is not on this list.',
    'locations': [for (final p in places) p.toJson()],
  };

  /// Reads [path]. A missing file is an EMPTY list rather than an error: a
  /// shop that has never set any places up is the normal state on day one,
  /// and the delivery log works without them.
  ///
  /// A broken file is logged and leaves the list empty - a set of addresses is
  /// not worth taking the app down for.
  static Future<DeliveryLocationBook> load(String path) async {
    if (path.isEmpty) return DeliveryLocationBook(source: 'No file set');
    try {
      final file = File(path);
      if (!await file.exists()) {
        return DeliveryLocationBook(
          filePath: path,
          source: 'No places saved yet (no file at $path)',
        );
      }
      final doc = jsonDecode(await file.readAsString());
      if (doc is! Map) throw const FormatException('Root must be an object.');
      final book = DeliveryLocationBook(filePath: path, source: path);
      for (final entry in (doc['locations'] as List? ?? [])) {
        if (entry is! Map) continue;
        final place = DeliveryLocation.fromJson(
          Map<String, dynamic>.from(entry),
        );
        if (place.name.isEmpty) continue;
        // A hand-written file can leave the id out, or repeat one. Neither is
        // worth refusing the place over: the name is what does the work.
        book.places.add(
          place.id.isEmpty || book.byId(place.id) != null
              ? DeliveryLocation(
                  id: book.nextId(place.name),
                  name: place.name,
                  address: place.address,
                  use: place.use,
                  notes: place.notes,
                )
              : place,
        );
      }
      AppLogger.logInfo(
        'Delivery locations loaded from $path (${book.places.length} places).',
      );
      return book;
    } catch (e, stack) {
      AppLogger.logError('Failed to load delivery locations from $path', e,
          stack);
      return DeliveryLocationBook(
        filePath: path,
        source: 'Failed to load $path: $e',
      );
    }
  }

  /// Writes the list. Returns the file written, or '' on failure.
  Future<String> save({String toPath = ''}) async {
    final target = toPath.isNotEmpty ? toPath : filePath;
    if (target.isEmpty) return '';
    try {
      const encoder = JsonEncoder.withIndent('  ');
      await File(target).parent.create(recursive: true);
      await File(target).writeAsString(encoder.convert(toJson()));
      filePath = target;
      source = target;
      AppLogger.logInfo('Delivery locations saved to $target.');
      return target;
    } catch (e, stack) {
      AppLogger.logError('Failed to save delivery locations to $target', e,
          stack);
      return '';
    }
  }
}

/// One entry in a location picker: what would be written, what to show under
/// it, and whether it came off the shared list or off this job.
typedef DeliveryPlaceChoice = ({String name, String detail, bool saved});

/// The places to offer, shared list first and then whatever this job has
/// already typed.
///
/// BOTH, IN THAT ORDER. The saved list is the answer somebody set up on
/// purpose; the job's own history is what stops a place typed this morning
/// from being retyped this afternoon. A name on both lists is offered once.
List<DeliveryPlaceChoice> deliveryPlaceChoices({
  required DeliveryLocationBook book,
  required List<String> usedOnThisJob,
  required bool storage,
}) {
  final out = <DeliveryPlaceChoice>[];
  final seen = <String>{};
  for (final place in book.forUse(storage: storage)) {
    if (place.name.trim().isEmpty) continue;
    if (seen.add(place.name.trim().toLowerCase())) {
      out.add((name: place.name.trim(), detail: place.detail, saved: true));
    }
  }
  for (final used in usedOnThisJob) {
    final text = used.trim();
    if (text.isEmpty) continue;
    if (seen.add(text.toLowerCase())) {
      out.add((name: text, detail: 'Used on this job', saved: false));
    }
  }
  return out;
}
