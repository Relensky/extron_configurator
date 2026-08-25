import 'report_tools.dart';

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

  /// Room id ([ProjectRoomRef.id]) -> how many. Rooms with none are simply
  /// absent rather than stored as zero.
  final Map<String, double> qtyByRoom;

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
    this.work = '',
    this.productLink = '',
    this.notes = '',
  }) : qtyByRoom = qtyByRoom ?? const {};

  /// How many of these the whole job needs — the number a bid is written
  /// against.
  double get total =>
      qtyByRoom.values.fold<double>(0, (sum, q) => sum + q);

  /// True when neither party has been settled. The matrix's own to-do list.
  bool get unassigned =>
      furnishedBy.trim().isEmpty || installedBy.trim().isEmpty;

  ResponsibilityItem copyWith({
    String? scope,
    String? furnishedBy,
    String? installedBy,
    String? neededBy,
    Map<String, double>? qtyByRoom,
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
  ResponsibilityItem withRoomQty(String roomId, double qty) {
    final next = Map<String, double>.from(qtyByRoom);
    if (qty > 0) {
      next[roomId] = qty;
    } else {
      next.remove(roomId);
    }
    return copyWith(qtyByRoom: next);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'scope': scope,
    if (furnishedBy.isNotEmpty) 'furnishedBy': furnishedBy,
    if (installedBy.isNotEmpty) 'installedBy': installedBy,
    if (neededBy.isNotEmpty) 'neededBy': neededBy,
    if (qtyByRoom.isNotEmpty) 'qtyByRoom': qtyByRoom,
    if (work.isNotEmpty) 'work': work,
    if (productLink.isNotEmpty) 'productLink': productLink,
    if (notes.isNotEmpty) 'notes': notes,
  };

  factory ResponsibilityItem.fromJson(Map<String, dynamic> json) {
    final qty = <String, double>{};
    final raw = json['qtyByRoom'];
    if (raw is Map) {
      raw.forEach((k, v) {
        final n = v is num ? v.toDouble() : double.tryParse(v.toString());
        // A quantity that is not a number is dropped rather than read as
        // zero: "2 per room" typed into a count is somebody's note, and
        // honouring it as 0 would quietly take the line off the bid.
        if (n != null && n > 0) qty[k.toString()] = n;
      });
    }
    return ResponsibilityItem(
      id: json['id']?.toString() ?? '',
      scope: json['scope']?.toString() ?? '',
      furnishedBy: json['furnishedBy']?.toString() ?? '',
      installedBy: json['installedBy']?.toString() ?? '',
      neededBy: json['neededBy']?.toString() ?? '',
      qtyByRoom: qty,
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
List<ReportSection> responsibilityMatrixSections(
  List<ResponsibilityItem> items, {
  required List<({String id, String name})> roomNames,
}) {
  if (items.isEmpty) return const [];

  final grid = <List<dynamic>>[
    for (final item in items)
      [
        item.scope,
        item.furnishedBy,
        item.installedBy,
        item.neededBy,
        for (final room in roomNames)
          formatResponsibilityQty(item.qtyByRoom[room.id] ?? 0),
        formatResponsibilityQty(item.total),
      ],
  ];

  // The row a bid is checked against. Down the bottom rather than the top,
  // where a spreadsheet reader looks for a total.
  if (roomNames.isNotEmpty) {
    grid.add([
      'Totals',
      '',
      '',
      '',
      for (final room in roomNames)
        formatResponsibilityQty(
          items.fold<double>(0, (sum, i) => sum + (i.qtyByRoom[room.id] ?? 0)),
        ),
      formatResponsibilityQty(
        items.fold<double>(0, (sum, i) => sum + i.total),
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
    (
      title: 'Description of Work',
      header: const ['Scope', 'What the work is', 'Product', 'Notes'],
      rows: [
        for (final item in items)
          [item.scope, item.work, item.productLink, item.notes],
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
            item.furnishedBy.isEmpty ? 'NOT AGREED' : item.furnishedBy,
            item.installedBy.isEmpty ? 'NOT AGREED' : item.installedBy,
          ],
      ],
    ));
  }

  return sections;
}
