import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'online_roundtrip.dart';
import 'xlsx_reader.dart';

/// ============================================================================
///  EVERYTHING TYPED INTO THE SHEET, NOT ONLY THE THREE TABS READ BACK
/// ============================================================================
///  Three tabs of the published copy are a form the app can read back
///  (online_roundtrip.dart). Every other tab - a room's listing, the summary -
///  is a report: the app writes it and never looked at it again. So a row
///  changed in a room's tab was found by no pull, held no publish, and was
///  written over by the next save without a word.
///
///  The app cannot turn a cell typed into a report back into the room it came
///  from. What it can do is never lose it:
///
///   * after each publish, what every tab says is kept beside the project
///     (`<project file>.online_sheet_baseline.json.gz` for the live Google
///     Sheet, `.online_workbook_baseline.json.gz` for the .xlsx in the synced
///     folder, whose formula cells are compared as formulas, not totals);
///   * before the next publish, and on every pull, the Sheet is compared with
///     that cell by cell, and every difference is listed with the rest - the
///     tab, the row, the column, what it said and what it says now;
///   * the list goes in the history file (online_pull_history.dart) before
///     anything is written over.
///
///  These are [kSheetEditKind] changes: listed and kept, not applied.
/// ============================================================================

/// The kind of an [OnlineChange] that was found in a tab the app cannot read
/// back. It is shown and recorded; applying an import does not act on it.
const String kSheetEditKind = 'sheet edit';

/// Where the last published contents of the Sheet are kept for [projectFile]
/// - or, with [workbook], of the .xlsx in the synced folder.
String onlineSheetBaselinePath(String projectFile, {bool workbook = false}) =>
    '$projectFile.online_${workbook ? 'workbook' : 'sheet'}_baseline.json.gz';

/// What a formula cell is kept as. A formula's figure moves whenever what it
/// adds up moves, so comparing it would list every total under every real
/// edit. The cell is compared as "a formula" instead: still one, nothing to
/// say; typed over with a figure, listed like any other edit.
const String kFormulaCell = '(formula)';

/// The workbook's tabs as text, each formula cell read as [kFormulaCell].
Map<String, List<List<String>>> workbookGrids(Uint8List bytes) {
  final formulas = <String, Set<String>>{};
  final grids = readXlsxSheets(bytes, formulas: formulas);
  return {
    for (final e in grids.entries)
      e.key: [
        for (var r = 0; r < e.value.length; r++)
          [
            for (var c = 0; c < e.value[r].length; c++)
              (formulas[e.key]?.contains('$r:$c') ?? false)
                  ? kFormulaCell
                  : e.value[r][c],
          ],
      ],
  };
}

/// What every tab said after the last publish, or null when none was kept.
Map<String, List<List<String>>>? readSheetBaseline(
  String projectFile, {
  bool workbook = false,
}) {
  if (projectFile.trim().isEmpty) return null;
  try {
    final file =
        File(onlineSheetBaselinePath(projectFile, workbook: workbook));
    if (!file.existsSync()) return null;
    final doc = jsonDecode(utf8.decode(gzip.decode(file.readAsBytesSync())));
    if (doc is! Map) return null;
    return {
      for (final e in doc.entries)
        '${e.key}': [
          for (final row in e.value as List)
            [for (final cell in row as List) '$cell'],
        ],
    };
  } catch (_) {
    // Unreadable is the same as absent: nothing to compare against.
    return null;
  }
}

/// Keeps [grids] as what the Sheet said after a publish.
void writeSheetBaseline(
  String projectFile,
  Map<String, List<List<String>>> grids, {
  bool workbook = false,
}) {
  if (projectFile.trim().isEmpty) return;
  final file = File(onlineSheetBaselinePath(projectFile, workbook: workbook));
  final part = File('${file.path}.part');
  part.writeAsBytesSync(
    gzip.encode(utf8.encode(jsonEncode(grids))),
    flush: true,
  );
  part.renameSync(file.path);
}

List<String> _tidyRow(List<String> row) {
  var end = row.length;
  while (end > 0 && row[end - 1].trim().isEmpty) {
    end--;
  }
  return [for (final c in row.sublist(0, end)) c.trim()];
}

List<List<String>> _tidy(List<List<String>> rows) {
  final out = [for (final r in rows) _tidyRow(r)];
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out;
}

String _clip(String v, [int max = 70]) {
  final one = v.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length <= max ? one : '${one.substring(0, max)}...';
}

/// 0 -> A, 25 -> Z, 26 -> AA.
String _columnLetters(int index) {
  var n = index + 1;
  final out = StringBuffer();
  while (n > 0) {
    final r = (n - 1) % 26;
    out.write(String.fromCharCode(65 + r));
    n = (n - 1) ~/ 26;
  }
  return out.toString().split('').reversed.join();
}

bool _numeric(String v) =>
    double.tryParse(v.replaceAll(RegExp(r'[\$,% ]'), '')) != null;

/// What column [col] of row [row] is called: the nearest row above that reads
/// as headings (three or more words, one of them over this column), else the
/// column's letter.
String _columnName(List<List<String>> rows, int row, int col) {
  for (var r = row - 1; r >= 0; r--) {
    final cells = rows[r];
    if (col >= cells.length) continue;
    final here = cells[col];
    if (here.isEmpty || _numeric(here) || here.startsWith('=')) continue;
    final words =
        cells.where((c) => c.isNotEmpty && !_numeric(c) && !c.startsWith('='));
    if (words.length >= 3) return _clip(here, 30);
  }
  return 'column ${_columnLetters(col)}';
}

/// Two cells that say the same thing. A number is the same number however it
/// is written - 12.5 and 12.50 - since the Sheet hands numbers back its own
/// way.
bool _sameCell(String a, String b) {
  if (a == b) return true;
  final x = double.tryParse(a), y = double.tryParse(b);
  if (x == null || y == null) return false;
  // Relative: a program that re-saves the file writes 1234.5 back as
  // 1234.4999999999998 and means the same figure.
  final scale = x.abs() > 1 ? x.abs() : 1.0;
  return (x - y).abs() <= 1e-9 * scale;
}

/// Every difference between what the tabs said after the last publish
/// ([before]) and what they say now ([now]), tabs in [skip] left out.
///
/// Only tabs the app wrote are looked at: a tab somebody added by hand is
/// never written over, so there is nothing of theirs to lose.
List<OnlineChange> sheetEdits(
  Map<String, List<List<String>>> before,
  Map<String, List<List<String>>> now, {
  Set<String> skip = const {},
}) {
  final out = <OnlineChange>[];
  for (final tab in before.keys) {
    if (skip.contains(tab)) continue;
    final current = now[tab];
    if (current == null) {
      out.add((
        kind: kSheetEditKind,
        id: tab,
        name: tab,
        what: 'this tab was deleted or renamed in the Sheet',
      ));
      continue;
    }
    final a = _tidy(before[tab]!), b = _tidy(current);

    if (a.length == b.length) {
      // Same shape: each row is still the row it was, so say which cells.
      for (var r = 0; r < a.length; r++) {
        final was = a[r], is_ = b[r];
        final width = was.length > is_.length ? was.length : is_.length;
        final cells = <String>[];
        for (var c = 0; c < width; c++) {
          final x = c < was.length ? was[c] : '';
          final y = c < is_.length ? is_[c] : '';
          if (_sameCell(x, y)) continue;
          cells.add('${_columnName(a, r, c)}: '
              '${x.isEmpty ? '(blank)' : '"${_clip(x)}"'} -> '
              '${y.isEmpty ? '(blank)' : '"${_clip(y)}"'}');
        }
        if (cells.isEmpty) continue;
        final label = was.firstWhere((c) => c.isNotEmpty,
            orElse: () => is_.firstWhere((c) => c.isNotEmpty, orElse: () => ''));
        out.add((
          kind: kSheetEditKind,
          id: tab,
          name: '$tab, row ${r + 1}'
              '${label.isEmpty ? '' : ' (${_clip(label, 40)})'}',
          what: cells.join('; '),
        ));
      }
      continue;
    }

    // Rows were added or deleted, so position no longer says which row is
    // which. What is listed is the rows that are new and the rows that went.
    Map<String, int> counts(List<List<String>> rows) {
      final m = <String, int>{};
      for (final r in rows) {
        if (r.isEmpty) continue;
        final line = r.join(' | ');
        m[line] = (m[line] ?? 0) + 1;
      }
      return m;
    }

    final ca = counts(a), cb = counts(b);
    for (final e in cb.entries) {
      for (var i = ca[e.key] ?? 0; i < e.value; i++) {
        out.add((
          kind: kSheetEditKind,
          id: tab,
          name: tab,
          what: 'row added or changed to: ${_clip(e.key, 200)}',
        ));
      }
    }
    for (final e in ca.entries) {
      for (var i = cb[e.key] ?? 0; i < e.value; i++) {
        out.add((
          kind: kSheetEditKind,
          id: tab,
          name: tab,
          what: 'row removed or changed from: ${_clip(e.key, 200)}',
        ));
      }
    }
  }
  return out;
}

/// The changes an import acts on, as opposed to the ones it only lists.
List<OnlineChange> appliedChanges(List<OnlineChange> changes) => [
      for (final c in changes)
        if (c.kind != kSheetEditKind) c,
    ];

/// The changes found in tabs the app cannot read back - listed and kept in
/// the history, never applied.
List<OnlineChange> listedOnlyChanges(List<OnlineChange> changes) => [
      for (final c in changes)
        if (c.kind == kSheetEditKind) c,
    ];
