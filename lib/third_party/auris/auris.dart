// Vendored from auris 0.2.0 (BSD 3-Clause, see LICENSE here), moved onto
// package:material_ui because the published package still builds on
// package:flutter/material.dart. Only the theme; the HUD widgets are not used.
/// Auris — a Flutter UI kit and Material 3 theme system with a warm
/// amber-on-near-black, chamfered "augmentation-era" sci-fi aesthetic.
///
/// This is the primary entry point: it exports the design tokens, the resolved
/// scheme, and the [AurisTheme] factory used to skin a Material application.
///
/// The custom HUD widget library is exported separately from
/// widgets in the published package are not carried here.
library;

export 'src/painters/chamfer_border.dart';
export 'src/painters/chamfer_clipper.dart';
export 'src/painters/slant_clipper.dart';
export 'src/scheme.dart';
export 'src/theme.dart';
export 'src/tokens.dart';
