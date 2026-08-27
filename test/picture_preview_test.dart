import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/screenshot_tools.dart';

/// A preview is only a preview if the whole document can be reached from it.
/// The responsibility matrix is wider than any dialog and the cost estimate is
/// taller than any screen, so the two things that have to hold are that the
/// bars are THERE rather than discovered by dragging, and that the zoom moves
/// the view without ever touching what would be photographed.
void main() {
  /// A document deliberately bigger than the frame it is put in.
  Widget oversizedSheet() => Container(
    key: const ValueKey('sheet'),
    width: 2400,
    height: 1600,
    color: Colors.white,
  );

  Future<void> pump(WidgetTester tester, {Size frame = const Size(600, 400)}) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: frame.width,
              height: frame.height,
              child: ZoomablePicturePreview(
                keyPrefix: 'preview',
                child: oversizedSheet(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// What the zoom bar currently says, as a whole-number percentage.
  int shownZoom(WidgetTester tester) {
    final label = tester.widget<Text>(
      find.byKey(const ValueKey('preview_zoom_level')),
    );
    return int.parse(label.data!.replaceAll('%', ''));
  }

  /// The sheet's DRAWN size - what the preview is showing right now.
  ///
  /// Deliberately not the sheet's own size. The whole design is that the
  /// document is LAID OUT full size and only DRAWN scaled, so the boundary
  /// inside it photographs the document rather than the window; measuring the
  /// sheet itself would report 2400 at every zoom and prove nothing. The box
  /// the scaling happens in is what the eye sees.
  Size drawnSize(WidgetTester tester) => tester.getSize(
    find
        .ancestor(
          of: find.byKey(const ValueKey('sheet')),
          matching: find.byType(FittedBox),
        )
        .first,
  );

  testWidgets('a sheet bigger than the frame gets a bar down both edges', (
    tester,
  ) async {
    await pump(tester);
    await tester.pumpAndSettle();

    // Two of them: one for each axis. A document that runs off to the right
    // with no bar down its edge is a document that LOOKS like it stops at the
    // frame, which is the whole complaint this fixes.
    expect(find.byType(Scrollbar), findsNWidgets(2));
    for (final bar in tester.widgetList<Scrollbar>(find.byType(Scrollbar))) {
      expect(bar.thumbVisibility, isTrue);
    }
    expect(find.byType(SingleChildScrollView), findsNWidgets(2));
  });

  testWidgets('it opens fitted, so the whole document is on screen at once', (
    tester,
  ) async {
    await pump(tester);
    await tester.pumpAndSettle();

    // 2400 wide into a 600 frame less the room kept for the bars.
    expect(shownZoom(tester), lessThan(100));
    final drawn = drawnSize(tester);
    expect(drawn.width, lessThanOrEqualTo(600));
    expect(drawn.height, lessThanOrEqualTo(400));
    // Still the same document — fitting scaled it, it did not crop it.
    expect(drawn.width / drawn.height, closeTo(2400 / 1600, 0.01));
  });

  testWidgets('zoom in and zoom out move the view', (tester) async {
    await pump(tester);
    await tester.pumpAndSettle();
    final int fitted = shownZoom(tester);
    final Size atFit = drawnSize(tester);

    await tester.tap(find.byKey(const ValueKey('preview_zoom_in')));
    await tester.pumpAndSettle();
    expect(shownZoom(tester), greaterThan(fitted));
    expect(drawnSize(tester).width, greaterThan(atFit.width));

    await tester.tap(find.byKey(const ValueKey('preview_zoom_out')));
    await tester.pumpAndSettle();
    expect(shownZoom(tester), fitted);
    expect(drawnSize(tester).width, closeTo(atFit.width, 0.5));
  });

  testWidgets('actual size shows the document at 1:1, and fit puts it back', (
    tester,
  ) async {
    await pump(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('preview_zoom_actual')));
    await tester.pumpAndSettle();
    expect(shownZoom(tester), 100);
    // The sheet is drawn at its own size and the frame scrolls over it.
    expect(drawnSize(tester), const Size(2400, 1600));

    await tester.tap(find.byKey(const ValueKey('preview_zoom_fit')));
    await tester.pumpAndSettle();
    expect(shownZoom(tester), lessThan(100));
    expect(drawnSize(tester).width, lessThanOrEqualTo(600));
  });

  testWidgets('a sheet smaller than the frame is left at its own size', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              height: 400,
              child: ZoomablePicturePreview(
                keyPrefix: 'preview',
                child: Container(
                  key: const ValueKey('sheet'),
                  width: 120,
                  height: 80,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Fitting never blows a small picture up into a poster of six cells.
    expect(shownZoom(tester), 100);
    expect(drawnSize(tester), const Size(120, 80));
  });

  testWidgets('the captured picture offers save, copy and the pen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCapturedPicture(
                context,
                _tinyPng,
                title: 'The estimate as a picture',
                fileName: 'estimate.png',
                what: 'The cost estimate image',
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('captured_picture_dialog')), findsOne);
    // The three things somebody does with a screenshot, on the screen where
    // they are looking at it: keep it, paste it, or mark it up first.
    expect(find.byKey(const ValueKey('captured_picture_save')), findsOne);
    expect(find.byKey(const ValueKey('captured_picture_copy')), findsOne);
    expect(find.byKey(const ValueKey('captured_picture_annotate')), findsOne);
    // And it can be read while it is being decided about.
    expect(find.byType(ZoomablePicturePreview), findsOne);
  });

  testWidgets('the pen opens the annotation editor over the picture', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCapturedPicture(
                context,
                _tinyPng,
                title: 'The estimate as a picture',
                fileName: 'estimate.png',
                what: 'The cost estimate image',
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('captured_picture_annotate')));
    // Pumped rather than settled, all the way down this test. The editor
    // decodes the PNG through the real image codec and shows a spinner while
    // it does, and a spinner is an animation that never finishes - so
    // pumpAndSettle would sit here until it timed out.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(AnnotationEditor), findsOne);
    expect(find.text('Annotate Screenshot'), findsOne);
    // The marked-up picture is a different picture from the one underneath,
    // and is usually the one that was wanted - so it has its own way out.
    expect(find.byKey(const ValueKey('annotation_copy')), findsOne);
    // The tools themselves.
    expect(find.byTooltip('Pen'), findsOne);
    expect(find.byTooltip('Highlighter'), findsOne);
    expect(find.byTooltip('Arrow'), findsOne);
    expect(find.byTooltip('Rectangle'), findsOne);
    expect(find.byTooltip('Text (click to place)'), findsOne);

    // OVER the preview, not instead of it: closing the pen puts somebody back
    // where they were rather than at nothing.
    await tester.tap(find.byTooltip('Close without saving'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AnnotationEditor), findsNothing);
    expect(find.byKey(const ValueKey('captured_picture_dialog')), findsOne);
  });
}

/// A real 4x4 PNG, so the dialog has something it can actually decode without
/// a fixture file on disk.
final Uint8List _tinyPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
  0x08, 0x06, 0x00, 0x00, 0x00, 0xA9, 0xF1, 0x9E,
  0x7E, 0x00, 0x00, 0x00, 0x12, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x38, 0xA1, 0xA1, 0xF1,
  0x1F, 0x19, 0x33, 0x90, 0x2E, 0x00, 0x00, 0x6C,
  0x38, 0x21, 0x71, 0x4B, 0x5E, 0xD7, 0x1C, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);
