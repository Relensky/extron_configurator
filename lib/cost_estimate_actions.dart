import 'package:flutter/material.dart';

/// ============================================================================
///  THE COST TAB'S OWN ACTIONS, REACHED FROM THE TOOLBAR
/// ============================================================================
///  The Cost tab used to carry its own Screenshot, Save AV Setup and Export
///  buttons, beside the toolbar's Screenshot, Save and Export that did nearly
///  the same things. They are one set now: the toolbar's menus offer the
///  estimate's picture and the estimate's exports while the Cost tab is on
///  screen. The picture is rendered by the page itself (it hides its own
///  controls and paints the whole estimate, not just what is scrolled into
///  view), so the page lends those two actions out while it is mounted.
/// ============================================================================
class CostEstimateActions {
  /// The Cost tab on screen right now, or null.
  static CostEstimateActions? current;

  /// Renders the whole estimate as a picture, light or dark.
  final Future<void> Function(Brightness brightness) screenshot;

  /// Exports the estimate: 'pdf', 'xlsx', 'txt' or 'copy'.
  final Future<void> Function(BuildContext context, String what) export;

  const CostEstimateActions({required this.screenshot, required this.export});
}
