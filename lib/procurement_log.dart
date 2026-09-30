import 'building_project.dart' show addDays, formatIsoDate, parseIsoDate;
import 'project_schedule.dart' show formatScheduleDate;
import 'report_tools.dart';
import 'xlsx_writer.dart' show XlsxSheet;

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
  });

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
  }) => ProcurementEntry(
    id: id,
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
    );
  }
}

/// The log's columns, in the order the contractor's sheet has them.
const List<String> kProcurementColumns = [
  'Company',
  'Room #',
  'Device',
  'Equipment Description',
  'Status',
  'Install Before Drywall or After Paint?',
  'P6 Activity ID',
  'P6 Activity Description',
  'Review Time',
  'Lead Times (In Weeks)',
  'P6 Start Date',
  'Date Required On Site ($kProcurementOnSiteLeadDays Days before P6)',
  'Date to be Submitted',
  'Released',
  'Actual Release Date',
  'Estimated Delivery Date',
  'Notes/Comments',
];

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

/// One row of the issued sheet.
List<dynamic> procurementRow(ProcurementEntry e) {
  String date(DateTime? d) => d == null ? '' : formatScheduleDate(d);
  return [
    e.company,
    e.room,
    e.device,
    e.description,
    e.statusText,
    e.installPhase,
    e.p6ActivityId,
    e.p6ActivityDescription,
    e.reviewTime,
    e.leadTime,
    date(e.p6Start),
    date(e.requiredOnSite),
    date(e.submitBy),
    e.released ? 'Yes' : '',
    date(e.releasedOn),
    date(e.estimatedDelivery),
    e.notes,
  ];
}

/// The log as report sections, one per room.
List<ReportSection> procurementLogSections(List<ProcurementEntry> entries) => [
  for (final group in procurementByRoom(entries))
    (
      title: group.room.isEmpty ? 'No room' : group.room,
      header: kProcurementColumns,
      rows: [for (final e in group.entries) procurementRow(e)],
    ),
];

/// The tab the log is written on, in its own file and in the workbook.
const String kProcurementLogSheet = 'AV Procurement Log';

/// The log as a spreadsheet for the contractor.
XlsxSheet procurementLogSheet(
  String projectName,
  List<ProcurementEntry> entries, {
  String sheetName = kProcurementLogSheet,
  DateTime? generated,
}) => buildStackedReportSheet(
  sheetName: sheetName,
  title: projectName.trim().isEmpty
      ? kProcurementLogSheet
      : '${projectName.trim()} - $kProcurementLogSheet',
  sections: procurementLogSections(entries),
  generated: generated,
);
