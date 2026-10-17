import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'app_state.dart';
import 'av_flow_model.dart';
import 'av_flow_routing.dart';
import 'cost_estimate.dart';

/// Putting gear that is quoted but not drawn onto the AV Flow.

/// Below everything already drawn, in the left column.
Offset flowSpawnPosition(AppStateProvider provider) {
  double bottom = 60;
  for (final n in provider.avNodes) {
    bottom = math.max(bottom, n.pos.dy + n.height + 30);
  }
  return Offset(40, bottom);
}

/// Equipment lines on the Cost page that are not drawn, leaving out shelf
/// spares and config devices taken off the drawing (those are listed as
/// config devices). One off the catalog draws as a plain box.
List<CostLineItem> undrawnQuotedLines(AppStateProvider provider) => [
      for (final item in provider.avCost.extraEquipment)
        if (!item.spare &&
            !(item.removedFrom.isNotEmpty &&
                provider.roomConfig[item.removedFrom] is Map) &&
            (item.catalogModel.trim().isNotEmpty ||
                item.description.trim().isNotEmpty))
          item,
    ];

/// Draws one quoted line on the AV Flow, one box per unit, without a config
/// block. The cost line goes, since the drawing is priced. Returns how many
/// boxes were drawn.
int placeQuotedLineOnFlow(AppStateProvider provider, CostLineItem item) {
  final added = provider.promoteAvCostEquipmentToDiagram(item.id,
      at: flowSpawnPosition(provider));
  drawNavRunsFor(provider, added);
  return added.length;
}

/// Cables NAV boxes to the network switch when any of [added] is a NAV box
/// or a switch. Returns how many runs were drawn.
int drawNavRunsFor(AppStateProvider provider, Iterable<AvNode> added) {
  final touches = added.any((n) =>
      navRole(n) != null || isNetworkSwitchNode(n, provider.avDeviceLibrary));
  return touches ? drawNavNetworkRuns(provider) : 0;
}
