import 'package:flutter/material.dart';

/// ============================================================================
///  WHERE THINGS ARE IN THE ROOM
/// ============================================================================
///  The AV diagram says what is cabled to what. It does not say where anything
///  IS — and that is the question the installer, the electrician and the person
///  pulling cable actually ask. "Six network jacks" is not a number anybody can
///  order conduit against; "six network jacks in the floor box at the front of
///  the room" is.
///
///  So a room carries a short list of LOCATIONS — the instructor station, the
///  front floor box, the ceiling over the second row, the rack in the closet —
///  and every device, jack field and screen switch names one. Three things fall
///  out of that once, rather than being re-derived three times:
///
///    * the reports can count jacks and cable runs PER LOCATION, and group them
///      by whether the location is a ceiling, a wall, a floor or a rack;
///    * the signal-flow canvas can group boxes by where they physically are,
///      over a floor plan dropped in behind them;
///    * a floor plan can carry a numbered CALLOUT at each location that points
///      back at the sheet and row of the workbook describing it.
///
///  Pure data and geometry — no widgets, no provider — so the reports can be
///  checked without pumping a frame, exactly like [AvFlowModel].
/// ============================================================================

// ---------------------------------------------------------------------------
//  ZONES
// ---------------------------------------------------------------------------

/// The kind of place a location is.
///
/// This is deliberately about the MOUNTING SURFACE rather than the part of the
/// room, because that is what changes the work: a ceiling device needs a lift
/// and a plenum-rated run, a wall device needs a back box, a rack device needs
/// rails and none of them need any of the others. Grouping the jack and cable
/// counts this way is what the request asked for and what a rough-in drawing
/// is read for.
enum RoomZone {
  unspecified,
  ceiling,
  wall,
  floor,
  rack,
  lectern,
  table,
  credenza,
  equipmentRoom,

  /// A pull box: the junction cable is routed THROUGH rather than terminated
  /// in. It has no gear in it, which is why it never turned up as a location
  /// before — and it is exactly what a cabling drawing is built around, so it
  /// has to be a place the room knows about like any other.
  pullBox,
}

const Map<RoomZone, String> kRoomZoneLabels = {
  RoomZone.unspecified: 'Not recorded',
  RoomZone.ceiling: 'Ceiling',
  RoomZone.wall: 'Wall',
  RoomZone.floor: 'Floor / floor box',
  RoomZone.rack: 'Rack',
  RoomZone.lectern: 'Lectern / podium',
  RoomZone.table: 'Table / desk',
  RoomZone.credenza: 'Credenza / cabinet',
  RoomZone.equipmentRoom: 'Equipment room / IDF',
  RoomZone.pullBox: 'Pull box',
};

/// Short form for a report column that has to stay narrow.
const Map<RoomZone, String> kRoomZoneCodes = {
  RoomZone.unspecified: '-',
  RoomZone.ceiling: 'CLG',
  RoomZone.wall: 'WALL',
  RoomZone.floor: 'FLR',
  RoomZone.rack: 'RACK',
  RoomZone.lectern: 'LECT',
  RoomZone.table: 'TBL',
  RoomZone.credenza: 'CRED',
  RoomZone.equipmentRoom: 'IDF',
  RoomZone.pullBox: 'PULL',
};

const Map<RoomZone, IconData> kRoomZoneIcons = {
  RoomZone.unspecified: Icons.help_outline,
  RoomZone.ceiling: Icons.vertical_align_top,
  RoomZone.wall: Icons.crop_square,
  RoomZone.floor: Icons.vertical_align_bottom,
  RoomZone.rack: Icons.view_day,
  RoomZone.lectern: Icons.co_present,
  RoomZone.table: Icons.table_restaurant,
  RoomZone.credenza: Icons.inventory_2,
  RoomZone.equipmentRoom: Icons.meeting_room,
  RoomZone.pullBox: Icons.check_box_outline_blank,
};

RoomZone roomZoneFromName(String? name) {
  final key = name?.trim().toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  for (final z in RoomZone.values) {
    if (z.name.toLowerCase() == key) return z;
  }
  const aliases = {
    'ceiling': RoomZone.ceiling,
    'clg': RoomZone.ceiling,
    'wall': RoomZone.wall,
    'floorbox': RoomZone.floor,
    'floor': RoomZone.floor,
    'rack': RoomZone.rack,
    'podium': RoomZone.lectern,
    'lectern': RoomZone.lectern,
    'desk': RoomZone.table,
    'table': RoomZone.table,
    'cabinet': RoomZone.credenza,
    'credenza': RoomZone.credenza,
    'idf': RoomZone.equipmentRoom,
    'equipmentroom': RoomZone.equipmentRoom,
    'pullbox': RoomZone.pullBox,
    'pull': RoomZone.pullBox,
    'jbox': RoomZone.pullBox,
    'junctionbox': RoomZone.pullBox,
  };
  return aliases[key] ?? RoomZone.unspecified;
}

// ---------------------------------------------------------------------------
//  LOCATIONS
// ---------------------------------------------------------------------------

/// The id a device carries when nobody has said where it is. Stored as the
/// empty string rather than a sentinel location, so a room that never uses
/// locations writes nothing extra into its sidecar.
const String kNoLocationId = '';

/// One named place in the room.
///
/// [callout] is the tag drawn on the floor plan and printed in the reports —
/// "A", "B", "1", whatever the drawing set uses. It is separate from [name]
/// because a plan has room for two characters next to a marker and none for
/// "Instructor station floor box".
class RoomLocation {
  /// `LOC_<n>`, referenced by [AvNode.locationId] and by the callouts.
  final String id;
  final String name;
  final RoomZone zone;

  /// Short tag printed on the plan and in the report ('A', 'FB1').
  final String callout;

  /// Where the marker sits on the floor plan image, in the plan's own
  /// coordinate space. [Offset.zero] means "not placed on the plan yet",
  /// which is normal: locations are named long before a plan turns up.
  final Offset planPos;

  final String note;

  const RoomLocation({
    required this.id,
    required this.name,
    this.zone = RoomZone.unspecified,
    this.callout = '',
    this.planPos = Offset.zero,
    this.note = '',
  });

  /// True when this location has been dropped on the floor plan.
  bool get isPlaced => planPos != Offset.zero;

  /// What a report column shows: the callout tag in front of the name when
  /// there is one, so a row can be found on the drawing without a lookup.
  String get displayName =>
      callout.trim().isEmpty ? name : '[${callout.trim()}] $name';

  RoomLocation copyWith({
    String? name,
    RoomZone? zone,
    String? callout,
    Offset? planPos,
    String? note,
  }) => RoomLocation(
    id: id,
    name: name ?? this.name,
    zone: zone ?? this.zone,
    callout: callout ?? this.callout,
    planPos: planPos ?? this.planPos,
    note: note ?? this.note,
  );

  RoomLocation withId(String newId) => RoomLocation(
    id: newId,
    name: name,
    zone: zone,
    callout: callout,
    planPos: planPos,
    note: note,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (zone != RoomZone.unspecified) 'zone': zone.name,
    if (callout.isNotEmpty) 'callout': callout,
    if (isPlaced) 'planX': planPos.dx,
    if (isPlaced) 'planY': planPos.dy,
    if (note.isNotEmpty) 'note': note,
  };

  factory RoomLocation.fromJson(Map<String, dynamic> json) => RoomLocation(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    zone: roomZoneFromName(json['zone']?.toString()),
    callout: json['callout']?.toString() ?? '',
    planPos: Offset(
      (json['planX'] as num?)?.toDouble() ?? 0,
      (json['planY'] as num?)?.toDouble() ?? 0,
    ),
    note: json['note']?.toString() ?? '',
  );
}

/// The locations a new room starts with, and the ones the presets refer to by
/// name. Every one of them is a place gear actually lands in a teaching space,
/// and having them pre-named is the difference between a room where locations
/// get used and one where the field stays blank.
const List<({String name, RoomZone zone, String callout})>
kDefaultRoomLocations = [
  (name: 'Equipment rack', zone: RoomZone.rack, callout: 'A'),
  (name: 'Instructor station', zone: RoomZone.lectern, callout: 'B'),
  (name: 'Projector box', zone: RoomZone.ceiling, callout: 'C'),
  (name: 'Projector screen', zone: RoomZone.wall, callout: 'D'),
  (name: 'Ceiling mic', zone: RoomZone.ceiling, callout: 'E'),
];

// ---------------------------------------------------------------------------
//  SCREEN SWITCHES
// ---------------------------------------------------------------------------

/// A low-voltage control run between two places in the room.
///
/// The one everybody has is the projection screen switch: a three-position
/// switch on the wall by the door, and the screen motor above the whiteboard,
/// with a run of control cable between them. Neither end is a device on the
/// signal flow — the switch has no signal connectors and the motor is not
/// something the processor talks to — so before this there was nowhere to
/// record it, and it turned up as a surprise at rough-in.
///
/// What it is worth writing down is exactly the two ends and what runs between
/// them, which is what the report prints.
class ScreenSwitch {
  /// `SCRSW_<n>`.
  final String id;

  /// What it controls — 'Front screen', 'Rear shade'.
  final String label;

  /// Where the switch itself is. A location id when it names one of the room's
  /// locations, so it moves with a rename.
  final String startLocationId;

  /// Free text used when the start is somewhere with no location of its own.
  /// Ignored when [startLocationId] is set.
  final String startNote;

  /// Where the thing being controlled is (the screen motor, the shade tube).
  final String endLocationId;
  final String endNote;

  /// What runs between them — '18/2 plenum', 'Cat6', 'line voltage'.
  final String cableType;

  /// Estimated run length in feet; 0 means nobody has measured it.
  final double runFeet;

  final String note;

  const ScreenSwitch({
    required this.id,
    required this.label,
    this.startLocationId = kNoLocationId,
    this.startNote = '',
    this.endLocationId = kNoLocationId,
    this.endNote = '',
    this.cableType = '',
    this.runFeet = 0,
    this.note = '',
  });

  ScreenSwitch copyWith({
    String? label,
    String? startLocationId,
    String? startNote,
    String? endLocationId,
    String? endNote,
    String? cableType,
    double? runFeet,
    String? note,
  }) => ScreenSwitch(
    id: id,
    label: label ?? this.label,
    startLocationId: startLocationId ?? this.startLocationId,
    startNote: startNote ?? this.startNote,
    endLocationId: endLocationId ?? this.endLocationId,
    endNote: endNote ?? this.endNote,
    cableType: cableType ?? this.cableType,
    runFeet: runFeet ?? this.runFeet,
    note: note ?? this.note,
  );

  ScreenSwitch withId(String newId) => ScreenSwitch(
    id: newId,
    label: label,
    startLocationId: startLocationId,
    startNote: startNote,
    endLocationId: endLocationId,
    endNote: endNote,
    cableType: cableType,
    runFeet: runFeet,
    note: note,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    if (startLocationId.isNotEmpty) 'startLocation': startLocationId,
    if (startNote.isNotEmpty) 'startNote': startNote,
    if (endLocationId.isNotEmpty) 'endLocation': endLocationId,
    if (endNote.isNotEmpty) 'endNote': endNote,
    if (cableType.isNotEmpty) 'cableType': cableType,
    if (runFeet > 0) 'runFeet': runFeet,
    if (note.isNotEmpty) 'note': note,
  };

  factory ScreenSwitch.fromJson(Map<String, dynamic> json) => ScreenSwitch(
    id: json['id']?.toString() ?? '',
    label: json['label']?.toString() ?? 'Screen switch',
    startLocationId: json['startLocation']?.toString() ?? kNoLocationId,
    startNote: json['startNote']?.toString() ?? '',
    endLocationId: json['endLocation']?.toString() ?? kNoLocationId,
    endNote: json['endNote']?.toString() ?? '',
    cableType: json['cableType']?.toString() ?? '',
    runFeet: (json['runFeet'] as num?)?.toDouble() ?? 0,
    note: json['note']?.toString() ?? '',
  );
}

/// Cable types offered in the screen switch editor; free text underneath.
const List<String> kScreenSwitchCableTypes = [
  '18/2 plenum',
  '18/3 plenum',
  '16/2 plenum',
  'Cat6',
  'Cat6 plenum',
  'Line voltage (dedicated)',
  'Manufacturer control cable',
];

// ---------------------------------------------------------------------------
//  FLOOR PLANS
// ---------------------------------------------------------------------------

/// What a callout on the floor plan points at.
///
/// A drawing set is read by cross-reference: the plan says "see A", and A is a
/// rack elevation on another sheet. Naming the KIND of thing a callout points
/// at is what lets the app resolve the reference itself — the rack's name, the
/// device's label — instead of making somebody re-type it on the plan and keep
/// the two in step by hand.
enum CalloutTarget {
  /// A rack frame — the common one: "the rack shown at A is Rack 1".
  rack,

  /// A device on the signal flow.
  device,

  /// One of the room's locations.
  location,

  /// A sheet of the workbook with no single object behind it — the cable
  /// schedule, the jack schedule.
  sheet,

  /// A plain annotation with no target at all.
  note,
}

const Map<CalloutTarget, String> kCalloutTargetLabels = {
  CalloutTarget.rack: 'Rack',
  CalloutTarget.device: 'Device',
  CalloutTarget.location: 'Location',
  CalloutTarget.sheet: 'Workbook sheet',
  CalloutTarget.note: 'Note only',
};

CalloutTarget calloutTargetFromName(String? name) {
  switch (name?.trim().toLowerCase()) {
    case 'rack':
      return CalloutTarget.rack;
    case 'device':
      return CalloutTarget.device;
    case 'location':
      return CalloutTarget.location;
    case 'sheet':
      return CalloutTarget.sheet;
    default:
      return CalloutTarget.note;
  }
}

/// One numbered marker on the floor plan, and what it refers to.
///
/// [workbookSheet] and [workbookRef] are the cross-reference the request asked
/// for: which tab of the exported room workbook, and where on it, describes
/// what is at this spot on the plan. The sheet is a name rather than an index
/// so it survives a sheet being added to the book.
class FloorPlanCallout {
  /// `CALLOUT_<n>`.
  final String id;

  /// What is printed inside the marker — '1', 'A', 'R1'.
  final String tag;

  /// Where the marker sits, in the plan image's own coordinates.
  final Offset pos;

  final CalloutTarget target;

  /// Rack id / node id / location id, per [target]. Empty for sheet and note.
  final String targetId;

  /// Which tab of the room workbook this points into ('Racks', 'AV Flow').
  final String workbookSheet;

  /// Where on that sheet — a section title, a cable id, a cell reference.
  /// Free text on purpose: a drawing set's cross-references are whatever the
  /// office's convention says they are.
  final String workbookRef;

  final String note;

  const FloorPlanCallout({
    required this.id,
    required this.tag,
    required this.pos,
    this.target = CalloutTarget.note,
    this.targetId = '',
    this.workbookSheet = '',
    this.workbookRef = '',
    this.note = '',
  });

  FloorPlanCallout copyWith({
    String? tag,
    Offset? pos,
    CalloutTarget? target,
    String? targetId,
    String? workbookSheet,
    String? workbookRef,
    String? note,
  }) => FloorPlanCallout(
    id: id,
    tag: tag ?? this.tag,
    pos: pos ?? this.pos,
    target: target ?? this.target,
    targetId: targetId ?? this.targetId,
    workbookSheet: workbookSheet ?? this.workbookSheet,
    workbookRef: workbookRef ?? this.workbookRef,
    note: note ?? this.note,
  );

  FloorPlanCallout withId(String newId) => FloorPlanCallout(
    id: newId,
    tag: tag,
    pos: pos,
    target: target,
    targetId: targetId,
    workbookSheet: workbookSheet,
    workbookRef: workbookRef,
    note: note,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'tag': tag,
    'x': pos.dx,
    'y': pos.dy,
    if (target != CalloutTarget.note) 'target': target.name,
    if (targetId.isNotEmpty) 'targetId': targetId,
    if (workbookSheet.isNotEmpty) 'sheet': workbookSheet,
    if (workbookRef.isNotEmpty) 'ref': workbookRef,
    if (note.isNotEmpty) 'note': note,
  };

  factory FloorPlanCallout.fromJson(Map<String, dynamic> json) =>
      FloorPlanCallout(
        id: json['id']?.toString() ?? '',
        tag: json['tag']?.toString() ?? '',
        pos: Offset(
          (json['x'] as num?)?.toDouble() ?? 0,
          (json['y'] as num?)?.toDouble() ?? 0,
        ),
        target: calloutTargetFromName(json['target']?.toString()),
        targetId: json['targetId']?.toString() ?? '',
        workbookSheet: json['sheet']?.toString() ?? '',
        workbookRef: json['ref']?.toString() ?? '',
        note: json['note']?.toString() ?? '',
      );
}

// ---------------------------------------------------------------------------
//  PLAN NOTATION
// ---------------------------------------------------------------------------

/// What a piece of notation is.
///
/// A callout says "this spot is that thing"; notation says everything else a
/// drawing has to say and a marker cannot — which way the cable leaves the
/// room, which wall the conduit runs up, which corner is out of scope, "core
/// drill here". Without it that all ends up in an email that gets separated
/// from the plan.
enum PlanShape {
  /// Two points and a head. The one everybody actually wants.
  arrow,

  /// Two points, no head — a lead line from a note to what it means.
  line,

  /// Ringing an area: "this whole corner is by others".
  rectangle,
  ellipse,

  /// Free text with no shape round it.
  text,
}

const Map<PlanShape, String> kPlanShapeLabels = {
  PlanShape.arrow: 'Arrow',
  PlanShape.line: 'Line',
  PlanShape.rectangle: 'Box',
  PlanShape.ellipse: 'Ellipse',
  PlanShape.text: 'Text',
};

PlanShape planShapeFromName(String? name) => PlanShape.values.firstWhere(
  (s) => s.name == name?.trim(),
  orElse: () => PlanShape.arrow,
);

/// One drawn annotation on a sheet.
///
/// Everything is stored in the PLAN IMAGE'S coordinates, exactly as callouts
/// and location markers are, so notation stays where it was put when the page
/// is zoomed, when the window changes size, and when the same drawing is
/// re-imported at the same size after a revision.
///
/// [start] and [end] carry the whole geometry: for an arrow or a line they are
/// its two ends, and for a box, an ellipse or a text block they are opposite
/// corners. One pair of points rather than a shape-specific record because
/// every edit gesture — draw, move, drag either handle — is then the same code
/// for all five.
class PlanAnnotation {
  /// `NOTE_<n>`.
  final String id;
  final PlanShape shape;
  final Offset start;
  final Offset end;

  /// Printed with the shape: beside a line, inside a box, on its own for text.
  final String text;

  /// ARGB. Stored per annotation because a drawing marks scope in one colour
  /// and cable routes in another, and one palette for the sheet would make
  /// that impossible to say.
  final int color;

  /// Stroke width in plan pixels.
  final double strokeWidth;

  const PlanAnnotation({
    required this.id,
    this.shape = PlanShape.arrow,
    this.start = Offset.zero,
    this.end = Offset.zero,
    this.text = '',
    this.color = 0xFFE53935,
    this.strokeWidth = 3,
  });

  /// The box the shape occupies, however its two points are ordered.
  Rect get bounds => Rect.fromPoints(start, end);

  /// True when the two points are close enough together that the shape has no
  /// real extent — a click rather than a drag. Text is exempt: a text block
  /// placed with a single click is a legitimate thing to do, and it sizes
  /// itself to what gets typed.
  bool get isDegenerate =>
      shape != PlanShape.text && (start - end).distance < 4;

  PlanAnnotation copyWith({
    PlanShape? shape,
    Offset? start,
    Offset? end,
    String? text,
    int? color,
    double? strokeWidth,
  }) => PlanAnnotation(
    id: id,
    shape: shape ?? this.shape,
    start: start ?? this.start,
    end: end ?? this.end,
    text: text ?? this.text,
    color: color ?? this.color,
    strokeWidth: strokeWidth ?? this.strokeWidth,
  );

  PlanAnnotation withId(String newId) => PlanAnnotation(
    id: newId,
    shape: shape,
    start: start,
    end: end,
    text: text,
    color: color,
    strokeWidth: strokeWidth,
  );

  /// Moves the whole thing by [delta], keeping its shape.
  PlanAnnotation shifted(Offset delta) =>
      copyWith(start: start + delta, end: end + delta);

  Map<String, dynamic> toJson() => {
    'id': id,
    'shape': shape.name,
    'x1': start.dx,
    'y1': start.dy,
    'x2': end.dx,
    'y2': end.dy,
    if (text.isNotEmpty) 'text': text,
    'color': color,
    'stroke': strokeWidth,
  };

  factory PlanAnnotation.fromJson(Map<String, dynamic> json) => PlanAnnotation(
    id: json['id']?.toString() ?? '',
    shape: planShapeFromName(json['shape']?.toString()),
    start: Offset(
      (json['x1'] as num?)?.toDouble() ?? 0,
      (json['y1'] as num?)?.toDouble() ?? 0,
    ),
    end: Offset(
      (json['x2'] as num?)?.toDouble() ?? 0,
      (json['y2'] as num?)?.toDouble() ?? 0,
    ),
    text: json['text']?.toString() ?? '',
    color: (json['color'] as num?)?.toInt() ?? 0xFFE53935,
    strokeWidth: (json['stroke'] as num?)?.toDouble() ?? 3,
  );
}

/// The colours the notation toolbar offers. Not a full picker: a drawing set
/// reads better for having five colours used consistently than for having any
/// colour used once.
const List<int> kPlanAnnotationColors = [
  0xFFE53935, // red — the default, and what a markup is expected to be
  0xFF1E88E5, // blue
  0xFF43A047, // green
  0xFFF9A825, // amber
  0xFF6A1B9A, // purple
  0xFF212121, // near-black, for a note that is not an exception
];

/// A floor plan image the room's locations and callouts are placed on.
///
/// The image is referenced by FILE NAME, not embedded. A room folder is
/// already the unit that travels — config, sidecar, workbook, PNGs — so the
/// plan travels with it as one more file, and a 4 MB architectural export
/// stays out of a JSON sidecar that is otherwise hand-readable and diffable.
/// [imageFile] is resolved against the folder the config lives in.
class FloorPlan {
  /// `PLAN_<n>`.
  final String id;
  final String name;

  /// File name of the image, relative to the config's folder. An absolute
  /// path is honoured too, for a plan somebody wants to keep on a share.
  final String imageFile;

  /// Natural size of the image in pixels, recorded when it was imported so
  /// the page can lay out before the bytes have been decoded.
  final Size imageSize;

  /// How the plan is drawn behind the signal flow: 1 is opaque, and the
  /// default is faint enough that the diagram still reads over it.
  final double opacity;

  /// Plan pixels per foot, when somebody has calibrated it. 0 means uncalibrated
  /// — lengths are then left blank rather than being reported in pixels.
  final double pixelsPerFoot;

  final List<FloorPlanCallout> callouts;

  /// Arrows, boxes and text drawn on this sheet. Per sheet rather than per
  /// room: an arrow saying which way the conduit leaves is about THIS drawing,
  /// and would be nonsense on the reflected ceiling plan.
  final List<PlanAnnotation> annotations;

  const FloorPlan({
    required this.id,
    required this.name,
    this.imageFile = '',
    this.imageSize = const Size(1200, 900),
    this.opacity = 0.35,
    this.pixelsPerFoot = 0,
    this.callouts = const [],
    this.annotations = const [],
  });

  bool get hasImage => imageFile.trim().isNotEmpty;

  FloorPlan copyWith({
    String? name,
    String? imageFile,
    Size? imageSize,
    double? opacity,
    double? pixelsPerFoot,
    List<FloorPlanCallout>? callouts,
    List<PlanAnnotation>? annotations,
  }) => FloorPlan(
    id: id,
    name: name ?? this.name,
    imageFile: imageFile ?? this.imageFile,
    imageSize: imageSize ?? this.imageSize,
    opacity: opacity ?? this.opacity,
    pixelsPerFoot: pixelsPerFoot ?? this.pixelsPerFoot,
    callouts: callouts ?? this.callouts,
    annotations: annotations ?? this.annotations,
  );

  FloorPlan withId(String newId) => FloorPlan(
    id: newId,
    name: name,
    imageFile: imageFile,
    imageSize: imageSize,
    opacity: opacity,
    pixelsPerFoot: pixelsPerFoot,
    callouts: callouts,
    annotations: annotations,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (imageFile.isNotEmpty) 'image': imageFile,
    'width': imageSize.width,
    'height': imageSize.height,
    'opacity': opacity,
    if (pixelsPerFoot > 0) 'pixelsPerFoot': pixelsPerFoot,
    'callouts': [for (final c in callouts) c.toJson()],
    if (annotations.isNotEmpty)
      'annotations': [for (final a in annotations) a.toJson()],
  };

  factory FloorPlan.fromJson(Map<String, dynamic> json) => FloorPlan(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? 'Floor plan',
    imageFile: json['image']?.toString() ?? '',
    imageSize: Size(
      (json['width'] as num?)?.toDouble() ?? 1200,
      (json['height'] as num?)?.toDouble() ?? 900,
    ),
    opacity: ((json['opacity'] as num?)?.toDouble() ?? 0.35).clamp(0.05, 1.0),
    pixelsPerFoot: (json['pixelsPerFoot'] as num?)?.toDouble() ?? 0,
    callouts: [
      for (final c in (json['callouts'] as List? ?? []))
        if (c is Map) FloorPlanCallout.fromJson(Map<String, dynamic>.from(c)),
    ],
    annotations: [
      for (final a in (json['annotations'] as List? ?? []))
        if (a is Map) PlanAnnotation.fromJson(Map<String, dynamic>.from(a)),
    ],
  );
}

/// Marker geometry, shared by the Floor Plan page and the AV canvas so a
/// location dot is the same size wherever it is drawn.
const double kLocationMarkerRadius = 13;
const double kCalloutMarkerRadius = 15;
