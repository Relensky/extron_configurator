import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/help_content.dart';
import 'package:extron_configurator/help_view.dart';

/// ============================================================================
///  THE HELP BOOK
/// ============================================================================
///  There is a guide in documentation/ and it is a file somebody has to find,
///  open in another window and search separately - which on a laptop with a
///  drawing open is a thing that does not get done. So the book is in the app,
///  it opens on its search box, and the search runs over everything: titles,
///  sections, where each feature lives, its keywords and its prose.
///
///  What is held here is the shape of the book (a topic with no "where" is a
///  topic that cannot be acted on) and the behaviour of the search - which is
///  the only part of help anybody actually uses.
void main() {
  group('the book is well formed', () {
    test('every topic says where it is and what it does', () {
      for (final topic in kHelpTopics) {
        expect(topic.title.trim(), isNotEmpty);
        expect(topic.section.trim(), isNotEmpty);
        expect(
          topic.where.trim(),
          isNotEmpty,
          reason: '"${topic.title}" has nowhere to go - the first thing '
              'somebody wants off a help page is how to reach the thing',
        );
        expect(
          topic.body.trim().length,
          greaterThan(60),
          reason: '"${topic.title}" is a heading, not an answer',
        );
      }
    });

    test('no two topics share a title', () {
      // The reader is held by TITLE, and the haystack is cached by it.
      final seen = <String>{};
      for (final topic in kHelpTopics) {
        expect(
          seen.add(topic.title),
          isTrue,
          reason: '"${topic.title}" appears twice',
        );
      }
    });

    test('it covers every part of the app', () {
      // A section missing here is a part of the app with no help at all.
      expect(
        helpSections,
        containsAll([
          'Start here',
          'The room',
          'The drawings',
          'The money',
          'The job',
          'The refresh plan',
          'The estate',
          'Getting work out',
          'The machinery',
        ]),
      );
      for (final section in helpSections) {
        expect(helpSection(section), isNotEmpty);
      }
    });

    test('the sections keep their book order', () {
      // Grouped listing walks the topics once and starts a heading when the
      // section changes, so two runs of one section would print it twice.
      final seen = <String>{};
      var current = '';
      for (final topic in kHelpTopics) {
        if (topic.section == current) continue;
        current = topic.section;
        expect(
          seen.add(current),
          isTrue,
          reason: '"$current" is split into two runs',
        );
      }
    });
  });

  group('searching', () {
    test('a blank query is the whole book', () {
      expect(searchHelp('').length, kHelpTopics.length);
      expect(searchHelp('   ').length, kHelpTopics.length);
    });

    test('the name of the thing comes first', () {
      // A word typed into this box turns up in the body of half the book. A
      // hit in the title has to outrank a hit in the prose.
      expect(
        searchHelp('vendor').first.title.toLowerCase(),
        contains('vendor'),
      );
      expect(searchHelp('undo').first.title, 'Undo and redo');
      expect(searchHelp('rack').first.title, 'Rack elevations');
      expect(searchHelp('campus').first.title, 'The campus report');
    });

    test('a word somebody would use finds the feature it belongs to', () {
      // The point of keywords: the words on the button are not always the
      // words in somebody's head.
      for (final (query, expected) in [
        ('rfq', 'Quote requests - where a vendor has got to'),
        ('ryg', 'How old the gear is, and when it falls due'),
        ('msrp', 'Pricing tier - list or education'),
        ('bom', 'The master parts list'),
        ('discontinued', 'Setting a replacement model on a retired product'),
        ('eol', 'Setting a replacement model on a retired product'),
        ('sftp', 'Pushing a config to the processor'),
      ]) {
        expect(
          searchHelp(query).map((t) => t.title),
          contains(expected),
          reason: 'searching "$query" should reach "$expected"',
        );
      }
    });

    test('every word has to appear somewhere', () {
      // AND, not OR. A search returning everything about vendors plus
      // everything about quotes has answered a question nobody asked.
      final both = searchHelp('vendor quote');
      expect(both, isNotEmpty);
      for (final topic in both) {
        expect(topic.haystack, contains('vendor'));
        expect(topic.haystack, contains('quote'));
      }
      expect(both.length, lessThan(searchHelp('vendor').length));
    });

    test('a word in nothing returns nothing rather than everything', () {
      expect(searchHelp('zzzznothinghere'), isEmpty);
    });

    test('it does not care about case', () {
      expect(searchHelp('VENDOR').length, searchHelp('vendor').length);
    });
  });

  group('on screen', () {
    Future<void> open(WidgetTester tester, {String query = ''}) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: HelpBook(initialQuery: query)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('it opens on the search box, with the whole book listed', (
      tester,
    ) async {
      await open(tester);
      expect(find.byKey(const ValueKey('help_search')), findsOneWidget);
      expect(
        find.textContaining('${kHelpTopics.length} features'),
        findsOneWidget,
      );
      // Grouped under section headings while nothing is typed.
      expect(find.text('THE JOB'), findsOneWidget);
    });

    testWidgets('typing narrows it and says how many are left', (tester) async {
      await open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('help_search')),
        'vendor',
      );
      await tester.pumpAndSettle();

      final hits = searchHelp('vendor').length;
      expect(
        find.textContaining('$hits ${hits == 1 ? 'feature' : 'features'} match'),
        findsOneWidget,
      );
      // And it really is narrowed: a topic that says nothing about vendors is
      // no longer on the list.
      expect(
        find.byKey(const ValueKey('help_topic_Rack elevations')),
        findsNothing,
      );
    });

    testWidgets('a topic can be read, and says where it lives', (tester) async {
      // Searched first: the whole book is longer than the frame, and a tile
      // below the fold cannot be tapped.
      await open(tester, query: 'master parts');
      await tester.tap(
        find.byKey(const ValueKey('help_topic_The master parts list')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('help_page_The master parts list')),
        findsOneWidget,
      );
      expect(find.text('Project tab → Equipment'), findsOneWidget);
    });

    testWidgets('a keyword on the page searches it', (tester) async {
      await open(tester, query: 'rfq');
      await tester.pumpAndSettle();
      // The first hit is already open on the wide layout.
      await tester.tap(
        find.byKey(
          const ValueKey('help_topic_Quote requests - where a vendor has got '
              'to'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(
          const ValueKey('help_keyword_Quote requests - where a vendor has got '
              'to_chase'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        (tester.widget<TextField>(
          find.byKey(const ValueKey('help_search')),
        )).controller?.text,
        'chase',
      );
    });

    testWidgets('a search matching nothing says so rather than emptying', (
      tester,
    ) async {
      await open(tester, query: 'zzzznothinghere');
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing matches'), findsWidgets);
    });

    testWidgets('the initial query is honoured', (tester) async {
      await open(tester, query: 'campus');
      expect(
        find.textContaining('match "campus"'),
        findsOneWidget,
      );
    });
  });
}
