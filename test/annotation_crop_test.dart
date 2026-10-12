// The crop tool on the annotation editor: draw a box, Apply crop, and the
// canvas (and what Copy and Save write) is only that box; Reset crop brings
// the whole picture back.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:extron_configurator/screenshot_tools.dart';

void main() {
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

  Future<void> openEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late Uint8List png;
    await tester.runAsync(() async => png = await pngOf(600, 400));
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }

  Size canvasSize(WidgetTester tester) =>
      tester.getSize(find.byKey(const ValueKey('annotation_canvas')));

  testWidgets('a crop keeps only the box drawn, until it is reset',
      (tester) async {
    await openEditor(tester);
    expect(canvasSize(tester), const Size(600, 400));

    await tester.tap(find.byTooltip(
        'Crop - draw the part to keep, then Apply crop'));
    await tester.pump();
    final Finder apply = find.byKey(const ValueKey('annotation_apply_crop'));
    expect(tester.widget<ButtonStyleButton>(apply).onPressed, isNull,
        reason: 'nothing to apply before a box is drawn');

    final Offset corner =
        tester.getTopLeft(find.byKey(const ValueKey('annotation_canvas')));
    final gesture = await tester.startGesture(corner + const Offset(100, 50));
    await gesture.moveBy(const Offset(20, 20));
    await gesture.moveTo(corner + const Offset(300, 150));
    await gesture.up();
    await tester.pump();

    await tester.tap(apply);
    await tester.pump();
    expect(canvasSize(tester), const Size(200, 100));

    await tester.tap(find.byKey(const ValueKey('annotation_reset_crop')));
    await tester.pump();
    expect(canvasSize(tester), const Size(600, 400));
  });
}
