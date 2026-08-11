import 'package:flutter/material.dart';

import 'av_flow_model.dart';
import 'room_locations.dart';

/// ============================================================================
///  THE CABLING SCHEMATIC
/// ============================================================================
///  The one-line drawing the trades are handed: boxes for the places in the
///  room, pull boxes for the junctions cable is routed THROUGH, and between
///  them a bundle labelled with what runs and how much of it — "2x Cat 6a",
///  "6x Cat 5e" — ending at the pathway back to the telecom room.
///
///  It is DERIVED, then EDITED, and the split between those two matters:
///
///    * DERIVED means the counts are read off the room rather than typed. A
///      bundle between the lectern and the rack is however many cables the
///      signal flow actually has crossing between them. Nobody adds up a
///      drawing by hand and gets the same answer as the cable schedule twice
///      running, which is why a hand-drawn version of this always ends up
///      disagreeing with the estimate.
///
///    * EDITED means the drawing is still a drawing. Boxes get dragged where
///      they read best, a bundle that the room cannot know about gets added by
///      hand, a label gets rewritten because the site calls it something else.
///
///  Both at once needs the overrides to be stored SEPARATELY from the derived
///  content and re-applied to it, which is what [CablingOverrides] is. Nothing
///  derived is ever written to disk: re-cable the room and the drawing follows,
///  while everything anybody typed stays exactly where they put it. And a
///  label or a count that has been overridden is marked as such, so the one
///  place the drawing and the room disagree is visible rather than buried.
/// ============================================================================

/// What a box on the drawing is.
enum CablingBoxKind {
  /// A named place in the room — where gear is, or where cable terminates.
  location,

  /// A junction cable passes through without terminating.
  pullBox,

  /// The route out of the room, drawn as the tall bar down the right.
  pathway,

  /// A free block of text: the scope notes down the side of the sheet.
  note,
}

const Map<CablingBoxKind, String> kCablingBoxKindLabels = {
  CablingBoxKind.location: 'Location',
  CablingBoxKind.pullBox: 'Pull box',
  CablingBoxKind.pathway: 'Pathway',
  CablingBoxKind.note: 'Notes',
};

CablingBoxKind cablingBoxKindFromName(String? name) =>
    CablingBoxKind.values.firstWhere(
      (k) => k.name == name?.trim(),
      orElse: () => CablingBoxKind.location,
    );

/// One box on the drawing.
class CablingBox {
  /// Stable and MEANINGFUL, because it is what an override is filed under.
  /// Derived boxes take their id from what they came from — `loc:LOC_3` — so
  /// a box keeps its position and its label across a rebuild. Hand-added ones
  /// are `box:<n>`.
  final String id;
  final String label;
  final CablingBoxKind kind;
  final Offset pos;

  /// Free text under the label — "13x Cat5e to SELV Telecom Room" on a
  /// pathway, the whole scope list on a note.
  final String body;

  const CablingBox({
    required this.id,
    required this.label,
    this.kind = CablingBoxKind.location,
    this.pos = Offset.zero,
    this.body = '',
  });

  /// True when this box is one the room produced rather than one somebody
  /// drew. Hand-added boxes can be deleted outright; a derived one can only be
  /// hidden, because deleting it would just bring it back on the next rebuild.
  bool get isDerived => id.startsWith('loc:');

  Size get size => switch (kind) {
    CablingBoxKind.pathway => const Size(46, 420),
    CablingBoxKind.note => const Size(250, 260),
    _ => const Size(180, 66),
  };

  Rect get rect => pos & size;

  CablingBox copyWith({
    String? label,
    CablingBoxKind? kind,
    Offset? pos,
    String? body,
  }) => CablingBox(
    id: id,
    label: label ?? this.label,
    kind: kind ?? this.kind,
    pos: pos ?? this.pos,
    body: body ?? this.body,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'kind': kind.name,
    'x': pos.dx,
    'y': pos.dy,
    if (body.isNotEmpty) 'body': body,
  };

  factory CablingBox.fromJson(Map<String, dynamic> json) => CablingBox(
    id: json['id']?.toString() ?? '',
    label: json['label']?.toString() ?? '',
    kind: cablingBoxKindFromName(json['kind']?.toString()),
    pos: Offset(
      (json['x'] as num?)?.toDouble() ?? 0,
      (json['y'] as num?)?.toDouble() ?? 0,
    ),
    body: json['body']?.toString() ?? '',
  );
}

/// A labelled run of cable between two boxes.
class CablingBundle {
  /// `bundle:<fromId>|<toId>|<type>` when derived, `run:<n>` when drawn.
  final String id;
  final String fromBoxId;
  final String toBoxId;

  /// How many cables. Derived from the room; overridable, and marked when it
  /// has been.
  final double count;

  /// What they are — 'Cat 6a', 'Cat 5e', 'HDMI'.
  final String cableType;

  /// ARGB. The reference drawing reads by colour — the AV bundles in one, the
  /// network in another — so the colour is part of the drawing, not decoration.
  final int color;

  const CablingBundle({
    required this.id,
    required this.fromBoxId,
    required this.toBoxId,
    this.count = 1,
    this.cableType = '',
    this.color = 0xFFD32F2F,
  });

  bool get isDerived => id.startsWith('bundle:');

  /// "2x Cat 6a" — what gets printed on the run.
  String get label {
    final n = count == count.roundToDouble()
        ? count.round().toString()
        : count.toStringAsFixed(1);
    return cableType.trim().isEmpty ? '${n}x' : '${n}x ${cableType.trim()}';
  }

  CablingBundle copyWith({
    String? fromBoxId,
    String? toBoxId,
    double? count,
    String? cableType,
    int? color,
  }) => CablingBundle(
    id: id,
    fromBoxId: fromBoxId ?? this.fromBoxId,
    toBoxId: toBoxId ?? this.toBoxId,
    count: count ?? this.count,
    cableType: cableType ?? this.cableType,
    color: color ?? this.color,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'from': fromBoxId,
    'to': toBoxId,
    'count': count,
    if (cableType.isNotEmpty) 'type': cableType,
    'color': color,
  };

  factory CablingBundle.fromJson(Map<String, dynamic> json) => CablingBundle(
    id: json['id']?.toString() ?? '',
    fromBoxId: json['from']?.toString() ?? '',
    toBoxId: json['to']?.toString() ?? '',
    count: (json['count'] as num?)?.toDouble() ?? 1,
    cableType: json['type']?.toString() ?? '',
    color: (json['color'] as num?)?.toInt() ?? 0xFFD32F2F,
  );
}

/// Everything anybody typed or moved. The only part that goes to disk.
class CablingOverrides {
  /// Box id -> where it was dragged to.
  final Map<String, Offset> positions;

  /// Box id -> what it was renamed to.
  final Map<String, String> labels;

  /// Box id -> the text under its label.
  final Map<String, String> bodies;

  /// Bundle id -> a count typed over the derived one.
  final Map<String, double> counts;

  /// Bundle id -> a cable type typed over the derived one.
  final Map<String, String> cableTypes;

  /// Derived boxes and bundles taken off the drawing. Hidden rather than
  /// deleted, because a rebuild would only bring a deleted one back.
  final Set<String> hidden;

  /// Boxes and runs that exist only on the drawing.
  final List<CablingBox> extraBoxes;
  final List<CablingBundle> extraBundles;

  CablingOverrides({
    Map<String, Offset>? positions,
    Map<String, String>? labels,
    Map<String, String>? bodies,
    Map<String, double>? counts,
    Map<String, String>? cableTypes,
    Set<String>? hidden,
    List<CablingBox>? extraBoxes,
    List<CablingBundle>? extraBundles,
  }) : positions = positions ?? {},
       labels = labels ?? {},
       bodies = bodies ?? {},
       counts = counts ?? {},
       cableTypes = cableTypes ?? {},
       hidden = hidden ?? {},
       extraBoxes = extraBoxes ?? [],
       extraBundles = extraBundles ?? [];

  bool get isEmpty =>
      positions.isEmpty &&
      labels.isEmpty &&
      bodies.isEmpty &&
      counts.isEmpty &&
      cableTypes.isEmpty &&
      hidden.isEmpty &&
      extraBoxes.isEmpty &&
      extraBundles.isEmpty;

  void clear() {
    positions.clear();
    labels.clear();
    bodies.clear();
    counts.clear();
    cableTypes.clear();
    hidden.clear();
    extraBoxes.clear();
    extraBundles.clear();
  }

  Map<String, dynamic> toJson() => {
    if (positions.isNotEmpty)
      'positions': {
        for (final e in positions.entries)
          e.key: {'x': e.value.dx, 'y': e.value.dy},
      },
    if (labels.isNotEmpty) 'labels': labels,
    if (bodies.isNotEmpty) 'bodies': bodies,
    if (counts.isNotEmpty) 'counts': counts,
    if (cableTypes.isNotEmpty) 'cableTypes': cableTypes,
    if (hidden.isNotEmpty) 'hidden': hidden.toList(),
    if (extraBoxes.isNotEmpty)
      'boxes': [for (final b in extraBoxes) b.toJson()],
    if (extraBundles.isNotEmpty)
      'bundles': [for (final b in extraBundles) b.toJson()],
  };

  void readJson(Map<String, dynamic> json) {
    clear();
    final p = json['positions'];
    if (p is Map) {
      p.forEach((key, value) {
        if (value is Map) {
          positions[key.toString()] = Offset(
            (value['x'] as num?)?.toDouble() ?? 0,
            (value['y'] as num?)?.toDouble() ?? 0,
          );
        }
      });
    }
    void strings(String key, Map<String, String> into) {
      final raw = json[key];
      if (raw is Map) {
        raw.forEach((k, v) => into[k.toString()] = v?.toString() ?? '');
      }
    }

    strings('labels', labels);
    strings('bodies', bodies);
    strings('cableTypes', cableTypes);

    final c = json['counts'];
    if (c is Map) {
      c.forEach((key, value) {
        final n = (value as num?)?.toDouble();
        if (n != null) counts[key.toString()] = n;
      });
    }
    for (final h in (json['hidden'] as List? ?? [])) {
      hidden.add(h.toString());
    }
    for (final b in (json['boxes'] as List? ?? [])) {
      if (b is Map) extraBoxes.add(CablingBox.fromJson(Map<String, dynamic>.from(b)));
    }
    for (final b in (json['bundles'] as List? ?? [])) {
      if (b is Map) {
        extraBundles.add(CablingBundle.fromJson(Map<String, dynamic>.from(b)));
      }
    }
  }
}

/// The drawing as it should be shown: derived content with the overrides on it.
class CablingSchematic {
  final List<CablingBox> boxes;
  final List<CablingBundle> bundles;

  /// Ids whose label or count was typed over the derived value. The view badges
  /// these — the one place the drawing and the room disagree should be visible
  /// rather than buried.
  final Set<String> overridden;

  const CablingSchematic({
    required this.boxes,
    required this.bundles,
    required this.overridden,
  });

  CablingBox? boxById(String id) {
    for (final b in boxes) {
      if (b.id == id) return b;
    }
    return null;
  }
}

/// Where a box is put before anybody drags it.
///
/// Laid out the way the reference drawing is: the places down the left in a
/// column, the pull boxes in the middle, the pathway on the right. Good enough
/// to read immediately and be rearranged from, which is all an automatic
/// layout has to be.
Offset _defaultPosition(int index, CablingBoxKind kind) => switch (kind) {
  CablingBoxKind.pathway => const Offset(880, 60),
  CablingBoxKind.note => const Offset(980, 60),
  CablingBoxKind.pullBox => Offset(560, 80.0 + index * 150),
  CablingBoxKind.location => Offset(80, 60.0 + index * 96),
};

/// Builds the drawing from the room, then lays the overrides on top.
///
/// The derivation is deliberately simple and explainable: one box per location
/// that has anything in it, and one bundle per pair of locations per signal
/// type, counted off the cables on the signal flow. A cable whose two ends are
/// in the same place is not a run between places and is left out — otherwise
/// every rack would have a bundle to itself.
CablingSchematic buildCablingSchematic({
  required AvFlowModel model,
  required List<RoomLocation> locations,
  required CablingOverrides overrides,
}) {
  final nodeLocation = <String, String>{
    for (final n in model.nodes) n.id: n.locationId,
  };

  // --- boxes, one per location that anything references --------------------
  final used = <String>{
    for (final n in model.nodes)
      if (n.locationId.isNotEmpty) n.locationId,
  };
  final derivedBoxes = <CablingBox>[];
  var locationIndex = 0;
  var pullIndex = 0;
  for (final loc in locations) {
    // A pull box earns its place by existing: nothing terminates in one, so
    // waiting for a device to name it would keep it off the drawing forever.
    final isPull = loc.zone == RoomZone.pullBox;
    if (!isPull && !used.contains(loc.id)) continue;
    final kind = isPull ? CablingBoxKind.pullBox : CablingBoxKind.location;
    derivedBoxes.add(
      CablingBox(
        id: 'loc:${loc.id}',
        label: loc.name,
        kind: kind,
        pos: _defaultPosition(isPull ? pullIndex++ : locationIndex++, kind),
      ),
    );
  }

  // --- bundles, counted off the cables between those places ----------------
  final counts = <String, ({String from, String to, SignalType signal, int n})>{};
  for (final cable in model.cables) {
    final from = nodeLocation[cable.fromNodeId] ?? '';
    final to = nodeLocation[cable.toNodeId] ?? '';
    if (from.isEmpty || to.isEmpty || from == to) continue;
    // Order-independent: a run is a run whichever end it was drawn from.
    final ends = [from, to]..sort();
    final key = 'bundle:loc:${ends[0]}|loc:${ends[1]}|${cable.signal.name}';
    final existing = counts[key];
    counts[key] = (
      from: 'loc:${ends[0]}',
      to: 'loc:${ends[1]}',
      signal: cable.signal,
      n: (existing?.n ?? 0) + 1,
    );
  }

  final derivedBundles = [
    for (final e in counts.entries)
      CablingBundle(
        id: e.key,
        fromBoxId: e.value.from,
        toBoxId: e.value.to,
        count: e.value.n.toDouble(),
        cableType: kSignalLabels[e.value.signal] ?? e.value.signal.name,
        color: 0xFFD32F2F,
      ),
  ]..sort((a, b) => a.id.compareTo(b.id));

  // --- overrides on top ----------------------------------------------------
  final overridden = <String>{};

  CablingBox applyBox(CablingBox box) {
    var out = box;
    final label = overrides.labels[box.id];
    if (label != null && label != box.label) {
      out = out.copyWith(label: label);
      if (box.isDerived) overridden.add(box.id);
    }
    final body = overrides.bodies[box.id];
    if (body != null) out = out.copyWith(body: body);
    final pos = overrides.positions[box.id];
    if (pos != null) out = out.copyWith(pos: pos);
    return out;
  }

  CablingBundle applyBundle(CablingBundle bundle) {
    var out = bundle;
    final count = overrides.counts[bundle.id];
    if (count != null && count != bundle.count) {
      out = out.copyWith(count: count);
      if (bundle.isDerived) overridden.add(bundle.id);
    }
    final type = overrides.cableTypes[bundle.id];
    if (type != null && type != bundle.cableType) {
      out = out.copyWith(cableType: type);
      if (bundle.isDerived) overridden.add(bundle.id);
    }
    return out;
  }

  final boxes = <CablingBox>[
    for (final b in derivedBoxes)
      if (!overrides.hidden.contains(b.id)) applyBox(b),
    for (final b in overrides.extraBoxes)
      if (!overrides.hidden.contains(b.id)) applyBox(b),
  ];

  final present = {for (final b in boxes) b.id};
  final bundles = <CablingBundle>[
    for (final b in derivedBundles)
      if (!overrides.hidden.contains(b.id) &&
          present.contains(b.fromBoxId) &&
          present.contains(b.toBoxId))
        applyBundle(b),
    // A hand-drawn run whose box has gone is dropped too — a line to nowhere
    // is worse than a missing line.
    for (final b in overrides.extraBundles)
      if (!overrides.hidden.contains(b.id) &&
          present.contains(b.fromBoxId) &&
          present.contains(b.toBoxId))
        applyBundle(b),
  ];

  return CablingSchematic(
    boxes: boxes,
    bundles: bundles,
    overridden: overridden,
  );
}
