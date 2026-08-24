import 'package:flutter/material.dart';

import 'contrast.dart';

/// ============================================================================
///  THE PASS THAT MAKES A GENERATED THEME READABLE
/// ============================================================================
///  Both theme families are generated around an accent SOMEBODY PICKS OUT OF A
///  WHEEL, and neither generator measures the result. Material's own defaults
///  then take the scheme at its word: a filled button paints `primary` and
///  writes `onPrimary` on it, a tonal button paints `secondaryContainer` and
///  writes `onSecondaryContainer`, and a text button writes `primary` straight
///  onto the page.
///
///  Measured across the accents this app ships in its picker, that produced
///  buttons nobody could read:
///
///    * CLASSIC LIGHT — the accent is a mid-tone, the page is white, and the
///      label is the accent. Text, outlined and elevated buttons landed at
///      1.5:1 to 4.4:1 on every accent tried; filled buttons at 2.8:1 on green
///      and 3.1:1 on blue.
///    * CLASSIC DARK — tonal buttons at 2.7:1 on blue, 3.2:1 on red and slate.
///    * AURIS — near enough clean, one elevated button at 4.1:1.
///
///  So the theme is measured after it is generated and before it is used. Two
///  kinds of repair, because there are two kinds of failure:
///
///    1. THE SCHEME'S OWN PAIRS. `onX` written on `X` — what Material's
///       defaults reach for, and the only lever that can separate a filled
///       button from a tonal one, since the two share a single
///       [FilledButtonTheme] and differ only in which roles they read. Fixed
///       with [readableOn], which keeps the generator's answer wherever it
///       reads and falls back to black or white where it does not — the same
///       two colours Material would have chosen itself.
///    2. INK ON A SURFACE. A text button's label is the accent on the page
///       behind it, and there is no `on` role for that. Fixed with
///       [legibleTone], which KEEPS THE HUE and moves the lightness: a blue
///       button that turned grey would stop being the app's blue, and the
///       point is a readable blue rather than no blue.
///
///  NOTHING MOVES THAT ALREADY READS. Every repair here is measured first and
///  skipped when it passes, so a theme that was fine is returned untouched —
///  which is most of Auris, and all four themes on most accents.
/// ============================================================================

/// [theme], with every foreground it paints measured against the fill it is
/// painted on and moved only where it falls short.
ThemeData legibleTheme(ThemeData theme) {
  final scheme = _legibleScheme(theme.colorScheme);
  final fixed = theme.copyWith(colorScheme: scheme);

  // WHAT SITS BEHIND A TRANSPARENT BUTTON. A text button is used on the page,
  // inside a card and inside a dialog, and its one label colour has to read on
  // all three — so the tone is walked against each in turn rather than against
  // whichever one somebody happened to think of.
  final behind = <Color>{
    theme.scaffoldBackgroundColor,
    theme.cardColor,
    theme.dialogTheme.backgroundColor ?? scheme.surface,
    scheme.surface,
  }.toList();

  return fixed.copyWith(
    // Filled and tonal share this theme and differ only in the scheme roles
    // they read, so a foreground written here would paint both the same. It is
    // only touched when the theme already sets one explicitly - Auris does,
    // Classic leaves it to Material - and then it is measured against the fill
    // that same style sets.
    filledButtonTheme: FilledButtonThemeData(
      style: _measuredStyle(
        theme.filledButtonTheme.style,
        fill: theme.filledButtonTheme.style?.backgroundColor
            ?.resolve(const <WidgetState>{}),
        behind: behind,
        onlyWhenExplicit: true,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: _measuredStyle(
        theme.elevatedButtonTheme.style,
        fill: theme.elevatedButtonTheme.style?.backgroundColor
                ?.resolve(const <WidgetState>{}) ??
            // Material's own default for an elevated button in M3.
            scheme.surfaceContainerLow,
        fallbackInk: scheme.primary,
        behind: behind,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: _measuredStyle(
        theme.textButtonTheme.style,
        fill: null,
        fallbackInk: scheme.primary,
        behind: behind,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: _measuredStyle(
        theme.outlinedButtonTheme.style,
        fill: null,
        fallbackInk: scheme.primary,
        behind: behind,
      ),
    ),
    // A CHIP CHANGES FILL WHEN IT IS PRESSED, and a theme that pins its label
    // colours pins them for both states. Auris does, and on a black accent
    // that left a near-black label on a near-black selected chip: 1.06:1.
    //
    // Only the colours the theme actually names are touched. Where it names
    // none - Classic names none - the chip reads `onSurfaceVariant` and
    // `onSecondaryContainer` off the scheme, which the pass above has already
    // been through.
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: _measuredChipLabel(
        theme.chipTheme.labelStyle,
        selected: theme.chipTheme.selectedColor ?? scheme.secondaryContainer,
        plain: theme.chipTheme.backgroundColor ?? scheme.surfaceContainerLow,
      ),
    ),
  );
}

/// A chip's label colour, measured against the fill of the state it is drawn
/// in — and still one colour per state afterwards.
///
/// A CHIP LABEL IS STATE-AWARE OR IT IS NOTHING. Auris hands its label colour
/// over as a [WidgetStateColor] that answers one thing selected and another
/// unselected, and the selected fill is not the unselected one — so measuring
/// the colour this getter happens to return and writing back a flat
/// replacement loses the state it was carrying. That is not a hypothetical:
/// doing it made selected chips render the UNSELECTED colour, a repair that
/// broke the thing it was measuring.
///
/// So each state is resolved, measured against the fill THAT state paints, and
/// put back as a state-aware colour. A theme that names no colour is left
/// alone: its chips read the scheme roles, which [_legibleScheme] has already
/// been through.
TextStyle? _measuredChipLabel(
  TextStyle? style, {
  required Color selected,
  required Color plain,
}) {
  final declared = style?.color;
  if (declared == null) return style;

  const picked = <WidgetState>{WidgetState.selected};
  const plainStates = <WidgetState>{};

  Color declaredFor(Set<WidgetState> states) =>
      WidgetStateProperty.resolveAs<Color>(declared, states);

  Color legibleFor(Set<WidgetState> states) => legibleTone(
        declaredFor(states),
        states.contains(WidgetState.selected) ? selected : plain,
      );

  if (legibleFor(picked) == declaredFor(picked) &&
      legibleFor(plainStates) == declaredFor(plainStates)) {
    return style;
  }
  return style!.copyWith(color: WidgetStateColor.resolveWith(legibleFor));
}

/// The scheme's own `onX`/`X` pairs, each kept where it reads and replaced
/// where it does not.
///
/// [readableOn] rather than [legibleTone] on purpose: these are labels ON a
/// fill, where black and white are the right answers and are what Material
/// picks itself. Keeping the hue matters for a coloured label on a neutral
/// page; it does not for white text on a coloured button.
ColorScheme _legibleScheme(ColorScheme s) => s.copyWith(
      onPrimary: readableOn(s.primary, prefer: [s.onPrimary]),
      onSecondary: readableOn(s.secondary, prefer: [s.onSecondary]),
      onTertiary: readableOn(s.tertiary, prefer: [s.onTertiary]),
      onPrimaryContainer:
          readableOn(s.primaryContainer, prefer: [s.onPrimaryContainer]),
      onSecondaryContainer:
          readableOn(s.secondaryContainer, prefer: [s.onSecondaryContainer]),
      onTertiaryContainer:
          readableOn(s.tertiaryContainer, prefer: [s.onTertiaryContainer]),
      onError: readableOn(s.error, prefer: [s.onError]),
      onErrorContainer:
          readableOn(s.errorContainer, prefer: [s.onErrorContainer]),
      onInverseSurface:
          readableOn(s.inverseSurface, prefer: [s.onInverseSurface]),
      onSurface: readableOn(s.surface, prefer: [s.onSurface]),
      // Measured against the DEEPEST container rather than against surface:
      // this is the role the app writes on every one of them, and the highest
      // container is the one it is closest to.
      onSurfaceVariant: readableOn(
        s.surfaceContainerHighest,
        prefer: [s.onSurfaceVariant],
      ),
    );

/// One button style with its enabled ink measured against what it is painted
/// on.
///
/// [fill] is the button's own fill, or null for a transparent one — then the
/// ink is measured against everything in [behind]. [fallbackInk] is what
/// Material would use when the theme names no foreground of its own.
///
/// [onlyWhenExplicit] returns the style untouched unless the theme already
/// names a foreground, which is how the shared filled/tonal theme avoids
/// flattening the difference between the two variants.
///
/// DISABLED IS LEFT ALONE. A disabled button is meant to be faint, and the
/// resolver hands that state straight back to whatever was going to answer it
/// — returning null where nothing did, so Material's own default still gets
/// its turn.
ButtonStyle? _measuredStyle(
  ButtonStyle? base, {
  required Color? fill,
  required List<Color> behind,
  Color? fallbackInk,
  bool onlyWhenExplicit = false,
}) {
  final existing = base?.foregroundColor;
  final declared = existing?.resolve(const <WidgetState>{});
  if (onlyWhenExplicit && declared == null) return base;

  final ink = declared ?? fallbackInk;
  if (ink == null) return base;

  // An opaque fill is the only thing the ink sits on. A transparent one means
  // whatever the button was dropped onto, so every one of those has to clear.
  final grounds = fill == null || fill.a == 0 ? behind : [fill];
  var legible = ink;
  for (final ground in grounds) {
    legible = legibleTone(legible, ground);
  }
  if (legible == ink) return base;

  Color? resolve(Set<WidgetState> states) =>
      states.contains(WidgetState.disabled)
          ? existing?.resolve(states)
          : legible;

  return (base ?? const ButtonStyle()).copyWith(
    foregroundColor: WidgetStateProperty.resolveWith(resolve),
    // The icon follows the label. Left out, an icon button keeps reading the
    // default — which is the colour this pass just moved off.
    iconColor: WidgetStateProperty.resolveWith(resolve),
  );
}
