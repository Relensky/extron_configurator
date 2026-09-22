import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/image_color_picker.dart';

/// Picking the estimate accent out of the logo.
void main() {
  /// [colors] side by side, each [w] pixels wide, as RGBA.
  DecodedImage stripes(List<Color> colors, {int w = 10, int h = 4}) {
    final width = colors.length * w;
    final rgba = Uint8List(width * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < width; x++) {
        final c = colors[x ~/ w];
        final i = (y * width + x) * 4;
        rgba[i] = (c.r * 255).round();
        rgba[i + 1] = (c.g * 255).round();
        rgba[i + 2] = (c.b * 255).round();
        rgba[i + 3] = (c.a * 255).round();
      }
    }
    return DecodedImage(width, h, rgba);
  }

  test('the main colors skip background, outline and transparency', () {
    final image = stripes([
      const Color(0xFFFFFFFF), // background
      const Color(0xFFFFFFFF),
      const Color(0xFF000000), // outline
      const Color(0x00880E4F), // transparent
      const Color(0xFF880E4F),
      const Color(0xFF880E4F),
      const Color(0xFF0D47A1),
    ]);
    final colors = dominantColors(image);
    expect(colors.map((c) => c.toARGB32()), [0xFF880E4F, 0xFF0D47A1]);
  });

  test('near-identical shades are offered once', () {
    final image = stripes([
      const Color(0xFF880E4F),
      const Color(0xFF8A104F),
      const Color(0xFF0D47A1),
    ]);
    expect(dominantColors(image).length, 2);
  });

  testWidgets('clicking the logo picks the color under the pointer', (
    tester,
  ) async {
    // Left half red, right half blue.
    final bytes = (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 20, 20),
        Paint()..color = const Color(0xFFB71C1C),
      );
      canvas.drawRect(
        const Rect.fromLTWH(20, 0, 20, 20),
        Paint()..color = const Color(0xFF0D47A1),
      );
      final image = await recorder.endRecording().toImage(40, 20);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      return png!.buffer.asUint8List();
    }))!;

    Color? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await pickColorFromImage(context, bytes),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 100),
        ));
    await tester.pumpAndSettle();

    final area = find.byKey(const ValueKey('image_color_area'));
    expect(area, findsOneWidget);
    // Nothing picked yet, so nothing to use.
    expect(
      tester.widget<FilledButton>(find.byKey(const ValueKey('image_color_use')))
          .onPressed,
      isNull,
    );

    // Right of center is the blue half.
    final box = tester.getRect(area);
    await tester.tapAt(box.center + Offset(box.height / 2, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('image_color_use')));
    await tester.pumpAndSettle();
    expect(result?.toARGB32(), 0xFF0D47A1);
  });
}
