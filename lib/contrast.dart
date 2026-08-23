import 'dart:math' as math;

import 'package:flutter/material.dart';

/// ============================================================================
///  READABLE TEXT, WHATEVER THE THEME IS SET TO
/// ============================================================================
///  This app has four themes — Classic and Auris, each light and dark — and
///  Classic's accent is a colour the user picks out of a wheel. That last part
///  is why picking foreground colours by hand does not work here: there is no
///  fixed palette to check against, because the palette is whatever somebody
///  chose this morning.
///
///  Measuring it is the only honest answer. [contrastRatio] is the WCAG
///  formula; [readableOn] takes the colours a design would LIKE to use and
///  hands back the first one that is actually readable on the background it is
///  going on, falling back to plain black or white when none of them are.
///
///  WHAT THE NUMBERS MEAN. WCAG asks for 4.5:1 for body text and 3:1 for large
///  text and for icons that carry meaning. Those are the two thresholds below,
///  and they are what the contrast test asserts.
///
///  THIS IS NOT FOR THE DRAWINGS. Cable colours, conversion highlights and plan
///  annotations are a fixed vocabulary — HDMI is that blue on every machine,
///  and a run that changed colour with the theme would stop matching the legend
///  and the printout. They are deliberately left alone.
/// ============================================================================

/// WCAG relative luminance.
double _relativeLuminance(Color c) {
  double channel(double v) => v <= 0.03928
      ? v / 12.92
      : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) +
      0.7152 * channel(c.g) +
      0.0722 * channel(c.b);
}

/// The WCAG contrast ratio between two colours: 1 (identical) to 21 (black on
/// white). Order does not matter.
///
/// Alpha is ignored — both colours are taken as painted. Everything this is
/// used for is an opaque fill under opaque text.
double contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// WCAG AA for body text.
const double kContrastBody = 4.5;

/// WCAG AA for large text and for icons that carry meaning rather than
/// decoration.
const double kContrastLarge = 3.0;

/// The first of [prefer] that reads clearly on [background], or black/white.
///
/// Written as a preference list rather than a single choice because the point
/// is to keep the design's intent where the theme allows it: "the error colour
/// if you can read it, the container's own on-colour otherwise" says what is
/// wanted and what to do when the theme cannot supply it. A caller that simply
/// wants *something* readable passes nothing.
Color readableOn(
  Color background, {
  List<Color> prefer = const [],
  double minRatio = kContrastBody,
}) {
  for (final c in prefer) {
    if (contrastRatio(c, background) >= minRatio) return c;
  }
  // Nothing offered works. Black or white always clears 4.5:1 against
  // something — one of them is at least 4.5 against every colour there is —
  // so this cannot fail, and it is better than painting text nobody can read.
  return contrastRatio(Colors.black, background) >=
          contrastRatio(Colors.white, background)
      ? Colors.black
      : Colors.white;
}

/// WCAG AAA for body text — the bar this app holds SMALL COLOURED text to.
///
/// Not pedantry. 4.5:1 is the minimum at which body text is legible for most
/// people in good conditions; a warning set in 12pt red at 4.8:1 on a near
/// black panel is the case where "passes" and "readable" part company, and it
/// is the one people actually complain about.
const double kContrastStrong = 7.0;

/// [color] moved along its own lightness until it reads on [background].
///
/// KEEPS THE HUE. That is the whole point: a warning that stopped being red
/// would stop meaning "warning", so this does not fall back to black or white
/// while any red will do — it lightens the red on a dark ground and darkens it
/// on a light one, a step at a time, and stops the moment it clears the bar.
/// Only if the colour runs out of lightness in both directions does
/// [readableOn] take over, because unreadable-and-red is worse than readable.
///
/// Both directions are tried and the NEARER answer wins, so a colour that is
/// already close keeps its character.
Color legibleTone(
  Color color,
  Color background, {
  double minRatio = kContrastStrong,
}) {
  if (contrastRatio(color, background) >= minRatio) return color;

  final hsl = HSLColor.fromColor(color);
  const step = 0.02;
  for (double delta = step; delta <= 1.0; delta += step) {
    for (final candidate in [
      if (hsl.lightness + delta <= 1.0)
        hsl.withLightness(hsl.lightness + delta).toColor(),
      if (hsl.lightness - delta >= 0.0)
        hsl.withLightness(hsl.lightness - delta).toColor(),
    ]) {
      if (contrastRatio(candidate, background) >= minRatio) return candidate;
    }
  }
  return readableOn(background, prefer: [color], minRatio: minRatio);
}

/// The error colour for small TEXT on [background], held to [kContrastStrong].
///
/// [errorOn] answers "which of the scheme's error roles reads here", which is
/// the right question for a fill somebody chose. This answers the harder one —
/// "make red legible here" — and is what the small red labels use.
Color errorTextOn(ColorScheme scheme, Color background) =>
    legibleTone(scheme.error, background);

/// The error colour to paint ON a container fill.
///
/// The obvious `colorScheme.error` is the wrong answer on a container and it
/// is wrong loudly: on this app's four themes it measures between 1.3:1 and
/// 5.6:1 against errorContainer, which is to say it is illegible on three of
/// them. `onErrorContainer` is the pair the scheme actually guarantees, and
/// where even that is thin the fallback takes over.
Color errorOn(ColorScheme scheme, Color background) => readableOn(
      background,
      prefer: [scheme.onErrorContainer, scheme.error, scheme.onSurface],
    );

/// A foreground for a container fill, keeping the scheme's own on-colour when
/// it is readable.
Color foregroundOn(ColorScheme scheme, Color background) => readableOn(
      background,
      prefer: [
        // The on-colours, cheapest first: whichever of these the caller's
        // background actually is, its partner is tried before anything else.
        scheme.onSurface,
        scheme.onSurfaceVariant,
        scheme.onPrimaryContainer,
        scheme.onSecondaryContainer,
        scheme.onErrorContainer,
      ],
    );

/// A "this is fine" colour that reads on [background].
///
/// Material 3 has no success role — it has primary, secondary and tertiary,
/// none of which mean "valid" — so the green is supplied here and then
/// MEASURED, which is the part that was missing. Plain `Colors.green` is
/// 2.8:1 on a white surface: under the 3:1 an icon needs, let alone the 4.5:1
/// for text beside it.
///
/// Dark tone first, then light: that ordering picks the right one for a light
/// surface and a dark surface without either being named.
Color successOn(Color background, {double minRatio = kContrastBody}) =>
    readableOn(
      background,
      prefer: const [Color(0xFF2E7D32), Color(0xFF81C784)],
      minRatio: minRatio,
    );

/// A "look at this" colour that reads on [background] — the same bargain as
/// [successOn], for the state that is neither fine nor broken.
Color warningOn(Color background, {double minRatio = kContrastBody}) =>
    readableOn(
      background,
      prefer: const [Color(0xFFB35C00), Color(0xFFFFB74D)],
      minRatio: minRatio,
    );

/// True when [foreground] on [background] clears AA for body text.
bool readsAsBody(Color foreground, Color background) =>
    contrastRatio(foreground, background) >= kContrastBody;
