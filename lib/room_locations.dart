import 'dart:math' as math;

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

  /// LEGACY. Where the marker sat back when a room had ONE plan and every
  /// sheet shared it.
  ///
  /// A marker now belongs to the SHEET it was dropped on — see
  /// [FloorPlan.markers] — because a room with a Level 1 plan, a Level 2 plan
  /// and a reflected ceiling plan does not have the instructor station in the
  /// same spot on all three, and drawing it in all three at one set of
  /// coordinates put two of them somewhere arbitrary.
  ///
  /// Still READ from an older room file so its markers survive the upgrade
  /// (they are copied onto the first sheet on load); never written back out.
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

  /// True when the LEGACY room file had this location on its single plan.
  /// Only the migration reads it; ask the sheet otherwise.
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

  /// The marker coordinates are deliberately NOT written: they live on the
  /// sheet now, and writing them here too would leave two answers to "where is
  /// the instructor station" for the next reader to choose between.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (zone != RoomZone.unspecified) 'zone': zone.name,
    if (callout.isNotEmpty) 'callout': callout,
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
///
/// The cameras are two entries rather than one because they point opposite ways
/// and are mounted at opposite ends of the room, and the speakers are four
/// because each one is its own ceiling drop with its own run — a single
/// "Speakers" location would put four drops at one dot on the plan and one row
/// in the schedule. The wall switch is where the screen switch's three-position
/// plate lands, which is the end of a run the electrician has to box out for.
///
/// The callout letters run on from the ones above them and skip I, which reads
/// as a 1 next to a numbered marker on a printed plan.
const List<({String name, RoomZone zone, String callout})>
kDefaultRoomLocations = [
  (name: 'Equipment rack', zone: RoomZone.rack, callout: 'A'),
  (name: 'Instructor station', zone: RoomZone.lectern, callout: 'B'),
  (name: 'Projector box', zone: RoomZone.ceiling, callout: 'C'),
  (name: 'Projector screen', zone: RoomZone.wall, callout: 'D'),
  (name: 'Ceiling mic', zone: RoomZone.ceiling, callout: 'E'),
  (name: 'Instructor camera', zone: RoomZone.wall, callout: 'F'),
  (name: 'Audience camera', zone: RoomZone.wall, callout: 'G'),
  (name: 'Speaker 1', zone: RoomZone.ceiling, callout: 'H'),
  (name: 'Speaker 2', zone: RoomZone.ceiling, callout: 'J'),
  (name: 'Speaker 3', zone: RoomZone.ceiling, callout: 'K'),
  (name: 'Speaker 4', zone: RoomZone.ceiling, callout: 'L'),
  (name: 'Wall switch', zone: RoomZone.wall, callout: 'M'),
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

  /// Places the cable is routed THROUGH on its way, in order, as location ids.
  ///
  /// The run that actually gets pulled is rarely a straight line between two
  /// rooms' worth of gear: it leaves the projector box, lands in an AV pull box
  /// above the ceiling, and carries on to the equipment rack. Recording only
  /// the two ends made the drawing show a line through the middle of the room
  /// and the schedule quote a length nobody could pull, and the pull box — the
  /// thing the electrician has to install — appeared nowhere at all.
  ///
  /// Empty is the normal case and behaves exactly as before: one leg, end to
  /// end. Anything named here becomes a leg boundary, so a run through two
  /// pull boxes is three legs on the cabling sheet.
  final List<String> viaLocationIds;

  /// What runs between them — '18/2 plenum', 'Cat6', 'line voltage'.
  final String cableType;

  /// The number this cable carries on the drawing set and on its own label —
  /// 'C-101', '14'. Printed on the run and in the schedule.
  ///
  /// Free text because a cable number is whatever the office's convention says
  /// it is, and a scheme that renumbers somebody's drawing set for them is a
  /// scheme that gets turned off.
  final String cableNumber;

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
    this.viaLocationIds = const [],
    this.cableType = '',
    this.cableNumber = '',
    this.runFeet = 0,
    this.note = '',
  });

  /// Every place this run touches, in pull order: the start, whatever it is
  /// routed through, then the end. Blank ids are dropped, and a via that
  /// repeats the leg before it is collapsed — a zero-length leg is a line the
  /// drawing cannot draw and a row the schedule should not print.
  List<String> get pathLocationIds {
    final out = <String>[];
    for (final id in [startLocationId, ...viaLocationIds, endLocationId]) {
      if (id.isEmpty || id == kNoLocationId) continue;
      if (out.isNotEmpty && out.last == id) continue;
      out.add(id);
    }
    return out;
  }

  /// The pairs of places cable is actually pulled between: one for a plain
  /// run, one per hop for a run routed through pull boxes.
  List<({String from, String to})> get legs => [
    for (int i = 0; i < pathLocationIds.length - 1; i++)
      (from: pathLocationIds[i], to: pathLocationIds[i + 1]),
  ];

  ScreenSwitch copyWith({
    String? label,
    String? startLocationId,
    String? startNote,
    String? endLocationId,
    String? endNote,
    List<String>? viaLocationIds,
    String? cableType,
    String? cableNumber,
    double? runFeet,
    String? note,
  }) => ScreenSwitch(
    id: id,
    label: label ?? this.label,
    startLocationId: startLocationId ?? this.startLocationId,
    startNote: startNote ?? this.startNote,
    endLocationId: endLocationId ?? this.endLocationId,
    endNote: endNote ?? this.endNote,
    viaLocationIds: viaLocationIds ?? this.viaLocationIds,
    cableType: cableType ?? this.cableType,
    cableNumber: cableNumber ?? this.cableNumber,
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
    viaLocationIds: viaLocationIds,
    cableType: cableType,
    cableNumber: cableNumber,
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
    if (viaLocationIds.isNotEmpty) 'via': viaLocationIds,
    if (cableType.isNotEmpty) 'cableType': cableType,
    if (cableNumber.isNotEmpty) 'cableNumber': cableNumber,
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
    viaLocationIds: [
      for (final v in (json['via'] as List? ?? []))
        if (v.toString().trim().isNotEmpty) v.toString(),
    ],
    cableType: json['cableType']?.toString() ?? '',
    cableNumber: json['cableNumber']?.toString() ?? '',
    runFeet: (json['runFeet'] as num?)?.toDouble() ?? 0,
    note: json['note']?.toString() ?? '',
  );
}

/// Cable types offered in the screen switch editor; free text underneath.
///
/// The three "what it is for, then what it is made of" entries are the office's
/// own names for the pulls it specifies most, and they are here rather than
/// being typed each time for the same reason kCablingCableTypes exists: a
/// schedule
/// carrying "Cat6a", "cat 6a" and "CAT6A" is three lines on a purchase order.
const List<String> kScreenSwitchCableTypes = [
  'AV Point to Point Cat6a',
  'Control Cable Cat5e',
  'Network to IDF Cat6a',
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

  /// Where each of the ROOM'S locations sits ON THIS SHEET, keyed by location
  /// id, in this sheet's own image coordinates.
  ///
  /// The locations themselves stay a property of the room — a floor box named
  /// once is the same floor box on every drawing, and the devices, the jack
  /// counts and the cable schedule all key off that one id. What is per sheet
  /// is WHERE it is drawn, and whether it is drawn at all:
  ///
  ///   * a location with no entry here is simply not on this sheet, which is
  ///     the normal case — the Level 2 plan has no business showing the Level 1
  ///     floor boxes;
  ///   * a location on two sheets has two sets of coordinates, because two
  ///     drawings of the same room are almost never at the same scale, origin
  ///     or crop.
  ///
  /// This is the third of the three things a sheet owns outright, beside its
  /// [imageFile] and its [callouts]. Before it, every sheet redrew one shared
  /// set of coordinates, so adding a second sheet scattered its markers
  /// wherever the first sheet's geometry happened to put them.
  final Map<String, Offset> markers;

  /// Bends a cable run has been given ON THIS SHEET, keyed by the run's id and
  /// held in this sheet's own image coordinates.
  ///
  /// Per sheet for the same reason [markers] is: the run between the rack and
  /// the lectern is one pull, but the way it is drawn round a Level 1 plan has
  /// nothing to say about how it is drawn on the reflected ceiling plan. The
  /// RUN belongs to the room; the shape of the line belongs to the drawing.
  ///
  /// The router picks a way through on its own. Which way the cable actually
  /// goes — down the tray, along the corridor, round the wall nobody may core
  /// — is a fact about the building, and this is where it gets said.
  final Map<String, List<Offset>> runWaypoints;

  /// How far a run's caption has been nudged from where the sheet put it,
  /// keyed by the pair of markers the caption names.
  ///
  /// A NUDGE rather than a position: the automatic spot follows the line, so a
  /// label that was moved out of the way of a door swing stays out of the way
  /// of it when the marker it belongs to is dragged half a metre. An absolute
  /// coordinate would be left behind pointing at nothing.
  ///
  /// Per sheet, like everything else drawn on one.
  final Map<String, Offset> runLabelOffsets;

  /// Where the key panel sits on this sheet, in the image's own coordinates.
  ///
  /// Per sheet like everything else drawn on one: a legend in the top-right
  /// corner of the furniture plan can be sitting on the title block of the
  /// reflected ceiling plan, and one shared position would put it there.
  final Offset keyPos;

  /// True when somebody has taken the key OFF this sheet.
  ///
  /// Stored the way round that makes the default "shown": a drawing whose
  /// lines are coded by colour, dash pattern and marker shape, and whose key is
  /// opt-in, is a drawing that gets issued without one.
  final bool keyHidden;

  const FloorPlan({
    required this.id,
    required this.name,
    this.imageFile = '',
    this.imageSize = const Size(1200, 900),
    this.opacity = 0.35,
    this.pixelsPerFoot = 0,
    this.callouts = const [],
    this.annotations = const [],
    this.markers = const {},
    this.runWaypoints = const {},
    this.runLabelOffsets = const {},
    this.keyPos = kDefaultPlanKeyPosition,
    this.keyHidden = false,
  });

  bool get hasImage => imageFile.trim().isNotEmpty;

  /// True when [locationId] has been dropped on THIS sheet.
  bool hasMarker(String locationId) => markers.containsKey(locationId);

  /// Where [locationId] is on this sheet, or null when it is not on it. Null
  /// rather than [Offset.zero] on purpose: the top-left corner is a legitimate
  /// place to put a marker, and "not placed" has to be a different answer from
  /// "placed at 0,0" or a marker dragged into the corner disappears.
  Offset? markerFor(String locationId) => markers[locationId];

  /// This sheet with [locationId] at [pos].
  FloorPlan withMarker(String locationId, Offset pos) =>
      copyWith(markers: {...markers, locationId: pos});

  /// This sheet with [locationId] taken off it. The location itself is
  /// untouched — it belongs to the room.
  FloorPlan withoutMarker(String locationId) =>
      copyWith(markers: {...markers}..remove(locationId));

  /// This sheet with [runId] bent through [points]. An empty list hands the
  /// run back to the router.
  FloorPlan withRunWaypoints(String runId, List<Offset> points) => copyWith(
    runWaypoints: {
      ...runWaypoints,
      if (points.isNotEmpty) runId: List<Offset>.from(points),
    }..removeWhere((key, _) => key == runId && points.isEmpty),
  );

  /// The bends [runId] has been given on this sheet, or none.
  List<Offset> waypointsFor(String runId) =>
      runWaypoints[runId] ?? const <Offset>[];

  /// This sheet with the caption for [edgeKey] nudged by [by].
  /// [Offset.zero] puts it back where the sheet would have placed it.
  FloorPlan withRunLabelOffset(String edgeKey, Offset by) => copyWith(
    runLabelOffsets: {
      ...runLabelOffsets,
      if (by != Offset.zero) edgeKey: by,
    }..removeWhere((key, _) => key == edgeKey && by == Offset.zero),
  );

  /// How far the caption for [edgeKey] has been moved, or [Offset.zero] when
  /// it is still where the sheet put it.
  Offset labelOffsetFor(String edgeKey) =>
      runLabelOffsets[edgeKey] ?? Offset.zero;

  FloorPlan copyWith({
    String? name,
    String? imageFile,
    Size? imageSize,
    double? opacity,
    double? pixelsPerFoot,
    List<FloorPlanCallout>? callouts,
    List<PlanAnnotation>? annotations,
    Map<String, Offset>? markers,
    Map<String, List<Offset>>? runWaypoints,
    Map<String, Offset>? runLabelOffsets,
    Offset? keyPos,
    bool? keyHidden,
  }) => FloorPlan(
    id: id,
    name: name ?? this.name,
    imageFile: imageFile ?? this.imageFile,
    imageSize: imageSize ?? this.imageSize,
    opacity: opacity ?? this.opacity,
    pixelsPerFoot: pixelsPerFoot ?? this.pixelsPerFoot,
    callouts: callouts ?? this.callouts,
    annotations: annotations ?? this.annotations,
    markers: markers ?? this.markers,
    runWaypoints: runWaypoints ?? this.runWaypoints,
    runLabelOffsets: runLabelOffsets ?? this.runLabelOffsets,
    keyPos: keyPos ?? this.keyPos,
    keyHidden: keyHidden ?? this.keyHidden,
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
    markers: markers,
    runWaypoints: runWaypoints,
    runLabelOffsets: runLabelOffsets,
    keyPos: keyPos,
    keyHidden: keyHidden,
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
    if (markers.isNotEmpty)
      'markers': {
        for (final e in markers.entries)
          e.key: {'x': e.value.dx, 'y': e.value.dy},
      },
    if (runWaypoints.isNotEmpty)
      'runWaypoints': {
        for (final e in runWaypoints.entries)
          if (e.value.isNotEmpty)
            e.key: [
              for (final w in e.value) {'x': w.dx, 'y': w.dy},
            ],
      },
    if (runLabelOffsets.isNotEmpty)
      'runLabelOffsets': {
        for (final e in runLabelOffsets.entries)
          if (e.value != Offset.zero)
            e.key: {'x': e.value.dx, 'y': e.value.dy},
      },
    if (keyPos != kDefaultPlanKeyPosition)
      'key': {'x': keyPos.dx, 'y': keyPos.dy},
    if (keyHidden) 'keyHidden': true,
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
    markers: {
      for (final e in (json['markers'] as Map? ?? {}).entries)
        if (e.value is Map)
          e.key.toString(): Offset(
            ((e.value as Map)['x'] as num?)?.toDouble() ?? 0,
            ((e.value as Map)['y'] as num?)?.toDouble() ?? 0,
          ),
    },
    runWaypoints: {
      for (final e in (json['runWaypoints'] as Map? ?? {}).entries)
        if (e.value is List && (e.value as List).isNotEmpty)
          e.key.toString(): [
            for (final p in (e.value as List))
              if (p is Map)
                Offset(
                  (p['x'] as num?)?.toDouble() ?? 0,
                  (p['y'] as num?)?.toDouble() ?? 0,
                ),
          ],
    },
    runLabelOffsets: {
      for (final e in (json['runLabelOffsets'] as Map? ?? {}).entries)
        if (e.value is Map)
          e.key.toString(): Offset(
            ((e.value as Map)['x'] as num?)?.toDouble() ?? 0,
            ((e.value as Map)['y'] as num?)?.toDouble() ?? 0,
          ),
    },
    keyPos: json['key'] is Map
        ? Offset(
            ((json['key'] as Map)['x'] as num?)?.toDouble() ??
                kDefaultPlanKeyPosition.dx,
            ((json['key'] as Map)['y'] as num?)?.toDouble() ??
                kDefaultPlanKeyPosition.dy,
          )
        : kDefaultPlanKeyPosition,
    keyHidden: json['keyHidden'] == true,
  );
}

/// Where a sheet's key sits before anybody drags it: in from the top-left,
/// which is the one corner of an architectural export that is reliably empty —
/// the title block is bottom-right and the north arrow is usually top-right.
const Offset kDefaultPlanKeyPosition = Offset(24, 24);

/// Marker geometry, shared by the Floor Plan page and the AV canvas so a
/// location dot is the same size wherever it is drawn.
const double kLocationMarkerRadius = 13;
const double kCalloutMarkerRadius = 15;

/// How wide the name printed under a location dot is allowed to get before it
/// wraps. A cap rather than no limit: "Instructor station floor box (front)"
/// on one line is a banner across the drawing.
const double kLocationLabelWidth = 170;

/// Font size of that name, and the padding the plate round it carries.
const double kLocationLabelFontSize = 10;
const double _kLocationLabelPadX = 4;
const double _kLocationLabelPadY = 1;
const double _kLocationLabelGap = 2;

/// The zone badge printed on the name plate, in front of the name: the same
/// [kRoomZoneIcons] glyph the key's "mounting surface" section lists.
///
/// The key was explaining a convention the drawing did not use. It said a
/// ceiling glyph means ceiling, and then every marker on the sheet was the same
/// blue dot, so the only way to tell a ceiling speaker from a wall plate was to
/// read the names and know the room. Printing the glyph on the marker is what
/// makes that section of the key worth having — and it is the fact the trades
/// care about, since a ceiling drop and a wall box are different work.
const double kLocationZoneIconSize = 11;
const double kLocationZoneIconGap = 3;

/// What the badge adds to the width of the plate. Part of the geometry rather
/// than a detail of the painter, because a run routes round the plate.
const double kLocationZoneBadgeWidth =
    kLocationZoneIconSize + kLocationZoneIconGap;

/// Just the dot, centred on [pos].
Rect locationDotBounds(Offset pos) => Rect.fromCenter(
  center: pos,
  width: kLocationMarkerRadius * 2,
  height: kLocationMarkerRadius * 2,
);

/// Just the plate the name is printed on, under the dot. Null when there is no
/// name to print.
///
/// Separate from [locationDotBounds] because the two are obstacles to a cable
/// run on DIFFERENT terms. A run landing at a location has to reach its dot, so
/// the dot cannot block it — but the name plate must block it even then, or the
/// last few pixels of a run come in sideways straight across the label of the
/// very place it is running to. That is the one crossing a single combined box
/// could not express, and it is the one that actually happened.
Rect? locationLabelBounds(Offset pos, String name) {
  if (name.trim().isEmpty) return null;
  final label = TextPainter(
    text: TextSpan(
      text: name,
      style: const TextStyle(fontSize: kLocationLabelFontSize),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 2,
    ellipsis: '…',
  )..layout(maxWidth: kLocationLabelWidth);

  // The zone badge is drawn inside the plate, so it is part of the box a run
  // has to keep off — a plate measured on the words alone left the glyph
  // sticking out into the routing.
  final width =
      label.width + _kLocationLabelPadX * 2 + kLocationZoneBadgeWidth;

  return Rect.fromLTWH(
    pos.dx - width / 2,
    locationDotBounds(pos).bottom + _kLocationLabelGap,
    width,
    math.max(label.height, kLocationZoneIconSize) + _kLocationLabelPadY * 2,
  );
}

/// The whole box a location marker occupies on a plan: the dot, centred on
/// [pos], with [name] printed on a plate under it.
///
/// Shared with the code that ROUTES cable runs, which is the point of it being
/// a function rather than a magic number in the painter. A run stepped round
/// the 26-pixel dot and straight through the words under it was the drawing
/// scribbling out its own labels.
Rect locationMarkerBounds(Offset pos, String name) {
  final dot = locationDotBounds(pos);
  final plate = locationLabelBounds(pos, name);
  return plate == null ? dot : dot.expandToInclude(plate);
}
