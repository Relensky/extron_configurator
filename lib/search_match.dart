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
/// ============================================================================
library;

/// [text] stripped to lowercase letters and digits: "BSS 103" and "BSS103" both
/// become "bss103", "PT-FW430U" and "PT FW430U" both become "ptfw430u".
String searchKey(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// The words of [query], each reduced by [searchKey], with the empties gone.
///
/// Split on WHITESPACE only. A dash inside a word is a separator people get
/// wrong ("PT-FW430U" / "PT FW430U"), and [searchKey] already forgives it; a
/// space between words is the user naming two different things about the same
/// item, and that is what [searchMatches] uses this for.
List<String> searchTerms(String query) => [
  for (final word in query.split(RegExp(r'\s+')))
    if (searchKey(word).isNotEmpty) searchKey(word),
];

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
bool searchMatches(String candidate, String query) {
  final terms = searchTerms(query);
  if (terms.isEmpty) return true;
  final haystack = searchKey(candidate);
  for (final term in terms) {
    if (!haystack.contains(term)) return false;
  }
  return true;
}

/// The entries of [candidates] that match [query] under [searchMatches],
/// in their original order.
Iterable<String> searchFilter(Iterable<String> candidates, String query) =>
    candidates.where((c) => searchMatches(c, query));
