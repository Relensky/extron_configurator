// The annotation editor's bar: the title and the ways out (Copy, Save PNG,
// close) stay pinned on the top row at any width; only the drawing tools wrap
// underneath. Matches the CTS-Dashboard's editor.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:extron_configurator/screenshot_tools.dart';

void main() {
  for (final width in [700.0, 1400.0]) {
    testWidgets('title left, Save right, on one row at $width px',
        (tester) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      late Uint8List png;
      await tester.runAsync(() async {
        final r = ui.PictureRecorder();
        Canvas(r).drawRect(const Rect.fromLTWH(0, 0, 300, 200),
            Paint()..color = const Color(0xFF2E7D6F));
        final im = await r.endRecording().toImage(300, 200);
        png = (await im.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
      });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () => showAnnotationEditor(c, png),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();

      expect(tester.takeException(), isNull);
      final title = tester.getRect(find.text('Annotate Screenshot'));
      final save = tester.getRect(find.text('Save PNG'));
      final copy = tester.getRect(find.byKey(const ValueKey('annotation_copy')));
      final pen = tester.getRect(find.byTooltip('Pen'));

      expect(save.center.dy, closeTo(title.center.dy, 12),
          reason: 'Save sits on the title row');
      expect(save.left, greaterThan(title.right));
      expect(copy.right, lessThanOrEqualTo(save.left));
      expect(pen.top, greaterThan(title.bottom - 1),
          reason: 'the drawing tools wrap below the pinned row');
    });
  }
}
