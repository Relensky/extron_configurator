import 'dart:math' as math;

import 'building_project.dart' show addDays, formatIsoDate, parseIsoDate;
import 'project_schedule.dart' show formatScheduleDate;
import 'report_tools.dart';
import 'xlsx_writer.dart' show XlsxRowStyle, XlsxSheet, XlsxTint;

/// ============================================================================
///  THE AV PROCUREMENT LOG
/// ============================================================================
///  The sheet the general contractor schedules against: every piece of AV kit,
///  room by room, who buys it, when it has to be on site, and where its
///  submittal has got to. Issued to the contractor as a spreadsheet with the
///  same columns their scheduler already uses.
/// ============================================================================

/// Where a line's submittal has got to.
enum ProcurementStatus {
  none(''),
  submitted('Submitted'),
  approved('Approved'),
  released('Released');

  final String label;
  const ProcurementStatus(this.label);

  static ProcurementStatus fromName(Object? name) =>
      ProcurementStatus.values.firstWhere(
        (s) => s.name == name,
        orElse: () => ProcurementStatus.none,
      );
}

/// Who furnishes and installs a line, in the contractor's shorthand.
const List<String> kProcurementCompanies = ['CTS (OFOI)', 'OFCI', 'CFCI'];

/// When in the build a line goes in.
const List<String> kProcurementInstallPhases = [
  'Before drywall',
  'Before paint',
  'After paint',
];

/// Days before the P6 start that equipment has to be on site.
const int kProcurementOnSiteLeadDays = 4;

const List<String> _kMonths = [
  'jan', 'feb', 'mar', 'apr', 'may', 'jun',
  'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
];

/// A date as somebody types it: '2027-03-10', '3/10/2027', '3/10/27',
/// '10 Mar 2027' or 'Mar 10, 2027'. Null when it is not one.
DateTime? parseTypedDate(String text) {
  final t = text.trim().toLowerCase().replaceAll(',', ' ');
  if (t.isEmpty) return null;
  DateTime? make(int y, int m, int d) {
    if (y < 100) y += 2000;
    if (m < 1 || m > 12 || d < 1 || d > 31) return null;
    final date = DateTime(y, m, d);
    return date.month == m ? date : null;
  }

  // A year on its own: the first of January.
  if (RegExp(r'^\d{4}$').hasMatch(t)) return make(int.parse(t), 1, 1);
  var match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(t);
  if (match != null) {
    return make(int.parse(match[1]!), int.parse(match[2]!),
        int.parse(match[3]!));
  }
  match = RegExp(r'^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2}|\d{4})$').firstMatch(t);
  if (match != null) {
    return make(int.parse(match[3]!), int.parse(match[1]!),
        int.parse(match[2]!));
  }
  int? month(String word) {
    if (word.length < 3) return null;
    final i = _kMonths.indexOf(word.substring(0, 3));
    return i < 0 ? null : i + 1;
  }

  final words = t.split(RegExp(r'\s+'));
  if (words.length == 3) {
    final day = int.tryParse(words[0]);
    final m = month(words[1]);
    if (day != null && m != null) {
      final y = int.tryParse(words[2]);
      if (y != null) return make(y, m, day);
    }
    final m2 = month(words[0]);
    final day2 = int.tryParse(words[1]);
    final y2 = int.tryParse(words[2]);
    if (m2 != null && day2 != null && y2 != null) return make(y2, m2, day2);
  }
  return null;
}

/// One piece of kit on the log.
class ProcurementEntry {
  final String id;

  /// 'CTS (OFOI)', 'OFCI', 'CFCI' - see [kProcurementCompanies].
  final String company;
  final String room;
  final String device;
  final String description;
  final ProcurementStatus status;

  /// Who the status is with - 'DPR' in "Submitted to DPR".
  final String statusTo;
  final String installPhase;
  final String p6ActivityId;
  final String p6ActivityDescription;
  final String reviewTime;

  /// Weeks, or words such as 'Contractor to order'.
  final String leadTime;
  final DateTime? p6Start;
  final DateTime? submitBy;
  final DateTime? releasedOn;
  final DateTime? estimatedDelivery;
  final String notes;

  /// The room line this entry is about: the project room's id and the line's
  /// key on that room's estimate. Both set, the room and device shown are the
  /// room's own, live - see procurement_sync.dart. Blank is a line typed here.
  final String roomId;
  final String lineKey;

  /// Taken off the log on purpose. Kept, so the room line it names does not
  /// come straight back.
  final bool excluded;

  /// Column id -> what this line says in a column added on the job - see
  /// [BuildingProject.procurementCustomColumns].
  final Map<String, String> custom;

  const ProcurementEntry({
    required this.id,
    this.company = '',
    this.room = '',
    this.device = '',
    this.description = '',
    this.status = ProcurementStatus.none,
    this.statusTo = '',
    this.installPhase = '',
    this.p6ActivityId = '',
    this.p6ActivityDescription = '',
    this.reviewTime = '',
    this.leadTime = '',
    this.p6Start,
    this.submitBy,
    this.releasedOn,
    this.estimatedDelivery,
    this.notes = '',
    this.roomId = '',
    this.lineKey = '',
    this.excluded = false,
    this.custom = const {},
  });

  /// True when this entry follows a line on a room's estimate.
  bool get linked => roomId.isNotEmpty && lineKey.isNotEmpty;

  /// The status as the contractor reads it: 'Submitted to DPR'.
  String get statusText {
    final to = statusTo.trim();
    return switch (status) {
      ProcurementStatus.none => to.isEmpty ? '' : 'For $to',
      ProcurementStatus.submitted =>
        to.isEmpty ? 'Submitted' : 'Submitted to $to',
      ProcurementStatus.approved =>
        to.isEmpty ? 'Approved' : 'Approved by $to',
      ProcurementStatus.released =>
        to.isEmpty ? 'Released' : 'Released to $to',
    };
  }

  bool get released => status == ProcurementStatus.released;

  /// On site [kProcurementOnSiteLeadDays] days before the P6 start.
  DateTime? get requiredOnSite =>
      p6Start == null ? null : addDays(p6Start!, -kProcurementOnSiteLeadDays);

  ProcurementEntry copyWith({
    String? company,
    String? room,
    String? device,
    String? description,
    ProcurementStatus? status,
    String? statusTo,
    String? installPhase,
    String? p6ActivityId,
    String? p6ActivityDescription,
    String? reviewTime,
    String? leadTime,
    DateTime? p6Start,
    bool clearP6Start = false,
    DateTime? submitBy,
    bool clearSubmitBy = false,
    DateTime? releasedOn,
    bool clearReleasedOn = false,
    DateTime? estimatedDelivery,
    bool clearEstimatedDelivery = false,
    String? notes,
    String? id,
    String? roomId,
    String? lineKey,
    bool? excluded,
    Map<String, String>? custom,
  }) => ProcurementEntry(
    id: id ?? this.id,
    roomId: roomId ?? this.roomId,
    lineKey: lineKey ?? this.lineKey,
    excluded: excluded ?? this.excluded,
    custom: custom ?? this.custom,
    company: company ?? this.company,
    room: room ?? this.room,
    device: device ?? this.device,
    description: description ?? this.description,
    status: status ?? this.status,
    statusTo: statusTo ?? this.statusTo,
    installPhase: installPhase ?? this.installPhase,
    p6ActivityId: p6ActivityId ?? this.p6ActivityId,
    p6ActivityDescription: p6ActivityDescription ?? this.p6ActivityDescription,
    reviewTime: reviewTime ?? this.reviewTime,
    leadTime: leadTime ?? this.leadTime,
    p6Start: clearP6Start ? null : (p6Start ?? this.p6Start),
    submitBy: clearSubmitBy ? null : (submitBy ?? this.submitBy),
    releasedOn: clearReleasedOn ? null : (releasedOn ?? this.releasedOn),
    estimatedDelivery: clearEstimatedDelivery
        ? null
        : (estimatedDelivery ?? this.estimatedDelivery),
    notes: notes ?? this.notes,
  );

  Map<String, dynamic> toJson() {
    String? date(DateTime? d) => d == null ? null : formatIsoDate(d);
    return {
      'id': id,
      if (company.trim().isNotEmpty) 'company': company.trim(),
      if (room.trim().isNotEmpty) 'room': room.trim(),
      if (device.trim().isNotEmpty) 'device': device.trim(),
      if (description.trim().isNotEmpty) 'description': description.trim(),
      if (status != ProcurementStatus.none) 'status': status.name,
      if (statusTo.trim().isNotEmpty) 'statusTo': statusTo.trim(),
      if (installPhase.trim().isNotEmpty) 'installPhase': installPhase.trim(),
      if (p6ActivityId.trim().isNotEmpty) 'p6ActivityId': p6ActivityId.trim(),
      if (p6ActivityDescription.trim().isNotEmpty)
        'p6ActivityDescription': p6ActivityDescription.trim(),
      if (reviewTime.trim().isNotEmpty) 'reviewTime': reviewTime.trim(),
      if (leadTime.trim().isNotEmpty) 'leadTime': leadTime.trim(),
      if (p6Start != null) 'p6Start': date(p6Start),
      if (submitBy != null) 'submitBy': date(submitBy),
      if (releasedOn != null) 'releasedOn': date(releasedOn),
      if (estimatedDelivery != null)
        'estimatedDelivery': date(estimatedDelivery),
      if (notes.trim().isNotEmpty) 'notes': notes.trim(),
      if (roomId.isNotEmpty) 'roomId': roomId,
      if (lineKey.isNotEmpty) 'lineKey': lineKey,
      if (excluded) 'excluded': true,
      if (custom.values.any((v) => v.trim().isNotEmpty))
        'custom': {
          for (final e in custom.entries)
            if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
        },
    };
  }

  factory ProcurementEntry.fromJson(Map<String, dynamic> json) {
    String text(String key) => json[key]?.toString() ?? '';
    return ProcurementEntry(
      id: text('id'),
      company: text('company'),
      room: text('room'),
      device: text('device'),
      description: text('description'),
      status: ProcurementStatus.fromName(json['status']),
      statusTo: text('statusTo'),
      installPhase: text('installPhase'),
      p6ActivityId: text('p6ActivityId'),
      p6ActivityDescription: text('p6ActivityDescription'),
      reviewTime: text('reviewTime'),
      leadTime: text('leadTime'),
      p6Start: parseIsoDate(json['p6Start']),
      submitBy: parseIsoDate(json['submitBy']),
      releasedOn: parseIsoDate(json['releasedOn']),
      estimatedDelivery: parseIsoDate(json['estimatedDelivery']),
      notes: text('notes'),
      roomId: text('roomId'),
      lineKey: text('lineKey'),
      excluded: json['excluded'] == true,
      custom: {
        if (json['custom'] is Map)
          for (final e in (json['custom'] as Map).entries)
            e.key.toString(): e.value?.toString() ?? '',
      },
    );
  }
}

/// A column added on one job, after the contractor's own.
typedef ProcurementCustomColumn = ({String id, String label});

/// What the id of every added column starts with.
const String kProcurementCustomPrefix = 'custom';

/// True for a column added on the job rather than built in.
bool procurementColumnIsCustom(String id) =>
    id.startsWith(kProcurementCustomPrefix);

/// The one column that cannot be deleted: it names the line, and it is the
/// frozen one the line is pressed by.
const String kProcurementFixedColumn = 'device';

/// The log's columns, in the order the contractor's sheet has them.
/// The bands the columns are colored in until somebody picks their own.
enum ProcurementGroup {
  item(0xFFC5CAE9),
  status(0xFFFFE0B2),
  schedule(0xFFB2DFDB),
  dates(0xFFE1BEE7),
  notes(0xFFCFD8DC);

  /// The default heading color, ARGB.
  final int color;
  const ProcurementGroup(this.color);
}

/// One column of the log: a stable id (what a chosen color is saved under),
/// its heading, and the band it starts in.
typedef ProcurementColumnSpec = ({
  String id,
  String label,
  ProcurementGroup group,
});

/// The log's columns, in the order the contractor's sheet has them.
const List<ProcurementColumnSpec> kProcurementColumnSpecs = [
  (id: 'company', label: 'Company', group: ProcurementGroup.item),
  (id: 'room', label: 'Room #', group: ProcurementGroup.item),
  (id: 'device', label: 'Device', group: ProcurementGroup.item),
  (
    id: 'description',
    label: 'Equipment Description',
    group: ProcurementGroup.item,
  ),
  (id: 'status', label: 'Status', group: ProcurementGroup.status),
  (
    id: 'phase',
    label: 'Install Before Drywall or After Paint?',
    group: ProcurementGroup.status,
  ),
  (id: 'p6Id', label: 'P6 Activity ID', group: ProcurementGroup.schedule),
  (
    id: 'p6Description',
    label: 'P6 Activity Description',
    group: ProcurementGroup.schedule,
  ),
  (id: 'review', label: 'Review Time', group: ProcurementGroup.schedule),
  (
    id: 'lead',
    label: 'Lead Times (In Weeks)',
    group: ProcurementGroup.schedule,
  ),
  (id: 'p6Start', label: 'P6 Start Date', group: ProcurementGroup.dates),
  (
    id: 'onSite',
    label: 'Date Required On Site ($kProcurementOnSiteLeadDays Days before P6)',
    group: ProcurementGroup.dates,
  ),
  (
    id: 'submitBy',
    label: 'Date to be Submitted',
    group: ProcurementGroup.dates,
  ),
  (id: 'released', label: 'Released', group: ProcurementGroup.dates),
  (
    id: 'releasedOn',
    label: 'Actual Release Date',
    group: ProcurementGroup.dates,
  ),
  (
    id: 'delivery',
    label: 'Estimated Delivery Date',
    group: ProcurementGroup.dates,
  ),
  (id: 'notes', label: 'Notes/Comments', group: ProcurementGroup.notes),
];

/// The headings alone, in order.
final List<String> kProcurementColumns = [
  for (final c in kProcurementColumnSpecs) c.label,
];

/// A column's heading color, ARGB: the one chosen on this job, or its band's.
int procurementColumnColor(
  ProcurementColumnSpec column,
  Map<String, int> chosen,
) => chosen[column.id] ?? column.group.color;

/// A column's heading: the one typed on this job, or its usual one.
String procurementColumnLabel(
  ProcurementColumnSpec column,
  Map<String, String> typed,
) {
  final own = typed[column.id]?.trim() ?? '';
  return own.isEmpty ? column.label : own;
}

/// Dark or white text, whichever reads on [argb].
int procurementInkFor(int argb) {
  double channel(int shift) {
    final c = ((argb >> shift) & 0xFF) / 255.0;
    return c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4) * 1.0;
  }

  final luminance =
      0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0);
  return luminance > 0.4 ? 0xFF1F2933 : 0xFFFFFFFF;
}

String _hex(int argb) =>
    (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

/// The entries grouped by room, rooms in the order they first appear.
List<({String room, List<ProcurementEntry> entries})> procurementByRoom(
  List<ProcurementEntry> entries,
) {
  final groups = <String, List<ProcurementEntry>>{};
  for (final e in entries) {
    groups.putIfAbsent(e.room.trim(), () => []).add(e);
  }
  return [
    for (final g in groups.entries) (room: g.key, entries: g.value),
  ];
}

/// The columns in the order the job keeps them: [order] first, by id, then
/// any it does not name in their usual places, then the job's [custom] ones.
/// Built-in columns in [hidden] are left out; the device column never is.
List<ProcurementColumnSpec> orderedProcurementColumns(
  List<String> order, {
  Set<String> hidden = const {},
  List<ProcurementCustomColumn> custom = const [],
}) {
  final all = <ProcurementColumnSpec>[
    for (final c in kProcurementColumnSpecs)
      if (c.id == kProcurementFixedColumn || !hidden.contains(c.id)) c,
    for (final c in custom)
      (id: c.id, label: c.label, group: ProcurementGroup.notes),
  ];
  final byId = {for (final c in all) c.id: c};
  final out = <ProcurementColumnSpec>[
    for (final id in order)
      if (byId.containsKey(id)) byId.remove(id)!,
  ];
  for (final c in all) {
    if (byId.containsKey(c.id)) out.add(c);
  }
  return out;
}

/// What one line says in each column, by column id.
Map<String, String> procurementValues(ProcurementEntry e) {
  String date(DateTime? d) => d == null ? '' : formatScheduleDate(d);
  return {
    'company': e.company,
    'room': e.room,
    'device': e.device,
    'description': e.description,
    'status': e.statusText,
    'phase': e.installPhase,
    'p6Id': e.p6ActivityId,
    'p6Description': e.p6ActivityDescription,
    'review': e.reviewTime,
    'lead': e.leadTime,
    'p6Start': date(e.p6Start),
    'onSite': date(e.requiredOnSite),
    'submitBy': date(e.submitBy),
    'released': e.released ? 'Yes' : '',
    'releasedOn': date(e.releasedOn),
    'delivery': date(e.estimatedDelivery),
    'notes': e.notes,
    ...e.custom,
  };
}

/// One row of the issued sheet, in [order] (see [orderedProcurementColumns]),
/// or in [columns] when given - see [BuildingProject.procurementColumns].
List<dynamic> procurementRow(
  ProcurementEntry e, {
  List<String> order = const [],
  List<ProcurementColumnSpec>? columns,
}) {
  final values = procurementValues(e);
  return [
    for (final c in columns ?? orderedProcurementColumns(order))
      values[c.id] ?? '',
  ];
}

/// The log as report sections, one per room, its columns in [order] (or
/// [columns]) and headed as [labels] renames them.
List<ReportSection> procurementLogSections(
  List<ProcurementEntry> entries, {
  List<String> order = const [],
  Map<String, String> labels = const {},
  List<ProcurementColumnSpec>? columns,
}) {
  final shown = columns ?? orderedProcurementColumns(order);
  final header = [for (final c in shown) procurementColumnLabel(c, labels)];
  return [
    for (final group in procurementByRoom(entries))
      (
        title: group.room.isEmpty ? 'No room' : group.room,
        header: header,
        rows: [
          for (final e in group.entries) procurementRow(e, columns: shown),
        ],
      ),
  ];
}

/// The tab the log is written on, in its own file and in the workbook.
const String kProcurementLogSheet = 'AV Procurement Log';

/// The log as a spreadsheet for the contractor, its column headings in the
/// colors chosen on the Procurement page.
XlsxSheet procurementLogSheet(
  String projectName,
  List<ProcurementEntry> entries, {
  String sheetName = kProcurementLogSheet,
  DateTime? generated,
  Map<String, int> colors = const {},
  List<String> order = const [],
  Map<String, String> labels = const {},
  List<ProcurementColumnSpec>? columns,
}) {
  final shown = columns ?? orderedProcurementColumns(order);
  final sheet = buildStackedReportSheet(
    sheetName: sheetName,
    title: projectName.trim().isEmpty
        ? kProcurementLogSheet
        : '${projectName.trim()} - $kProcurementLogSheet',
    sections: procurementLogSections(
      entries,
      labels: labels,
      columns: shown,
    ),
    generated: generated,
  );
  final byLabel = {
    for (final c in shown) procurementColumnLabel(c, labels): c,
  };
  for (var r = 0; r < sheet.rows.length; r++) {
    if (sheet.rowStyles[r] != XlsxRowStyle.header) continue;
    final row = sheet.rows[r];
    for (var c = 0; c < row.length; c++) {
      final spec = byLabel[row[c]];
      if (spec == null) continue;
      final fill = procurementColumnColor(spec, colors);
      row[c] = XlsxTint(
        text: procurementColumnLabel(spec, labels),
        fillHex: _hex(fill),
        inkHex: _hex(procurementInkFor(fill)),
        bold: true,
      );
    }
  }
  return sheet;
}
