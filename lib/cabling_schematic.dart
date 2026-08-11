import 'package:flutter/material.dart';

import 'av_flow_model.dart';
import 'layout_tools.dart';
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

  /// A piece of gear, drawn with the same icon the Schematic tab gives it.
  ///
  /// A cabling drawing is read at the wall, and "the ceiling mic" is what the
  /// person holding it calls the thing they are pulling to — not "CEILING
  /// LOCATION 2". Devices are drawn rather than derived because the drawing is
  /// about where cable GOES, and a run can be pulled to a projector months
  /// before anybody has decided which projector.
  device,
}

const Map<CablingBoxKind, String> kCablingBoxKindLabels = {
  CablingBoxKind.location: 'Location',
  CablingBoxKind.pullBox: 'Pull box',
  CablingBoxKind.pathway: 'Pathway',
  CablingBoxKind.note: 'Notes',
  CablingBoxKind.device: 'Device',
};

/// The gear a cabling drawing can carry, with the icon the rest of the app
/// already draws it with.
///
/// The same names and the same icons as the Schematic and Signal Flow tabs, so
/// a projector is the same picture on every sheet of the set. Keyed by a
/// stable slug because the key is what gets written to the room file — the
/// label can be reworded without orphaning every drawing that used it.
const Map<String, ({String label, IconData icon})> kCablingDeviceShapes = {
  'projector': (label: 'Projector', icon: Icons.connected_tv),
  'display': (label: 'Display / TV', icon: Icons.tv),
  'screen': (label: 'Projection screen', icon: Icons.aspect_ratio),
  'camera': (label: 'Camera', icon: Icons.videocam),
  'ceilingMic': (label: 'Ceiling mic', icon: Icons.mic),
  'tableMic': (label: 'Table mic', icon: Icons.mic_none),
  'speaker': (label: 'Speaker', icon: Icons.speaker),
  'amplifier': (label: 'Amplifier', icon: Icons.volume_up),
  'switcher': (label: 'Switcher', icon: Icons.swap_horiz),
  'dsp': (label: 'DSP', icon: Icons.equalizer),
  'transmitter': (label: 'Transmitter / wall plate', icon: Icons.input),
  'receiver': (label: 'Receiver', icon: Icons.output),
  'networkSwitch': (label: 'Network switch', icon: Icons.lan),
  'patchPanel': (label: 'Patch panel', icon: Icons.dns),
  'touchPanel': (label: 'Touch panel', icon: Icons.tablet_mac),
  'floorBox': (label: 'Floor box', icon: Icons.crop_free),
  'laptop': (label: 'Laptop / BYOD', icon: Icons.laptop),
  'pc': (label: 'Room PC', icon: Icons.desktop_windows),
  'rack': (label: 'Rack', icon: Icons.storage),
  'power': (label: 'Power controller', icon: Icons.power),
  'wireless': (label: 'Wireless / AP', icon: Icons.wifi),
  'other': (label: 'Other device', icon: Icons.developer_board),
};

/// The icon for a device box, falling back to the generic chip so a drawing
/// written by a newer version still draws.
IconData cablingDeviceIcon(String shape) =>
    kCablingDeviceShapes[shape]?.icon ??
    kCablingDeviceShapes['other']!.icon;

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

  /// Which of [kCablingDeviceShapes] a [CablingBoxKind.device] box draws.
  /// Empty on every other kind.
  final String shape;

  const CablingBox({
    required this.id,
    required this.label,
    this.kind = CablingBoxKind.location,
    this.pos = Offset.zero,
    this.body = '',
    this.shape = '',
  });

  /// True when this box is one the room produced rather than one somebody
  /// drew. Hand-added boxes can be deleted outright; a derived one can only be
  /// hidden, because deleting it would just bring it back on the next rebuild.
  bool get isDerived => id.startsWith('loc:');

  Size get size => switch (kind) {
    CablingBoxKind.pathway => const Size(46, 420),
    // Sized to what is IN it. The scope notes down the side of a cabling sheet
    // are the part that says whose contract each half of the job is, and a
    // fixed box either clipped a long one or left a short one floating in a
    // rectangle of nothing.
    CablingBoxKind.note => _noteSize(body),
    // Narrower than a place: a device box is an icon with a name under it, the
    // way it reads on the schematic. Tall enough for the icon plus TWO lines
    // of label — "Transmitter / wall plate" is a real entry in
    // [kCablingDeviceShapes], and a box sized to the one-line case clips it.
    CablingBoxKind.device => const Size(140, 96),
    _ => const Size(180, 66),
  };

  Rect get rect => pos & size;

  /// How big a notes block has to be to hold [body].
  ///
  /// Estimated from the character count rather than measured, because [size]
  /// is model geometry — the router, the hit targets and the report all read
  /// it, and none of them has a text painter to hand. The estimate runs a
  /// little generous on purpose: a box slightly too tall is a margin, a box
  /// slightly too short is text nobody can read.
  static Size _noteSize(String body) {
    const width = 250.0;
    const charsPerLine = 34;
    const lineHeight = 15.0;
    var lines = 0;
    for (final paragraph in body.split('\n')) {
      lines += paragraph.isEmpty
          ? 1
          : (paragraph.length + charsPerLine - 1) ~/ charsPerLine;
    }
    // padding + the label + the gap under it + the body itself.
    final height = 16 + 20 + 4 + lines * lineHeight;
    return Size(width, height.clamp(110.0, 1400.0));
  }

  CablingBox copyWith({
    String? label,
    CablingBoxKind? kind,
    Offset? pos,
    String? body,
    String? shape,
  }) => CablingBox(
    id: id,
    label: label ?? this.label,
    kind: kind ?? this.kind,
    pos: pos ?? this.pos,
    body: body ?? this.body,
    shape: shape ?? this.shape,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'kind': kind.name,
    'x': pos.dx,
    'y': pos.dy,
    if (body.isNotEmpty) 'body': body,
    if (shape.isNotEmpty) 'shape': shape,
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
    shape: json['shape']?.toString() ?? '',
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

  /// What they are FILED as — 'AV cabling', 'Network', 'Cat 6a'. For a derived
  /// bundle this is [cableTypeLabel] of [signal], which is why a DTP run and a
  /// Dante run both read "AV cabling" on the drawing.
  final String cableType;

  /// The signal the derived count was taken off, when there is one. It is what
  /// the sub-heading under "AV cabling" names, so the drawing can say the
  /// family and the specific signal without them ever drifting apart.
  ///
  /// Null on a run somebody drew by hand: nothing counted it, so nothing knows
  /// what is in it beyond whatever they typed in [cableType].
  final SignalType? signal;

  /// ARGB. The reference drawing reads by colour — the AV bundles in one, the
  /// network in another — so the colour is part of the drawing, not decoration.
  ///
  /// A derived run takes the room's colour for its signal, so the cabling sheet
  /// and the signal flow describe the same run in the same colour without
  /// anybody keeping two palettes in step. A hand-drawn one takes whatever it
  /// was given, and either can be recoloured on the drawing.
  final int color;

  const CablingBundle({
    required this.id,
    required this.fromBoxId,
    required this.toBoxId,
    this.count = 1,
    this.cableType = '',
    this.signal,
    this.color = 0xFFD32F2F,
  });

  /// True when the ROOM produced this run rather than somebody drawing it —
  /// counted off the signal flow (`bundle:`) or read off a screen / shade
  /// control run (`screen:`). Either way deleting it would only bring it back
  /// on the next rebuild, so the drawing hides it instead.
  bool get isDerived =>
      id.startsWith('bundle:') || id.startsWith(kCablingScreenRunPrefix);

  /// True when this run is a low-voltage control run rather than signal
  /// cable. It is counted per RUN, not per cable on the flow, so the schedule
  /// can say what it is without implying the signal flow knows about it.
  bool get isControlRun => id.startsWith(kCablingScreenRunPrefix);

  /// "2x AV cabling" — what gets printed on the run.
  String get label {
    final n = count == count.roundToDouble()
        ? count.round().toString()
        : count.toStringAsFixed(1);
    return cableType.trim().isEmpty ? '${n}x' : '${n}x ${cableType.trim()}';
  }

  /// The line UNDER [label] — 'HDBaseT / DTP' beneath '4x AV cabling'.
  ///
  /// Empty when the heading already names the signal, so a network run is not
  /// labelled "Network" twice, and empty on a hand-drawn run, which is a count
  /// of something somebody named rather than a count of a signal.
  String get signalSubLabel {
    final s = signal;
    if (s == null) return '';
    final sub = cableSignalSubLabel(s);
    // A typed-over cable type is what the site calls it; the signal underneath
    // is still worth saying, so this only falls silent when the two agree.
    return sub == cableType.trim() ? '' : sub;
  }

  CablingBundle copyWith({
    String? fromBoxId,
    String? toBoxId,
    double? count,
    String? cableType,
    SignalType? signal,
    int? color,
  }) => CablingBundle(
    id: id,
    fromBoxId: fromBoxId ?? this.fromBoxId,
    toBoxId: toBoxId ?? this.toBoxId,
    count: count ?? this.count,
    cableType: cableType ?? this.cableType,
    signal: signal ?? this.signal,
    color: color ?? this.color,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'from': fromBoxId,
    'to': toBoxId,
    'count': count,
    if (cableType.isNotEmpty) 'type': cableType,
    if (signal != null) 'signal': signal!.name,
    'color': color,
  };

  factory CablingBundle.fromJson(Map<String, dynamic> json) => CablingBundle(
    id: json['id']?.toString() ?? '',
    fromBoxId: json['from']?.toString() ?? '',
    toBoxId: json['to']?.toString() ?? '',
    count: (json['count'] as num?)?.toDouble() ?? 1,
    cableType: json['type']?.toString() ?? '',
    signal: json['signal'] == null
        ? null
        : signalFromName(json['signal']?.toString()),
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

  /// Bundle id -> ARGB picked for this run on the drawing.
  ///
  /// Separate from [cableTypes] because recolouring is not a disagreement with
  /// the room the way a typed count is — it is how the sheet is drawn, and the
  /// run is still whatever the signal flow says it is.
  final Map<String, int> colors;

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
    Map<String, int>? colors,
    Set<String>? hidden,
    List<CablingBox>? extraBoxes,
    List<CablingBundle>? extraBundles,
  }) : positions = positions ?? {},
       labels = labels ?? {},
       bodies = bodies ?? {},
       counts = counts ?? {},
       cableTypes = cableTypes ?? {},
       colors = colors ?? {},
       hidden = hidden ?? {},
       extraBoxes = extraBoxes ?? [],
       extraBundles = extraBundles ?? [];

  bool get isEmpty =>
      positions.isEmpty &&
      labels.isEmpty &&
      bodies.isEmpty &&
      counts.isEmpty &&
      cableTypes.isEmpty &&
      colors.isEmpty &&
      hidden.isEmpty &&
      extraBoxes.isEmpty &&
      extraBundles.isEmpty;

  void clear() {
    positions.clear();
    labels.clear();
    bodies.clear();
    counts.clear();
    cableTypes.clear();
    colors.clear();
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
    if (colors.isNotEmpty) 'colors': colors,
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
    final rgb = json['colors'];
    if (rgb is Map) {
      rgb.forEach((key, value) {
        final n = (value as num?)?.toInt();
        if (n != null) colors[key.toString()] = n;
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

  /// Every run between the same two boxes, in drawing order.
  ///
  /// A location feeding the pathway with six Cat 6a and five Cat 5e is TWO
  /// runs on one edge, and both have to be visible: one line hiding another is
  /// the drawing quietly under-reporting the job.
  List<CablingBundle> bundlesBetween(String boxA, String boxB) => [
    for (final b in bundles)
      if ((b.fromBoxId == boxA && b.toBoxId == boxB) ||
          (b.fromBoxId == boxB && b.toBoxId == boxA))
        b,
  ];

  /// How far off the centre line each run is drawn, by bundle id.
  ///
  /// Runs sharing an edge are fanned out either side of where a single run
  /// would sit, so a pair reads as two cables rather than one thick one. The
  /// same map feeds the painter and the click targets, so what you see and
  /// what you can hit can never come apart.
  Map<String, double> get bundleLanes {
    final byEdge = <String, List<CablingBundle>>{};
    for (final b in bundles) {
      final ends = [b.fromBoxId, b.toBoxId]..sort();
      byEdge.putIfAbsent('${ends[0]}|${ends[1]}', () => []).add(b);
    }
    final lanes = <String, double>{};
    for (final group in byEdge.values) {
      for (int i = 0; i < group.length; i++) {
        lanes[group[i].id] = (i - (group.length - 1) / 2) * kCablingLaneStep;
      }
    }
    return lanes;
  }

  /// The key: one line per cable on the sheet, in the order the colours were
  /// handed out, with what it is and how much of it there is.
  ///
  /// Built off the same bundles the drawing paints, so a key line and the
  /// lines it describes cannot come apart — which is the whole reason to
  /// derive it rather than let somebody maintain a legend by hand.
  List<CableKeyEntry> get key {
    // Which cable types are claimed by more than one category. Only those need
    // the category printed: "Cat 6a (Network)" earns its parenthesis when
    // there is also an AV Cat 6a, and is noise when there isn't.
    final categoriesPerType = <String, Set<String>>{};
    for (final b in bundles) {
      categoriesPerType
          .putIfAbsent(cablingTypeKey(b.cableType), () => {})
          .add(cablingCategoryOf(b));
    }

    final order = <String>[];
    final rolled = <String, ({
      String category,
      String typeKey,
      String type,
      int color,
      double count,
      int runs,
    })>{};
    for (final b in bundles) {
      final k = cablingColorKey(b);
      final existing = rolled[k];
      if (existing == null) {
        order.add(k);
        rolled[k] = (
          category: cablingCategoryOf(b),
          typeKey: cablingTypeKey(b.cableType),
          type: b.cableType.trim().isEmpty
              ? '(cable not specified)'
              : b.cableType.trim(),
          color: b.color,
          count: b.count,
          runs: 1,
        );
      } else {
        rolled[k] = (
          category: existing.category,
          typeKey: existing.typeKey,
          type: existing.type,
          color: existing.color,
          count: existing.count + b.count,
          runs: existing.runs + 1,
        );
      }
    }

    return [
      for (final k in order)
        (
          category: rolled[k]!.category,
          type: rolled[k]!.type,
          color: rolled[k]!.color,
          count: rolled[k]!.count,
          runs: rolled[k]!.runs,
          categoryMatters:
              (categoriesPerType[rolled[k]!.typeKey]?.length ?? 1) > 1,
        ),
    ];
  }

  /// Where [bundle] is actually drawn: its two ends, already pushed onto its
  /// lane. Null when either box has gone off the drawing.
  ({Offset from, Offset to})? endsOf(CablingBundle bundle, double lane) {
    final a = boxById(bundle.fromBoxId);
    final b = boxById(bundle.toBoxId);
    if (a == null || b == null) return null;
    final from = a.rect.center;
    final to = b.rect.center;
    if (lane == 0) return (from: from, to: to);
    // Perpendicular to the run, so the fan opens across the line rather than
    // along it however the two boxes happen to be arranged.
    final d = to - from;
    final length = d.distance;
    if (length == 0) return (from: from, to: to);
    final normal = Offset(-d.dy / length, d.dx / length) * lane;
    return (from: from + normal, to: to + normal);
  }
}

/// How far apart runs sharing an edge are fanned. Wide enough to read as
/// separate cables at the zoom a cabling sheet is looked at, tight enough that
/// four of them still look like one bundle.
const double kCablingLaneStep = 13;

/// The point halfway ALONG [route], measured by distance travelled.
///
/// Not the midpoint of the two ends: a run that detours around a rack has a
/// straight-line middle that can sit well off the line itself, and a label
/// anchored there is a label pointing at nothing.
Offset polylineMidpoint(List<Offset> route) {
  if (route.isEmpty) return Offset.zero;
  if (route.length == 1) return route.first;

  var total = 0.0;
  for (int i = 0; i < route.length - 1; i++) {
    total += (route[i + 1] - route[i]).distance;
  }
  if (total == 0) return route.first;

  var travelled = 0.0;
  for (int i = 0; i < route.length - 1; i++) {
    final leg = (route[i + 1] - route[i]).distance;
    if (travelled + leg >= total / 2) {
      final into = leg == 0 ? 0.0 : (total / 2 - travelled) / leg;
      return route[i] + (route[i + 1] - route[i]) * into;
    }
    travelled += leg;
  }
  return route.last;
}

/// Bundle ids for the runs read off the room's screen and shade control runs.
const String kCablingScreenRunPrefix = 'screen:';

/// What a screen / shade control run is drawn in before anybody recolours it.
///
/// Deliberately nothing like the signal palette: a control run is not program
/// signal, it is pulled by different people to a different spec, and a drawing
/// that painted it the same colour as the AV would be inviting somebody to
/// land it on a switch.
const int kCablingControlRunColor = 0xFFFFA726;

/// What a control run is called when nobody has said what cable it is.
const String kCablingControlRunType = 'Control cable';

// ---------------------------------------------------------------------------
//  THE KEY: ONE COLOUR PER CABLE
// ---------------------------------------------------------------------------

/// What a run is FILED under, over and above what cable it is.
///
/// A drawing's colours have to answer one question — "which of these lines am
/// I pulling?" — and the answer is the CABLE, not the signal riding it. Two
/// HDBaseT runs and two Dante runs down the same four Cat 6a are four lines of
/// one cable, and drawing them in four colours told the person pulling them
/// they were four different things.
///
/// So colour keys off the cable type, with the category as the one permitted
/// tiebreak: AV Cat 6a and network Cat 6a really are two different pulls, by
/// two different contractors, to two different test standards, and the sheet
/// has to be able to say so.
const String kCablingControlCategory = 'Control';
const String kCablingUnfiledCategory = 'Other cabling';

/// The category a run is filed under.
String cablingCategoryOf(CablingBundle bundle) {
  if (bundle.isControlRun) return kCablingControlCategory;
  final s = bundle.signal;
  if (s == null) return kCablingUnfiledCategory;
  return kCableFamilyLabels[cableFamilyFor(s)] ?? kCablingUnfiledCategory;
}

/// The cable type as the key groups it — case-folded with the spaces taken
/// out, so "Cat6a", "Cat 6a" and "CAT  6A" are ONE line of the key and one
/// colour on the drawing rather than three of each.
///
/// The same three spellings are already the reason [kCablingCableTypes] exists
/// as a shortcut menu: a schedule carrying all three is three lines of a
/// purchase order for one reel of cable. Folding them here means the DRAWING
/// stops disagreeing with itself even when somebody types past the menu.
String cablingTypeKey(String cableType) =>
    cableType.toLowerCase().replaceAll(RegExp(r'\s+'), '');

/// The identity a colour is assigned against: category and cable type.
String cablingColorKey(CablingBundle bundle) =>
    '${cablingCategoryOf(bundle)}|${cablingTypeKey(bundle.cableType)}';

/// The colours the key runs through, in order.
///
/// No orange in it: orange is spoken for by the control runs (see
/// [kCablingControlRunColor]), and a network run the same colour as the screen
/// switch run is the drawing telling somebody to land data on a motor.
/// Picked to stay apart from each other at the weight a cable line is drawn
/// and in both light and dark, which is a shorter list than it looks.
const List<int> kCablingTypeColors = [
  0xFF3949AB, // indigo
  0xFF546E7A, // blue grey
  0xFF2E7D32, // green
  0xFF8E24AA, // purple
  0xFF00838F, // teal
  0xFFC2185B, // pink
  0xFF5D4037, // brown
  0xFF1976D2, // blue
  0xFF689F38, // olive
  0xFF00695C, // deep teal
  0xFF7B1FA2, // deep purple
  0xFF455A64, // slate
];

/// The shades the control runs get, amber first — the colour they have always
/// been drawn in, and the one the rest of the palette keeps clear of.
const List<int> kCablingControlColors = [
  kCablingControlRunColor,
  0xFFFB8C00,
  0xFFFFCA28,
  0xFFEF6C00,
];

/// A colour per [cablingColorKey], assigned in the order the runs are drawn.
///
/// First-appearance order rather than alphabetical so adding a cable type
/// appends a colour instead of reshuffling every line already on the sheet.
/// The bundles arrive sorted by id, which is derived from the two ends and the
/// signal, so the same room gives the same key every time it is opened.
Map<String, int> cablingKeyColors(List<CablingBundle> bundles) {
  final out = <String, int>{};
  var next = 0;
  var nextControl = 0;
  for (final bundle in bundles) {
    final key = cablingColorKey(bundle);
    if (out.containsKey(key)) continue;
    out[key] = bundle.isControlRun
        ? kCablingControlColors[nextControl++ % kCablingControlColors.length]
        : kCablingTypeColors[next++ % kCablingTypeColors.length];
  }
  return out;
}

/// The id the key panel is filed under in [CablingOverrides] — so it can be
/// dragged out of the way and taken off the sheet like anything else drawn,
/// without being a box the runs could be wired to.
const String kCablingKeyId = 'key:cables';

/// One line of the key on the drawing.
typedef CableKeyEntry = ({
  String category,
  String type,
  int color,

  /// How many cables the sheet has of it, summed across every run.
  double count,

  /// How many runs those cables are spread over.
  int runs,

  /// True when another category uses the same cable type, so the key has to
  /// print the category to explain why one Cat 6a is blue and the other green.
  bool categoryMatters,
});

/// The cable types offered on a run before anybody types their own.
///
/// A list rather than a free field alone because "Cat5e" gets typed a hundred
/// times a year and misspelled a dozen of them, and a schedule that has
/// "Cat5e", "cat 5e" and "CAT5E" on it is three lines on a purchase order. The
/// field still takes anything — the presets are a shortcut, not a whitelist.
const List<String> kCablingCableTypes = [
  'Cat 5e',
  'Cat 6',
  'Cat 6a',
  'Cat 7',
  'Fiber (OM4)',
  'Fiber (OS2)',
  'Coax (RG6)',
  '18/2 plenum',
  '16/2 speaker',
  '14/2 speaker',
  'HDMI',
  'Line voltage',
];

/// Where a box is put before anybody drags it.
///
/// Laid out the way the reference drawing is: the places down the left in a
/// column, the pull boxes in the middle, the pathway on the right. Good enough
/// to read immediately and be rearranged from, which is all an automatic
/// layout has to be.
/// Public because a box added BY HAND wants the same slot the derived layout
/// would have given it. Dropping every new box at one fixed spot is how a
/// pathway ends up sitting on top of the device added a moment earlier.
Offset defaultCablingBoxPosition(int index, CablingBoxKind kind) =>
    _defaultPosition(index, kind);

/// Where the key sits before anybody drags it: clear to the right of the notes
/// column, which is the far edge of the derived layout.
const Offset kDefaultCablingKeyPosition = Offset(1270, 60);

/// How wide the key panel is drawn. Fixed, because a key whose width follows
/// its longest cable name jumps around every time somebody retypes one.
const double kCablingKeyWidth = 260;

Offset _defaultPosition(int index, CablingBoxKind kind) => switch (kind) {
  // A room has one route out and usually one block of scope notes, so these
  // step sideways rather than down when a second one is added.
  CablingBoxKind.pathway => Offset(880.0 + index * 70, 60),
  CablingBoxKind.note => Offset(980.0 + index * 40, 60.0 + index * 40),
  CablingBoxKind.pullBox => Offset(560, 80.0 + index * 150),
  // Devices land in a row of their own above the places, so a handful dropped
  // in one after another don't stack on each other.
  CablingBoxKind.device => Offset(320, 60.0 + index * 104),
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

  /// The room's signal colours, so a derived run is drawn the colour the
  /// signal flow already draws it. Omitted only where there is no room to ask
  /// — the tests and the reports, which do not care what colour anything is.
  Map<SignalType, Color>? palette,
}) {
  final nodeLocation = <String, String>{
    for (final n in model.nodes) n.id: n.locationId,
  };

  // --- boxes, one per location that anything references --------------------
  final used = <String>{
    for (final n in model.nodes)
      if (n.locationId.isNotEmpty) n.locationId,
    // A screen switch and the motor it drives are both places cable lands,
    // and neither is a device on the signal flow. Without this the control
    // run would be a line between two boxes that were never drawn.
    for (final s in model.screenSwitches) ...[
      if (s.startLocationId.isNotEmpty) s.startLocationId,
      if (s.endLocationId.isNotEmpty) s.endLocationId,
    ],
  }..remove(kNoLocationId);
  final derivedBoxes = <CablingBox>[];
  var locationIndex = 0;
  var pullIndex = 0;
  for (final loc in locations) {
    // A pull box earns its place by existing: nothing terminates in one, so
    // waiting for a device to name it would keep it off the drawing forever.
    final isPull = loc.zone == RoomZone.pullBox;
    if (!isPull && !used.contains(loc.id)) continue;
    final kind = isPull ? CablingBoxKind.pullBox : CablingBoxKind.location;
    final box = CablingBox(
      id: 'loc:${loc.id}',
      label: loc.name,
      kind: kind,
      pos: _defaultPosition(isPull ? pullIndex++ : locationIndex++, kind),
    );
    derivedBoxes.add(
      // The column layout steps far enough apart for the boxes it was written
      // for, but a room whose places came off the floor plan can produce more
      // of a kind than the step allows for, and a note box sizes itself to its
      // text. Checking beats trusting the arithmetic: a box that lands on
      // another hides both, and the runs between them become unreadable.
      box.copyWith(
        pos: nonOverlappingPosition(
          desired: box.pos,
          size: box.size,
          others: [for (final b in derivedBoxes) b.rect],
        ),
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
        // The FAMILY, not the signal: a DTP run and a Dante run are both
        // "AV cabling" to whoever is pulling them, and the signal goes on the
        // sub-heading underneath.
        cableType: cableTypeLabel(e.value.signal),
        signal: e.value.signal,
        // The room's own colour for that signal, so the AV runs and the
        // network runs read apart on the cabling sheet exactly the way they do
        // on the signal flow. One line in one colour was the drawing saying
        // every cable in the room was the same thing.
        color: signalColor(e.value.signal, palette).toARGB32(),
      ),
    // The screen and shade control runs, on the drawing rather than only in a
    // table at the back. They are cable somebody has to pull between two
    // places in this room, which is exactly what this sheet is for — and they
    // used to turn up as a surprise at rough-in precisely because no drawing
    // showed them.
    for (final s in model.screenSwitches)
      if (s.startLocationId.isNotEmpty &&
          s.endLocationId.isNotEmpty &&
          s.startLocationId != kNoLocationId &&
          s.endLocationId != kNoLocationId &&
          s.startLocationId != s.endLocationId)
        CablingBundle(
          id: '$kCablingScreenRunPrefix${s.id}',
          fromBoxId: 'loc:${s.startLocationId}',
          toBoxId: 'loc:${s.endLocationId}',
          count: 1,
          // Whatever the run was specified as — "Cat 5e", "18/2 plenum" — and
          // a name that says what it is when nobody has specified it yet.
          cableType: s.cableType.trim().isEmpty
              ? kCablingControlRunType
              : s.cableType.trim(),
          color: kCablingControlRunColor,
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

  // --- the colours, last: one per cable, not one per signal ----------------
  //
  // After the type overrides, because retyping a run's cable is exactly how
  // somebody says "this one is Cat 6a like those two" and the colour has to
  // follow. A run recoloured BY HAND still wins — that is the drawing set's
  // own convention overriding the app's, which is the one thing a colour rule
  // must never take away.
  final keyColors = cablingKeyColors(bundles);
  for (int i = 0; i < bundles.length; i++) {
    final explicit = overrides.colors[bundles[i].id];
    final byType = keyColors[cablingColorKey(bundles[i])];
    final color = explicit ?? byType;
    if (color != null && color != bundles[i].color) {
      bundles[i] = bundles[i].copyWith(color: color);
    }
  }

  return CablingSchematic(
    boxes: boxes,
    bundles: bundles,
    overridden: overridden,
  );
}
