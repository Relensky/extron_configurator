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

/// [text] stripped to lowercase letters and digits: "BSS 103" and "BSS103" both
/// become "bss103", "PT-FW430U" and "PT FW430U" both become "ptfw430u".
String searchKey(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// True when [candidate] contains [query], ignoring case and every separator.
/// A query of nothing but punctuation reduces to '' and matches everything,
/// which is the same thing an empty query does.
bool searchMatches(String candidate, String query) =>
    searchKey(candidate).contains(searchKey(query));

/// The entries of [candidates] that match [query] under [searchMatches],
/// in their original order.
Iterable<String> searchFilter(Iterable<String> candidates, String query) =>
    candidates.where((c) => searchMatches(c, query));
