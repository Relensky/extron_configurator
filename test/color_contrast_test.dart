import 'package:auris/auris.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_snack.dart';
import 'package:extron_configurator/contrast.dart';
import 'package:extron_configurator/main.dart';
import 'package:extron_configurator/project_spares_view.dart'
    show spareSectionFill;

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

  /// A far wider sweep than the named accents above: every hue at five
  /// lightnesses, plus black, white and mid grey.
  ///
  /// Five hand-picked accents were not enough. An audit over this grid found
  /// the scheme's OWN pairings failing on a third to a half of it — 45 of 180
  /// for onErrorContainer on errorContainer, 43 for onPrimaryContainer, 36 for
  /// onSecondaryContainer, 35 for onPrimary — which is why nothing in this app
  /// may paint one of those pairs directly, and why the guarantee below is
  /// about the HELPERS rather than about the scheme.
  Iterable<({String name, ThemeData theme})> everyAccent() sync* {
    final accents = <String>[
      '000000', 'FFFFFF', '808080',
      for (final hue in [0, 30, 60, 120, 180, 210, 270, 300])
        for (final light in [0.15, 0.30, 0.50, 0.70, 0.90])
          HSLColor.fromAHSL(1, hue.toDouble(), 0.75, light)
              .toColor()
              .toARGB32()
              .toRadixString(16)
              .substring(2)
              .toUpperCase(),
    ];
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
      reason: '$what is ${r.toStringAsFixed(2)}:1 on $where - needs $min:1',
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

      test('body text on every surface - ${t.name}', () {
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

      test('the error colour on an ordinary surface - ${t.name}', () {
        expectReadable('error', s.error, s.surface, t.name);
      });
    }
  });

  group('the helpers hold on EVERY accent, not just the likely ones', () {
    // One test rather than 180, because 180 named tests for one guarantee is a
    // test report nobody reads. The failure message names the combination.
    test('every fill the app paints on has a readable foreground', () {
      final failures = <String>[];
      for (final t in everyAccent()) {
        final s = t.theme.colorScheme;
        for (final entry in {
          'primary': s.primary,
          'primaryContainer': s.primaryContainer,
          'secondaryContainer': s.secondaryContainer,
          'errorContainer': s.errorContainer,
          'surface': s.surface,
          'surfaceContainerLow': s.surfaceContainerLow,
          'surfaceContainerHigh': s.surfaceContainerHigh,
          'surfaceContainerHighest': s.surfaceContainerHighest,
        }.entries) {
          for (final pick in {
            'foregroundOn': foregroundOn(s, entry.value),
            'errorOn': errorOn(s, entry.value),
            'readableOn': readableOn(entry.value),
          }.entries) {
            final r = contrastRatio(pick.value, entry.value);
            if (r < kContrastBody) {
              failures.add(
                '${pick.key} on ${entry.key} - ${t.name} - '
                '${r.toStringAsFixed(2)}:1',
              );
            }
          }
        }
      }
      expect(failures, isEmpty,
          reason: 'text this app paints is unreadable on '
              '${failures.length} fill/theme combinations');
    });

    test('the GENERATED schemes are not safe - which is why the pass exists',
        () {
      // Not a complaint about Material: a scheme's on-colours are generated
      // for its own generated palette, and this app hands it a colour a user
      // picked. Measured on the theme as its generator hands it over, before
      // legibleTheme has been near it — so the repair pass has to keep
      // proving it is repairing something.
      var bad = 0;
      for (final accent in ['2196F3', '4CAF50', 'FFC107', '607D8B']) {
        for (final style in ['classic', 'auris']) {
          for (final dark in [false, true]) {
            final s = RoomConfigApp.rawThemeFor(
              style,
              dark,
              accent,
              accent,
              '',
            ).colorScheme;
            for (final pair in [
              (s.onPrimary, s.primary),
              (s.onPrimaryContainer, s.primaryContainer),
              (s.onSecondaryContainer, s.secondaryContainer),
            ]) {
              if (contrastRatio(pair.$1, pair.$2) < kContrastBody) bad++;
            }
          }
        }
      }
      expect(bad, greaterThan(0),
          reason: 'if this ever reaches zero the pass could be retired');
    });

    test('...and the finished schemes are', () {
      // The other half, and the one that matters: after legibleTheme, every
      // pairing Material's own defaults reach for reads on every accent.
      final failures = <String>[];
      for (final t in everyAccent()) {
        final s = t.theme.colorScheme;
        for (final pair in {
          'onPrimary': (s.onPrimary, s.primary),
          'onSecondary': (s.onSecondary, s.secondary),
          'onTertiary': (s.onTertiary, s.tertiary),
          'onPrimaryContainer': (s.onPrimaryContainer, s.primaryContainer),
          'onSecondaryContainer': (
            s.onSecondaryContainer,
            s.secondaryContainer,
          ),
          'onTertiaryContainer': (s.onTertiaryContainer, s.tertiaryContainer),
          'onError': (s.onError, s.error),
          'onErrorContainer': (s.onErrorContainer, s.errorContainer),
          'onInverseSurface': (s.onInverseSurface, s.inverseSurface),
          'onSurface': (s.onSurface, s.surface),
        }.entries) {
          final r = contrastRatio(pair.value.$1, pair.value.$2);
          if (r < kContrastBody) {
            failures.add('${pair.key} - ${t.name} - ${r.toStringAsFixed(2)}:1');
          }
        }
      }
      expect(failures, isEmpty,
          reason: 'the scheme pairs Material paints without asking are '
              'unreadable on ${failures.length} combinations');
    });

    test('every button variant reads, on every accent', () {
      // The five the app uses, each measured the way the widget resolves it:
      // the theme's own foreground if it names one, Material's default role if
      // it does not, against the theme's own fill or - for a transparent
      // button - against the page, the card and a dialog.
      //
      // Before the pass this failed on 26 of the 60 pairings tried, all of
      // them on Classic: text, outlined and elevated buttons down at 1.5:1 in
      // light mode, tonal buttons at 2.7:1 in dark.
      const empty = <WidgetState>{};
      final failures = <String>[];
      for (final t in everyAccent()) {
        final s = t.theme.colorScheme;
        final theme = t.theme;

        Color? declared(ButtonStyle? style) =>
            style?.foregroundColor?.resolve(empty);
        Color? declaredFill(ButtonStyle? style) =>
            style?.backgroundColor?.resolve(empty);

        void check(String what, Color ink, List<Color> grounds) {
          for (final ground in grounds) {
            final r = contrastRatio(ink, ground);
            if (r < kContrastBody) {
              failures.add('$what - ${t.name} - ${r.toStringAsFixed(2)}:1');
            }
          }
        }

        final behind = [
          theme.scaffoldBackgroundColor,
          theme.cardColor,
          theme.dialogTheme.backgroundColor ?? s.surface,
        ];

        // Filled and tonal read their own scheme roles unless the theme names
        // a foreground for both of them.
        final filledStyle = theme.filledButtonTheme.style;
        check(
          'filled',
          declared(filledStyle) ?? s.onPrimary,
          [declaredFill(filledStyle) ?? s.primary],
        );
        check(
          'tonal',
          declared(filledStyle) ?? s.onSecondaryContainer,
          [declaredFill(filledStyle) ?? s.secondaryContainer],
        );
        check(
          'elevated',
          declared(theme.elevatedButtonTheme.style) ?? s.primary,
          [
            declaredFill(theme.elevatedButtonTheme.style) ??
                s.surfaceContainerLow,
          ],
        );
        for (final entry in {
          'text': theme.textButtonTheme.style,
          'outlined': theme.outlinedButtonTheme.style,
        }.entries) {
          check(entry.key, declared(entry.value) ?? s.primary, behind);
        }
      }
      expect(failures, isEmpty,
          reason: 'button labels are unreadable on ${failures.length} '
              'combinations');
    });
  });

  group('the pairings this app actually paints', () {
    for (final t in themes()) {
      final s = t.theme.colorScheme;

      test('small red text holds the STRONG bar - ${t.name}', () {
        // The scheme's own error red clears the 4.5:1 minimum on every fill
        // this app paints — by as little as 4.65:1, which is passing and
        // still hard to read at 12pt on a near-black panel. errorTextOn keeps
        // the red and lightens it until it clears 7:1.
        for (final bg in [
          s.surface,
          t.theme.cardColor,
          s.surfaceContainerLow,
          s.surfaceContainerHigh,
          t.theme.dialogTheme.backgroundColor ?? s.surface,
        ]) {
          expectReadable('errorTextOn', errorTextOn(s, bg), bg, t.name,
              min: kContrastStrong);
        }
      });

      test('a legible tone is still the colour it started as - ${t.name}', () {
        // The point of legibleTone over readableOn: red stays red. Measured
        // as hue, because "still red" is not something a ratio can say.
        final red = errorTextOn(s, s.surface);
        expect(
          (HSLColor.fromColor(red).hue - HSLColor.fromColor(s.error).hue)
              .abs(),
          lessThan(1.0),
          reason: 'the warning colour must not drift off its own hue',
        );
      });

      test('error text on a container fill - ${t.name}', () {
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

      test('foreground on a container fill - ${t.name}', () {
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

      test('the rail\'s selected row - ${t.name}', () {
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

      test('the project total, painted on the accent - ${t.name}', () {
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

      test('the top-level banner - ${t.name}', () {
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

      test('a failure snack bar - ${t.name}', () {
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

      test('an ordinary snack bar - ${t.name}', () {
        final ink = t.theme.snackBarTheme.contentTextStyle?.color ??
            s.onInverseSurface;
        final bg = t.theme.snackBarTheme.backgroundColor ?? s.inverseSurface;
        expectReadable('snack bar text', ink, bg, t.name);
      });

      test('the spares figures - ${t.name}', () {
        // Small coloured text, and the colour is TERTIARY — derived from an
        // accent somebody picked out of a wheel, with no promise about the
        // panels this app paints it on. Plain tertiary measured 2.2:1 on the
        // spares card with the Classic blue accent and 1.3:1 with cyan or
        // amber, all of them in light mode, which is what accentTextOn exists
        // to stop.
        for (final bg in [
          spareSectionFill(t.theme),
          t.theme.cardColor,
          s.surface,
        ]) {
          expectReadable('accentTextOn', accentTextOn(s, bg), bg, t.name,
              min: kContrastStrong);
        }
      });

      test('the spares accent is still the spares accent - ${t.name}', () {
        // The same bargain errorTextOn makes: legible, and still the colour it
        // started as. A spares figure that turned grey would stop being the
        // spares figure.
        final bg = spareSectionFill(t.theme);
        expect(
          (HSLColor.fromColor(accentTextOn(s, bg)).hue -
                  HSLColor.fromColor(s.tertiary).hue)
              .abs(),
          lessThan(1.0),
          reason: 'the spares colour must not drift off its own hue',
        );
      });

      test('a chip label survives being pressed - ${t.name}', () {
        // A selected chip DROPS whatever fill it was handed and paints the
        // theme's own, with the theme's own label on it. The master list's
        // warning chips carry a label coloured for their error fill, and that
        // colour must not follow them onto the selected fill — it measured
        // 3.7:1 on a light Classic blue and 1.7:1 on a dark amber when it did.
        //
        // Unselected: the app's own choice, on the fill the app set.
        expectReadable('warning chip', foregroundOn(s, s.errorContainer),
            s.errorContainer, t.name);

        // And the theme's own, in both states, resolved the way the widget
        // resolves it: the theme's label colour FOR THAT STATE where it names
        // one - Auris hands over a state-aware colour - and the scheme role
        // where it does not. Checked against what a real chip renders before
        // it was written down here.
        final chip = t.theme.chipTheme;
        Color labelFor(Set<WidgetState> states, Color fallback) {
          final declared = chip.labelStyle?.color;
          return declared == null
              ? fallback
              : WidgetStateProperty.resolveAs<Color>(declared, states);
        }

        expectReadable(
          'chip label',
          labelFor(const <WidgetState>{}, s.onSurfaceVariant),
          chip.backgroundColor ?? s.surfaceContainerLow,
          t.name,
        );
        expectReadable(
          'selected chip label',
          labelFor(
            const <WidgetState>{WidgetState.selected},
            s.onSecondaryContainer,
          ),
          chip.selectedColor ?? s.secondaryContainer,
          t.name,
        );
      });

      test('icons that carry meaning - ${t.name}', () {
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

      test('the status colours on the Raw JSON header - ${t.name}', () {
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

      test('the invalid-JSON banner - ${t.name}', () {
        expectReadable('banner text', errorOn(s, s.errorContainer),
            s.errorContainer, t.name);
      });

      test('the app bar title - ${t.name}', () {
        final bar = t.theme.appBarTheme.backgroundColor ?? s.surface;
        final ink = t.theme.appBarTheme.foregroundColor ?? s.onSurface;
        expectReadable('app bar text', ink, bar, t.name);
      });
    }
  });
}
