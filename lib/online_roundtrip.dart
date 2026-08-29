import 'dart:typed_data';

import 'building_project.dart';
import 'cost_estimate.dart' show trimNumber;
import 'xlsx_reader.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  THE TWO SHEETS THAT COME BACK
/// ============================================================================
///  The published copy of a job (see online_copy.dart) is a spreadsheet other
///  people can open, and the moment somebody can open it they type in it. Up
///  to now those edits went nowhere: the next publish overwrote them, and the
///  person who typed had no way to know.
///
///  So two of the sheets in the published copy are a CONTRACT rather than a
///  report. They have a stable shape, a row id on every line, and nothing in
///  them that has to be read as prose — and the app can read them back.
///
///  WHY NOT READ THE REPORT SHEETS. The Purchasing sheet is stacked tables
///  under prose headings, sized and banded for a person reading it. Parsing
///  that back would mean a document that could never be re-laid-out without
///  silently breaking the import, and an import that broke differently
///  depending on which section somebody had typed in. A report is for reading;
///  a round trip needs a form.
///
///  THE ROW ID IS THE JOIN, and a blank one means ADD. That is the whole
///  protocol: a technician who logs a delivery on a phone types a line with no
///  id and it arrives as a new delivery; an edit to an existing line finds its
///  record by the id it was written with. Ids are the app's own — `del4`,
///  `po2` — and nobody has to understand them, only leave them alone.
///
///  NOTHING IS EVER DELETED. A row missing from the sheet is a row somebody
///  filtered, sorted away, or never scrolled to — not an instruction to remove
///  a delivery from the job. Removing things stays a decision made in the app,
///  in front of the record being removed.
///
///  DATES AND FLAGS ARE TEXT. '2026-04-20' rather than a date cell, 'one-off'
///  rather than a tick: a date cell is a serial number in a format the two
///  spreadsheet programs disagree about, and text is what both of them hand
///  back unchanged. See the note at the head of xlsx_reader.dart.
/// ============================================================================

/// The delivery log, as a form somebody can fill in.
const String kEditableDeliveriesSheet = 'Deliveries (edit)';

/// The purchase orders, likewise.
const String kEditablePosSheet = 'Purchase orders (edit)';

/// The first column on both sheets, and how the header row is found again
/// after somebody has inserted a line above it.
const String kRoundTripIdColumn = 'Row id';

/// What the note column says, on both sheets. Read and then forgotten: an
/// entry here becomes a new signed note on the record, and the column comes
/// back empty on the next publish, because a note is an event rather than a
/// field with a current value.
const String kRoundTripNoteColumn = 'Add a note';

/// The 'bought on' answer that means a card purchase — see
/// [ProjectDelivery.oneOff]. Matched loosely on the way in, because somebody
/// will type 'P-Card' or 'one off'.
const String kOneOffText = 'One-off - P-Card';

bool _readsAsOneOff(String text) {
  final t = text.trim().toLowerCase().replaceAll(RegExp(r'[\s_]+'), '-');
  return t == 'one-off' ||
      t == 'oneoff' ||
      t == 'p-card' ||
      t == 'pcard' ||
      t.startsWith('one-off');
}

// ---------------------------------------------------------------------------
//  WRITING THEM
// ---------------------------------------------------------------------------

/// The two lines above the table on both sheets: what this is, and the three
/// rules somebody has to know before they type.
List<List<dynamic>> _preamble(String title, String rules, int width) {
  List<dynamic> pad(List<dynamic> row) => [
    ...row,
    ...List.filled(width - row.length, ''),
  ];
  return [pad([title]), pad([rules]), pad([''])];
}

/// The delivery log as an editable sheet.
///
/// [roomNames] maps room id to the name the Room column shows and is matched
/// back against — the building code and number, the same as everywhere else.
XlsxSheet buildEditableDeliveriesSheet(
  BuildingProject project, {
  required Map<String, String> roomNames,
}) {
  const header = [
    kRoundTripIdColumn,
    'What',
    'Qty',
    'Bought on',
    'Arrived',
    'Where is it',
    'Delivered to / held at',
    'Room',
    'Installed',
    kRoundTripNoteColumn,
  ];

  final rows = <List<dynamic>>[
    ..._preamble(
      'Deliveries you can edit - this sheet is read back into the app',
      'Type over any cell. Leave the Row id alone. To log something new, '
          'add a line and leave its Row id blank. Dates as 2026-04-20. '
          'Deleting a line here does NOT remove it from the job.',
      header.length,
    ),
    header,
    for (final d in [...project.deliveries]..sort(
      (a, b) => a.id.compareTo(b.id),
    ))
      [
        d.id,
        d.itemName.trim(),
        d.qty == 0 ? '' : trimNumber(d.qty),
        d.poNumber.trim().isNotEmpty
            ? d.poNumber.trim()
            : d.oneOff
            ? kOneOffText
            : '',
        d.deliveredOn == null ? '' : formatIsoDate(d.deliveredOn!),
        d.state.label,
        d.location.trim(),
        roomNames[d.roomId] ?? '',
        d.installedOn == null ? '' : formatIsoDate(d.installedOn!),
        // Always blank: what was said before is already on the record, and a
        // column that came back full of old notes would add every one of them
        // again on every import.
        '',
      ],
  ];

  return XlsxSheet(
    name: kEditableDeliveriesSheet,
    rows: rows,
    rowStyles: const {0: XlsxRowStyle.title, 3: XlsxRowStyle.header},
    columnWidths: const {1: 34, 6: 30, 9: 34},
  );
}

/// The purchase orders as an editable sheet.
XlsxSheet buildEditablePosSheet(BuildingProject project) {
  const header = [
    kRoundTripIdColumn,
    'PO',
    'Vendor',
    'Raised',
    'Vendor promised',
    'Raised for',
    kRoundTripNoteColumn,
  ];

  String vendorOf(ProjectPo po) {
    for (final v in project.vendors) {
      if (v.id == po.vendorId) return v.name;
    }
    return po.vendor.trim();
  }

  final rows = <List<dynamic>>[
    ..._preamble(
      'Purchase orders you can edit - this sheet is read back into the app',
      'Type over any cell. Leave the Row id alone. To add a PO, add a line '
          'and leave its Row id blank. Dates as 2026-04-20. Deleting a line '
          'here does NOT remove it from the job.',
      header.length,
    ),
    header,
    for (final po in project.purchaseOrders)
      [
        po.id,
        po.number.trim(),
        vendorOf(po),
        po.issuedOn == null ? '' : formatIsoDate(po.issuedOn!),
        po.expectedOn == null ? '' : formatIsoDate(po.expectedOn!),
        po.amount == 0 ? '' : trimNumber(po.amount),
        '',
      ],
  ];

  return XlsxSheet(
    name: kEditablePosSheet,
    rows: rows,
    rowStyles: const {0: XlsxRowStyle.title, 3: XlsxRowStyle.header},
    columnWidths: const {2: 24, 6: 34},
  );
}

// ---------------------------------------------------------------------------
//  READING THEM BACK
// ---------------------------------------------------------------------------

/// One delivery line, as it came back off the sheet.
///
/// Every field is what the app would store, already parsed — so applying it is
/// a copy rather than a second round of interpretation, and anything that
/// could not be understood has already been reported in [problems].
class ParsedDelivery {
  /// The row it belongs to, or '' for a line somebody added.
  final String id;
  final String itemName;
  final double qty;
  final String poNumber;
  final bool oneOff;
  final DateTime? deliveredOn;
  final DeliveryState state;
  final String location;
  final String roomId;
  final DateTime? installedOn;

  /// A note to sign onto the record. Appended, never replacing what is there.
  final String note;

  const ParsedDelivery({
    required this.id,
    this.itemName = '',
    this.qty = 0,
    this.poNumber = '',
    this.oneOff = false,
    this.deliveredOn,
    this.state = DeliveryState.delivered,
    this.location = '',
    this.roomId = '',
    this.installedOn,
    this.note = '',
  });

  bool get isNew => id.trim().isEmpty;
}

/// One purchase order line, as it came back.
class ParsedPo {
  final String id;
  final String number;
  final String vendorId;
  final String vendor;
  final DateTime? issuedOn;
  final DateTime? expectedOn;
  final double amount;
  final String note;

  const ParsedPo({
    required this.id,
    this.number = '',
    this.vendorId = '',
    this.vendor = '',
    this.issuedOn,
    this.expectedOn,
    this.amount = 0,
    this.note = '',
  });

  bool get isNew => id.trim().isEmpty;
}

/// What one .xlsx had to say when it was read back.
typedef OnlineImport = ({
  List<ParsedDelivery> deliveries,
  List<ParsedPo> pos,

  /// Anything that could not be understood, in the words a person can act on:
  /// 'Row del4: "next Tuesday" is not a date (2026-04-20), left as it was.'
  ///
  /// REPORTED, NEVER GUESSED AT. A cell this cannot read leaves the record
  /// alone and says so — the alternative is an import that quietly writes its
  /// best guess into a job nobody is going to re-check.
  List<String> problems,

  /// True when the file has neither editable sheet — almost always the wrong
  /// file rather than an empty one.
  bool wrongFile,
});

/// Reads both editable sheets out of a published workbook.
///
/// [roomIdsByName] maps the Room column's text back to a room id, matched
/// case-insensitively. [vendorIdsByName] does the same for the PO sheet's
/// Vendor column; a vendor that is not on the job's list is kept as typed
/// rather than refused, exactly as the PO dialog allows.
OnlineImport readOnlineEdits(
  Uint8List bytes, {
  Map<String, String> roomIdsByName = const {},
  Map<String, String> vendorIdsByName = const {},
  BuildingProject? against,
}) {
  final problems = <String>[];
  final sheets = readXlsxSheets(bytes);
  final hasDeliveries = sheets.containsKey(kEditableDeliveriesSheet);
  final hasPos = sheets.containsKey(kEditablePosSheet);
  if (!hasDeliveries && !hasPos) {
    return (
      deliveries: const [],
      pos: const [],
      problems: const [],
      wrongFile: true,
    );
  }

  DateTime? date(String raw, String where, String column) {
    if (raw.trim().isEmpty) return null;
    final parsed = parseIsoDate(raw.trim());
    if (parsed == null) {
      problems.add(
        '$where: $column reads "$raw", which is not a date like 2026-04-20 - '
        'left as it was.',
      );
    }
    return parsed;
  }

  final deliveries = <ParsedDelivery>[];
  if (hasDeliveries) {
    final rows = readXlsxTable(
      bytes,
      kEditableDeliveriesSheet,
      headerMarker: kRoundTripIdColumn,
    );
    for (final row in rows) {
      final id = (row[kRoundTripIdColumn.toLowerCase()] ?? '').trim();
      final where = id.isEmpty ? 'A new line' : 'Row $id';
      final existing = id.isEmpty ? null : against?.deliveryById(id);
      if (id.isNotEmpty && against != null && existing == null) {
        problems.add(
          '$where is not a delivery on this job - it was probably removed '
          'here after the copy went out. Skipped.',
        );
        continue;
      }

      final bought = (row['bought on'] ?? '').trim();
      final oneOff = _readsAsOneOff(bought);
      final stateText = (row['where is it'] ?? '').trim();
      var state = existing?.state ?? DeliveryState.delivered;
      if (stateText.isNotEmpty) {
        final match = _stateFromLabel(stateText);
        if (match == null) {
          problems.add(
            '$where: "$stateText" is not one of '
            '${DeliveryState.values.map((s) => s.label).join(', ')} - left as '
            'it was.',
          );
        } else {
          state = match;
        }
      }

      final roomText = (row['room'] ?? '').trim();
      var roomId = existing?.roomId ?? '';
      if (roomText.isEmpty) {
        roomId = '';
      } else {
        final match = roomIdsByName[roomText.toLowerCase()];
        if (match == null) {
          problems.add(
            '$where: there is no room called "$roomText" on this job - the '
            'room was left as it was.',
          );
        } else {
          roomId = match;
        }
      }

      final qtyText = (row['qty'] ?? '').trim();
      var qty = 0.0;
      if (qtyText.isNotEmpty) {
        final parsed = double.tryParse(qtyText.replaceAll(',', ''));
        if (parsed == null) {
          problems.add('$where: "$qtyText" is not a number of units - left as '
              'it was.');
          qty = existing?.qty ?? 0;
        } else {
          qty = parsed;
        }
      }

      deliveries.add(ParsedDelivery(
        id: id,
        itemName: (row['what'] ?? '').trim(),
        qty: qty,
        poNumber: oneOff ? '' : bought,
        oneOff: oneOff,
        deliveredOn:
            date(row['arrived'] ?? '', where, 'Arrived') ??
            existing?.deliveredOn,
        state: state,
        location: (row['delivered to / held at'] ?? '').trim(),
        roomId: roomId,
        installedOn:
            date(row['installed'] ?? '', where, 'Installed') ??
            existing?.installedOn,
        note: (row[kRoundTripNoteColumn.toLowerCase()] ?? '').trim(),
      ));
    }
  }

  final pos = <ParsedPo>[];
  if (hasPos) {
    final rows = readXlsxTable(
      bytes,
      kEditablePosSheet,
      headerMarker: kRoundTripIdColumn,
    );
    for (final row in rows) {
      final id = (row[kRoundTripIdColumn.toLowerCase()] ?? '').trim();
      final where = id.isEmpty ? 'A new PO line' : 'Row $id';
      final existing = id.isEmpty ? null : against?.poById(id);
      if (id.isNotEmpty && against != null && existing == null) {
        problems.add(
          '$where is not a purchase order on this job - it was probably '
          'removed here after the copy went out. Skipped.',
        );
        continue;
      }

      final number = (row['po'] ?? '').trim();
      if (number.isEmpty) {
        problems.add(
          '$where has no PO number, and a purchase order is the number - '
          'skipped.',
        );
        continue;
      }

      final vendorText = (row['vendor'] ?? '').trim();
      final vendorId = vendorIdsByName[vendorText.toLowerCase()] ?? '';

      final amountText = (row['raised for'] ?? '')
          .replaceAll(RegExp(r'[^0-9.\-]'), '')
          .trim();
      final amount = amountText.isEmpty
          ? 0.0
          : (double.tryParse(amountText) ?? existing?.amount ?? 0);

      pos.add(ParsedPo(
        id: id,
        number: number,
        vendorId: vendorId,
        vendor: vendorId.isEmpty ? vendorText : '',
        issuedOn: date(row['raised'] ?? '', where, 'Raised') ??
            existing?.issuedOn,
        expectedOn:
            date(row['vendor promised'] ?? '', where, 'Vendor promised') ??
            existing?.expectedOn,
        amount: amount,
        note: (row[kRoundTripNoteColumn.toLowerCase()] ?? '').trim(),
      ));
    }
  }

  return (
    deliveries: deliveries,
    pos: pos,
    problems: problems,
    wrongFile: false,
  );
}

/// A [DeliveryState] by the label the sheet shows, or null when it is not one.
DeliveryState? _stateFromLabel(String label) {
  final needle = label.trim().toLowerCase();
  for (final s in DeliveryState.values) {
    if (s.label.toLowerCase() == needle) return s;
  }
  return null;
}

// ---------------------------------------------------------------------------
//  WHAT WOULD CHANGE
// ---------------------------------------------------------------------------

/// One thing an import would do, in the words it is shown and logged in.
typedef OnlineChange = ({
  /// 'delivery' or 'purchase order' — what kind of record.
  String kind,

  /// The record's id, or '' for one that would be created.
  String id,

  /// What the record is called, for a person reading the list.
  String name,

  /// 'Qty: 6 -> 8', 'added', 'note added'.
  String what,
});

/// Everything the import would change, worked out before anything is written.
///
/// SHOWN BEFORE IT IS APPLIED, always. An import is somebody else's typing
/// arriving in your job: a list of exactly what it would do, checked once, is
/// the difference between a feature people use and a feature people are
/// frightened of.
List<OnlineChange> onlineChanges(BuildingProject project, OnlineImport read) {
  final out = <OnlineChange>[];

  for (final d in read.deliveries) {
    final name = d.itemName.trim().isEmpty ? 'a delivery' : d.itemName.trim();
    if (d.isNew) {
      out.add((
        kind: 'delivery',
        id: '',
        name: name,
        what: 'added - ${trimNumber(d.qty)} ${d.state.phrase}',
      ));
      continue;
    }
    final was = project.deliveryById(d.id);
    if (was == null) continue;
    final fields = <String>[
      if (was.itemName.trim() != d.itemName) 'name',
      if (was.qty != d.qty) 'Qty ${trimNumber(was.qty)} -> ${trimNumber(d.qty)}',
      if (was.poNumber.trim() != d.poNumber.trim() || was.oneOff != d.oneOff)
        'bought on',
      if (was.deliveredOn != d.deliveredOn) 'arrived',
      if (was.state != d.state) '${was.state.label} -> ${d.state.label}',
      if (was.location.trim() != d.location.trim()) 'where it is held',
      if (was.roomId != d.roomId) 'room',
      if (was.installedOn != d.installedOn) 'installed',
    ];
    if (fields.isNotEmpty) {
      out.add((
        kind: 'delivery',
        id: d.id,
        name: name,
        what: fields.join(', '),
      ));
    }
    if (d.note.isNotEmpty) {
      out.add((kind: 'delivery', id: d.id, name: name, what: 'note added'));
    }
  }

  for (final po in read.pos) {
    final name = po.number.trim();
    if (po.isNew) {
      // A number the job already has is the same paperwork, not a second row -
      // see [BuildingProject.addPo].
      final already = project.poByNumber(po.number);
      out.add((
        kind: 'purchase order',
        id: already?.id ?? '',
        name: name,
        what: already == null ? 'added' : 'already on the job - details only',
      ));
      continue;
    }
    final was = project.poById(po.id);
    if (was == null) continue;
    final fields = <String>[
      if (normalizePoNumber(was.number) != normalizePoNumber(po.number))
        'number ${was.number} -> ${po.number}',
      if (was.vendorId != po.vendorId || was.vendor.trim() != po.vendor.trim())
        'vendor',
      if (was.issuedOn != po.issuedOn) 'raised',
      if (was.expectedOn != po.expectedOn) 'promised',
      if (was.amount != po.amount) 'raised for',
    ];
    if (fields.isNotEmpty) {
      out.add((
        kind: 'purchase order',
        id: po.id,
        name: name,
        what: fields.join(', '),
      ));
    }
    if (po.note.isNotEmpty) {
      out.add((
        kind: 'purchase order',
        id: po.id,
        name: name,
        what: 'note added',
      ));
    }
  }

  return out;
}
