import 'dart:typed_data';

import 'av_device_library.dart';
import 'base_costs.dart';
import 'building_project.dart';
import 'class_schedule.dart' show ClassScheduleIndex;
import 'control_gaps.dart';
import 'cost_estimate.dart';
import 'equipment_lifecycle.dart';
import 'online_roundtrip.dart';
import 'project_estimate.dart';
import 'project_schedule.dart';
import 'report_tools.dart';
import 'procurement_log.dart';
import 'procurement_sync.dart';
import 'responsibility_matrix.dart';
import 'schedule_workbook.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  THE PROJECT WORKBOOK, AND THE QUOTE REQUESTS THAT COME OUT OF IT
/// ============================================================================
///  Two documents, built from the same rollup so they cannot disagree:
///
///  THE PROJECT WORKBOOK — everything, for the file and for the stakeholder:
///
///    Summary       — what the building costs, and the same figure broken back
///                    down to one row per room
///    Core Components — every part once, quantities merged across rooms, with the
///                    vendor it is tagged to and which rooms it is for
///    <Vendor>      — one tab per vendor: exactly what that company is being
///                    asked to quote
///    <Room>        — one tab per room, its own estimate in full
///
///  THE VENDOR RFQ — one .xlsx per vendor, holding only that vendor's parts.
///  This is the file that gets emailed, which is why it is a separate document
///  rather than "the workbook, tell them to look at tab six": sending the whole
///  book sends every other vendor's pricing to a competitor, and sends the
///  stakeholder's labor rates and margins to a supplier. A quote request contains
///  what is being asked for and nothing else.
///
///  Both are dealt from [ProjectEstimate], and the room tabs from the SAME
///  [costReportSections] the room's own Cost tab and room workbook use — so a
///  room's numbers are identical in the room's book and in the building's.
/// ============================================================================

/// The fixed sheets, in workbook order. Vendor and room tabs follow.
const List<String> kProjectWorkbookSheets = ['Summary', 'Core Components'];

/// A part's cells on the master sheet, as references a room's line reads:
/// its name, model, part number and - when it has one price - unit price.
typedef MasterCellRefs = ({
  String name,
  String model,
  String part,
  String? unit,

  /// The master sheet and the part's name cell on it, for a link back.
  String sheet,
  String cell,
});

/// [MasterCellRefs] by master key.
typedef MasterPriceCells = Map<String, MasterCellRefs>;

/// A sheet name as a formula writes it.
String _sheetRef(String name) => "'${name.replaceAll("'", "''")}'";

/// Text read from another cell. `&""` keeps a blank cell blank rather than
/// showing it as 0.
XlsxTextFormula _textFrom(String ref, Object? cached) =>
    XlsxTextFormula('$ref&""', cached?.toString() ?? '');

/// A part's name that reads from, and jumps to, its row on the master list.
XlsxLink _nameLink(MasterCellRefs refs, Object? cached) => XlsxLink(
      text: cached?.toString() ?? '',
      sheet: refs.sheet,
      cell: refs.cell,
      formula: '${refs.name}&""',
    );

/// Links every other part table in the book back to the master list: each
/// part's name jumps to its row there, and its model and single unit price
/// read from it. Tables are found by a first column headed Part or Item, and
/// a row by its name - a name two parts share is left alone.
void _linkPartTables(
  XlsxSheet sheet,
  ProjectEstimate estimate,
  MasterPriceCells cells,
) {
  final byName = <String, List<MasterPartLine>>{};
  for (final l in estimate.master) {
    if (!cells.containsKey(l.key)) continue;
    (byName[l.description] ??= []).add(l);
  }
  List<dynamic>? header;
  for (var r = 0; r < sheet.rows.length; r++) {
    final style = sheet.rowStyles[r];
    final row = sheet.rows[r];
    if (style == XlsxRowStyle.title) {
      header = null;
      continue;
    }
    if (style == XlsxRowStyle.header) {
      header = row.isNotEmpty && (row.first == 'Part' || row.first == 'Item')
          ? row
          : null;
      continue;
    }
    if (header == null || row.isEmpty) continue;
    final first = row.first;
    if (first is! String) continue;
    final matches = byName[first];
    if (matches == null || matches.length != 1) continue;
    final line = matches.single;
    final refs = cells[line.key]!;
    row[0] = _nameLink(refs, first);

    final model = header.indexOf('Model');
    if (model > 0 && model < row.length && row[model] == line.model) {
      row[model] = _textFrom(refs.model, line.model);
    }
    final unit = header.indexOf('Unit price');
    final price = refs.unit;
    if (price != null &&
        unit > 0 &&
        unit < row.length &&
        row[unit] is XlsxMoney &&
        ((row[unit] as XlsxMoney).value - line.unitPrice).abs() <= 0.005) {
      row[unit] = XlsxFormula(price, row[unit] as XlsxMoney);
    }
  }
}

/// Finds each part's row on the built master [sheet], makes its Extended a
/// formula of its own Qty and Unit price, and returns where every part's
/// cells are.
///
/// Read off the BUILT sheet, not worked out from the sections: the builder
/// can lift a long column out of the grid, which moves every column after it.
MasterPriceCells _linkMasterSheet(XlsxSheet sheet, ProjectEstimate estimate) {
  final out = <String, MasterCellRefs>{};
  final tab = _sheetRef(sheet.name);
  var r = 0;
  for (final kind in MasterPartKind.values) {
    final lines = [for (final l in estimate.master) if (l.kind == kind) l];
    if (lines.isEmpty) continue;
    // This kind's header row.
    int name = -1, model = -1, part = -1, qty = -1, unit = -1, ext = -1;
    for (; r < sheet.rows.length; r++) {
      final row = sheet.rows[r];
      unit = row.indexWhere((c) => c == 'Unit price');
      if (unit < 0) continue;
      name = row.indexWhere((c) => c == 'Part');
      model = row.indexWhere((c) => c == 'Model');
      part = row.indexWhere((c) => c == 'Part number');
      qty = row.indexWhere((c) => c == 'Qty');
      ext = row.indexWhere((c) => c == 'Extended');
      r++;
      break;
    }
    if ([name, model, part, qty, unit, ext].any((i) => i < 0)) return out;
    String at(int col) => '${xlsxColumnLetter(col)}${r + 1}';
    for (final l in lines) {
      while (r < sheet.rows.length &&
          (sheet.rows[r].isEmpty || sheet.rows[r].first != l.description)) {
        r++;
      }
      if (r >= sheet.rows.length) return out;
      final row = sheet.rows[r];
      final priced = row[unit] is XlsxMoney;
      if (priced && row[ext] is XlsxMoney) {
        row[ext] = XlsxFormula('${at(qty)}*${at(unit)}', row[ext] as XlsxMoney);
      }
      out[l.key] = (
        name: '$tab!${at(name)}',
        model: '$tab!${at(model)}',
        part: '$tab!${at(part)}',
        unit: priced ? '$tab!${at(unit)}' : null,
        sheet: sheet.name,
        cell: at(name),
      );
      r++;
    }
  }
  return out;
}

/// The master cells [line] in a room reads from, or null when it is not on
/// the master list. [MasterCellRefs.unit] is null when the line keeps its own
/// price: somebody else furnishes it, or the room prices it differently.
MasterCellRefs? _masterCellFor(
  ProjectEstimate estimate,
  MasterPriceCells cells,
  MasterPartKind kind,
  CostLine line,
) {
  if (line.qty <= 0) return null;
  final key = masterPartKey(
    kind: kind.name,
    partNumber: line.partNumber,
    model: line.model,
    manufacturer: line.manufacturer,
    description: line.description,
  );
  final refs = cells[key];
  if (refs == null) return null;
  final master = estimate.master.firstWhere((m) => m.key == key);
  final samePrice = refs.unit != null &&
      !line.furnished &&
      (master.unitPrice - line.unitPrice).abs() <= 0.005;
  return (
    name: refs.name,
    model: refs.model,
    part: refs.part,
    unit: samePrice ? refs.unit : null,
    sheet: refs.sheet,
    cell: refs.cell,
  );
}

/// One row of a room or All Items sheet, with its cells reading from the
/// master list. -1 skips a column the section does not have.
List<dynamic> _linkRow(
  List<dynamic> row,
  MasterCellRefs refs,
  CostLine line, {
  required int name,
  required int model,
  required int part,
  required int unit,
  required int ext,
}) {
  final out = [...row];
  // The spare split is written into the name, so that one keeps its own.
  if (name >= 0 && line.spareQty <= 0) {
    out[name] = _nameLink(refs, out[name]);
  }
  if (model >= 0) out[model] = _textFrom(refs.model, out[model]);
  if (part >= 0) out[part] = _textFrom(refs.part, out[part]);
  final price = refs.unit;
  if (price != null &&
      unit >= 0 &&
      ext >= 0 &&
      out[unit] is XlsxMoney &&
      out[ext] is XlsxMoney) {
    out[unit] = XlsxFormula(price, out[unit] as XlsxMoney);
    out[ext] = XlsxFormula(
      '${trimNumber(line.qty)}*$price',
      out[ext] as XlsxMoney,
    );
  }
  return out;
}

/// [sections] from one room's cost sheet, with each line reading its name,
/// model, part number and price from the master list where it can.
List<ReportSection> _linkRoomSections(
  List<ReportSection> sections,
  CostEstimate estimate,
  ProjectEstimate project,
  MasterPriceCells cells,
) {
  final byTitle = <String, (MasterPartKind, List<CostLine>)>{
    'Equipment': (MasterPartKind.equipment, estimate.equipment),
    'Rack Hardware': (MasterPartKind.hardware, estimate.hardware),
    'Cabling': (MasterPartKind.cabling, estimate.cabling),
    'Other Items': (MasterPartKind.other, estimate.extras),
  };
  return [
    for (final s in sections)
      () {
        final match = byTitle[s.title];
        if (match == null) return s;
        final (kind, lines) = match;
        if (lines.length != s.rows.length) return s;
        final rows = <List<dynamic>>[
          for (var i = 0; i < lines.length; i++)
            () {
              final refs = _masterCellFor(project, cells, kind, lines[i]);
              if (refs == null) return s.rows[i];
              return _linkRow(
                s.rows[i],
                refs,
                lines[i],
                name: 0,
                model: s.header.indexOf('Model'),
                part: s.header.indexOf('Part number'),
                unit: s.header.indexOf('Unit price'),
                ext: s.header.indexOf('Extended'),
              );
            }(),
        ];
        return (title: s.title, header: s.header, rows: rows);
      }(),
  ];
}

// ---------------------------------------------------------------------------
//  TOTALS AS FORMULAS
// ---------------------------------------------------------------------------
//  A price edited on the master list changes the lines; these make the sums
//  under them follow too.

/// Where a section's figures are on a built sheet: its Extended column and
/// the first and last data rows (0-based), or null when it is not there.
({int col, int first, int last})? _sectionRange(
  XlsxSheet sheet,
  String title, {
  String column = 'Extended',
}) {
  for (var r = 0; r < sheet.rows.length - 1; r++) {
    final row = sheet.rows[r];
    if (sheet.rowStyles[r] != XlsxRowStyle.title) continue;
    if (row.isEmpty || row.first != title) continue;
    final col = sheet.rows[r + 1].indexOf(column);
    if (col < 0) return null;
    var last = -1;
    for (var i = r + 2; i < sheet.rows.length; i++) {
      if (sheet.rowStyles[i] == XlsxRowStyle.title) break;
      final cells = sheet.rows[i];
      if (cells.every((c) => c == null || c.toString().isEmpty)) break;
      last = i;
    }
    if (last < 0) return null;
    return (col: col, first: r + 2, last: last);
  }
  return null;
}

String _cell(int col, int row) => '${xlsxColumnLetter(col)}${row + 1}';

String? _sumOf(XlsxSheet sheet, String title) {
  final s = _sectionRange(sheet, title);
  if (s == null) return null;
  return 'SUM(${_cell(s.col, s.first)}:${_cell(s.col, s.last)})';
}

/// The key/value rows of [title] on a built sheet, by label, with the column
/// the amounts are in.
({int col, Map<String, int> rows})? _keyValueRows(
  XlsxSheet sheet,
  String title,
) {
  for (var r = 0; r < sheet.rows.length - 1; r++) {
    if (sheet.rowStyles[r] != XlsxRowStyle.title) continue;
    if (sheet.rows[r].isEmpty || sheet.rows[r].first != title) continue;
    final rows = <String, int>{};
    for (var i = r + 2; i < sheet.rows.length; i++) {
      if (sheet.rowStyles[i] == XlsxRowStyle.title) break;
      final cells = sheet.rows[i];
      if (cells.isEmpty || cells.first.toString().isEmpty) break;
      rows.putIfAbsent(cells.first.toString(), () => i);
    }
    return (col: 1, rows: rows);
  }
  return null;
}

/// Replaces the money in [row], [col] with [formula], keeping its figure.
void _setFormula(XlsxSheet sheet, int row, int col, String formula) {
  final cells = sheet.rows[row];
  if (col >= cells.length) return;
  final value = cells[col];
  final cached = value is XlsxMoney
      ? value
      : value is XlsxFormula
      ? value.cached
      : null;
  if (cached == null) return;
  cells[col] = XlsxFormula(formula, cached);
}

/// Where a room's own totals are, for the sheets that sum rooms.
typedef RoomTotalRefs = ({
  String? equipment,
  String? hardware,
  String? cabling,
  String? extras,
  String? labor,
  String? shipping,
  String? fees,
  String? tax,
  String? total,

  /// Formulas adding the room's crew hours and total labor hours.
  String? crewHours,
  String? laborHours,
});

const RoomTotalRefs _noRoomTotals = (
  equipment: null,
  hardware: null,
  cabling: null,
  extras: null,
  labor: null,
  shipping: null,
  fees: null,
  tax: null,
  total: null,
  crewHours: null,
  laborHours: null,
);

/// Makes the Totals block on a built room [sheet] add up its own lines, and
/// returns where the room's figures are.
RoomTotalRefs _formulaRoomTotals(XlsxSheet sheet, CostEstimate e) {
  final totals = _keyValueRows(sheet, 'Totals');
  if (totals == null) return _noRoomTotals;
  final col = totals.col;
  final tab = _sheetRef(sheet.name);
  String? at(String label) {
    final r = totals.rows[label];
    return r == null ? null : _cell(col, r);
  }

  int? rowStarting(String prefix) {
    for (final entry in totals.rows.entries) {
      if (entry.key.startsWith(prefix)) return entry.value;
    }
    return null;
  }

  void set(String label, String? formula) {
    final r = totals.rows[label];
    if (r != null && formula != null) _setFormula(sheet, r, col, formula);
  }

  set('Equipment', _sumOf(sheet, 'Equipment'));
  set('Rack hardware', _sumOf(sheet, 'Rack Hardware'));
  set('Cabling', _sumOf(sheet, 'Cabling'));
  set('Other items', _sumOf(sheet, 'Other Items'));
  final laborRow = rowStarting('Labor');
  final laborSum = _sumOf(sheet, 'Labor');
  if (laborRow != null && laborSum != null) {
    _setFormula(sheet, laborRow, col, laborSum);
  }
  final labor = laborRow == null ? null : _cell(col, laborRow);

  final parts = [
    at('Equipment'),
    at('Rack hardware'),
    at('Cabling'),
    labor,
    at('Other items'),
    at('Shipping'),
  ].whereType<String>().toList();
  const subtotalLabel = 'Subtotal (before fees and tax)';
  final subtotal = at(subtotalLabel);
  if (subtotal != null && parts.isNotEmpty) {
    set(subtotalLabel, parts.join('+'));
  }

  // The fees follow the subtotal in order, each a percentage of it.
  final feeCells = <String>[];
  final taxableFeeCells = <String>[];
  var taxableFeesStatic = 0.0;
  final subRow = totals.rows[subtotalLabel];
  if (subRow != null && subtotal != null) {
    for (var i = 0; i < e.fees.length; i++) {
      final r = subRow + 1 + i;
      final f = e.fees[i];
      _setFormula(
        sheet,
        r,
        col,
        'ROUND($subtotal*${trimNumber(f.fee.percent)}/100,2)',
      );
      feeCells.add(_cell(col, r));
      if (f.fee.taxable) {
        taxableFeeCells.add(_cell(col, r));
        taxableFeesStatic += f.amount;
      }
    }
  }
  if (feeCells.length > 1) set('Fees total', feeCells.join('+'));

  String? tax;
  final taxableRow = totals.rows['Taxable amount'];
  if (taxableRow != null) {
    // What the sheet cannot see - taxed labor, shipping and other items - is
    // carried as the figure it was.
    final fixed = e.taxableBase -
        e.equipmentTotal -
        e.hardwareTotal -
        e.cablingTotal -
        taxableFeesStatic;
    final taxable = [
      at('Equipment'),
      at('Rack hardware'),
      at('Cabling'),
      ...taxableFeeCells,
    ].whereType<String>().toList();
    _setFormula(
      sheet,
      taxableRow,
      col,
      [...taxable, if (fixed.abs() > 0.005) fixed.toStringAsFixed(2)]
          .join('+'),
    );
    final taxRow = taxableRow + 1;
    _setFormula(
      sheet,
      taxRow,
      col,
      'ROUND(${_cell(col, taxableRow)}*${trimNumber(e.taxPercent)}/100,2)',
    );
    tax = _cell(col, taxRow);
  }
  final total = at('TOTAL');
  if (total != null && subtotal != null) {
    set('TOTAL', [subtotal, ...feeCells, ?tax].join('+'));
  }

  String? on(String? cell) => cell == null ? null : '$tab!$cell';
  String? hoursSum(String column) {
    final s = _sectionRange(sheet, 'Labor', column: column);
    if (s == null) return null;
    return 'SUM($tab!${_cell(s.col, s.first)}:${_cell(s.col, s.last)})';
  }

  return (
    equipment: on(at('Equipment')),
    hardware: on(at('Rack hardware')),
    cabling: on(at('Cabling')),
    extras: on(at('Other items')),
    labor: on(labor),
    shipping: on(at('Shipping')),
    fees: on(
      feeCells.isEmpty
          ? null
          : feeCells.length == 1
          ? feeCells.single
          : at('Fees total'),
    ),
    tax: on(tax),
    total: on(total),
    crewHours: hoursSum('Crew hours'),
    laborHours: hoursSum('Total hours'),
  );
}

/// Makes the Summary's Rooms table read each room's own totals, and its
/// Building total add up the rooms that count.
void _formulaSummaryTotals(
  XlsxSheet sheet,
  ProjectEstimate estimate,
  Map<String, String> roomTabs,
  Map<String, RoomTotalRefs> byTab,
) {
  final s = _sectionRange(sheet, 'Rooms', column: 'Room total');
  if (s == null) return;
  final header = sheet.rows[s.first - 1];
  int colOf(String name) => header.indexOf(name);
  final columns = <String, String? Function(RoomTotalRefs)>{
    'Equipment': (t) => t.equipment,
    'Rack hardware': (t) => t.hardware,
    'Cabling': (t) => t.cabling,
    'Other items': (t) => t.extras,
    'Labor': (t) => t.labor,
    'Shipping': (t) => t.shipping,
    'Fees': (t) => t.fees,
    'Tax': (t) => t.tax,
    'Room total': (t) => t.total,
  };

  // Row by room name, rooms in the order the table lists them.
  final counted = <String, List<String>>{
    for (final name in columns.keys) name: [],
  };
  var r = s.first;
  for (final room in estimate.rooms) {
    while (r <= s.last && sheet.rows[r].first != room.name) {
      r++;
    }
    if (r > s.last) break;
    final tab = roomTabs[room.ref.id];
    final refs = tab == null ? null : byTab[tab];
    if (refs != null) {
      columns.forEach((name, pick) {
        final c = colOf(name);
        final ref = pick(refs);
        if (c >= 0 && ref != null) _setFormula(sheet, r, c, ref);
      });
      final e = room.estimate;
      void hours(String column, String? formula, double value) {
        final c = colOf(column);
        if (c < 0 || formula == null) return;
        sheet.rows[r][c] = XlsxNumberFormula(formula, value, trimNumber(value));
      }

      if (e != null) {
        hours('Crew hrs', refs.crewHours, e.laborCrewHours);
        hours('Total labor hrs', refs.laborHours, e.laborHours);
      }
    }
    // The building's figures are the rooms that count - excluded alternates
    // and rooms that could not be read stay out, as they do in the app.
    if (room.ok && room.ref.included) {
      for (final name in columns.keys) {
        final c = colOf(name);
        if (c >= 0) counted[name]!.add(_cell(c, r));
      }
    }
    r++;
  }

  final building = _keyValueRows(sheet, 'Building total');
  if (building == null) return;
  String? sumOf(String column) {
    final cells = counted[column]!;
    return cells.isEmpty ? null : cells.join('+');
  }

  void set(String label, String? formula) {
    final row = building.rows[label];
    if (row != null && formula != null) {
      _setFormula(sheet, row, building.col, formula);
    }
  }

  int? rowStarting(String prefix) {
    for (final e in building.rows.entries) {
      if (e.key.startsWith(prefix)) return e.value;
    }
    return null;
  }

  String? at(String label) {
    final row = building.rows[label];
    return row == null ? null : _cell(building.col, row);
  }

  set('Equipment', sumOf('Equipment'));
  set('Rack hardware', sumOf('Rack hardware'));
  set('Cabling', sumOf('Cabling'));
  set('Other items', sumOf('Other items'));
  final parts = [
    at('Equipment'),
    at('Rack hardware'),
    at('Cabling'),
    at('Other items'),
  ].whereType<String>().toList();
  if (parts.isNotEmpty) set('Parts subtotal', parts.join('+'));
  final laborRow = rowStarting('Labor');
  final labor = sumOf('Labor');
  if (laborRow != null && labor != null) {
    _setFormula(sheet, laborRow, building.col, labor);
  }
  set('Shipping', sumOf('Shipping'));
  set('Fees', sumOf('Fees'));
  set('Tax', sumOf('Tax'));
  set('PROJECT TOTAL', sumOf('Room total'));
}

/// Makes Core Components' Parts total add up the sections above it.
void _formulaMasterTotals(XlsxSheet sheet) {
  final totals = _keyValueRows(sheet, 'Parts total');
  if (totals == null) return;
  final kinds = <String>[];
  for (final kind in MasterPartKind.values) {
    final label = kMasterPartKindLabels[kind]!;
    final r = totals.rows[label];
    final sum = _sumOf(sheet, label);
    if (r == null || sum == null) continue;
    _setFormula(sheet, r, totals.col, sum);
    kinds.add(_cell(totals.col, r));
  }
  final all = totals.rows['ALL PARTS'];
  if (all != null && kinds.isNotEmpty) {
    _setFormula(sheet, all, totals.col, kinds.join('+'));
  }
}

/// Makes All Items' Room totals read each room's own totals, and its Total
/// row add them up.
void _formulaAllItemsTotals(
  XlsxSheet sheet,
  Map<String, RoomTotalRefs> byTab,
) {
  final s = _sectionRange(sheet, 'Room totals', column: 'Room total');
  if (s == null) return;
  final header = sheet.rows[s.first - 1];
  final equipment = header.indexOf('Equipment');
  final labor = header.indexOf('Labor');
  final roomTotal = s.col;
  final target = header.indexOf('Target');
  final less = header.indexOf('Target less total');
  for (var r = s.first; r <= s.last; r++) {
    final room = sheet.rows[r].first;
    if (room is XlsxLink) {
      final refs = byTab[room.sheet];
      if (refs == null) continue;
      if (equipment >= 0 && refs.equipment != null) {
        _setFormula(sheet, r, equipment, refs.equipment!);
      }
      if (labor >= 0 && refs.labor != null) {
        _setFormula(sheet, r, labor, refs.labor!);
      }
      if (refs.total != null) _setFormula(sheet, r, roomTotal, refs.total!);
      if (target >= 0 && less >= 0) {
        _setFormula(
          sheet,
          r,
          less,
          '${_cell(target, r)}-${_cell(roomTotal, r)}',
        );
      }
    } else if (room == 'Total') {
      String sum(int col) =>
          'SUM(${_cell(col, s.first)}:${_cell(col, r - 1)})';
      if (target >= 0) _setFormula(sheet, r, target, sum(target));
      _setFormula(sheet, r, roomTotal, sum(roomTotal));
      if (target >= 0 && less >= 0) {
        _setFormula(
          sheet,
          r,
          less,
          '${_cell(target, r)}-${_cell(roomTotal, r)}',
        );
      }
    }
  }
}

/// Every priced line in every room on one sheet, each room linked to its own
/// tab. Second in the book, after the Summary.
const String kProjectAllItemsSheet = 'All Items';

/// The master price list: every line of every room that counts, then each
/// room's total against its target. Room names link to [roomTabs] (ref id ->
/// tab name); a room with no tab is plain text.
List<ReportSection> allItemsSections(
  ProjectEstimate estimate, {
  Map<String, String> roomTabs = const {},
  MasterPriceCells masterCells = const {},
}) {
  final project = estimate.project;
  final currency = estimate.currency;
  XlsxMoney cash(double v) => money(v, currency);
  dynamic roomCell(ProjectRoomCost room) {
    final tab = roomTabs[room.ref.id];
    return tab == null ? room.name : XlsxLink(text: room.name, sheet: tab);
  }

  String priority(int p) => p > 0 ? '$p' : '';
  final counted = [
    for (final r in estimate.rooms)
      if (r.ref.included && r.ok) r,
  ]..sort((a, b) {
      int rank(int p) => p > 0 ? p : 1 << 20;
      return rank(a.ref.priority).compareTo(rank(b.ref.priority));
    });

  final items = <List<dynamic>>[];
  for (final room in counted) {
    final e = room.estimate!;
    for (final (section, lines) in [
      ('Equipment', e.equipment),
      ('Rack hardware', e.hardware),
      ('Cabling', e.cabling),
      ('Other items', e.extras),
    ]) {
      for (final line in lines) {
        final kind = switch (section) {
          'Equipment' => MasterPartKind.equipment,
          'Rack hardware' => MasterPartKind.hardware,
          'Cabling' => MasterPartKind.cabling,
          _ => MasterPartKind.other,
        };
        final refs = _masterCellFor(estimate, masterCells, kind, line);
        // The item first: the sheet builder never moves column 0 out of the
        // grid, and a long description anywhere else would be.
        final row = [
          line.description,
          roomCell(room),
          priority(room.ref.priority),
          section,
          line.model,
          line.partNumber,
          line.qty,
          cash(line.unitPrice),
          cash(line.total),
          priceFromLabel(line),
        ];
        items.add(
          refs == null
              ? row
              : _linkRow(
                  row,
                  refs,
                  line,
                  name: 0,
                  model: 4,
                  part: 5,
                  unit: 7,
                  ext: 8,
                ),
        );
      }
    }
    if (e.laborTotal > 0) {
      items.add([
        'Labor, ${trimNumber(e.laborHours)} hrs',
        roomCell(room),
        priority(room.ref.priority),
        'Labor',
        '',
        '',
        '',
        '',
        cash(e.laborTotal),
        '',
      ]);
    }
  }

  final lines = [...project.manualRooms]..sort((a, b) {
      int rank(int p) => p > 0 ? p : 1 << 20;
      return rank(a.priority).compareTo(rank(b.priority));
    });
  final hasTargets = project.targetTotal > 0;
  var total = 0.0;
  final totals = <List<dynamic>>[
    for (final room in counted)
      () {
        total += room.total;
        return [
          roomCell(room),
          priority(room.ref.priority),
          room.ref.funding,
          if (hasTargets) ...[
            room.ref.targetPrice > 0 ? cash(room.ref.targetPrice) : '',
          ],
          cash(room.equipmentTotal),
          cash(room.laborTotal),
          cash(room.total),
          if (hasTargets) ...[
            room.ref.targetPrice > 0
                ? cash(room.ref.targetPrice - room.total)
                : '',
          ],
        ];
      }(),
    for (final line in lines)
      [
        '${line.name} (line item, no config)',
        priority(line.priority),
        line.funding,
        if (hasTargets) ...[
          line.targetPrice > 0 ? cash(line.targetPrice) : '',
        ],
        '',
        '',
        '',
        if (hasTargets) '',
      ],
    [
      'Total',
      '',
      '',
      if (hasTargets) ...[cash(project.targetTotal)],
      '',
      '',
      cash(total),
      if (hasTargets) ...[cash(project.targetTotal - total)],
    ],
  ];

  return [
    (
      title: 'Every item, every room',
      header: const [
        'Item',
        'Room',
        'Priority',
        'Section',
        'Model',
        'Part number',
        'Qty',
        'Unit price',
        'Extended',
        'Price from',
      ],
      rows: items,
    ),
    (
      title: 'Room totals',
      header: [
        'Room',
        'Priority',
        'Source',
        if (hasTargets) 'Target',
        'Equipment',
        'Labor',
        'Room total',
        if (hasTargets) 'Target less total',
      ],
      rows: totals,
    ),
  ];
}

/// The building-wide control-gap sheet, added only when there is something on
/// it. Named here so the tests and the tab-order check can agree on it.
const String kProjectControlSheet = 'Control Gaps';

/// The tab the spares answer lands on — what is spared, and what is not.
const String kProjectSparesSheet = 'Spares';

/// The tab purchasing works down: what to order, in the order to order it.
const String kProjectTimelineSheet = 'Order Timeline';

/// The paperwork and the pallets: what each PO bought, what has landed against
/// it, and where every lot is now. Added only when the job has a purchase
/// order or a delivery on it.
const String kProjectPurchasingSheet = 'Purchasing';

/// Whose job each piece of scope is. Added only when the matrix has lines on
/// it — a blank sheet headed "Roles and Responsibilities" in an issued
/// workbook reads as "nothing is anybody's job".
const String kProjectResponsibilitySheet = 'Responsibility';

/// The building's replacement plan: how old every room's equipment is and the
/// year each of it falls due. Added only when something on the job has been
/// dated.
const String kProjectLifecycleSheet = 'Replacement Plan';

/// Who changed what, and when. Added only when there is something on it.
///
/// ON THE WORKBOOK, NOT ON A QUOTE REQUEST. The workbook is the internal
/// document — it already carries labor rates and margins, which is exactly why
/// the vendor RFQ is a separate file — so an audit trail belongs on it. The
/// RFQ is built from the vendor package alone and cannot pick this up.
const String kProjectHistorySheet = 'History';

// ---------------------------------------------------------------------------
//  SECTIONS
// ---------------------------------------------------------------------------

/// What the building costs, and every room's share of it.
List<ReportSection> projectSummarySections(ProjectEstimate estimate) {
  final currency = estimate.currency;
  XlsxMoney cash(double v) => money(v, currency);

  final project = estimate.project;

  final sections = <ReportSection>[
    (
      title: 'Project',
      header: const ['', ''],
      rows: [
        if (project.name.trim().isNotEmpty) ['Project', project.name],
        // Wrapped in column B: a campus job's list of buildings runs long.
        if (project.building.trim().isNotEmpty)
          ['Building', XlsxWrapped(project.building)],
        if (project.projectNumber.trim().isNotEmpty)
          ['Project number', project.projectNumber],
        if (project.stakeholder.trim().isNotEmpty)
          ['Stakeholder', project.stakeholder],
        ['Rooms quoted', estimate.costedRooms.length],
        if (project.deliveryDeadline != null)
          [
            'Delivery deadline',
            formatScheduleDate(project.deliveryDeadline!),
          ],
        // On the summary because it is a figure somebody decides about rather
        // than reads: a job with no spares on it is a decision, and one nobody
        // is asked to make is one that gets made by default.
        [
          'Spares',
          estimate.spareUnits == 0
              ? 'none on this job'
              : '${trimNumber(estimate.spareUnits)} unit'
                    '${estimate.spareUnits == 1 ? '' : 's'} across '
                    '${estimate.sparedParts.length} product'
                    '${estimate.sparedParts.length == 1 ? '' : 's'} '
                    '(${formatMoney(estimate.sparesTotal, currency)}) - '
                    'see the $kProjectSparesSheet sheet',
        ],
        if (project.rooms.length != estimate.costedRooms.length)
          [
            'Rooms not counted',
            '${project.rooms.length - estimate.costedRooms.length} '
                '(excluded or unreadable - see Rooms below)',
          ],
        if (project.notes.trim().isNotEmpty)
          [ReportParagraph('Notes', project.notes.trim())],
      ],
    ),
    (
      title: 'Rooms',
      header: const [
        'Room',
        'Equipment',
        'Rack hardware',
        'Cabling',
        'Other items',
        'Crew hrs',
        'Total labor hrs',
        'Labor',
        'Shipping',
        'Fees',
        'Tax',
        'Room total',
        'Status',
      ],
      rows: [
        for (final room in estimate.rooms)
          if (room.ok)
            [
              room.name,
              cash(room.estimate!.equipmentTotal),
              cash(room.estimate!.hardwareTotal),
              cash(room.estimate!.cablingTotal),
              cash(room.estimate!.extrasTotal),
              trimNumber(room.estimate!.laborCrewHours),
              trimNumber(room.estimate!.laborHours),
              cash(room.estimate!.laborTotal),
              cash(room.estimate!.shippingTotal),
              cash(room.estimate!.feeTotal),
              cash(room.estimate!.tax),
              cash(room.estimate!.grandTotal),
              _roomStatus(room),
            ]
          else
            // A room that could not be read still gets a row. A building whose
            // total is short by one room must say which one, in the same table
            // the total is in — a warning somewhere else gets skimmed past.
            [
              room.name,
              '', '', '', '', '', '', '', '', '', '',
              '',
              'NOT COUNTED - ${room.room.error}',
            ],
      ],
    ),
    (
      title: 'Building total',
      header: const ['', ''],
      rows: [
        ['Equipment', cash(estimate.equipmentTotal)],
        ['Rack hardware', cash(estimate.hardwareTotal)],
        ['Cabling', cash(estimate.cablingTotal)],
        ['Other items', cash(estimate.extrasTotal)],
        ['Parts subtotal', cash(estimate.partsTotal)],
        [
          'Labor (${trimNumber(estimate.laborCrewHours)} crew hrs, '
              '${trimNumber(estimate.laborHours)} total hrs)',
          cash(estimate.laborTotal),
        ],
        if (estimate.shippingTotal > 0)
          ['Shipping', cash(estimate.shippingTotal)],
        ['Fees', cash(estimate.feeTotal)],
        ['Tax', cash(estimate.taxTotal)],
        ['PROJECT TOTAL', cash(estimate.grandTotal)],
      ],
    ),
  ];

  // Packages get a summary block here as well as their own tabs: "how is this
  // job split up, for how much, and where has each lot got to" is a question
  // asked long before anybody opens a per-package sheet, and it is the number
  // that decides whether the split is worth making at all.
  if (estimate.packages.isNotEmpty) {
    sections.add((
      title: 'By package',
      header: const [
        'Package',
        'Lines',
        'Units',
        'Our estimate',
        'Stage',
        'Bids',
        'Awarded to',
      ],
      rows: [
        for (final p in estimate.packages)
          [
            p.isUntagged ? 'UNTAGGED - no package rule matched' : p.packageName,
            p.lines.length,
            trimNumber(p.qty),
            cash(p.total),
            p.rfq?.stage.label ?? '',
            p.rfq?.bids.length ?? '',
            p.awardedVendor?.name ?? '',
          ],
        [
          'All parts',
          estimate.master.length,
          trimNumber(
            estimate.master.fold(0.0, (s, l) => s + l.qty),
          ),
          cash(estimate.partsTotal),
          '',
        ],
      ],
    ));
  }

  // THE DRAWINGS THE JOB WAS QUOTED AGAINST.
  //
  // On the summary rather than a sheet of its own, for the same reason the job
  // list below is: a drawing set is a handful of rows, and a tab nobody clicks
  // is a tab nobody reads.
  //
  // It is here at all because a quote is an answer to a QUESTION, and the
  // drawings are the question. "Which set was this priced from" is asked every
  // time a plan is reissued and a number stops matching, and up to now the
  // only answer was somebody's memory of an email.
  //
  // THE PATH AS STORED, not as resolved: it is what the project file says, so
  // a reader with the folder in front of them can follow it, and a reader
  // without it is not handed the absolute layout of somebody else's machine.
  // A file that has gone says so in the status column, exactly as an unreadable
  // room does in the Rooms table above.
  if (project.plans.isNotEmpty) {
    final missing = {for (final p in missingProjectPlans(estimate)) p.id};
    sections.add((
      title: 'Plans this job is quoted against (${project.plans.length})',
      header: const ['Sheet', 'File', 'Notes', 'Status'],
      rows: [
        for (final plan in project.plans)
          [
            plan.displayName,
            plan.filePath,
            plan.notes,
            missing.contains(plan.id)
                ? 'NOT FOUND - the file is not where the project says it is'
                : '',
          ],
      ],
    ));
  }

  // The job's own list, on the summary rather than a sheet of its own: it is
  // short, it is the thing somebody wants to see when they pick the job back
  // up, and a tab nobody clicks is a tab nobody reads. Open items only —
  // finished ones are history and belong on screen, not in a document that
  // gets sent out.
  final openTodos = project.openTodos;
  if (openTodos.isNotEmpty) {
    // The building code and number, the same as the tab shows — a note filed
    // against a room means the room on the door.
    //
    // Only here. The tables above are a QUOTE, and a quote says "Behavioral
    // And Social Science 103" because that is what the stakeholder calls it; a
    // job list is read by the people doing the work, who call it BSS 103.
    final roomNames = {for (final r in estimate.rooms) r.ref.id: r.codeName};
    // Dated items first, soonest due at the top — the same order the tab
    // shows them in, so the document and the screen agree about what matters.
    final ordered = [...openTodos]..sort((a, b) {
      final ad = a.due;
      final bd = b.due;
      if (ad != null && bd != null && ad != bd) return ad.compareTo(bd);
      if (ad == null && bd != null) return 1;
      if (ad != null && bd == null) return -1;
      return a.created.compareTo(b.created);
    });
    sections.add((
      title: 'Still to do on this job (${openTodos.length})',
      header: const ['Item', 'About', 'State', 'Due', 'Open since'],
      rows: [
        for (final t in ordered)
          [
            t.text,
            t.isWholeJob
                ? 'the job'
                : t.roomId.isNotEmpty
                    ? roomNames[t.roomId] ?? t.roomId
                    : t.scopeLabel,
            kProjectTodoStateLabels[t.state] ?? '',
            t.due == null
                ? ''
                // Late is spelled out rather than left to the reader to work
                // out from a date and today's date.
                : t.isOverdue()
                    ? '${formatScheduleDate(t.due!)} - PAST ITS DATE'
                    : formatScheduleDate(t.due!),
            formatScheduleDate(t.created),
          ],
      ],
    ));
  }

  final warnings = _projectWarnings(estimate);
  if (warnings.isNotEmpty) {
    sections.add((
      title: 'Check before this goes out',
      header: const ['Issue'],
      rows: [for (final w in warnings) [w]],
    ));
  }

  return sections;
}

/// Why a room's figure might not be what somebody expects. Blank when there is
/// nothing to say — a status column of "OK" on every row is noise.
String _roomStatus(ProjectRoomCost room) {
  final e = room.estimate!;
  final notes = <String>[
    if (!room.ref.included) 'EXCLUDED from the project total',
    if (room.room.isEmpty) 'nothing drawn yet',
    if (e.unpricedLines > 0)
      '${e.unpricedLines} line${e.unpricedLines == 1 ? '' : 's'} unpriced',
    if (e.unratedLabor > 0)
      '${e.unratedLabor} labor line${e.unratedLabor == 1 ? '' : 's'} at no '
          'rate',
    if (e.estimatedLines > 0) '${e.estimatedLines} at base cost (budgetary)',
    if (e.otherTierLines > 0) '${e.otherTierLines} priced at the other tier',
    if (e.excludedLines > 0) '${e.excludedLines} drawn but not bought',
    if (room.controlGaps.isNotEmpty)
      () {
        final n = room.controlGaps.fold(0, (s, g) => s + g.qty);
        return '$n device${n == 1 ? '' : 's'} with no control module';
      }(),
    if (room.ref.notes.trim().isNotEmpty) room.ref.notes.trim(),
  ];
  return notes.join('; ');
}

/// The devices with no driver, counted and said in the right number.
String _undrivenWarning(ProjectEstimate estimate) {
  final devices = estimate.undrivenDevices;
  final rooms =
      estimate.controlGaps.map((g) => g.room.ref.id).toSet().length;
  final one = devices == 1;
  return '$devices device${one ? '' : 's'} across $rooms '
      'room${rooms == 1 ? '' : 's'} ${one ? 'has' : 'have'} no control '
      'module. ${one ? 'It is' : 'They are'} quoted and '
      '${one ? 'it' : 'they'} will not commission as '
      '${one ? 'it stands' : 'they stand'} - see the $kProjectControlSheet '
      'sheet.';
}

/// The things that should stop a quote going out, in the order they matter.
List<String> _projectWarnings(ProjectEstimate estimate) {
  // Worked out once: every entry costs a stat of a file, and the list below
  // asks about it three times.
  final missingPlans = missingProjectPlans(estimate);
  return [
  if (estimate.failedRooms > 0)
    '${estimate.failedRooms} room${estimate.failedRooms == 1 ? '' : 's'} '
        'could not be read, so the project total is short by whatever '
        '${estimate.failedRooms == 1 ? 'it costs' : 'they cost'}. See the '
        'Rooms table.',
  if (estimate.mixedCurrency)
    'Rooms in this project are quoted in different currencies. The totals '
        'add them as though they were the same one - fix the room currencies '
        'before relying on any figure here.',
  if (estimate.unpricedParts > 0)
    '${estimate.unpricedParts} part${estimate.unpricedParts == 1 ? '' : 's'} '
        '${estimate.unpricedParts == 1 ? 'is' : 'are'} missing pricing. '
        'The total is short by whatever '
        '${estimate.unpricedParts == 1 ? 'it costs' : 'they cost'}.',
  if (estimate.untaggedParts > 0)
    '${estimate.untaggedParts} item'
        '${estimate.untaggedParts == 1 ? ' is' : 's are'} missing a vendor and '
        'will not be tracked. See the Untagged rows on Core Components.',
  // Not a pricing problem, and on the pricing sheet anyway. A building quoted
  // without anybody noticing that six of its boxes have no driver is a
  // building that arrives on site and cannot be commissioned, and the quote is
  // the document that actually gets read before that happens.
  if (estimate.undrivenDevices > 0)
    _undrivenWarning(estimate),
  // Not a mistake, and not something the app should decide — but a building
  // where nothing at all is spared is a building where the first failure is
  // paid for out of a budget that has already closed, and nobody was ever
  // going to be reminded of that by a drawing.
  if (estimate.spareUnits == 0 && estimate.partsWithoutSpares.isNotEmpty)
    'Nothing on this job has a spare. '
        '${estimate.partsWithoutSpares.length} '
        'product${estimate.partsWithoutSpares.length == 1 ? '' : 's'} would '
        'be replaced out of the next budget rather than off the shelf - see '
        'the $kProjectSparesSheet sheet.',
  // The job's rule, broken: one spare of everything a room installs. Said as
  // a count of PARTS rather than as a percentage of the job, because it is the
  // parts somebody has to go and decide about.
  if (estimate.unsparedParts.isNotEmpty && estimate.spareUnits > 0)
    '${estimate.unsparedParts.length} '
        'product${estimate.unsparedParts.length == 1 ? '' : 's'} '
        '${estimate.unsparedParts.length == 1 ? 'is' : 'are'} installed with '
        'nothing held spare - see the $kProjectSparesSheet sheet.',
  // Not a pricing problem either, and the last chance to catch it: the
  // workbook is usually built when the job is about to go somewhere, and a
  // drawing that has moved is found on the day it is wanted otherwise.
  if (missingPlans.isNotEmpty)
    '${missingPlans.length} building plan'
        '${missingPlans.length == 1 ? ' is' : 's are'} not where the project '
        'says ${missingPlans.length == 1 ? 'it is' : 'they are'} - see the '
        'Plans table above.',
  for (final c in estimate.project.rfqConflicts)
    '${c.kind} rule "${c.rule}" is claimed by '
        '${c.rfqs.map((r) => r.name).join(' and ')}. '
        '${c.rfqs.first.name} wins; the others never see those parts.',
  ];
}

/// Every part on the job, once, with the rooms it is for.
///
/// [roomNames] maps room id to the name shown in the breakdown column. Passed
/// in rather than looked up so the same names appear here, on the Summary and
/// on the room tabs.
List<ReportSection> masterPartsSections(
  ProjectEstimate estimate, {
  bool includeVendorColumn = true,
}) {
  final currency = estimate.currency;
  XlsxMoney cash(double v) => money(v, currency);

  String unit(MasterPartLine line) {
    if (line.unpriced) return 'not priced';
    if (!line.priceVaries) return formatMoney(line.unitPrice, currency);
    // Two rooms bought the same part at different prices — a negotiated
    // override in one of them. Printing either figure alone would look like
    // the answer, so it prints as the range it is.
    return '${formatMoney(line.unitPrice, currency)}'
        '-${formatMoney(line.maxUnitPrice, currency)}';
  }

  final sections = <ReportSection>[];

  for (final kind in MasterPartKind.values) {
    final lines = [for (final l in estimate.master) if (l.kind == kind) l];
    if (lines.isEmpty) continue;
    sections.add((
      title: kMasterPartKindLabels[kind]!,
      header: [
        'Part',
        'Manufacturer',
        'Model',
        'Part number',
        'Qty',
        // Spares are tagged ON the line rather than split onto one of their
        // own, because they are the same product at the same price — see the
        // Spares sheet for the job's whole answer. Blank rather than 0 on a
        // part nobody spared: a column of zeroes reads as a column of
        // decisions, and these are the opposite.
        'Spares',
        'For install',
        'Unit price',
        'Extended',
        if (includeVendorColumn) 'Package',
        // Blank until the package is awarded — before that nobody is
        // supplying this line yet.
        if (includeVendorColumn) 'Vendor',
        if (includeVendorColumn) 'Tagged',
        // Products only. Devices with no control module are on the Control
        // Gaps sheet.
        // Where each part goes is the Parts by Room tab: a list of thirty
        // rooms in one cell is a sentence, not a column.
        //
        // What the online copy's pull reads a row back by - see
        // [readMasterEdits]. Leave it alone and edit the rest.
        'Row id',
      ],
      rows: [
        for (final l in lines)
          [
            l.description,
            l.manufacturer,
            l.model,
            l.partNumber,
            l.qty,
            l.hasSpares ? l.spareQty : '',
            l.hasSpares ? l.drawnQty : '',
            // A number where the part has one price, so the rooms can read
            // it from here - see [_linkMasterSheet].
            l.unpriced || l.priceVaries ? unit(l) : cash(l.unitPrice),
            cash(l.total),
            if (includeVendorColumn) l.rfq?.name ?? 'UNTAGGED',
            if (includeVendorColumn) l.vendor?.name ?? '',
            if (includeVendorColumn) kRfqTagSourceLabels[l.tagSource] ?? '',
            masterRowId(l.key),
          ],
      ],
    ));
  }

  if (sections.isEmpty) return const [];

  sections.add((
    title: 'Parts total',
    header: const ['', ''],
    rows: [
      for (final kind in MasterPartKind.values)
        if (estimate.master.any((l) => l.kind == kind))
          [
            kMasterPartKindLabels[kind]!,
            cash(estimate.master
                .where((l) => l.kind == kind)
                .fold(0.0, (s, l) => s + l.total)),
          ],
      ['ALL PARTS', cash(estimate.partsTotal)],
    ],
  ));

  return sections;
}

/// The tab that says where each part goes - see [partsByRoomSections].
const String kProjectPartsByRoomSheet = 'Parts by Room';

/// Every part on the job against every room: one row per part, one column
/// per room with how many go there, and the total. Read down a column for
/// what a room gets, across a row for where a part goes. Blank, not 0, where
/// a room gets none.
List<ReportSection> partsByRoomSections(ProjectEstimate estimate) {
  final rooms = [
    for (final r in estimate.rooms)
      if (r.ref.included && r.ok) r,
  ];
  if (estimate.master.isEmpty || rooms.isEmpty) return const [];
  return [
    for (final kind in MasterPartKind.values)
      if (estimate.master.any((l) => l.kind == kind))
        (
          title: kMasterPartKindLabels[kind]!,
          header: [
            'Part',
            'Model',
            for (final r in rooms) r.codeName,
            'Total',
          ],
          rows: [
            for (final l in estimate.master)
              if (l.kind == kind)
                [
                  l.description,
                  l.model,
                  for (final r in rooms)
                    (l.qtyByRoom[r.ref.id] ?? 0) > 0
                        ? l.qtyByRoom[r.ref.id]!
                        : '',
                  l.qty,
                ],
          ],
        ),
  ];
}

/// The install windows put on the job, earliest first. Empty when there are
/// none.
List<ReportSection> installWindowSections(BuildingProject project) {
  final windows = [...project.installWindows]
    ..sort((a, b) => a.start.compareTo(b.start));
  if (windows.isEmpty) return const [];
  const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return [
    (
      title: 'Maintenance windows (${windows.length})',
      header: const ['Date', 'Day', 'Room', 'Time', 'Notes'],
      rows: [
        for (final w in windows)
          [
            formatScheduleDate(w.day),
            weekdays[w.day.weekday - 1],
            w.roomLabel,
            w.timeLabel,
            w.notes,
          ],
      ],
    ),
  ];
}

/// When each part has to be ordered, and what cannot be scheduled yet.
///
/// The Core Components list says what to buy; this says when. Kept as its own
/// set of sections because it is read by a different person for a different
/// reason — purchasing works down this in date order, and does not care which
/// vendor rule tagged what.
List<ReportSection> projectTimelineSections(
  ProjectEstimate estimate, {
  DateTime? asOf,
}) {
  final schedule = buildProjectSchedule(estimate: estimate, asOf: asOf);
  final sections = <ReportSection>[];

  sections.add((
    title: 'The dates',
    header: const ['', ''],
    rows: [
      [
        'Delivery deadline',
        schedule.deadline == null
            ? 'not set - nothing can be scheduled'
            : formatScheduleDate(schedule.deadline!),
      ],
      [
        'First order due',
        schedule.firstOrderDate == null
            ? '-'
            : formatScheduleDate(schedule.firstOrderDate!),
      ],
      ['Past their order date', schedule.lateCount],
      ['To order within $kOrderDueSoonDays days', schedule.dueSoonCount],
      ['No lead time recorded', schedule.unknownCount],
      ['On order', schedule.onOrderCount],
      if (schedule.arrivingLateCount > 0)
        [
          'On order but promised LATE',
          '${schedule.arrivingLateCount} - bought, and the room will not have '
              'them in time',
        ],
      ['Arrived', schedule.receivedCount],
      ['Worked out on', formatScheduleDate(schedule.asOf)],
    ],
  ));

  // The phases, when a job has split into them: each one's delivery date is
  // what its parts are worked back from, so a reader checking a date needs to
  // see them.
  if (estimate.project.tracks.isNotEmpty) {
    sections.add((
      title: 'Delivery phases',
      header: const ['Phase', 'On site by', 'Parts', 'First order', 'Notes'],
      rows: [
        for (final entry in schedule.byTrack(estimate.project))
          [
            entry.track?.name ?? 'With the job',
            // A phase with no date of its own falls back to the job's, and
            // says so — otherwise two phases print the same date and nothing
            // explains why.
            entry.track?.deadline != null
                ? formatScheduleDate(entry.track!.deadline!)
                : estimate.project.deliveryDeadline == null
                ? 'not set'
                : '${formatScheduleDate(estimate.project.deliveryDeadline!)}'
                      ' (from the job)',
            entry.parts.length,
            () {
              DateTime? first;
              for (final p in entry.parts) {
                final d = p.orderBy;
                if (d == null) continue;
                if (first == null || d.isBefore(first)) first = d;
              }
              return first == null ? '-' : formatScheduleDate(first);
            }(),
            entry.track?.notes ?? '',
          ],
      ],
    ));
  }

  sections.addAll(installWindowSections(estimate.project));

  // STILL TO BUY. A part already on order has no trip to purchasing left to
  // schedule, and leaving it here would put a date in front of somebody for an
  // order that went out last week. What HAS been bought gets its own table
  // below, because "is it bought" is the first thing anybody asks of this
  // sheet and a document that only lists what is outstanding cannot answer it.
  final dated = [
    for (final l in schedule.lines)
      if (l.orderBy != null && !l.isBought) l,
  ];
  if (dated.isNotEmpty) {
    sections.add((
      title: 'Order by',
      header: const [
        'Order by',
        'Part',
        'Qty',
        'Vendor',
        'Phase',
        'Lead time',
        'On site by',
        'Status',
      ],
      rows: [
        for (final l in dated)
          [
            formatScheduleDate(l.orderBy!),
            l.line.description,
            l.line.qty,
            l.line.vendor?.name ?? 'UNTAGGED',
            l.trackName,
            formatLeadTime(l.leadDays),
            // The early ones are called out: a part wanted ahead of the job is
            // the thing somebody has to remember.
            l.needByIsOwn
                ? '${formatScheduleDate(l.needBy!)} (ahead of the job)'
                : formatScheduleDate(l.needBy!),
            '${kOrderStatusLabels[l.status]} - '
                '${formatDayGap(l.daysUntilOrder ?? 0)}',
          ],
      ],
    ));
  }

  // What has been bought, and whether it is going to make it.
  final bought = [for (final l in schedule.lines) if (l.isBought) l];
  if (bought.isNotEmpty) {
    sections.add((
      title: 'Bought (${bought.length})',
      header: const [
        'Part',
        'Qty',
        'Vendor',
        'PO',
        'Ordered',
        'Vendor promised',
        'On site by',
        'Arrived',
        'Status',
      ],
      rows: [
        for (final l in bought)
          [
            l.line.description,
            l.line.qty,
            l.line.vendor?.name ?? 'UNTAGGED',
            l.order?.poNumber ?? '',
            l.order?.orderedOn == null
                ? ''
                : formatScheduleDate(l.order!.orderedOn!),
            l.order?.expectedOn == null
                ? ''
                : formatScheduleDate(l.order!.expectedOn!),
            l.needBy == null ? '' : formatScheduleDate(l.needBy!),
            l.order?.receivedOn == null
                ? ''
                : formatScheduleDate(l.order!.receivedOn!),
            // Spelled out rather than left to be worked out from two dates:
            // an order placed on time against a promise that lands after the
            // room needs it is the thing this table exists to surface.
            l.status == OrderStatus.arrivingLate
                ? 'ON ORDER - PROMISED AFTER IT IS NEEDED'
                : kOrderStatusLabels[l.status] ?? '',
          ],
      ],
    ));
  }

  // Listed rather than left out. A timeline that silently omits the parts
  // nobody has a lead time for reads as complete while being the opposite.
  final unscheduled = [
    for (final l in schedule.lines)
      if (l.orderBy == null && !l.isBought) l,
  ];
  if (unscheduled.isNotEmpty) {
    sections.add((
      title: 'Cannot be scheduled yet (${unscheduled.length})',
      header: const ['Part', 'Qty', 'Vendor', 'What is missing'],
      rows: [
        for (final l in unscheduled)
          [
            l.line.description,
            l.line.qty,
            l.line.vendor?.name ?? 'UNTAGGED',
            l.status == OrderStatus.noDeadline
                ? 'no delivery date for this part or the job'
                : 'nobody has asked the vendor how long it takes',
          ],
      ],
    ));
  }

  return sections;
}

/// The paperwork and the pallets: what was bought on each purchase order, what
/// has turned up against it, and where every lot of it is now.
///
/// THE QUESTION THIS SHEET ANSWERS IS ASKED BY SOMEBODY STANDING IN A
/// CORRIDOR. The Order Timeline says what to buy and when; it stops at the day
/// a part arrives, and the weeks between the loading dock and the finished room
/// are where a job actually loses things. Eighteen wall plates arrive in March,
/// six go into 103 in April, and in June the workbook that was filed is the
/// only record of whether the other twelve are in a basement or were never
/// delivered at all.
///
/// ONE ROW PER LOT, NOT PER PART. A part that turned up in three shipments is
/// three rows, each with its own date, its own quantity and its own place,
/// because that is what happened and a single "received" tick cannot hold it.
///
/// THE PO IS THE SPINE. Every table here is filed under the number the vendor,
/// the finance system and the packing slip all already use — see [ProjectPo] —
/// so a PO on this sheet can be read straight against the paperwork in
/// somebody's hand.
List<ReportSection> projectPurchasingSections(ProjectEstimate estimate) {
  final project = estimate.project;
  final currency = estimate.currency;
  XlsxMoney cash(double v) => money(v, currency);
  final lines = {for (final m in estimate.master) m.key: m};
  final vendorNames = {for (final v in project.vendors) v.id: v.name};
  final roomNames = estimate.roomCodeNames;

  /// Who a PO went to: the vendor row it points at, or whatever was typed.
  String vendorOf(ProjectPo po) =>
      vendorNames[po.vendorId] ?? po.vendor.trim();

  /// What a part is called, as the job calls it now. A key that has dropped
  /// off the master list still prints — as the key — rather than vanishing:
  /// the PO bought it, and a purchase that no longer matches the equipment
  /// list is the single most useful thing this sheet can say.
  String partName(String key) => lines[key]?.description ?? key;

  final sections = <ReportSection>[];

  // Every PO number the job mentions anywhere, not just the rows somebody
  // entered: a number typed onto a part or read off a packing slip is a PO
  // this sheet has to account for. See [BuildingProject.poNumbersInUse].
  final numbers = project.poNumbersInUse;

  if (numbers.isNotEmpty) {
    sections.add((
      title: 'Purchase orders (${numbers.length})',
      header: const [
        'PO',
        'Vendor',
        'Raised',
        'Vendor promised',
        'Raised for',
        'Parts on it',
        'Marked arrived',
        'Deliveries logged',
        'Units landed',
      ],
      rows: [
        for (final number in numbers)
          () {
            final po = project.poByNumber(number);
            final parts = project.partsOnPo(number);
            final landed = project.deliveriesForPo(number);
            var units = 0.0;
            for (final d in landed) {
              if (d.isOnHand) units += d.qty;
            }
            return [
              number,
              po == null ? '' : vendorOf(po),
              po?.issuedOn == null ? '' : formatScheduleDate(po!.issuedOn!),
              po?.expectedOn == null ? '' : formatScheduleDate(po!.expectedOn!),
              (po?.amount ?? 0) > 0 ? cash(po!.amount) : '',
              parts.length,
              [
                for (final key in parts)
                  if (project.orderForPart(key)?.isReceived == true) key,
              ].length,
              landed.length,
              units == 0 ? '' : trimNumber(units),
            ];
          }(),
      ],
    ));
  }

  // WHAT EACH ONE BOUGHT. The Order Timeline's bought table is filed under the
  // PART, which is the right way round for "has this been ordered" and the
  // wrong way round for "what is on PO-1188" — the question somebody rings up
  // with, holding the PO.
  final byPo = <List<dynamic>>[];
  for (final number in numbers) {
    for (final key in project.partsOnPo(number)) {
      final order = project.orderForPart(key);
      final line = lines[key];
      byPo.add([
        number,
        partName(key),
        line == null ? '' : trimNumber(line.qty),
        line?.vendor?.name ?? '',
        order?.orderedOn == null ? '' : formatScheduleDate(order!.orderedOn!),
        order?.expectedOn == null ? '' : formatScheduleDate(order!.expectedOn!),
        order?.receivedOn == null ? '' : formatScheduleDate(order!.receivedOn!),
        trimNumber(project.deliveredQty(key)),
      ]);
    }
  }
  if (byPo.isNotEmpty) {
    sections.add((
      title: 'What each PO bought (${byPo.length})',
      header: const [
        'PO',
        'Part',
        'Qty on the job',
        'Vendor',
        'Ordered',
        'Vendor promised',
        'Marked arrived',
        'Units logged in',
      ],
      rows: byPo,
    ));
  }

  // What was bought on a card, and what was bought against nothing anybody
  // has written down. Worked out here because the rollup below counts them
  // and the tables at the foot of the sheet list them.
  final oneOffs = project.oneOffDeliveries;
  final loose = project.deliveriesNeedingPaperwork;

  // WHERE IT IS. Newest first, the way the pane reads and the way anybody
  // scanning for "what landed this week" reads it.
  final deliveries = [...project.deliveries]..sort((a, b) {
    final ad = a.deliveredOn;
    final bd = b.deliveredOn;
    if (ad == null && bd == null) return b.id.compareTo(a.id);
    if (ad == null) return 1;
    if (bd == null) return -1;
    final byDate = bd.compareTo(ad);
    return byDate != 0 ? byDate : b.id.compareTo(a.id);
  });

  if (deliveries.isNotEmpty) {
    sections.add((
      title: 'Deliveries (${deliveries.length}, newest first)',
      header: const [
        'Arrived',
        'What',
        'Qty',
        'Bought on',
        'Where it is',
        'Delivered to / held at',
        'Room',
        'Installed',
        'Notes',
      ],
      rows: [
        for (final d in deliveries)
          [
            d.deliveredOn == null ? '' : formatScheduleDate(d.deliveredOn!),
            d.itemName.trim().isEmpty
                ? (d.partKey.isEmpty
                      ? 'not on the equipment list'
                      : partName(d.partKey))
                : d.itemName.trim(),
            d.qty == 0 ? '' : trimNumber(d.qty),
            // WHAT BOUGHT IT, in one column with three answers. A PO number;
            // a card purchase that was never going to have one; or a row
            // nobody has said anything about, which is called out in capitals
            // rather than left as a blank cell that reads as "no data".
            d.poNumber.trim().isNotEmpty
                ? d.poNumber.trim()
                : d.oneOff
                ? 'One-off - P-Card'
                : 'NOT RECORDED',
            d.state.label,
            // The ADDRESS, in its own column rather than folded into the
            // state: 'delivered' with nowhere after it is the answer that
            // sends somebody walking round a campus looking for a pallet.
            d.location.trim(),
            roomNames[d.roomId] ?? '',
            d.installedOn == null ? '' : formatScheduleDate(d.installedOn!),
            // One per line, so a lot with three notes on it reads as three
            // lines in one cell rather than as one paragraph.
            [
              for (final n in d.notes)
                '${formatIsoDate(n.at)} ${n.user.isEmpty ? '' : '${n.user}: '}'
                    '${n.text}',
            ].join('\n'),
          ],
      ],
    ));

    // THE ROLLUP. The tables above are read a row at a time; this is the
    // paragraph somebody quotes in a meeting.
    var onHand = 0.0;
    var installed = 0.0;
    var stored = 0.0;
    var returned = 0.0;
    for (final d in deliveries) {
      if (!d.isOnHand) {
        returned += d.qty;
        continue;
      }
      onHand += d.qty;
      if (d.isInstalled) {
        installed += d.qty;
      } else if (d.state == DeliveryState.stored) {
        stored += d.qty;
      }
    }
    sections.add((
      title: 'Where the kit is',
      header: const ['', ''],
      rows: [
        ['Units delivered and still the job\'s', trimNumber(onHand)],
        ['In a room', trimNumber(installed)],
        ['In storage', trimNumber(stored)],
        ['On site, nowhere named', trimNumber(onHand - installed - stored)],
        ['Sent back', trimNumber(returned)],
        if (oneOffs.isNotEmpty)
          ['Deliveries bought outside the PO process', oneOffs.length],
        if (loose.isNotEmpty)
          ['Deliveries on no PO and not marked one-off', loose.length],
        for (final place in project.deliveryLocations)
          [
            'At $place',
            trimNumber(
              deliveries
                  .where(
                    (d) =>
                        d.isOnHand &&
                        !d.isInstalled &&
                        d.location.trim() == place,
                  )
                  .fold<double>(0, (sum, d) => sum + d.qty),
            ),
          ],
      ],
    ));
  }

  // BOUGHT OUTSIDE THE PROCESS. Its own table because it is the spend nothing
  // else in this app knows about: a card purchase is on no estimate, in no
  // vendor package and on no purchase order, and "what did we buy outside the
  // process" is a question somebody in finance asks at the end of a job.
  if (oneOffs.isNotEmpty) {
    sections.add((
      title: 'Bought outside the PO process (${oneOffs.length})',
      header: const [
        'Arrived',
        'What',
        'Qty',
        'Where it is',
        'Delivered to / held at',
        'Room',
        'Notes',
      ],
      rows: [
        for (final d in oneOffs)
          [
            d.deliveredOn == null ? '' : formatScheduleDate(d.deliveredOn!),
            d.itemName.trim().isEmpty
                ? (d.partKey.isEmpty
                      ? 'not on the equipment list'
                      : partName(d.partKey))
                : d.itemName.trim(),
            d.qty == 0 ? '' : trimNumber(d.qty),
            d.state.label,
            d.location.trim(),
            roomNames[d.roomId] ?? '',
            [
              for (final n in d.notes)
                '${formatIsoDate(n.at)} ${n.user.isEmpty ? '' : '${n.user}: '}'
                    '${n.text}',
            ].join('\n'),
          ],
      ],
    ));
  }

  // AND THE ONES THAT SAY NOTHING. Listed rather than left in the log to be
  // found by reading it: a row with no PO and no card behind it cannot be
  // reconciled against an order, an invoice or a statement, and a document
  // that quietly carries three of them reads as complete while being the
  // opposite. See [ProjectDelivery.needsPaperwork].
  if (loose.isNotEmpty) {
    sections.add((
      title: 'Arrived against nothing (${loose.length})',
      header: const ['Arrived', 'What', 'Qty', 'Where it is', 'What is missing'],
      rows: [
        for (final d in loose)
          [
            d.deliveredOn == null ? '' : formatScheduleDate(d.deliveredOn!),
            d.itemName.trim().isEmpty
                ? (d.partKey.isEmpty
                      ? 'not on the equipment list'
                      : partName(d.partKey))
                : d.itemName.trim(),
            d.qty == 0 ? '' : trimNumber(d.qty),
            d.whereText,
            'no PO, and not marked as a one-off purchase',
          ],
      ],
    ));
  }

  // The commentary a PO attracts, signed. Its own table rather than a column,
  // because these are written by several people over several weeks and the
  // name and the date on each are the reason they are worth keeping.
  final poNotes = <List<dynamic>>[];
  for (final po in project.purchaseOrders) {
    for (final n in po.notes) {
      poNotes.add([
        formatIsoDate(n.at),
        po.number.trim().isEmpty ? 'PO' : po.number.trim(),
        n.text,
        n.user,
      ]);
    }
  }
  if (poNotes.isNotEmpty) {
    poNotes.sort((a, b) => b[0].toString().compareTo(a[0].toString()));
    sections.add((
      title: 'What has been said about the purchase orders (${poNotes.length})',
      header: const ['Date', 'PO', 'Note', 'By'],
      rows: poNotes,
    ));
  }

  return sections;
}

/// Every recorded change on this job, newest first.
///
/// The document answer to the question the History pane answers on screen:
/// "this says four weeks, it said eight in March — who changed it, and when".
/// A workbook filed at the end of a job is what somebody reads a year later,
/// and a file holding only the current values cannot settle that.
///
/// One row per change, with the item NAMED as it read at the time. A part that
/// has since been renamed or dropped off the job still reads correctly here,
/// which is the whole point of storing the name with the entry rather than
/// resolving it when the sheet is written.
List<ReportSection> projectHistorySections(ProjectEstimate estimate) {
  final entries = estimate.project.recentHistory;
  if (entries.isEmpty) return const [];

  return [
    (
      title: 'Changes (${entries.length}, newest first)',
      header: const ['Date', 'Time', 'Item', 'Kind', 'What', 'Change', 'By'],
      rows: [
        for (final e in entries)
          [
            formatIsoDate(e.at),
            // 24 hour, so the sheet sorts and reads the same on both sides of
            // the Atlantic.
            '${e.at.hour.toString().padLeft(2, '0')}:'
                '${e.at.minute.toString().padLeft(2, '0')}',
            e.itemName,
            e.itemKind,
            e.field,
            e.summary,
            // A blank login is left blank rather than dressed up as a name.
            e.user,
          ],
      ],
    ),
    (
      title: 'Who has worked on this job',
      header: const ['Login', 'Changes'],
      rows: [
        for (final user in estimate.project.historyUsers)
          [
            user,
            entries
                .where((e) => e.user.toLowerCase() == user.toLowerCase())
                .length,
          ],
        if (entries.any((e) => e.user.isEmpty))
          [
            '(not recorded)',
            entries.where((e) => e.user.isEmpty).length,
          ],
      ],
    ),
  ];
}

/// The job's spares: what is spared, how many, and what is NOT.
///
/// Two tables, and the second is the one worth having. A list of the spares
/// somebody remembered to ask for reads as a job with spares on it; the list of
/// products with none is the one that turns into a decision — and it is the
/// list nothing in this app was ever going to produce on its own, because a
/// spare is not on any drawing and nothing was ever going to notice its
/// absence.
///
/// Equipment only in the second table, deliberately. Nobody wants a report
/// nagging about a spare blanking plate, and a list long enough to include them
/// is a list whose real rows — the boxes with power supplies in them — go
/// unread.
List<ReportSection> projectSparesSections(ProjectEstimate estimate) {
  final currency = estimate.currency;
  XlsxMoney cash(double v) => money(v, currency);
  // The code rather than the building's full name, for the reason
  // [masterPartsSections] gives: this is a room repeated once per part.
  final roomNames = {for (final r in estimate.rooms) r.ref.id: r.codeName};

  /// Which rooms asked for the spares — "who wanted this" is the question
  /// that follows every spare on a quote somebody is trimming.
  String askedBy(MasterPartLine line) => [
    for (final id in line.spareRoomIdsByQty())
      '${roomNames[id] ?? id} ×${trimNumber(line.spareByRoom[id] ?? 0)}',
  ].join(', ');

  final spared = estimate.sparedParts;
  final without = estimate.partsWithoutSpares;
  final sections = <ReportSection>[];

  sections.add((
    title: 'Spares on this job',
    header: const [
      'Part',
      'Manufacturer',
      'Model',
      'Part number',
      'Spares',
      'For install',
      'Total bought',
      'Unit price',
      'Spares cost',
      'Asked for by',
    ],
    rows: spared.isEmpty
        ? [
            [
              'Nothing on this job is spared.',
              '', '', '', '', '', '', '', '', '',
            ],
          ]
        : [
            for (final l in spared)
              [
                l.description,
                l.manufacturer,
                l.model,
                l.partNumber,
                l.spareQty,
                l.drawnQty,
                l.qty,
                l.unpriced ? 'not priced' : formatMoney(l.unitPrice, currency),
                cash(l.spareQty * l.unitPrice),
                askedBy(l),
              ],
          ],
  ));

  // HOW MUCH OF THE JOB IS SPARED, part by part. The table above says what
  // was asked for; this one says whether it is enough, which is the question
  // the first table cannot be read for - "two spare projectors" is a row
  // nobody can approve until they know two out of how many.
  final cover = estimate.spareCover;
  sections.add((
    title: estimate.unsparedParts.isEmpty
        ? 'Spare cover, part by part'
        : 'Spare cover, part by part '
              '(${estimate.unsparedParts.length} with no spare)',
    header: const [
      'Part',
      'Manufacturer',
      'Model',
      'Installed',
      'Spares',
      'Cover',
      'Any spare',
    ],
    rows: cover.isEmpty
        ? [
            ['Nothing on this job is installed yet.', '', '', '', '', '', ''],
          ]
        : [
            for (final c in cover)
              [
                c.line.description,
                c.line.manufacturer,
                c.line.model,
                c.installed,
                c.spares,
                // A percentage as text rather than as a number: the column
                // holds "5%" beside "0%", and a spreadsheet that formatted one
                // of them as 0.05 would be read as five units.
                formatSpareCover(c.coverage),
                c.short ? 'none' : 'yes',
              ],
          ],
  ));

  sections.add((
    title: 'Equipment with NO spare (${without.length})',
    header: const [
      'Part',
      'Manufacturer',
      'Model',
      'Part number',
      'Units on the job',
      'Unit price',
      'One spare would cost',
      'Rooms',
    ],
    rows: without.isEmpty
        ? [
            ['Every product on this job has a spare.', '', '', '', '', '', '', ''],
          ]
        : [
            for (final l in without)
              [
                l.description,
                l.manufacturer,
                l.model,
                l.partNumber,
                l.qty,
                l.unpriced ? 'not priced' : formatMoney(l.unitPrice, currency),
                l.unpriced ? '' : cash(l.unitPrice),
                [
                  for (final id in l.roomIdsByQty())
                    '${roomNames[id] ?? id} '
                        '×${trimNumber(l.qtyByRoom[id] ?? 0)}',
                ].join(', '),
              ],
          ],
  ));

  // THE BUILDING'S OWN, which no room's table can carry: a switcher on a shelf
  // for the campus belongs to no room, and the figure it is approved on is not
  // its price but its COVERAGE. Two spare projectors is a number nobody can
  // weigh until they know two out of how many.
  final shelf = estimate.buildingSpares;
  sections.add((
    title: 'Spares for the building (${shelf.length})',
    header: const [
      'Part',
      'Manufacturer',
      'Model',
      'On the shelf',
      'Installed on the job',
      'Coverage',
      'Cost',
      'A spare for',
    ],
    rows: shelf.isEmpty
        ? [
            [
              'Nothing is spared for the building as a whole.',
              '', '', '', '', '', '', '',
            ],
          ]
        : [
            for (final row in shelf)
              [
                row.line.description,
                row.line.manufacturer,
                row.line.model,
                row.qty,
                row.installed,
                // A part no room is having covers nothing measurable, and
                // both '0%' and 'infinity%' would be saying something untrue.
                row.coverage == null
                    ? 'nothing installed'
                    : '${(row.coverage! * 100).toStringAsFixed(
                        row.coverage! >= 0.1 ? 0 : 1,
                      )}%',
                cash(row.cost),
                [
                  for (final id in row.roomIds)
                    '${roomNames[id] ?? id} '
                        '×${trimNumber(row.line.qtyByRoom[id] ?? 0)}',
                ].join(', '),
              ],
          ],
  ));

  // WHOSE SPARES THEY ARE. The two tables above are per PART, which is what a
  // vendor is quoting; this one is per ROOM, which is what gets approved or
  // trimmed. A spares bill nobody can break back down to a room is one that
  // gets cut whole because no one could defend any part of it.
  final byRoom = estimate.sparesByRoom;
  sections.add((
    title: 'Spares by room (${byRoom.length})',
    header: const [
      'Room',
      'Spare units',
      'Products spared',
      'Spares cost',
      'What was spared',
    ],
    rows: byRoom.isEmpty
        ? [
            ['No room on this job asked for a spare.', '', '', '', ''],
          ]
        : [
            for (final r in byRoom)
              [
                r.name,
                r.units,
                r.parts,
                cash(r.cost),
                [
                  for (final l in estimate.sparedPartsForRoom(r.roomId))
                    '${l.description} '
                        '×${trimNumber(l.spareByRoom[r.roomId] ?? 0)}',
                ].join(', '),
              ],
          ],
  ));

  sections.add((
    title: 'Spares total',
    header: const ['', ''],
    rows: [
      ['Products with a spare', spared.length],
      ['Equipment with none', without.length],
      ['Spare units bought', estimate.spareUnits],
      // Split out because the two are approved by different people: a room's
      // spare is that room's contingency, and the building's is the job's.
      ['Of those, for the building', estimate.buildingSpareUnits],
      ['Spares cost', cash(estimate.sparesTotal)],
      ['Of that, for the building', cash(estimate.buildingSparesTotal)],
    ],
  ));

  return sections;
}

/// Every device on the job that no control module will drive, room by room.
///
/// The building's version of the sheet a room's own AV and Cost exports carry,
/// built from the same rule (control_gaps.dart) so the two cannot disagree
/// about which devices are undriven.
///
/// Room first in the sort, because this list is worked THROUGH: somebody opens
/// one room, fixes everything on it, and moves to the next. Sorted by device it
/// would be a list that sends them back and forth across the building.
List<ReportSection> projectControlGapSections(ProjectEstimate estimate) {
  if (estimate.controlGaps.isEmpty) return const [];

  String devices(int n) => '$n device${n == 1 ? '' : 's'}';
  final byKind = <ControlGapKind, int>{};
  for (final entry in estimate.controlGaps) {
    byKind[entry.gap.kind] = (byKind[entry.gap.kind] ?? 0) + entry.gap.qty;
  }

  return [
    (
      title: 'Devices Without a Control Module',
      header: const ['Room', 'Device', 'Model', 'Qty', 'From', 'Note'],
      rows: [
        for (final entry in estimate.controlGaps)
          [
            // 'BSS 103'. This list is worked THROUGH room by room, so the
            // column is read forty times down the page and the code is the
            // form of it somebody can scan.
            entry.room.codeName,
            entry.gap.device,
            entry.gap.model.isEmpty ? '(no model set)' : entry.gap.model,
            entry.gap.qty,
            entry.gap.sourceLabel,
            entry.gap.note,
          ],
      ],
    ),
    (
      title: 'What needs doing',
      header: const ['', ''],
      rows: [
        if ((byKind[ControlGapKind.moduleUnset] ?? 0) > 0)
          [
            'Pick the module',
            '${devices(byKind[ControlGapKind.moduleUnset]!)} - a module '
                'already claims the model; the field is just empty.',
          ],
        if ((byKind[ControlGapKind.noModuleClaims] ?? 0) > 0)
          [
            'No driver exists',
            '${devices(byKind[ControlGapKind.noModuleClaims]!)} - write or '
                'import a module, or mark the product as never controlled on '
                'the Catalog tab if it genuinely has no interface.',
          ],
        if ((byKind[ControlGapKind.noModel] ?? 0) > 0)
          [
            'Choose a model',
            byKind[ControlGapKind.noModel] == 1
                ? '1 device has no model, so nothing can be matched to it.'
                : '${byKind[ControlGapKind.noModel]} devices have no model, '
                      'so nothing can be matched to them.',
          ],
        if ((byKind[ControlGapKind.notDrawn] ?? 0) > 0)
          [
            'In the config, not on the drawing',
            '${devices(byKind[ControlGapKind.notDrawn]!)} - undriven and not '
                'on the signal flow either.',
          ],
        ['Total', devices(estimate.undrivenDevices)],
      ],
    ),
  ];
}

/// EVERY QUOTE ON THE JOB, PACKAGE BY PACKAGE - the sheet the award is argued
/// from.
///
/// One row per bid rather than one per package, because the question is not
/// "what did this cost" but "what did each of them say, and how far apart were
/// they". A package with a single bid still gets its row: a sole quote against
/// our own estimate is the same comparison with one fewer column.
///
/// Empty when nobody has been asked anything, so a job that has not gone out
/// yet does not carry a blank sheet around.
List<ReportSection> quoteComparisonSections(ProjectEstimate estimate) {
  final currency = estimate.currency;
  XlsxMoney cash(double v) => money(v, currency);
  final project = estimate.project;
  final sections = <ReportSection>[];

  for (final package in estimate.packages) {
    final rfq = package.rfq;
    if (rfq == null || rfq.bids.isEmpty) continue;
    sections.addAll(packageQuoteSections(estimate, package));
  }
  if (sections.isEmpty) return const [];

  // The job-wide line, at the end, where a total belongs. Only the AWARDED
  // packages: adding up quotes nobody has accepted would be a number that
  // reads like a commitment and is not one.
  final awarded = [
    for (final p in estimate.packages)
      if (p.rfq?.winningBid != null) p,
  ];
  if (awarded.isNotEmpty) {
    sections.add((
      title: 'Awarded so far',
      header: const ['Package', 'Vendor', 'PO', 'Quoted', 'Our estimate'],
      rows: [
        for (final p in awarded)
          [
            p.packageName,
            p.awardedVendor?.name ?? '',
            p.rfq!.poNumber,
            p.rfq!.winningBid!.amount > 0
                ? cash(p.rfq!.winningBid!.amount)
                : '',
            cash(p.total),
          ],
        [
          'Total',
          '',
          '',
          cash(
            awarded.fold(0.0, (t, p) => t + p.rfq!.winningBid!.amount),
          ),
          cash(awarded.fold(0.0, (t, p) => t + p.total)),
        ],
      ],
    ));
  }
  // The project number is on the header of every other sheet; this one is read
  // on its own often enough to say which job it belongs to.
  if (project.projectNumber.trim().isNotEmpty) {
    sections.insert(0, (
      title: 'Project',
      header: const ['', ''],
      rows: [
        ['Project number', project.projectNumber.trim()],
      ],
    ));
  }
  return sections;
}

/// One package's quotes, side by side — who was asked, what came back, and how
/// each answer sits against the figure we hold.
///
/// The DELTA is the column that does the work. Four raw prices in a column are
/// four numbers somebody has to subtract in their head, and the question being
/// asked of them is always the same one: is this above or below what we
/// budgeted, and by how much.
///
/// Returns nothing at all for a package nobody has been asked to quote.
List<ReportSection> packageQuoteSections(
  ProjectEstimate estimate,
  VendorPackage package,
) {
  final rfq = package.rfq;
  if (rfq == null || rfq.bids.isEmpty) return const [];
  final currency = estimate.currency;
  XlsxMoney cash(double v) => money(v, currency);
  final project = estimate.project;

  String vendorName(String id) =>
      project.vendorById(id)?.name ?? '(vendor removed)';

  // Cheapest first, then everybody who has answered, then the silent ones.
  // The order a comparison is actually read in: the shortlist is at the top
  // and the chasing list is at the bottom.
  final ordered = [...rfq.bids]
    ..sort((a, b) {
      if (a.hasPrice != b.hasPrice) return a.hasPrice ? -1 : 1;
      if (a.hasPrice && b.hasPrice) return a.amount.compareTo(b.amount);
      if (a.hasAnswered != b.hasAnswered) return a.hasAnswered ? -1 : 1;
      return vendorName(a.vendorId).toLowerCase().compareTo(
        vendorName(b.vendorId).toLowerCase(),
      );
    });

  final low = rfq.lowestBid;
  return [
    (
      title: '${package.packageName} - quotes',
      header: const [
        'Vendor',
        'Sent',
        'Quoted',
        'Reference',
        'Amount',
        'vs our estimate',
        'Promised',
        'Status',
        'Notes',
      ],
      rows: [
        for (final b in ordered)
          [
            vendorName(b.vendorId),
            b.sentOn == null ? '' : formatIsoDate(b.sentOn!),
            b.quotedOn == null ? '' : formatIsoDate(b.quotedOn!),
            b.reference,
            b.hasPrice ? cash(b.amount) : '',
            // Signed on purpose: '+1,240' and '-1,240' are opposite answers
            // and an unsigned column makes them look like the same one.
            b.hasPrice && package.total > 0
                ? '${b.amount >= package.total ? '+' : '-'}'
                      '${trimNumber((b.amount - package.total).abs())}'
                : '',
            b.expectedOn == null ? '' : formatIsoDate(b.expectedOn!),
            [
              if (rfq.awardedVendorId == b.vendorId) 'AWARDED',
              if (b.declined) 'declined',
              if (!b.declined && b.quotedOn == null && b.isSent) 'awaited',
              if (!b.isSent) 'not sent',
              if (low != null && low.vendorId == b.vendorId && b.hasPrice)
                'lowest',
            ].join(', '),
            b.notes,
          ],
        [
          'Our estimate',
          '',
          '',
          '',
          cash(package.total),
          '',
          '',
          '${package.lines.length} lines',
          '',
        ],
      ],
    ),
  ];
}

/// One package's quote request, addressed to one vendor: what they are being
/// asked to price, under what terms, and by when.
///
/// EVERY COPY IS THE SAME DOCUMENT except the addressee. That is the point of
/// competing a package — three vendors pricing three slightly different
/// requests produce three numbers that cannot be compared, and nobody can see
/// from the answers that they differed. The parts, the terms and the due date
/// come off the package; only the name at the top comes off the vendor.
///
/// Deliberately NOT a copy of the master list filtered down. It carries no
/// labor, no fees, no tax, no other package's parts and no project total —
/// those are the stakeholder's numbers, and a quote request that leaks them is
/// a negotiating position handed to a supplier.
///
/// OUR OWN ESTIMATE is on the sheet only when the package says so — see
/// [ProjectRfq.showEstimate]. Withheld by default from a competition, because
/// handing every bidder the figure we hold anchors all of them to it.
List<ReportSection> vendorPackageSections(
  ProjectEstimate estimate,
  VendorPackage package, {
  ProjectVendor? vendor,
}) {
  final currency = estimate.currency;
  XlsxMoney cash(double v) => money(v, currency);
  final project = estimate.project;
  final rfq = package.rfq;
  final showEstimate = rfq?.sendsEstimate ?? true;
  // The code here too: it is what will be on the label when this arrives, and
  // what the person unpacking it is standing in front of.
  final roomNames = {for (final r in estimate.rooms) r.ref.id: r.codeName};

  String rooms(MasterPartLine line) => [
    for (final id in line.roomIdsByQty())
      '${roomNames[id] ?? id} ×${trimNumber(line.qtyByRoom[id] ?? 0)}',
  ].join(', ');

  final sections = <ReportSection>[
    (
      title: 'Quote request',
      header: const ['', ''],
      rows: [
        ['Package', package.packageName],
        if (vendor != null) ['To', vendor.name],
        if ((vendor?.contact ?? '').isNotEmpty) ['Contact', vendor!.contact],
        if (project.name.trim().isNotEmpty) ['Project', project.name],
        if (project.building.trim().isNotEmpty) ['Building', project.building],
        if (project.projectNumber.trim().isNotEmpty)
          ['Project number', project.projectNumber],
        ['Line items', package.lines.length],
        ['Total units', trimNumber(package.qty)],
        // The date is ON THE PAPER rather than in a diary on this end: a due
        // date the vendor never saw is not a due date.
        if (rfq?.dueBy != null) ['Quotes due by', formatIsoDate(rfq!.dueBy!)],
        if ((rfq?.scope ?? '').trim().isNotEmpty) ['Terms', rfq!.scope.trim()],
      ],
    ),
  ];

  for (final kind in MasterPartKind.values) {
    final lines = [for (final l in package.lines) if (l.kind == kind) l];
    if (lines.isEmpty) continue;
    sections.add((
      title: kMasterPartKindLabels[kind]!,
      header: [
        'Item',
        'Manufacturer',
        'Model',
        'Part number',
        'Qty',
        // The prices we HOLD, so a returned quote can be compared against them
        // line by line. Off by default once more than one vendor is bidding -
        // see the note on this function.
        if (showEstimate) 'Our estimate (unit)',
        if (showEstimate) 'Our estimate (ext)',
        // Left empty on purpose: this is where the vendor writes.
        'Your unit price',
        'Your extended',
        'Lead time',
        'Rooms',
      ],
      rows: [
        for (final l in lines)
          [
            l.description,
            l.manufacturer,
            l.model,
            l.partNumber,
            l.qty,
            if (showEstimate) l.unpriced ? '' : cash(l.unitPrice),
            if (showEstimate) l.unpriced ? '' : cash(l.total),
            '',
            '',
            '',
            rooms(l),
          ],
      ],
    ));
  }

  return sections;
}

// ---------------------------------------------------------------------------
//  THE BOOKS
// ---------------------------------------------------------------------------

/// The whole project: summary, master list, a tab per vendor, a tab per room.
Uint8List buildProjectWorkbookBytes({
  required ProjectEstimate estimate,
  DateTime? generated,

  /// The catalog and the base card, for pricing the replacement plan. Both
  /// optional because the estimate does not carry either and a caller that
  /// only wants the quote should not have to find them — without them the plan
  /// still says WHEN each room falls due, and simply prices nothing.
  AvDeviceLibrary? library,
  BaseCostBook? baseCosts,
  PricingTier tier = PricingTier.msrp,
  /// Add the two sheets that can be typed in and read back — see
  /// online_roundtrip.dart.
  ///
  /// OFF for a workbook saved by hand, ON for the published copy. A book
  /// somebody saves to their desktop and mails on is a document; only the
  /// copy in the synced folder is a thing this app will read again, and two
  /// form sheets on every export would invite edits into files nothing is
  /// ever going to pick up.
  bool editable = false,

  /// The class schedule, for the Class Schedule tab written when the job has
  /// install windows. Without it the windows are still charted.
  ClassScheduleIndex? classSchedule,
}) {
  final stamp = generated ?? DateTime.now();
  final title = _projectTitle(estimate.project);

  // Vendor and room names become tab names, and both are free text the user
  // typed. Excel refuses a book with two sheets of one name and refuses one
  // whose names run past 31 characters — and "Behavioral and Social Science
  // 101" and "...102" clip to the same thing — so every name goes through the
  // same settling the location report's per-drawing tabs use.
  final taken = <String>{};
  String tab(String proposed) => uniqueXlsxSheetName(proposed, taken);

  final sheets = <XlsxSheet>[
    buildStackedReportSheet(
      sheetName: tab(kProjectWorkbookSheets[0]),
      title: title,
      sections: projectSummarySections(estimate),
      generated: stamp,
    ),
  ];

  // THE ROOM TABS ARE NAMED NOW, so the master list can link to them. They
  // are still written last, after every other sheet.
  final allItemsTab = tab(kProjectAllItemsSheet);
  final roomTabs = <String, String>{
    for (final room in estimate.rooms)
      if (room.ok && costReportSections(room.estimate!).isNotEmpty)
        room.ref.id: tab(room.name),
  };
  // THE MASTER LIST IS LAID OUT FIRST, so every room's lines can read their
  // price off it: change a price there and it changes in every room. It is
  // still placed after All Items.
  final master = masterPartsSections(estimate);
  final masterSheet = master.isEmpty
      ? null
      : buildStackedReportSheet(
          sheetName: tab(kProjectWorkbookSheets[1]),
          title: '$title - core components list',
          sections: master,
          generated: stamp,
        );
  final MasterPriceCells masterCells = masterSheet == null
      ? const {}
      : _linkMasterSheet(masterSheet, estimate);
  if (masterSheet != null) _formulaMasterTotals(masterSheet);

  // THE ROOM TABS ARE LAID OUT HERE TOO, so All Items can read each room's
  // own totals. They are still written last, after every other sheet.
  final summaryTab = sheets.first.name;
  final roomSheets = <XlsxSheet>[];
  final roomTotals = <String, RoomTotalRefs>{};
  // Every room that priced, including the excluded ones: an alternate that is
  // out of the total is still work somebody did and still gets read.
  for (final room in estimate.rooms) {
    if (!room.ok) continue;
    final priced = costReportSections(room.estimate!);
    final tabName = roomTabs[room.ref.id];
    if (priced.isEmpty || tabName == null) continue;
    final sheet = buildStackedReportSheet(
      sheetName: tabName,
      title: room.ref.included
          ? room.name
          : '${room.name} - EXCLUDED from the project total',
      // The way back to the master list, then the room's scope, notes and
      // custom sections, as on its own exports.
      sections: [
        (
          title: 'Go to',
          header: const ['', ''],
          rows: [
            [
              XlsxLink(text: 'All items (every room)', sheet: allItemsTab),
              '',
            ],
            [XlsxLink(text: 'Summary', sheet: summaryTab), ''],
          ],
        ),
        ...withEstimateSections(
          _linkRoomSections(priced, room.estimate!, estimate, masterCells),
          room.room.settings,
        ),
      ],
      generated: stamp,
    );
    roomTotals[tabName] = _formulaRoomTotals(sheet, room.estimate!);
    roomSheets.add(sheet);
  }

  if (roomTabs.isNotEmpty || estimate.project.manualRooms.isNotEmpty) {
    final allItems = buildStackedReportSheet(
      sheetName: allItemsTab,
      title: '$title - all items',
      sections: allItemsSections(
        estimate,
        roomTabs: roomTabs,
        masterCells: masterCells,
      ),
      generated: stamp,
    );
    _formulaAllItemsTotals(allItems, roomTotals);
    sheets.add(allItems);
  }

  if (masterSheet != null) {
    sheets.add(masterSheet);
    final byRoom = partsByRoomSections(estimate);
    if (byRoom.isNotEmpty) {
      sheets.add(buildStackedReportSheet(
        sheetName: tab(kProjectPartsByRoomSheet),
        title: '$title - parts by room',
        sections: byRoom,
        generated: stamp,
      ));
    }
  }

  // Purchasing works down this in date order and does not care which vendor
  // rule tagged what, so it is a sheet rather than more columns on the parts
  // list.
  if (estimate.master.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kProjectTimelineSheet),
      title: '$title - when to order',
      sections: projectTimelineSections(estimate, asOf: stamp),
      generated: stamp,
    ));
  } else if (estimate.project.installWindows.isNotEmpty) {
    // No parts to order, but install windows still go out on the sheet.
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kProjectTimelineSheet),
      title: '$title - maintenance windows',
      sections: installWindowSections(estimate.project),
      generated: stamp,
    ));
  }

  // When each room is free, beside when its parts are due.
  final classes = classScheduleSections(
    estimate.project,
    classSchedule ?? ClassScheduleIndex.empty,
  );
  if (classes.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kClassScheduleSheet),
      title: '$title - class schedule and maintenance windows',
      sections: classes,
      generated: stamp,
    ));
  }

  // Its own sheet rather than a block at the foot of the parts list: "what is
  // not spared" is a list of things that are NOT on the order, and a table of
  // absences buried under a table of purchases is a table nobody reads.
  if (estimate.master.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kProjectSparesSheet),
      title: '$title - spares',
      sections: projectSparesSections(estimate),
      generated: stamp,
    ));
  }

  // WHAT WAS BOUGHT AND WHERE IT IS. Its own sheet next to the timeline,
  // because the two are the same job read at two different moments: the
  // timeline is what has to be ordered, this is what was ordered and what
  // came of it. Written only when there is something to write — a blank sheet
  // headed "Purchasing" in an issued workbook reads as a job nobody has
  // bought anything for.
  final purchasing = projectPurchasingSections(estimate);
  if (purchasing.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kProjectPurchasingSheet),
      title: '$title - purchase orders and deliveries',
      sections: purchasing,
      generated: stamp,
    ));
  }

  final gaps = projectControlGapSections(estimate);
  if (gaps.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kProjectControlSheet),
      title: '$title - devices without a control module',
      sections: gaps,
      generated: stamp,
    ));
  }

  // Whose job each piece of scope is. On the workbook because it is agreed
  // with the contractor off the same document the quantities are read from,
  // and a matrix that only exists as a separate file is one that goes out of
  // step with the rooms the moment either changes.
  //
  // THE SAME SHEET the Responsibility page exports, so the two copies match.
  final matrix = responsibilityMatrixSheet(
    estimate.project.responsibility,
    projectName: estimate.project.name,
    roomNames: estimate.project.responsibilityRoomColumns(
      names: estimate.roomCodeNames,
    ),
    partyColors: estimate.project.partyColors,
    sheetName: tab(kProjectResponsibilitySheet),
    generated: stamp,
  );
  if (matrix != null) sheets.add(matrix);

  // The contractor's procurement log, as its own export writes it.
  // Only on a job that keeps one. The lines are the live ones - named off the
  // rooms, with every room line on them - see procurement_sync.dart.
  final procurement = !estimate.project.procurement.any((e) => !e.excluded)
      ? null
      : procurementLogSheet(
          estimate.project.name,
          liveProcurement(estimate.project, estimate),
          sheetName: tab(kProcurementLogSheet),
          generated: stamp,
          colors: estimate.project.procurementColors,
          labels: estimate.project.procurementColumnLabels,
          columns: estimate.project.procurementColumns,
        );
  if (procurement != null) sheets.add(procurement);

  // The job AFTER this one: what is already in the building, and the year it
  // has to come out. On the workbook because that is the document a budget
  // request is assembled from, and beside the order timeline because the two
  // are the same calendar read forward and back.
  final lifecycle = buildingLifecycleSections(
    buildProjectLifecycle(
      estimate: estimate,
      library: library,
      baseCosts: baseCosts,
      tier: tier,
      asOf: stamp,
    ),
  );
  if (lifecycle.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kProjectLifecycleSheet),
      title: '$title - when it has to be replaced',
      sections: lifecycle,
      generated: stamp,
    ));
  }

  // After the job's own sheets and before the vendor tabs: it is a record
  // about the JOB, and it should not push the tabs somebody actually sends
  // anywhere further along than they already are.
  final changes = projectHistorySections(estimate);
  if (changes.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab(kProjectHistorySheet),
      title: '$title - who changed what',
      sections: changes,
      generated: stamp,
    ));
  }

  // THE COMPARISON, before the package tabs. It is the sheet the decision gets
  // taken off - who quoted what against what we held - and it is the one thing
  // in this book that did not exist while a vendor was a package, because
  // there was never more than one price to put in a row.
  final comparison = quoteComparisonSections(estimate);
  if (comparison.isNotEmpty) {
    sheets.add(buildStackedReportSheet(
      sheetName: tab('Quote comparison'),
      title: '$title - quotes received',
      sections: comparison,
      generated: stamp,
    ));
  }

  for (final package in estimate.packages) {
    sheets.add(buildStackedReportSheet(
      // The package's name is the tab, so the book is navigable by the thing
      // somebody is looking for.
      sheetName: tab(package.isUntagged ? 'Untagged' : package.packageName),
      title: '$title - ${package.packageName}',
      sections: [
        ...packageQuoteSections(estimate, package),
        ...vendorPackageSections(estimate, package),
      ],
      generated: stamp,
    ));
  }

  // THE FORM, at the end. It is the sheet somebody TYPES in rather than one
  // they read, so it sits after everything that gets read — and after the
  // package tabs, which are what a reader is usually looking for.
  final forms = <XlsxSheet>[
    if (editable) ...[
      buildEditableDeliveriesSheet(
        estimate.project,
        roomNames: estimate.roomCodeNames,
      ),
      buildEditablePosSheet(estimate.project),
    ],
  ];
  sheets.addAll(forms);

  _formulaSummaryTotals(sheets.first, estimate, roomTabs, roomTotals);
  sheets.addAll(roomSheets);

  // Every other part table points back at the master list too. Not the
  // master itself, and not the forms, which are read back as typed.
  if (masterSheet != null && masterCells.isNotEmpty) {
    for (final sheet in sheets) {
      if (identical(sheet, masterSheet) || forms.contains(sheet)) continue;
      // Issued documents in their own right: kept as their own exports.
      if (identical(sheet, matrix) || identical(sheet, procurement)) continue;
      _linkPartTables(sheet, estimate, masterCells);
    }
  }

  return buildXlsx(sheets);
}

/// One vendor's quote request, as its own file.
Uint8List buildVendorRfqBytes({
  required ProjectEstimate estimate,
  required VendorPackage package,
  ProjectVendor? vendor,
  DateTime? generated,
}) => buildXlsx([
  buildStackedReportSheet(
    sheetName: xlsxSheetName(
      package.isUntagged ? 'Untagged' : package.packageName,
    ),
    title: '${_projectTitle(estimate.project)} - quote request',
    sections: vendorPackageSections(estimate, package, vendor: vendor),
    generated: generated ?? DateTime.now(),
  ),
]);

/// What the documents are headed with: the project name, the building, or
/// failing both something that is at least not blank.
String _projectTitle(BuildingProject project) {
  final name = project.name.trim();
  final building = project.building.trim();
  if (name.isNotEmpty && building.isNotEmpty && name != building) {
    return '$name - $building';
  }
  if (name.isNotEmpty) return name;
  if (building.isNotEmpty) return building;
  return 'Project';
}

/// A file name stem for one copy of a quote request, safe on every platform:
/// the project, the package and who it is going to, so a folder of them can be
/// read without opening any.
String vendorRfqFileStem(
  BuildingProject project,
  VendorPackage package, {
  ProjectVendor? vendor,
}) {
  String clean(String s) => s
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
      .replaceAll(RegExp(r'\s+'), '_');
  final job = clean(
    project.name.trim().isNotEmpty ? project.name : project.building,
  );
  final lot = clean(package.packageName);
  // The VENDOR too, now that one package produces a file per bidder: three
  // copies of Campus_Displays_RFQ.xlsx in one folder is three files nobody can
  // tell apart, and the second one silently overwrites the first.
  final to = clean(vendor?.name ?? '');
  final stem = [
    if (job.isNotEmpty) job,
    if (lot.isNotEmpty) lot,
    if (to.isNotEmpty) to,
    'RFQ',
  ].join('_');
  return stem.isEmpty ? 'RFQ' : stem;
}
