import 'package:flutter/material.dart';

import 'app_state.dart';

/// ============================================================================
///  CONVERSION COLOURS
/// ============================================================================
///  The one place the provenance palette is defined. Both readers of it — the
///  conversion preview dialog and the field editors on the Devices / System
///  tabs — resolve it from here, so a value cannot be orange in one and white
///  in the other.
///
///  Three states, because a conversion does three different things to a value:
///
///    LEGACY   the loaded file's value, untouched. Orange: nobody has checked
///             it against the current template yet.
///    CHANGED  the key came from the old file but the conversion REWROTE the
///             value (gve_bldg 'BEHAVIORAL...' -> 'BSS', module resolved from
///             model, the generated room name). Teal — neither purely the old
///             file's nor purely the template's.
///    WRITTEN  the conversion introduced the key: template, schema defaults,
///             companion keys. Drawn in the theme's normal text colour,
///             because it is what a config built from the template looks like.
///
///  Everything is resolved from the active ThemeData rather than hardcoded, so
///  the panel follows Classic and Auris alike. 'written' in particular is
///  colorScheme.onSurface and not Colors.white: Auris's text is a warm cream,
///  and a true white beside it reads as a deliberate highlight it isn't.
/// ============================================================================
class ConversionColors {
  /// Carried over from the loaded file, unchanged.
  final Color legacy;

  /// Was in the loaded file, but the conversion rewrote the value.
  final Color changed;

  /// Written by the conversion — the theme's ordinary text colour.
  final Color written;

  /// Braces, commas and the trailing '// removed' notes in the JSON pane.
  final Color punctuation;

  /// A section name ("SYSTEM_SETUP") in the JSON pane — the app's accent, so
  /// the preview reads as part of the app instead of a stock JSON viewer.
  final Color sectionName;

  /// A property name inside a section. Deliberately quieter than
  /// [sectionName]: when both were the same colour the section headings did
  /// not read as headings.
  final Color propertyName;

  /// The JSON pane's background.
  final Color panel;

  /// A dropped/invalid property.
  final Color conflict;

  const ConversionColors({
    required this.legacy,
    required this.changed,
    required this.written,
    required this.punctuation,
    required this.sectionName,
    required this.propertyName,
    required this.panel,
    required this.conflict,
  });

  factory ConversionColors.of(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bool isDark = theme.brightness == Brightness.dark;

    return ConversionColors(
      // Readable on both themes — the light theme needs the darker shade
      legacy: isDark ? Colors.orangeAccent : Colors.deepOrange.shade700,
      // Kept well away from orange in hue: under the Auris amber theme an
      // amber "changed" would sit on top of both the legacy orange and the
      // accent, and the whole point of the third state is telling them apart.
      changed: isDark ? Colors.cyanAccent.shade100 : Colors.teal.shade700,
      written: scheme.onSurface,
      punctuation: scheme.onSurfaceVariant.withValues(alpha: 0.7),
      sectionName: scheme.primary,
      propertyName: scheme.onSurfaceVariant,
      panel: scheme.surfaceContainerHighest,
      conflict: isDark ? Colors.red.shade300 : Colors.red.shade700,
    );
  }

  /// The colour for [origin], or null when the value has no conversion history
  /// (a config built from the template, or a value the user has since typed) —
  /// callers leave their normal styling alone in that case.
  Color? forOrigin(ValueOrigin? origin) {
    switch (origin) {
      case ValueOrigin.legacy:
        return legacy;
      case ValueOrigin.changed:
        return changed;
      case ValueOrigin.written:
        return written;
      case null:
        return null;
    }
  }

  /// What the legend calls each state, in the order it is shown.
  static const List<(ValueOrigin, String)> legend = [
    (ValueOrigin.legacy, 'from the old file'),
    (ValueOrigin.changed, 'rewritten by the conversion'),
    (ValueOrigin.written, 'written from template'),
  ];
}
