import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/base_costs.dart';
import 'package:extron_configurator/device_editor_view.dart';

/// ONE VOCABULARY, OR THE APP UNDERSTANDS NONE OF IT.
///
/// A category is free text and always will be. What that got the shipped
/// catalog was thirty-one words for eighteen kinds of box - 'Fox Systems',
/// 'XTP Systems', 'Scalers Switchers', 'Audio', 'DA', 'Matrix' - which are
/// aisles of a manufacturer's web shop filed as though they described the
/// product.
///
/// The cost of that is invisible and real: the app maps a room's config
/// section onto a category to price it and to group it, and a part filed under
/// a word nothing maps to prices at nothing, silently, with a perfectly
/// sensible-looking entry in the column.
///
/// So: the pickers offer the words the app tracks, the tracked list agrees
/// with what actually does the tracking, and there is one screen that refiles
/// a whole family in one go. Nothing here closes the set - a typed category
/// still works, and a site with a product this list has no word for should
/// invent one.
void main() {
  // -------------------------------------------------------------------------
  //  THE LIST IS THE ONE THAT DOES THE WORK
  // -------------------------------------------------------------------------
  //  These are the tests that would catch the list drifting away from the
  //  thing it claims to describe, which is the only way this whole idea fails
  //  quietly.

  group('the tracked categories are the ones that track', () {
    test('every config section maps onto one of them', () {
      // categoryForConfigKey is the actual mapping from a room's own
      // SWITCHERDEVICE_1 block to a word. A word it can produce that the
      // pickers do not offer is a category the app understands and nobody can
      // choose.
      const sections = [
        'SWITCHERDEVICE_1',
        'CAMERADEVICE_1',
        'DSPDEVICE_1',
        'AMPDEVICE_1',
        'PROJECTORDEVICE_1',
        'DISPLAYDEVICE_1',
        'MONITORDEVICE_1',
        'SCREENDEVICE_1',
        'USBDEVICE_1',
        'MEDIAPORTDEVICE_1',
        'WIRELESSDEVICE_1',
        'RECORDERDEVICE_1',
        'STREAMDEVICE_1',
        'CONTROLDEVICE_1',
        'TOUCHDEVICE_1',
        'PANELDEVICE_1',
        'POWERDEVICE_1',
        'SWITCHDEVICE_1',
        'MICDEVICE_1',
        'SPEAKERDEVICE_1',
      ];
      for (final key in sections) {
        final category = categoryForConfigKey(key);
        expect(category, isNotEmpty, reason: '$key maps to nothing');
        expect(
          kTrackedCategories,
          contains(category),
          reason: '$key maps to "$category", which no picker offers',
        );
      }
    });

    test('every base-cost category is one of them', () {
      // The other half of the same contract: the base card prices by category,
      // so a category it prices that the catalog cannot be filed under is a
      // price nothing will ever match.
      for (final cost in BaseCostBook.defaults) {
        expect(
          kTrackedCategories,
          contains(cost.category),
          reason: '"${cost.category}" is priced and cannot be chosen',
        );
      }
    });

    test('and the app-behavior ones are offered alongside them', () {
      // A picker that hides "Consumable" until a consumable exists is a picker
      // you cannot create the first consumable with.
      expect(kWellKnownCategories, containsAll(kTrackedCategories));
      expect(kWellKnownCategories, contains(kCategoryCable));
      expect(kWellKnownCategories, contains(kCategoryConsumable));
      expect(kWellKnownCategories, contains(kCategoryMisc));
      expect(kWellKnownCategories, contains('Vent plate'));
    });

    test('isTrackedCategory ignores case and spacing, like a person', () {
      expect(isTrackedCategory('Switcher'), isTrue);
      expect(isTrackedCategory('  switcher '), isTrue);
      expect(isTrackedCategory('Fox Systems'), isFalse);
      expect(isTrackedCategory(''), isFalse);
    });
  });

  group('the app suggests only where it can be sure', () {
    test('a family that is one kind of box gets a suggestion', () {
      expect(catalogCategorySuggestion('Matrix'), 'Switcher');
      expect(catalogCategorySuggestion('matrix'), 'Switcher');
      expect(catalogCategorySuggestion('Flat panel'), 'Display');
      expect(catalogCategorySuggestion('Cables'), kCategoryCable);
    });

    test('a family that holds four kinds of box gets none', () {
      // SILENCE IS AN ANSWER. 'Audio' holds DSPs, amplifiers, microphones and
      // loudspeakers, and a guess there retags a $90 mic as a $4,000
      // processor with nothing on screen to say so.
      for (final ambiguous in [
        'Audio',
        'Control Systems',
        'DTP Systems',
        'XTP Systems',
        'Fox Systems',
        'Architectural',
        'Collaboration Systems',
      ]) {
        expect(
          catalogCategorySuggestion(ambiguous),
          isEmpty,
          reason: '$ambiguous holds more than one kind of product',
        );
      }
    });

    test('every suggestion points at a category the app tracks', () {
      for (final target in kCatalogCategorySuggestions.values) {
        expect(
          kWellKnownCategories,
          contains(target),
          reason: '"$target" is suggested and is not itself a known category',
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  //  REFILING A WHOLE FAMILY
  // -------------------------------------------------------------------------

  AvDeviceLibrary messyCatalog() => AvDeviceLibrary.empty()
    ..upsert(
      const AvDeviceTemplate(
        model: 'DTP CrossPoint 108',
        manufacturer: 'Extron',
        category: 'Matrix',
        ports: [],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(
        model: 'DTP CrossPoint 84',
        manufacturer: 'Extron',
        category: 'Matrix',
        ports: [],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(
        model: 'MLC 104',
        manufacturer: 'Extron',
        category: 'Control Systems',
        ports: [],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(
        model: 'PowerLite L610U',
        manufacturer: 'Epson',
        category: 'Projector',
        ports: [],
      ),
    );

  group('the catalog is tidied a family at a time', () {
    test('retagging moves every entry under the word, and says how many', () {
      final library = messyCatalog();
      final moved = library.retagCategories({'Matrix': 'Switcher'});

      expect(moved, 2, reason: 'both matrix entries, and nothing else');
      for (final entry in library.all) {
        expect(entry.category, isNot('Matrix'));
      }
      expect(
        library.all.where((e) => e.category == 'Switcher').length,
        2,
      );
      // Untouched families are untouched.
      expect(
        library.all.where((e) => e.category == 'Control Systems').length,
        1,
      );
    });

    test('it matches the way a person reads a category', () {
      final library = messyCatalog();
      expect(library.retagCategories({'  matrix ': 'Switcher'}), 2);
    });

    test('a no-op mapping is not an edit', () {
      final library = messyCatalog();
      expect(library.retagCategories({'Matrix': 'Matrix'}), 0);
      expect(library.retagCategories({'Matrix': '   '}), 0);
      expect(library.retagCategories({}), 0);
      expect(library.retagCategories({'Nothing here': 'Switcher'}), 0);
    });

    test('what it moved is marked as this site\'s own entry', () {
      // The tidy-up is a decision about this site's catalog, and it belongs in
      // the file this site saves rather than being lost on the next build.
      final library = messyCatalog();
      library.retagCategories({'Matrix': 'Switcher'});
      for (final entry in library.all.where((e) => e.category == 'Switcher')) {
        expect(entry.custom, isTrue);
      }
    });

    test('the counts and the examples are what the screen is read from', () {
      final library = messyCatalog();
      final counts = library.categoryCounts;

      // Most-used first: 'Matrix' with two entries and 'Projector' with one
      // are the same kind of mistake and nothing like the same amount of it.
      expect(counts.first.category, 'Matrix');
      expect(counts.first.count, 2);
      // Only what is actually there - a category nothing is filed under has
      // nothing to retag.
      expect(counts.map((c) => c.category), isNot(contains('Consumable')));

      // And what a family HOLDS, which is the only thing on the row that can
      // answer "is this one kind of box".
      expect(library.examplesIn('Matrix'), hasLength(2));
      expect(library.examplesIn('Matrix'), contains('DTP CrossPoint 108'));
      expect(library.examplesIn('Matrix', limit: 1), hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  //  THE SCREEN
  // -------------------------------------------------------------------------

  Future<void> openEditor(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1700, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: DeviceEditorView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  AppStateProvider withMessyCatalog() =>
      AppStateProvider(autoLoadSettings: false)
        ..avDeviceLibrary = messyCatalog();

  group('the tidy-up screen', () {
    testWidgets('the toolbar says how much of the catalog is untracked', (
      tester,
    ) async {
      await openEditor(tester, withMessyCatalog());
      // 'Matrix' and 'Control Systems'. 'Projector' is already right.
      expect(find.text('Tidy categories (2)...'), findsOneWidget);
    });

    testWidgets('it refiles a family and the catalog says so', (tester) async {
      final p = withMessyCatalog();
      await openEditor(tester, p);

      await tester.tap(find.byKey(const ValueKey('catalog_tidy_categories')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tidy_categories_dialog')), findsOne);

      // The obvious one is filled in for you; the ambiguous one is not.
      await tester.tap(find.byKey(const ValueKey('tidy_categories_suggest')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('tidy_categories_apply')));
      await tester.pumpAndSettle();

      expect(
        p.avDeviceLibrary.all.where((e) => e.category == 'Switcher').length,
        2,
        reason: 'Matrix is a switcher and nothing else',
      );
      expect(
        p.avDeviceLibrary.all.where((e) => e.category == 'Control Systems')
            .length,
        1,
        reason: 'Control Systems holds processors AND touch panels, so the '
            'app must not have guessed at it',
      );
    });

    testWidgets('nothing chosen is nothing applied', (tester) async {
      final p = withMessyCatalog();
      await openEditor(tester, p);

      await tester.tap(find.byKey(const ValueKey('catalog_tidy_categories')));
      await tester.pumpAndSettle();

      // A retag of two hundred entries is the sort of edit people want to look
      // at before it happens, so the button is dead until something would move.
      final apply = tester.widget<FilledButton>(
        find.byKey(const ValueKey('tidy_categories_apply')),
      );
      expect(apply.onPressed, isNull);
    });
  });
}
