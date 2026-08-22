import 'package:auris/auris.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_snack.dart';
import 'package:extron_configurator/contrast.dart';
import 'package:extron_configurator/main.dart';

/// Text somebody can actually read, in every theme this app can be set to.
///
/// There are four — Classic and Auris, each light and dark — and Classic's
/// accent is a colour the user picks out of a wheel, so the palette is not a
/// fixed thing that can be eyeballed once. Every pairing below is measured, at
/// several accents, against the WCAG thresholds: 4.5:1 for body text, 3:1 for
/// large text and for icons that carry meaning.
///
/// The drawings are deliberately not in scope. Cable colours, conversion
/// highlights and plan annotations are a fixed vocabulary — HDMI is that blue
/// on every machine, and a run that changed colour with the theme would stop
/// matching its legend and its printout.
void main() {
  /// Every theme the app can be in, at a spread of accents including the ones
  /// most likely to be picked and the two that are hardest on contrast.
  Iterable<({String name, ThemeData theme})> themes() sync* {
    const accents = ['2196F3', 'F0A500', '000000', 'FFFFFF', '4CAF50'];
    for (final style in ['classic', 'auris']) {
      for (final dark in [false, true]) {
        for (final accent in accents) {
          yield (
            name: '$style ${dark ? 'dark' : 'light'} #$accent',
            theme: RoomConfigApp.themeFor(style, dark, accent, accent, ''),
          );
        }
      }
    }
  }

  void expectReadable(
    String what,
    Color fg,
    Color bg,
    String where, {
    double min = kContrastBody,
  }) {
    final r = contrastRatio(fg, bg);
    expect(
      r,
      greaterThanOrEqualTo(min),
      reason: '$what is ${r.toStringAsFixed(2)}:1 on $where — needs $min:1',
    );
  }

  group('the helper itself', () {
    test('black on white is 21:1 and a colour on itself is 1:1', () {
      expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
      expect(contrastRatio(Colors.red, Colors.red), closeTo(1, 0.001));
      // Order does not matter.
      expect(
        contrastRatio(Colors.black, Colors.white),
        closeTo(contrastRatio(Colors.white, Colors.black), 0.001),
      );
    });

    test('readableOn keeps a preference that works', () {
      expect(
        readableOn(Colors.white, prefer: [Colors.black, Colors.yellow]),
        Colors.black,
      );
    });

    test('readableOn skips a preference that does not', () {
      // Yellow on white is about 1.07:1. It must not be chosen.
      final picked = readableOn(Colors.white, prefer: [Colors.yellow]);
      expect(picked, isNot(Colors.yellow));
      expect(contrastRatio(picked, Colors.white),
          greaterThanOrEqualTo(kContrastBody));
    });

    test('readableOn always returns something readable, for any colour', () {
      // The fallback is what makes this usable on a user-chosen accent: there
      // is no colour it can be handed that leaves it without an answer.
      for (var r = 0; r < 256; r += 17) {
        for (var g = 0; g < 256; g += 17) {
          for (var b = 0; b < 256; b += 17) {
            final bg = Color.fromARGB(255, r, g, b);
            expect(
              contrastRatio(readableOn(bg), bg),
              greaterThanOrEqualTo(kContrastBody),
              reason: 'nothing readable found on $bg',
            );
          }
        }
      }
    });
  });

  group('the theme reads', () {
    for (final t in themes()) {
      final s = t.theme.colorScheme;

      test('body text on every surface — ${t.name}', () {
        expectReadable('onSurface', s.onSurface, s.surface, t.name);
        for (final bg in [
          s.surface,
          s.surfaceContainerLowest,
          s.surfaceContainerLow,
          s.surfaceContainer,
          s.surfaceContainerHigh,
          s.surfaceContainerHighest,
        ]) {
          expectReadable('onSurfaceVariant', s.onSurfaceVariant, bg, t.name);
        }
      });

      test('the error colour on an ordinary surface — ${t.name}', () {
        expectReadable('error', s.error, s.surface, t.name);
      });
    }
  });

  group('the pairings this app actually paints', () {
    for (final t in themes()) {
      final s = t.theme.colorScheme;

      test('error text on a container fill — ${t.name}', () {
        // colorScheme.error straight onto a container measures as low as
        // 1.3:1 on these themes. errorOn is what the app calls instead.
        for (final bg in [
          s.errorContainer,
          s.primaryContainer,
          s.surfaceContainerHigh,
          s.surfaceContainerLow,
        ]) {
          expectReadable('errorOn', errorOn(s, bg), bg, t.name);
        }
      });

      test('foreground on a container fill — ${t.name}', () {
        for (final bg in [
          s.primaryContainer,
          s.secondaryContainer,
          s.errorContainer,
          s.surfaceContainerLow,
          s.surfaceContainerHigh,
        ]) {
          expectReadable('foregroundOn', foregroundOn(s, bg), bg, t.name);
        }
      });

      test('the rail\'s selected row — ${t.name}', () {
        // What nav_rail.dart computes for the band behind the current tab.
        //
        // The band comes from a DIFFERENT role in the two families, because
        // they put the accent in different places: Classic derives its
        // secondary from the accent, Auris never recolors its slate. The same
        // split has to be here, or this measures a pairing the app does not
        // paint.
        final auris = t.theme.extension<AurisScheme>() != null;
        final bg = auris ? s.primaryContainer : s.secondaryContainer;
        final ink = readableOn(
          bg,
          prefer: [
            auris ? s.onPrimaryContainer : s.onSecondaryContainer,
            s.onSurface,
          ],
        );
        expectReadable('rail label', ink, bg, t.name);
      });

      test('the project total, painted on the accent — ${t.name}', () {
        // _TotalChip's emphasis fill IS primaryContainer, so on the Classic
        // theme it is whatever colour somebody picked out of a wheel. The
        // figure used to be drawn in the page's ink, which went dark-on-dark
        // the moment that colour was a dark one.
        final bg = s.primaryContainer;
        final ink = readableOn(bg, prefer: [s.onPrimaryContainer, s.onSurface]);
        expectReadable('project total', ink, bg, t.name);

        // The label is faded, then re-measured — 75% of an ink that only just
        // cleared the threshold does not clear it.
        final label = readableOn(
          bg,
          prefer: [Color.alphaBlend(ink.withValues(alpha: 0.75), bg), ink],
          minRatio: kContrastLarge,
        );
        expectReadable('project total label', label, bg, t.name,
            min: kContrastLarge);
      });

      test('the top-level banner — ${t.name}', () {
        final bg = s.surfaceContainerHighest;
        expectReadable(
          'job name',
          readableOn(bg, prefer: [
            t.theme.textTheme.bodySmall?.color ?? s.onSurfaceVariant,
            s.onSurface,
          ]),
          bg,
          t.name,
        );
        expectReadable('unsaved marker', errorOn(s, bg), bg, t.name);
        expectReadable(
          'the gear',
          readableOn(bg,
              prefer: [s.onSurfaceVariant, s.onSurface],
              minRatio: kContrastLarge),
          bg,
          t.name,
          min: kContrastLarge,
        );
      });

      test('a failure snack bar — ${t.name}', () {
        // The fill is chosen against the bar's own text colour, which is what
        // makes this pass where a flat Colors.red did not.
        final ink = t.theme.snackBarTheme.contentTextStyle?.color ??
            s.onInverseSurface;
        expectReadable(
          'snack bar text',
          ink,
          snackErrorFillFor(t.theme),
          t.name,
        );
      });

      test('an ordinary snack bar — ${t.name}', () {
        final ink = t.theme.snackBarTheme.contentTextStyle?.color ??
            s.onInverseSurface;
        final bg = t.theme.snackBarTheme.backgroundColor ?? s.inverseSurface;
        expectReadable('snack bar text', ink, bg, t.name);
      });

      test('icons that carry meaning — ${t.name}', () {
        // 3:1 rather than 4.5 — the threshold for a graphic rather than for
        // body text. This is the check plain `tertiary` failed at 2.1:1.
        final surface = s.surface;
        expectReadable(
          'info icon',
          readableOn(
            surface,
            prefer: [s.tertiary, s.onSurfaceVariant],
            minRatio: kContrastLarge,
          ),
          surface,
          t.name,
          min: kContrastLarge,
        );
      });

      test('the status colours on the Raw JSON header — ${t.name}', () {
        // Icon plus wording carry the state; the colour only reinforces it.
        // It still has to be visible, at the 3:1 an icon needs.
        final bg = s.surface;
        expectReadable('success icon', successOn(bg, minRatio: kContrastLarge),
            bg, t.name, min: kContrastLarge);
        expectReadable('warning icon', warningOn(bg, minRatio: kContrastLarge),
            bg, t.name, min: kContrastLarge);
        expectReadable(
          'error icon',
          readableOn(bg, prefer: [s.error], minRatio: kContrastLarge),
          bg,
          t.name,
          min: kContrastLarge,
        );
        // And as body text beside the icon, at the stricter threshold.
        expectReadable('success text', successOn(bg), bg, t.name);
        expectReadable('warning text', warningOn(bg), bg, t.name);
      });

      test('the invalid-JSON banner — ${t.name}', () {
        expectReadable('banner text', errorOn(s, s.errorContainer),
            s.errorContainer, t.name);
      });

      test('the app bar title — ${t.name}', () {
        final bar = t.theme.appBarTheme.backgroundColor ?? s.surface;
        final ink = t.theme.appBarTheme.foregroundColor ?? s.onSurface;
        expectReadable('app bar text', ink, bar, t.name);
      });
    }
  });
}
