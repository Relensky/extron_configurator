import 'dart:math' as math;

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
///       two colors Material would have chosen itself.
///    2. INK ON A SURFACE. A text button's label is the accent on the page
///       behind it, and there is no `on` role for that. Fixed with
///       [legibleTone], which KEEPS THE HUE and moves the lightness: a blue
///       button that turned gray would stop being the app's blue, and the
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
  // inside a card and inside a dialog, and its one label color has to read on
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
    // colors pins them for both states. Auris does, and on a black accent
    // that left a near-black label on a near-black selected chip: 1.06:1.
    //
    // Only the colors the theme actually names are touched. Where it names
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
    // ------------------------------------------------------------------
    //  THE FOREGROUNDS THE THEME NAMES ON A FILL THE THEME ALSO NAMES
    // ------------------------------------------------------------------
    //  Everything above is about the scheme and about buttons. These are the
    //  component themes that carry their OWN ink on their OWN fill, which
    //  nothing above touches - so a generator that got one of them wrong got
    //  it wrong all the way to the screen. Measured across every accent in the
    //  picker plus a grid of hues at five lightnesses, the failures were real
    //  and several were total: an app bar icon at 1.02:1, a list-tile icon at
    //  1.00:1, a nav-rail label at 1.02:1, a tab label at 1.03:1.
    //
    //  [legibleTone] rather than [readableOn] throughout: these are the app's
    //  own colors on the app's own furniture, and an accent that turned white
    //  would stop being the accent. The tone keeps the hue and moves the
    //  lightness only as far as it has to.
    appBarTheme: _measuredAppBar(theme.appBarTheme, scheme),
    tabBarTheme: _measuredTabBar(
      theme.tabBarTheme,
      theme.appBarTheme.backgroundColor ?? scheme.surface,
    ),
    snackBarTheme: _measuredSnackBar(theme.snackBarTheme, scheme),
    floatingActionButtonTheme: _measuredFab(
      theme.floatingActionButtonTheme,
      scheme,
    ),
    listTileTheme: _measuredListTile(theme.listTileTheme, scheme, behind),
    navigationRailTheme: _measuredRail(theme.navigationRailTheme, scheme),
    inputDecorationTheme: _measuredField(theme.inputDecorationTheme, behind),
  );
}

/// A color that reads on EVERY ground in [grounds].
///
/// The same question the transparent buttons ask: a list tile is used on the
/// page, in a card and in a dialog, and a field is dropped into all three too.
/// Measuring against whichever one the theme happens to name leaves the other
/// two to chance - which is how a tile's ink came out fine on `surface` and
/// unreadable on the card the app actually draws it in.
///
/// WALKED TO A FIXED POINT, not once per ground. [legibleTone] moves a color
/// the NEARER way, so fixing it against a light ground can push it back under
/// the bar on a dark one - and one pass down a list of four leaves whichever
/// ground came first to chance. Repeating until nothing moves settles it,
/// which on grounds this close together takes two passes at most.
///
/// If it still will not settle, black or white takes over against the ground
/// it reads worst on. Losing the hue is a real loss; losing the text is worse,
/// and that is the same trade [legibleTone] makes at the end of its own walk.
Color? _inkOnAll(Color? ink, List<Color> grounds, {double min = kContrastBody}) {
  if (ink == null || grounds.isEmpty) return ink;

  var out = ink;
  for (var pass = 0; pass < 6; pass++) {
    var moved = false;
    for (final ground in grounds) {
      final next = legibleTone(out, ground, minRatio: min);
      if (next != out) {
        out = next;
        moved = true;
      }
    }
    if (!moved) return out;
  }

  var worst = grounds.first;
  for (final ground in grounds) {
    if (contrastRatio(out, ground) < contrastRatio(out, worst)) worst = ground;
  }
  return readableOn(worst, prefer: [out], minRatio: min);
}

TextStyle? _styleOnAll(TextStyle? style, List<Color> grounds,
        {double min = kContrastBody}) =>
    style?.color == null
        ? style
        : style!.copyWith(color: _inkOnAll(style.color, grounds, min: min));

/// A color moved onto [ground] only if it does not already read there.
Color? _ink(Color? ink, Color ground, {double min = kContrastBody}) =>
    ink == null ? null : legibleTone(ink, ground, minRatio: min);

/// A text style whose color has been measured against [ground].
TextStyle? _inkStyle(TextStyle? style, Color ground,
        {double min = kContrastBody}) =>
    style?.color == null
        ? style
        : style!.copyWith(color: _ink(style.color, ground, min: min));

/// The bar across the top: its title, its ink and both sets of icons, all
/// measured against the fill the bar itself paints.
AppBarThemeData _measuredAppBar(AppBarThemeData bar, ColorScheme scheme) {
  final ground = bar.backgroundColor ?? scheme.surface;
  return bar.copyWith(
    foregroundColor: _ink(bar.foregroundColor, ground),
    titleTextStyle: _inkStyle(bar.titleTextStyle, ground),
    toolbarTextStyle: _inkStyle(bar.toolbarTextStyle, ground),
    // Icons carry meaning rather than words, so they clear the large-text bar
    // rather than the body one - the same rule the rest of the app uses.
    iconTheme: bar.iconTheme?.color == null
        ? bar.iconTheme
        : bar.iconTheme!.copyWith(
            color: _ink(bar.iconTheme!.color, ground, min: kContrastLarge),
          ),
    actionsIconTheme: bar.actionsIconTheme?.color == null
        ? bar.actionsIconTheme
        : bar.actionsIconTheme!.copyWith(
            color:
                _ink(bar.actionsIconTheme!.color, ground, min: kContrastLarge),
          ),
  );
}

/// Tabs sit on the app bar, so that is what their labels are measured on.
///
/// The unselected label is meant to be quieter and is held to the large bar;
/// quieter is not the same as absent, and 1.03:1 is absent.
TabBarThemeData _measuredTabBar(TabBarThemeData tabs, Color ground) =>
    tabs.copyWith(
      labelColor: _ink(tabs.labelColor, ground),
      unselectedLabelColor:
          _ink(tabs.unselectedLabelColor, ground, min: kContrastLarge),
      labelStyle: _inkStyle(tabs.labelStyle, ground),
      unselectedLabelStyle:
          _inkStyle(tabs.unselectedLabelStyle, ground, min: kContrastLarge),
    );

/// A snack bar is a message somebody has a few seconds to read, and its action
/// is the only thing on it that can be pressed.
SnackBarThemeData _measuredSnackBar(SnackBarThemeData bar, ColorScheme scheme) {
  final ground = bar.backgroundColor ?? scheme.inverseSurface;
  return bar.copyWith(
    contentTextStyle: _inkStyle(bar.contentTextStyle, ground),
    actionTextColor: _ink(bar.actionTextColor, ground),
  );
}

FloatingActionButtonThemeData _measuredFab(
  FloatingActionButtonThemeData fab,
  ColorScheme scheme,
) {
  final ground = fab.backgroundColor ?? scheme.primaryContainer;
  return fab.copyWith(
    foregroundColor: _ink(fab.foregroundColor, ground, min: kContrastLarge),
  );
}

/// A list tile is used on the page, in a card and in a dialog, so its ink has
/// to clear all three - unless the theme pins a fill of its own, in which case
/// that is the only thing it ever sits on.
ListTileThemeData _measuredListTile(
  ListTileThemeData tile,
  ColorScheme scheme,
  List<Color> behind,
) {
  final grounds = tile.tileColor == null ? behind : [tile.tileColor!];
  return tile.copyWith(
    textColor: _inkOnAll(tile.textColor, grounds),
    iconColor: _inkOnAll(tile.iconColor, grounds, min: kContrastLarge),
  );
}

/// The words around a text field: its label, its hint, its helper and the
/// prefix and suffix inside it.
///
/// THE HINT IS THE ONE THAT MATTERS. It is the only text in this app that is
/// meant to be faint, which is exactly why it is the one a generator lets
/// drift below readable - and on the cost sheet a hint is not decoration, it
/// is the catalog price the row resolved to. Held to the large-text bar, which
/// is quiet without being absent.
InputDecorationThemeData _measuredField(
  InputDecorationThemeData field,
  List<Color> behind,
) {
  // A FILLED FIELD PAINTS ITS OWN GROUND. Auris fills; Classic does not, and
  // there the words inside a field sit on whatever the field was dropped onto
  // - the page, a card or a dialog - so all three have to clear.
  final fill = field.fillColor;
  final grounds = field.filled && fill != null ? [fill] : behind;
  return field.copyWith(
    labelStyle: _styleOnAll(field.labelStyle, grounds),
    floatingLabelStyle: _styleOnAll(field.floatingLabelStyle, grounds),
    hintStyle: _styleOnAll(field.hintStyle, grounds, min: kContrastLarge),
    helperStyle: _styleOnAll(field.helperStyle, grounds, min: kContrastLarge),
    prefixStyle: _styleOnAll(field.prefixStyle, grounds),
    suffixStyle: _styleOnAll(field.suffixStyle, grounds),
    counterStyle: _styleOnAll(field.counterStyle, grounds, min: kContrastLarge),
  );
}

NavigationRailThemeData _measuredRail(
  NavigationRailThemeData rail,
  ColorScheme scheme,
) {
  final ground = rail.backgroundColor ?? scheme.surface;
  return rail.copyWith(
    selectedLabelTextStyle: _inkStyle(rail.selectedLabelTextStyle, ground),
    unselectedLabelTextStyle:
        _inkStyle(rail.unselectedLabelTextStyle, ground, min: kContrastLarge),
    selectedIconTheme: rail.selectedIconTheme?.color == null
        ? rail.selectedIconTheme
        : rail.selectedIconTheme!.copyWith(
            color: _ink(
              rail.selectedIconTheme!.color,
              ground,
              min: kContrastLarge,
            ),
          ),
    unselectedIconTheme: rail.unselectedIconTheme?.color == null
        ? rail.unselectedIconTheme
        : rail.unselectedIconTheme!.copyWith(
            color: _ink(
              rail.unselectedIconTheme!.color,
              ground,
              min: kContrastLarge,
            ),
          ),
  );
}

/// A chip's label color, measured against the fill of the state it is drawn
/// in — and still one color per state afterwards.
///
/// A CHIP LABEL IS STATE-AWARE OR IT IS NOTHING. Auris hands its label color
/// over as a [WidgetStateColor] that answers one thing selected and another
/// unselected, and the selected fill is not the unselected one — so measuring
/// the color this getter happens to return and writing back a flat
/// replacement loses the state it was carrying. That is not a hypothetical:
/// doing it made selected chips render the UNSELECTED color, a repair that
/// broke the thing it was measuring.
///
/// So each state is resolved, measured against the fill THAT state paints, and
/// put back as a state-aware color. A theme that names no color is left
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
/// picks itself. Keeping the hue matters for a colored label on a neutral
/// page; it does not for white text on a colored button.
ColorScheme _legibleScheme(ColorScheme s) {
  // THE ACCENT ITSELF, WHERE NO INK IS COMFORTABLE ON IT.
  //
  // Every other repair in this file moves the ink and leaves the fill alone.
  // A mid-tone accent - the slate and the light blues in the Classic picker -
  // is the case where that is not enough: it is too dark for black and too
  // light for white, so black lands around 5:1, white around 4:1, the pass
  // picks black because it is the better of the two, and the result is a
  // filled button with BLACK text on a color, sitting next to a tonal button
  // in white. Both clear the WCAG bar and it still reads badly.
  //
  // So `primary` - and only `primary`, the one role this app paints solid
  // buttons out of - is taken the way its own mode already goes: darker in a
  // light theme so white sits on it, lighter in a dark one so black does. The
  // hue is kept, as everywhere else here, so the button is still the color
  // somebody picked. An accent that already carries a comfortable ink is left
  // exactly where it is, which is most of them and all of Auris.
  final primary = _comfortableFill(s.primary, s.brightness);
  return s.copyWith(
      primary: primary,
      onPrimary: readableOn(primary, prefer: [s.onPrimary]),
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
}

/// [fill] moved until black or white is COMFORTABLE on it, or left alone.
///
/// Comfortable is [kContrastStrong] rather than the 4.5:1 bar: this is about
/// the pairing that passes and still reads badly, and a button label is the
/// place that shows up worst. The direction is the one the mode already
/// implies - a light theme's solid button is dark with white on it, a dark
/// theme's is light with black on it - so an accent that has to move goes the
/// way it was already meant to be.
Color _comfortableFill(Color fill, Brightness brightness) {
  if (fill.a == 0) return fill;
  if (math.max(
        contrastRatio(Colors.white, fill),
        contrastRatio(Colors.black, fill),
      ) >=
      kContrastStrong) {
    return fill;
  }
  final ink = brightness == Brightness.light ? Colors.white : Colors.black;
  return legibleTone(fill, ink, minRatio: kContrastStrong);
}

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
    // default — which is the color this pass just moved off.
    iconColor: WidgetStateProperty.resolveWith(resolve),
  );
}

