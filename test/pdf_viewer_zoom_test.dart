import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/pdf_viewer_dialog.dart';

/// The two presses every other reader has.
///
/// A plan is read by going in close on one corner of it, and the wheel and the
/// pinch that do that are neither discoverable nor available to somebody
/// driving the app from a laptop keyboard. The buttons are, so they have to be
/// on the bar and they have to move the document.
///
/// Driven on an IMAGE document: the PDF half of the viewer needs pdfium and a
/// real file, and the question here — does the button change what is on
/// screen — is the same question either way.
void main() {
  double scaleOf(WidgetTester tester) => tester
      .widget<InteractiveViewer>(find.byType(InteractiveViewer))
      .transformationController!
      .value
      .getMaxScaleOnAxis();

  Future<void> pumpViewer(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PdfViewerDialog(
            // Never read: a missing image draws its error message, and the
            // pan/zoom around it is what is being tested.
            filePath: 'not_a_real_drawing.png',
            title: 'Level 2',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('both buttons are on the bar', (tester) async {
    await pumpViewer(tester);
    expect(find.byKey(const ValueKey('document_viewer_zoom_in')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('document_viewer_zoom_out')),
        findsOneWidget);
    expect(find.byTooltip('Zoom in'), findsOneWidget);
    expect(find.byTooltip('Zoom out'), findsOneWidget);
  });

  testWidgets('zoom in goes in, zoom out comes back', (tester) async {
    await pumpViewer(tester);
    expect(scaleOf(tester), 1.0);

    await tester.tap(find.byKey(const ValueKey('document_viewer_zoom_in')));
    await tester.pumpAndSettle();
    final zoomed = scaleOf(tester);
    expect(zoomed, greaterThan(1.0));

    await tester.tap(find.byKey(const ValueKey('document_viewer_zoom_out')));
    await tester.pumpAndSettle();
    expect(scaleOf(tester), closeTo(1.0, 0.001),
        reason: 'a press each way lands back where it started');
    expect(tester.takeException(), isNull);
  });

  testWidgets('zooming out at the far end stops rather than inverting',
      (tester) async {
    await pumpViewer(tester);
    for (var i = 0; i < 12; i++) {
      await tester.tap(find.byKey(const ValueKey('document_viewer_zoom_out')));
      await tester.pumpAndSettle();
    }
    expect(scaleOf(tester), greaterThan(0.0));
    expect(tester.takeException(), isNull);
  });
}
