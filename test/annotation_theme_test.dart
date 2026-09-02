// The annotation editor's own colors, sampled off the rendered pixels.
//
// The bar and the canvas are read back from a painted frame rather than off
// the widgets, because what went wrong here was not a wrong color constant:
// the editor was handed the wrong THEME and picked its light colors correctly
// out of it.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:extron_configurator/screenshot_tools.dart';

void main() {
  final probeKey = GlobalKey();
  const Size window = Size(900, 600);

  /// Opens the editor and returns the painted (bar, canvas) colors.
  ///
  /// [underPrintSkin] opens it the way a drawing does - from a caller sitting
  /// inside the forced light theme that makes a sheet print as paper.
  Future<(Color bar, Color canvas)> colorsOf(
    WidgetTester tester, {
    required Brightness brightness,
    bool underPrintSkin = false,
  }) async {
    tester.view.physicalSize = window;
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

    await tester.pumpWidget(RepaintBoundary(
      key: probeKey,
      child: MaterialApp(
        theme: ThemeData(
            useMaterial3: true,
            brightness: brightness,
            colorSchemeSeed: Colors.blue),
        home: Scaffold(
          body: printSkin(
            enabled: underPrintSkin,
            child: Builder(
              builder: (c) => TextButton(
                onPressed: () => showAnnotationEditor(c, png),
                child: const Text('go'),
              ),
            ),
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

    final Rect title = tester.getRect(find.text('Annotate Screenshot'));
    final boundary =
        probeKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    late ByteData bytes;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      image.dispose();
    });
    Color at(double x, double y) {
      final i = ((y.round() * window.width.round()) + x.round()) * 4;
      return Color.fromARGB(255, bytes.getUint8(i), bytes.getUint8(i + 1),
          bytes.getUint8(i + 2));
    }

    // Just right of the title, which is bar and nothing else; and low on the
    // canvas, below the picture.
    return (at(title.right + 6, title.center.dy), at(450, 470));
  }

  testWidgets('in a dark theme the bar is dark', (tester) async {
    final (bar, canvas) = await colorsOf(tester, brightness: Brightness.dark);
    expect(bar.computeLuminance(), lessThan(0.2), reason: 'bar $bar is light');
    expect(canvas.computeLuminance(), lessThan(0.2));
  });

  testWidgets('...and still dark opened from inside the print skin',
      (tester) async {
    // THE BUG. showDialog copies the caller's inherited themes into the route,
    // so opening the editor from inside printSkin's forced light theme used to
    // paint a light gray toolbar over a dark-mode app.
    final (bar, canvas) = await colorsOf(tester,
        brightness: Brightness.dark, underPrintSkin: true);
    expect(bar.computeLuminance(), lessThan(0.2),
        reason: 'the print skin leaked into the editor: bar $bar');
    expect(canvas.computeLuminance(), lessThan(0.2));
  });

  testWidgets('in a light theme the bar is light', (tester) async {
    final (bar, canvas) = await colorsOf(tester, brightness: Brightness.light);
    expect(bar.computeLuminance(), greaterThan(0.6), reason: 'bar $bar');
    // The picture sits ON the canvas, which is the dimmer of the two.
    expect(canvas.computeLuminance(), lessThan(bar.computeLuminance()));
  });

  testWidgets('the dark bar sits above its canvas too', (tester) async {
    final (bar, canvas) = await colorsOf(tester, brightness: Brightness.dark);
    expect(canvas.computeLuminance(), lessThan(bar.computeLuminance()),
        reason: 'bar $bar, canvas $canvas');
  });
}
