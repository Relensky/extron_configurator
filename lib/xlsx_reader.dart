import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// ============================================================================
///  READING AN .XLSX BACK
/// ============================================================================
///  This app has always written spreadsheets and never read one. It reads one
///  now for exactly one reason: the published copy of a job (see
///  online_copy.dart) is a file other people can open, and the moment somebody
///  can open it they will type in it — a delivery that landed, a quantity that
///  was wrong, the room a pallet went into. Those edits were going nowhere.
///
///  WHAT COMES BACK IS TEXT. Every cell is handed over as the string it reads
///  as, and the caller decides what a column means. That is deliberate: a
///  spreadsheet is a grid of what somebody typed, and a reader that tried to
///  guess types would have to guess wrong somewhere — '103' is a room, not a
///  number, and '0004' is a PO, not four.
///
///  IT HAS TO SURVIVE BEING SAVED BY SOMEBODY ELSE'S PROGRAM. This app writes
///  every string inline; Excel Online and Google Sheets both rewrite the file
///  with a shared-string table when they save it, and Sheets adds formula
///  results and its own styles. So all of it is handled — inline strings,
///  shared strings, formula cached values, numbers and booleans — because the
///  file that comes back is never the file that went out.
///
///  DATES ARE NOT DECODED, and the writer of a round-trip sheet should not
///  write them as dates. A date cell is a serial number against one of two
///  epochs, formatted by a style this reader would have to resolve, and the
///  two spreadsheet programs disagree about the edges. A round-trip column
///  holds '2026-04-20' as TEXT, which both programs leave alone and any human
///  can read — see [readXlsxTable].
/// ============================================================================

/// Every sheet in [bytes], in workbook order: name -> rows of cell text.
///
/// Rows are ragged — trailing blank cells are not padded — so callers should
/// index defensively. Blank rows are kept, because a row's POSITION is
/// sometimes the only thing tying it to what a reader saw on screen.
Map<String, List<List<String>>> readXlsxSheets(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);

  String? fileText(String name) {
    for (final f in archive.files) {
      if (f.name == name) return String.fromCharCodes(f.content as List<int>);
    }
    return null;
  }

  // The shared-string table, when the program that saved this used one.
  // Each <si> can be several runs; the cell reads as all of them joined.
  final shared = <String>[];
  final sharedXml = fileText('xl/sharedStrings.xml');
  if (sharedXml != null) {
    for (final si in XmlDocument.parse(
      sharedXml,
    ).findAllElements('si')) {
      shared.add(si.findAllElements('t').map((t) => t.innerText).join());
    }
  }

  // Sheet name -> the part that holds it. The workbook lists names against
  // relationship ids; the rels file says which file each id is.
  final workbookXml = fileText('xl/workbook.xml');
  if (workbookXml == null) return const {};
  final relsXml = fileText('xl/_rels/workbook.xml.rels') ?? '';
  final targets = <String, String>{};
  if (relsXml.isNotEmpty) {
    for (final rel in XmlDocument.parse(relsXml).findAllElements(
      'Relationship',
    )) {
      final id = rel.getAttribute('Id');
      final target = rel.getAttribute('Target');
      if (id != null && target != null) targets[id] = target;
    }
  }

  final out = <String, List<List<String>>>{};
  var fallbackIndex = 0;
  for (final sheet in XmlDocument.parse(workbookXml).findAllElements('sheet')) {
    fallbackIndex++;
    final name = sheet.getAttribute('name');
    if (name == null) continue;
    // 'r:id', whatever prefix this file bound the relationship namespace to.
    final rid = _relationshipId(sheet);
    // The rels entry when there is one; otherwise the nth worksheet, which is
    // what a file written without rels (or with an id this cannot resolve)
    // still lines up with.
    final target = targets[rid] ?? 'worksheets/sheet$fallbackIndex.xml';
    final part = target.startsWith('/')
        ? target.substring(1)
        : target.startsWith('xl/')
        ? target
        : 'xl/$target';
    final xml = fileText(part);
    if (xml == null) continue;
    out[name] = _readSheet(xml, shared);
  }
  return out;
}

/// One sheet's cells as text, or null when the book has no sheet of that name.
List<List<String>>? readXlsxSheet(Uint8List bytes, String name) =>
    readXlsxSheets(bytes)[name];

/// A sheet read as a TABLE: the row at [headerRow] names the columns, and
/// every row under it comes back keyed by those names.
///
/// The shape a round-trip sheet is read in. Keys are trimmed and lower-cased,
/// so a column somebody has re-capitalised — or that a spreadsheet program has
/// tidied — still lands on the same field.
///
/// EMPTY ROWS ARE DROPPED, because a spreadsheet is full of them: the blank
/// line under a table, the fifty rows a program pads a file with, the row
/// somebody cleared instead of deleting. A row with nothing in any column
/// cannot say anything and must never read as an instruction to blank a
/// record.
List<Map<String, String>> readXlsxTable(
  Uint8List bytes,
  String sheet, {
  int headerRow = 0,
  String headerMarker = '',
}) {
  final grid = readXlsxSheet(bytes, sheet);
  if (grid == null) return const [];
  // FOUND, NOT COUNTED, when the caller knows what the first column is called.
  // A sheet with a title and a line of instructions above the table is a sheet
  // somebody will insert a row into, and a header row addressed by number
  // would then read the instructions as column names.
  if (headerMarker.isNotEmpty) {
    final needle = headerMarker.trim().toLowerCase();
    for (var r = 0; r < grid.length; r++) {
      if (grid[r].isNotEmpty && grid[r].first.trim().toLowerCase() == needle) {
        headerRow = r;
        break;
      }
    }
  }
  if (grid.length <= headerRow) return const [];
  final header = [
    for (final cell in grid[headerRow]) cell.trim().toLowerCase(),
  ];
  final rows = <Map<String, String>>[];
  for (var r = headerRow + 1; r < grid.length; r++) {
    final cells = grid[r];
    if (cells.every((c) => c.trim().isEmpty)) continue;
    final row = <String, String>{};
    for (var c = 0; c < header.length; c++) {
      if (header[c].isEmpty) continue;
      row[header[c]] = c < cells.length ? cells[c].trim() : '';
    }
    rows.add(row);
  }
  return rows;
}

/// One worksheet part, as a grid of text.
List<List<String>> _readSheet(String xml, List<String> shared) {
  final rows = <List<String>>[];
  for (final row in XmlDocument.parse(xml).findAllElements('row')) {
    // The row's own number when it has one: a sheet with gaps in it would
    // otherwise close them up and move every row under the gap.
    final at = int.tryParse(row.getAttribute('r') ?? '');
    final cells = <String>[];
    for (final cell in row.findElements('c')) {
      final index = _columnOf(cell.getAttribute('r'));
      final value = _cellText(cell, shared);
      if (index == null) {
        cells.add(value);
        continue;
      }
      while (cells.length < index) {
        cells.add('');
      }
      if (cells.length == index) {
        cells.add(value);
      } else {
        cells[index] = value;
      }
    }
    if (at != null) {
      while (rows.length < at - 1) {
        rows.add(const []);
      }
    }
    rows.add(cells);
  }
  return rows;
}

/// What one cell reads as.
String _cellText(XmlElement cell, List<String> shared) {
  final type = cell.getAttribute('t') ?? 'n';
  switch (type) {
    case 's':
      final index = int.tryParse(cell.findElements('v').firstOrNull?.innerText ?? '');
      return (index != null && index >= 0 && index < shared.length)
          ? shared[index]
          : '';
    case 'inlineStr':
      return cell.findAllElements('t').map((t) => t.innerText).join();
    case 'b':
      return (cell.findElements('v').firstOrNull?.innerText ?? '') == '1'
          ? 'TRUE'
          : 'FALSE';
    case 'e':
      // An error cell — #REF!, #N/A. Handed over as it reads, so a caller can
      // say "that column is broken" rather than silently taking a blank.
      return cell.findElements('v').firstOrNull?.innerText ?? '';
    default:
      // Numbers, and 'str' formula results. A number comes back as the text
      // the file holds: '4', not '4.0' — see the note at the head of this
      // file about not guessing types.
      final v = cell.findElements('v').firstOrNull?.innerText;
      if (v != null) return v;
      return cell.findAllElements('t').map((t) => t.innerText).join();
  }
}

/// The relationship id on a `<sheet>` element — `r:id`, under whichever prefix
/// the file happens to have bound the namespace to. Matched on the LOCAL name
/// for that reason: the prefix is the writer's choice, not the format's.
String? _relationshipId(XmlElement sheet) {
  for (final attribute in sheet.attributes) {
    if (attribute.name.local == 'id') return attribute.value;
  }
  return null;
}

/// The zero-based column an A1 reference names — 'C7' is 2, 'AA1' is 26.
int? _columnOf(String? ref) {
  if (ref == null || ref.isEmpty) return null;
  var value = 0;
  var seen = 0;
  for (final unit in ref.codeUnits) {
    if (unit >= 0x41 && unit <= 0x5A) {
      value = value * 26 + (unit - 0x40);
      seen++;
    } else if (unit >= 0x61 && unit <= 0x7A) {
      value = value * 26 + (unit - 0x60);
      seen++;
    } else {
      break;
    }
  }
  return seen == 0 ? null : value - 1;
}
