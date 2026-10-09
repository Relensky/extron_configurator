import 'dart:math' as math;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:material_ui/material_ui.dart';

import 'av_flow_model.dart';
import 'cabling_schematic.dart';
import 'cost_estimate.dart';
import 'projection_calc.dart';

/// ============================================================================
///  ROOM DEVICES ON THE DRAWINGS
/// ============================================================================
///  The equipment on the room's estimate, offered for placing on the floor
///  plan and the cabling drawing. Each name is offered once, A to Z, and can
///  be placed as many times as the estimate buys it and no more.
/// ============================================================================

/// One entry in the add-device menu.
class RoomDeviceChoice {
  /// What a placed device is filed under: [nodeDeviceKey] for one unit on
  /// the AV Flow, else [name] lowercased and trimmed.
  final String key;
  final String name;

  /// How many the estimate buys, across every line with this name.
  final int qty;

  /// Which of [kCablingDeviceShapes] it draws as.
  final String shape;

  const RoomDeviceChoice({
    required this.key,
    required this.name,
    required this.qty,
    required this.shape,
  });
}

/// The key a device name is filed under.
String roomDeviceKey(String name) => name.trim().toLowerCase();

/// The key one unit on the AV Flow is filed under. It follows the unit
/// through renames and model swaps, where a name key would be left behind.
String nodeDeviceKey(String nodeId) => 'node:$nodeId';

/// The AV Flow unit behind [deviceKey], or null for a name key.
String? nodeIdOfDeviceKey(String deviceKey) =>
    deviceKey.startsWith('node:') ? deviceKey.substring(5) : null;

/// The estimate line's key -> the AV Flow units on it.
Map<String, List<AvNode>> nodesByCostLine(AvFlowModel model) => {
  for (final g in groupDevices(model)) g.key: g.nodes,
};

/// Ties placed devices to units on the AV Flow, and keeps their labels on
/// the unit's name. A device still filed under a name (placed before units
/// were tracked) takes the first unclaimed unit going by that name, or by
/// the estimate line it was named after. Returns null when nothing changed.
List<PlanDevice>? linkPlanDevices(
  List<PlanDevice> devices,
  List<AvNode> nodes,
) {
  final byId = {for (final n in nodes) n.id: n};
  final claimed = {
    for (final d in devices) ?nodeIdOfDeviceKey(d.deviceKey),
  };
  Map<String, List<AvNode>>? byName;
  var changed = false;
  final out = <PlanDevice>[];
  for (final d in devices) {
    final id = nodeIdOfDeviceKey(d.deviceKey);
    if (id != null) {
      final n = byId[id];
      if (n != null && n.label.trim().isNotEmpty && n.label != d.label) {
        out.add(d.copyWith(label: n.label));
        changed = true;
      } else {
        out.add(d);
      }
      continue;
    }
    byName ??= _unitsByName(nodes);
    final n = byName[d.deviceKey]
        ?.where((n) => !claimed.contains(n.id))
        .firstOrNull;
    if (n == null) {
      out.add(d);
      continue;
    }
    claimed.add(n.id);
    out.add(
      d.copyWith(
        deviceKey: nodeDeviceKey(n.id),
        label: n.label.trim().isEmpty ? d.label : n.label,
      ),
    );
    changed = true;
  }
  return changed ? out : null;
}

/// Name key -> units, under each unit's own name and under the estimate
/// line it shares with others of its model.
Map<String, List<AvNode>> _unitsByName(List<AvNode> nodes) {
  final out = <String, List<AvNode>>{};
  final lines = <String, List<AvNode>>{};
  for (final n in nodes) {
    if (n.excludeFromCost) continue;
    out.putIfAbsent(roomDeviceKey(n.label), () => []).add(n);
    final line = n.model.trim().isEmpty
        ? 'device:${n.id}'
        : 'model:${n.model.trim().toLowerCase()}';
    lines.putIfAbsent(line, () => []).add(n);
  }
  for (final units in lines.values) {
    final key = roomDeviceKey({for (final n in units) n.label}.join(', '));
    final list = out.putIfAbsent(key, () => []);
    for (final n in units) {
      if (!list.contains(n)) list.add(n);
    }
  }
  return out;
}

/// The estimate's equipment, one entry per name, sorted by name.
///
/// Lines sharing a name are merged and their quantities added, so two models
/// both called "Display" are one menu entry for both.
///
/// With [units] (from [nodesByCostLine]), each unit on the AV Flow is its
/// own entry under its own name, so it keeps its place through a rename.
/// Any the line buys beyond the drawn units are offered by name as before.
List<RoomDeviceChoice> roomDeviceChoices(
  Iterable<CostLine> equipment, {
  Map<String, List<AvNode>> units = const {},
}) {
  final names = <String, String>{};
  final qty = <String, double>{};
  final hints = <String, String>{};
  for (final line in equipment) {
    final name = line.description.trim();
    if (name.isEmpty || line.spare || line.qty <= 0) continue;
    var left = line.qty;
    for (final n in units[line.key] ?? const <AvNode>[]) {
      if (left <= 0) break;
      left--;
      final key = nodeDeviceKey(n.id);
      final label = n.label.trim().isEmpty ? name : n.label.trim();
      names[key] = label;
      qty[key] = 1;
      hints[key] = '$label ${line.model} ${line.category}';
    }
    if (left <= 0) continue;
    final key = roomDeviceKey(name);
    names.putIfAbsent(key, () => name);
    qty[key] = (qty[key] ?? 0) + left;
    hints[key] = '${hints[key] ?? ''} $name ${line.model} ${line.category}';
  }
  final out = [
    for (final key in names.keys)
      RoomDeviceChoice(
        key: key,
        name: names[key]!,
        qty: qty[key]!.ceil(),
        shape: guessDeviceShape(hints[key]!),
      ),
  ];
  out.sort((a, b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.name.compareTo(b.name);
  });
  return out;
}

/// The icon a device most likely is, from its name, model and category.
/// First match wins, so the specific words go before the general ones.
String guessDeviceShape(String text) {
  final t = ' ${text.toLowerCase()} ';
  bool any(List<String> words) => words.any(t.contains);
  if (any(['projector', 'projection lens'])) return 'projector';
  if (any(['screen'])) return 'screen';
  if (any(['camera', 'ptz', ' cam '])) return 'camera';
  if (any(['touch panel', 'touchpanel', 'tlp', 'tlc ', 'keypad'])) {
    return 'touchPanel';
  }
  if (any(['display', 'monitor', ' tv ', 'television', 'lcd', 'led wall'])) {
    return 'display';
  }
  if (any(['ceiling mic', 'ceiling array', 'tcc2', 'mxa9', 'mxa7'])) {
    return 'ceilingMic';
  }
  if (any(['mic', 'microphone'])) return 'tableMic';
  if (any(['speaker', 'loudspeaker', 'soundbar'])) return 'speaker';
  if (any(['amplifier', ' amp ', 'xpa', 'netpa'])) return 'amplifier';
  if (any(['dsp', 'tesira', 'q-sys core', 'dmp'])) return 'dsp';
  if (any(['network switch', 'poe switch', 'ethernet switch'])) {
    return 'networkSwitch';
  }
  if (any(['switcher', 'scaler', 'presenter', 'matrix', ' sw '])) {
    return 'switcher';
  }
  if (any(['transmitter', ' tx', 'wall plate', 'wallplate'])) {
    return 'transmitter';
  }
  if (any(['receiver', ' rx'])) return 'receiver';
  if (any(['patch panel'])) return 'patchPanel';
  if (any(['floor box'])) return 'floorBox';
  if (any(['laptop', 'byod'])) return 'laptop';
  if (any([' pc ', 'computer', 'nuc'])) return 'pc';
  if (any(['rack'])) return 'rack';
  if (any(['power', 'ups', 'ipcp', 'ipl'])) return 'power';
  if (any(['wireless', 'access point', 'airmedia', 'via '])) return 'wireless';
  return 'other';
}

/// True when [shape] has a direction worth turning on a drawing.
bool deviceShapeAims(String shape) =>
    shape == 'projector' || shape == 'camera' || shape == 'display';

/// True when [shape] can be turned and show a cone on the floor plan. A
/// projector screen faces the room here, though it does not turn on the
/// cabling drawing.
bool deviceShapeHasFov(String shape) =>
    deviceShapeAims(shape) || shape == 'screen';

/// Field of view a new device starts with, in degrees. A screen's is where
/// it looks half as bright, either side: a matte screen's 60 each way.
double defaultDeviceFov(String shape) => switch (shape) {
  'camera' => 70,
  'projector' => 30,
  'display' => 120,
  'screen' => 120,
  _ => 60,
};

/// What the cone is called in the editor and the key.
String deviceFovLabel(String shape) => switch (shape) {
  'projector' => 'Throw',
  'display' || 'screen' => 'Viewing angle',
  _ => 'Field of view',
};

/// The cone's color.
Color deviceFovColor(String shape) => switch (shape) {
  'camera' => const Color(0xFF43A047),
  'projector' => const Color(0xFFFFA000),
  'screen' => const Color(0xFF8E24AA),
  _ => const Color(0xFF1E88E5),
};

/// The shape a projector or screen pairs with; '' for anything else.
String partnerShape(String shape) => switch (shape) {
  'projector' => 'screen',
  'screen' => 'projector',
  _ => '',
};

/// The screen a projector throws at, or the projector that throws at a
/// screen. A pair somebody set wins - see [PlanDevice.pairedWith]; failing
/// that, the nearest of the other kind that nobody has paired. Null for
/// anything else, or when there is none.
PlanDevice? projectionPartner(List<PlanDevice> devices, PlanDevice device) {
  final want = partnerShape(device.shape);
  if (want.isEmpty) return null;
  bool live(PlanDevice d) => d.shape == want && d.id != device.id;
  // Set on this one, or on the other end.
  if (device.pairedWith.isNotEmpty) {
    final set = devices
        .where((d) => d.id == device.pairedWith && live(d))
        .firstOrNull;
    if (set != null) return set;
  }
  final claimed = devices
      .where((d) => d.pairedWith == device.id && live(d))
      .firstOrNull;
  if (claimed != null) return claimed;
  // Paired elsewhere: not this one's to take.
  bool taken(PlanDevice d) =>
      d.pairedWith.isNotEmpty &&
      d.pairedWith != device.id &&
      devices.any((o) => o.id == d.pairedWith);
  PlanDevice? best;
  var bestDist = double.infinity;
  for (final d in devices) {
    if (!live(d) || taken(d)) continue;
    final dist = (d.pos - device.pos).distanceSquared;
    if (dist < bestDist) {
      best = d;
      bestDist = dist;
    }
  }
  return best;
}

/// Width over height of a projection screen, as drawn and lit on the plan.
const double kPlanScreenAspect = 16 / 10;

/// How far out a screen [width] wide is watched from: six image heights.
/// In the units of [width], so it works on a sheet without a scale too.
double screenViewingReach(double width) =>
    farthestViewer(imageHeightFromWidth(width, kPlanScreenAspect))
        .clamp(20.0, 20000.0);

/// [devices] with [after] in place of the one it replaces, and the other
/// half of its projector and screen pair kept to the image between them.
/// A projector's throw angle or reach sizes its screen to the image it
/// lands; a screen made wider or narrower zooms its projector to fill it.
/// A screen that changes width is watched from six image heights.
List<PlanDevice> withProjectionLinked(
  List<PlanDevice> devices,
  PlanDevice after,
) {
  final at = devices.indexWhere((d) => d.id == after.id);
  if (at < 0) return devices;
  final before = devices[at];
  final next = List<PlanDevice>.from(devices)..[at] = after;
  final partner = projectionPartner(next, after);
  if (partner == null) return next;
  final p = next.indexWhere((d) => d.id == partner.id);
  if (after.shape == 'projector' &&
      (after.fov != before.fov || after.range != before.range)) {
    final width = imageWidthForBeam(after.range, after.fov)
        .clamp(4.0, 20000.0);
    next[p] = partner.copyWith(
      width: width,
      range: screenViewingReach(width),
    );
  } else if (after.shape == 'screen' && after.width != before.width) {
    next[at] = after.copyWith(range: screenViewingReach(after.width));
    next[p] = partner.copyWith(
      fov: beamAngleToFill(partner.range, after.width).clamp(5.0, 180.0),
    );
  }
  return next;
}

/// The usual color of the working-area bands the content needs and above.
const Color kPlanBandColor = Color(0xFF2E7D32);

/// Reach of a new cone, in plan pixels.
const double kDefaultDeviceRange = 260;

/// Width of a new projection screen, in plan pixels, until the sheet has a
/// scale.
const double kDefaultScreenWidth = 120;

/// Width of a new projection screen once the sheet has a scale, in feet.
const double kDefaultScreenWidthFt = 8;

/// Radius of the disc a device is drawn in on the floor plan.
const double kPlanDeviceRadius = 15;

/// One piece of gear placed on a floor plan sheet.
class PlanDevice {
  /// `DEV_<n>`, unique on its sheet.
  final String id;

  /// The [RoomDeviceChoice.key] it was placed from.
  final String deviceKey;

  /// Printed under the icon.
  final String label;

  /// Which of [kCablingDeviceShapes] it draws as.
  final String shape;

  /// Center, in the sheet's own coordinates.
  final Offset pos;

  /// Which way it faces, degrees clockwise from the top of the sheet.
  final double rotation;

  final bool showFov;

  /// Width of the cone, in degrees.
  final double fov;

  /// Reach of the cone, in plan pixels.
  final double range;

  /// For a projection screen or a display: how wide it is, in plan pixels.
  final double width;

  /// For a projection screen: its gain. 1.0 is matte white.
  final double gain;

  /// For a projector or screen: the id of the one it is paired with, for
  /// squaring up and brightness. '' pairs with the nearest.
  final String pairedWith;

  /// The cone's color as ARGB; 0 uses its shape's, see [deviceFovColor].
  final int coneColor;

  /// For a screen or display: a color of its own for each contrast band of
  /// its working area, as ARGB by the band's N in N:1 (7, 15, 50, 80).
  final Map<int, int> rangeColors;

  const PlanDevice({
    required this.id,
    required this.deviceKey,
    required this.label,
    required this.shape,
    required this.pos,
    this.rotation = 0,
    this.showFov = false,
    this.fov = 60,
    this.range = kDefaultDeviceRange,
    this.width = kDefaultScreenWidth,
    this.gain = 1.0,
    this.pairedWith = '',
    this.coneColor = 0,
    this.rangeColors = const {},
  });

  /// The color its cone, throw or viewing angle is drawn in.
  Color get fovColor =>
      coneColor != 0 ? Color(coneColor) : deviceFovColor(shape);

  /// True when it is drawn as a flat face as wide as [width].
  bool get hasFace => shape == 'screen' || shape == 'display';

  /// The way it faces, as a unit vector on screen.
  Offset get facing {
    final r = rotation * math.pi / 180;
    return Offset(math.sin(r), -math.cos(r));
  }

  PlanDevice copyWith({
    String? id,
    String? deviceKey,
    String? label,
    String? shape,
    Offset? pos,
    double? rotation,
    bool? showFov,
    double? fov,
    double? range,
    double? width,
    double? gain,
    String? pairedWith,
    int? coneColor,
    Map<int, int>? rangeColors,
  }) => PlanDevice(
    id: id ?? this.id,
    deviceKey: deviceKey ?? this.deviceKey,
    label: label ?? this.label,
    shape: shape ?? this.shape,
    pos: pos ?? this.pos,
    rotation: rotation ?? this.rotation,
    showFov: showFov ?? this.showFov,
    fov: fov ?? this.fov,
    range: range ?? this.range,
    width: width ?? this.width,
    gain: gain ?? this.gain,
    pairedWith: pairedWith ?? this.pairedWith,
    coneColor: coneColor ?? this.coneColor,
    rangeColors: rangeColors ?? this.rangeColors,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'device': deviceKey,
    'label': label,
    'shape': shape,
    'x': pos.dx,
    'y': pos.dy,
    if (rotation != 0) 'rotation': rotation,
    if (showFov) 'showFov': true,
    'fov': fov,
    'range': range,
    if (hasFace) 'width': width,
    if (shape == 'screen' && gain != 1.0) 'gain': gain,
    if (pairedWith.isNotEmpty) 'pair': pairedWith,
    if (coneColor != 0) 'coneColor': coneColor,
    if (rangeColors.isNotEmpty)
      'rangeColors': {
        for (final e in rangeColors.entries) '${e.key}': e.value,
      },
  };

  factory PlanDevice.fromJson(Map<String, dynamic> json) {
    final shape = json['shape']?.toString() ?? 'other';
    return PlanDevice(
      id: json['id']?.toString() ?? '',
      deviceKey: json['device']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      shape: shape,
      pos: Offset(
        (json['x'] as num?)?.toDouble() ?? 0,
        (json['y'] as num?)?.toDouble() ?? 0,
      ),
      rotation: normalizeDegrees((json['rotation'] as num?)?.toDouble() ?? 0),
      showFov: json['showFov'] == true,
      fov: ((json['fov'] as num?)?.toDouble() ?? defaultDeviceFov(shape))
          .clamp(5.0, 180.0),
      range: ((json['range'] as num?)?.toDouble() ?? kDefaultDeviceRange)
          .clamp(20.0, 20000.0),
      width: ((json['width'] as num?)?.toDouble() ?? kDefaultScreenWidth)
          .clamp(4.0, 20000.0),
      gain: ((json['gain'] as num?)?.toDouble() ?? 1.0).clamp(0.1, 5.0),
      pairedWith: json['pair']?.toString() ?? '',
      coneColor: (json['coneColor'] as num?)?.toInt() ?? 0,
      rangeColors: {
        if (json['rangeColors'] case final Map<String, dynamic> m)
          for (final e in m.entries)
            if (int.tryParse(e.key) case final k?)
              if (e.value case final num v) k: v.toInt(),
      },
    );
  }
}

/// [degrees] folded into 0 to 360.
double normalizeDegrees(double degrees) {
  final d = degrees % 360;
  return d < 0 ? d + 360 : d;
}

/// How many of [deviceKey] are already among [placedKeys].
int placedCount(Iterable<String> placedKeys, String deviceKey) =>
    placedKeys.where((k) => k == deviceKey).length;

/// Draws the field-of-view cones of a sheet's devices.
class PlanDeviceFovPainter extends CustomPainter {
  final List<PlanDevice> devices;

  /// The device being dragged and how far it has come, so its cone follows.
  final String dragId;
  final Offset drag;

  /// A projector and screen to draw the screen's center line and the angle
  /// between them for, usually the selected one and its partner.
  final String squareScreenId;
  final String squareProjectorId;

  /// False draws the screens but no cones, angles or rings, for an export
  /// without them.
  final bool showCones;

  /// Rated lumens of each projector by id, for the brightness rings.
  final Map<String, double> lumens;

  /// Shortest and longest throw ratio of each projector's lens by id, to
  /// flag an image the lens cannot zoom to.
  final Map<String, (double, double)> throwRanges;

  /// The sheet's scale; 0 leaves the rings unlabeled.
  final double pixelsPerFoot;

  /// Straight-on brightness of each screen and display by id, in nits.
  final Map<String, double> nits;

  /// Light landing on the screens, in foot-candles; 0 when not set, and no
  /// working area is drawn.
  final double roomLightFc;

  /// Contrast the content needs, as N:1.
  final double contrast;

  const PlanDeviceFovPainter({
    required this.devices,
    this.dragId = '',
    this.drag = Offset.zero,
    this.squareScreenId = '',
    this.squareProjectorId = '',
    this.showCones = true,
    this.lumens = const {},
    this.throwRanges = const {},
    this.pixelsPerFoot = 0,
    this.nits = const {},
    this.roomLightFc = 0,
    this.contrast = 15,
  });

  Offset _at(PlanDevice d) => d.pos + (d.id == dragId ? drag : Offset.zero);

  @override
  void paint(Canvas canvas, Size size) {
    if (showCones) _paintCones(canvas);
    for (final d in devices) {
      if (d.hasFace) _paintScreen(canvas, d);
    }
  }

  /// The two ends of a screen: clockwise of its facing, then counterclockwise.
  (Offset, Offset) _screenEnds(PlanDevice d) {
    final f = d.facing;
    final across = Offset(-f.dy, f.dx);
    final c = _at(d);
    return (c + across * (d.width / 2), c - across * (d.width / 2));
  }

  /// A screen or display from above: a bar as wide as it is, with a white
  /// face on the side it is viewed from.
  void _paintScreen(Canvas canvas, PlanDevice d) {
    final (a, b) = _screenEnds(d);
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = d.shape == 'screen'
            ? const Color(0xFF4A148C)
            : const Color(0xFF263238)
        ..strokeWidth = d.shape == 'screen' ? 5 : 7,
    );
    final face = d.facing * 2.5;
    canvas.drawLine(
      a + face,
      b + face,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..strokeWidth = 1.5,
    );
  }

  /// [v] turned [deg] degrees clockwise on screen.
  static Offset _turn(Offset v, double deg) {
    final r = deg * math.pi / 180;
    final c = math.cos(r);
    final s = math.sin(r);
    return Offset(v.dx * c - v.dy * s, v.dx * s + v.dy * c);
  }

  /// A screen's viewing area, flaring out from both edges at [angle] either
  /// side of square, [reach] out.
  Path _flare(PlanDevice d, double angle, double reach) {
    final (a, b) = _screenEnds(d);
    final (oa, ob) = _flareDirs(d, angle);
    return Path()
      ..moveTo(a.dx, a.dy)
      ..lineTo(a.dx + oa.dx * reach, a.dy + oa.dy * reach)
      ..lineTo(b.dx + ob.dx * reach, b.dy + ob.dy * reach)
      ..lineTo(b.dx, b.dy)
      ..close();
  }

  /// Which way each end flares, away from the other: the first end sits
  /// clockwise of the facing, so it turns clockwise.
  (Offset, Offset) _flareDirs(PlanDevice d, double angle) =>
      (_turn(d.facing, angle), _turn(d.facing, -angle));

  void _paintCones(Canvas canvas) {
    for (final d in devices) {
      if (!d.showFov || !deviceShapeHasFov(d.shape)) continue;
      if (d.hasFace) {
        _paintScreenView(canvas, d);
        continue;
      }
      final center = _at(d);
      final color = d.fovColor;
      // Rotation 0 is up the sheet; canvas angle 0 is to the right.
      final mid = (d.rotation - 90) * math.pi / 180;
      final half = d.fov / 2 * math.pi / 180;
      final rect = Rect.fromCircle(center: center, radius: d.range);
      final wedge = Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(rect, mid - half, half * 2, false)
        ..close();
      if (d.shape == 'projector') {
        _paintThrow(canvas, d, center, mid, half, color);
      } else {
        canvas.drawPath(wedge, Paint()..color = color.withValues(alpha: 0.18));
      }
      canvas.drawPath(
        wedge,
        Paint()
          ..color = color.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    _paintSquare(canvas);
  }

  /// A screen's viewing area, flaring from its edges out to where it looks
  /// half as bright. Nested bands make it brighter toward square on.
  void _paintScreenView(Canvas canvas, PlanDevice d) {
    final color = d.fovColor;
    final halfGain = d.fov / 2;
    if (_paintWorking(canvas, d, halfGain)) return;
    for (final k in const [1.0, 0.8, 0.6, 0.4, 0.2]) {
      canvas.drawPath(
        _flare(d, halfGain * k, d.range),
        Paint()..color = color.withValues(alpha: 0.07),
      );
    }
    canvas.drawPath(
      _flare(d, halfGain, d.range),
      Paint()
        ..color = color.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final (a, _) = _screenEnds(d);
    final (oa, _) = _flareDirs(d, halfGain);
    _label(canvas, '50% at ±${halfGain.round()}°', a + oa * d.range, color);
  }

  /// Where the image holds the contrast its content needs against the room
  /// light: out to the angle where it is still bright enough, and as far
  /// back as its reach. Each AVIXA category the image reaches is a band,
  /// narrower for the higher ones, so more room light shrinks the area a
  /// step at a time. A band is drawn in its own color where one is set
  /// ([PlanDevice.rangeColors]); otherwise the content's own and above are
  /// in the device's color (green until one is picked) and the ones under
  /// it amber. False when there is not enough to go on (no room light set,
  /// or no brightness), so the plain viewing angle is drawn instead.
  bool _paintWorking(Canvas canvas, PlanDevice d, double halfGain) {
    final peak = nits[d.id] ?? 0;
    if (roomLightFc <= 0 || peak <= 0) return false;
    final reflect = d.shape == 'screen'
        ? screenReflectance(d.gain)
        : kDisplayReflectance;
    final ambient = ambientNits(roomLightFc, reflect);
    double angleFor(double c) =>
        workingAngle(peak, neededNits(c, ambient), halfGain);
    final angle = angleFor(contrast);
    final (a, b) = _screenEnds(d);
    final mid = Offset.lerp(a, b, 0.5)!;
    // The reach set on the device; six image heights is where it starts.
    final reach = d.range;
    final ok = d.coneColor != 0 ? d.fovColor : kPlanBandColor;
    const under = Color(0xFFEF6C00);
    Color colorOf(double c) {
      final own = d.rangeColors[c.round()];
      if (own != null) return Color(own);
      return c >= contrast ? ok : under;
    }

    // Widest first, so the narrower, higher bands stack darker on top.
    final steps = {
      for (final (c, _) in kContrastTargets) c: angleFor(c),
      contrast: angle,
    }.entries.where((e) => e.value > 0).toList()
      ..sort((x, y) => x.key.compareTo(y.key));
    for (final e in steps) {
      final band = _flare(d, e.value, reach);
      final ink = colorOf(e.key);
      canvas.drawPath(band, Paint()..color = ink.withValues(alpha: 0.08));
      canvas.drawPath(
        band,
        Paint()
          ..color = ink.withValues(alpha: e.key == contrast ? 0.9 : 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = e.key == contrast ? 1.8 : 1,
      );
    }
    final straightOn = contrastInRoom(peak, ambient);
    final seen = straightOn.isFinite
        ? '${straightOn.toStringAsFixed(straightOn < 10 ? 1 : 0)}:1'
        : '';
    final contrastLabel = '${contrast.round()}:1';
    final feet = pixelsPerFoot > 0
        ? ' · ${(reach / pixelsPerFoot).round()} ft'
        : '';
    if (angle > 0) {
      final (_, ob) = _flareDirs(d, angle);
      _label(
        canvas,
        '$contrastLabel to ±${angle.round()}°$feet · '
        '${peak.round()} nits · $seen straight on',
        b + ob * reach,
        colorOf(contrast),
      );
      return true;
    }
    // Short of the content's own: say by how much, and what it does reach.
    _label(
      canvas,
      'Too dim for $contrastLabel: $seen straight on '
      '(${peak.round()} of ${neededNits(contrast, ambient).round()} nits)',
      mid + d.facing * 24,
      const Color(0xFFC62828),
    );
    final best = steps.lastOrNull;
    if (best != null) {
      final (_, ob) = _flareDirs(d, best.value);
      _label(
        canvas,
        '${best.key.round()}:1 to ±${best.value.round()}°$feet',
        b + ob * reach,
        colorOf(best.key),
      );
    }
    return true;
  }

  /// A projector's throw, brighter near the lens. With a scale, rings mark
  /// the distance, and with the projector's lumens how bright an image would
  /// be on a screen that far away (gain 1.0, 16:10).
  void _paintThrow(
    Canvas canvas,
    PlanDevice d,
    Offset center,
    double mid,
    double half,
    Color color,
  ) {
    const steps = 4;
    for (var i = steps; i >= 1; i--) {
      final r = d.range * i / steps;
      final band = Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(
          Rect.fromCircle(center: center, radius: r),
          mid - half,
          half * 2,
          false,
        )
        ..close();
      canvas.drawPath(band, Paint()..color = color.withValues(alpha: 0.07));
    }
    _paintImage(canvas, d, center, mid, half, color);
    if (pixelsPerFoot <= 0) return;
    final lm = lumens[d.id] ?? 0;
    final ring = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    // The last ring is the image, labeled by [_paintImage].
    for (var i = 1; i < steps; i++) {
      final r = d.range * i / steps;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        mid - half,
        half * 2,
        false,
        ring,
      );
      final feet = r / pixelsPerFoot;
      final w = 2 * feet * math.tan(half);
      final at = center + Offset(math.cos(mid), math.sin(mid)) * r;
      final fl = footLamberts(lm, 1, w * w / 1.6);
      _label(
        canvas,
        lm > 0 && w > 0
            ? '${feet.round()} ft · ${fl.toStringAsFixed(1)} ft-L'
            : '${feet.round()} ft',
        at,
        color,
      );
    }
  }

  /// The image at the end of the throw: a bar as wide as the beam is there,
  /// with its width, throw ratio and brightness. Red when the ratio is past
  /// what the lens zooms to.
  void _paintImage(
    Canvas canvas,
    PlanDevice d,
    Offset center,
    double mid,
    double half,
    Color color,
  ) {
    Offset at(double a) => center + Offset(math.cos(a), math.sin(a)) * d.range;
    final a = at(mid - half);
    final b = at(mid + half);
    final ratio = throwRatioForBeam(d.fov);
    final lens = throwRanges[d.id];
    final past = lens != null &&
        (ratio < lens.$1 * 0.995 || ratio > lens.$2 * 1.005);
    final ink = past ? const Color(0xFFC62828) : color;
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = ink
        ..strokeWidth = 3,
    );
    final parts = <String>[];
    if (pixelsPerFoot > 0) {
      final w = (b - a).distance / pixelsPerFoot;
      final diag = imageFromWidth(
        w,
        const ScreenAspect('16:10', 16, 10),
      ).diagonal;
      parts.add('Image ${formatFeetInches(w)} · ${(diag * 12).round()}" diag');
    }
    parts.add('${ratio.toStringAsFixed(2)}:1');
    final lm = lumens[d.id] ?? 0;
    if (pixelsPerFoot > 0 && lm > 0) {
      final w = (b - a).distance / pixelsPerFoot;
      final fl = footLamberts(lm, 1, w * w / kPlanScreenAspect);
      parts.add('${fl.toStringAsFixed(1)} ft-L');
    }
    if (past) {
      parts.add(
        'lens ${lens.$1.toStringAsFixed(2)}-${lens.$2.toStringAsFixed(2)}',
      );
    }
    final out = Offset(math.cos(mid), math.sin(mid)) * 14;
    _label(canvas, parts.join(' · '), Offset.lerp(a, b, 0.5)! + out, ink);
  }

  void _label(Canvas canvas, String text, Offset at, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Color.lerp(color, const Color(0xFF000000), 0.45),
          backgroundColor: const Color(0xCCFFFFFF),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at - Offset(painter.width / 2, painter.height / 2));
  }

  /// The screen's center line out to the projector, the line to the
  /// projector and the angle between them.
  void _paintSquare(Canvas canvas) {
    final screen = devices.where((d) => d.id == squareScreenId).firstOrNull;
    final projector = devices
        .where((d) => d.id == squareProjectorId)
        .firstOrNull;
    if (!showCones || screen == null || projector == null) return;
    final s = _at(screen);
    final p = _at(projector);
    final dist = (p - s).distance;
    if (dist < 1) return;
    final ink = Paint()
      ..color = const Color(0xFF8E24AA)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    // Dashed center line, square to the screen.
    final end = pointOnCenterLine(s, screen.rotation, dist);
    final dir = (end - s) / dist;
    for (var t = 0.0; t < dist; t += 12) {
      canvas.drawLine(s + dir * t, s + dir * math.min(t + 7, dist), ink);
    }
    // A small square at the screen marks the right angle.
    final across = Offset(-dir.dy, dir.dx);
    const k = 9.0;
    canvas.drawPath(
      Path()
        ..moveTo(s.dx + across.dx * k, s.dy + across.dy * k)
        ..lineTo(
          s.dx + (across.dx + dir.dx) * k,
          s.dy + (across.dy + dir.dy) * k,
        )
        ..lineTo(s.dx + dir.dx * k, s.dy + dir.dy * k),
      ink,
    );
    final off = offAxisAngle(s, screen.rotation, p);
    canvas.drawLine(
      s,
      p,
      Paint()
        ..color = const Color(0xFFFFA000)
        ..strokeWidth = 1.5,
    );
    final toward = (p - s) / dist;
    if (off >= 0.5) {
      final r = math.min(40.0, dist / 2);
      final a0 = (screen.rotation - 90) * math.pi / 180;
      final a1 = (rotationToward(s, p) - 90) * math.pi / 180;
      var sweep = a1 - a0;
      while (sweep > math.pi) {
        sweep -= 2 * math.pi;
      }
      while (sweep < -math.pi) {
        sweep += 2 * math.pi;
      }
      canvas.drawArc(
        Rect.fromCircle(center: s, radius: r),
        a0,
        sweep,
        false,
        ink,
      );
    }
    final label = TextPainter(
      text: TextSpan(
        text: '${off.toStringAsFixed(off < 10 ? 1 : 0)}°',
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Color(0xFF6A1B9A),
          backgroundColor: Color(0xCCFFFFFF),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final at = s + (dir + toward) * 26;
    label.paint(canvas, at - Offset(label.width / 2, label.height / 2));
  }

  @override
  bool shouldRepaint(PlanDeviceFovPainter old) =>
      old.devices != devices ||
      old.dragId != dragId ||
      old.drag != drag ||
      old.squareScreenId != squareScreenId ||
      old.squareProjectorId != squareProjectorId ||
      old.showCones != showCones ||
      old.pixelsPerFoot != pixelsPerFoot ||
      old.roomLightFc != roomLightFc ||
      old.contrast != contrast ||
      !mapEquals(old.lumens, lumens) ||
      !mapEquals(old.throwRanges, throwRanges) ||
      !mapEquals(old.nits, nits);
}

/// The add-device menu: every device on the estimate, A to Z, each once,
/// with how many are placed out of how many are bought. A device that is
/// all placed is shown but cannot be picked.
List<PopupMenuEntry<RoomDeviceChoice>> roomDeviceMenuItems(
  BuildContext context,
  List<RoomDeviceChoice> choices,
  Iterable<String> placedKeys,
) {
  final theme = Theme.of(context);
  if (choices.isEmpty) {
    return [
      const PopupMenuItem(
        enabled: false,
        child: Text('No equipment on the estimate yet'),
      ),
    ];
  }
  final placed = placedKeys.toList();
  final items = <PopupMenuEntry<RoomDeviceChoice>>[];
  for (final c in choices) {
    final used = placedCount(placed, c.key);
    final full = used >= c.qty;
    items.add(
      PopupMenuItem<RoomDeviceChoice>(
        key: ValueKey('add_device_${c.key}'),
        value: c,
        enabled: !full,
        child: Row(
          children: [
            Icon(cablingDeviceIcon(c.shape), size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(c.name, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 12),
            Text(
              '$used / ${c.qty}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: full ? theme.disabledColor : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
  return items;
}
