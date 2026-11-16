import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'mount_spec.dart';

/// ============================================================================
///  WALL ELEVATIONS
/// ============================================================================
///  One wall of the room seen straight on, with what is mounted on it drawn at
///  its real size, and a side section showing how far each thing stands off
///  the wall. Checked for clashes: two things in the same place at the same
///  depth, a mount that cannot take its display, something over a door or a
///  fire alarm, and anything that sticks out more than 4" into a walkway.
///
///  All lengths are inches. x runs from the wall's left end as seen from
///  inside the room; y is the item's bottom edge above the finished floor.
///  Pure data and geometry: no widgets, no provider.
/// ============================================================================

enum WallItemKind {
  display('Display'),
  mount('Wall mount'),
  screen('Projection screen'),
  whiteboard('Whiteboard'),
  door('Door'),
  window('Window'),
  outlet('Power / data box'),
  recessedBox('Recessed box'),
  lightSwitch('Wall switch'),
  touchPanel('Touch panel'),
  thermostat('Thermostat'),
  fireAlarm('Fire alarm / strobe'),
  speaker('Speaker'),
  camera('Camera'),
  videoBar('Video bar'),
  credenza('Credenza / cabinet'),
  table('Table'),
  obstruction('Column / pipe / duct'),
  caneRail('Cane rail'),
  raceway('Conduit / raceway'),
  other('Other');

  final String label;
  const WallItemKind(this.label);

  static WallItemKind fromName(String? name) =>
      values.where((k) => k.name == name).firstOrNull ?? other;

  /// Stands on the floor.
  bool get onFloor => this == credenza || this == table;

  /// An opening: nothing may stand in front of it.
  bool get isOpening => this == door || this == window;

  /// Has operable parts somebody reaches for.
  bool get operable =>
      this == lightSwitch || this == touchPanel || this == thermostat;

  /// Must stay in sight and uncovered.
  bool get keepUncovered => this == fireAlarm || this == thermostat;

  /// Hangs a display.
  bool get hangsDisplay => this == mount;

  /// Shows a picture.
  bool get showsImage => this == display || this == screen;

  IconData get icon => switch (this) {
    display => Icons.tv,
    mount => Icons.vertical_split,
    screen => Icons.crop_landscape,
    whiteboard => Icons.border_color,
    door => Icons.door_front_door,
    window => Icons.window,
    outlet => Icons.power,
    recessedBox => Icons.inbox,
    lightSwitch => Icons.toggle_on,
    touchPanel => Icons.tablet_mac,
    thermostat => Icons.thermostat,
    fireAlarm => Icons.local_fire_department,
    speaker => Icons.speaker,
    camera => Icons.videocam,
    videoBar => Icons.video_camera_front,
    credenza => Icons.inventory_2,
    table => Icons.table_restaurant,
    obstruction => Icons.view_column,
    caneRail => Icons.horizontal_rule,
    raceway => Icons.cable,
    other => Icons.crop_square,
  };

  Color get color => switch (this) {
    display => const Color(0xFF263238),
    mount => const Color(0xFF78909C),
    screen => const Color(0xFF5E35B1),
    whiteboard => const Color(0xFF43A047),
    door => const Color(0xFF8D6E63),
    window => const Color(0xFF4FC3F7),
    outlet || recessedBox => const Color(0xFFFFA000),
    lightSwitch || thermostat => const Color(0xFFFFB300),
    touchPanel => const Color(0xFF00897B),
    fireAlarm => const Color(0xFFE53935),
    speaker => const Color(0xFF6D4C41),
    camera || videoBar => const Color(0xFFD81B60),
    credenza || table => const Color(0xFF795548),
    obstruction => const Color(0xFF9E9E9E),
    caneRail => const Color(0xFF6A1B9A),
    raceway => const Color(0xFF3949AB),
    other => const Color(0xFF607D8B),
  };
}

/// Inches in a millimeter.
const double kInPerMm = 1 / 25.4;

/// Highest a protruding object's leading edge may be and still be found
/// with a cane, and lowest it may be overhead (ADA 307.2).
const double kCaneDetectIn = 27;
const double kHeadroomIn = 80;

/// How far an object between [kCaneDetectIn] and [kHeadroomIn] may stick
/// out from the wall (ADA 307.2).
const double kMaxProtrusionIn = 4;

/// Highest and lowest operable parts may be (ADA 308).
const double kReachHighIn = 48;
const double kReachLowIn = 15;

/// Overlaps smaller than this are touching, not clashing.
const double _kTouch = 0.05;

/// One thing on a wall.
@immutable
class WallItem {
  /// `WI_<n>`, unique on its wall.
  final String id;
  final WallItemKind kind;
  final String label;
  final String model;

  /// Left edge from the wall's left end, and bottom edge above the floor.
  final double x, y;

  /// Front-view size, and depth front to back.
  final double width, height, depth;

  /// How far its back stands off the wall face.
  final double standoff;

  /// Degrees the top is tipped out from the wall; negative tips the bottom
  /// out. Pivots on the VESA center.
  final double tiltDeg;

  /// For a display: the mount it hangs on. Its standoff and the mount's
  /// place follow from it.
  final String mountId;

  /// VESA pattern in mm. For a mount, the largest it takes.
  final double vesaW, vesaH;

  /// For a display: the VESA center above its bottom edge, and in from its
  /// left edge as seen from the front; 0 is the middle.
  final double vesaUp, vesaLeft;

  /// For a mount: height of the plate on the wall, centered; 0 is the whole
  /// height. What clashes with boxes in the wall.
  final double plateHeight;

  /// For a mount: the plate's center above the arms' middle, which sits on
  /// the display's VESA center. Set by where the arms' hooks seat on the
  /// plate; 0 is centered.
  final double plateOffset;

  /// For a mount: how far it tilts either way, degrees.
  final double maxTiltDeg;

  /// For a mount: each arm's width, and how far apart the arms go, center
  /// to center; 0 is not recorded.
  final double armWidth, armSpanMin, armSpanMax;

  /// For a mount: the smallest VESA pattern it takes, mm; 0 is any.
  final double vesaMinW, vesaMinH;

  final double weightLb;

  /// For a mount: the most it holds.
  final double capacityLb;

  /// Takes touch.
  final bool touch;

  /// The picture or touch area, inside the frame; 0 by 0 is the whole face.
  final double activeW, activeH;

  /// The active area's bottom above the frame's bottom.
  final double activeUp;

  final String note;

  /// Held where it is.
  final bool locked;

  const WallItem({
    required this.id,
    required this.kind,
    this.label = '',
    this.model = '',
    this.x = 0,
    this.y = 0,
    this.width = 12,
    this.height = 12,
    this.depth = 1,
    this.standoff = 0,
    this.tiltDeg = 0,
    this.mountId = '',
    this.vesaW = 0,
    this.vesaH = 0,
    this.vesaUp = 0,
    this.vesaLeft = 0,
    this.plateHeight = 0,
    this.plateOffset = 0,
    this.maxTiltDeg = 0,
    this.armWidth = 0,
    this.armSpanMin = 0,
    this.armSpanMax = 0,
    this.vesaMinW = 0,
    this.vesaMinH = 0,
    this.weightLb = 0,
    this.capacityLb = 0,
    this.touch = false,
    this.activeW = 0,
    this.activeH = 0,
    this.activeUp = 0,
    this.note = '',
    this.locked = false,
  });

  String get name => label.trim().isNotEmpty
      ? label.trim()
      : model.trim().isNotEmpty
          ? model.trim()
          : kind.label;

  double get right => x + width;
  double get top => y + height;
  double get centerX => x + width / 2;
  double get centerY => y + height / 2;

  /// The front view as a rect, y up from the floor: its `top` is the LOWER
  /// edge and its `bottom` the upper one. So are the rects below.
  Rect get face => Rect.fromLTRB(x, y, right, top);

  /// The VESA center above the floor.
  double get vesaCenterY => y + (vesaUp > 0 ? vesaUp : height / 2);

  /// The VESA center along the wall.
  double get vesaCenterX => x + (vesaLeft > 0 ? vesaLeft : width / 2);

  /// The VESA pattern in inches, wide and high.
  double get vesaWIn => vesaW * kInPerMm;
  double get vesaHIn => vesaH * kInPerMm;

  /// For a mount: each arm's width as drawn.
  double get armDrawWidth => armWidth > 0 ? armWidth : math.max(1.0, width * 0.035);

  /// The four VESA holes on the wall, empty with no pattern.
  List<Offset> get vesaHoles {
    if (vesaW <= 0 || vesaH <= 0) return const [];
    final cx = vesaCenterX, cy = vesaCenterY;
    final dx = vesaWIn / 2, dy = vesaHIn / 2;
    return [
      Offset(cx - dx, cy - dy),
      Offset(cx + dx, cy - dy),
      Offset(cx - dx, cy + dy),
      Offset(cx + dx, cy + dy),
    ];
  }

  /// The part that sits on the wall: a mount's plate, else the whole face.
  Rect get wallFootprint {
    if (kind == WallItemKind.mount && plateHeight > 0 && plateHeight < height) {
      final mid = centerY + plateOffset;
      return Rect.fromLTRB(x, mid - plateHeight / 2, right, mid + plateHeight / 2);
    }
    return face;
  }

  /// The picture or touch area above the floor.
  Rect get activeFace {
    if (activeW <= 0 || activeH <= 0) return face;
    final left = x + (width - activeW) / 2;
    final bottom = y + activeUp;
    return Rect.fromLTRB(left, bottom, left + activeW, bottom + activeH);
  }

  /// Farthest it reaches from the wall face, tilt included.
  double get projection {
    final t = tiltDeg * math.pi / 180;
    if (t == 0) return standoff + depth;
    final pivot = vesaUp > 0 ? vesaUp : height / 2;
    final lever = t > 0 ? height - pivot : pivot;
    return standoff + depth * math.cos(t) + lever * math.sin(t.abs());
  }

  /// Back and front, out from the wall face.
  double get back => standoff;
  double get front => projection;

  WallItem copyWith({
    String? id,
    WallItemKind? kind,
    String? label,
    String? model,
    double? x,
    double? y,
    double? width,
    double? height,
    double? depth,
    double? standoff,
    double? tiltDeg,
    String? mountId,
    double? vesaW,
    double? vesaH,
    double? vesaUp,
    double? vesaLeft,
    double? plateHeight,
    double? plateOffset,
    double? maxTiltDeg,
    double? armWidth,
    double? armSpanMin,
    double? armSpanMax,
    double? vesaMinW,
    double? vesaMinH,
    double? weightLb,
    double? capacityLb,
    bool? touch,
    double? activeW,
    double? activeH,
    double? activeUp,
    String? note,
    bool? locked,
  }) => WallItem(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    label: label ?? this.label,
    model: model ?? this.model,
    x: x ?? this.x,
    y: y ?? this.y,
    width: width ?? this.width,
    height: height ?? this.height,
    depth: depth ?? this.depth,
    standoff: standoff ?? this.standoff,
    tiltDeg: tiltDeg ?? this.tiltDeg,
    mountId: mountId ?? this.mountId,
    vesaW: vesaW ?? this.vesaW,
    vesaH: vesaH ?? this.vesaH,
    vesaUp: vesaUp ?? this.vesaUp,
    vesaLeft: vesaLeft ?? this.vesaLeft,
    plateHeight: plateHeight ?? this.plateHeight,
    plateOffset: plateOffset ?? this.plateOffset,
    maxTiltDeg: maxTiltDeg ?? this.maxTiltDeg,
    armWidth: armWidth ?? this.armWidth,
    armSpanMin: armSpanMin ?? this.armSpanMin,
    armSpanMax: armSpanMax ?? this.armSpanMax,
    vesaMinW: vesaMinW ?? this.vesaMinW,
    vesaMinH: vesaMinH ?? this.vesaMinH,
    weightLb: weightLb ?? this.weightLb,
    capacityLb: capacityLb ?? this.capacityLb,
    touch: touch ?? this.touch,
    activeW: activeW ?? this.activeW,
    activeH: activeH ?? this.activeH,
    activeUp: activeUp ?? this.activeUp,
    note: note ?? this.note,
    locked: locked ?? this.locked,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    if (label.isNotEmpty) 'label': label,
    if (model.isNotEmpty) 'model': model,
    'x': x,
    'y': y,
    'w': width,
    'h': height,
    'd': depth,
    if (standoff != 0) 'standoff': standoff,
    if (tiltDeg != 0) 'tilt': tiltDeg,
    if (mountId.isNotEmpty) 'mount': mountId,
    if (vesaW > 0) 'vesaW': vesaW,
    if (vesaH > 0) 'vesaH': vesaH,
    if (vesaUp > 0) 'vesaUp': vesaUp,
    if (vesaLeft > 0) 'vesaLeft': vesaLeft,
    if (plateHeight > 0) 'plateH': plateHeight,
    if (plateOffset != 0) 'plateOff': plateOffset,
    if (maxTiltDeg > 0) 'maxTilt': maxTiltDeg,
    if (armWidth > 0) 'armW': armWidth,
    if (armSpanMin > 0) 'armSpanMin': armSpanMin,
    if (armSpanMax > 0) 'armSpanMax': armSpanMax,
    if (vesaMinW > 0) 'vesaMinW': vesaMinW,
    if (vesaMinH > 0) 'vesaMinH': vesaMinH,
    if (weightLb > 0) 'lb': weightLb,
    if (capacityLb > 0) 'capacityLb': capacityLb,
    if (touch) 'touch': true,
    if (activeW > 0) 'activeW': activeW,
    if (activeH > 0) 'activeH': activeH,
    if (activeUp > 0) 'activeUp': activeUp,
    if (note.isNotEmpty) 'note': note,
    if (locked) 'locked': true,
  };

  factory WallItem.fromJson(Map<String, dynamic> json) {
    double read(String k, [double fallback = 0]) {
      final v = (json[k] as num?)?.toDouble();
      return v != null && v.isFinite ? v : fallback;
    }

    double size(String k, double fallback) => math.max(0.1, read(k, fallback));
    double plus(String k) => math.max(0, read(k));
    return WallItem(
      id: json['id']?.toString() ?? '',
      kind: WallItemKind.fromName(json['kind']?.toString()),
      label: json['label']?.toString() ?? '',
      model: json['model']?.toString() ?? '',
      x: read('x'),
      y: read('y'),
      width: size('w', 12),
      height: size('h', 12),
      depth: math.max(0, read('d', 1)),
      standoff: plus('standoff'),
      tiltDeg: read('tilt').clamp(-45.0, 45.0),
      mountId: json['mount']?.toString() ?? '',
      vesaW: plus('vesaW'),
      vesaH: plus('vesaH'),
      vesaUp: plus('vesaUp'),
      vesaLeft: plus('vesaLeft'),
      plateHeight: plus('plateH'),
      plateOffset: read('plateOff'),
      maxTiltDeg: plus('maxTilt'),
      armWidth: plus('armW'),
      armSpanMin: plus('armSpanMin'),
      armSpanMax: plus('armSpanMax'),
      vesaMinW: plus('vesaMinW'),
      vesaMinH: plus('vesaMinH'),
      weightLb: plus('lb'),
      capacityLb: plus('capacityLb'),
      touch: json['touch'] == true,
      activeW: plus('activeW'),
      activeH: plus('activeH'),
      activeUp: plus('activeUp'),
      note: json['note']?.toString() ?? '',
      locked: json['locked'] == true,
    );
  }
}

/// One wall, straight on.
@immutable
class WallView {
  /// `WALL_<n>`.
  final String id;
  final String name;

  /// Wall length, and floor to ceiling; 0 when not known.
  final double widthIn, heightIn;

  final List<WallItem> items;
  final String note;

  const WallView({
    required this.id,
    required this.name,
    this.widthIn = 240,
    this.heightIn = 108,
    this.items = const [],
    this.note = '',
  });

  WallItem? item(String id) => items.where((i) => i.id == id).firstOrNull;

  /// The next free item id.
  String nextItemId() {
    var n = 0;
    for (final i in items) {
      final m = RegExp(r'^WI_(\d+)$').firstMatch(i.id);
      if (m != null) n = math.max(n, int.parse(m.group(1)!));
    }
    return 'WI_${n + 1}';
  }

  WallView copyWith({
    String? name,
    double? widthIn,
    double? heightIn,
    List<WallItem>? items,
    String? note,
  }) => WallView(
    id: id,
    name: name ?? this.name,
    widthIn: widthIn ?? this.widthIn,
    heightIn: heightIn ?? this.heightIn,
    items: items ?? this.items,
    note: note ?? this.note,
  );

  /// This wall with [item] in place of the one with its id, or added.
  WallView withItem(WallItem item) {
    final at = items.indexWhere((i) => i.id == item.id);
    final next = List<WallItem>.from(items);
    if (at < 0) {
      next.add(item);
    } else {
      next[at] = item;
    }
    return copyWith(items: next).resolved();
  }

  /// This wall without [itemId]. A display on it lets go of the mount; a cane
  /// rail under it stays where it was drawn.
  WallView withoutItem(String itemId) {
    final r = resolved();
    return copyWith(
      items: [
        for (final i in items)
          if (i.id != itemId)
            if (i.mountId != itemId)
              i
            else if (i.kind == WallItemKind.caneRail)
              (r.item(i.id) ?? i).copyWith(mountId: '')
            else
              i.copyWith(mountId: '', standoff: 0),
      ],
    );
  }

  /// Mounts moved to their displays, and displays stood off by their mounts.
  WallView resolved() {
    final byId = {for (final i in items) i.id: i};
    final out = <WallItem>[];
    final placed = <String, WallItem>{};
    for (final i in items) {
      if (i.kind != WallItemKind.display || i.mountId.isEmpty) continue;
      final m = byId[i.mountId];
      if (m == null || m.kind != WallItemKind.mount) continue;
      placed[m.id] = m.copyWith(
        x: i.vesaCenterX - m.width / 2,
        y: i.vesaCenterY - m.height / 2,
      );
    }
    for (final i in items) {
      if (placed[i.id] case final m?) {
        out.add(m);
        continue;
      }
      if (i.kind == WallItemKind.display && i.mountId.isNotEmpty) {
        final m = byId[i.mountId];
        if (m != null && m.kind == WallItemKind.mount) {
          out.add(i.copyWith(standoff: m.standoff + m.depth));
          continue;
        }
      }
      out.add(i);
    }
    // A cane rail keeps under what it guards: as wide, to within 4" of its
    // face (CBC 11B-307.2). Its height stays the user's; locked, it stays.
    final byOut = {for (final i in out) i.id: i};
    for (var n = 0; n < out.length; n++) {
      final r = out[n];
      if (r.kind != WallItemKind.caneRail || r.mountId.isEmpty || r.locked) {
        continue;
      }
      final g = byOut[r.mountId];
      if (g == null) continue;
      out[n] = r.copyWith(
        x: g.x,
        width: g.width,
        depth: math.max(1.5, g.front - kMaxProtrusionIn),
      );
    }
    return copyWith(items: out);
  }

  /// The item [railId] guards, if it is a cane rail tied to one.
  WallItem? guardedBy(String railId) {
    final r = item(railId);
    if (r == null || r.kind != WallItemKind.caneRail || r.mountId.isEmpty) {
      return null;
    }
    return item(r.mountId);
  }

  /// The display hanging on [mountId], if any.
  WallItem? displayOn(String mountId) => items
      .where((i) => i.kind == WallItemKind.display && i.mountId == mountId)
      .firstOrNull;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'w': widthIn,
    'h': heightIn,
    'items': [for (final i in items) i.toJson()],
    if (note.isNotEmpty) 'note': note,
  };

  factory WallView.fromJson(Map<String, dynamic> json) => WallView(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? 'Wall',
    widthIn: math.max(12, (json['w'] as num?)?.toDouble() ?? 240),
    heightIn: math.max(0, (json['h'] as num?)?.toDouble() ?? 108),
    items: [
      for (final i in (json['items'] as List? ?? const []))
        if (i is Map) WallItem.fromJson(Map<String, dynamic>.from(i)),
    ],
    note: json['note']?.toString() ?? '',
  );
}

// ---------------------------------------------------------------------------
//  MOUNTING
// ---------------------------------------------------------------------------

/// Where one wall mount goes, for the installer: its plate on the wall, the
/// holes it carries, and the display on it.
@immutable
class MountPlacement {
  /// M1, M2... left to right.
  final String tag;
  final WallItem mount;
  final WallItem? display;
  final double wallWidth;

  const MountPlacement({
    required this.tag,
    required this.mount,
    required this.display,
    required this.wallWidth,
  });

  /// The plate on the wall, y up: `top` is its bottom edge.
  Rect get plate => mount.wallFootprint;

  double get plateLeft => plate.left;
  double get plateRight => plate.right;
  double get plateWidth => plate.width;
  double get plateBottom => plate.top;
  double get plateTop => plate.bottom;
  double get plateHeight => plate.height;

  /// The plate's center line, along the wall and above the floor.
  double get centerX => plate.center.dx;
  double get centerY => plate.center.dy;

  double get fromLeft => centerX;
  double get fromRight => wallWidth - centerX;

  /// The VESA holes it carries: its display's, else its own largest.
  List<Offset> get holes {
    final d = display;
    if (d != null && d.vesaHoles.isNotEmpty) return d.vesaHoles;
    return mount.vesaHoles;
  }

  /// The mount's center above the floor: the arms' middle, on its display's
  /// VESA center.
  double get mountCenterY => mount.centerY;

  /// The low and high rows of holes the arms bolt to, above the floor; null
  /// with no pattern.
  double? get lowHolesY => holes.isEmpty ? null : holes.first.dy;
  double? get highHolesY => holes.isEmpty ? null : holes.last.dy;

  /// The VESA pattern, mm.
  double get vesaWmm => display != null && display!.vesaW > 0 ? display!.vesaW : mount.vesaW;
  double get vesaHmm => display != null && display!.vesaH > 0 ? display!.vesaH : mount.vesaH;

  /// The display's back off the wall face.
  double get offWall => mount.standoff + mount.depth;
}

/// [mountId]'s wall plate as drawn, y up: `top` is its bottom edge.
Rect? plateOf(WallView wall, String mountId) {
  final m = wall.resolved().item(mountId);
  return m == null || m.kind != WallItemKind.mount ? null : m.wallFootprint;
}

/// [wall] with [mountId]'s plate bottom [bottom] above the floor. A display
/// hanging on it moves, and the mount with it.
WallView withPlateBottom(WallView wall, String mountId, double bottom) {
  final plate = plateOf(wall, mountId);
  if (plate == null) return wall;
  final dy = bottom - plate.top;
  if (dy.abs() < 1e-9) return wall;
  final moved = wall.displayOn(mountId) ?? wall.item(mountId)!;
  return wall.withItem(moved.copyWith(y: moved.y + dy));
}

/// A line on the wall to measure from: up and down at [x], level at [y], or
/// a point with both.
@immutable
class WallMark {
  final String id, label;
  final double? x, y;
  const WallMark(this.id, this.label, {this.x, this.y});
}

/// The holes [m]'s arms bolt to: its display's, else its own pattern.
WallItem _holesFor(WallItem m, WallItem? d) =>
    d != null && d.vesaW > 0 && d.vesaH > 0 ? d : m;

/// How high [m]'s hook seat (the plate's top) is above the top VESA holes
/// its arms bolt to.
double hookAboveTopHoles(WallItem m, WallItem? d) {
  final h = _holesFor(m, d);
  return m.plateOffset + m.plateHeight / 2 - h.vesaHIn / 2;
}

/// [m] with its hooks [above] the top VESA holes.
WallItem withHookAboveTopHoles(WallItem m, WallItem? d, double above) {
  final h = _holesFor(m, d);
  return m.copyWith(
    plateOffset: above - m.plateHeight / 2 + h.vesaHIn / 2,
  );
}

/// Where [m]'s arms run along the wall: on [d]'s VESA holes when it hangs
/// one, else on its own largest pattern.
List<double> armCenters(WallItem m, WallItem? d) {
  final span = d != null && d.vesaW > 0
      ? d.vesaWIn
      : math.min(m.width - 2, m.vesaWIn);
  return [m.centerX - span / 2, m.centerX + span / 2];
}

/// The wall's own lines: its ends, the floor and the ceiling.
List<WallMark> wallMarks(WallView wall) => [
  const WallMark('wall:left', 'Wall: left end', x: 0),
  WallMark('wall:right', 'Wall: right end', x: wall.widthIn),
  const WallMark('wall:floor', 'Floor', y: 0),
  if (wall.heightIn > 0)
    WallMark('wall:ceiling', 'Ceiling', y: wall.heightIn),
];

/// What can be measured from on [i]: its edges and center; a display's VESA
/// hole lines; a mount's plate and each arm.
List<WallMark> marksOf(WallView wall, WallItem i) {
  final n = i.name, p = '${i.id}:';
  if (i.kind == WallItemKind.mount) {
    final plate = i.wallFootprint;
    final hung = wall.displayOn(i.id);
    final arms = armCenters(i, hung);
    final half = i.armDrawWidth / 2;
    // The holes it carries: its display's, else its own largest pattern.
    final h = hung != null && hung.vesaW > 0 ? hung : i;
    final holes = h.vesaW > 0 && h.vesaH > 0;
    return [
      if (holes) ...[
        WallMark('${p}hL', '$n: left holes',
            x: h.vesaCenterX - h.vesaWIn / 2),
        WallMark('${p}hR', '$n: right holes',
            x: h.vesaCenterX + h.vesaWIn / 2),
        WallMark('${p}hB', '$n: low holes',
            y: h.vesaCenterY - h.vesaHIn / 2),
        WallMark('${p}hT', '$n: high holes',
            y: h.vesaCenterY + h.vesaHIn / 2),
        WallMark('${p}hC', '$n: holes center',
            x: h.vesaCenterX, y: h.vesaCenterY),
        ..._holeMarks(p, '$n:', h),
      ],
      WallMark('${p}plateL', '$n: plate left end', x: plate.left),
      WallMark('${p}plateR', '$n: plate right end', x: plate.right),
      WallMark('${p}plateB', '$n: plate bottom', y: plate.top),
      WallMark('${p}plateT', '$n: plate top', y: plate.bottom),
      WallMark('${p}plateC', '$n: plate center line',
          x: plate.center.dx, y: plate.center.dy),
      WallMark('${p}armLo', '$n: left arm, outer edge', x: arms[0] - half),
      WallMark('${p}armLc', '$n: left arm, center line', x: arms[0]),
      WallMark('${p}armLi', '$n: left arm, inner edge', x: arms[0] + half),
      WallMark('${p}armRi', '$n: right arm, inner edge', x: arms[1] - half),
      WallMark('${p}armRc', '$n: right arm, center line', x: arms[1]),
      WallMark('${p}armRo', '$n: right arm, outer edge', x: arms[1] + half),
      WallMark('${p}armB', '$n: arm bottom ends', y: i.y),
      WallMark('${p}armT', '$n: arm top ends', y: i.top),
    ];
  }
  final holes = i.vesaW > 0 && i.vesaH > 0;
  return [
    WallMark('${p}L', '$n: left edge', x: i.x),
    WallMark('${p}R', '$n: right edge', x: i.right),
    WallMark('${p}B', '$n: bottom', y: i.y),
    WallMark('${p}T', '$n: top', y: i.top),
    WallMark('${p}C', '$n: center', x: i.centerX, y: i.centerY),
    if (holes) ...[
      WallMark('${p}vL', '$n: VESA left holes',
          x: i.vesaCenterX - i.vesaWIn / 2),
      WallMark('${p}vR', '$n: VESA right holes',
          x: i.vesaCenterX + i.vesaWIn / 2),
      WallMark('${p}vB', '$n: VESA low holes',
          y: i.vesaCenterY - i.vesaHIn / 2),
      WallMark('${p}vT', '$n: VESA high holes',
          y: i.vesaCenterY + i.vesaHIn / 2),
      WallMark('${p}vC', '$n: VESA center',
          x: i.vesaCenterX, y: i.vesaCenterY),
      ..._holeMarks(p, '$n: VESA', i),
    ],
  ];
}

/// [h]'s four corner holes, each a point, so a single hole can be measured
/// to the floor, the ceiling or a wall end.
List<WallMark> _holeMarks(String p, String n, WallItem h) {
  final l = h.vesaCenterX - h.vesaWIn / 2, r = h.vesaCenterX + h.vesaWIn / 2;
  final b = h.vesaCenterY - h.vesaHIn / 2, t = h.vesaCenterY + h.vesaHIn / 2;
  return [
    WallMark('${p}pTL', '$n top left hole', x: l, y: t),
    WallMark('${p}pTR', '$n top right hole', x: r, y: t),
    WallMark('${p}pBL', '$n bottom left hole', x: l, y: b),
    WallMark('${p}pBR', '$n bottom right hole', x: r, y: b),
  ];
}

/// The mark with [id] on [wall], or null.
WallMark? markById(WallView wall, String id) {
  if (id.isEmpty) return null;
  if (id.startsWith('wall:')) {
    return wallMarks(wall).where((m) => m.id == id).firstOrNull;
  }
  final item = wall.item(id.substring(0, math.max(0, id.indexOf(':'))));
  if (item == null) return null;
  return marksOf(wall, item).where((m) => m.id == id).firstOrNull;
}

/// From [a] to [b]: across when both have a place along the wall, up and
/// down when both have a height; null each way they cannot be compared.
({double? across, double? upDown}) markDistance(WallMark a, WallMark b) => (
  across: a.x != null && b.x != null ? (a.x! - b.x!).abs() : null,
  upDown: a.y != null && b.y != null ? (a.y! - b.y!).abs() : null,
);

/// The space between [a] and [b] on the wall face: clear across and clear
/// up and down, edge to edge (0 where they overlap that way), and center
/// to center each way.
({double across, double upDown, double centersAcross, double centersUpDown})
    gapBetween(WallItem a, WallItem b) => (
  across: math.max(0, math.max(b.x - a.right, a.x - b.right)),
  upDown: math.max(0, math.max(b.y - a.top, a.y - b.top)),
  centersAcross: (a.centerX - b.centerX).abs(),
  centersUpDown: (a.centerY - b.centerY).abs(),
);

/// Every mount on [wall], left to right, tagged M1, M2...
List<MountPlacement> mountPlacements(WallView wall) {
  final mounts = [
    for (final i in wall.items)
      if (i.kind == WallItemKind.mount) i,
  ]..sort((a, b) => a.wallFootprint.center.dx.compareTo(b.wallFootprint.center.dx));
  return [
    for (var n = 0; n < mounts.length; n++)
      MountPlacement(
        tag: 'M${n + 1}',
        mount: mounts[n],
        display: wall.displayOn(mounts[n].id),
        wallWidth: wall.widthIn,
      ),
  ];
}

/// A VESA pattern as "600 x 400 mm", '' when none.
String vesaLabel(double wMm, double hMm) {
  if (wMm <= 0 || hMm <= 0) return '';
  String n(double v) => v.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  return '${n(wMm)} x ${n(hMm)} mm';
}

// ---------------------------------------------------------------------------
//  CHECKS
// ---------------------------------------------------------------------------

enum WallIssueLevel { problem, warning, note }

@immutable
class WallIssue {
  final WallIssueLevel level;
  final String text;
  final List<String> itemIds;

  /// An accessibility finding (ADA / California CBC 11B), listed apart.
  final bool access;

  /// A recommendation under the finding, '' for none.
  final String advice;

  /// The item a cane rail would guard, '' when a rail is not the fix.
  final String railFor;

  const WallIssue(
    this.level,
    this.text, [
    this.itemIds = const [],
    this.access = false,
    this.advice = '',
    this.railFor = '',
  ]);

  @override
  String toString() => '${level.name}: $text';
}

/// Inches as 4' 6", or 7.6" under a foot.
/// How the Walls tab shows a length.
enum LengthUnit {
  feet('Feet', "ft-in"),
  inches('Inches', 'in'),
  cm('Centimeters', 'cm'),
  mm('Millimeters', 'mm');

  final String label, short;
  const LengthUnit(this.label, this.short);

  static LengthUnit fromName(String? name) =>
      values.where((u) => u.name == name).firstOrNull ?? feet;
}

/// The unit [inchesLabel] shows; set from the user's settings.
LengthUnit wallLengthUnit = LengthUnit.feet;

/// [inches] in [wallLengthUnit]: 3' 6", 42", 106.7 cm or 1067 mm.
String inchesLabel(double inches, {LengthUnit? unit}) {
  if (!inches.isFinite) return '-';
  final neg = inches < 0;
  final v = inches.abs();
  String body;
  switch (unit ?? wallLengthUnit) {
    case LengthUnit.inches:
      body = '${_trim2(v)}"';
    case LengthUnit.cm:
      body = '${_trim(v * 2.54)} cm';
    case LengthUnit.mm:
      body = '${(v * 25.4).round()} mm';
    case LengthUnit.feet:
      body = _feetBody(v);
  }
  return neg ? '-$body' : body;
}

/// [inches] for a text box to edit, in [wallLengthUnit], with its mark so
/// [parseInchesText] reads it back the same.
String lengthFieldText(double inches) {
  String t(double v, int places) =>
      v.toStringAsFixed(places).replaceFirst(RegExp(r'\.?0+$'), '');
  return switch (wallLengthUnit) {
    LengthUnit.cm => '${t(inches * 2.54, 2)} cm',
    LengthUnit.mm => '${t(inches * 25.4, 1)} mm',
    LengthUnit.feet when inches.abs() >= 12 => _feetField(inches, t),
    _ => '${t(inches, 3)}"',
  };
}

String _feetField(double inches, String Function(double, int) t) {
  final v = double.parse(inches.abs().toStringAsFixed(3));
  final ft = (v / 12).floor();
  final rest = double.parse((v - ft * 12).toStringAsFixed(3));
  final body = rest == 0 ? "$ft'" : "$ft' ${t(rest, 3)}\"";
  return inches < 0 ? '-$body' : body;
}

String _feetBody(double v) {
  String body;
  if (v < 12) {
    body = '${_trim(v)}"';
  } else {
    var ft = (v / 12).floor();
    var rest = double.parse((v - ft * 12).toStringAsFixed(1));
    if (rest >= 12) {
      ft++;
      rest = 0;
    }
    body = rest == 0 ? "$ft'" : "$ft' ${_trim(rest)}\"";
  }
  return body;
}

String _trim(double v) =>
    v.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');

String _trim2(double v) =>
    v.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

/// A length typed in: 36, 36.5, 36", 3', 3' 6", 3ft 6in, 91.4 cm, 914 mm or
/// 0.9 m. A bare number is inches, or cm or mm when that is the unit shown.
/// Null when it does not read as one.
double? parseInchesText(String text) {
  var s = text.trim().toLowerCase();
  if (s.isEmpty) return null;
  final neg = s.startsWith('-');
  if (neg) s = s.substring(1).trim();
  double? v;
  final feet = RegExp(
    r"""^([\d.]+)\s*(?:'|ft|feet|foot)\s*(?:([\d.]+)\s*(?:"|in|inch|inches)?)?$""",
  ).firstMatch(s);
  if (feet != null) {
    final ft = double.tryParse(feet.group(1)!);
    final inch = feet.group(2) == null ? 0.0 : double.tryParse(feet.group(2)!);
    if (ft != null && inch != null) v = ft * 12 + inch;
  } else {
    final metric = RegExp(r'^([\d.]+)\s*(mm|cm|m)$').firstMatch(s);
    final m = RegExp(r'^([\d.]+)\s*("|in|inch|inches)?$').firstMatch(s);
    if (metric != null) {
      final n = double.tryParse(metric.group(1)!);
      if (n != null) {
        v = switch (metric.group(2)) {
          'mm' => n / 25.4,
          'cm' => n / 2.54,
          _ => n / 0.0254,
        };
      }
    } else if (m != null) {
      final n = double.tryParse(m.group(1)!);
      // A bare number is in the unit shown, when that is metric.
      v = n == null || m.group(2) != null
          ? n
          : switch (wallLengthUnit) {
              LengthUnit.cm => n / 2.54,
              LengthUnit.mm => n / 25.4,
              _ => n,
            };
    }
  }
  if (v == null || !v.isFinite) return null;
  return neg ? -v : v;
}

/// Length of the overlap of [a0, a1] and [b0, b1]; 0 or less when apart.
double _overlap(double a0, double a1, double b0, double b1) =>
    math.min(a1, b1) - math.max(a0, b0);

/// Everything worth saying about [wall], worst first.
List<WallIssue> checkWall(WallView wall) {
  final w = wall.resolved();
  final out = <WallIssue>[];
  final items = w.items;

  // On the wall at all.
  for (final i in items) {
    if (i.x < -_kTouch || i.right > w.widthIn + _kTouch) {
      out.add(WallIssue(
        WallIssueLevel.problem,
        '${i.name} runs past the end of the wall.',
        [i.id],
      ));
    }
    if (i.y < -_kTouch) {
      out.add(WallIssue(
        WallIssueLevel.problem,
        '${i.name} is below the floor.',
        [i.id],
      ));
    }
    if (w.heightIn > 0 && i.top > w.heightIn + _kTouch) {
      out.add(WallIssue(
        WallIssueLevel.problem,
        '${i.name} goes ${inchesLabel(i.top - w.heightIn)} above the '
        'ceiling.',
        [i.id],
      ));
    }
  }

  // Two things in the same place.
  for (var a = 0; a < items.length; a++) {
    for (var b = a + 1; b < items.length; b++) {
      final issue = _pairIssue(items[a], items[b]);
      if (issue != null) out.add(issue);
    }
  }

  // Mounts and their displays.
  for (final d in items) {
    if (d.kind != WallItemKind.display) continue;
    final holes = d.vesaHoles;
    if (holes.any((h) =>
        h.dx < d.x - _kTouch ||
        h.dx > d.right + _kTouch ||
        h.dy < d.y - _kTouch ||
        h.dy > d.top + _kTouch)) {
      out.add(WallIssue(
        WallIssueLevel.problem,
        '${d.name}\'s VESA holes fall off its back - check where they are.',
        [d.id],
      ));
    }
    final m = d.mountId.isEmpty ? null : w.item(d.mountId);
    if (m == null) {
      out.add(WallIssue(
        WallIssueLevel.note,
        '${d.name} has no wall mount picked.',
        [d.id],
      ));
      continue;
    }
    out.addAll(_mountIssues(d, m));
  }

  // Sticking out into the room.
  for (final i in items) {
    final p = _protrusion(i, items);
    if (p != null) out.add(p);
  }

  // A hook seat that puts the plate past the arms' ends.
  for (final m in items) {
    if (m.kind != WallItemKind.mount || m.plateHeight <= 0) continue;
    final room = (m.height - m.plateHeight) / 2;
    if (m.plateOffset.abs() > room + _kTouch) {
      out.add(WallIssue(
        WallIssueLevel.warning,
        '${m.name}\'s plate sits past the ends of its arms: check where '
        'the hooks seat.',
        [m.id],
      ));
    }
  }

  // Reach.
  for (final i in items) {
    if (i.touch) {
      final a = i.activeFace;
      final above = a.bottom - kReachHighIn;
      if (above > _kTouch) {
        final pct = (above / a.height * 100).clamp(0, 100).round();
        out.add(WallIssue(
          WallIssueLevel.note,
          'The top ${inchesLabel(above)} ($pct%) of ${i.name}\'s touch '
          'area is above the 48" reach limit.',
          [i.id],
          true,
          'Keep the controls people need - the home screen, inputs, volume - '
          'in the lower part, below 48" (ADA 308, CBC 11B-308).',
        ));
      }
      if (a.top < kReachLowIn - _kTouch) {
        out.add(WallIssue(
          WallIssueLevel.note,
          '${i.name}\'s touch area starts below 15" off the floor.',
          [i.id],
          true,
        ));
      }
    } else if (i.kind.operable && i.top > kReachHighIn + _kTouch) {
      out.add(WallIssue(
        WallIssueLevel.note,
        '${i.name} is above the 48" reach limit '
        '(top at ${inchesLabel(i.top)}).',
        [i.id],
        true,
        'Lower it so its top is at 48" or below (ADA 308, CBC 11B-308).',
      ));
    }
  }

  // Power and data behind each display.
  for (final d in items) {
    if (d.kind != WallItemKind.display) continue;
    final fed = items.any((o) =>
        (o.kind == WallItemKind.outlet || o.kind == WallItemKind.recessedBox) &&
        _overlap(o.x, o.right, d.x, d.right) > _kTouch &&
        _overlap(o.y, o.top, d.y, d.top) > _kTouch);
    if (!fed) {
      out.add(WallIssue(
        WallIssueLevel.note,
        'No power or data box behind ${d.name}.',
        [d.id],
      ));
    }
  }

  if (w.heightIn <= 0) {
    out.add(const WallIssue(
      WallIssueLevel.note,
      'Ceiling height not set, so nothing is checked against it.',
    ));
  }

  out.sort((a, b) => a.level.index.compareTo(b.level.index));
  return out;
}

/// What [a] and [b] do to each other, or null.
WallIssue? _pairIssue(WallItem a, WallItem b) {
  // A display and its own mount belong together.
  if (a.mountId == b.id || b.mountId == a.id) return null;
  final fa = a.kind == WallItemKind.mount ? a.wallFootprint : a.face;
  final fb = b.kind == WallItemKind.mount ? b.wallFootprint : b.face;
  final ox = _overlap(fa.left, fa.right, fb.left, fb.right);
  final oy = _overlap(fa.top, fa.bottom, fb.top, fb.bottom);
  if (ox <= _kTouch || oy <= _kTouch) return null;
  final ids = [a.id, b.id];
  final size = '${inchesLabel(ox)} x ${inchesLabel(oy)}';

  // Openings first: nothing goes over a door, and a window is a warning.
  for (final (open, other) in [(a, b), (b, a)]) {
    if (!open.kind.isOpening || other.kind.isOpening) continue;
    return WallIssue(
      open.kind == WallItemKind.door
          ? WallIssueLevel.problem
          : WallIssueLevel.warning,
      '${other.name} is over the ${open.kind.label.toLowerCase()} '
      '($size).',
      ids,
    );
  }

  // Raceway meets the boxes it feeds and the raceway it joins.
  for (final (r, other) in [(a, b), (b, a)]) {
    if (r.kind != WallItemKind.raceway) continue;
    if (other.kind == WallItemKind.raceway ||
        other.kind == WallItemKind.outlet ||
        other.kind == WallItemKind.recessedBox) {
      return null;
    }
  }

  final od = _overlap(a.back, a.front, b.back, b.front);
  if (od > _kTouch) {
    return WallIssue(
      WallIssueLevel.problem,
      '${a.name} runs into ${b.name}: $size, ${inchesLabel(od)} deep.',
      ids,
    );
  }

  // One in front of the other.
  final (behind, before) = a.back < b.back ? (a, b) : (b, a);
  if (behind.kind.keepUncovered) {
    return WallIssue(
      behind.kind == WallItemKind.fireAlarm
          ? WallIssueLevel.problem
          : WallIssueLevel.warning,
      '${before.name} covers ${behind.name}.',
      ids,
    );
  }
  if (behind.kind.operable) {
    return WallIssue(
      WallIssueLevel.warning,
      '${behind.name} is hidden behind ${before.name}.',
      ids,
    );
  }
  if (behind.kind == WallItemKind.outlet ||
      behind.kind == WallItemKind.recessedBox) {
    // Power behind a display is the point.
    return null;
  }
  return WallIssue(
    WallIssueLevel.note,
    '${before.name} is in front of ${behind.name}, with '
    '${inchesLabel(before.back - behind.front)} between them.',
    ids,
  );
}

/// [d] on [m]: pattern, weight, size and tilt.
List<WallIssue> _mountIssues(WallItem d, WallItem m) {
  final out = <WallIssue>[];
  final ids = [d.id, m.id];
  if (d.vesaW > 0 && m.vesaW > 0 && d.vesaW > m.vesaW + 0.5) {
    out.add(WallIssue(
      WallIssueLevel.problem,
      '${d.name}\'s VESA ${d.vesaW.round()} mm is wider than ${m.name} '
      'takes (${m.vesaW.round()} mm).',
      ids,
    ));
  }
  if (d.vesaH > 0 && m.vesaH > 0 && d.vesaH > m.vesaH + 0.5) {
    out.add(WallIssue(
      WallIssueLevel.problem,
      '${d.name}\'s VESA ${d.vesaH.round()} mm is taller than ${m.name} '
      'takes (${m.vesaH.round()} mm).',
      ids,
    ));
  }
  if (d.vesaH > 0 && d.vesaH * kInPerMm > m.height + _kTouch) {
    out.add(WallIssue(
      WallIssueLevel.problem,
      '${m.name}\'s arms (${inchesLabel(m.height)}) are shorter than '
      '${d.name}\'s hole spacing (${inchesLabel(d.vesaH * kInPerMm)}).',
      ids,
    ));
  }
  if (d.vesaW > 0 && m.vesaMinW > 0 && d.vesaW < m.vesaMinW - 0.5) {
    out.add(WallIssue(
      WallIssueLevel.problem,
      '${d.name}\'s VESA ${d.vesaW.round()} mm is narrower than ${m.name} '
      'takes (${m.vesaMinW.round()} mm at least).',
      ids,
    ));
  }
  if (d.vesaH > 0 && m.vesaMinH > 0 && d.vesaH < m.vesaMinH - 0.5) {
    out.add(WallIssue(
      WallIssueLevel.problem,
      '${d.name}\'s VESA ${d.vesaH.round()} mm is shorter than ${m.name} '
      'takes (${m.vesaMinH.round()} mm at least).',
      ids,
    ));
  }
  if (d.vesaW > 0 && m.armSpanMax > 0 && d.vesaWIn > m.armSpanMax + _kTouch) {
    out.add(WallIssue(
      WallIssueLevel.problem,
      '${m.name}\'s arms go ${inchesLabel(m.armSpanMax)} apart at most; '
      '${d.name}\'s holes are ${inchesLabel(d.vesaWIn)} apart.',
      ids,
    ));
  }
  if (d.vesaW > 0 && m.armSpanMin > 0 && d.vesaWIn < m.armSpanMin - _kTouch) {
    out.add(WallIssue(
      WallIssueLevel.problem,
      '${m.name}\'s arms close to ${inchesLabel(m.armSpanMin)} apart at '
      'least; ${d.name}\'s holes are ${inchesLabel(d.vesaWIn)} apart.',
      ids,
    ));
  }
  if (m.capacityLb > 0 && d.weightLb > 0 && d.weightLb > m.capacityLb) {
    out.add(WallIssue(
      WallIssueLevel.problem,
      '${d.name} (${d.weightLb.round()} lb) is over ${m.name}\'s '
      '${m.capacityLb.round()} lb limit.',
      ids,
    ));
  } else if (m.capacityLb > 0 && d.weightLb <= 0) {
    out.add(WallIssue(
      WallIssueLevel.note,
      '${d.name} has no weight set, so it is not checked against '
      '${m.name}\'s ${m.capacityLb.round()} lb limit.',
      ids,
    ));
  } else if (m.capacityLb <= 0) {
    out.add(WallIssue(
      WallIssueLevel.note,
      '${m.name} has no weight limit set, so ${d.name} is not checked '
      'against it.',
      ids,
    ));
  }
  if (d.vesaW > 0 && m.vesaW <= 0 && m.vesaH <= 0) {
    out.add(WallIssue(
      WallIssueLevel.note,
      '${m.name} has no VESA range set, so ${d.name}\'s '
      '${vesaLabel(d.vesaW, d.vesaH)} is not checked against it.',
      ids,
    ));
  }
  if (m.x < d.x - _kTouch ||
      m.right > d.right + _kTouch ||
      m.y < d.y - _kTouch ||
      m.top > d.top + _kTouch) {
    out.add(WallIssue(
      WallIssueLevel.warning,
      '${m.name} shows past the edge of ${d.name}.',
      ids,
    ));
  }
  if (d.tiltDeg.abs() > m.maxTiltDeg + 0.05) {
    out.add(WallIssue(
      WallIssueLevel.problem,
      m.maxTiltDeg > 0
          ? '${d.name} is tilted ${d.tiltDeg.abs().round()}°; ${m.name} '
              'tilts ${m.maxTiltDeg.round()}° at most.'
          : '${d.name} is tilted, but ${m.name} is fixed.',
      ids,
    ));
  }
  return out;
}

/// [i] sticking out more than 4" between 27" and 80" with nothing under it
/// a cane would find first.
WallIssue? _protrusion(WallItem i, List<WallItem> all) {
  if (i.kind.onFloor || i.kind.isOpening) return null;
  final reach = i.front;
  if (reach <= kMaxProtrusionIn + _kTouch) return null;
  if (i.y <= kCaneDetectIn + _kTouch || i.y >= kHeadroomIn - _kTouch) {
    return null;
  }
  // Something on the floor under it, low enough to find and deep enough
  // to keep a person back.
  final guarded = all.any((o) =>
      o.id != i.id &&
      ((o.kind.onFloor && o.top <= kCaneDetectIn + _kTouch) ||
          (o.kind == WallItemKind.caneRail &&
              o.y <= kCaneDetectIn + _kTouch)) &&
      o.x <= i.x + _kTouch &&
      o.right >= i.right - _kTouch &&
      o.front >= reach - kMaxProtrusionIn - _kTouch);
  if (guarded) return null;
  final rail = caneRailFor(i);
  return WallIssue(
    WallIssueLevel.warning,
    '${i.name} sticks out ${inchesLabel(reach)} with its bottom at '
    '${inchesLabel(i.y)}: past the 4" limit between 27" and 80" '
    '(ADA 307.2, CBC 11B-307.2) unless something under it can be found '
    'with a cane.',
    [i.id],
    true,
    'California: put a cane rail under it - its bottom edge at '
    '${inchesLabel(kCaneDetectIn)} or lower, reaching at least '
    '${inchesLabel(rail.front)} out from the wall (within 4" of the face), '
    'and running its full ${inchesLabel(i.width)} width. A credenza or '
    'cabinet no taller than 27" and as deep does the same job.',
    i.id,
  );
}

/// A cane rail that guards [i] (a resolved item): as wide, its bottom at
/// 25.5" so its 1.5" rail tops out at 27", reaching to within 4" of [i]'s
/// face. Tied to [i], it follows it.
WallItem caneRailFor(WallItem i, {String id = ''}) => WallItem(
  id: id,
  kind: WallItemKind.caneRail,
  label: 'Cane rail',
  mountId: i.id,
  x: i.x,
  y: kCaneDetectIn - 1.5,
  width: i.width,
  height: 1.5,
  depth: math.max(1.5, i.front - kMaxProtrusionIn),
  note: 'Cane-detectable rail under ${i.name} (CBC 11B-307.2).',
);

/// [wall] with a cane rail under [itemId].
WallView withCaneRail(WallView wall, String itemId) {
  final i = wall.resolved().item(itemId);
  if (i == null) return wall;
  return wall.withItem(caneRailFor(i, id: wall.nextItemId()));
}

/// The item on [wall] that most needs a cane rail, nearest [atX] (else the
/// wall's middle); null when none does.
WallItem? railTarget(WallView wall, {double? atX}) {
  final r = wall.resolved();
  final x = atX ?? wall.widthIn / 2;
  final needs = [
    for (final issue in checkWall(wall))
      if (issue.railFor.isNotEmpty) ?r.item(issue.railFor),
  ]..sort((a, b) =>
      (a.centerX - x).abs().compareTo((b.centerX - x).abs()));
  return needs.firstOrNull;
}

// ---------------------------------------------------------------------------
//  PRESETS
// ---------------------------------------------------------------------------

/// The usual VESA patterns, mm wide by mm high.
const List<(double, double)> kVesaPatterns = [
  (0, 0),
  (75, 75),
  (100, 100),
  (200, 100),
  (200, 200),
  (300, 200),
  (300, 300),
  (400, 200),
  (400, 300),
  (400, 400),
  (600, 400),
  (600, 600),
  (800, 400),
  (800, 600),
];

/// Surface raceway and conduit, face width and depth off the wall, inches.
/// Wiremold from Legrand's and distributors' listings; EMT by its outside
/// diameter, strapped tight to the wall.
const List<({String name, String label, String model, double across, double deep})>
    kRacewaySizes = [
  (name: 'Wiremold 500 (3/4" x 17/32")', label: 'Wiremold 500',
      model: 'V500', across: 0.75, deep: 0.53),
  (name: 'Wiremold 700 (3/4" x 21/32")', label: 'Wiremold 700',
      model: 'V700', across: 0.75, deep: 0.66),
  (name: 'Wiremold 2400 (1-29/32" x 7/8")', label: 'Wiremold 2400',
      model: 'V2400', across: 1.91, deep: 0.88),
  (name: 'Wiremold 4000 (4-3/4" x 1-3/4")', label: 'Wiremold 4000',
      model: 'V4000', across: 4.75, deep: 1.75),
  (name: 'Conduit, 1/2" EMT (0.706" OD)', label: '1/2" EMT',
      model: '', across: 0.706, deep: 0.706),
  (name: 'Conduit, 3/4" EMT (0.922" OD)', label: '3/4" EMT',
      model: '', across: 0.922, deep: 0.922),
  (name: 'Conduit, 1" EMT (1.163" OD)', label: '1" EMT',
      model: '', across: 1.163, deep: 1.163),
  (name: 'Conduit, 1-1/4" EMT (1.510" OD)', label: '1-1/4" EMT',
      model: '', across: 1.51, deep: 1.51),
];

/// [i] turned a quarter about its center: a run up the wall laid across, or
/// back.
WallItem turned(WallItem i) => i.copyWith(
  x: i.centerX - i.height / 2,
  y: math.max(0, i.centerY - i.width / 2),
  width: i.height,
  height: i.width,
);

/// A ready-made item for the add menu.
@immutable
class WallItemPreset {
  final String group;
  final String name;
  final WallItem item;
  const WallItemPreset(this.group, this.name, this.item);
}

/// The Newline Q Pro 86" (TT-8624QPRO), from Newline's dimensional drawing.
/// The active area's height off the frame bottom is read off the drawing.
const WallItem kNewlineQPro86 = WallItem(
  id: '',
  kind: WallItemKind.display,
  label: 'Newline Q Pro 86"',
  model: 'TT-8624QPRO',
  width: 78.03,
  height: 46.88,
  depth: 4.7,
  vesaW: 800,
  vesaH: 400,
  // Holes 14.3" up and 23.25" in from the left, 15.75" by 31.49" apart.
  vesaUp: 14.3 + 15.75 / 2,
  vesaLeft: 23.25 + 31.49 / 2,
  touch: true,
  activeW: 74.73,
  activeH: 42.04,
  activeUp: 3.4,
);

/// Newline's tilting mount EPR8A50600-000: 37.79" wide on a 9.76" plate,
/// 2.67" off the wall, +5/-10°, VESA 100 x 100 to 800 x 400, 250 lb.
const WallItem kNewlineTiltMount = WallItem(
  id: '',
  kind: WallItemKind.mount,
  label: 'Newline tilt mount',
  model: 'EPR8A50600-000',
  width: 37.79,
  height: 16.5,
  depth: 2.67,
  plateHeight: 9.76,
  // Arm length and width read off the drawing; arms 3.93" to 31.49" apart.
  armWidth: 1.45,
  armSpanMin: 3.93,
  armSpanMax: 31.49,
  vesaW: 800,
  vesaH: 400,
  vesaMinW: 100,
  vesaMinH: 100,
  maxTiltDeg: 10,
  capacityLb: 250,
);

final List<WallItemPreset> kWallItemPresets = [
  WallItemPreset('Displays', 'Newline Q Pro 86" (TT-8624QPRO)', kNewlineQPro86),
  WallItemPreset(
    'Displays',
    'Display, 75" generic',
    WallItem(
      id: '',
      kind: WallItemKind.display,
      label: 'Display 75"',
      width: 66.3,
      height: 38.0,
      depth: 3,
      vesaW: 600,
      vesaH: 400,
    ),
  ),
  WallItemPreset(
    'Displays',
    'Display, 65" generic',
    WallItem(
      id: '',
      kind: WallItemKind.display,
      label: 'Display 65"',
      width: 57.3,
      height: 33.0,
      depth: 3,
      vesaW: 400,
      vesaH: 300,
    ),
  ),
  WallItemPreset(
    'Mounts',
    'Newline tilt mount (EPR8A50600-000)',
    kNewlineTiltMount,
  ),
  WallItemPreset(
    'Mounts',
    'Chief Fusion fixed mount (XSM1U)',
    wallItemFromSpec(kSpecChiefXSM1U, model: 'XSM1U', label: 'Chief XSM1U'),
  ),
  WallItemPreset(
    'Mounts',
    'Chief Fusion tilt mount (XTM1U)',
    wallItemFromSpec(kSpecChiefXTM1U, model: 'XTM1U', label: 'Chief XTM1U'),
  ),
  WallItemPreset(
    'Mounts',
    'Ergotron Neo-Flex tilt mount (60-612)',
    wallItemFromSpec(
      kSpecErgotron60612,
      model: '60-612',
      label: 'Ergotron 60-612',
    ),
  ),
  WallItemPreset(
    'Mounts',
    'Flat mount, low profile',
    WallItem(
      id: '',
      kind: WallItemKind.mount,
      label: 'Flat mount',
      width: 32,
      height: 16,
      depth: 1.5,
      plateHeight: 8,
      vesaW: 800,
      vesaH: 500,
      capacityLb: 150,
    ),
  ),
  WallItemPreset(
    'In the wall',
    'Power / data box, 2-gang',
    WallItem(
      id: '',
      kind: WallItemKind.outlet,
      label: 'Power / data',
      width: 4.5,
      height: 4.5,
      depth: 0.3,
      y: 18,
    ),
  ),
  WallItemPreset(
    'In the wall',
    'Recessed TV box',
    WallItem(
      id: '',
      kind: WallItemKind.recessedBox,
      label: 'Recessed box',
      width: 14,
      height: 7,
      depth: 0,
    ),
  ),
  WallItemPreset(
    'In the wall',
    'Light switch, 1-gang',
    WallItem(
      id: '',
      kind: WallItemKind.lightSwitch,
      label: 'Light switch',
      width: 2.75,
      height: 4.5,
      depth: 0.3,
      y: 42,
    ),
  ),
  WallItemPreset(
    'In the wall',
    'Thermostat',
    WallItem(
      id: '',
      kind: WallItemKind.thermostat,
      label: 'Thermostat',
      width: 4,
      height: 4,
      depth: 1,
      y: 44,
    ),
  ),
  WallItemPreset(
    'In the wall',
    'Fire alarm strobe',
    WallItem(
      id: '',
      kind: WallItemKind.fireAlarm,
      label: 'Fire alarm strobe',
      width: 5,
      height: 5.5,
      depth: 2.5,
      y: 80,
    ),
  ),
  WallItemPreset(
    'Openings',
    'Door, 3\' x 7\'',
    WallItem(
      id: '',
      kind: WallItemKind.door,
      label: 'Door',
      width: 36,
      height: 84,
      depth: 0,
    ),
  ),
  WallItemPreset(
    'Openings',
    'Window, 4\' x 4\'',
    WallItem(
      id: '',
      kind: WallItemKind.window,
      label: 'Window',
      width: 48,
      height: 48,
      depth: 0,
      y: 36,
    ),
  ),
  WallItemPreset(
    'AV',
    'Touch panel, 10"',
    WallItem(
      id: '',
      kind: WallItemKind.touchPanel,
      label: 'Touch panel',
      width: 10.2,
      height: 7,
      depth: 1.5,
      y: 40,
      touch: true,
    ),
  ),
  WallItemPreset(
    'AV',
    'Video bar',
    WallItem(
      id: '',
      kind: WallItemKind.videoBar,
      label: 'Video bar',
      width: 28.4,
      height: 3,
      depth: 3.2,
    ),
  ),
  WallItemPreset(
    'AV',
    'Wall speaker',
    WallItem(
      id: '',
      kind: WallItemKind.speaker,
      label: 'Speaker',
      width: 8,
      height: 12,
      depth: 8,
      y: 84,
    ),
  ),
  WallItemPreset(
    'AV',
    'Camera',
    WallItem(
      id: '',
      kind: WallItemKind.camera,
      label: 'Camera',
      width: 6.5,
      height: 7,
      depth: 6.5,
      y: 84,
    ),
  ),
  WallItemPreset(
    'Room',
    'Whiteboard, 8\' x 4\'',
    WallItem(
      id: '',
      kind: WallItemKind.whiteboard,
      label: 'Whiteboard',
      width: 96,
      height: 48,
      depth: 1,
      y: 30,
    ),
  ),
  WallItemPreset(
    'Room',
    'Credenza, 6\' x 30" x 24" deep',
    WallItem(
      id: '',
      kind: WallItemKind.credenza,
      label: 'Credenza',
      width: 72,
      height: 30,
      depth: 24,
    ),
  ),
  WallItemPreset(
    'Room',
    'Column / pipe',
    WallItem(
      id: '',
      kind: WallItemKind.obstruction,
      label: 'Column',
      width: 12,
      height: 96,
      depth: 12,
    ),
  ),
  WallItemPreset(
    'Room',
    'Cane rail',
    WallItem(
      id: '',
      kind: WallItemKind.caneRail,
      label: 'Cane rail',
      width: 72,
      height: 1.5,
      depth: 4,
      y: 25.5,
    ),
  ),
  for (final r in kRacewaySizes)
    WallItemPreset(
      'Raceway',
      r.name,
      WallItem(
        id: '',
        kind: WallItemKind.raceway,
        label: r.label,
        model: r.model,
        // A run up the wall to start; Turn lays it across.
        width: r.across,
        height: 48,
        depth: r.deep,
      ),
    ),
  WallItemPreset(
    'Room',
    'Something else',
    WallItem(id: '', kind: WallItemKind.other, label: 'Item'),
  ),
];

/// [preset] placed on [wall]: given an id, centered along the wall unless
/// it has a place, and a display at a usual 36" off the floor.
WallItem placePreset(WallView wall, WallItem preset, {double? atX}) {
  // A cane rail goes under what needs one, sized to it.
  if (preset.kind == WallItemKind.caneRail) {
    final target = railTarget(wall, atX: atX);
    if (target != null) return caneRailFor(target, id: wall.nextItemId());
  }
  var y = preset.y;
  if (y == 0 && !preset.kind.onFloor && !preset.kind.isOpening) {
    y = switch (preset.kind) {
      WallItemKind.display || WallItemKind.screen => 36,
      WallItemKind.recessedBox => 48,
      WallItemKind.videoBar => 84,
      _ => 48,
    };
  }
  final x = atX ?? (wall.widthIn - preset.width) / 2;
  return preset.copyWith(
    id: wall.nextItemId(),
    x: x.clamp(0, math.max(0, wall.widthIn - preset.width)).toDouble(),
    y: y,
  );
}

/// A display and its mount added together, the mount hung behind it.
WallView withDisplayOnMount(
  WallView wall,
  WallItem display,
  WallItem mount,
) {
  final d = placePreset(wall, display);
  final w1 = wall.withItem(d);
  final m = placePreset(w1, mount);
  return w1.withItem(m).withItem(d.copyWith(mountId: m.id));
}

// ---------------------------------------------------------------------------
//  FROM THE CATALOG
// ---------------------------------------------------------------------------

/// What a catalog product's [spec] makes on a wall, sized but not placed.
WallItem wallItemFromSpec(
  WallMountSpec spec, {
  required String model,
  String label = '',
  double weightLb = 0,
}) {
  final kind = switch (spec.role) {
    MountRole.display => WallItemKind.display,
    MountRole.mount => WallItemKind.mount,
    MountRole.other => WallItemKind.other,
  };
  final base = WallItem(id: '', kind: kind, label: label, model: model);
  return withSpecSizes(base, spec, weightLb: weightLb);
}

/// [spec] with a stand-in size where the catalog has none: a 65" display,
/// a low-profile mount, or a 12" square.
WallMountSpec withStandInSize(WallMountSpec spec) {
  final (w, h, d) = switch (spec.role) {
    MountRole.display => (57.3, 33.0, 3.0),
    MountRole.mount => (32.0, 16.0, 1.5),
    MountRole.other => (12.0, 12.0, 1.0),
  };
  return spec.copyWith(
    width: spec.width > 0 ? spec.width : w,
    height: spec.height > 0 ? spec.height : h,
    depth: spec.depth > 0 ? spec.depth : d,
  );
}

/// [item] with [spec]'s sizes, VESA and arms, where it is.
WallItem withSpecSizes(WallItem item, WallMountSpec spec, {double weightLb = 0}) {
  final vw = spec.vesaW * kInPerMm, vh = spec.vesaH * kInPerMm;
  final display = spec.role == MountRole.display;
  return item.copyWith(
    width: spec.width > 0 ? spec.width : item.width,
    height: spec.height > 0 ? spec.height : item.height,
    depth: spec.depth > 0 ? spec.depth : item.depth,
    vesaW: spec.vesaW,
    vesaH: spec.vesaH,
    vesaLeft: display && spec.holeLeft > 0 ? spec.holeLeft + vw / 2 : 0,
    vesaUp: display && spec.holeUp > 0 ? spec.holeUp + vh / 2 : 0,
    activeW: spec.activeW,
    activeH: spec.activeH,
    activeUp: spec.activeUp,
    touch: spec.touch,
    plateHeight: spec.plateHeight,
    armWidth: spec.armWidth,
    armSpanMin: spec.armSpanMin,
    armSpanMax: spec.armSpanMax,
    vesaMinW: spec.vesaMinW,
    vesaMinH: spec.vesaMinH,
    maxTiltDeg: spec.maxTilt,
    capacityLb: spec.capacityLb,
    weightLb: weightLb > 0 ? weightLb : item.weightLb,
  );
}

/// [item]'s sizes as a catalog product's wall mounting sizes: the reverse
/// of [withSpecSizes]. Where it hangs and how its hooks seat stay on the
/// wall; they are about one installation, not the product.
WallMountSpec specFromWallItem(WallItem item) {
  final display = item.kind == WallItemKind.display;
  final mount = item.kind == WallItemKind.mount;
  final vw = item.vesaWIn, vh = item.vesaHIn;
  return WallMountSpec(
    role: display
        ? MountRole.display
        : mount
            ? MountRole.mount
            : MountRole.other,
    width: item.width,
    height: item.height,
    depth: item.depth,
    vesaW: item.vesaW,
    vesaH: item.vesaH,
    vesaMinW: mount ? item.vesaMinW : 0,
    vesaMinH: mount ? item.vesaMinH : 0,
    holeLeft: display && item.vesaLeft > 0 && item.vesaW > 0
        ? math.max(0, item.vesaLeft - vw / 2)
        : 0,
    holeUp: display && item.vesaUp > 0 && item.vesaH > 0
        ? math.max(0, item.vesaUp - vh / 2)
        : 0,
    activeW: display ? item.activeW : 0,
    activeH: display ? item.activeH : 0,
    activeUp: display ? item.activeUp : 0,
    touch: display && item.touch,
    plateHeight: mount ? item.plateHeight : 0,
    armWidth: mount ? item.armWidth : 0,
    armSpanMin: mount ? item.armSpanMin : 0,
    armSpanMax: mount ? item.armSpanMax : 0,
    maxTilt: mount ? item.maxTiltDeg : 0,
    capacityLb: mount ? item.capacityLb : 0,
  );
}

/// True when [item]'s sizes are not what [spec] says.
bool differsFromSpec(WallItem item, WallMountSpec spec, {double weightLb = 0}) {
  final want = withSpecSizes(item, spec, weightLb: weightLb);
  final a = item.toJson(), b = want.toJson();
  bool same(Object? x, Object? y) =>
      x is num && y is num ? (x - y).abs() < 0.005 : x == y;
  for (final k in {...a.keys, ...b.keys}) {
    if (!same(a[k], b[k])) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
//  HANGING A DISPLAY ON A MOUNT
// ---------------------------------------------------------------------------

/// [wall] with [mountId] holding [displayId]; '' lets go of what it holds.
WallView hangMount(WallView wall, String mountId, String displayId) => wall
    .copyWith(
      items: [
        for (final i in wall.items)
          if (i.id == displayId)
            i.copyWith(mountId: mountId)
          else if (i.kind == WallItemKind.display && i.mountId == mountId)
            i.copyWith(mountId: '', standoff: 0)
          else
            i,
      ],
    )
    .resolved();

/// [movedId] just dropped: a free mount onto a display with none, or a
/// display with none onto a free mount, hangs one on the other. Null when
/// it landed on neither.
({WallView wall, String label})? hangOnDrop(WallView wall, String movedId) {
  final moved = wall.item(movedId);
  if (moved == null) return null;
  bool freeMount(WallItem m) =>
      m.kind == WallItemKind.mount && wall.displayOn(m.id) == null;
  bool freeDisplay(WallItem d) =>
      d.kind == WallItemKind.display &&
      (d.mountId.isEmpty || wall.item(d.mountId) == null);
  Offset mid(WallItem i) => Offset(i.centerX, i.centerY);
  if (freeMount(moved)) {
    final d = wall.items
        .where((d) => freeDisplay(d) && d.face.contains(mid(moved)))
        .firstOrNull;
    if (d != null) {
      return (
        wall: hangMount(wall, moved.id, d.id),
        label: 'Hang ${d.name} on ${moved.name}',
      );
    }
  }
  if (freeDisplay(moved)) {
    final m = wall.items
        .where((m) => freeMount(m) && moved.face.contains(mid(m)))
        .firstOrNull;
    if (m != null) {
      return (
        wall: hangMount(wall, m.id, moved.id),
        label: 'Hang ${moved.name} on ${m.name}',
      );
    }
  }
  return null;
}
