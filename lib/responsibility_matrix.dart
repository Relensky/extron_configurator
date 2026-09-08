import 'package:path/path.dart' as path;

import 'name_colors.dart' show nameSheetTint, normalizedName;
import 'report_tools.dart';
import 'xlsx_writer.dart' show XlsxTint;

/// ============================================================================
///  WHO FURNISHES IT, WHO INSTALLS IT
/// ============================================================================
///  A quote says what a building costs. It does not say WHOSE JOB each part of
///  it is — and that is the document every one of these projects actually
///  argues over, because the answer is different for almost every line:
///
///    * the screens are bought by the owner and hung by the electrical
///      contractor;
///    * the projector boxes are bought AND installed by the contractor;
///    * the speaker wire is pulled by the contractor and the speakers are
///      furnished by us;
///    * the PC monitors are ours and nobody installs them, because they sit on
///      a desk.
///
///  Get one of those wrong and the day the trades arrive is the day it is
///  discovered. So it is written down before the job starts, agreed with the
///  contractor, and re-issued whenever it changes — which is what a roles and
///  responsibilities matrix IS.
///
///  ONE ROW PER SCOPE ITEM, ONE COLUMN PER ROOM. The spreadsheet this replaces
///  is laid out the other way round, items across the top and rooms down the
///  side, which works while there are fourteen items and stops working at
///  thirty: a column per item is a sheet nobody can read without scrolling
///  sideways past the room names, and the description of the work — the part
///  people actually argue from — ends up in a cell three feet wide. Turned on
///  its side it is the same matrix, it grows downward the way a list should,
///  and the long prose sits in a column of its own.
///
///  IT IS NOT DERIVED FROM THE ROOMS, deliberately. The app knows what
///  equipment is on the drawing; it cannot know whose contract covers pulling
///  the cable to it, and inventing an answer to that is worse than leaving the
///  cell empty. What it does do is count: the quantity per room is typed once
///  and the totals row adds up, because the total is the number the contractor
///  bids against and adding fourteen columns by hand is how a bid comes back
///  wrong.
///
///  Pure data and report sections, no widgets, so the pane, the workbook and
///  the image export all render the same matrix.
/// ============================================================================

/// The answers that come up on nearly every line, offered rather than typed.
///
/// Free text underneath, because a real matrix names actual parties — "CTS
/// Chico", "CFCI", "Valley/DPR" — and a closed list would force those into a
/// generic word that loses the point of writing it down.
const List<String> kResponsibilityParties = [
  'Owner',
  'Contractor',
  'Integrator',
  'Vendor',
  'N/A',
  'TBD',
];

/// The answers a room's cell takes, offered rather than typed.
///
/// NUMBERS AND WORDS IN ONE LIST, because a cell takes either and the person
/// filling it in does not think of them as two kinds of thing - they think
/// "how many of these go in room 101", and sometimes the true answer is four
/// and sometimes it is "as required". A picker that offered only counts would
/// be telling them the second answer is not allowed.
///
/// The counts stop at eight. Past that it is quicker to type the number than
/// to find it in a list, and a dropdown thirty long is a dropdown that has to
/// be scrolled.
const List<String> kResponsibilityCellAnswers = [
  '1',
  '2',
  '3',
  '4',
  '5',
  'Existing',
  'N/A',
  'TBD',
];

/// A party reduced to what it MEANS, which is what a color is filed under.
///
/// One place rather than a call to [normalizedName] at every site, because the
/// key a color is STORED under and the key it is LOOKED UP by have to be the
/// same function forever - a project file outlives any one screen, and a
/// second answer to "what is this party called" is a color that goes missing
/// the next time the job is opened.
String responsibilityPartyKey(String party) => normalizedName(party);

/// One line of the matrix: a piece of scope, whose it is, and how much of it
/// each room needs.
class ResponsibilityItem {
  /// `resp<n>`, handed out by [BuildingProject.addResponsibilityItem].
  final String id;

  /// The scope, as it is named to the contractor: 'Projection screen',
  /// 'Ceiling speaker', 'Patch panels in the wall rack'.
  final String scope;

  /// Who buys it, and who puts it in. Free text — see
  /// [kResponsibilityParties].
  final String furnishedBy;
  final String installedBy;

  /// When the equipment has to be on site for the trades to install it.
  ///
  /// Free text rather than a date, because on a live job the honest answer for
  /// most lines is 'TBD' or 'with the rough-in', and a date field would force
  /// somebody to invent one. The job's own delivery deadline is on the
  /// Timeline tab and means something different — this is the date the
  /// CONTRACTOR needs it by, which is usually earlier.
  final String neededBy;

  /// Room id ([ProjectRoomRef.id]) -> how many.
  ///
  /// A ROOM THAT IS ABSENT AND A ROOM STORED AS 0 ARE DIFFERENT ANSWERS, and
  /// the difference is the same one the notes draw: absent means nobody has
  /// said, and 0 means somebody decided this room does not get one. On a sheet
  /// being walked line by line before it goes to a contractor, "we looked and
  /// the answer is none" is worth writing down - an empty cell is the thing
  /// still to do, and a zero is a thing that is finished.
  ///
  /// A zero is drawn quietly rather than in the count's ink: it is an answer,
  /// but it is not a quantity anybody has to buy.
  final Map<String, double> qtyByRoom;

  /// Room id -> the answer in WORDS, for a cell that is not a count.
  ///
  /// NOT EVERY CELL ON THIS SHEET IS A NUMBER. The honest answer for a room is
  /// often 'as required', 'per plan', 'existing to remain' or 'TBD' - and
  /// until now typing one of those left the cell empty, because a quantity
  /// that would not parse was dropped on the way in. An empty cell and "we
  /// have not decided" are opposite things to a contractor pricing the line.
  ///
  /// A CELL HOLDS ONE OR THE OTHER, never both - see [withRoomQty] and
  /// [withRoomNote], each of which clears the other. A room with a count and a
  /// note would be a cell with two answers, and the totals row could only
  /// honor one of them.
  ///
  /// These do NOT reach [total]. 'As required' cannot be added up, and a sheet
  /// that quietly counted it as one would be a bid short by however many rooms
  /// said it. They are highlighted wherever the matrix is drawn instead.
  final Map<String, String> noteByRoom;

  /// What the work actually is, in the words it will be read in on site. The
  /// longest field on the sheet and the one that settles arguments.
  final String work;

  /// Where to see the product — a manufacturer page, a cutsheet.
  final String productLink;

  /// Anything still open: a size not settled, a party still to confirm.
  final String notes;

  const ResponsibilityItem({
    required this.id,
    required this.scope,
    this.furnishedBy = '',
    this.installedBy = '',
    this.neededBy = '',
    Map<String, double>? qtyByRoom,
    Map<String, String>? noteByRoom,
    this.work = '',
    this.productLink = '',
    this.notes = '',
  })  : qtyByRoom = qtyByRoom ?? const {},
        noteByRoom = noteByRoom ?? const {};

  /// How many of these the whole job needs — the number a bid is written
  /// against.
  double get total =>
      qtyByRoom.values.fold<double>(0, (sum, q) => sum + q);

  /// What one room's cell says: its note if it has one, else its count, else
  /// nothing at all. THE ONE ANSWER TO "what goes in this box", so the grid,
  /// the editor list, the picture and the spreadsheet cannot disagree.
  String cellText(String roomId) {
    final note = noteByRoom[roomId]?.trim() ?? '';
    if (note.isNotEmpty) return note;
    final qty = qtyByRoom[roomId];
    if (qty == null) return '';
    // WRITTEN OUT, unlike the blank a missing room gets. See [qtyByRoom]:
    // a zero is an answer and has to look like one.
    return qty == 0 ? '0' : formatResponsibilityQty(qty);
  }

  /// True when this room's answer is words rather than a count - the cells
  /// that are highlighted, and the ones [total] cannot include.
  bool cellIsNote(String roomId) =>
      (noteByRoom[roomId]?.trim() ?? '').isNotEmpty;

  /// True when somebody has answered this room with NONE - see [qtyByRoom].
  /// Drawn quietly: it is settled, and it is nothing to buy.
  bool cellIsNone(String roomId) =>
      !cellIsNote(roomId) && qtyByRoom[roomId] == 0;

  /// How many rooms answered this line in words. What the totals row says out
  /// loud, so a total that is short of the room count says why.
  int get noteCount =>
      noteByRoom.values.where((n) => n.trim().isNotEmpty).length;

  /// True when neither party has been settled. The matrix's own to-do list.
  bool get unassigned =>
      furnishedBy.trim().isEmpty || installedBy.trim().isEmpty;

  /// True when [productLink] is a web address rather than a file on disk.
  ///
  /// The field takes both on purpose. Half the cutsheets on a job are a
  /// manufacturer's page somebody pasted and half are a PDF in the job folder,
  /// and forcing one of them into the shape of the other is how the field
  /// stops being filled in.
  bool get productIsUrl {
    final link = productLink.trim().toLowerCase();
    return link.startsWith('http://') || link.startsWith('https://');
  }

  /// WHAT THE CUTSHEET IS CALLED, for a document that cannot be clicked.
  ///
  /// A printed matrix carrying a full job-folder path to a PDF is a matrix
  /// with a column of noise in it. The file's NAME is the half that means
  /// something to somebody holding the paper, and it is what they will search
  /// the job folder for. A web link keeps its host for the same reason -
  /// 'extron.com' says where to look, the query string does not.
  ///
  /// '' when there is no link at all.
  String get productName {
    final link = productLink.trim();
    if (link.isEmpty) return '';
    if (productIsUrl) {
      final host = Uri.tryParse(link)?.host ?? '';
      return host.isEmpty ? link : host;
    }
    final base = path.basename(link.replaceAll(r'\', '/'));
    return base.isEmpty ? link : base;
  }

  ResponsibilityItem copyWith({
    String? scope,
    String? furnishedBy,
    String? installedBy,
    String? neededBy,
    Map<String, double>? qtyByRoom,
    Map<String, String>? noteByRoom,
    String? work,
    String? productLink,
    String? notes,
  }) => ResponsibilityItem(
    id: id,
    scope: scope ?? this.scope,
    furnishedBy: furnishedBy ?? this.furnishedBy,
    installedBy: installedBy ?? this.installedBy,
    neededBy: neededBy ?? this.neededBy,
    qtyByRoom: qtyByRoom ?? this.qtyByRoom,
    noteByRoom: noteByRoom ?? this.noteByRoom,
    work: work ?? this.work,
    productLink: productLink ?? this.productLink,
    notes: notes ?? this.notes,
  );

  /// The same item with [roomId] set to [qty], or dropped when [qty] is not a
  /// positive number.
  ///
  /// Dropped rather than stored as zero so the file stays about what a room
  /// NEEDS: a matrix that wrote a 0 for every room that does not want a
  /// projection screen would be mostly zeroes, and the export would print
  /// them.
  /// A NEGATIVE [qty] IS NOT AN ANSWER and takes the room off the line; zero
  /// is an answer and is kept - see [qtyByRoom]. To blank a cell outright, use
  /// [withRoomCleared], which says so at the call site.
  ResponsibilityItem withRoomQty(String roomId, double qty) {
    final next = Map<String, double>.from(qtyByRoom);
    if (qty >= 0) {
      next[roomId] = qty;
    } else {
      next.remove(roomId);
    }
    // A COUNT REPLACES A NOTE. The cell has one answer; leaving 'as required'
    // behind a 4 would put two of them in one box, and only one of the two can
    // reach the totals row.
    final notes = Map<String, String>.from(noteByRoom)..remove(roomId);
    return copyWith(qtyByRoom: next, noteByRoom: notes);
  }

  /// The same item with this room unanswered again - no count and no note.
  ///
  /// BOTH MAPS, which is what makes this its own method. Clearing used to go
  /// through the note road with an empty string, and that dropped the note and
  /// left the count sitting there - so "not in this room" did nothing at all
  /// to the cells that had a number in them, which is most of them.
  ResponsibilityItem withRoomCleared(String roomId) => copyWith(
    qtyByRoom: Map<String, double>.from(qtyByRoom)..remove(roomId),
    noteByRoom: Map<String, String>.from(noteByRoom)..remove(roomId),
  );

  /// The same item with [roomId] answered in words, or cleared when [note] is
  /// blank. Drops any count that room had, for the reason on [withRoomQty].
  ResponsibilityItem withRoomNote(String roomId, String note) {
    final clean = note.trim();
    final notes = Map<String, String>.from(noteByRoom);
    final counts = Map<String, double>.from(qtyByRoom);
    if (clean.isEmpty) {
      // Blank is not an answer in words, so it takes the whole cell back to
      // unanswered rather than leaving a count behind - see [withRoomCleared].
      return withRoomCleared(roomId);
    } else {
      notes[roomId] = clean;
      counts.remove(roomId);
    }
    return copyWith(qtyByRoom: counts, noteByRoom: notes);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'scope': scope,
    if (furnishedBy.isNotEmpty) 'furnishedBy': furnishedBy,
    if (installedBy.isNotEmpty) 'installedBy': installedBy,
    if (neededBy.isNotEmpty) 'neededBy': neededBy,
    if (qtyByRoom.isNotEmpty) 'qtyByRoom': qtyByRoom,
    if (noteByRoom.isNotEmpty) 'noteByRoom': noteByRoom,
    if (work.isNotEmpty) 'work': work,
    if (productLink.isNotEmpty) 'productLink': productLink,
    if (notes.isNotEmpty) 'notes': notes,
  };

  factory ResponsibilityItem.fromJson(Map<String, dynamic> json) {
    final qty = <String, double>{};
    final notes = <String, String>{};
    final raw = json['qtyByRoom'];
    if (raw is Map) {
      raw.forEach((k, v) {
        final n = v is num ? v.toDouble() : double.tryParse(v.toString());
        // Zero included - see [ResponsibilityItem.qtyByRoom]: a room answered
        // 'none' is a room somebody settled, and dropping it would put it back
        // among the ones still to do.
        if (n != null && n >= 0) {
          qty[k.toString()] = n;
          return;
        }
        // A QUANTITY THAT IS NOT A NUMBER IS THE ROOM'S ANSWER IN WORDS, and
        // it used to be dropped here - "2 per room" or "as required" typed
        // into a count left the cell blank, which reads to a contractor as a
        // room that does not want the line. It is kept as a note now, which is
        // where such an answer belongs; a bare 0 is still nothing at all.
        final text = v?.toString().trim() ?? '';
        if (text.isNotEmpty && n == null) {
          notes[k.toString()] = text;
        }
      });
    }
    final rawNotes = json['noteByRoom'];
    if (rawNotes is Map) {
      rawNotes.forEach((k, v) {
        final text = v?.toString().trim() ?? '';
        if (text.isNotEmpty) notes[k.toString()] = text;
      });
    }
    return ResponsibilityItem(
      id: json['id']?.toString() ?? '',
      scope: json['scope']?.toString() ?? '',
      furnishedBy: json['furnishedBy']?.toString() ?? '',
      installedBy: json['installedBy']?.toString() ?? '',
      neededBy: json['neededBy']?.toString() ?? '',
      qtyByRoom: qty,
      noteByRoom: notes,
      work: json['work']?.toString() ?? '',
      productLink: json['productLink']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
    );
  }
}

/// The lines nearly every job in this shop has, offered rather than typed.
///
/// Taken from the matrix these projects are actually issued with, with the
/// building-specific quantities stripped off. The point is not that these are
/// the right lines for every job — several will be deleted on most of them —
/// it is that a matrix somebody starts from a blank page is a matrix that gets
/// started next week.
const List<({String scope, String furnishedBy, String installedBy, String work})>
    kStarterResponsibilityItems = [
  (
    scope: 'Projection screen',
    furnishedBy: 'Owner',
    installedBy: 'Contractor',
    work: 'Install the motorized screen and run control cable back to the '
        'control processor.',
  ),
  (
    scope: 'Screen control wall switch',
    furnishedBy: 'Owner',
    installedBy: 'Contractor',
    work: 'Wall switch installed with a point-to-point cable from the switch '
        'location back to the control processor.',
  ),
  (
    scope: 'Projector ceiling box',
    furnishedBy: 'Contractor',
    installedBy: 'Contractor',
    work: 'Install the ceiling enclosure and door. AV and network lines to be '
        'terminated inside the box.',
  ),
  (
    scope: 'Display wall box',
    furnishedBy: 'Contractor',
    installedBy: 'Contractor',
    work: 'Install the recessed wall box behind the display, with AV lines, '
        'network back to the IDF and power inside the box.',
  ),
  (
    scope: 'Display mount',
    furnishedBy: 'Owner',
    installedBy: 'Contractor',
    work: 'Install the wall or ceiling mounting bracket and hang the display '
        'on it.',
  ),
  (
    scope: 'Patch panels in the rack',
    furnishedBy: 'Contractor',
    installedBy: 'Contractor',
    work: 'Install patch panels in the rack for all AV lines and network lines '
        'back to the IDF.',
  ),
  (
    scope: 'Speaker cable pull',
    furnishedBy: 'Contractor',
    installedBy: 'Contractor',
    work: 'Supply and pull speaker cable, plenum rated where required, daisy '
        'chained and terminating at the amplifier location.',
  ),
  (
    scope: 'Ceiling speakers',
    furnishedBy: 'Owner',
    installedBy: 'Contractor',
    work: 'Install speakers in the ceiling with slack wire for seismic bracing '
        'and a cross tee at each location.',
  ),
  (
    scope: 'Ceiling microphones',
    furnishedBy: 'Owner',
    installedBy: 'Contractor',
    work: 'Provide slack and seismic wire bracing and a cross tee at each '
        'microphone location.',
  ),
  (
    scope: 'Ceiling cameras',
    furnishedBy: 'Owner',
    installedBy: 'Contractor',
    work: 'Install the ceiling plate above the tile and provide slack and '
        'seismic wire.',
  ),
];

// ---------------------------------------------------------------------------
//  THE SHEET
// ---------------------------------------------------------------------------

/// A party's name in the color it reads in everywhere else.
///
/// WHY THE SPREADSHEET GETS THE COLORS TOO. This matrix is read by whose name
/// is on the line - the whole reason the screen tints every party - and the
/// exported copy is the one that goes to the contractor, gets printed, and is
/// argued from at the pre-installation meeting. Black on white there sent the
/// reader back to reading every cell, which is the job the color was doing.
///
/// The hue comes from the SAME [nameSheetTint] the screen and the picture use,
/// so 'CTS Chico' is the same color in the app, in the PNG and in the .xlsx.
/// A blank party is deliberately gray and says so out loud: an unagreed line
/// must not read as a decided one.
/// [missingLabel] is what an unnamed party reads as. The grid's columns are
/// narrow and take the short form the screen uses; the table underneath has
/// room for the one that says it is not finished yet.
/// [color] is the color the JOB has given this party, as an ARGB int, or null
/// to leave it on the one its name derives. The spreadsheet has to be told:
/// its whole claim is that a party is the same color here as on the screen it
/// was agreed on, and a sheet that quietly re-derived the hue would be a
/// second opinion about it.
XlsxTint responsibilityPartyCell(
  String party, {
  String missingLabel = 'NOBODY',
  int? color,
}) {
  if (party.trim().isEmpty) {
    // NOT the neutral gray the other unsettled answers get. 'N/A' on the
    // install column is a real answer - the PC monitors sit on a desk and
    // nobody hangs them - and a blank is not. Printed in the same gray, the
    // one that needs chasing hides among the ones that do not.
    return XlsxTint(
      text: missingLabel,
      fillHex: kResponsibilityMissingFill,
      inkHex: kResponsibilityMissingInk,
    );
  }
  final tint = nameSheetTint(party, assigned: color);
  return XlsxTint(text: party.trim(), fillHex: tint.fill, inkHex: tint.ink);
}

/// The wash and ink a party nobody has named prints in: a pale red and a dark
/// one, the spreadsheet's version of the error color the screen uses.
const String kResponsibilityMissingFill = 'FBE4E4';
const String kResponsibilityMissingInk = 'A21C1C';

/// The wash a cell answered in WORDS prints in - see
/// [ResponsibilityItem.noteByRoom].
///
/// A DIFFERENT COLOR FROM THE MISSING ONE, because they are different
/// problems: a blank party has to be chased, and 'as required' is a decision
/// somebody made. Amber rather than red, and the words are in the cell either
/// way - the wash is the second way to read it, never the only one.
const String kResponsibilityNoteFill = 'FFF3D6';
const String kResponsibilityNoteInk = '7A4E00';

/// How many lines answered one ROOM in words rather than a count.
///
/// The other way round from [ResponsibilityItem.noteCount], which counts the
/// rooms on one line. The totals row at the foot of the sheet adds a column
/// per room, so it needs this one - and without it that row is the one figure
/// on the document that gives no sign of what it left out.
int responsibilityNotesInRoom(List<ResponsibilityItem> items, String roomId) =>
    items.where((i) => i.cellIsNote(roomId)).length;

/// A total with what it could not add said beside it, or the bare figure when
/// it added everything.
///
/// ONE WORDING, so the grid, the picture and the spreadsheet cannot describe
/// the same shortfall three ways.
/// A column where nothing at all could be added prints as '(+3 noted)' rather
/// than ' (+3 noted)': [formatResponsibilityQty] gives '' for a zero, and the
/// separator has nothing to separate.
String responsibilityTotalText(double total, int notes) => notes > 0
    ? '${formatResponsibilityQty(total)} (+$notes noted)'.trim()
    : formatResponsibilityQty(total);

/// The ink a room answered NONE prints in: gray on the faintest wash. It is a
/// settled answer, not a quantity, and it must not draw the eye the way a
/// number to be bought does.
const String kResponsibilityNoneFill = 'F4F4F4';
const String kResponsibilityNoneInk = '8A8A8A';

/// One room's cell for the spreadsheet: the count as plain text, or the words
/// with a wash behind them.
///
/// A plain String rather than an unwashed [XlsxTint], because a count is the
/// ordinary case and most of this grid is counts - tinting every one of them
/// white would put a fill on three hundred cells to make a point about four.
Object responsibilityQtyCell(ResponsibilityItem item, String roomId) {
  final text = item.cellText(roomId);
  if (item.cellIsNote(roomId)) {
    return XlsxTint(
      text: text,
      fillHex: kResponsibilityNoteFill,
      inkHex: kResponsibilityNoteInk,
    );
  }
  if (item.cellIsNone(roomId)) {
    return XlsxTint(
      text: text,
      fillHex: kResponsibilityNoneFill,
      inkHex: kResponsibilityNoneInk,
    );
  }
  return text;
}

/// True when what somebody typed into a cell is a COUNT rather than an answer
/// in words.
///
/// ONE RULE, in one place. The dialog says which of the two it is about to
/// save, the sheet highlights the ones that are not counts, and the totals row
/// adds up the ones that are - three readings of the same question, and a
/// second opinion anywhere among them is a cell that is highlighted and
/// counted, or counted and not shown.
///
/// A BARE '0' IS A COUNT. It is somebody saying this room gets none, which is
/// an answer and belongs with the numbers; a room nobody has answered is the
/// blank, and blank is not a count. See [ResponsibilityItem.qtyByRoom].
bool responsibilityCellIsCount(String typed) {
  final n = double.tryParse(typed.trim());
  return n != null && n >= 0;
}

/// A quantity with no trailing `.0` on it — a matrix counts screens and
/// speakers, and '2.0 screens' reads as a measurement rather than a count.
String formatResponsibilityQty(double qty) {
  if (qty <= 0) return '';
  return qty == qty.roundToDouble()
      ? qty.round().toString()
      : qty.toStringAsFixed(1);
}

/// The matrix, as tables.
///
/// [roomNames] is the room columns in the order they should appear, as
/// (id, name) pairs — passed in rather than read off a project so the sheet
/// can be rendered for a subset of rooms and so this stays free of the project
/// layer.
///
/// Two tables rather than one wide one: the GRID is what gets read across at a
/// glance and has to stay narrow enough to, and the prose — what the work is,
/// where the product is, what is still open — is what gets read one line at a
/// time. A single table carrying both is a table where neither is legible.
/// [partyColors] is the job's own color per party, keyed by
/// [responsibilityPartyKey] - see [BuildingProject.partyColors]. Empty leaves
/// every party on the color its name derives, which is what a job nobody has
/// set a color on looks like.
List<ReportSection> responsibilityMatrixSections(
  List<ResponsibilityItem> items, {
  required List<({String id, String name})> roomNames,
  Map<String, int> partyColors = const {},
}) {
  if (items.isEmpty) return const [];

  int? colorOf(String party) => partyColors[responsibilityPartyKey(party)];

  final grid = <List<dynamic>>[
    for (final item in items)
      [
        item.scope,
        responsibilityPartyCell(
          item.furnishedBy,
          color: colorOf(item.furnishedBy),
        ),
        responsibilityPartyCell(
          item.installedBy,
          color: colorOf(item.installedBy),
        ),
        item.neededBy,
        for (final room in roomNames)
          responsibilityQtyCell(item, room.id),
        // THE TOTAL SAYS WHAT IT COULD NOT ADD. 'As required' in four rooms is
        // four rooms missing from a figure the contractor bids against, and a
        // bare number gives no sign of it.
        responsibilityTotalText(item.total, item.noteCount),
      ],
  ];

  // The row a bid is checked against. Down the bottom rather than the top,
  // where a spreadsheet reader looks for a total.
  if (roomNames.isNotEmpty) {
    final noted = items.fold<int>(0, (sum, i) => sum + i.noteCount);
    grid.add([
      // The sheet's whole shortfall, beside the word that names the row - the
      // same place the screen and the picture carry it.
      noted > 0 ? 'Totals (+$noted noted)' : 'Totals',
      '',
      '',
      '',
      // EVERY TOTAL ON THE SHEET SAYS WHAT IT LEFT OUT, this row included.
      // A room column whose figure is 6 when nine lines mention the room is a
      // figure somebody has to be told about.
      for (final room in roomNames)
        responsibilityTotalText(
          items.fold<double>(0, (sum, i) => sum + (i.qtyByRoom[room.id] ?? 0)),
          responsibilityNotesInRoom(items, room.id),
        ),
      responsibilityTotalText(
        items.fold<double>(0, (sum, i) => sum + i.total),
        items.fold<int>(0, (sum, i) => sum + i.noteCount),
      ),
    ]);
  }

  final sections = <ReportSection>[
    (
      title: 'Roles and Responsibilities',
      header: [
        'Scope',
        'Furnished by',
        'Installed by',
        'Equipment needed by',
        for (final room in roomNames) room.name,
        'Total',
      ],
      rows: grid,
    ),
    // EVERY LINE, WHETHER IT HAS PROSE ON IT OR NOT. A table that skipped the
    // blank ones would read as a shorter matrix than the one being issued -
    // and a line with nothing said about it is itself worth seeing.
    //
    // The cutsheet is named AND linked. The name is what somebody holding the
    // printout searches the job folder for; the link is what the person with
    // the file open needs, and it is routinely a path too long to read.
    (
      title: 'Description of Work',
      header: const [
        'Scope',
        'What the work is',
        'Cutsheet',
        'Product or cutsheet link',
        'Notes',
      ],
      rows: [
        for (final item in items)
          [
            item.scope,
            item.work,
            item.productName,
            item.productLink,
            item.notes,
          ],
      ],
    ),
  ];

  // What is still to be agreed, called out on its own. A matrix issued with
  // four blank parties reads as complete unless somebody counts the blanks,
  // and the whole document exists to stop exactly that kind of assumption.
  final open = items.where((i) => i.unassigned).toList();
  if (open.isNotEmpty) {
    sections.add((
      title: 'Still To Be Agreed',
      header: const ['Scope', 'Furnished by', 'Installed by'],
      rows: [
        for (final item in open)
          [
            item.scope,
            responsibilityPartyCell(
              item.furnishedBy,
              missingLabel: 'NOT AGREED',
              color: colorOf(item.furnishedBy),
            ),
            responsibilityPartyCell(
              item.installedBy,
              missingLabel: 'NOT AGREED',
              color: colorOf(item.installedBy),
            ),
          ],
      ],
    ));
  }

  return sections;
}
