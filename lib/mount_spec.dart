import 'dart:convert';

/// ============================================================================
///  WALL MOUNTING SIZES ON A CATALOG PRODUCT
/// ============================================================================
///  What the Walls tab needs to draw a product to scale: its size, and for a
///  display its VESA pattern and where the holes are on its back; for a wall
///  mount its plate, its arms and what it takes. Lengths are inches, VESA in
///  mm, as the makers' drawings give them. Pure data.
/// ============================================================================

/// What a product is on a wall.
enum MountRole {
  other('Something on the wall'),
  display('Display'),
  mount('Wall mount');

  final String label;
  const MountRole(this.label);

  static MountRole fromName(String? name) =>
      values.where((r) => r.name == name).firstOrNull ?? other;
}

class WallMountSpec {
  final MountRole role;

  /// Front-view size and depth. For a mount: plate width, arm length, and
  /// how far it holds a display off the wall.
  final double width, height, depth;

  /// A display's VESA pattern; for a mount, the largest it takes. mm.
  final double vesaW, vesaH;

  /// For a mount: the smallest pattern it takes, mm; 0 is any.
  final double vesaMinW, vesaMinH;

  /// For a display: the left holes in from its left edge and the low holes
  /// up from its bottom; 0 is centered.
  final double holeLeft, holeUp;

  /// For a display: the picture, and its bottom above the frame's bottom.
  final double activeW, activeH, activeUp;
  final bool touch;

  /// For a mount: the plate's height on the wall, each arm's width, and how
  /// far apart the arms go, center to center; 0 is not recorded.
  final double plateHeight, armWidth, armSpanMin, armSpanMax;

  /// For a mount: tilt either way, degrees, and the load it holds, lb.
  final double maxTilt, capacityLb;

  const WallMountSpec({
    this.role = MountRole.other,
    this.width = 0,
    this.height = 0,
    this.depth = 0,
    this.vesaW = 0,
    this.vesaH = 0,
    this.vesaMinW = 0,
    this.vesaMinH = 0,
    this.holeLeft = 0,
    this.holeUp = 0,
    this.activeW = 0,
    this.activeH = 0,
    this.activeUp = 0,
    this.touch = false,
    this.plateHeight = 0,
    this.armWidth = 0,
    this.armSpanMin = 0,
    this.armSpanMax = 0,
    this.maxTilt = 0,
    this.capacityLb = 0,
  });

  /// Has a size to draw.
  bool get hasSize => width > 0 && height > 0;

  WallMountSpec copyWith({
    MountRole? role,
    double? width,
    double? height,
    double? depth,
    double? vesaW,
    double? vesaH,
    double? vesaMinW,
    double? vesaMinH,
    double? holeLeft,
    double? holeUp,
    double? activeW,
    double? activeH,
    double? activeUp,
    bool? touch,
    double? plateHeight,
    double? armWidth,
    double? armSpanMin,
    double? armSpanMax,
    double? maxTilt,
    double? capacityLb,
  }) => WallMountSpec(
    role: role ?? this.role,
    width: width ?? this.width,
    height: height ?? this.height,
    depth: depth ?? this.depth,
    vesaW: vesaW ?? this.vesaW,
    vesaH: vesaH ?? this.vesaH,
    vesaMinW: vesaMinW ?? this.vesaMinW,
    vesaMinH: vesaMinH ?? this.vesaMinH,
    holeLeft: holeLeft ?? this.holeLeft,
    holeUp: holeUp ?? this.holeUp,
    activeW: activeW ?? this.activeW,
    activeH: activeH ?? this.activeH,
    activeUp: activeUp ?? this.activeUp,
    touch: touch ?? this.touch,
    plateHeight: plateHeight ?? this.plateHeight,
    armWidth: armWidth ?? this.armWidth,
    armSpanMin: armSpanMin ?? this.armSpanMin,
    armSpanMax: armSpanMax ?? this.armSpanMax,
    maxTilt: maxTilt ?? this.maxTilt,
    capacityLb: capacityLb ?? this.capacityLb,
  );

  Map<String, dynamic> toJson() => {
    'role': role.name,
    if (width > 0) 'w': width,
    if (height > 0) 'h': height,
    if (depth > 0) 'd': depth,
    if (vesaW > 0) 'vesaW': vesaW,
    if (vesaH > 0) 'vesaH': vesaH,
    if (vesaMinW > 0) 'vesaMinW': vesaMinW,
    if (vesaMinH > 0) 'vesaMinH': vesaMinH,
    if (holeLeft > 0) 'holeLeft': holeLeft,
    if (holeUp > 0) 'holeUp': holeUp,
    if (activeW > 0) 'activeW': activeW,
    if (activeH > 0) 'activeH': activeH,
    if (activeUp > 0) 'activeUp': activeUp,
    if (touch) 'touch': true,
    if (plateHeight > 0) 'plateH': plateHeight,
    if (armWidth > 0) 'armW': armWidth,
    if (armSpanMin > 0) 'armSpanMin': armSpanMin,
    if (armSpanMax > 0) 'armSpanMax': armSpanMax,
    if (maxTilt > 0) 'maxTilt': maxTilt,
    if (capacityLb > 0) 'capacityLb': capacityLb,
  };

  /// Null when [json] is not a map.
  static WallMountSpec? fromJson(Object? json) {
    if (json is! Map) return null;
    double read(String k) {
      final raw = json[k];
      final v = raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}');
      return v == null || !v.isFinite || v < 0 ? 0 : v;
    }

    return WallMountSpec(
      role: MountRole.fromName(json['role']?.toString()),
      width: read('w'),
      height: read('h'),
      depth: read('d'),
      vesaW: read('vesaW'),
      vesaH: read('vesaH'),
      vesaMinW: read('vesaMinW'),
      vesaMinH: read('vesaMinH'),
      holeLeft: read('holeLeft'),
      holeUp: read('holeUp'),
      activeW: read('activeW'),
      activeH: read('activeH'),
      activeUp: read('activeUp'),
      touch: json['touch'] == true,
      plateHeight: read('plateH'),
      armWidth: read('armW'),
      armSpanMin: read('armSpanMin'),
      armSpanMax: read('armSpanMax'),
      maxTilt: read('maxTilt'),
      capacityLb: read('capacityLb'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WallMountSpec &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;

  /// One line, for a merge's list of differences.
  String get summary {
    String n(double v) =>
        v.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
    return [
      role.label,
      if (hasSize) '${n(width)} x ${n(height)}"',
      if (depth > 0) '${n(depth)}" deep',
      if (vesaW > 0) 'VESA ${n(vesaW)} x ${n(vesaH)}',
      if (holeLeft > 0 || holeUp > 0)
        'holes ${n(holeLeft)}" in, ${n(holeUp)}" up',
      if (armSpanMax > 0) 'arms to ${n(armSpanMax)}" apart',
      if (capacityLb > 0) '${n(capacityLb)} lb',
    ].join(', ');
  }
}

// ---------------------------------------------------------------------------
//  FROM THE MAKERS' DRAWINGS
// ---------------------------------------------------------------------------
//  Built into the catalog, and filled in on a catalog entry of the same model
//  that has no wall mounting sizes of its own.

/// Newline Q Pro 86" (TT-8624QPRO): holes 14.3" up and 23.25" in from the
/// left. The active area's height off the frame bottom is read off the drawing.
const WallMountSpec kSpecNewlineQPro86 = WallMountSpec(
  role: MountRole.display,
  width: 78.03,
  height: 46.88,
  depth: 4.7,
  vesaW: 800,
  vesaH: 400,
  holeLeft: 23.25,
  holeUp: 14.3,
  activeW: 74.73,
  activeH: 42.04,
  activeUp: 3.4,
  touch: true,
);

/// Newline tilt mount EPR8A50600-000: 34.6" wide, arms 16.9" on a 7.9" plate,
/// 2.9" off the wall, 10 degrees, VESA to 800 x 400, 250 lb.
const WallMountSpec kSpecNewlineTiltMount = WallMountSpec(
  role: MountRole.mount,
  width: 34.6,
  height: 16.9,
  depth: 2.9,
  vesaW: 800,
  vesaH: 400,
  plateHeight: 7.9,
  armWidth: 1.1,
  armSpanMax: 33.5,
  maxTilt: 10,
  capacityLb: 250,
);

/// Chief XSM1U Fusion fixed mount (TECH-000618): rails 42.75" wide on wall
/// brackets 17" tall, 2.25" off the wall; uprights 26.25" long, 1.83" wide,
/// holes over 600 mm. Uprights spread to 38.7" (982 mm), 42.1" (1070 mm)
/// reversed.
const WallMountSpec kSpecChiefXSM1U = WallMountSpec(
  role: MountRole.mount,
  width: 42.75,
  height: 26.25,
  depth: 2.25,
  vesaW: 1070,
  vesaH: 600,
  plateHeight: 17,
  armWidth: 1.83,
  armSpanMax: 42.1,
);

/// Chief XTM1U Fusion tilt mount (TECH-000619): rails 42.75" wide on wall
/// brackets 17" tall, 2.5" off the wall; uprights 24.5" long, 2.05" wide,
/// holes over 600 mm; tilts 12 degrees. Uprights spread to 36.7" (932 mm),
/// 42.1" (1070 mm) reversed.
const WallMountSpec kSpecChiefXTM1U = WallMountSpec(
  role: MountRole.mount,
  width: 42.75,
  height: 24.5,
  depth: 2.5,
  vesaW: 1070,
  vesaH: 600,
  plateHeight: 17,
  armWidth: 2.05,
  armSpanMax: 42.1,
  maxTilt: 12,
);

/// Chief FCAV1U Fusion pullout (TECH-000708), one of its two assemblies:
/// 4.5" by 17.5" on the wall, 19.5" tall, 9.53" deep pulled out (1.56" in).
const WallMountSpec kSpecChiefFCAV1U = WallMountSpec(
  role: MountRole.mount,
  width: 4.5,
  height: 19.5,
  depth: 9.53,
  plateHeight: 17.5,
);

/// Ergotron 60-612 Neo-Flex tilting mount UHD: 32.5" wide on a 14.8" plate,
/// 2.7" off the wall (7" tilted); uprights 21" long, 1.8" wide, holes over
/// 19.8" (502 mm), spread to 28.3" (718 mm); tilts 15 degrees.
const WallMountSpec kSpecErgotron60612 = WallMountSpec(
  role: MountRole.mount,
  width: 32.5,
  height: 21,
  depth: 2.7,
  vesaW: 718,
  vesaH: 502,
  plateHeight: 14.8,
  armWidth: 1.8,
  armSpanMax: 28.3,
  maxTilt: 15,
);
