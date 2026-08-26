import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

import 'package:extron_configurator/pdf_viewer_dialog.dart';

/// ============================================================================
///  THE CONTENTS PAGE OF A DRAWING SET
/// ============================================================================
///  A building's plan set is forty sheets that all look alike from a scroll
///  thumb, and the person who drew it already wrote the contents page - the
///  PDF's own bookmarks. What these guard is that the panel keeps the shape
///  that makes it worth reading: nested the way the set is nested, the sheet
///  on screen marked, and something useful to show for a set that carries no
///  bookmarks at all.
/// ============================================================================
void main() {
  PdfOutlineNode node(String title, int? page,
          {List<PdfOutlineNode> children = const []}) =>
      PdfOutlineNode(
        title: title,
        dest: page == null ? null : PdfDest(page, PdfDestCommand.fit, null),
        children: children,
      );

  Future<void> pump(
    WidgetTester tester, {
    List<PdfOutlineNode> chapters = const [],
    int pages = 0,
    int page = 1,
    void Function(PdfDest?)? onDest,
    void Function(int)? onPage,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            height: 600,
            child: PdfChapterList(
              chapters: chapters,
              pages: pages,
              page: page,
              onGoToDest: onDest ?? (_) {},
              onGoToPage: onPage ?? (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a set is read in the shape it was drawn in', (tester) async {
    await pump(tester, chapters: [
      node('Architectural', 1, children: [
        node('Level 1', 2),
        node('Reflected ceiling', 3),
      ]),
      node('Riser diagram', 9),
    ]);

    expect(find.text('CHAPTERS'), findsOneWidget);
    for (final title in [
      'Architectural',
      'Level 1',
      'Reflected ceiling',
      'Riser diagram',
    ]) {
      expect(find.text(title), findsOneWidget);
    }

    // Nested, not flattened: a child sits in from its parent.
    final parent = tester.getTopLeft(find.text('Architectural')).dx;
    final child = tester.getTopLeft(find.text('Level 1')).dx;
    expect(child, greaterThan(parent));
  });

  testWidgets('pressing a chapter goes to where it points', (tester) async {
    PdfDest? went;
    await pump(
      tester,
      chapters: [node('Riser diagram', 9)],
      onDest: (d) => went = d,
    );

    await tester.tap(find.text('Riser diagram'));
    await tester.pump();
    expect(went?.pageNumber, 9);
  });

  testWidgets('the sheet on screen is the one marked', (tester) async {
    await pump(
      tester,
      chapters: [node('Level 1', 2), node('Level 2', 7)],
      page: 7,
    );
    expect(
      tester.widget<Text>(find.text('Level 2')).style?.fontWeight,
      FontWeight.bold,
    );
    expect(
      tester.widget<Text>(find.text('Level 1')).style?.fontWeight,
      isNot(FontWeight.bold),
    );
  });

  testWidgets('a set with no bookmarks lists its sheets instead',
      (tester) async {
    var went = 0;
    await pump(tester, pages: 3, onPage: (n) => went = n);

    expect(find.text('SHEETS'), findsOneWidget);
    expect(find.textContaining('no bookmarks'), findsOneWidget);
    expect(find.text('Sheet 1'), findsOneWidget);
    expect(find.text('Sheet 3'), findsOneWidget);

    await tester.tap(find.text('Sheet 3'));
    await tester.pump();
    expect(went, 3);
  });

  testWidgets('a bookmark that points nowhere is shown, not pressed',
      (tester) async {
    var pressed = false;
    await pump(
      tester,
      chapters: [node('Cover', null)],
      onDest: (_) => pressed = true,
    );
    await tester.tap(find.text('Cover'));
    await tester.pump();
    expect(pressed, isFalse);
  });
}
