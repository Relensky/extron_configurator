import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';

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

  // ==========================================================================
  //  THE ANNOTATION CANVAS
  // ==========================================================================
  //  A screenshot of a whole cost estimate is several screens tall, and fitted
  //  into a dialog it is a picture too small to draw on accurately - which is
  //  the point of marking one up at all. So the canvas zooms, and once it is
  //  bigger than the window it has to be movable.
  //
  //  There is only one drag, and both the pen and the scroll views want it.
  //  Rather than put the two in a gesture arena and hope - which is how a
  //  stroke turns into a scroll halfway through a circle - the hand tool
  //  decides it outright, and the bars and the wheel work either way.
  // ==========================================================================

  /// A real PNG of a given size, encoded the way the app encodes one.
  ///
  /// Built rather than pasted in as a byte literal: these tests need pictures
  /// of particular sizes relative to the window, and a 600x400 PNG written out
  /// as Dart source is four thousand lines nobody can check.
  Future<Uint8List> pngOf(int w, int h) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xFF2E7D6F),
    );
    final image = await recorder.endRecording().toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// The annotation editor, open over a picture [w] x [h] in a [window]-sized
  /// window.
  Future<void> openEditor(
    WidgetTester tester, {
    int w = 600,
    int h = 400,
    Size window = const Size(700, 500),
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late Uint8List png;
    await tester.runAsync(() async => png = await pngOf(w, h));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAnnotationEditor(context, png),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    // Pumped rather than settled: the editor spins while it decodes, and a
    // spinner is an animation that never finishes.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // The picture comes off the REAL image codec, which needs real time to
    // run - under fake async it never completes and the canvas stays a
    // spinner, with no zoom bar and nothing to draw on.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }

  /// The drawing surface, whose size IS the current zoom.
  Size canvasSize(WidgetTester tester) =>
      tester.getSize(find.byKey(const ValueKey('annotation_canvas')));

  /// The two scroll views around the canvas - NOT the toolbar's, which scrolls
  /// the tools and has nothing to do with the picture.
  Iterable<SingleChildScrollView> canvasScrollers(WidgetTester tester) =>
      tester.widgetList<SingleChildScrollView>(
        find.descendant(
          of: find.byKey(const ValueKey('annotation_canvas_area')),
          matching: find.byType(SingleChildScrollView),
        ),
      );

  /// A point on the picture with nothing drawn on it - its far corner, away
  /// from the marks these tests put near the top-left.
  ///
  /// Measured off the canvas as laid out rather than written down as a fixed
  /// offset: how much of the window the picture gets depends on how many
  /// lines the toolbar has wrapped onto, and a fixed offset that lands
  /// OUTSIDE the canvas is a click that never reaches it - which reads in a
  /// test as a mark that refused to be dropped.
  Offset bareCanvas(WidgetTester tester) =>
      tester.getRect(find.byKey(const ValueKey('annotation_canvas')))
          .bottomRight -
      const Offset(20, 20);

  int editorZoom(WidgetTester tester) {
    final label = tester.widget<Text>(
      find.byKey(const ValueKey('annotation_zoom_level')),
    );
    return int.parse(label.data!.replaceAll('%', ''));
  }

  Future<void> press(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('the canvas carries the same zoom controls as the preview', (
    tester,
  ) async {
    await openEditor(tester);

    expect(find.byKey(const ValueKey('annotation_zoom_in')), findsOne);
    expect(find.byKey(const ValueKey('annotation_zoom_out')), findsOne);
    expect(find.byKey(const ValueKey('annotation_zoom_fit')), findsOne);
    expect(find.byKey(const ValueKey('annotation_zoom_actual')), findsOne);
    // And bars down both edges, for the picture that no longer fits.
    expect(find.byType(Scrollbar), findsNWidgets(2));
  });

  testWidgets('zooming in makes the drawing surface bigger', (tester) async {
    await openEditor(tester);
    final Size fitted = canvasSize(tester);
    final int fittedZoom = editorZoom(tester);

    await press(tester, 'annotation_zoom_in');

    expect(editorZoom(tester), greaterThan(fittedZoom));
    expect(canvasSize(tester).width, greaterThan(fitted.width));

    await press(tester, 'annotation_zoom_fit');
    expect(canvasSize(tester).width, closeTo(fitted.width, 0.5));
  });

  testWidgets('a small capture is left at its own size, not blown up', (
    tester,
  ) async {
    await openEditor(tester, w: 40, h: 30);
    // Fitting never blows a small picture up into a poster of six pixels.
    expect(editorZoom(tester), 100);
    expect(canvasSize(tester), const Size(40, 30));
  });

  testWidgets('a picture too tall for the window opens fitted', (
    tester,
  ) async {
    await openEditor(tester, w: 600, h: 2400);
    expect(editorZoom(tester), lessThan(100));
    expect(canvasSize(tester).height, lessThanOrEqualTo(500));
  });

  /// Selects a tool off the toolbar.
  Future<void> pickTool(WidgetTester tester, String tooltip) async {
    await tester.ensureVisible(find.byTooltip(tooltip));
    await tester.pump();
    await tester.tap(find.byTooltip(tooltip));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// One toolbar button, by key.
  ///
  /// By predicate rather than [CommonFinders.byKey]: an [IconButton] with a
  /// tooltip wraps itself, and the plain key finder can land on the wrapper.
  IconButton toolbarButton(WidgetTester tester, String key) =>
      tester.widget<IconButton>(
        find.byWidgetPredicate(
          (w) => w is IconButton && w.key == ValueKey(key),
        ),
      );

  /// Every control on the toolbar, by the finder that reaches it.
  ///
  /// The colors are counted rather than named: they are drawn containers
  /// with no text or tooltip on them, so what is checked is that all eight
  /// are laid out and hittable.
  const List<String> toolbarTooltips = [
    'Pen',
    'Highlighter',
    'Arrow',
    'Rectangle',
    'Text (click to place)',
    'Select - move, recolor or retype a mark',
    'Move the picture',
    'Clear all annotations',
    'Edit the selected text',
    'Delete the selected mark',
    'Close without saving',
  ];

  /// THE BAR WRAPS RATHER THAN CUTS. The editor is opened over whatever it is
  /// annotating, so it gets shrunk - and a color or a Save button that has
  /// gone off the edge, behind an overflow stripe or into a sideways
  /// scroller, is one nobody can press and most will not know is there. At
  /// every width the bar is allowed to get taller instead, and everything
  /// stays on screen.
  for (final Size window in [
    const Size(1200, 700),
    const Size(700, 500),
    const Size(460, 620),
  ]) {
    testWidgets('the toolbar keeps every control at ${window.width}px wide',
        (tester) async {
      await openEditor(tester, window: window);

      // An overflowing Row reports itself as an exception when it paints.
      expect(tester.takeException(), isNull);

      for (final String tip in toolbarTooltips) {
        expect(find.byTooltip(tip), findsOne, reason: '$tip is missing');
        expect(tester.getRect(find.byTooltip(tip)).right,
            lessThanOrEqualTo(window.width),
            reason: '$tip runs off the right-hand edge');
      }
      expect(find.text('Copy'), findsOne);
      expect(find.text('Save PNG'), findsOne);
      expect(tester.getRect(find.text('Save PNG')).right,
          lessThanOrEqualTo(window.width));

      // All eight colors, inside the window, without a scroll.
      final Finder swatches = find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle);
      expect(swatches, findsNWidgets(8));
      for (int i = 0; i < 8; i++) {
        expect(tester.getRect(swatches.at(i)).right,
            lessThanOrEqualTo(window.width),
            reason: 'color $i runs off the right-hand edge');
      }
    });
  }

  testWidgets('the narrow toolbar leaves the picture room to be drawn on',
      (tester) async {
    // Wrapping costs height, and the canvas pays for it - but it is the
    // canvas the editor exists for, so it has to keep a usable share of a
    // small window rather than being squeezed to a sliver by the bar.
    await openEditor(tester, window: const Size(460, 620));
    expect(canvasSize(tester).height, greaterThan(200));
  });

  /// The controller behind the picture's vertical scroll.
  ScrollController downController(WidgetTester tester) => tester
      .widgetList<Scrollbar>(
        find.descendant(
          of: find.byKey(const ValueKey('annotation_canvas_area')),
          matching: find.byType(Scrollbar),
        ),
      )
      .first
      .controller!;

  testWidgets('no drag on this canvas is ever contested', (tester) async {
    await openEditor(tester);
    expect(find.byTooltip('Move the picture'), findsOne);

    // The scroll views take no drags at all, whatever tool is up: the canvas
    // takes every drag and decides what it meant, so a stroke can never turn
    // into a scroll halfway through a circle.
    expect(canvasScrollers(tester), hasLength(2));
    for (final view in canvasScrollers(tester)) {
      expect(view.physics, isA<NeverScrollableScrollPhysics>());
    }

    await pickTool(tester, 'Move the picture');
    for (final view in canvasScrollers(tester)) {
      expect(
        view.physics,
        isA<NeverScrollableScrollPhysics>(),
        reason: 'handing the drag back is what broke the hand',
      );
    }
  });

  testWidgets('the hand actually moves the picture', (tester) async {
    await openEditor(tester);
    // Big enough to overflow the window, or there is nothing to move.
    await press(tester, 'annotation_zoom_in');
    await press(tester, 'annotation_zoom_in');

    final down = downController(tester);
    expect(down.position.maxScrollExtent, greaterThan(0));
    expect(down.position.pixels, 0);

    await pickTool(tester, 'Move the picture');

    // THE BUG THIS GUARDS. The hand used to hand the drag back to the scroll
    // views - and a SingleChildScrollView on desktop does not accept drags
    // from a MOUSE, only from touch and stylus. So the tool did nothing at
    // all, while the bars and the wheel went on working, which is why it read
    // as inert rather than as broken.
    final canvas = find.byKey(const ValueKey('annotation_canvas'));
    final gesture = await tester.startGesture(
      tester.getCenter(canvas),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(
      down.position.pixels,
      greaterThan(0),
      reason: 'dragging with the hand has to move the picture',
    );
  });

  testWidgets('the wheel moves the picture even while the pen has the drag', (
    tester,
  ) async {
    await openEditor(tester);
    // Big enough to actually overflow the window.
    await press(tester, 'annotation_zoom_in');
    await press(tester, 'annotation_zoom_in');

    final down = tester
        .widgetList<Scrollbar>(
          find.descendant(
            of: find.byKey(const ValueKey('annotation_canvas_area')),
            matching: find.byType(Scrollbar),
          ),
        )
        .first
        .controller!;
    expect(
      down.position.maxScrollExtent,
      greaterThan(0),
      reason: 'the picture has to overflow before scrolling means anything',
    );
    expect(down.position.pixels, 0);

    // The pen is still the selected tool, so the scroll views are refusing
    // drags - and the wheel still has to work.
    final centre = tester.getCenter(
      find.byKey(const ValueKey('annotation_canvas')),
    );
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(centre);
    await tester.sendEventToBinding(
      pointer.scroll(const Offset(0, 60)),
    );
    await tester.pump();

    expect(down.position.pixels, greaterThan(0));
  });

  // ==========================================================================
  //  NOTHING IS FINAL UNTIL SAVE
  // ==========================================================================
  //  A mark used to be write-once: drawn, appended, and beyond reach except by
  //  undoing everything drawn after it. So a typo in the first label cost the
  //  three arrows that came next, and the usual fix was to close the editor
  //  and take the screenshot again.
  //
  //  The marks are a list right up to the moment Save turns them into pixels,
  //  so the pointer tool can reach any of them: pick it up, move it, recolor
  //  it, retype it, throw it away - however many marks have been made since.
  // ==========================================================================

  /// Puts a text label on the canvas at [at], through the toolbar.
  Future<void> addLabel(
    WidgetTester tester,
    String words, {
    Offset at = Offset.zero,
  }) async {
    await pickTool(tester, 'Text (click to place)');
    final canvas = find.byKey(const ValueKey('annotation_canvas'));
    await tester.tapAt(tester.getTopLeft(canvas) + at);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('annotation_text_dialog')), findsOne);
    await tester.enterText(
      find.byKey(const ValueKey('annotation_text_field')),
      words,
    );
    await tester.tap(find.byKey(const ValueKey('annotation_text_ok')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Draws an arrow across the canvas, so there is a later mark in the way.
  Future<void> drawArrow(WidgetTester tester) async {
    await pickTool(tester, 'Arrow');
    final canvas = find.byKey(const ValueKey('annotation_canvas'));
    final from = tester.getTopLeft(canvas) + const Offset(200, 200);
    final gesture = await tester.startGesture(from);
    await gesture.moveBy(const Offset(120, 60));
    await tester.pump();
    await gesture.up();
    await tester.pump();
  }

  testWidgets('the pointer is a tool of its own', (tester) async {
    await openEditor(tester);
    expect(
      find.byTooltip('Select - move, recolor or retype a mark'),
      findsOne,
    );
    // Nothing is in hand yet, so there is nothing to delete.
    expect(
      toolbarButton(tester, 'annotation_delete_selected').onPressed,
      isNull,
    );
  });

  testWidgets('a label can be retyped after later marks are drawn', (
    tester,
  ) async {
    await openEditor(tester);
    await addLabel(tester, 'Prjector', at: const Offset(60, 60));
    // The mark that used to make the label unreachable: Undo would have taken
    // this instead.
    await drawArrow(tester);

    await pickTool(tester, 'Select - move, recolor or retype a mark');
    final canvas = find.byKey(const ValueKey('annotation_canvas'));
    final onLabel = tester.getTopLeft(canvas) + const Offset(70, 72);

    // Double-click the label: its own words come back, ready to correct.
    await tester.tapAt(onLabel);
    // Past kDoubleTapMinTime (40ms) and inside kDoubleTapTimeout (300ms):
    // taps closer together than the minimum are rejected as one fumble.
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tapAt(onLabel);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const ValueKey('annotation_text_dialog')), findsOne);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('annotation_text_field')),
          )
          .controller!
          .text,
      'Prjector',
      reason: 'editing a label starts from what it says',
    );

    await tester.enterText(
      find.byKey(const ValueKey('annotation_text_field')),
      'Projector',
    );
    await tester.tap(find.byKey(const ValueKey('annotation_text_ok')));
    await tester.pump();
    // Long enough for the dialog to finish leaving.
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const ValueKey('annotation_text_dialog')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retyping is on the bar too, not only on a gesture', (
    tester,
  ) async {
    await openEditor(tester);
    await addLabel(tester, 'Screen', at: const Offset(60, 60));
    await pickTool(tester, 'Select - move, recolor or retype a mark');

    // A gesture is not an affordance: somebody who has clicked a label and can
    // see it is held has to be TOLD its words can be changed.
    final canvas = find.byKey(const ValueKey('annotation_canvas'));
    await tester.tapAt(tester.getTopLeft(canvas) + const Offset(70, 72));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(toolbarButton(tester, 'annotation_edit_text').onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('annotation_edit_text')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('annotation_text_dialog')), findsOne);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // ...and it stays dark for a mark that has no words.
    await tester.tapAt(bareCanvas(tester));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(toolbarButton(tester, 'annotation_edit_text').onPressed, isNull);
  });

  testWidgets('clicking a mark picks it up, and empty canvas drops it', (
    tester,
  ) async {
    await openEditor(tester);
    await addLabel(tester, 'Here', at: const Offset(60, 60));
    await pickTool(tester, 'Select - move, recolor or retype a mark');

    final canvas = find.byKey(const ValueKey('annotation_canvas'));

    await tester.tapAt(tester.getTopLeft(canvas) + const Offset(70, 72));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      toolbarButton(tester, 'annotation_delete_selected').onPressed,
      isNotNull,
      reason: 'a click on the label has to pick it up',
    );

    // Bare picture: nothing under the pointer, so nothing in hand.
    await tester.tapAt(bareCanvas(tester));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      toolbarButton(tester, 'annotation_delete_selected').onPressed,
      isNull,
    );
  });

  /// Paints the canvas as it stands into an image, and gives back the box that
  /// encloses every pixel that is not the flat backdrop.
  ///
  /// The only way to ask "is the halo actually ON the mark". The halo is drawn
  /// by a CustomPainter and has no widget of its own to measure, so the painter
  /// is run again into a recorder and the result is read back as pixels.
  Future<Rect> inkBounds(WidgetTester tester) async {
    final canvas = find.byKey(const ValueKey('annotation_canvas'));
    final size = tester.getSize(canvas);
    final painter = tester
        .widget<CustomPaint>(
          find.descendant(of: canvas, matching: find.byType(CustomPaint)),
        )
        .painter!;

    late Rect bounds;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), size);
      final w = size.width.round();
      final h = size.height.round();
      final image = await recorder.endRecording().toImage(w, h);
      final data = (await image.toByteData())!;
      image.dispose();

      // The picture underneath is one flat color, so anything else on it is
      // either the mark or the halo.
      const backdrop = 0xFF2E7D6F;
      var left = w, top = h, right = -1, bottom = -1;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          final argb =
              (data.getUint8(i + 3) << 24) |
              (data.getUint8(i) << 16) |
              (data.getUint8(i + 1) << 8) |
              data.getUint8(i + 2);
          if (argb == backdrop) continue;
          if (x < left) left = x;
          if (x > right) right = x;
          if (y < top) top = y;
          if (y > bottom) bottom = y;
        }
      }
      bounds = right < 0
          ? Rect.zero
          : Rect.fromLTRB(
              left.toDouble(),
              top.toDouble(),
              right.toDouble(),
              bottom.toDouble(),
            );
    });
    return bounds;
  }

  testWidgets('the halo lands on the mark at every zoom', (tester) async {
    await openEditor(tester);
    await addLabel(tester, 'Screen', at: const Offset(120, 90));
    await pickTool(tester, 'Select - move, recolor or retype a mark');

    final canvas = find.byKey(const ValueKey('annotation_canvas'));
    final onLabel = tester.getTopLeft(canvas) + const Offset(130, 100);
    await tester.tapAt(onLabel);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Fitted, which for a 600x400 picture in this window is well under 100%.
    expect(editorZoom(tester), lessThan(100));
    final fitted = await inkBounds(tester);

    // THE BUG THIS GUARDS. The shared mark painter used to scale the canvas
    // and never put it back, so the halo - drawn afterwards - was scaled a
    // second time. It landed on the mark at 100% and slid towards the
    // top-left corner at every other zoom, which is the one place a selection
    // box must never be.
    //
    // The halo surrounds the label with a few pixels to spare, so the two
    // together are barely bigger than the label. Painted twice-scaled they
    // would be a box stretching from the corner to the label instead.
    expect(
      fitted.left,
      greaterThan(100),
      reason: 'a halo scaled twice slides towards the origin',
    );
    expect(fitted.top, greaterThan(70));
    expect(
      fitted.width,
      lessThan(200),
      reason: 'the halo hugs the label rather than spanning to the corner',
    );

    // ...and again at 100%, where the two scalings used to agree.
    await press(tester, 'annotation_zoom_actual');
    expect(editorZoom(tester), 100);
    final actual = await inkBounds(tester);

    // The label was placed at the same image point, so at 100% its ink starts
    // further out than it did fitted - and the halo has to have gone with it.
    expect(actual.left, greaterThan(fitted.left));
    expect(actual.top, greaterThan(fitted.top));
    // Both are the label plus a handful of pixels of handle: at 100% the
    // lettering is bigger, so the box is bigger, but neither is a box that
    // reaches back to the corner.
    expect(actual.width, lessThan(250));
  });

  testWidgets('the halo is never saved into the picture', (tester) async {
    await openEditor(tester);
    await addLabel(tester, 'Screen', at: const Offset(120, 90));
    await pickTool(tester, 'Select - move, recolor or retype a mark');
    await tester.tapAt(
      tester.getTopLeft(find.byKey(const ValueKey('annotation_canvas'))) +
          const Offset(130, 100),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final held = await inkBounds(tester);

    // Dropping what is held is the only difference, so anything left over is
    // the halo - and the saved file is the picture with the halo gone. A
    // dashed box round whichever mark happened to be selected at the moment
    // somebody pressed Save is not a mark anybody made.
    await tester.tapAt(bareCanvas(tester));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final dropped = await inkBounds(tester);

    expect(dropped.width, lessThan(held.width));
    expect(dropped.height, lessThan(held.height));
  });

  // ---------------------------------------------------------------------------
  //  BACK AND FORWARD ON THE MARKS
  // ---------------------------------------------------------------------------
  //  This editor kept the only undo in the app that went one way, which is what
  //  makes people stop pressing it: a stroke taken back by mistake meant
  //  drawing it again by hand, on a picture somebody is annotating for a
  //  report.
  //
  //  The pair lives at the END of the scrolling tool group rather than beside
  //  Save and Close. The note at the head of that bar says why: the pinned
  //  group has no slack, and a button added to it squeezes the tool viewport
  //  until the tools themselves scroll out of reach.

  testWidgets('a mark taken back can be put back', (tester) async {
    await openEditor(tester);

    final undo = find.byKey(const ValueKey('annotation_undo'));
    final redo = find.byKey(const ValueKey('annotation_redo'));

    // Nothing drawn: neither is offered, and both say why.
    expect(tester.widget<IconButton>(undo).onPressed, isNull);
    expect(tester.widget<IconButton>(redo).onPressed, isNull);
    expect(tester.widget<IconButton>(undo).tooltip, contains('Nothing to undo'));

    await drawArrow(tester);
    expect(tester.widget<IconButton>(undo).onPressed, isNotNull);
    expect(tester.widget<IconButton>(undo).tooltip, contains('last mark'));

    await tester.tap(undo);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.widget<IconButton>(undo).onPressed, isNull,
        reason: 'the arrow went');
    expect(tester.widget<IconButton>(redo).onPressed, isNotNull,
        reason: 'and can be put back');

    await tester.tap(redo);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.widget<IconButton>(undo).onPressed, isNotNull,
        reason: 'the arrow is back');
    expect(tester.widget<IconButton>(redo).onPressed, isNull);
  });

  testWidgets('drawing over an undone mark ends the way forward',
      (tester) async {
    await openEditor(tester);
    await drawArrow(tester);

    await tester.tap(find.byKey(const ValueKey('annotation_undo')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('annotation_redo')))
          .onPressed,
      isNotNull,
    );

    await drawArrow(tester);

    // WHAT EVERY REDO IN EVERY PROGRAM DOES, and what people expect even when
    // they could not say so: something undone and then drawn over is gone.
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('annotation_redo')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('the ways out keep their places', (tester) async {
    // THE REGRESSION THIS FILE ALREADY CAUGHT ONCE. Adding a button to the
    // pinned group pushed the tools out of their viewport and left taps
    // landing on nothing. Save, Copy and Close have to stay reachable, and so
    // do the tools.
    await openEditor(tester);

    for (final key in ['annotation_copy', 'annotation_undo']) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    expect(
      find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == 'Close without saving',
      ),
      findsOneWidget,
    );
    // And a tool still takes a tap, which is what broke last time.
    await pickTool(tester, 'Select - move, recolor or retype a mark');
  });

  testWidgets('the mark in hand is deleted without touching the others', (
    tester,
  ) async {
    await openEditor(tester);
    await addLabel(tester, 'Wrong', at: const Offset(60, 60));
    await drawArrow(tester);

    await pickTool(tester, 'Select - move, recolor or retype a mark');
    final canvas = find.byKey(const ValueKey('annotation_canvas'));
    await tester.tapAt(tester.getTopLeft(canvas) + const Offset(70, 72));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byKey(const ValueKey('annotation_delete_selected')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Nothing in hand any more...
    expect(
      toolbarButton(tester, 'annotation_delete_selected').onPressed,
      isNull,
    );
    // ...and the arrow drawn after it is still there, which is the whole
    // difference between this and Undo: Clear all still has something to
    // clear.
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Clear all annotations',
            ),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
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
