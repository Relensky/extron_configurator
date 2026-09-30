import 'package:material_ui/material_ui.dart';

/// Shared widget-state layer helpers for the Auris component themes.
///
/// Internal to the theme layer — not exported from the public barrels. Every
/// interactive Material component replaces the default ink ripple with the same
/// amber hover / focus / press overlay, so the resolution logic lives in one
/// place rather than being copied into each component-theme builder.
abstract final class AurisStateLayers {
  /// An amber hover / focus / press overlay tinting [base], replacing the
  /// default Material ink ripple.
  static WidgetStateProperty<Color?> overlay(Color base) {
    return WidgetStateProperty.resolveWith<Color?>((Set<WidgetState> states) {
      if (states.contains(WidgetState.pressed)) {
        return base.withValues(alpha: 0.24);
      }
      if (states.contains(WidgetState.focused)) {
        return base.withValues(alpha: 0.20);
      }
      if (states.contains(WidgetState.hovered)) {
        return base.withValues(alpha: 0.12);
      }
      return null;
    });
  }
}
