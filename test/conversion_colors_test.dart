import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/conversion_colors.dart';
import 'package:extron_configurator/main.dart';

/// The provenance palette used to be written out twice — once in the preview
/// dialog, once in the field builder — with its own hardcoded blues, whites and
/// greys. That is why the preview came out looking like a stock JSON viewer
/// dropped into an amber HUD. It is one theme-derived palette now, and these
/// hold it to that.
void main() {
  /// [ConversionColors] resolved under each theme the App Config tab offers.
  Future<ConversionColors> paletteFor(
      WidgetTester tester, String style, bool dark) async {
    late ConversionColors colors;
    late ThemeData theme;
    await tester.pumpWidget(MaterialApp(
      theme: RoomConfigApp.themeFor(style, dark, '1976D2', 'F0A500', ''),
      home: Builder(builder: (context) {
        colors = ConversionColors.of(context);
        theme = Theme.of(context);
        return const SizedBox();
      }),
    ));
    // Sanity: the palette really came from the theme under test
    expect(colors.sectionName, theme.colorScheme.primary);
    return colors;
  }

  const themes = [
    ('classic', true),
    ('classic', false),
    ('auris', true),
    ('auris', false),
  ];

  for (final (style, dark) in themes) {
    final name = '$style ${dark ? 'dark' : 'light'}';

    testWidgets('$name: a written value is the theme\'s own text colour',
        (tester) async {
      final colors = await paletteFor(tester, style, dark);
      final onSurface = Theme.of(tester.element(find.byType(SizedBox)))
          .colorScheme
          .onSurface;
      // Not Colors.white: Auris's text is a warm cream, and a true white
      // beside it reads as a highlight it isn't.
      expect(colors.written, onSurface);
    });

    testWidgets('$name: the three origins are three different colours',
        (tester) async {
      final colors = await paletteFor(tester, style, dark);
      final swatches = [
        colors.forOrigin(ValueOrigin.legacy),
        colors.forOrigin(ValueOrigin.changed),
        colors.forOrigin(ValueOrigin.written),
      ];
      expect(swatches.whereType<Color>(), hasLength(3),
          reason: 'every origin needs a colour to be flagged with');
      expect(swatches.toSet(), hasLength(3),
          reason: 'two states sharing a colour flag nothing');
    });

    testWidgets('$name: section headings outrank property names',
        (tester) async {
      final colors = await paletteFor(tester, style, dark);
      // Both were the same blue before, so the headings did not read as
      // headings — the thing that looked "off" about them.
      expect(colors.sectionName, isNot(colors.propertyName));
    });

    testWidgets('$name: no origin colour is lost against the panel',
        (tester) async {
      final colors = await paletteFor(tester, style, dark);
      double luminance(Color c) => c.computeLuminance();
      double contrast(Color a, Color b) {
        final l1 = luminance(a), l2 = luminance(b);
        final hi = l1 > l2 ? l1 : l2, lo = l1 > l2 ? l2 : l1;
        return (hi + 0.05) / (lo + 0.05);
      }

      for (final origin in ValueOrigin.values) {
        expect(contrast(colors.forOrigin(origin)!, colors.panel),
            greaterThan(3.0),
            reason: '$origin is unreadable on the JSON pane under $name');
      }
    });
  }

  testWidgets('the legend covers every origin, in one place', (tester) async {
    expect(ConversionColors.legend.map((e) => e.$1).toSet(),
        ValueOrigin.values.toSet(),
        reason: 'a state with no legend entry is a colour nobody can read');
  });
}
