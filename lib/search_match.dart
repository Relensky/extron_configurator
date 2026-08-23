/// ============================================================================
///  SEARCH MATCHING
/// ============================================================================
///  One rule for every search box and autocomplete in the app, so a field never
///  hinges on the user reproducing punctuation exactly.
///
///  AV naming is inconsistent by nature: the same room is written "BSS103" or
///  "BSS 103", a model is "PT-FW430U" or "PT FW430U", a module is
///  "extr_scaler_IN1606_IN1608_Series", a processor line carries an IP with
///  dots. Whoever is searching knows the name, not the separators — so both the
///  query and the candidate are reduced to letters and digits before comparing.
///
///  THIS IS A HOT PATH. The catalog search box runs every entry of a
///  1600-model catalog through [searchMatches] on every keystroke, so what
///  looks like a one-line string tidy is really sixteen hundred of them
///  between one character and the next. Everything below is written for that:
///  the query is reduced ONCE per search rather than once per candidate (see
///  [SearchQuery]), and [searchKey] walks code units instead of building a
///  lowercase copy and running a regex over it.
/// ============================================================================
library;

/// The separator strip, kept for the non-ASCII fallback in [searchKey] and for
/// [searchTerms]. Built once: `RegExp(...)` in an expression compiles a fresh
/// pattern on every call, which at catalog scale is the bulk of the work.
final RegExp _nonAlphanumeric = RegExp(r'[^a-z0-9]');
final RegExp _whitespace = RegExp(r'\s+');

const int _$0 = 0x30; // '0'
const int _$9 = 0x39; // '9'
const int _$a = 0x61; // 'a'
const int _$z = 0x7a; // 'z'
const int _$A = 0x41; // 'A'
const int _$Z = 0x5a; // 'Z'
const int _asciiMax = 0x7f;

/// [text] stripped to lowercase letters and digits: "BSS 103" and "BSS103" both
/// become "bss103", "PT-FW430U" and "PT FW430U" both become "ptfw430u".
///
/// Plain ASCII — which is every model name, part number and room name in
/// practice — is folded in a single pass over the code units, with no
/// lowercase copy and no regex. Anything carrying a character above 0x7f falls
/// back to the original `toLowerCase()` + strip, because Unicode lowercasing is
/// not a per-character operation and a hand-rolled fold would quietly disagree
/// with it (U+0130 lowercases to "i" plus a combining mark, and that "i" is a
/// letter this is supposed to keep).
String searchKey(String text) {
  final length = text.length;
  final units = <int>[];
  for (var i = 0; i < length; i++) {
    final c = text.codeUnitAt(i);
    if (c > _asciiMax) {
      return text.toLowerCase().replaceAll(_nonAlphanumeric, '');
    }
    if ((c >= _$a && c <= _$z) || (c >= _$0 && c <= _$9)) {
      units.add(c);
    } else if (c >= _$A && c <= _$Z) {
      units.add(c + 0x20);
    }
  }
  return String.fromCharCodes(units);
}

/// The words of [query], each reduced by [searchKey], with the empties gone.
///
/// Split on WHITESPACE only. A dash inside a word is a separator people get
/// wrong ("PT-FW430U" / "PT FW430U"), and [searchKey] already forgives it; a
/// space between words is the user naming two different things about the same
/// item, and that is what [searchMatches] uses this for.
List<String> searchTerms(String query) => [
  for (final word in query.split(_whitespace))
    if (searchKey(word) case final key when key.isNotEmpty) key,
];

/// A query reduced to the terms it asks for, ONCE, so a search over many
/// candidates does not re-split and re-normalize the same handful of
/// characters for every one of them.
///
/// This is the difference between reducing the query once per keystroke and
/// reducing it sixteen hundred times per keystroke; [searchMatches] keeps
/// working on a raw string for the call sites that test a single candidate.
class SearchQuery {
  /// Every word of the query, reduced by [searchKey]. Empty for a query that
  /// asked for nothing, which matches everything.
  final List<String> terms;

  SearchQuery(String query) : terms = searchTerms(query);

  /// True when nothing was actually asked for — no words, or nothing but
  /// punctuation and space.
  bool get isEmpty => terms.isEmpty;

  /// True when [candidate] contains every term. [candidate] is raw text; use
  /// [matchesKey] when the reduced form is already to hand.
  bool matches(String candidate) =>
      terms.isEmpty || matchesKey(searchKey(candidate));

  /// [matches] against a candidate that has ALREADY been through [searchKey]
  /// — what a caller holding a precomputed haystack wants.
  bool matchesKey(String haystack) {
    for (var i = 0; i < terms.length; i++) {
      if (!haystack.contains(terms[i])) return false;
    }
    return true;
  }
}

/// True when [candidate] contains EVERY word of [query], ignoring case and
/// every separator. A query of nothing but punctuation and space reduces to no
/// words at all and matches everything, which is what an empty query does.
///
/// Every word, anywhere, in any order — because the thing being searched is
/// spread across several fields that the person searching does not think of as
/// separate. "Epson PowerLite" is a maker and a product line, and nothing in
/// the catalog holds those two next to each other in that order: the model
/// says "PowerLite L630U" and the manufacturer column says "Epson". Squashing
/// the whole query into one token — which is what this did — asks for
/// "epsonpowerlite" as a single run of characters and finds nothing, on the
/// most natural way there is to search for that projector.
///
/// Testing MANY candidates against one query? Build a [SearchQuery] once and
/// ask it instead — this reduces the query again on every call.
bool searchMatches(String candidate, String query) =>
    SearchQuery(query).matches(candidate);

/// The entries of [candidates] that match [query] under [searchMatches],
/// in their original order.
Iterable<String> searchFilter(Iterable<String> candidates, String query) {
  final q = SearchQuery(query);
  return candidates.where(q.matches);
}
