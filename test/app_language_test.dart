import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ============================================================================
///  HOW THE APP TALKS
/// ============================================================================
///  House style, enforced on the text that reaches a person rather than left to
///  be spotted in review. Three rules, each of which was a sweep across sixty
///  files the first time and is one failing test from here on:
///
///    * NO EM DASHES. They do not survive being pasted into a work order, a
///      ticket or a mail client that is not set to UTF-8, and the app's text is
///      pasted constantly - the briefing, the reports and the clipboard copies
///      exist for exactly that.
///    * THE PEOPLE ON THE OTHER SIDE ARE STAKEHOLDERS, not customers. This
///      shop's work is for the university: the department, the dean and
///      facilities. Nobody here is being sold to.
///    * PHYSICAL WORK IS SOMEBODY ELSE'S. The app does not tell anyone to drill
///      or to demolish anything. That work is a contractor's, arranged through
///      facilities, and an example that reads as an instruction is one that
///      gets copied onto a drawing as though it were one.
///
///  ONLY STRING LITERALS ARE CHECKED, not comments. A comment is written for
///  whoever is reading the source and is not part of what the app says; the
///  prose style in this codebase leans on the em dash heavily and there is no
///  reason for it not to.
/// ============================================================================
void main() {
  /// Every string literal in [source], skipping comments.
  ///
  /// Not a Dart parser and it does not have to be: it needs to tell a quote
  /// that opens a string from one inside a comment, and an escaped quote from
  /// a closing one. Interpolations are treated as part of the literal that
  /// holds them, which is right for a text check - the words are what is being
  /// read, and `${a.b}` has none in it.
  List<String> stringLiterals(String source) {
    final out = <String>[];
    var i = 0;
    final n = source.length;

    while (i < n) {
      final c = source[i];

      if (c == '/' && i + 1 < n && source[i + 1] == '/') {
        final end = source.indexOf('\n', i);
        i = end < 0 ? n : end + 1;
        continue;
      }
      if (c == '/' && i + 1 < n && source[i + 1] == '*') {
        // Dart nests block comments.
        var depth = 1;
        i += 2;
        while (i < n && depth > 0) {
          if (source.startsWith('/*', i)) {
            depth++;
            i += 2;
          } else if (source.startsWith('*/', i)) {
            depth--;
            i += 2;
          } else {
            i++;
          }
        }
        continue;
      }

      final raw = c == 'r' && i + 1 < n && (source[i + 1] == "'" || source[i + 1] == '"');
      if (c == "'" || c == '"' || raw) {
        var j = raw ? i + 1 : i;
        final quote = source[j];
        final triple = source.startsWith(quote * 3, j);
        final delim = triple ? quote * 3 : quote;
        j += delim.length;
        final body = j;
        var closed = false;
        while (j < n) {
          if (!raw && source[j] == r'\') {
            j += 2;
            continue;
          }
          // An unterminated single-quoted string is a lexer disagreement, not
          // a literal. Bail rather than swallowing the rest of the file.
          if (!triple && source[j] == '\n') break;
          if (source.startsWith(delim, j)) {
            out.add(source.substring(body, j));
            j += delim.length;
            closed = true;
            break;
          }
          j++;
        }
        i = closed ? j : i + 1;
        continue;
      }
      i++;
    }
    return out;
  }

  List<File> dartFiles(String root) => [
    for (final e in Directory(root).listSync(recursive: true))
      if (e is File && e.path.endsWith('.dart')) e,
  ];

  /// Every offending literal, as `file: the text`, so a failure names what to
  /// fix rather than only how many there are.
  List<String> offenders(bool Function(String) bad) => [
    for (final file in dartFiles('lib'))
      for (final literal in stringLiterals(file.readAsStringSync()))
        if (bad(literal))
          '${file.uri.pathSegments.last}: '
              '${literal.trim().replaceAll('\n', ' ')}',
  ];

  test('the scanner tells a string from a comment', () {
    // The check is only worth as much as this is.
    const source = '''
// a comment with 'quotes' in it
/* and a /* nested */ block one */
const a = 'plain';
const b = "double";
const c = r'raw \\n';
const d = 'escaped \\' quote';
const e = 'with \${interpolation.here}';
''';
    expect(stringLiterals(source), [
      'plain',
      'double',
      r'raw \n',
      r"escaped \' quote",
      r'with ${interpolation.here}',
    ]);
  });

  test('nothing the app says uses an em dash', () {
    // They do not survive a paste into a work order, and this app's text is
    // pasted constantly.
    final found = offenders((s) => s.contains('—'));
    expect(found, isEmpty, reason: 'em dash in app text:\n${found.join('\n')}');
  });

  test('nor an en dash, including in a range', () {
    // The same problem in a narrower place: a price range and a span of years
    // are where one gets typed without anybody thinking of it as punctuation.
    final found = offenders((s) => s.contains('–'));
    expect(found, isEmpty, reason: 'en dash in app text:\n${found.join('\n')}');
  });

  test('the app calls them stakeholders, not customers', () {
    final found = offenders((s) => s.toLowerCase().contains('customer'));
    expect(found, isEmpty, reason: '"customer" in app text:\n${found.join('\n')}');
  });

  test('the app never tells anybody to drill or demolish', () {
    // Physical work is a contractor's, arranged through facilities. The words
    // may appear in a comment explaining that; they may not appear in
    // something the app puts on screen.
    final found = offenders((s) {
      final text = s.toLowerCase();
      return text.contains('drill') || text.contains('demolition');
    });
    expect(found, isEmpty, reason: 'work we do not do:\n${found.join('\n')}');
  });

  group('the data files shipped with the app', () {
    // ui_schema.json is the help text behind every field on the config tabs,
    // av_devices.json is the catalog, labor_rates.json is the rate card. All
    // three are read on screen, so they are app text as much as any literal.
    //
    // THE PROSE ONLY, not the whole file. A few values in these documents are
    // IDENTIFIERS rather than sentences, and one of them legitimately holds a
    // dash: the catalog carries a 9-12" extension column whose model name is
    // spelled with an en dash, and rooms already drawn on disk point at that
    // exact string. Rewriting it to tidy the punctuation would orphan them.
    const identifierKeys = {'id', 'value', 'model', 'partNumber', 'key'};

    /// Every string in [node] that is something a person READS, with the key
    /// it was filed under, so a failure can name it.
    List<String> prose(Object? node, [String key = '']) {
      if (node is Map) {
        return [
          for (final entry in node.entries)
            ...prose(entry.value, entry.key.toString()),
        ];
      }
      if (node is List) {
        return [for (final item in node) ...prose(item, key)];
      }
      if (node is String && !identifierKeys.contains(key)) {
        return ['$key: $node'];
      }
      return const [];
    }

    for (final name in const [
      'ui_schema.json',
      'av_devices.json',
      'labor_rates.json',
      'base_costs.json',
    ]) {
      test('$name is written the same way', () {
        final file = File(name);
        if (!file.existsSync()) return;

        final text = file.readAsStringSync();
        // Still valid JSON after the sweep that took the dashes out.
        late final Object? doc;
        expect(() => doc = jsonDecode(text), returnsNormally);

        for (final line in prose(doc)) {
          expect(line.contains('\u2014'), isFalse,
              reason: 'em dash in $name - $line');
          expect(line.contains('\u2013'), isFalse,
              reason: 'en dash in $name - $line');
          expect(line.toLowerCase().contains('customer'), isFalse,
              reason: '"customer" in $name - $line');
        }
      });
    }
  });
}
