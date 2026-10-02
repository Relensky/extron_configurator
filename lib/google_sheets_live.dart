import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'google_sheets_export.dart';
import 'online_roundtrip.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  ONE GOOGLE SHEET, KEPT CURRENT
/// ============================================================================
///  The upload in google_sheets_export.dart makes a NEW Sheet every time, in
///  the Drive of whoever pressed the button. This writes the same Sheet every
///  time, cell by cell through the Sheets API, so one link stays current and
///  everybody on the job publishes to the same place.
///
///  The Sheet's id is kept on the project file, which is what makes it shared:
///  whoever opens the job publishes to the Sheet the job names. The person who
///  made it shares it in Google with the others as editors.
///
///  Only the tabs this app writes are touched. A tab somebody added by hand is
///  left alone, and so is a tab for a room since taken off the job.
///
///  The three sheets that are read back (online_roundtrip.dart) are read back
///  from here too, and a publish that would write over somebody's typing
///  stands down exactly as it does for the file in the sync folder.
/// ============================================================================

/// What a publish calls this destination in its list of what was written.
const String kOnlineSheetLabel = 'Google Sheet';

/// The sheets a publish reads back before it writes over them.
const List<String> kLiveReadBackSheets = [
  kMasterSheet,
  kEditableDeliveriesSheet,
  kEditablePosSheet,
];

/// How much JSON goes in one request. Google suggests staying near 2 MB.
const int kLiveBatchChars = 1500000;

/// Rows left under a table for somebody to type new lines into.
const int kLiveSpareRows = 50;

String liveSheetUrl(String id) =>
    'https://docs.google.com/spreadsheets/d/$id/edit';

/// The Sheet's id out of a pasted link, or [typed] itself when it is an id.
String liveSheetIdFrom(String typed) {
  final t = typed.trim();
  final m = RegExp(r'/d/([A-Za-z0-9_-]+)').firstMatch(t);
  return m != null ? m.group(1)! : t;
}

/// A fingerprint of what the read-back sheets say. Recorded after a publish
/// and compared before the next, it is what the file's timestamp is for the
/// copy in the sync folder: whether anybody has typed since.
String liveSheetStamp(Map<String, List<List<String>>> grids) {
  List<String> tidyRow(List<String> row) {
    var end = row.length;
    while (end > 0 && row[end - 1].trim().isEmpty) {
      end--;
    }
    return row.sublist(0, end);
  }

  final tidy = <String, List<List<String>>>{};
  for (final name in grids.keys.toList()..sort()) {
    final rows = [for (final row in grids[name]!) tidyRow(row)];
    while (rows.isNotEmpty && rows.last.isEmpty) {
      rows.removeLast();
    }
    tidy[name] = rows;
  }
  return sha256.convert(utf8.encode(jsonEncode(tidy))).toString();
}

// ---------------------------------------------------------------------------
//  A SHEET AS REQUESTS
// ---------------------------------------------------------------------------

Map<String, double> _rgb(String hex) {
  final v = int.tryParse(hex, radix: 16) ?? 0;
  return {
    'red': ((v >> 16) & 0xFF) / 255,
    'green': ((v >> 8) & 0xFF) / 255,
    'blue': (v & 0xFF) / 255,
  };
}

/// The same bands the .xlsx carries - see [XlsxRowStyle].
Map<String, dynamic> _rowFormat(int style, String accent) => switch (style) {
      XlsxRowStyle.bold => {
          'textFormat': {'bold': true},
        },
      XlsxRowStyle.title => {
          'backgroundColor': _rgb(XlsxTheme.titleFill(accent)),
          'textFormat': {
            'bold': true,
            'fontSize': 12,
            'foregroundColor': _rgb(XlsxTheme.titleInk(accent)),
          },
        },
      XlsxRowStyle.header => {
          'backgroundColor': _rgb(XlsxTheme.headerFill(accent)),
          'textFormat': {'bold': true},
        },
      XlsxRowStyle.zebra => {'backgroundColor': _rgb('EFEFEF')},
      _ => const {},
    };

/// One cell as the Sheets API takes it. [sheetIds] is every tab's id by name,
/// for a link to another tab.
Map<String, dynamic> liveCell(
  dynamic value,
  int style,
  String accent,
  Map<String, int> sheetIds,
) {
  var format = <String, dynamic>{..._rowFormat(style, accent)};
  Map<String, dynamic>? entered;

  Map<String, dynamic> number(num n) =>
      n.isFinite ? {'numberValue': n} : {'stringValue': '$n'};
  void money(String symbol) => format['numberFormat'] = {
        'type': 'CURRENCY',
        'pattern': '"$symbol"#,##0.00',
      };

  if (value == null) {
    // Blank, but still part of its row's band.
  } else if (value is XlsxLink) {
    final gid = sheetIds[value.sheet];
    final text = value.formula ?? '"${value.text.replaceAll('"', '""')}"';
    entered = gid != null
        ? {
            'formulaValue':
                '=HYPERLINK("#gid=$gid&range=${value.cell}",$text)',
          }
        : value.formula != null
            ? {'formulaValue': '=${value.formula}'}
            : {'stringValue': value.text};
  } else if (value is XlsxTint) {
    // Its own fill and ink, whatever band the row is in.
    format = {
      'backgroundColor': _rgb(value.fillHex),
      'textFormat': {
        'foregroundColor': _rgb(value.inkHex),
        if (value.bold) 'bold': true,
      },
    };
    entered = {'stringValue': value.text};
  } else if (value is XlsxMoney) {
    entered = number(value.value);
    money(value.symbol);
  } else if (value is XlsxFormula) {
    entered = {'formulaValue': '=${value.formula}'};
    money(value.cached.symbol);
  } else if (value is XlsxNumberFormula) {
    entered = {'formulaValue': '=${value.formula}'};
  } else if (value is XlsxTextFormula) {
    entered = {'formulaValue': '=${value.formula}'};
  } else if (value is num) {
    entered = number(value);
  } else {
    final text = value.toString();
    // Text, never a formula: a part called "=A1" stays a part called "=A1".
    if (text.isNotEmpty) entered = {'stringValue': text};
    final long = text.contains('\n') || text.length > kXlsxMaxColumnWidth;
    if (value is XlsxWrapped || (long && style != XlsxRowStyle.title)) {
      format['wrapStrategy'] = 'WRAP';
      format['verticalAlignment'] = 'TOP';
    }
  }

  return {
    'userEnteredValue': ?entered,
    if (format.isNotEmpty) 'userEnteredFormat': format,
  };
}

/// "A1:E1" as 0-based (firstCol, firstRow, lastCol, lastRow), or null.
(int, int, int, int)? _parseRange(String range) {
  final m = RegExp(r'^([A-Z]+)(\d+):([A-Z]+)(\d+)$')
      .firstMatch(range.toUpperCase());
  if (m == null) return null;
  int col(String letters) {
    var n = 0;
    for (final unit in letters.codeUnits) {
      n = n * 26 + (unit - 64);
    }
    return n - 1;
  }

  return (
    col(m.group(1)!),
    int.parse(m.group(2)!) - 1,
    col(m.group(3)!),
    int.parse(m.group(4)!) - 1,
  );
}

/// Column widths in pixels, by the rules the .xlsx is sized by: explicit
/// widths win, title rows, merged blocks and wrapped text size nothing.
Map<int, int> liveColumnPixels(XlsxSheet sheet) {
  final spanning = <(int, int)>{};
  for (final range in sheet.merges) {
    final m = _parseRange(range);
    if (m == null || m.$1 == m.$3) continue;
    for (var r = m.$2; r <= m.$4; r++) {
      for (var c = m.$1; c <= m.$3; c++) {
        spanning.add((r, c));
      }
    }
  }
  final chars = <int, double>{};
  for (var r = 0; r < sheet.rows.length; r++) {
    if (sheet.rowStyles[r] == XlsxRowStyle.title) continue;
    final cells = sheet.rows[r];
    final overflow = sheet.overflowRows.contains(r);
    for (var c = 0; c < cells.length; c++) {
      final cell = cells[c];
      if (cell == null || cell is XlsxWrapped) continue;
      if (spanning.contains((r, c))) continue;
      if (overflow &&
          c == cells.length - 1 &&
          cell is! num &&
          cell is! XlsxMoney) {
        continue;
      }
      for (final line in cell.toString().split('\n')) {
        final want = (line.length + 3)
            .clamp(kXlsxMinColumnWidth, kXlsxMaxColumnWidth)
            .toDouble();
        if (want > (chars[c] ?? 0)) chars[c] = want;
      }
    }
  }
  chars.addAll(sheet.columnWidths);
  return {for (final e in chars.entries) e.key: (e.value * 7 + 5).round()};
}

/// Everything that makes the tab [sheetId] read as [sheet]: cleared, then
/// written, merged and sized. [haveRows] and [haveColumns] are the tab's grid
/// now - it is grown to fit and never shrunk.
List<Map<String, dynamic>> liveSheetRequests(
  XlsxSheet sheet, {
  required int sheetId,
  required Map<String, int> sheetIds,
  int haveRows = 0,
  int haveColumns = 0,
  String? accentHex,
}) {
  final accent = accentHex ?? XlsxTheme.accentHex;
  final merges = [
    for (final m in sheet.merges)
      if (_parseRange(m) != null) _parseRange(m)!,
  ];
  final width = sheet.rows.fold<int>(0, (w, r) => math.max(w, r.length));
  // A freeze that cuts through a merged block is refused, so it is dropped.
  final freeze = merges.any(
    (m) => m.$1 < sheet.freezeColumns && m.$3 >= sheet.freezeColumns,
  )
      ? 0
      : sheet.freezeColumns;

  return [
    {
      'updateCells': {
        'range': {'sheetId': sheetId},
        'fields': '*',
      },
    },
    {
      'unmergeCells': {
        'range': {'sheetId': sheetId},
      },
    },
    {
      'updateSheetProperties': {
        'properties': {
          'sheetId': sheetId,
          'gridProperties': {
            'rowCount':
                math.max(haveRows, sheet.rows.length + kLiveSpareRows),
            'columnCount':
                math.max(haveColumns, math.max(width, freeze) + 1),
            'frozenColumnCount': freeze,
          },
        },
        'fields': 'gridProperties(rowCount,columnCount,frozenColumnCount)',
      },
    },
    {
      'updateCells': {
        'start': {'sheetId': sheetId, 'rowIndex': 0, 'columnIndex': 0},
        'rows': [
          for (var r = 0; r < sheet.rows.length; r++)
            {
              'values': [
                for (final value in sheet.rows[r])
                  liveCell(
                    value,
                    sheet.rowStyles[r] ?? XlsxRowStyle.normal,
                    accent,
                    sheetIds,
                  ),
              ],
            },
        ],
        'fields': 'userEnteredValue,userEnteredFormat',
      },
    },
    for (final m in merges)
      {
        'mergeCells': {
          'range': {
            'sheetId': sheetId,
            'startColumnIndex': m.$1,
            'endColumnIndex': m.$3 + 1,
            'startRowIndex': m.$2,
            'endRowIndex': m.$4 + 1,
          },
          'mergeType': 'MERGE_ALL',
        },
      },
    for (final e in liveColumnPixels(sheet).entries)
      {
        'updateDimensionProperties': {
          'range': {
            'sheetId': sheetId,
            'dimension': 'COLUMNS',
            'startIndex': e.key,
            'endIndex': e.key + 1,
          },
          'properties': {'pixelSize': e.value},
          'fields': 'pixelSize',
        },
      },
  ];
}

// ---------------------------------------------------------------------------
//  TALKING TO GOOGLE
// ---------------------------------------------------------------------------

/// One call to the Sheets API: the decoded answer, or a
/// [GoogleSheetsException]. Swappable for tests.
typedef LiveSheetTransport = Future<Map<String, dynamic>> Function(
  String method,
  Uri uri,
  Object? body,
);

/// One tab as the Sheet reports it.
typedef LiveTab = ({String title, int id, int rows, int columns});

class GoogleLiveSheet {
  final LiveSheetTransport send;

  GoogleLiveSheet(this.send);

  /// Signed in through [auth]. [interactive] off never opens a browser - a
  /// save must not - and fails instead when nobody has signed in yet.
  factory GoogleLiveSheet.signedIn(
    GoogleSheetsUploader auth, {
    bool interactive = true,
  }) {
    String? token;
    return GoogleLiveSheet((method, uri, body) async {
      token ??= await auth.accessToken(interactive: interactive);
      // Over the per-minute quota, or Google having a moment: wait and retry.
      for (var attempt = 0;; attempt++) {
        final client = auth.httpClient();
        try {
          final req = await client.openUrl(method, uri);
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
          if (body != null) {
            final bytes = utf8.encode(jsonEncode(body));
            req.headers.contentType =
                ContentType('application', 'json', charset: 'utf-8');
            req.contentLength = bytes.length;
            req.add(bytes);
          }
          final res = await req.close();
          final text = await res.transform(utf8.decoder).join();
          if (res.statusCode >= 200 && res.statusCode < 300) {
            final json = text.isEmpty ? const {} : jsonDecode(text);
            return json is Map
                ? Map<String, dynamic>.from(json)
                : <String, dynamic>{};
          }
          final busy = res.statusCode == 429 || res.statusCode >= 500;
          if (busy && attempt < 3) {
            await Future<void>.delayed(Duration(seconds: 2 << attempt));
            continue;
          }
          throw GoogleSheetsException(_refusal(res.statusCode, text));
        } finally {
          client.close();
        }
      }
    });
  }

  static String _refusal(int status, String body) {
    var said = body.length > 200 ? '${body.substring(0, 200)}…' : body;
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is Map) {
        said = '${(j['error'] as Map)['message'] ?? said}';
      }
    } catch (_) {}
    return switch (status) {
      403 => 'Google refused ($said) - the Sheet has to be shared with you as '
          'an editor, and the Google Sheets API enabled for the client',
      404 => 'that Sheet was not found - check the link',
      429 => 'Google is limiting requests - try again in a minute',
      _ => 'Google Sheets answered $status: $said',
    };
  }

  static const String _api = 'https://sheets.googleapis.com/v4/spreadsheets';

  /// The Sheet's tabs.
  Future<List<LiveTab>> tabs(String id) async {
    final json = await send(
      'GET',
      Uri.parse('$_api/$id?fields=sheets.properties'),
      null,
    );
    return [
      for (final s in (json['sheets'] as List? ?? const []))
        if (s is Map && s['properties'] is Map)
          (
            title: '${s['properties']['title'] ?? ''}',
            id: (s['properties']['sheetId'] as num?)?.toInt() ?? 0,
            rows: (s['properties']['gridProperties']?['rowCount'] as num?)
                    ?.toInt() ??
                0,
            columns:
                (s['properties']['gridProperties']?['columnCount'] as num?)
                        ?.toInt() ??
                    0,
          ),
    ];
  }

  /// Makes a new Sheet called [title] and returns its id. [firstTab] names the
  /// one tab a new Sheet always has, so no empty "Sheet1" is left in it.
  Future<String> create(String title, {required String firstTab}) async {
    final json = await send('POST', Uri.parse(_api), {
      'properties': {'title': title},
      'sheets': [
        {
          'properties': {'title': firstTab},
        },
      ],
    });
    final id = json['spreadsheetId']?.toString() ?? '';
    if (id.isEmpty) {
      throw const GoogleSheetsException('Google did not return a Sheet.');
    }
    return id;
  }

  /// Writes [sheets] into the Sheet, a tab each, adding the tabs it lacks.
  Future<void> write(
    String id,
    List<XlsxSheet> sheets, {
    String? accentHex,
  }) async {
    final have = {for (final t in await tabs(id)) t.title: t};
    final ids = {for (final t in have.values) t.title: t.id};
    final used = ids.values.toSet();
    var next = 1;

    var requests = <Map<String, dynamic>>[];
    var size = 0;
    Future<void> flush() async {
      if (requests.isEmpty) return;
      await send('POST', Uri.parse('$_api/$id:batchUpdate'), {
        'requests': requests,
      });
      requests = [];
      size = 0;
    }

    // Every tab exists before any cell is written, so a link or a formula
    // can name a tab that comes later in the book.
    for (final sheet in sheets) {
      if (ids.containsKey(sheet.name)) continue;
      while (used.contains(next)) {
        next++;
      }
      used.add(next);
      ids[sheet.name] = next;
      requests.add({
        'addSheet': {
          'properties': {'sheetId': next, 'title': sheet.name},
        },
      });
    }

    for (final sheet in sheets) {
      final tab = have[sheet.name];
      final batch = liveSheetRequests(
        sheet,
        sheetId: ids[sheet.name]!,
        sheetIds: ids,
        haveRows: tab?.rows ?? 0,
        haveColumns: tab?.columns ?? 0,
        accentHex: accentHex,
      );
      final chars = jsonEncode(batch).length;
      if (size > 0 && size + chars > kLiveBatchChars) await flush();
      requests.addAll(batch);
      size += chars;
    }
    await flush();
  }

  /// The tabs in [names] that the Sheet has, as rows of the text they show.
  ///
  /// [entered] asks for what was put IN each cell instead - a formula as its
  /// formula, a number unformatted. That is what a cell-by-cell comparison is
  /// made on (online_sheet_merge.dart): it does not move when a formula
  /// recalculates, only when somebody types.
  Future<Map<String, List<List<String>>>> read(
    String id,
    List<String> names, {
    bool entered = false,
  }) async {
    final have = {for (final t in await tabs(id)) t.title};
    final want = [
      for (final n in names)
        if (have.contains(n)) n,
    ];
    if (want.isEmpty) return {};
    final json = await send(
      'GET',
      Uri.parse('$_api/$id/values:batchGet').replace(
        queryParameters: {
          'ranges': [for (final n in want) "'${n.replaceAll("'", "''")}'"],
          'valueRenderOption': entered ? 'FORMULA' : 'FORMATTED_VALUE',
        },
      ),
      null,
    );
    final ranges = json['valueRanges'] as List? ?? const [];
    return {
      for (var i = 0; i < want.length; i++)
        want[i]: [
          if (i < ranges.length && ranges[i] is Map)
            for (final row in (ranges[i]['values'] as List? ?? const []))
              [
                if (row is List)
                  for (final cell in row) '${cell ?? ''}',
              ],
        ],
    };
  }
}
