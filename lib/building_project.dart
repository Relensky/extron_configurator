import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'av_device_library.dart' show AvDeviceLibrary;
import 'responsibility_matrix.dart';

/// ============================================================================
///  THE BUILDING PROJECT
/// ============================================================================
///  A room is one config and its sidecars. A JOB is usually a building: eight
///  classrooms, two conference rooms and a lecture hall, quoted together,
///  ordered together, and installed by the same crew over the same fortnight.
///
///  Nothing in the app knew that. Every room priced itself in isolation, so the
///  number anybody actually needed — what the building costs — was arrived at
///  by opening nine rooms in turn and adding up nine screenshots. And the
///  ORDER was worse: nine separate equipment lists, each with its own two
///  Extron switchers on it, sent to a vendor who then quotes eighteen line
///  items for a building that needs eighteen switchers spread across nine
///  rooms and would rather buy them as one line.
///
///  A project fixes both by being a THIN thing. It is a list of room config
///  paths and some job metadata — it does not own the rooms, copy them, or
///  lock them. Each room stays exactly the file it was: openable on its own,
///  editable on its own, and able to belong to two projects at once (a
///  building-wide refresh and a departmental sub-job frequently want the same
///  classroom). Re-pricing a project re-reads the rooms off disk, so a price
///  fixed in a room this morning is in the building total this afternoon
///  without anybody re-importing anything.
///
///  VENDORS are the other half. Which company quotes a part is a fact about
///  the JOB, not about the product — the same 86" display goes through the
///  manufacturer on one contract and a reseller on the next — so the tags live
///  here rather than in the catalog. They are assigned two ways:
///
///    * BY RULE. A vendor lists the manufacturers it quotes, and every part by
///      those makers tags itself. One line of setup covers "all Extron to
///      Extron Direct" for the whole building.
///    * BY HAND. Any part on the master list can be pinned to a vendor,
///      overriding the rules. Stored per PART rather than per room-line,
///      because that is the decision being made: "we buy the ceiling mics from
///      the integrator" is true of the whole job at once.
///
///  LEAD TIMES AND THE DEADLINE are the third half — the part of a job that is
///  not money and not who sells it, but WHEN it has to be bought. They live
///  here for the same reason vendor tags do: how long a part takes to arrive is
///  a fact about this order on this job, and the date it has to be on site by
///  is a fact about the building, not about any one room. See
///  project_schedule.dart for the arithmetic that turns them into an order-by
///  date per part.
///
///  See project_estimate.dart for the rollup that turns this plus the rooms on
///  disk into per-room totals, a core components list and per-vendor packages.
/// ============================================================================

// ---------------------------------------------------------------------------
//  VENDORS
// ---------------------------------------------------------------------------

/// How a part came by the vendor it is tagged with — shown on the master list
/// so a tag can be argued with. "Why is the projector going to the reseller?"
/// has three different answers and three different fixes, and a bare vendor
/// name gives none of them.
enum VendorTagSource {
  /// Somebody pinned this part by hand. Beats every rule.
  pinned,

  /// A vendor's manufacturer list claims the maker.
  manufacturerRule,

  /// A vendor's category list claims the kind of part.
  categoryRule,

  /// Nothing claims it — it lands in the untagged package, which is the
  /// project's to-do list rather than a vendor.
  none,
}

const Map<VendorTagSource, String> kVendorTagSourceLabels = {
  VendorTagSource.pinned: 'Pinned',
  VendorTagSource.manufacturerRule: 'By manufacturer',
  VendorTagSource.categoryRule: 'By category',
  VendorTagSource.none: 'Untagged',
};

// ---------------------------------------------------------------------------
//  DATES, WITHOUT THE TIME
// ---------------------------------------------------------------------------
//  Every date on a job is a DAY: the delivery lands on the 14th, the order goes
//  in on the 3rd. Carrying a time of day around is what makes a deadline read
//  as the 13th after a save and a reload in another timezone, and what makes
//  "is this overdue" hinge on the hour the app happened to be opened at.
//
//  So every date this file stores and reads is normalized to local midnight and
//  written as a plain `yyyy-mm-dd` string. Both of those are one function each,
//  here, rather than a convention every call site is trusted to remember.

/// [when] with the clock stripped: local midnight on the same calendar day.
DateTime dateOnly(DateTime when) => DateTime(when.year, when.month, when.day);

/// Today, as a date with no time — what "is this overdue" is measured against.
DateTime today() => dateOnly(DateTime.now());

/// A date as `yyyy-mm-dd`, which sorts as text and survives a hand edit.
String formatIsoDate(DateTime when) =>
    '${when.year.toString().padLeft(4, '0')}-'
    '${when.month.toString().padLeft(2, '0')}-'
    '${when.day.toString().padLeft(2, '0')}';

/// A count of units as somebody would write it: '6', '2.5', and '' for none.
///
/// Whole numbers lose the decimal, because '6.0 wall plates' reads as a
/// measurement rather than a count. Nought comes back BLANK rather than as
/// '0' - on a delivery row it means nobody said how many, and printing a
/// zero would state that none arrived.
String formatUnits(double qty) {
  if (qty == 0) return '';
  return qty == qty.roundToDouble()
      ? qty.toStringAsFixed(0)
      : qty.toStringAsFixed(1);
}

/// A `yyyy-mm-dd` back, or null when it is missing or not a date.
///
/// Tolerant on the way in because a project file is a supported thing to hand
/// edit: a full ISO timestamp, which is what an older writer or another tool
/// might leave, is accepted and reduced to its day.
DateTime? parseIsoDate(Object? raw) {
  if (raw == null) return null;
  final text = raw.toString().trim();
  if (text.isEmpty) return null;
  final parsed = DateTime.tryParse(text);
  return parsed == null ? null : dateOnly(parsed);
}

/// Whole days from [from] to [to], forwards positive.
///
/// Measured between two local midnights via UTC, because subtracting local
/// DateTimes across a daylight-saving boundary yields 23 or 25 hours and
/// truncates to a day out — which is a whole day of lead time, in the
/// direction that misses the delivery.
int daysBetween(DateTime from, DateTime to) {
  final a = DateTime.utc(from.year, from.month, from.day);
  final b = DateTime.utc(to.year, to.month, to.day);
  return b.difference(a).inDays;
}

/// [when] moved by [days] calendar days — negative to go back.
///
/// NOT `subtract(Duration(days: n))`, which is the same trap [daysBetween]
/// avoids from the other side. A Duration is a fixed number of HOURS, so
/// stepping back thirty days across the spring clock change lands at 23:00 on
/// the day before the one wanted, and reducing that to a date silently loses a
/// whole day — of lead time, in the direction that misses the delivery. This
/// was live: a part needed on 1 April 2026 with a thirty-day lead came back
/// with an order date of 1 March instead of 2 March.
///
/// `DateTime(y, m, d + n)` normalizes the day-of-month itself, over month and
/// year ends, with no hours involved for the clock change to eat.
DateTime addDays(DateTime when, int days) =>
    DateTime(when.year, when.month, when.day + days);

// ---------------------------------------------------------------------------
//  WHO CHANGED WHAT, AND WHEN
// ---------------------------------------------------------------------------
//  A job is worked on by more than one person over more than one month, and
//  the questions that come up months later are always the same two: WHEN did
//  this change, and WHO changed it. "The lead time on the projector says four
//  weeks, it said eight in March" is not an argument anybody can settle from a
//  file that only holds the current value.
//
//  So the decisions on a project — the lead times, the orders, the vendor
//  pins, the dates, the notes — are logged as they are made, against the ITEM
//  they belong to. Per item rather than per file: "what has happened to this
//  projector" is the question people actually ask, and a flat list of every
//  edit on a nine-room job cannot answer it.
//
//  WHAT IS NOT LOGGED, deliberately: the room files. A room is its own
//  document with its own backup-and-undo machinery, and shadowing every device
//  edit into the project would double-record work the room already tracks
//  while making the project file grow with changes that are not the project's.
//  This is the log of decisions made ON THE JOB.
//
//  THE TIME IS PART OF IT. Everywhere else in this file a date is a DAY, on
//  purpose — a delivery lands on the 14th, not at 14:32. A log entry is the
//  exception: two edits on the same afternoon are two edits, and reducing them
//  both to "the 14th" loses the order they happened in, which is the one thing
//  a history is for.

/// The Windows login of whoever is running the app, for attributing an edit.
///
/// `USERNAME` on Windows, `USER` elsewhere, and '' when the environment says
/// nothing. Blank is an honest answer and is recorded as such — inventing
/// 'unknown' as if it were a name would put a user called Unknown in the
/// filter list beside the real ones.
String currentUserName() {
  final env = Platform.environment;
  final name = (Platform.isWindows ? env['USERNAME'] : env['USER']) ?? '';
  return name.trim();
}

/// One recorded change.
class ProjectEdit {
  /// What was changed, as `<kind>:<id>` — `part:<masterKey>`, `todo:<id>`,
  /// `room:<id>`, `track:<id>`, or `project` for the job itself.
  ///
  /// Opaque on purpose: the log survives a part being renamed or a room being
  /// removed, and an entry whose item has since gone is still a true statement
  /// about what somebody did.
  final String itemKey;

  /// A short label for the item as it read AT THE TIME — 'DTP CrossPoint 108',
  /// 'BSS 103'. Stored rather than resolved on the way out, because the whole
  /// value of a history is that it still reads correctly after the thing it
  /// describes has been renamed or deleted.
  final String itemName;

  /// What changed about it: 'Lead time', 'Order', 'Vendor', 'Deadline'.
  final String field;

  /// What actually happened, in a sentence somebody can read six months later:
  /// 'set to 6 weeks', 'ordered on PO-1234', 'cleared'.
  final String summary;

  /// The Windows login it was done under. '' when the environment gave none.
  final String user;

  /// When — with the time on it. See the note above on why this one is not a
  /// date-only value.
  final DateTime at;

  const ProjectEdit({
    required this.itemKey,
    required this.itemName,
    required this.field,
    required this.summary,
    required this.user,
    required this.at,
  });

  /// The kind of thing this was — 'part', 'todo', 'room', 'track', 'project'.
  String get itemKind {
    final i = itemKey.indexOf(':');
    return i < 0 ? itemKey : itemKey.substring(0, i);
  }

  Map<String, dynamic> toJson() => {
    'itemKey': itemKey,
    if (itemName.isNotEmpty) 'itemName': itemName,
    'field': field,
    'summary': summary,
    if (user.isNotEmpty) 'user': user,
    'at': at.toIso8601String(),
  };

  factory ProjectEdit.fromJson(Map<String, dynamic> json) => ProjectEdit(
    itemKey: json['itemKey']?.toString() ?? '',
    itemName: json['itemName']?.toString() ?? '',
    field: json['field']?.toString() ?? '',
    summary: json['summary']?.toString() ?? '',
    user: json['user']?.toString() ?? '',
    // An entry with no readable time is dated to the epoch rather than
    // dropped: something happened, and losing the record because the stamp is
    // unreadable is worse than showing it at the bottom of the list.
    at: DateTime.tryParse(json['at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// How many entries a project keeps.
///
/// A log that grows without limit turns the project file into something that
/// takes a second to open and a scroll bar to read. Five hundred is more than
/// a year of ordinary work on one building, and the oldest go first — a job's
/// recent history is the part anybody asks about.
const int kMaxProjectHistory = 500;

/// How long a run of edits to one continuous field counts as one change.
///
/// Two minutes: long enough that typing a paragraph, stopping to think and
/// carrying on stays one entry, short enough that coming back after lunch and
/// rewriting the note is recorded as the separate decision it is.
const Duration kEditCoalesceWindow = Duration(minutes: 2);

// ---------------------------------------------------------------------------
//  A NOTE WITH A NAME ON IT
// ---------------------------------------------------------------------------
//  The job's other notes are one text field per thing — a paragraph the whole
//  team writes into, where the last person to type owns all of it. That is
//  right for a fact that stays true ("the ceiling is asbestos"), and wrong for
//  the running commentary a delivery attracts:
//
//    "2 of the 6 arrived damaged, Extron collecting"      — dstanley, 12 Mar
//    "replacements promised for the 28th"                 — jperez,   19 Mar
//    "swapped in, old ones on the pallet by the door"     — dstanley, 30 Mar
//
//  Three people, three days, three statements that are each true of the moment
//  they were written and none of which should overwrite the others. So this
//  kind of note is a LIST of signed entries rather than a field, and each one
//  carries who wrote it and when.
//
//  THE NAME IS TAKEN, NOT TYPED. It is the Windows login the app is running
//  under ([currentUserName]), for the same reason the edit log takes it: a
//  field asking who you are is a field people leave on whoever set it last.
//
//  THE TIME IS PART OF IT, with the clock on — see the note above the edit
//  log. Two notes on the same afternoon are two notes, and reducing them both
//  to a day loses the order they were written in.
//
//  NOTHING IS EDITED IN PLACE. A note that turned out to be wrong is answered
//  by another note or deleted outright; quietly rewriting one under somebody
//  else's name is the one thing a signed record must not do.

/// One signed note: what was said, who said it, when.
class ProjectNote {
  final String text;

  /// The Windows login it was written under. '' when the environment gave
  /// none — an honest blank, the same as [ProjectEdit.user].
  final String user;

  final DateTime at;

  const ProjectNote({required this.text, required this.user, required this.at});

  /// A note as it is written now: signed by whoever is at the keyboard, dated
  /// to this moment. [user] and [at] are only ever passed by tests and by the
  /// reader, which have their own answers.
  factory ProjectNote.now(String text, {String? user, DateTime? at}) =>
      ProjectNote(
        text: text.trim(),
        user: user ?? currentUserName(),
        at: at ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
    'text': text,
    if (user.isNotEmpty) 'user': user,
    'at': at.toIso8601String(),
  };

  factory ProjectNote.fromJson(Map<String, dynamic> json) => ProjectNote(
    text: json['text']?.toString() ?? '',
    user: json['user']?.toString() ?? '',
    // Dated to the epoch rather than dropped when the stamp is unreadable,
    // for the reason [ProjectEdit.fromJson] gives: somebody wrote this.
    at:
        DateTime.tryParse(json['at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// Signed notes off a hand-editable list, empty ones dropped.
List<ProjectNote> notesFromJson(Object? raw) => [
  for (final n in (raw as List? ?? []))
    if (n is Map && n['text']?.toString().trim().isNotEmpty == true)
      ProjectNote.fromJson(Map<String, dynamic>.from(n)),
];

// ---------------------------------------------------------------------------
//  WHAT HAS ACTUALLY BEEN BOUGHT
// ---------------------------------------------------------------------------
//  The schedule says what to order and when. It has no idea whether any of it
//  WAS ordered — and a warning that does not know is a warning that is wrong
//  the morning after somebody raises the first purchase order. "3 parts are
//  past their order date" stops meaning anything the moment two of them went
//  out last week, and a list that cries wolf is a list people stop opening.
//
//  So an order is recorded against the part: the PO it went out on, the day it
//  went, the date the vendor promised, and the day it turned up. That is the
//  whole model — this is a record of a decision, not a procurement system, and
//  every field on it is one somebody already has written down somewhere.
//
//  IT CHANGES WHAT THE SCHEDULE SAYS. A part on order is not late and not due;
//  it is bought, and the only question left about it is whether the promised
//  date still clears the day it is needed. A part that has arrived is finished
//  with entirely. See project_schedule.dart.

/// One part, ordered.
class PartOrder {
  /// The purchase order it went out on — free text, because a PO number is
  /// whatever the finance system calls it. Empty is allowed: "we ordered it"
  /// is worth recording before the paperwork catches up.
  final String poNumber;

  /// The day the order went in. Null means somebody has started filling this
  /// in and not said when — the part still counts as NOT ordered, because a
  /// record with no date cannot be checked against anything.
  final DateTime? orderedOn;

  /// What the vendor promised. Null when they have not said.
  ///
  /// This is the figure that makes an order worth recording rather than just
  /// ticking: an order placed in time against a promise that lands after the
  /// room needs it is a problem nobody would otherwise see until the week it
  /// mattered.
  final DateTime? expectedOn;

  /// The day it turned up. Once set, this part is done.
  final DateTime? receivedOn;

  /// Units ordered, when it was not the whole line. 0 means "all of it" —
  /// the ordinary case, and one nobody should have to type.
  final double qty;

  final String notes;

  const PartOrder({
    this.poNumber = '',
    this.orderedOn,
    this.expectedOn,
    this.receivedOn,
    this.qty = 0,
    this.notes = '',
  });

  /// True when this is a real order rather than a half-filled record.
  ///
  /// The DATE is what makes it one. A PO number with no date cannot be
  /// measured against a deadline, and treating it as ordered would take the
  /// part off the schedule on the strength of a text field.
  bool get isOrdered => orderedOn != null;

  bool get isReceived => receivedOn != null;

  /// True when the vendor's promised date lands after [needBy] — ordered, and
  /// still going to be late. False when either date is missing: this is a
  /// statement about two known dates, not a guess.
  bool arrivesLate(DateTime? needBy) =>
      expectedOn != null && needBy != null && expectedOn!.isAfter(needBy);

  PartOrder copyWith({
    String? poNumber,
    DateTime? orderedOn,
    bool clearOrderedOn = false,
    DateTime? expectedOn,
    bool clearExpectedOn = false,
    DateTime? receivedOn,
    bool clearReceivedOn = false,
    double? qty,
    String? notes,
  }) => PartOrder(
    poNumber: poNumber ?? this.poNumber,
    orderedOn: clearOrderedOn ? null : (orderedOn ?? this.orderedOn),
    expectedOn: clearExpectedOn ? null : (expectedOn ?? this.expectedOn),
    receivedOn: clearReceivedOn ? null : (receivedOn ?? this.receivedOn),
    qty: qty ?? this.qty,
    notes: notes ?? this.notes,
  );

  /// True when there is nothing on this record worth keeping — what an entry
  /// looks like after somebody clears the last field on it.
  bool get isEmpty =>
      poNumber.trim().isEmpty &&
      orderedOn == null &&
      expectedOn == null &&
      receivedOn == null &&
      qty == 0 &&
      notes.trim().isEmpty;

  Map<String, dynamic> toJson() => {
    if (poNumber.trim().isNotEmpty) 'poNumber': poNumber.trim(),
    if (orderedOn != null) 'orderedOn': formatIsoDate(orderedOn!),
    if (expectedOn != null) 'expectedOn': formatIsoDate(expectedOn!),
    if (receivedOn != null) 'receivedOn': formatIsoDate(receivedOn!),
    if (qty > 0) 'qty': qty,
    if (notes.trim().isNotEmpty) 'notes': notes.trim(),
  };

  factory PartOrder.fromJson(Map<String, dynamic> json) => PartOrder(
    poNumber: json['poNumber']?.toString() ?? '',
    orderedOn: parseIsoDate(json['orderedOn']),
    expectedOn: parseIsoDate(json['expectedOn']),
    receivedOn: parseIsoDate(json['receivedOn']),
    qty: (json['qty'] as num?)?.toDouble() ?? 0,
    notes: json['notes']?.toString() ?? '',
  );
}

// ---------------------------------------------------------------------------
//  THE PURCHASE ORDERS THE JOB WAS BOUGHT ON
// ---------------------------------------------------------------------------
//  A PO number was already recorded — on the PART, as free text, one field per
//  line of the master list. That is the right place to answer "what did this
//  switcher go out on", and it cannot answer any of the questions people
//  actually ring up about:
//
//    "what is on PO-1188?"
//    "PO-1188 was raised on the 4th — has any of it landed?"
//    "which PO has the projector mounts on it?"
//
//  Those are questions about the PO, and a number retyped into forty part
//  fields is not a thing that can be asked a question. So the job holds its
//  purchase orders as rows of their own — the number, who it went to, the day
//  it was raised, what it was raised for — and a part points at one.
//
//  THE NUMBER IS THE LINK, not the row's id. A PO number is the identifier the
//  finance system, the vendor and the packing slip all already use, so it is
//  what a part order and a delivery record store — which means a project file
//  written before any of this existed already links up correctly the first
//  time it is opened, and a delivery logged against a PO nobody has entered
//  yet still says which PO it was. The row's [ProjectPo.id] exists so the
//  number itself can be corrected without the row becoming a different row;
//  see [BuildingProject.renamePo], which carries the parts and deliveries
//  across with it.
//
//  DELETING A PO DOES NOT UNPICK ANYTHING. The parts keep the number they were
//  bought on, because they WERE bought on it — removing the row removes the
//  job's copy of the paperwork, not the history of what happened.

/// One purchase order raised on the job.
class ProjectPo {
  /// Row identity — `po1`. Stable across a renumber, and referenced by nothing
  /// except this list; see the note above on why the link is the number.
  final String id;

  /// What finance calls it — 'PO-1188', 'B24-0413'. Free text, because every
  /// institution numbers these differently, and the one thing that must not
  /// happen is a format this app insists on that nobody else uses.
  final String number;

  /// The vendor on the job's own list this went to, or '' when it went
  /// somewhere that is not one of them.
  final String vendorId;

  /// Who it went to, typed. Used when [vendorId] is blank — a distributor or
  /// a one-off supplier that never earned a row on the vendor list.
  final String vendor;

  /// The day it was raised. Null means somebody has noted the number before
  /// the paperwork went through, which is the ordinary way round.
  final DateTime? issuedOn;

  /// What the vendor promised for the order as a whole. A part can still carry
  /// its own promised date — this is the one quoted on the acknowledgement.
  final DateTime? expectedOn;

  /// What it was raised for, in the job's currency. 0 means nobody has said —
  /// NOT that it was free.
  final double amount;

  /// The running commentary, each entry signed. See [ProjectNote].
  final List<ProjectNote> notes;

  ProjectPo({
    required this.id,
    this.number = '',
    this.vendorId = '',
    this.vendor = '',
    this.issuedOn,
    this.expectedOn,
    this.amount = 0,
    List<ProjectNote>? notes,
  }) : notes = notes ?? [];

  ProjectPo copyWith({
    String? number,
    String? vendorId,
    String? vendor,
    DateTime? issuedOn,
    bool clearIssuedOn = false,
    DateTime? expectedOn,
    bool clearExpectedOn = false,
    double? amount,
    List<ProjectNote>? notes,
  }) => ProjectPo(
    id: id,
    number: number ?? this.number,
    vendorId: vendorId ?? this.vendorId,
    vendor: vendor ?? this.vendor,
    issuedOn: clearIssuedOn ? null : (issuedOn ?? this.issuedOn),
    expectedOn: clearExpectedOn ? null : (expectedOn ?? this.expectedOn),
    amount: amount ?? this.amount,
    notes: notes ?? List<ProjectNote>.from(this.notes),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'number': number.trim(),
    if (vendorId.isNotEmpty) 'vendorId': vendorId,
    if (vendor.trim().isNotEmpty) 'vendor': vendor.trim(),
    if (issuedOn != null) 'issuedOn': formatIsoDate(issuedOn!),
    if (expectedOn != null) 'expectedOn': formatIsoDate(expectedOn!),
    if (amount > 0) 'amount': amount,
    if (notes.isNotEmpty) 'notes': [for (final n in notes) n.toJson()],
  };

  factory ProjectPo.fromJson(Map<String, dynamic> json) => ProjectPo(
    id: json['id']?.toString() ?? '',
    number: json['number']?.toString() ?? '',
    vendorId: json['vendorId']?.toString() ?? '',
    vendor: json['vendor']?.toString() ?? '',
    issuedOn: parseIsoDate(json['issuedOn']),
    expectedOn: parseIsoDate(json['expectedOn']),
    amount: (json['amount'] as num?)?.toDouble() ?? 0,
    notes: notesFromJson(json['notes']),
  );
}

/// Two PO numbers compared the way a person reads them: trimmed, and without
/// caring which case somebody typed. `po-1188` and `PO-1188 ` are one PO.
String normalizePoNumber(String number) => number.trim().toUpperCase();

// ---------------------------------------------------------------------------
//  WHERE THE KIT ACTUALLY IS
// ---------------------------------------------------------------------------
//  An order ends at "it arrived". The job does not: between the loading dock
//  and the finished room there are weeks in which somebody has to be able to
//  answer "where is it" — and on a nine-room job the answer is different for
//  every pallet.
//
//    18 wall plates arrived on the 4th
//     6 of them went into BSS 103 on the 11th
//    12 are still on the shelf in the basement of Bessey
//
//  That is THREE facts about one part, and the arrival date on the order
//  record can hold exactly one of them. So an arrival is its own row: what
//  came, how many, on which PO, when, and where it is now. A part that turns
//  up in three shipments is three rows, which is what actually happened.
//
//  THE STATE IS ABOUT PLACE, not about progress. 'Delivered' is on site and
//  nobody has said where; 'In storage' is somewhere with a name on it; and
//  'Installed' is in a room, which is the only state that ends the question.
//  'Returned' is here because kit does go back — damaged, over-shipped, wrong
//  model — and a row that is deleted when it goes back takes the reason with
//  it.
//
//  IT DOES NOT REPLACE THE ORDER RECORD, and neither one is derived from the
//  other. [PartOrder] is what was BOUGHT — the PO, the dates, the promise — and
//  is what the order schedule reads. This is what ARRIVED. A part can be
//  received against its order and still have nothing logged here (nobody has
//  said where it went), or have deliveries logged against no order at all
//  (it turned up from stock). Both are true states of a real job.

/// Where one delivered lot of a part is.
enum DeliveryState {
  /// On site. Nobody has said where it went yet — the state a row starts in
  /// when it is logged off a packing slip.
  delivered('Delivered', 'on site'),

  /// Somewhere with a name on it — [ProjectDelivery.location] says where.
  stored('In storage', 'held'),

  /// In the room, on the wall, in the rack. The state that ends the question.
  installed('Installed', 'in the room'),

  /// Went back: damaged, wrong model, over-shipped. Still on the job's record
  /// because the reason is the part worth keeping.
  returned('Returned', 'sent back');

  /// What the chip and the dropdown read.
  final String label;

  /// The half-sentence form, for a row that reads as prose.
  final String phrase;

  const DeliveryState(this.label, this.phrase);
}

/// A [DeliveryState] by name, defaulting to [DeliveryState.delivered].
///
/// Tolerant because a project file is a supported thing to hand edit, and
/// "it is here" is the safe reading of a state this build does not know: the
/// row still counts as arrived rather than vanishing off the tracker.
DeliveryState deliveryStateFromName(Object? raw) {
  final name = raw?.toString().trim().toLowerCase() ?? '';
  for (final s in DeliveryState.values) {
    if (s.name.toLowerCase() == name) return s;
  }
  return DeliveryState.delivered;
}

/// One lot of one part, arrived.
class ProjectDelivery {
  final String id;

  /// The master-list part this is a delivery of — the same key a lead time, a
  /// vendor pin and an order are filed under. '' for something that arrived
  /// which is not on the list at all: a loaner, a tool, a box of connectors
  /// somebody bought on a card.
  final String partKey;

  /// What it is, as it read when the row was written. Stored rather than
  /// resolved, for the reason [ProjectEdit.itemName] is: the row still says
  /// what turned up after the part is renamed or drops off the job.
  final String itemName;

  /// The PO it came in on — see the note above on why this is the number and
  /// not a row id. '' when it arrived against no paperwork anybody has.
  final String poNumber;

  /// Bought outside the PO process — on the department card, as a one-off.
  ///
  /// NOT EVERYTHING ON A JOB IS QUOTED. A box of connectors, a replacement
  /// power supply, an adapter somebody drove out for on the Friday: these are
  /// bought on a P-Card in ten minutes, they never touch a quote, a vendor
  /// package or a purchase order, and they still turn up on a loading dock and
  /// still have to be found in June.
  ///
  /// It is a FLAG rather than the absence of a PO number, because those two
  /// say opposite things. A row with no PO and nothing else said is a row
  /// nobody has finished — somebody has the paperwork and it has not been
  /// entered — and the log should say so. A row marked one-off is COMPLETE:
  /// there is no PO, there was never going to be one, and it needs no chasing.
  /// See [needsPaperwork], which is what the warning is hung on.
  ///
  /// It changes nothing about money. This pane records what happened to kit,
  /// and a card purchase is no more part of the estimate than a delivery of
  /// something that was quoted — see the note at the head of
  /// project_deliveries_view.dart.
  final bool oneOff;

  /// How many. The whole point of a per-arrival row: 6 of the 18.
  final double qty;

  /// The day it landed. Null only on a hand-edited row — everything that logs
  /// a delivery through the app puts a date on it.
  final DateTime? deliveredOn;

  final DeliveryState state;

  /// WHERE IT WENT — the address it was delivered to, or the place it is being
  /// held: 'Bessey loading dock', 'Central Stores, 1 Campus Drive', 'the
  /// shipping container', 'my office'.
  ///
  /// Free text, and typed rather than picked. A job takes delivery wherever
  /// the vendor could get a truck to that week, and a fixed list of places
  /// would mean the one delivery that went somewhere else is the one that
  /// cannot be written down. The places this job has already used are offered
  /// as suggestions - see [BuildingProject.deliveryLocations] - so the usual
  /// two or three are one tap away without the unusual one being refused.
  ///
  /// Kept rather than cleared when the state moves on, so a row that goes from
  /// a dock to a shelf to a room still says where it had been.
  final String location;

  /// The room it went into, as a project room id. Set with
  /// [DeliveryState.installed].
  final String roomId;

  /// The day it went in. Separate from [deliveredOn] because the gap between
  /// the two is the thing storage exists to cover.
  final DateTime? installedOn;

  /// The running commentary, each entry signed. See [ProjectNote].
  final List<ProjectNote> notes;

  ProjectDelivery({
    required this.id,
    this.partKey = '',
    this.itemName = '',
    this.poNumber = '',
    this.oneOff = false,
    this.qty = 0,
    this.deliveredOn,
    this.state = DeliveryState.delivered,
    this.location = '',
    this.roomId = '',
    this.installedOn,
    List<ProjectNote>? notes,
  }) : notes = notes ?? [];

  /// True when these units are still the job's to account for. A returned lot
  /// is not — counting it as on hand is how a delivery tracker ends up saying
  /// a room has kit that went back to the vendor a month ago.
  bool get isOnHand => state != DeliveryState.returned;

  bool get isInstalled => state == DeliveryState.installed;

  /// True when nothing on this row says what bought it: no PO, and nobody has
  /// said it was a one-off.
  ///
  /// The one thing a delivery log cannot do is quietly hold rows that cannot
  /// be reconciled against anything. This is what the pane warns on and what
  /// the workbook calls out — not to refuse the row, because a pallet that
  /// turned up is a fact whether or not the paperwork has caught up, but so
  /// that "we have no idea what this was bought on" is a sentence the job says
  /// out loud rather than one it hides.
  bool get needsPaperwork => poNumber.trim().isEmpty && !oneOff;

  /// What bought it, in the words the card and the sheet both use.
  String get boughtOnText => poNumber.trim().isNotEmpty
      ? 'PO ${poNumber.trim()}'
      : oneOff
      ? 'One-off purchase - P-Card'
      : 'No PO recorded';

  /// Where this lot is, in the fewest words that are still true.
  ///
  /// The PLACE is named wherever there is one, in every state that has not
  /// ended the question: 'on site' with nothing after it is the answer that
  /// sends somebody walking round a campus looking for a pallet.
  String get whereText => switch (state) {
    DeliveryState.stored => location.trim().isEmpty
        ? 'In storage'
        : 'In storage - ${location.trim()}',
    DeliveryState.installed => 'Installed',
    DeliveryState.returned => 'Returned',
    DeliveryState.delivered => location.trim().isEmpty
        ? 'On site'
        : 'On site - ${location.trim()}',
  };

  ProjectDelivery copyWith({
    String? partKey,
    String? itemName,
    String? poNumber,
    bool? oneOff,
    double? qty,
    DateTime? deliveredOn,
    bool clearDeliveredOn = false,
    DeliveryState? state,
    String? location,
    String? roomId,
    DateTime? installedOn,
    bool clearInstalledOn = false,
    List<ProjectNote>? notes,
  }) => ProjectDelivery(
    id: id,
    partKey: partKey ?? this.partKey,
    itemName: itemName ?? this.itemName,
    poNumber: poNumber ?? this.poNumber,
    oneOff: oneOff ?? this.oneOff,
    qty: qty ?? this.qty,
    deliveredOn: clearDeliveredOn ? null : (deliveredOn ?? this.deliveredOn),
    state: state ?? this.state,
    location: location ?? this.location,
    roomId: roomId ?? this.roomId,
    installedOn: clearInstalledOn ? null : (installedOn ?? this.installedOn),
    notes: notes ?? List<ProjectNote>.from(this.notes),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    if (partKey.isNotEmpty) 'partKey': partKey,
    if (itemName.trim().isNotEmpty) 'itemName': itemName.trim(),
    if (poNumber.trim().isNotEmpty) 'poNumber': poNumber.trim(),
    if (oneOff) 'oneOff': true,
    if (qty != 0) 'qty': qty,
    if (deliveredOn != null) 'deliveredOn': formatIsoDate(deliveredOn!),
    'state': state.name,
    if (location.trim().isNotEmpty) 'location': location.trim(),
    if (roomId.isNotEmpty) 'roomId': roomId,
    if (installedOn != null) 'installedOn': formatIsoDate(installedOn!),
    if (notes.isNotEmpty) 'notes': [for (final n in notes) n.toJson()],
  };

  factory ProjectDelivery.fromJson(Map<String, dynamic> json) =>
      ProjectDelivery(
        id: json['id']?.toString() ?? '',
        partKey: json['partKey']?.toString() ?? '',
        itemName: json['itemName']?.toString() ?? '',
        poNumber: json['poNumber']?.toString() ?? '',
        oneOff: json['oneOff'] == true,
        qty: (json['qty'] as num?)?.toDouble() ?? 0,
        deliveredOn: parseIsoDate(json['deliveredOn']),
        state: deliveryStateFromName(json['state']),
        location: json['location']?.toString() ?? '',
        roomId: json['roomId']?.toString() ?? '',
        installedOn: parseIsoDate(json['installedOn']),
        notes: notesFromJson(json['notes']),
      );
}

// ---------------------------------------------------------------------------
//  TRACKS: THE JOB HAS MORE THAN ONE DEADLINE
// ---------------------------------------------------------------------------
//  A building does not get finished on one date. The conduit, the backboxes and
//  the screen mounts go in while the walls are open; the racks, the switchers
//  and the cameras go in months later, after the ceiling is closed and the room
//  is painted. Those are two different deliveries with two different dates, and
//  a single project deadline can only ever be right for one of them.
//
//  So a job carries TRACKS: named phases, each with its own delivery date. A
//  part belongs to one, and its order-by date is worked back from that track's
//  date rather than from the job's. Laid out together they are the thing this
//  exists for — you can see the infrastructure order going in three months
//  before the tech order, and whether the two line up.
//
//  THE LIST IS NOT FIXED. Two are offered on a new job because they are the
//  split nearly every job has, but they are ordinary rows: rename them, delete
//  them, add "Phase 2" or "Furniture" or whatever this job is actually divided
//  into. A track a job does not use costs nothing, and a job that never adds
//  one behaves exactly as it did before tracks existed — everything falls back
//  to the project deadline.

/// One phase of a job, with the date its equipment has to be on site by.
class ProjectTrack {
  final String id;

  /// What this phase is called on the timeline — 'Infrastructure', 'Tech
  /// install', 'Phase 2'.
  final String name;

  /// When this phase's equipment has to be delivered, or null when nobody has
  /// said and it should fall back to the job's own deadline.
  final DateTime? deadline;

  /// When this phase is FINISHED - installed, commissioned and handed over -
  /// or null while nobody has committed to one.
  ///
  /// A second date rather than a second meaning for [deadline], because they
  /// are two different promises to two different people: the delivery date is
  /// what the supplier is held to and the one every order date is worked back
  /// from, and this is what the building is told. On a phased job they can be
  /// weeks apart, and a timeline sorted by one is not the timeline sorted by
  /// the other.
  final DateTime? completion;

  /// A line of explanation for the people reading the timeline — what belongs
  /// in this phase and why it is separate.
  final String notes;

  const ProjectTrack({
    required this.id,
    required this.name,
    this.deadline,
    this.completion,
    this.notes = '',
  });

  ProjectTrack copyWith({
    String? name,
    DateTime? deadline,
    bool clearDeadline = false,
    DateTime? completion,
    bool clearCompletion = false,
    String? notes,
  }) => ProjectTrack(
    id: id,
    name: name ?? this.name,
    deadline: clearDeadline ? null : (deadline ?? this.deadline),
    completion: clearCompletion ? null : (completion ?? this.completion),
    notes: notes ?? this.notes,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (deadline != null) 'deadline': formatIsoDate(deadline!),
    if (completion != null) 'completion': formatIsoDate(completion!),
    if (notes.trim().isNotEmpty) 'notes': notes.trim(),
  };

  factory ProjectTrack.fromJson(Map<String, dynamic> json) => ProjectTrack(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    deadline: parseIsoDate(json['deadline']),
    completion: parseIsoDate(json['completion']),
    notes: json['notes']?.toString() ?? '',
  );
}

/// The split nearly every job has, offered on a new project the way
/// [starterVendors] offers the usual vendor split — as a starting point to
/// edit, not a structure to work around.
List<ProjectTrack> starterTracks(BuildingProject project) => [
  ProjectTrack(
    id: project.nextTrackId(),
    name: 'Infrastructure',
    notes: 'Conduit, backboxes, mounts, floor boxes - contractor work, '
        'arranged through facilities, that goes in while the walls are '
        'open.',
  ),
  ProjectTrack(
    id: project.nextTrackId(),
    name: 'Tech install',
    notes: 'Racks, switchers, displays, cameras - everything that lands after '
        'the room is closed up.',
  ),
];

// ---------------------------------------------------------------------------
//  THE JOB'S OWN TO-DO LIST
// ---------------------------------------------------------------------------
//  Everything else this app records is a FACT about the building: what is in
//  the room, what it costs, who sells it, when it has to be ordered. A job also
//  accumulates a second kind of thing entirely — "the client wants the second
//  display moved", "chase Extron about the DTP lead time", "check whether 214
//  is still in scope" — and until now those lived in an email thread, a
//  notebook, or nowhere.
//
//  They belong on the project because they are about the JOB rather than about
//  any one room, and because the project file is the document that gets opened
//  when somebody picks the job back up after three weeks on something else.
//
//  DELIBERATELY PLAIN. A note, a state, when it was written, and a date it has
//  to be done by. No assignees and no priority ladder — a job list that needs
//  its own workflow is one people stop filling in.
//
//  THE DUE DATE IS OPTIONAL AND MEANS SOMETHING WHEN IT IS SET. Most notes on a
//  job do not have a deadline; the ones that do have a real one ("the client
//  wants an answer before Friday", "this has to be decided before the order
//  goes in"), and those are the ones that need to surface on their own rather
//  than waiting to be scrolled past. An item with no date is not late and never
//  nags — see [ProjectTodo.isOverdue].

/// Where one job note stands.
enum ProjectTodoState {
  /// Still to do — the default, and what the count on the tab is counting.
  open,

  /// Waiting on somebody else. Still open work, and not something the person
  /// looking at the list can act on today, which is the whole distinction.
  blocked,

  /// Finished. Kept rather than deleted: "when did we agree to move that
  /// display" is a question that gets asked, and a list that forgets its own
  /// history cannot answer it.
  done,
}

const Map<ProjectTodoState, String> kProjectTodoStateLabels = {
  ProjectTodoState.open: 'To do',
  ProjectTodoState.blocked: 'Waiting on',
  ProjectTodoState.done: 'Done',
};

ProjectTodoState _todoStateFromName(String name) => ProjectTodoState.values
    .firstWhere(
      (s) => s.name == name,
      // An unreadable state is OPEN rather than done. A hand-edited file that
      // loses a note's state should surface the note, not bury it.
      orElse: () => ProjectTodoState.open,
    );

/// One thing somebody has to do on this job.
class ProjectTodo {
  final String id;

  /// What has to happen, in whatever words it was said in.
  final String text;

  final ProjectTodoState state;

  /// When it was first written down. Shown as an age, because the useful
  /// question about an open item is how long it has been open.
  final DateTime created;

  /// When it was marked done, null while it is not. Kept so a finished list
  /// still says when each thing actually happened.
  final DateTime? completed;

  /// When this has to be done by, or null when it is simply on the list.
  ///
  /// Most notes never get one and should not: a deadline on everything is a
  /// deadline on nothing. The ones that carry a date carry a real one, which
  /// is what makes [isOverdue] worth surfacing on its own.
  final DateTime? due;

  /// The room this is about, by [ProjectRoomRef.id], or '' when it is not
  /// about one room.
  ///
  /// Optional on purpose: forcing a room onto a note about the job would file
  /// them all against whichever room happened to come first.
  final String roomId;

  /// A scope somebody typed, for the notes that are about neither the whole
  /// job nor one room.
  ///
  /// A real job does not divide cleanly into those two. "Extron", "the punch
  /// list", "phase 2", "the AV closet", "whoever is doing the conduit" — these
  /// are all things a handful of notes belong to, and a dropdown of rooms can
  /// name none of them. Rather than guess at a taxonomy, the third option is a
  /// box: whatever is typed becomes the label, and notes sharing a label read
  /// as a group.
  ///
  /// [roomId] wins when both are set, because a room is a thing the project
  /// actually knows about and a typed label is not.
  final String scopeLabel;

  const ProjectTodo({
    required this.id,
    required this.text,
    this.state = ProjectTodoState.open,
    required this.created,
    this.completed,
    this.due,
    this.roomId = '',
    this.scopeLabel = '',
  });

  /// True when this note is about the job as a whole — neither a room nor a
  /// typed scope.
  bool get isWholeJob => roomId.isEmpty && scopeLabel.trim().isEmpty;

  /// What the note is filed under, for a caller that cannot resolve a room id.
  /// Returns '' for a whole-job note; [roomId] wins over [scopeLabel].
  String scopeKey() => roomId.isNotEmpty ? roomId : scopeLabel.trim();

  bool get isDone => state == ProjectTodoState.done;

  /// Still work: to do or waiting on somebody.
  bool get isOpen => state != ProjectTodoState.done;

  /// Past its date and not finished.
  ///
  /// A FINISHED item is never overdue however late it was — the list is not
  /// there to keep score — and an item with no date never is, so adding notes
  /// freely never produces a list that nags.
  bool isOverdue([DateTime? asOf]) =>
      isOpen && due != null && due!.isBefore(dateOnly(asOf ?? DateTime.now()));

  /// Days until [due]: negative when it has gone, null when there is no date.
  int? daysUntilDue([DateTime? asOf]) => due == null
      ? null
      : daysBetween(dateOnly(asOf ?? DateTime.now()), due!);

  ProjectTodo copyWith({
    String? text,
    ProjectTodoState? state,
    DateTime? completed,
    bool clearCompleted = false,
    DateTime? due,
    bool clearDue = false,
    String? roomId,
    String? scopeLabel,
  }) => ProjectTodo(
    id: id,
    text: text ?? this.text,
    state: state ?? this.state,
    created: created,
    completed: clearCompleted ? null : (completed ?? this.completed),
    due: clearDue ? null : (due ?? this.due),
    roomId: roomId ?? this.roomId,
    scopeLabel: scopeLabel ?? this.scopeLabel,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'state': state.name,
    'created': formatIsoDate(created),
    if (completed != null) 'completed': formatIsoDate(completed!),
    if (due != null) 'due': formatIsoDate(due!),
    if (roomId.isNotEmpty) 'roomId': roomId,
    if (scopeLabel.trim().isNotEmpty) 'scopeLabel': scopeLabel.trim(),
  };

  factory ProjectTodo.fromJson(Map<String, dynamic> json) => ProjectTodo(
    id: json['id']?.toString() ?? '',
    text: json['text']?.toString() ?? '',
    state: _todoStateFromName(json['state']?.toString() ?? ''),
    // A note with no date on it is still a note. Today rather than dropping
    // it: the text is the thing worth keeping.
    created: parseIsoDate(json['created']) ?? today(),
    completed: parseIsoDate(json['completed']),
    due: parseIsoDate(json['due']),
    roomId: json['roomId']?.toString() ?? '',
    scopeLabel: json['scopeLabel']?.toString().trim() ?? '',
  );
}

/// A company the job buys from, and what it is assumed to quote.
class ProjectVendor {
  final String id;
  final String name;

  /// Who the RFQ goes to. Written onto the vendor's own quote sheet, because
  /// the file gets emailed and the person emailing it should not have to go
  /// looking for the address in a different system.
  final String contact;

  /// Anything the quote request should say — contract number, terms, the fact
  /// that this one needs a delivery date before it can be approved.
  final String notes;

  /// The makers this vendor quotes, matched case-insensitively against a
  /// part's manufacturer.
  final List<String> manufacturers;

  /// The catalog categories this vendor quotes — 'Camera', 'Display',
  /// 'USB Extender'. The other half of the rule, and the half the split is
  /// usually described with: "everything Extron" is a maker, but "cameras,
  /// screens and USB interfaces" is three categories from four different
  /// makers, and no list of manufacturers expresses it without naming every
  /// brand anybody might ever specify.
  ///
  /// Matched case-insensitively, and by PREFIX as well as in full, because
  /// the catalog's categories are finer than a purchasing split is: a rule
  /// for 'Camera' should claim 'Camera - PTZ' without the buyer having to
  /// enumerate the variants a catalog import invented.
  final List<String> categories;

  /// Both lists empty = assigned by hand only, which is a legitimate setup:
  /// an integrator quoting a mixed bag of parts has nothing about the parts
  /// themselves that identifies it.
  bool get hasRules => manufacturers.isNotEmpty || categories.isNotEmpty;

  /// The colour this vendor's parts are marked in, as an ARGB int, or null to
  /// let one be derived from the name.
  ///
  /// WHY A COLOUR IS A PROPERTY OF THE VENDOR. A vendor IS an order: every
  /// part tagged to it goes on one purchase order, to one company, on one
  /// date. Reading a master list of two hundred parts and asking "which of
  /// these am I ordering from whom" is the question the list is opened for,
  /// and the answer was a name in a narrow column that had to be read row by
  /// row. A colour answers it down the whole page at once.
  ///
  /// ASSIGNABLE, because the buyer's own colours mean things this app cannot
  /// know — the vendor that is always late, the one the contract covers, the
  /// order that has already been placed. Null is not "no colour": a vendor
  /// nobody has assigned one still gets a stable colour off its name, so a
  /// list is legible before anybody has set anything up.
  ///
  /// Stored as an int rather than a Color to keep this file free of Flutter,
  /// the same way the cable colours are stored on a bundle.
  final int? color;

  const ProjectVendor({
    required this.id,
    required this.name,
    this.contact = '',
    this.notes = '',
    this.manufacturers = const [],
    this.categories = const [],
    this.color,
  });

  /// [clearColor] rather than passing null, which cannot be told from "leave
  /// it alone" — and the two mean opposite things here: back to the derived
  /// colour, or keep the one that was assigned.
  ProjectVendor copyWith({
    String? name,
    String? contact,
    String? notes,
    List<String>? manufacturers,
    List<String>? categories,
    int? color,
    bool clearColor = false,
  }) => ProjectVendor(
    id: id,
    name: name ?? this.name,
    contact: contact ?? this.contact,
    notes: notes ?? this.notes,
    manufacturers: manufacturers ?? this.manufacturers,
    categories: categories ?? this.categories,
    color: clearColor ? null : (color ?? this.color),
  );

  /// True when this vendor's manufacturer rules claim [manufacturer].
  bool quotesManufacturer(String manufacturer) {
    final needle = manufacturer.trim().toLowerCase();
    if (needle.isEmpty) return false;
    for (final m in manufacturers) {
      if (m.trim().toLowerCase() == needle) return true;
    }
    return false;
  }

  /// True when this vendor's category rules claim [category], in full or as
  /// the head of a finer one ('Camera' claims 'Camera - PTZ').
  bool quotesCategory(String category) {
    final needle = category.trim().toLowerCase();
    if (needle.isEmpty) return false;
    for (final c in categories) {
      final rule = c.trim().toLowerCase();
      if (rule.isEmpty) continue;
      if (needle == rule) return true;
      // Only on a word boundary: a 'Mic' rule must not swallow 'Microwave
      // link', and a 'Camera' rule must not swallow 'Cameraman kit'.
      if (needle.startsWith(rule) &&
          RegExp(r'[^a-z0-9]').hasMatch(needle[rule.length])) {
        return true;
      }
    }
    return false;
  }

  /// True when either rule claims the part. Manufacturer is checked first
  /// only for reporting — for the answer itself, either is enough.
  bool quotes({String manufacturer = '', String category = ''}) =>
      quotesManufacturer(manufacturer) || quotesCategory(category);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (contact.isNotEmpty) 'contact': contact,
    if (notes.isNotEmpty) 'notes': notes,
    if (manufacturers.isNotEmpty) 'manufacturers': manufacturers,
    if (categories.isNotEmpty) 'categories': categories,
    if (color != null) 'color': color,
  };

  factory ProjectVendor.fromJson(Map<String, dynamic> json) {
    List<String> list(String key) => [
      for (final m in (json[key] as List? ?? []))
        if (m.toString().trim().isNotEmpty) m.toString().trim(),
    ];
    final raw = json['color'];
    return ProjectVendor(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Vendor',
      contact: json['contact']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      manufacturers: list('manufacturers'),
      categories: list('categories'),
      // Anything that is not a number is no assignment at all, which reads as
      // the derived colour rather than as black.
      color: raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? ''),
    );
  }
}

// ---------------------------------------------------------------------------
//  THE BUILDING'S OWN DRAWINGS
// ---------------------------------------------------------------------------

/// One drawing the whole JOB refers to: an architectural floor plan, a
/// reflected ceiling plan, a riser diagram, the electrical sheet somebody was
/// sent as a PDF.
///
/// NOT the room's floor plan. That one is a picture you drag locations and
/// call-outs onto and it belongs to one config - see floor_plan_view.dart.
/// This is the set of sheets the BUILDING came with: they are read, pointed
/// at and argued over, and they are the same sheets for every room on the job.
/// Until there was somewhere to put them they lived in an email, which means
/// the person who picks the job up next does not have them.
///
/// A REFERENCE, exactly like a room. The project does not copy the file, own
/// it, or lock it: a plan set is hundreds of megabytes and gets reissued
/// halfway through a job, and a copy taken in March is the drawing somebody
/// installs the wrong thing from in June. Stored relative to the project file
/// when it sits under the same folder tree, so the job travels onto a laptop
/// or into a backup with its drawings still attached.
class ProjectPlan {
  final String id;

  /// The drawing itself, stored the same way a room's config is - see
  /// [BuildingProject.storePath] and [BuildingProject.resolvePath].
  final String filePath;

  /// What the sheet is called on the job - 'Level 2 RCP', 'A-101 as-built'.
  /// Blank falls back to the file's own name, which is usually already the
  /// sheet number.
  final String label;

  /// Free text on the row - 'issued 3 Feb, supersedes the December set'.
  final String notes;

  const ProjectPlan({
    required this.id,
    required this.filePath,
    this.label = '',
    this.notes = '',
  });

  ProjectPlan copyWith({String? filePath, String? label, String? notes}) =>
      ProjectPlan(
        id: id,
        filePath: filePath ?? this.filePath,
        label: label ?? this.label,
        notes: notes ?? this.notes,
      );

  /// What to call this sheet: the label if there is one, otherwise the file
  /// name, which on a drawing set is nearly always the sheet number.
  String get displayName {
    if (label.trim().isNotEmpty) return label.trim();
    final base = path.basename(filePath);
    return base.isEmpty ? filePath : base;
  }

  /// Lower-case extension with no dot - 'pdf', 'png'. What decides which
  /// viewer opens it.
  String get extension {
    final ext = path.extension(filePath);
    return ext.isEmpty ? '' : ext.substring(1).toLowerCase();
  }

  /// Whether the app can show this sheet itself rather than handing it to
  /// whatever the machine opens the file type with.
  bool get isViewable => kViewablePlanExtensions.contains(extension);

  bool get isPdf => extension == 'pdf';

  Map<String, dynamic> toJson() => {
        'id': id,
        'filePath': filePath,
        if (label.isNotEmpty) 'label': label,
        if (notes.isNotEmpty) 'notes': notes,
      };

  factory ProjectPlan.fromJson(Map<String, dynamic> json) => ProjectPlan(
        id: json['id']?.toString() ?? '',
        filePath: json['filePath']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        notes: json['notes']?.toString() ?? '',
      );
}

/// The sheets the app opens in its own viewer: PDFs through the same pdfium
/// the module manuals use, and the ordinary image formats Flutter decodes.
/// Anything else - a DWG, a Revit model - is still worth listing and is handed
/// to the machine's own opener.
const Set<String> kViewablePlanExtensions = {
  'pdf',
  'png',
  'jpg',
  'jpeg',
  'gif',
  'bmp',
  'webp',
};

// ---------------------------------------------------------------------------
//  ROOMS IN THE PROJECT
// ---------------------------------------------------------------------------

/// A ROOM ON THE PLAN THAT HAS NO CONFIG.
///
/// Most of an estate has never been through this app. The rooms that have are
/// the ones somebody rebuilt recently; the other forty are a projector, a
/// screen and a wall plate that went in in 2014, and the only facts anybody
/// has about them are the year and roughly what a room like that costs to do.
///
/// Those rooms are the LARGER half of a refresh plan, and leaving them off it
/// because nobody has drawn them yet makes the plan read as a fraction of the
/// real ask — which is the one direction a budget must not be wrong in.
///
/// So a room can be typed in: a name, when it was last done, how long it is
/// expected to last, and what it costs to do again. No config, no diagram, no
/// parts list. It ages on exactly the same cycle as a drawn room and lands in
/// the same year columns; what it does NOT do is claim to know what is in it.
///
/// THE MONEY IS A BASE COST unless somebody types a figure. A room nobody has
/// itemised is priced the way the rest of this app prices what it has not
/// itemised — off the base-cost card, by category — and every figure derived
/// from it says it is an estimate. See [replacementCost] and [category].
class ManualRoom {
  final String id;

  /// What the room is called on the plan — 'BSS 214'.
  final String name;

  /// When it was last done, or null when nobody has recorded it. A room with
  /// no date has nothing to age and shows up as unsurveyed, the same as a
  /// drawn position with no install date.
  final DateTime? installedOn;

  /// How long this room is expected to last. 0 takes the blanket cycle, so a
  /// room typed in without an opinion follows the same default everything
  /// else does.
  final int lifeYears;

  /// What it costs to do the room again. 0 means "price it off the base-cost
  /// card", which is what a room nobody has itemised gets.
  final double replacementCost;

  /// The base-cost line this room is priced from when [replacementCost] is 0 —
  /// a category on the shared card. Empty falls back to the whole-room line if
  /// the card has one, and to nothing if it does not, which reports as
  /// unpriced rather than as free.
  final String category;

  final String notes;

  const ManualRoom({
    required this.id,
    required this.name,
    this.installedOn,
    this.lifeYears = 0,
    this.replacementCost = 0,
    this.category = '',
    this.notes = '',
  });

  ManualRoom copyWith({
    String? name,
    DateTime? installedOn,
    bool clearInstalledOn = false,
    int? lifeYears,
    double? replacementCost,
    String? category,
    String? notes,
  }) => ManualRoom(
    id: id,
    name: name ?? this.name,
    installedOn:
        clearInstalledOn ? null : (installedOn ?? this.installedOn),
    lifeYears: lifeYears ?? this.lifeYears,
    replacementCost: replacementCost ?? this.replacementCost,
    category: category ?? this.category,
    notes: notes ?? this.notes,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (installedOn != null) 'installedOn': formatIsoDate(installedOn!),
    if (lifeYears > 0) 'lifeYears': lifeYears,
    if (replacementCost > 0) 'replacementCost': replacementCost,
    if (category.trim().isNotEmpty) 'category': category.trim(),
    if (notes.trim().isNotEmpty) 'notes': notes.trim(),
  };

  /// The room TYPE this estimate was priced against, off the master refresh
  /// sheet, or '' when the note does not name one.
  ///
  /// The importer writes it into the notes - 'LEC-Lecture  ·  capacity 44  ·
  /// RYG estimate for 2 Projector' - because a note is the one field on a line
  /// item that survives every round trip and needs no schema. Read back out
  /// here so it can be matched against [RoomPreset.sourceName] rather than
  /// left as prose nobody parses.
  ///
  /// Anything after the type is an annotation the importer added about the
  /// master sheet ('last update unknown'), so it stops at the separator.
  String get sourceType {
    final match = RegExp(r'RYG estimate for (.+)$').firstMatch(notes.trim());
    if (match == null) return '';
    return match.group(1)!.split('·').first.trim();
  }

  static ManualRoom fromJson(Map<String, dynamic> json) => ManualRoom(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    installedOn: parseIsoDate(json['installedOn']),
    lifeYears: (json['lifeYears'] as num?)?.toInt() ?? 0,
    replacementCost: (json['replacementCost'] as num?)?.toDouble() ?? 0,
    category: json['category']?.toString() ?? '',
    notes: json['notes']?.toString() ?? '',
  );
}

/// One room on the job: where its config lives, and whether it counts.
class ProjectRoomRef {
  final String id;

  /// The room's config.json, stored RELATIVE to the project file whenever it
  /// sits under the same folder tree — see [resolvePath] and
  /// [BuildingProject.storePath].
  ///
  /// A building's rooms and its project file travel together: onto a laptop,
  /// into a backup, across to whoever is covering next week. Absolute paths
  /// break every one of those moves, and break them silently — the project
  /// opens, the rooms are all "missing", and the total reads as zero rather
  /// than as an error.
  final String configPath;

  /// What to call this room when the config's own name is wrong or absent.
  /// Blank means "read it from the config", which is what almost every room
  /// wants — renaming the room should rename it on the quote.
  final String label;

  /// Off the rollup without being removed from the job.
  ///
  /// An alternate is a real thing on a real bid: two versions of the same
  /// lecture hall, one with the camera package and one without, both priced,
  /// one of them chosen. Deleting the loser loses the work; leaving it in the
  /// total makes the building read double.
  final bool included;

  /// Free text on the row — "phase 2", "waiting on the ceiling survey".
  final String notes;

  const ProjectRoomRef({
    required this.id,
    required this.configPath,
    this.label = '',
    this.included = true,
    this.notes = '',
  });

  ProjectRoomRef copyWith({
    String? configPath,
    String? label,
    bool? included,
    String? notes,
  }) => ProjectRoomRef(
    id: id,
    configPath: configPath ?? this.configPath,
    label: label ?? this.label,
    included: included ?? this.included,
    notes: notes ?? this.notes,
  );

  /// The name to show before the room has been read off disk — the label if
  /// there is one, otherwise the file's own name, which is nearly always the
  /// room ("BSS_101_config.json").
  String get fallbackName {
    if (label.trim().isNotEmpty) return label.trim();
    final base = path.basenameWithoutExtension(configPath);
    return base.isEmpty ? configPath : base;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'configPath': configPath,
    if (label.isNotEmpty) 'label': label,
    if (!included) 'included': false,
    if (notes.isNotEmpty) 'notes': notes,
  };

  factory ProjectRoomRef.fromJson(Map<String, dynamic> json) => ProjectRoomRef(
    id: json['id']?.toString() ?? '',
    configPath: json['configPath']?.toString() ?? '',
    label: json['label']?.toString() ?? '',
    included: json['included'] != false,
    notes: json['notes']?.toString() ?? '',
  );
}

// ---------------------------------------------------------------------------
//  THE MASTER-LIST PART KEY
// ---------------------------------------------------------------------------

/// What makes two lines in two different rooms THE SAME PART on one order.
///
/// The estimate's own line key cannot do this job. It is built for a single
/// room — a model-less device is keyed on its node id, a cable line on the
/// length it happens to be cut to — so the same product in two rooms can key
/// two different ways, and merging on it would put four displays on one line
/// in one room and four separate lines in the building.
///
/// So the merge runs down the identifiers in the order a purchasing department
/// would use them:
///
///   1. PART NUMBER, when it is a real one. Two entries that order under
///      60-1439-13 are one line however they are named on two drawings, and
///      this is the only identifier the vendor's own system shares with ours.
///   2. MODEL, for a part the catalog has no ordering code for yet. Still
///      unambiguous within a maker's range.
///   3. MAKER AND DESCRIPTION, for a hand-typed line with neither. Two rooms
///      that both typed "Ceiling speaker pair" merge; a room that typed
///      "Ceiling speakers" does not, and that is the honest outcome — the app
///      cannot know they are the same thing and guessing would quietly halve
///      an order.
///
/// [kind] is part of the key so a cable and a device that happen to share a
/// description never merge across the section boundary the quote is read by.
String masterPartKey({
  required String kind,
  String partNumber = '',
  String model = '',
  String manufacturer = '',
  String description = '',
}) {
  if (AvDeviceLibrary.isRealPartNumber(partNumber)) {
    return '$kind|pn:${AvDeviceLibrary.normalizePartNumber(partNumber)}';
  }
  final m = model.trim().toLowerCase();
  if (m.isNotEmpty) return '$kind|model:$m';
  final maker = manufacturer.trim().toLowerCase();
  final desc = description.trim().toLowerCase();
  return '$kind|desc:$maker~$desc';
}

// ---------------------------------------------------------------------------
//  SPARES THE JOB BUYS, RATHER THAN A ROOM
// ---------------------------------------------------------------------------
//  A room's own spares live in that room's cost file: a fourth display for a
//  room with three drawn is a decision about THAT room, made on its Cost tab,
//  and it travels with the room to whatever job the room ends up on.
//
//  A BUILDING'S spares are not that. "Two spare projectors for the campus
//  store" is a decision about the JOB, it belongs to no room, and there is no
//  room file it could be written into without lying about which room is buying
//  it. So it lives here, on the project, where it can also be re-pointed at a
//  room - or off one - without rewriting anything on disk.
//
//  Both kinds end up on the same master line and in the same total. See
//  [MasterPartLine.spareQty] and [MasterPartLine.buildingSpareQty].

/// The spare cover a job starts at when nobody has said otherwise.
///
/// A SUGGESTION AND NOT A DEFAULT POLICY. It is the figure the old typed-in
/// target defaulted to on every job that ever set one, it is what the box on
/// the spares page opens showing, and it is one press away again after
/// somebody has moved it. See [BuildingProject.spareCoverTarget] for what it
/// does and, just as importantly, what it does not.
const double kSuggestedSpareCover = 0.10;

/// One spare the JOB is buying, for a room or for the building.
class ProjectSpare {
  final String id;

  /// The master-list key of the part this is a spare FOR - see
  /// [masterPartKey]. What ties it to the line it is counted onto.
  final String partKey;

  /// The part as it read when the spare was added.
  ///
  /// Stored rather than resolved on the way out, for the same reason a history
  /// entry stores its item name: a spare for a product that has since been
  /// swapped out of every room is still a spare somebody decided to buy, and a
  /// row that went blank would be money on the quote with nothing beside it.
  final String description;
  final String model;
  final String manufacturer;
  final String partNumber;

  /// How many are being bought.
  final double qty;

  /// The room this is a spare for, or '' for the building as a whole.
  ///
  /// The one field that moves. "Move it off the room" is this going blank, and
  /// nothing else about the spare changes - not its part, not its quantity,
  /// not what it cost.
  final String roomId;

  /// Why, in the words of whoever asked for it. 'To cover a repair', 'the
  /// dean wants one on the shelf'.
  final String note;

  const ProjectSpare({
    required this.id,
    required this.partKey,
    required this.description,
    this.model = '',
    this.manufacturer = '',
    this.partNumber = '',
    this.qty = 1,
    this.roomId = '',
    this.note = '',
  });

  /// True when this is the building's spare rather than a room's.
  bool get forBuilding => roomId.trim().isEmpty;

  ProjectSpare copyWith({
    double? qty,
    String? roomId,
    String? note,
  }) => ProjectSpare(
    id: id,
    partKey: partKey,
    description: description,
    model: model,
    manufacturer: manufacturer,
    partNumber: partNumber,
    qty: qty ?? this.qty,
    // Not `?? this.roomId`: '' is a real answer here and means the building,
    // so a move off a room has to be able to say it.
    roomId: roomId ?? this.roomId,
    note: note ?? this.note,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'partKey': partKey,
    'description': description,
    if (model.isNotEmpty) 'model': model,
    if (manufacturer.isNotEmpty) 'manufacturer': manufacturer,
    if (partNumber.isNotEmpty) 'partNumber': partNumber,
    'qty': qty,
    if (roomId.isNotEmpty) 'roomId': roomId,
    if (note.trim().isNotEmpty) 'note': note.trim(),
  };

  factory ProjectSpare.fromJson(Map<String, dynamic> json) => ProjectSpare(
    id: json['id']?.toString() ?? '',
    partKey: json['partKey']?.toString() ?? '',
    description: json['description']?.toString() ?? '',
    model: json['model']?.toString() ?? '',
    manufacturer: json['manufacturer']?.toString() ?? '',
    partNumber: json['partNumber']?.toString() ?? '',
    // A spare with no readable quantity is one of it. Dropping the row would
    // lose a decision; reading it as zero would put a line of nothing on the
    // quote.
    qty: (json['qty'] as num?)?.toDouble() ?? 1,
    roomId: json['roomId']?.toString() ?? '',
    note: json['note']?.toString() ?? '',
  );
}

// ---------------------------------------------------------------------------
//  THE PROJECT
// ---------------------------------------------------------------------------

/// A building's worth of rooms, quoted as one job.
class BuildingProject {
  /// What the job is called on the front of the quote.
  String name;

  /// The building, as a code from buildings.json or as a name typed in. Not
  /// resolved here: the project is written and read with no app around it, and
  /// a code that cannot be looked up should still come back out unchanged.
  String building;

  /// The number this job is filed under - what a PO, an invoice and a
  /// timesheet all quote back. Called a PROJECT number rather than a job
  /// number because that is what it is called on the paperwork it has to
  /// match.
  String projectNumber;

  /// Who the job is FOR. A department, a dean, facilities - the people whose
  /// room this is and who have to agree to what is on the quote.
  ///
  /// Called a stakeholder rather than a customer because this shop's work is
  /// for the university: nobody on the other side of one of these quotes is
  /// buying, and nobody could take their money elsewhere.
  String stakeholder;

  String notes;

  /// The symbol every figure in the rollup is written in. Rooms carry their
  /// own — a project total can only be one number, so the project's symbol
  /// wins and a room quoted in something else is flagged rather than silently
  /// added (see ProjectEstimate.mixedCurrency).
  String currency;

  final List<ProjectRoomRef> rooms;

  // -------------------------------------------------------------------------
  //  THE ESTATE THIS JOB IS PART OF
  // -------------------------------------------------------------------------
  //  A campus is a list of jobs somebody assembled and named — see
  //  campus_file.dart. The assembly was one-way: the campus knew its jobs and
  //  a job knew nothing about the campus, so opening the campus from inside a
  //  building started a sheet of ONE building and left somebody to go and find
  //  the other thirty-three on disk. Every time.
  //
  //  So the job remembers which sheet it is on, and Campus opens THAT sheet.
  //  It is a path and nothing else: no names, no totals, no copy of the list.
  //  The campus file is still the document, still re-read off disk, and a job
  //  whose campus has been moved or deleted falls back to the sheet of one
  //  rather than failing — the pointer is a convenience, never a dependency.

  /// The campus sheet this job is on, RELATIVE to the project file wherever it
  /// sits under the same folder tree — the same bargain the room paths make,
  /// so a campus folder that is copied to a laptop still opens. '' for a job
  /// nobody has put on a sheet.
  String campusFile;

  // -------------------------------------------------------------------------
  //  THE COPY SOMEBODY ELSE CAN READ
  // -------------------------------------------------------------------------
  //  This app runs on one machine, and the people who ask about a job do not
  //  sit at it. The stakeholder wants to see the number, the technician on
  //  site wants to know whether the mounts landed, and the answer to both has
  //  been "let me get back to you" or an .xlsx emailed round that is out of
  //  date the moment anything changes.
  //
  //  So a job can PUBLISH itself: the workbook, written into a folder that
  //  OneDrive or Google Drive already syncs, under the same file name every
  //  time. That last part is the whole trick — a file that keeps its name
  //  keeps its share link, so "here is the job" is a URL somebody sends once
  //  and everybody afterwards opens on the current figures.
  //
  //  IT IS A COPY, AND IT ONLY GOES ONE WAY. Nothing is read back: an edit
  //  made in Excel Online or Google Sheets changes the published sheet and
  //  nothing else, and the next publish overwrites it. That is a deliberate
  //  limit rather than an unfinished one — a document that quietly takes
  //  changes back from a copy several people can edit is a document that
  //  loses work without anybody being told.

  /// The folder the published copy is written into — a local path, inside
  /// whatever OneDrive or Google Drive keeps in step with the cloud. '' for a
  /// job nobody has published.
  ///
  /// Absolute and machine-specific ON PURPOSE, unlike the room paths: it names
  /// a sync client's folder on the machine doing the publishing, and rewriting
  /// it relative to the project file would break the moment the project moved.
  /// A job opened on another machine simply has nowhere to publish until
  /// somebody points it at a folder there.
  String onlineFolder;

  /// Rewrite the published copy every time the project file is saved.
  ///
  /// OFF unless somebody asks for it. Publishing on save is the difference
  /// between a copy people trust and one they check the date on first — but it
  /// writes to a folder that syncs to other people's screens, and doing that
  /// unasked, every save, is not a decision this app gets to make for a job.
  ///
  /// It cannot be on without [onlineFolder], because there would be nowhere
  /// for it to write.
  bool onlineAutoPublish;

  /// When the published copy was last written, or null when it never has been.
  ///
  /// Kept so the app can say how stale the online version is. A published copy
  /// that is three weeks behind is worse than none, because the person reading
  /// it has no way to know — which is the whole reason this is recorded and
  /// shown rather than left to be worked out from a file date somebody would
  /// have to go and look at.
  DateTime? onlinePublishedAt;

  /// Rooms on the refresh plan that have no config file — see [ManualRoom].
  /// They are counted, aged and budgeted; they are not priced, ordered or
  /// drawn, because there is nothing in them to price.
  final List<ManualRoom> manualRooms;

  final List<ProjectVendor> vendors;

  /// Whose job each piece of scope is - see [ResponsibilityItem].
  ///
  /// On the PROJECT rather than on each room because that is the level it is
  /// agreed at: one matrix is issued for the building and the contractor bids
  /// the totals off it. A per-room copy would be fourteen documents that have
  /// to agree with each other.
  final List<ResponsibilityItem> responsibility;

  /// Core component key (see [masterPartKey]) -> vendor id, for the parts
  /// somebody has pinned by hand. Beats the manufacturer rules; an entry whose
  /// vendor has since been deleted resolves to untagged rather than to a
  /// dangling name.
  final Map<String, String> partVendors;

  // -------------------------------------------------------------------------
  //  WHEN IT HAS TO BE BOUGHT
  // -------------------------------------------------------------------------
  //  A quote answers "what does the building cost". It does not answer the
  //  question that actually sinks installs, which is "what should already have
  //  been ordered by now" — and that one is only answerable at the JOB level,
  //  because the deadline is the building's and the lead time is the order's.
  //
  //  Three facts, and the schedule is derived from them rather than stored:
  //  the date the job needs everything by, how long each part takes to come,
  //  and the parts that are wanted EARLIER than the rest. Nothing here holds a
  //  computed date — see project_schedule.dart — so moving the deadline moves
  //  every order-by date with it instead of leaving stale ones behind.

  /// The date the job needs everything delivered by, or null when nobody has
  /// said. Date only: a delivery lands on a day, not at a time, and carrying a
  /// clock reading through a save-and-reload is how a deadline drifts across
  /// midnight into the day before.
  DateTime? deliveryDeadline;

  /// Core component key -> lead time in calendar days.
  ///
  /// CALENDAR days rather than working days, because that is the unit vendors
  /// quote in ("6-8 weeks") and converting a quoted figure into working days
  /// at the keyboard is an invitation to get it wrong in the safe-looking
  /// direction. An absent entry means nobody has asked the vendor yet, which
  /// the schedule reports as unknown rather than assuming zero — a part
  /// silently treated as available tomorrow is exactly the part that holds up
  /// an install.
  final Map<String, int> partLeadTimes;

  /// Core component key -> the date THAT part has to arrive by, when it is not
  /// the project's own deadline.
  ///
  /// Screens, mounts, floor boxes and conduit go in while the walls are still
  /// open, weeks before the rack is delivered — so "everything by the 14th" is
  /// wrong for them in the one direction that cannot be recovered from. An
  /// entry here overrides [deliveryDeadline] for that part only, and its
  /// absence means the part is wanted with everything else.
  final Map<String, DateTime> partNeedBy;

  /// The job's own list of things to do — see [ProjectTodo]. Newest first is
  /// how it is shown, but stored in the order it was written so a reordering
  /// on screen never rewrites the file.
  final List<ProjectTodo> todos;

  /// The phases this job delivers in, in timeline order — see [ProjectTrack].
  /// Empty on a job that has never used them, which behaves exactly as it did
  /// before tracks existed.
  final List<ProjectTrack> tracks;

  /// Core component key -> track id. A part with no entry is delivered with
  /// the job as a whole, against [deliveryDeadline].
  final Map<String, String> partTracks;

  /// Every recorded change, oldest first. See [ProjectEdit].
  final List<ProjectEdit> history;

  /// Core component key -> what has been bought against it. See [PartOrder].
  ///
  /// A part with no entry has not been ordered, which is what makes the
  /// schedule's warnings about it worth reading.
  final Map<String, PartOrder> partOrders;

  /// The purchase orders raised on this job - see [ProjectPo]. In the order
  /// they were entered, which is close enough to the order they were raised in
  /// and is what somebody scanning the list expects.
  final List<ProjectPo> purchaseOrders;

  /// Everything that has ARRIVED, one row per lot - see [ProjectDelivery].
  /// Empty on a job nobody is tracking deliveries on, which behaves exactly as
  /// it did before this existed.
  final List<ProjectDelivery> deliveries;

  /// The building's own drawings - see [ProjectPlan]. References, not copies,
  /// and in the order they were added, which on a drawing set is the order
  /// somebody wants to read them in.
  final List<ProjectPlan> plans;

  /// Spares the JOB is buying, for a room or for the building. See
  /// [ProjectSpare]. Empty on a job that only uses the rooms' own spares,
  /// which behaves exactly as it did before this existed.
  final List<ProjectSpare> spares;

  /// THE SHARE OF WHAT THIS JOB INSTALLS THAT IT MEANS TO HOLD SPARE.
  ///
  /// A fraction, not a percentage: 0.1 is ten per cent. Per JOB rather than
  /// per app, because it is a decision about this building - a lecture block
  /// with twelve identical rooms and a shelf of spares is not the same job as
  /// one theatre with one of everything in it.
  ///
  /// IT IS A RECOMMENDATION AND NOT A RULE. Nothing is flagged for being under
  /// it; a part with NO spare at all is the only thing on the spares page
  /// drawn as a fault, and that is true whatever this is set to. What the
  /// figure does is turn "this has a spare" into "this has enough", which is
  /// the question the one-spare rule cannot answer and the reason a percentage
  /// is worth having at all. The old typed-in target was removed because it
  /// FLAGGED against this number, which made forty wall plates into forty
  /// faults on every job.
  ///
  /// NOUGHT IS A REAL ANSWER, and a useful one: the recommendation never asks
  /// for less than one of anything, so a target of nought is exactly "one of
  /// everything the job installs" - the rule and nothing more.
  ///
  /// Starts at [kSuggestedSpareCover] on a job nobody has told.
  double spareCoverTarget;


  /// Counters behind [nextRoomId] / [nextVendorId], persisted so ids stay
  /// unique across sessions — a reused id would re-point somebody's hand
  /// vendor tags at a different room.
  int _roomCounter;
  int _manualRoomCounter;
  int _vendorCounter;
  int _todoCounter;
  int _trackCounter;
  int _spareCounter;
  int _planCounter;
  int _responsibilityCounter;
  int _poCounter;
  int _deliveryCounter;

  BuildingProject({
    this.name = '',
    this.building = '',
    this.projectNumber = '',
    this.stakeholder = '',
    this.notes = '',
    this.currency = r'$',
    List<ProjectRoomRef>? rooms,
    this.campusFile = '',
    this.onlineFolder = '',
    this.onlineAutoPublish = false,
    this.onlinePublishedAt,
    List<ManualRoom>? manualRooms,
    List<ProjectVendor>? vendors,
    List<ResponsibilityItem>? responsibility,
    Map<String, String>? partVendors,
    this.deliveryDeadline,
    Map<String, int>? partLeadTimes,
    Map<String, DateTime>? partNeedBy,
    List<ProjectTodo>? todos,
    List<ProjectTrack>? tracks,
    Map<String, String>? partTracks,
    Map<String, PartOrder>? partOrders,
    List<ProjectSpare>? spares,
    this.spareCoverTarget = kSuggestedSpareCover,
    List<ProjectPlan>? plans,
    List<ProjectPo>? purchaseOrders,
    List<ProjectDelivery>? deliveries,
    List<ProjectEdit>? history,
    int roomCounter = 0,
    int manualRoomCounter = 0,
    int vendorCounter = 0,
    int todoCounter = 0,
    int trackCounter = 0,
    int spareCounter = 0,
    int planCounter = 0,
    int responsibilityCounter = 0,
    int poCounter = 0,
    int deliveryCounter = 0,
  }) : rooms = rooms ?? [],
       manualRooms = manualRooms ?? [],
       vendors = vendors ?? [],
       responsibility = responsibility ?? [],
       partVendors = partVendors ?? {},
       partLeadTimes = partLeadTimes ?? {},
       partNeedBy = partNeedBy ?? {},
       todos = todos ?? [],
       tracks = tracks ?? [],
       partTracks = partTracks ?? {},
       partOrders = partOrders ?? {},
       spares = spares ?? [],
       plans = plans ?? [],
       purchaseOrders = purchaseOrders ?? [],
       deliveries = deliveries ?? [],
       history = history ?? [],
       _roomCounter = roomCounter,
       _manualRoomCounter = manualRoomCounter,
       _vendorCounter = vendorCounter,
       _todoCounter = todoCounter,
       _trackCounter = trackCounter,
       _spareCounter = spareCounter,
       _planCounter = planCounter,
       _responsibilityCounter = responsibilityCounter,
       _poCounter = poCounter,
       _deliveryCounter = deliveryCounter;

  bool get isEmpty =>
      rooms.isEmpty &&
      manualRooms.isEmpty &&
      vendors.isEmpty &&
      partVendors.isEmpty &&
      deliveryDeadline == null &&
      partLeadTimes.isEmpty &&
      partNeedBy.isEmpty &&
      todos.isEmpty &&
      tracks.isEmpty &&
      partTracks.isEmpty &&
      partOrders.isEmpty &&
      spares.isEmpty &&
      plans.isEmpty &&
      purchaseOrders.isEmpty &&
      deliveries.isEmpty &&
      onlineFolder.trim().isEmpty &&
      name.trim().isEmpty &&
      building.trim().isEmpty &&
      projectNumber.trim().isEmpty &&
      stakeholder.trim().isEmpty &&
      notes.trim().isEmpty;

  /// The rooms that count toward the total.
  List<ProjectRoomRef> get includedRooms =>
      [for (final r in rooms) if (r.included) r];

  String nextRoomId() => 'room${++_roomCounter}';

  /// Ids for the rooms with no config. Their OWN counter, not the room one: a
  /// manual room and a config room are two different things on two different
  /// lists, and sharing a counter would make 'room7' mean either.
  String nextManualRoomId() => 'manual${++_manualRoomCounter}';

  /// Adds a room that has no config file, and returns it. See [ManualRoom].
  ManualRoom addManualRoom({
    required String name,
    DateTime? installedOn,
    int lifeYears = 0,
    double replacementCost = 0,
    String category = '',
    String notes = '',
  }) {
    final room = ManualRoom(
      id: nextManualRoomId(),
      name: name.trim(),
      installedOn: installedOn,
      lifeYears: lifeYears,
      replacementCost: replacementCost,
      category: category.trim(),
      notes: notes.trim(),
    );
    manualRooms.add(room);
    return room;
  }

  /// Replaces one by id. Nothing happens for an id that is not on the job.
  void updateManualRoom(ManualRoom room) {
    final at = manualRooms.indexWhere((r) => r.id == room.id);
    if (at < 0) return;
    manualRooms[at] = room;
  }

  void removeManualRoom(String id) =>
      manualRooms.removeWhere((r) => r.id == id);
  String nextVendorId() => 'vendor${++_vendorCounter}';
  String nextTodoId() => 'todo${++_todoCounter}';
  String nextTrackId() => 'track${++_trackCounter}';
  String nextSpareId() => 'spare${++_spareCounter}';
  String nextPlanId() => 'plan${++_planCounter}';
  String nextPoId() => 'po${++_poCounter}';
  String nextDeliveryId() => 'del${++_deliveryCounter}';
  String nextResponsibilityId() => 'resp${++_responsibilityCounter}';

  // -------------------------------------------------------------------------
  //  SPARES THE JOB BUYS
  // -------------------------------------------------------------------------

  /// Adds a spare and returns it. See [ProjectSpare].
  ProjectSpare addSpare({
    required String partKey,
    required String description,
    String model = '',
    String manufacturer = '',
    String partNumber = '',
    double qty = 1,
    String roomId = '',
    String note = '',
  }) {
    final spare = ProjectSpare(
      id: nextSpareId(),
      partKey: partKey,
      description: description,
      model: model,
      manufacturer: manufacturer,
      partNumber: partNumber,
      // A spare of none is not a spare. Clamped rather than refused: the box
      // it is typed into can be emptied mid-edit, and a row that vanished
      // while somebody was retyping its quantity would be worse.
      qty: qty <= 0 ? 1 : qty,
      roomId: roomId,
      note: note,
    );
    spares.add(spare);
    return spare;
  }

  ProjectSpare? spareById(String id) {
    for (final s in spares) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Changes one spare. [roomId] of '' moves it to the building, which is the
  /// whole point of it being a separate field - see [ProjectSpare.roomId].
  void updateSpare(String id, {double? qty, String? roomId, String? note}) {
    final at = spares.indexWhere((s) => s.id == id);
    if (at < 0) return;
    spares[at] = spares[at].copyWith(
      qty: qty == null ? null : (qty <= 0 ? 1 : qty),
      roomId: roomId,
      note: note,
    );
  }

  void removeSpare(String id) => spares.removeWhere((s) => s.id == id);

  /// The job's spares for one room, or for the building when [roomId] is ''.
  List<ProjectSpare> sparesFor(String roomId) =>
      [for (final s in spares) if (s.roomId == roomId) s];

  /// Every spare the job buys for the building rather than for a room.
  List<ProjectSpare> get buildingSpares =>
      [for (final s in spares) if (s.forBuilding) s];

  /// A room leaving the job takes its spares with it - but only the ones that
  /// were FOR that room. A building spare is nobody's room's and stays.
  ///
  /// Called when a room is removed, so a spare cannot outlive the room it was
  /// bought for and quietly go on being quoted under a name nothing resolves.
  void dropSparesForRoom(String roomId) {
    if (roomId.isEmpty) return;
    spares.removeWhere((s) => s.roomId == roomId);
  }

  // -------------------------------------------------------------------------
  //  THE TO-DO LIST
  // -------------------------------------------------------------------------

  /// Open items — to do, and waiting on somebody. What the tab's badge counts.
  List<ProjectTodo> get openTodos => [for (final t in todos) if (t.isOpen) t];

  /// Items to do that are not waiting on anybody: the ones somebody can pick
  /// up right now.
  List<ProjectTodo> get actionableTodos =>
      [for (final t in todos) if (t.state == ProjectTodoState.open) t];

  /// Open items that have gone past their date.
  List<ProjectTodo> overdueTodos([DateTime? asOf]) =>
      [for (final t in todos) if (t.isOverdue(asOf)) t];

  /// Open items due within [days] and not yet past — the ones to start on.
  List<ProjectTodo> todosDueSoon({int days = 7, DateTime? asOf}) {
    final now = dateOnly(asOf ?? DateTime.now());
    return [
      for (final t in todos)
        if (t.isOpen && t.due != null && !t.due!.isBefore(now))
          if (daysBetween(now, t.due!) <= days) t,
    ];
  }

  /// Adds a note and hands back its id. Blank text adds nothing — an empty row
  /// on a to-do list is a row somebody has to work out how to delete.
  String addTodo(
    String text, {
    String roomId = '',
    String scopeLabel = '',
    DateTime? created,
    DateTime? due,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';
    final id = nextTodoId();
    todos.add(
      ProjectTodo(
        id: id,
        text: trimmed,
        created: dateOnly(created ?? DateTime.now()),
        due: due == null ? null : dateOnly(due),
        roomId: roomId,
        // A room and a typed label are alternatives, not both: the room is the
        // stronger statement, so naming one clears the other rather than
        // leaving a note filed under two things at once.
        scopeLabel: roomId.isNotEmpty ? '' : scopeLabel.trim(),
      ),
    );
    return id;
  }

  /// Every scope somebody has typed on this job, in use order, deduplicated
  /// case-insensitively.
  ///
  /// What the scope box offers as suggestions: a label is only useful when
  /// more than one note carries it, and retyping "punch list" with a capital P
  /// would quietly split the group in two.
  List<String> get todoScopeLabels {
    final seen = <String>{};
    final out = <String>[];
    for (final t in todos) {
      final label = t.scopeLabel.trim();
      if (label.isEmpty) continue;
      if (seen.add(label.toLowerCase())) out.add(label);
    }
    return out;
  }

  /// Sets the date one note has to be done by, or clears it so it is simply on
  /// the list.
  void setTodoDue(String id, DateTime? date) {
    final i = todos.indexWhere((t) => t.id == id);
    if (i < 0) return;
    todos[i] = todos[i].copyWith(
      due: date == null ? null : dateOnly(date),
      clearDue: date == null,
    );
  }

  /// Moves one note to [state], stamping or clearing its completion date.
  ///
  /// Re-opening something clears the date rather than leaving the old one on
  /// it: a note that says it was finished in March and is sitting in the open
  /// column is a note that will be read wrong.
  void setTodoState(String id, ProjectTodoState state, {DateTime? when}) {
    final i = todos.indexWhere((t) => t.id == id);
    if (i < 0) return;
    todos[i] = todos[i].copyWith(
      state: state,
      completed: state == ProjectTodoState.done
          ? dateOnly(when ?? DateTime.now())
          : null,
      clearCompleted: state != ProjectTodoState.done,
    );
  }

  /// Rewrites one note's text. Blank is ignored — see [addTodo].
  void setTodoText(String id, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final i = todos.indexWhere((t) => t.id == id);
    if (i >= 0) todos[i] = todos[i].copyWith(text: trimmed);
  }

  /// Files one note against a room. Naming a room clears any typed scope — the
  /// two are alternatives.
  void setTodoRoom(String id, String roomId) {
    final i = todos.indexWhere((t) => t.id == id);
    if (i < 0) return;
    todos[i] = todos[i].copyWith(
      roomId: roomId,
      scopeLabel: roomId.isEmpty ? todos[i].scopeLabel : '',
    );
  }

  /// Files one note under a scope somebody typed — "Extron", "punch list",
  /// "phase 2". Blank puts it back on the job as a whole.
  ///
  /// Clears [ProjectTodo.roomId] for the same reason [setTodoRoom] clears this:
  /// a note belongs to one thing.
  void setTodoScopeLabel(String id, String label) {
    final i = todos.indexWhere((t) => t.id == id);
    if (i < 0) return;
    final trimmed = label.trim();
    todos[i] = todos[i].copyWith(
      scopeLabel: trimmed,
      roomId: trimmed.isEmpty ? todos[i].roomId : '',
    );
  }

  void removeTodo(String id) => todos.removeWhere((t) => t.id == id);

  /// Drops every finished note. The one bulk action the list offers, because
  /// tidying a long done-list one row at a time is the reason people stop
  /// marking things done.
  int clearDoneTodos() {
    final before = todos.length;
    todos.removeWhere((t) => t.isDone);
    return before - todos.length;
  }

  ProjectVendor? vendorById(String id) {
    if (id.isEmpty) return null;
    for (final v in vendors) {
      if (v.id == id) return v;
    }
    return null;
  }

  ProjectRoomRef? roomById(String id) {
    for (final r in rooms) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Which vendor quotes a part, and why.
  ///
  /// The hand pin first — it exists precisely to beat the rules. Then the
  /// MANUFACTURER rules before the CATEGORY ones, because that is the
  /// stronger statement: "we buy Extron direct" is a purchasing relationship,
  /// while "the reseller does screens" is a default for everything nobody has
  /// a relationship for. A job that buys Extron direct and screens from a
  /// reseller must not send the Extron display to the reseller just because
  /// it is a screen — and without this ordering, whichever vendor happened to
  /// be created first would decide.
  ///
  /// Within a tier, the first matching vendor wins. That is deliberate and the
  /// UI says so: two vendors both claiming Extron is a setup mistake, and
  /// picking the earlier one gives a stable, explainable answer instead of an
  /// arbitrary one that moves when a vendor is renamed.
  ({ProjectVendor? vendor, VendorTagSource source}) vendorForPart(
    String partKey, {
    String manufacturer = '',
    String category = '',
  }) {
    final pinnedId = partVendors[partKey];
    if (pinnedId != null && pinnedId.isNotEmpty) {
      final v = vendorById(pinnedId);
      // A pin to a vendor that has been deleted is dead, not sticky: fall
      // through to the rules so the part lands somewhere real.
      if (v != null) return (vendor: v, source: VendorTagSource.pinned);
    }
    for (final v in vendors) {
      if (v.quotesManufacturer(manufacturer)) {
        return (vendor: v, source: VendorTagSource.manufacturerRule);
      }
    }
    for (final v in vendors) {
      if (v.quotesCategory(category)) {
        return (vendor: v, source: VendorTagSource.categoryRule);
      }
    }
    return (vendor: null, source: VendorTagSource.none);
  }

  /// Vendors whose rules overlap — the setup mistake [vendorForPart] resolves
  /// by order. Surfaced so it can be fixed rather than lived with.
  ///
  /// Only LIKE rules collide. A manufacturer rule and a category rule that
  /// both cover the same part are not a mistake, they are the normal case the
  /// tier ordering exists for, and reporting them would bury the real
  /// conflicts under noise on every project.
  List<({String rule, String kind, List<ProjectVendor> vendors})>
  get vendorConflicts {
    final out = <({String rule, String kind, List<ProjectVendor> vendors})>[];

    void collide(String kind, List<String> Function(ProjectVendor) rulesOf) {
      final byRule = <String, List<ProjectVendor>>{};
      final display = <String, String>{};
      for (final v in vendors) {
        for (final r in rulesOf(v)) {
          final key = r.trim().toLowerCase();
          if (key.isEmpty) continue;
          display.putIfAbsent(key, () => r.trim());
          byRule.putIfAbsent(key, () => []).add(v);
        }
      }
      byRule.forEach((key, vs) {
        if (vs.length > 1) {
          out.add((rule: display[key] ?? key, kind: kind, vendors: vs));
        }
      });
    }

    collide('Manufacturer', (v) => v.manufacturers);
    collide('Category', (v) => v.categories);
    out.sort((a, b) {
      final byKind = a.kind.compareTo(b.kind);
      return byKind != 0
          ? byKind
          : a.rule.toLowerCase().compareTo(b.rule.toLowerCase());
    });
    return out;
  }

  /// Pins [partKey] to [vendorId], or clears the pin when it is blank.
  void pinPart(String partKey, String vendorId) {
    if (vendorId.isEmpty) {
      partVendors.remove(partKey);
    } else {
      partVendors[partKey] = vendorId;
    }
  }

  // -------------------------------------------------------------------------
  //  TRACKS
  // -------------------------------------------------------------------------

  ProjectTrack? trackById(String id) {
    if (id.isEmpty) return null;
    for (final t in tracks) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// The track [partKey] is delivered on, or null when it goes with the job.
  ///
  /// A pin naming a track that has since been deleted resolves to null rather
  /// than to a dangling id, the same way a deleted vendor does.
  ProjectTrack? trackForPart(String partKey) =>
      trackById(partTracks[partKey] ?? '');

  /// The date [partKey] has to be on site by, before its own date is taken
  /// into account: its track's deadline, or the job's.
  DateTime? trackDeadlineForPart(String partKey) =>
      trackForPart(partKey)?.deadline ?? deliveryDeadline;

  // -------------------------------------------------------------------------
  //  WHOSE JOB EACH PIECE OF IT IS
  // -------------------------------------------------------------------------
  //  See responsibility_matrix.dart. The list is edited the way the vendors
  //  and the phases are — add, replace, remove — so the pane stays a form and
  //  the rules about ids stay here with the ids.

  ResponsibilityItem? responsibilityById(String id) {
    for (final item in responsibility) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// Adds a line to the matrix. A blank scope is named for its position rather
  /// than refused, so a row added by mistake is a row somebody can see and
  /// delete instead of a press that appeared to do nothing.
  ResponsibilityItem addResponsibilityItem(
    String scope, {
    String furnishedBy = '',
    String installedBy = '',
    String neededBy = '',
    String work = '',
    String productLink = '',
    String notes = '',
  }) {
    final item = ResponsibilityItem(
      id: nextResponsibilityId(),
      scope: scope.trim().isEmpty
          ? 'Scope item ${responsibility.length + 1}'
          : scope.trim(),
      furnishedBy: furnishedBy,
      installedBy: installedBy,
      neededBy: neededBy,
      work: work,
      productLink: productLink,
      notes: notes,
    );
    responsibility.add(item);
    return item;
  }

  void updateResponsibilityItem(ResponsibilityItem item) {
    final i = responsibility.indexWhere((r) => r.id == item.id);
    if (i >= 0) responsibility[i] = item;
  }

  void removeResponsibilityItem(String id) {
    responsibility.removeWhere((r) => r.id == id);
  }

  /// Moves a line up or down the sheet by [delta] places.
  ///
  /// The ORDER IS CONTENT on a document like this: it is read top to bottom on
  /// site and it is grouped the way the work is sequenced — everything in the
  /// ceiling together, everything in the rack together — so it has to be
  /// arrangeable rather than left in the order somebody happened to type.
  void moveResponsibilityItem(String id, int delta) {
    final from = responsibility.indexWhere((r) => r.id == id);
    if (from < 0) return;
    final to = (from + delta).clamp(0, responsibility.length - 1);
    if (to == from) return;
    responsibility.insert(to, responsibility.removeAt(from));
  }

  /// Puts one line at [toIndex], where a drag dropped it.
  ///
  /// The other half of [moveResponsibilityItem]. A step at a time is right for
  /// a keyboard and for the buttons on the editor; dragging a column across a
  /// sheet of thirty is one gesture and has to land where it was let go, not
  /// twenty-nine places later.
  void reorderResponsibilityItem(String id, int toIndex) {
    final from = responsibility.indexWhere((r) => r.id == id);
    if (from < 0) return;
    final to = toIndex.clamp(0, responsibility.length - 1);
    if (to == from) return;
    responsibility.insert(to, responsibility.removeAt(from));
  }

  /// Puts the usual lines on an empty matrix, skipping any scope already
  /// there. Returns how many were added.
  ///
  /// Skipping by name rather than refusing outright so this can be pressed on
  /// a half-filled matrix to top it up — which is what somebody does after
  /// deleting the four lines that did not apply and wondering what else there
  /// was.
  int addStarterResponsibilityItems() {
    final have = {
      for (final item in responsibility) item.scope.trim().toLowerCase(),
    };
    var added = 0;
    for (final starter in kStarterResponsibilityItems) {
      if (have.contains(starter.scope.toLowerCase())) continue;
      addResponsibilityItem(
        starter.scope,
        furnishedBy: starter.furnishedBy,
        installedBy: starter.installedBy,
        neededBy: 'TBD',
        work: starter.work,
      );
      added++;
    }
    return added;
  }

  /// The room columns the matrix is drawn with, in project order.
  ///
  /// [names] is room id -> what to call it, from a caller that has read the
  /// configs — the building code and the room number, `BSS 101`, which is what
  /// is written on the door and on the work order. Without it the fallback is
  /// the label somebody typed on the job and then the FILE STEM, and a matrix
  /// headed `BSS_101_config` is one nobody can check against a drawing.
  ///
  /// Passed in rather than resolved here because a project is loaded and
  /// edited with no app around it: the room files may be on a share that is
  /// briefly offline, and a column that vanished because of that would take
  /// the quantities under it out of view.
  List<({String id, String name})> responsibilityRoomColumns({
    Map<String, String> names = const {},
  }) => [
    for (final room in rooms)
      (
        id: room.id,
        name: switch ((
          names[room.id]?.trim() ?? '',
          room.label.trim(),
        )) {
          (final code, _) when code.isNotEmpty => code,
          (_, final label) when label.isNotEmpty => label,
          _ => room.fallbackName,
        },
      ),
    // THE ROOMS WITH NO CONFIG ARE STILL ROOMS ON THE JOB - see [ManualRoom].
    //
    // A matrix is agreed for a BUILDING, and on a job imported off a refresh
    // spreadsheet every room in that building is a line item: the sheet had
    // its headings, its parties and its scope lines, and not one column to put
    // them against. The thing the document exists to settle - whose job is
    // this, in which room - could not be written down at all.
    //
    // Their ids are their own ('manual1', never 'room1'), so a quantity
    // recorded against one can never be read as another room's - and a line
    // item that is later replaced by a real room config takes its column with
    // it rather than leaving a stray one behind.
    for (final line in manualRooms)
      (
        id: line.id,
        name: line.name.trim().isEmpty ? line.id : line.name.trim(),
      ),
  ];

  ProjectTrack addTrack(String name, {DateTime? deadline, String notes = ''}) {
    final track = ProjectTrack(
      id: nextTrackId(),
      name: name.trim().isEmpty ? 'Phase ${tracks.length + 1}' : name.trim(),
      deadline: deadline == null ? null : dateOnly(deadline),
      notes: notes,
    );
    tracks.add(track);
    return track;
  }

  void updateTrack(ProjectTrack track) {
    final i = tracks.indexWhere((t) => t.id == track.id);
    if (i >= 0) tracks[i] = track;
  }

  /// Sets one track's delivery date, or clears it so the track falls back to
  /// the job's own deadline.
  void setTrackDeadline(String id, DateTime? date) {
    final i = tracks.indexWhere((t) => t.id == id);
    if (i < 0) return;
    tracks[i] = tracks[i].copyWith(
      deadline: date == null ? null : dateOnly(date),
      clearDeadline: date == null,
    );
  }

  /// Sets one phase's completion date, or clears it.
  void setTrackCompletion(String id, DateTime? date) {
    final i = tracks.indexWhere((t) => t.id == id);
    if (i < 0) return;
    tracks[i] = tracks[i].copyWith(
      completion: date == null ? null : dateOnly(date),
      clearCompletion: date == null,
    );
  }

  /// Moves the phase at [from] to sit at [to], the way somebody dragged it.
  ///
  /// THE ORDER IS A DECISION, not a derivation: a job's phases are read in the
  /// order the work happens in, which is not always the order of their dates -
  /// a long-lead order can be placed for a phase that lands last. So the list
  /// keeps whatever order it was put in, and sorting by a date is an ACTION
  /// that rewrites it rather than a view that hides it.
  void moveTrack(int from, int to) {
    if (from < 0 || from >= tracks.length) return;
    if (to < 0 || to >= tracks.length || to == from) return;
    final moved = tracks.removeAt(from);
    tracks.insert(to, moved);
  }

  /// Puts the phases in date order. Undated ones keep to the end rather than
  /// sorting as the beginning of time, which would put every phase nobody has
  /// committed to yet in front of the ones that are booked.
  void sortTracksByDate({required bool byCompletion}) {
    DateTime? keyOf(ProjectTrack t) => byCompletion ? t.completion : t.deadline;
    tracks.sort((a, b) {
      final da = keyOf(a);
      final db = keyOf(b);
      if (da == null && db == null) {
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      if (da == null) return 1;
      if (db == null) return -1;
      final byDate = da.compareTo(db);
      return byDate != 0
          ? byDate
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  /// Drops a track and every part pinned to it. Leaving the pins would file
  /// parts against a phase with no row to click, which is how a part
  /// disappears off a timeline nobody can find it on.
  void removeTrack(String id) {
    tracks.removeWhere((t) => t.id == id);
    partTracks.removeWhere((_, v) => v == id);
  }

  // -------------------------------------------------------------------------
  //  THE LOG
  // -------------------------------------------------------------------------

  /// Records one change. [at] and [user] are for tests and for replaying an
  /// import; ordinary callers let them default to now and the Windows login.
  ///
  /// DELIBERATELY NOT PART OF [isEmpty]. A project whose only content is a log
  /// of changes to nothing is an empty project — otherwise a job that was
  /// built up and then emptied would refuse to be treated as blank, and the
  /// "nothing to save" path would stop working.
  void logEdit({
    required String itemKey,
    required String field,
    required String summary,
    String itemName = '',
    String? user,
    DateTime? at,
    bool coalesce = false,
  }) => appendEdit(
    history,
    itemKey: itemKey,
    field: field,
    summary: summary,
    itemName: itemName,
    user: user,
    at: at,
    coalesce: coalesce,
  );

  /// Everything recorded against one item, NEWEST FIRST — which is the order
  /// "what has happened to this" is read in.
  List<ProjectEdit> historyFor(String itemKey) => [
    for (final h in history.reversed)
      if (h.itemKey == itemKey) h,
  ];

  /// The whole log, newest first.
  List<ProjectEdit> get recentHistory => history.reversed.toList();

  /// Every login that has touched this job, in the order they first appear.
  /// What the History pane offers as a filter.
  List<String> get historyUsers {
    final seen = <String>{};
    final out = <String>[];
    for (final h in history) {
      if (h.user.isEmpty) continue;
      if (seen.add(h.user.toLowerCase())) out.add(h.user);
    }
    return out;
  }

  /// What has been bought against [partKey], or null when nothing has.
  PartOrder? orderForPart(String partKey) => partOrders[partKey];

  /// Records an order against [partKey]. An empty record removes the entry
  /// rather than leaving a blank one that would take the part off the
  /// schedule while saying nothing about when it was bought.
  void setPartOrder(String partKey, PartOrder? order) {
    if (order == null || order.isEmpty) {
      partOrders.remove(partKey);
    } else {
      partOrders[partKey] = order;
    }
  }

  /// Parts with an order against them that has not arrived yet.
  List<String> get onOrderKeys => [
    for (final e in partOrders.entries)
      if (e.value.isOrdered && !e.value.isReceived) e.key,
  ];

  // --- the purchase orders --------------------------------------------------

  /// The PO row with [id], or null.
  ProjectPo? poById(String id) {
    for (final po in purchaseOrders) {
      if (po.id == id) return po;
    }
    return null;
  }

  /// The PO row carrying [number], compared the way a person reads a PO
  /// number — see [normalizePoNumber]. Null when the job has no row for it,
  /// which is a normal state: a part can carry a number nobody has entered.
  ProjectPo? poByNumber(String number) {
    final needle = normalizePoNumber(number);
    if (needle.isEmpty) return null;
    for (final po in purchaseOrders) {
      if (normalizePoNumber(po.number) == needle) return po;
    }
    return null;
  }

  /// Every PO number this job mentions ANYWHERE — the rows, the part orders
  /// and the delivery log — each in the spelling it was first seen in, in the
  /// order they turn up.
  ///
  /// What a "which PO?" dropdown offers, so a number typed onto a part before
  /// anybody entered the PO is still one click away rather than something to
  /// retype and mistype.
  List<String> get poNumbersInUse {
    final seen = <String>{};
    final out = <String>[];
    void take(String raw) {
      final key = normalizePoNumber(raw);
      if (key.isEmpty || !seen.add(key)) return;
      out.add(raw.trim());
    }

    for (final po in purchaseOrders) {
      take(po.number);
    }
    for (final order in partOrders.values) {
      take(order.poNumber);
    }
    for (final d in deliveries) {
      take(d.poNumber);
    }
    return out;
  }

  /// Adds a PO row, or returns the existing one when the job already has that
  /// number. Never two rows for one number — the number is what everything
  /// else points at, and two rows for it would be two answers to "what is on
  /// this PO".
  ProjectPo addPo({
    String number = '',
    String vendorId = '',
    String vendor = '',
    DateTime? issuedOn,
    DateTime? expectedOn,
    double amount = 0,
  }) {
    final existing = poByNumber(number);
    if (existing != null) return existing;
    final po = ProjectPo(
      id: nextPoId(),
      number: number.trim(),
      vendorId: vendorId,
      vendor: vendor,
      issuedOn: issuedOn,
      expectedOn: expectedOn,
      amount: amount,
    );
    purchaseOrders.add(po);
    return po;
  }

  /// Replaces the row with [po.id]. Does nothing when it has gone.
  void updatePo(ProjectPo po) {
    final at = purchaseOrders.indexWhere((p) => p.id == po.id);
    if (at >= 0) purchaseOrders[at] = po;
  }

  /// Corrects a PO's number, carrying every part and delivery that referenced
  /// the old one across with it.
  ///
  /// Not a plain [updatePo] with a new number, because the number IS the link:
  /// changing it in one place would leave forty parts pointing at a PO that no
  /// longer exists, which is exactly the state this list was added to prevent.
  ///
  /// Refuses when [number] is blank or already belongs to another row — a
  /// second row for one number is the one shape this list must not take.
  bool renamePo(String id, String number) {
    final po = poById(id);
    if (po == null) return false;
    final trimmed = number.trim();
    if (trimmed.isEmpty) return false;
    final clash = poByNumber(trimmed);
    if (clash != null && clash.id != id) return false;

    final was = normalizePoNumber(po.number);
    updatePo(po.copyWith(number: trimmed));
    if (was.isEmpty || was == normalizePoNumber(trimmed)) return true;

    for (final key in partOrders.keys.toList()) {
      final order = partOrders[key]!;
      if (normalizePoNumber(order.poNumber) == was) {
        partOrders[key] = order.copyWith(poNumber: trimmed);
      }
    }
    for (var i = 0; i < deliveries.length; i++) {
      if (normalizePoNumber(deliveries[i].poNumber) == was) {
        deliveries[i] = deliveries[i].copyWith(poNumber: trimmed);
      }
    }
    return true;
  }

  /// Takes a PO row off the job. The parts and deliveries KEEP the number —
  /// see the note above the class on why.
  void removePo(String id) => purchaseOrders.removeWhere((p) => p.id == id);

  /// Adds a signed note to a PO. Returns false when the row has gone.
  bool addPoNote(String id, ProjectNote note) {
    final po = poById(id);
    if (po == null || note.text.trim().isEmpty) return false;
    po.notes.add(note);
    return true;
  }

  /// The master-list keys bought on [number].
  List<String> partsOnPo(String number) {
    final needle = normalizePoNumber(number);
    if (needle.isEmpty) return const [];
    return [
      for (final e in partOrders.entries)
        if (normalizePoNumber(e.value.poNumber) == needle) e.key,
    ];
  }

  /// Puts equipment on a PO, and takes equipment off it, in one call.
  ///
  /// ONE DECISION, NOT NINETEEN. "Everything Extron quoted went out on
  /// PO-1188" is a sentence about a SET of parts, and made one part at a time
  /// it is nineteen trips through the Bought? box - of which, on a real job,
  /// the first three get filled in and the rest stay blank. That reads on the
  /// timeline as sixteen parts nobody has bought, which is worse than not
  /// having recorded the PO at all.
  ///
  /// A part joining the PO keeps everything else its order record says and
  /// gains an order date when it has none: a part bought on a PO IS ordered,
  /// and a record carrying a number with no date does not count as one - see
  /// [PartOrder.isOrdered]. [expectedOn] - what the vendor promised for the
  /// order as a whole - is filled in the same way, only where the part has no
  /// promise of its own, because a date typed against one line is a better
  /// answer than the one on the acknowledgement.
  ///
  /// A part leaving loses the NUMBER, and when the number was the whole record
  /// it loses the record: what would be left is an order date against no
  /// paperwork, which reads on the timeline as a part somebody bought and
  /// cannot say where from. A record carrying anything else - a vendor's
  /// promise, an arrival, a quantity, a note - keeps all of it and loses only
  /// the number, because that was typed by somebody who meant it.
  ///
  /// Returns what actually moved, so a caller can log what it did rather than
  /// what it was asked to do.
  ({List<String> added, List<String> removed}) setPartsOnPo(
    String number, {
    Iterable<String> onIt = const [],
    Iterable<String> offIt = const [],
    DateTime? orderedOn,
    DateTime? expectedOn,
  }) {
    final trimmed = number.trim();
    final needle = normalizePoNumber(trimmed);
    final added = <String>[];
    final removed = <String>[];
    if (needle.isEmpty) return (added: added, removed: removed);

    for (final key in onIt) {
      final was = orderForPart(key);
      if (was != null && normalizePoNumber(was.poNumber) == needle) continue;
      setPartOrder(
        key,
        (was ?? const PartOrder()).copyWith(
          poNumber: trimmed,
          orderedOn: was?.orderedOn ?? orderedOn,
          expectedOn: was?.expectedOn ?? expectedOn,
        ),
      );
      added.add(key);
    }

    for (final key in offIt) {
      final was = orderForPart(key);
      if (was == null || normalizePoNumber(was.poNumber) != needle) continue;
      final left = was.copyWith(poNumber: '');
      final bare =
          left.expectedOn == null &&
          left.receivedOn == null &&
          left.qty == 0 &&
          left.notes.trim().isEmpty;
      setPartOrder(key, bare ? null : left);
      removed.add(key);
    }
    return (added: added, removed: removed);
  }

  // --- what has arrived and where it is -------------------------------------

  /// The delivery row with [id], or null.
  ProjectDelivery? deliveryById(String id) {
    for (final d in deliveries) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// Every arrival logged against one master-list part, newest first.
  List<ProjectDelivery> deliveriesForPart(String partKey) {
    final out = [for (final d in deliveries) if (d.partKey == partKey) d];
    out.sort(_byDeliveredDescending);
    return out;
  }

  /// The one-off purchases: what was bought on a card rather than through the
  /// quote and the PO. Newest first.
  ///
  /// Worth being able to list on its own, because it is the spend nothing else
  /// in this app knows about — it is on no estimate, in no vendor package and
  /// on no purchase order, and at the end of a job "what did we buy outside
  /// the process" is a question somebody in finance asks.
  List<ProjectDelivery> get oneOffDeliveries {
    final out = [for (final d in deliveries) if (d.oneOff) d];
    out.sort(_byDeliveredDescending);
    return out;
  }

  /// Arrivals that say nothing about what bought them — no PO, and not marked
  /// as a one-off. See [ProjectDelivery.needsPaperwork].
  List<ProjectDelivery> get deliveriesNeedingPaperwork {
    final out = [for (final d in deliveries) if (d.needsPaperwork) d];
    out.sort(_byDeliveredDescending);
    return out;
  }

  /// Every arrival logged against one PO, newest first.
  List<ProjectDelivery> deliveriesForPo(String number) {
    final needle = normalizePoNumber(number);
    if (needle.isEmpty) return const [];
    final out = [
      for (final d in deliveries)
        if (normalizePoNumber(d.poNumber) == needle) d,
    ];
    out.sort(_byDeliveredDescending);
    return out;
  }

  /// Newest arrival first, undated rows last. Undated rows are hand-edited
  /// ones, and sorting them to the top would put the least certain rows above
  /// everything somebody actually logged.
  static int _byDeliveredDescending(ProjectDelivery a, ProjectDelivery b) {
    final ad = a.deliveredOn;
    final bd = b.deliveredOn;
    if (ad == null && bd == null) return a.id.compareTo(b.id);
    if (ad == null) return 1;
    if (bd == null) return -1;
    final byDate = bd.compareTo(ad);
    return byDate != 0 ? byDate : a.id.compareTo(b.id);
  }

  /// How many units of [partKey] are on site — everything that arrived and did
  /// not go back, installed or not.
  double deliveredQty(String partKey) => _qtyWhere(
    partKey,
    (d) => d.isOnHand,
  );

  /// How many are in the room.
  double installedQty(String partKey) => _qtyWhere(partKey, (d) => d.isInstalled);

  /// How many are on site and NOT in a room yet — the figure the tracker
  /// exists for. Counts both 'delivered' and 'in storage', because from the
  /// job's point of view they are the same thing: kit somebody still has to
  /// carry somewhere.
  double awaitingInstallQty(String partKey) => _qtyWhere(
    partKey,
    (d) => d.isOnHand && !d.isInstalled,
  );

  double _qtyWhere(String partKey, bool Function(ProjectDelivery) test) {
    var total = 0.0;
    for (final d in deliveries) {
      if (d.partKey == partKey && test(d)) total += d.qty;
    }
    return total;
  }

  /// Logs an arrival and returns the row it made.
  ProjectDelivery addDelivery({
    String partKey = '',
    String itemName = '',
    String poNumber = '',
    bool oneOff = false,
    double qty = 0,
    DateTime? deliveredOn,
    DeliveryState state = DeliveryState.delivered,
    String location = '',
    String roomId = '',
    DateTime? installedOn,
    ProjectNote? note,
  }) {
    final row = ProjectDelivery(
      id: nextDeliveryId(),
      partKey: partKey,
      itemName: itemName.trim(),
      poNumber: poNumber.trim(),
      oneOff: oneOff,
      qty: qty,
      deliveredOn: deliveredOn ?? today(),
      state: state,
      location: location,
      roomId: roomId,
      // An arrival that is already in the room happened on a day, and the day
      // it went in is the day it was logged unless somebody says otherwise.
      installedOn: installedOn ??
          (state == DeliveryState.installed ? (deliveredOn ?? today()) : null),
      notes: [
        if (note != null && note.text.trim().isNotEmpty) note,
      ],
    );
    deliveries.add(row);
    return row;
  }

  /// Replaces the row with [row.id]. Does nothing when it has gone.
  void updateDelivery(ProjectDelivery row) {
    final at = deliveries.indexWhere((d) => d.id == row.id);
    if (at >= 0) deliveries[at] = row;
  }

  void removeDelivery(String id) => deliveries.removeWhere((d) => d.id == id);

  /// Adds a signed note to a delivery. Returns false when the row has gone.
  bool addDeliveryNote(String id, ProjectNote note) {
    final row = deliveryById(id);
    if (row == null || note.text.trim().isEmpty) return false;
    row.notes.add(note);
    return true;
  }

  /// Takes one note back off a delivery, by its position. False when either
  /// the row or the note has gone.
  bool removeDeliveryNote(String id, int index) {
    final row = deliveryById(id);
    if (row == null || index < 0 || index >= row.notes.length) return false;
    row.notes.removeAt(index);
    return true;
  }

  /// Every place the job has had kit delivered to or held at, in the order
  /// first seen.
  ///
  /// What the location field offers as suggestions: a job takes delivery at
  /// two or three addresses and holds kit in two or three places, and retyping
  /// 'Bessey basement, rack 3' is how one place becomes four spellings that no
  /// filter can bring back together.
  ///
  /// SUGGESTIONS, NOT A LIST TO PICK FROM. The next delivery can go to an
  /// address nobody has used yet - a loading dock across campus, a contractor's
  /// warehouse, somebody's office - so what this offers has to be typed over
  /// rather than chosen between.
  List<String> get deliveryLocations {
    final seen = <String>{};
    final out = <String>[];
    for (final d in deliveries) {
      final text = d.location.trim();
      if (text.isEmpty) continue;
      if (seen.add(text.toLowerCase())) out.add(text);
    }
    return out;
  }

  /// Adopts PO numbers that were typed onto parts before this job had a PO
  /// list, so the list is populated the first time an older project is opened
  /// rather than starting empty beside forty parts that all name a PO.
  ///
  /// Additive and idempotent: it only ever adds rows for numbers with none,
  /// and never touches what the part orders say.
  void _adoptPoNumbers() {
    for (final number in poNumbersInUse) {
      if (poByNumber(number) == null) addPo(number: number);
    }
  }

  /// Puts [partKey] on [trackId], or back with the job when it is blank.
  void setPartTrack(String partKey, String trackId) {
    if (trackId.isEmpty) {
      partTracks.remove(partKey);
    } else {
      partTracks[partKey] = trackId;
    }
  }

  /// Records how many calendar days [partKey] takes to arrive, or forgets the
  /// figure when [days] is null or negative.
  ///
  /// Zero is a real answer and is kept: "it is on the shelf" is something
  /// somebody checked, and the schedule shows it as a part that can be ordered
  /// on the day it is needed rather than as one nobody has asked about.
  void setPartLeadTime(String partKey, int? days) {
    if (days == null || days < 0) {
      partLeadTimes.remove(partKey);
    } else {
      partLeadTimes[partKey] = days;
    }
  }

  /// Sets the date [partKey] has to arrive by, ahead of the rest of the job,
  /// or clears it so the part goes back to wanting the project deadline.
  void setPartNeedBy(String partKey, DateTime? date) {
    if (date == null) {
      partNeedBy.remove(partKey);
    } else {
      partNeedBy[partKey] = dateOnly(date);
    }
  }

  /// Drops a vendor and every pin that named it. Leaving the pins would make
  /// the parts unreachable — tagged to a vendor with no row to click.
  void removeVendor(String id) {
    vendors.removeWhere((v) => v.id == id);
    partVendors.removeWhere((_, v) => v == id);
  }

  // -------------------------------------------------------------------------
  //  PATHS
  // -------------------------------------------------------------------------

  /// A stored room path made absolute, against the folder the project file is
  /// in. An absolute stored path is returned as-is, so a room deliberately
  /// kept somewhere else still resolves.
  static String resolvePath(String stored, String projectPath) {
    if (stored.isEmpty) return '';
    if (path.isAbsolute(stored)) return path.normalize(stored);
    if (projectPath.isEmpty) return path.normalize(stored);
    return path.normalize(
      path.join(path.dirname(projectPath), stored),
    );
  }

  /// How a room path should be WRITTEN into a project saved at [projectPath]:
  /// relative when the room is under the project's folder, absolute otherwise.
  ///
  /// The condition matters. Relativising a path that climbs out of the folder
  /// produces `..\..\..\other_building\room_config.json`, which is both
  /// unreadable and fragile — it breaks the moment the project file moves,
  /// which is the exact thing relative paths were supposed to survive.
  static String storePath(String absolute, String projectPath) {
    if (absolute.isEmpty || projectPath.isEmpty) return absolute;
    final root = path.dirname(projectPath);
    final rel = path.relative(absolute, from: root);
    if (rel.startsWith('..') || path.isAbsolute(rel)) return absolute;
    return rel;
  }

  /// How the CAMPUS pointer is stored - see [campusFile].
  ///
  /// The same bargain [storePath] makes, with one difference: a campus is
  /// allowed to sit ABOVE the jobs on it. `..\Chico_campus.json` is refused
  /// for a room, and rightly - a config that climbs out of the job's folder is
  /// a room that is not part of the job - but it is the ordinary shape of an
  /// estate, where the sheet is at the top of the folder and the buildings are
  /// in it.
  ///
  /// THREE LEVELS AND NO MORE. Past that the two documents are not in one tree
  /// in any sense somebody would recognise - they are two files that happen to
  /// be on one disk - and a chain of `..` that long breaks on any move at all,
  /// which is the exact thing a relative path is for. Those store absolute,
  /// which still opens; it simply does not survive the folder being copied.
  static String storeCampusPath(String absolute, String projectPath) {
    if (absolute.isEmpty || projectPath.isEmpty) return absolute;
    final rel = path.relative(absolute, from: path.dirname(projectPath));
    if (path.isAbsolute(rel)) return absolute;
    final up = path.split(rel).where((s) => s == '..').length;
    return up > 3 ? absolute : rel;
  }

  /// This project's rooms as absolute config paths, in project order.
  List<String> resolvedRoomPaths(String projectPath) => [
    for (final r in rooms) resolvePath(r.configPath, projectPath),
  ];

  /// The campus sheet this job is on, as an absolute path, or '' when it is on
  /// none. Resolved against [projectPath] the same way a room is, because it
  /// is stored the same way. See [campusFile].
  String resolvedCampusFile(String projectPath) => campusFile.trim().isEmpty
      ? ''
      : resolvePath(campusFile.trim(), projectPath);

  // -------------------------------------------------------------------------
  //  PERSISTENCE
  // -------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
    '__readme':
        'Room Config Builder project: a building quoted as one job. The '
        'rooms are references to config.json files, not copies - editing a '
        'room edits it here too. Paths are relative to this file when the '
        'room sits under the same folder.',
    'version': 1,
    'name': name,
    'building': building,
    if (projectNumber.isNotEmpty) 'projectNumber': projectNumber,
    if (stakeholder.isNotEmpty) 'stakeholder': stakeholder,
    if (notes.isNotEmpty) 'notes': notes,
    'currency': currency,
    'rooms': [for (final r in rooms) r.toJson()],
    // Which sheet this job is on - see [campusFile]. Written only when there
    // is one, so a job that has never been on a campus does not grow a key
    // saying so.
    if (campusFile.trim().isNotEmpty) 'campusFile': campusFile.trim(),
    // Where the published copy goes, and when it last went. Written only when
    // there is one, so a job nobody has published does not grow keys saying
    // so - the same bargain campusFile makes above.
    if (onlineFolder.trim().isNotEmpty) 'onlineFolder': onlineFolder.trim(),
    if (onlineAutoPublish) 'onlineAutoPublish': true,
    if (onlinePublishedAt != null)
      'onlinePublishedAt': onlinePublishedAt!.toIso8601String(),
    if (manualRooms.isNotEmpty)
      'manualRooms': [for (final r in manualRooms) r.toJson()],
    'vendors': [for (final v in vendors) v.toJson()],
    if (responsibility.isNotEmpty)
      'responsibility': [for (final r in responsibility) r.toJson()],
    if (partVendors.isNotEmpty) 'partVendors': partVendors,
    if (deliveryDeadline != null)
      'deliveryDeadline': formatIsoDate(deliveryDeadline!),
    if (partLeadTimes.isNotEmpty) 'partLeadTimes': partLeadTimes,
    if (partNeedBy.isNotEmpty)
      'partNeedBy': {
        for (final e in partNeedBy.entries) e.key: formatIsoDate(e.value),
      },
    if (todos.isNotEmpty) 'todos': [for (final t in todos) t.toJson()],
    if (tracks.isNotEmpty) 'tracks': [for (final t in tracks) t.toJson()],
    if (partTracks.isNotEmpty) 'partTracks': partTracks,
    if (partOrders.isNotEmpty)
      'partOrders': {
        for (final e in partOrders.entries) e.key: e.value.toJson(),
      },
    if (spares.isNotEmpty) 'spares': [for (final s in spares) s.toJson()],
    // AS A PERCENTAGE, under the name the old target had. A file is read by
    // people as well as by this app, and 'spareTargetPercent: 15' is a line
    // somebody can check against what was agreed; 0.15 is a line they have to
    // convert first. Written only when it is not the suggested figure, so an
    // untouched job's file does not grow a key saying nothing.
    if ((spareCoverTarget - kSuggestedSpareCover).abs() > 1e-9)
      'spareTargetPercent': spareCoverTarget * 100,
    if (plans.isNotEmpty) 'plans': [for (final p in plans) p.toJson()],
    if (purchaseOrders.isNotEmpty)
      'purchaseOrders': [for (final p in purchaseOrders) p.toJson()],
    if (deliveries.isNotEmpty)
      'deliveries': [for (final d in deliveries) d.toJson()],
    if (history.isNotEmpty)
      'history': [for (final h in history) h.toJson()],
    'roomCounter': _roomCounter,
    if (_manualRoomCounter > 0) 'manualRoomCounter': _manualRoomCounter,
    'vendorCounter': _vendorCounter,
    if (_todoCounter > 0) 'todoCounter': _todoCounter,
    if (_trackCounter > 0) 'trackCounter': _trackCounter,
    if (_spareCounter > 0) 'spareCounter': _spareCounter,
    if (_planCounter > 0) 'planCounter': _planCounter,
    if (_poCounter > 0) 'poCounter': _poCounter,
    if (_deliveryCounter > 0) 'deliveryCounter': _deliveryCounter,
    if (_responsibilityCounter > 0)
      'responsibilityCounter': _responsibilityCounter,
  };

  factory BuildingProject.fromJson(Map<String, dynamic> json) {
    final rooms = [
      for (final r in (json['rooms'] as List? ?? []))
        if (r is Map) ProjectRoomRef.fromJson(Map<String, dynamic>.from(r)),
    ];
    // A room with no name cannot be read on a plan or pointed at in a
    // meeting, so it is dropped the way an empty note is.
    final manualRooms = [
      for (final r in (json['manualRooms'] as List? ?? []))
        if (r is Map && r['name']?.toString().trim().isNotEmpty == true)
          ManualRoom.fromJson(Map<String, dynamic>.from(r)),
    ];
    final vendors = [
      for (final v in (json['vendors'] as List? ?? []))
        if (v is Map) ProjectVendor.fromJson(Map<String, dynamic>.from(v)),
    ];
    // A line with no scope on it names nothing and can be neither agreed nor
    // bid, so it is dropped the way an empty note is.
    final responsibility = [
      for (final r in (json['responsibility'] as List? ?? []))
        if (r is Map && r['scope']?.toString().trim().isNotEmpty == true)
          ResponsibilityItem.fromJson(Map<String, dynamic>.from(r)),
    ];

    final pins = <String, String>{};
    final rawPins = json['partVendors'];
    if (rawPins is Map) {
      rawPins.forEach((k, v) => pins[k.toString()] = v.toString());
    }

    // Lead times and the dates that go with them. A figure that is not a
    // number, or a date that is not a date, is DROPPED rather than defaulted:
    // a hand-edited file with "6-8 weeks" typed into a day count should read
    // as "nobody has answered this yet", which is true and visible, instead of
    // as zero days, which is false and invisible.
    final leadTimes = <String, int>{};
    final rawLead = json['partLeadTimes'];
    if (rawLead is Map) {
      rawLead.forEach((k, v) {
        final days = v is num ? v.toInt() : int.tryParse(v.toString().trim());
        if (days != null && days >= 0) leadTimes[k.toString()] = days;
      });
    }
    final needBy = <String, DateTime>{};
    final rawNeedBy = json['partNeedBy'];
    if (rawNeedBy is Map) {
      rawNeedBy.forEach((k, v) {
        final date = parseIsoDate(v);
        if (date != null) needBy[k.toString()] = date;
      });
    }

    // A note with no words on it is not a note. Everything else about a to-do
    // is recoverable — a missing date becomes today, an unreadable state
    // becomes open — but there is nothing to show for an empty one.
    // A track with no name cannot be picked or read, so it is dropped the way
    // an empty note is.
    final tracks = [
      for (final t in (json['tracks'] as List? ?? []))
        if (t is Map && t['name']?.toString().trim().isNotEmpty == true)
          ProjectTrack.fromJson(Map<String, dynamic>.from(t)),
    ];

    final spares = [
      for (final entry in (json['spares'] as List? ?? []))
        if (entry is Map)
          ProjectSpare.fromJson(Map<String, dynamic>.from(entry)),
    ];

    // A drawing with no path is not a drawing: there is nothing to open and
    // nothing to say is missing, so it is dropped the way an empty note is.
    final plans = [
      for (final entry in (json['plans'] as List? ?? []))
        if (entry is Map &&
            entry['filePath']?.toString().trim().isNotEmpty == true)
          ProjectPlan.fromJson(Map<String, dynamic>.from(entry)),
    ];
    // A PO with no number names nothing and can be pointed at by nothing, so
    // it is dropped the way an empty note is.
    final purchaseOrders = [
      for (final entry in (json['purchaseOrders'] as List? ?? []))
        if (entry is Map &&
            entry['number']?.toString().trim().isNotEmpty == true)
          ProjectPo.fromJson(Map<String, dynamic>.from(entry)),
    ];
    // A delivery row is kept whatever else is thin on it: an arrival that only
    // says a date and a note is still somebody's record of something turning
    // up, and the tracker's whole job is not to lose those.
    final deliveries = [
      for (final entry in (json['deliveries'] as List? ?? []))
        if (entry is Map)
          ProjectDelivery.fromJson(Map<String, dynamic>.from(entry)),
    ];
    final trackPins = <String, String>{};
    final rawTracks = json['partTracks'];
    if (rawTracks is Map) {
      rawTracks.forEach((k, v) => trackPins[k.toString()] = v.toString());
    }

    // An order record with nothing on it is dropped: it would take a part off
    // the schedule without saying anything about when it was bought.
    // Trimmed on the way in as well as on the way out, so a file that grew
    // under an older build does not stay large forever.
    final rawHistory = (json['history'] as List? ?? []);
    final history = [
      for (final h in rawHistory)
        if (h is Map) ProjectEdit.fromJson(Map<String, dynamic>.from(h)),
    ];
    if (history.length > kMaxProjectHistory) {
      history.removeRange(0, history.length - kMaxProjectHistory);
    }

    final orders = <String, PartOrder>{};
    final rawOrders = json['partOrders'];
    if (rawOrders is Map) {
      rawOrders.forEach((k, v) {
        if (v is! Map) return;
        final order = PartOrder.fromJson(Map<String, dynamic>.from(v));
        if (!order.isEmpty) orders[k.toString()] = order;
      });
    }

    final todos = [
      for (final t in (json['todos'] as List? ?? []))
        if (t is Map && t['text']?.toString().trim().isNotEmpty == true)
          ProjectTodo.fromJson(Map<String, dynamic>.from(t)),
    ];

    // Counters are rebuilt from the ids present as well as read from the file:
    // a project hand-edited to add a room (which is a supported thing to do —
    // see the readme key) has ids the stored counter has never seen, and
    // handing out one of them again would silently merge two rooms.
    int highest(Iterable<String> ids, String prefix) {
      var best = 0;
      for (final id in ids) {
        if (!id.startsWith(prefix)) continue;
        final n = int.tryParse(id.substring(prefix.length));
        if (n != null && n > best) best = n;
      }
      return best;
    }

    final project = BuildingProject(
      name: json['name']?.toString() ?? '',
      building: json['building']?.toString() ?? '',
      // 'jobNumber' is what this was called before the app settled on
      // "project" for the thing a building is quoted as. Read under both
      // names, written under the new one - so the old key retires as each
      // project is saved rather than on a migration nobody asked for.
      projectNumber:
          (json['projectNumber'] ?? json['jobNumber'])?.toString() ?? '',
      // 'client' is what this was called before, and a project file written
      // then is still the one somebody opens this afternoon. Read under both
      // names, written under the new one - so the old key retires as each
      // project is saved rather than on a migration nobody asked for.
      stakeholder: (json['stakeholder'] ?? json['client'])?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      currency: json['currency']?.toString().isNotEmpty == true
          ? json['currency'].toString()
          : r'$',
      rooms: rooms,
      campusFile: json['campusFile']?.toString().trim() ?? '',
      onlineFolder: json['onlineFolder']?.toString().trim() ?? '',
      onlineAutoPublish: json['onlineAutoPublish'] == true,
      onlinePublishedAt: DateTime.tryParse(
        json['onlinePublishedAt']?.toString() ?? '',
      ),
      manualRooms: manualRooms,
      vendors: vendors,
      responsibility: responsibility,
      partVendors: pins,
      deliveryDeadline: parseIsoDate(json['deliveryDeadline']),
      partLeadTimes: leadTimes,
      partNeedBy: needBy,
      todos: todos,
      tracks: tracks,
      partTracks: trackPins,
      partOrders: orders,
      spares: spares,
      // A target that is not a number, or one outside nought to a hundred, is
      // read as the SUGGESTION rather than clamped: "we hold 200%" in a
      // hand-edited file is a typo, and honouring it would put a
      // recommendation of two hundred spare wall plates on the sheet.
      //
      // A file written by the version that first had a target opens with that
      // target back in force - it is the same key, holding the same number,
      // meaning very nearly the same thing.
      spareCoverTarget: () {
        final raw = json['spareTargetPercent'];
        final percent = raw is num
            ? raw.toDouble()
            : double.tryParse(raw?.toString().trim() ?? '');
        return percent == null || percent < 0 || percent > 100
            ? kSuggestedSpareCover
            : percent / 100;
      }(),
      plans: plans,
      purchaseOrders: purchaseOrders,
      deliveries: deliveries,
      history: history,
      spareCounter: [
        (json['spareCounter'] as num?)?.toInt() ?? 0,
        highest(spares.map((s) => s.id), 'spare'),
      ].reduce((a, b) => a > b ? a : b),
      planCounter: [
        (json['planCounter'] as num?)?.toInt() ?? 0,
        highest(plans.map((p) => p.id), 'plan'),
      ].reduce((a, b) => a > b ? a : b),
      poCounter: [
        (json['poCounter'] as num?)?.toInt() ?? 0,
        highest(purchaseOrders.map((p) => p.id), 'po'),
      ].reduce((a, b) => a > b ? a : b),
      deliveryCounter: [
        (json['deliveryCounter'] as num?)?.toInt() ?? 0,
        highest(deliveries.map((d) => d.id), 'del'),
      ].reduce((a, b) => a > b ? a : b),
      responsibilityCounter: [
        (json['responsibilityCounter'] as num?)?.toInt() ?? 0,
        highest(responsibility.map((r) => r.id), 'resp'),
      ].reduce((a, b) => a > b ? a : b),
      trackCounter: [
        (json['trackCounter'] as num?)?.toInt() ?? 0,
        highest(tracks.map((t) => t.id), 'track'),
      ].reduce((a, b) => a > b ? a : b),
      // Rebuilt from the ids present as well as read, for the same reason the
      // room and vendor counters are: a reused id would make two notes the
      // same note, and ticking one would tick the other.
      todoCounter: [
        (json['todoCounter'] as num?)?.toInt() ?? 0,
        highest(todos.map((t) => t.id), 'todo'),
      ].reduce((a, b) => a > b ? a : b),
      roomCounter: [
        (json['roomCounter'] as num?)?.toInt() ?? 0,
        highest(rooms.map((r) => r.id), 'room'),
      ].reduce((a, b) => a > b ? a : b),
      manualRoomCounter: [
        (json['manualRoomCounter'] as num?)?.toInt() ?? 0,
        highest(manualRooms.map((r) => r.id), 'manual'),
      ].reduce((a, b) => a > b ? a : b),
      vendorCounter: [
        (json['vendorCounter'] as num?)?.toInt() ?? 0,
        highest(vendors.map((v) => v.id), 'vendor'),
      ].reduce((a, b) => a > b ? a : b),
    );
    // A PO number typed onto a part under an older build becomes a row on the
    // job's PO list the first time the file is opened - see [_adoptPoNumbers].
    project._adoptPoNumbers();
    return project;
  }

  /// Reads a project file. Throws with a readable message rather than a
  /// decoder error, because this path is one file-picker click from a user
  /// who picked the wrong json.
  static Future<BuildingProject> load(String file) async {
    final text = await File(file).readAsString();
    final doc = jsonDecode(text);
    if (doc is! Map) {
      throw const FormatException(
        'That file is not a project - its root is not an object.',
      );
    }
    final map = Map<String, dynamic>.from(doc);
    if (!map.containsKey('rooms')) {
      throw const FormatException(
        'That file has no "rooms" list, so it is not a project file. A room '
        'config is opened with Open Config instead.',
      );
    }
    return BuildingProject.fromJson(map);
  }

  Future<void> save(String file) async {
    const encoder = JsonEncoder.withIndent('    ');
    await File(file).writeAsString(encoder.convert(toJson()));
  }

  /// A deep-enough copy for the undo of a destructive edit (removing a room,
  /// deleting a vendor) — every collection this class mutates is fresh, and
  /// the entries themselves are immutable.
  BuildingProject clone() => BuildingProject(
    name: name,
    building: building,
    projectNumber: projectNumber,
    stakeholder: stakeholder,
    notes: notes,
    currency: currency,
    rooms: List<ProjectRoomRef>.from(rooms),
    campusFile: campusFile,
    onlineFolder: onlineFolder,
    onlineAutoPublish: onlineAutoPublish,
    onlinePublishedAt: onlinePublishedAt,
    manualRooms: List<ManualRoom>.from(manualRooms),
    vendors: List<ProjectVendor>.from(vendors),
    responsibility: List<ResponsibilityItem>.from(responsibility),
    partVendors: Map<String, String>.from(partVendors),
    deliveryDeadline: deliveryDeadline,
    partLeadTimes: Map<String, int>.from(partLeadTimes),
    partNeedBy: Map<String, DateTime>.from(partNeedBy),
    todos: List<ProjectTodo>.from(todos),
    tracks: List<ProjectTrack>.from(tracks),
    partTracks: Map<String, String>.from(partTracks),
    partOrders: Map<String, PartOrder>.from(partOrders),
    spares: List<ProjectSpare>.from(spares),
    plans: List<ProjectPlan>.from(plans),
    // The signed notes on a PO or a delivery are a LIST INSIDE the row, and a
    // row is not immutable the way the others here are - see [addPoNote]. So
    // each one is rebuilt with its own copy of its notes, or an undo would
    // hand back rows that share their note lists with the ones it replaced.
    purchaseOrders: [for (final p in purchaseOrders) p.copyWith()],
    deliveries: [for (final d in deliveries) d.copyWith()],
    history: List<ProjectEdit>.from(history),
    roomCounter: _roomCounter,
    manualRoomCounter: _manualRoomCounter,
    vendorCounter: _vendorCounter,
    todoCounter: _todoCounter,
    trackCounter: _trackCounter,
    spareCounter: _spareCounter,
    planCounter: _planCounter,
    responsibilityCounter: _responsibilityCounter,
    poCounter: _poCounter,
    deliveryCounter: _deliveryCounter,
  );
}

/// Appends one entry to an edit log, coalescing a run of keystrokes.
///
/// Free rather than a method, because there are now TWO logs with exactly this
/// rule: the job's ([BuildingProject.history]) and the open room's. Two copies
/// of a coalescing window is two answers to "is this one decision or forty",
/// and the answer has to be the same or the two halves of the History screen
/// read as different features.
///
/// TYPING IS ONE DECISION, NOT FORTY. A field that writes through on every
/// keystroke — a note, a label, a device name — would otherwise put one entry
/// per character in the log and bury everything else. Only for fields that say
/// they are continuous, and only while the same person is still editing the
/// same field of the same item inside [kEditCoalesceWindow]. A done/undone pair
/// on a to-do is two decisions however fast they happen, so discrete changes
/// never coalesce.
///
/// [limit] caps the log so a file cannot grow without bound; the oldest go.
void appendEdit(
  List<ProjectEdit> log, {
  required String itemKey,
  required String field,
  required String summary,
  String itemName = '',
  String? user,
  DateTime? at,
  bool coalesce = false,
  int limit = kMaxProjectHistory,
}) {
  final when = at ?? DateTime.now();
  final who = user ?? currentUserName();

  if (coalesce && log.isNotEmpty) {
    final last = log.last;
    if (last.itemKey == itemKey &&
        last.field == field &&
        last.user == who &&
        when.difference(last.at).abs() < kEditCoalesceWindow) {
      log[log.length - 1] = ProjectEdit(
        itemKey: itemKey,
        itemName: itemName.isEmpty ? last.itemName : itemName,
        field: field,
        summary: summary,
        user: who,
        at: when,
      );
      return;
    }
  }

  log.add(
    ProjectEdit(
      itemKey: itemKey,
      itemName: itemName,
      field: field,
      summary: summary,
      user: who,
      at: when,
    ),
  );
  if (log.length > limit) {
    log.removeRange(0, log.length - limit);
  }
}

/// The file suffix a project is saved under, so the picker and the "is this a
/// project?" check agree on one spelling.
const String kProjectFileSuffix = '_project.json';

/// The vendor split nearly every job starts from: the control line bought
/// direct from its manufacturer, and the room hardware — cameras, screens,
/// USB — bought from whoever resells it.
///
/// Offered on a new project rather than imposed, and expressed the way the
/// split is actually described: ONE manufacturer rule for the direct line,
/// CATEGORY rules for the rest. Naming categories rather than brands is what
/// makes the second vendor survive contact with a real room — a job that
/// specifies a camera brand nobody listed still tags it, instead of landing
/// in the untagged pile for somebody to notice.
///
/// The manufacturer rule is on the FIRST vendor deliberately: an Extron
/// display is bought direct, not from the reseller who does screens, and
/// [BuildingProject.vendorForPart] resolves that by tier rather than by luck.
List<ProjectVendor> starterVendors(BuildingProject project) => [
  ProjectVendor(
    id: project.nextVendorId(),
    name: 'Extron Direct',
    notes: 'Everything Extron makes, bought on the direct account.',
    manufacturers: const ['Extron'],
  ),
  ProjectVendor(
    id: project.nextVendorId(),
    name: 'AV Reseller',
    notes: 'Cameras, screens, USB and the mounting hardware that goes with '
        'them.',
    categories: const [
      'Camera',
      'Display',
      'Projector',
      'Screen',
      'Mount',
      'USB',
      'Speaker',
      'Microphone',
    ],
  ),
];
