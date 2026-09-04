import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// ============================================================================
///  THE PATH ROWS ARE ONE ROW, REPEATED
/// ============================================================================
///  Every file-path row on the settings tab is the same row: a field that
///  stretches and a button that acts on it. The button used to be exactly as
///  wide as its own label, so 'Reload Rules' was narrower than 'Reload
///  Catalog', the field beside it was correspondingly longer, and five rows
///  that are the same row ended in five different places down the page.
///
///  Held here: one width for the button, which means one right-hand edge for
///  the fields.
/// ============================================================================
void main() {
  /// Every path row on the tab, in the order it prints them: the words on the
  /// button, and the setting the field beside it writes.
  const rows = <(String, String)>[
    ('Re-read Modules', 'modulesPath'),
    ('Load Template', 'templateFilePath'),
    ('Reload Schema', 'uiSchemaPath'),
    ('Reload Catalog', 'avDevicesFilePath'),
    ('Reload Rules', 'flowRulesFilePath'),
    ('Edit Locations', 'deliveryLocationsFilePath'),
    ('Edit Vendors', 'vendorListFilePath'),
    ('Reload Key Map', 'keyMapPath'),
  ];

  /// Puts the tab up under one of the app's real themes.
  ///
  /// THE THEME IS PART OF THE QUESTION. The button is a FIXED width now, so a
  /// theme that pads or sizes its buttons differently is a theme where the
  /// label could run out of the box - and this app ships two of them.
  Future<void> pumpSettings(
    WidgetTester tester, {
    String style = 'classic',
    bool dark = false,
  }) async {
    // TALL ENOUGH TO HOLD THE WHOLE TAB. The list builds lazily, so a
    // measurement of a row still below the fold is a measurement of a widget
    // that does not exist - and these are questions about seven rows at once.
    tester.view.physicalSize = const Size(1600, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final provider = AppStateProvider(autoLoadSettings: false);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(
          theme: RoomConfigApp.themeFor(style, dark, '1976D2', 'F0A500', ''),
          home: const Scaffold(body: AppSettingsView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The button on the end of a path row, by the words on it.
  Finder action(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byType(ElevatedButton),
  );

  /// The path field a row is about, by the setting it writes.
  Finder field(String setting) => find.byWidgetPredicate((w) {
    final key = w.key;
    return w is TextFormField &&
        key is ValueKey<String> &&
        key.value.startsWith('${setting}_');
  });

  /// Every path row on the tab, measured.
  List<({String label, Size button, double fieldRight})> measure(
    WidgetTester tester,
  ) => [
    for (final (label, setting) in rows)
      (
        label: label,
        button: tester.getSize(action(label)),
        fieldRight: tester.getBottomRight(field(setting)).dx,
      ),
  ];

  testWidgets('every path row ends with a button of the same size', (
    tester,
  ) async {
    await pumpSettings(tester);
    final measured = measure(tester);

    // Not "close enough": the same box, so a column of them reads as one
    // control repeated rather than as seven different ones.
    final first = measured.first;
    for (final row in measured) {
      expect(
        row.button,
        first.button,
        reason: '${row.label} is the same size as ${first.label}',
      );
    }
  });

  testWidgets('which puts every path field on one right-hand edge', (
    tester,
  ) async {
    await pumpSettings(tester);
    final measured = measure(tester);

    final first = measured.first;
    for (final row in measured) {
      expect(
        row.fieldRight,
        moreOrLessEquals(first.fieldRight, epsilon: 0.5),
        reason: '${row.label} ends where every other path field ends',
      );
    }
  });

  // A FIXED WIDTH AND A LABEL THAT DOES NOT FIT is an overflow stripe, not a
  // tidy column - so both of the app's themes are asked, because Auris sizes
  // its type its own way. One test each: switching theme under a live tab is
  // a theme lerp, which is a different thing to be testing.
  for (final (style, dark) in [('classic', false), ('auris', true)]) {
    testWidgets('the labels still fit the box in $style', (tester) async {
      await pumpSettings(tester, style: style, dark: dark);
      final measured = measure(tester);
      for (final row in measured) {
        expect(row.button, measured.first.button, reason: row.label);
      }
      expect(tester.takeException(), isNull, reason: 'nothing overflowed');
    });
  }

  testWidgets('the AV flow rules row is one of them', (tester) async {
    // The row this was reported against: its button is the size of the
    // catalog row's above it, and its field the same length.
    await pumpSettings(tester);
    final measured = measure(tester);
    final rules = measured.firstWhere((r) => r.label == 'Reload Rules');
    final catalog = measured.firstWhere((r) => r.label == 'Reload Catalog');

    expect(rules.button, catalog.button);
    expect(
      rules.fieldRight,
      moreOrLessEquals(catalog.fieldRight, epsilon: 0.5),
    );
  });
}
