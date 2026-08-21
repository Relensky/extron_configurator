import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'av_flow_routing.dart' show withOutletNames;
import 'search_match.dart';

/// ============================================================================
///  CHANGING YOUR MIND ABOUT A BOX OR A LEAD
/// ============================================================================
///  Two pickers, and the same complaint behind both: everything on this page
///  could be created and deleted and nothing could be CHANGED.
///
///  A run drawn to input 3 that turns out to be on input 4 had to be deleted
///  and drawn again, which loses its cable id, its label and its length — the
///  three things somebody had actually done work on. And a box put down as the
///  wrong model had to be deleted and replaced, which loses every cable on it.
///  Both are the same edit: keep the thing, move what it points at.
/// ============================================================================

/// One end of a cable, as the node and connector it lands on.
typedef CableEnd = ({String nodeId, String portId});

/// Picks a new connector for one end of a drawn run.
///
/// Only connectors that would actually make a cable are offered, judged by
/// [checkPortMatch] against the end that is NOT moving — so an output end is
/// offered outputs, and a DMP EXP lead is offered nothing but other DMP EXP
/// sockets. That is the whole reason the list is filtered rather than showing
/// every socket in the room: the rule already exists, and a picker that
/// ignored it would be a second way to draw a cable the canvas refuses.
///
/// [signalMismatch] entries are still listed. Real rooms are full of adapters,
/// and the canvas asks about those rather than refusing them; this marks them
/// instead, so the choice is informed rather than blocked.
Future<CableEnd?> pickCableEnd(
  BuildContext context,
  AppStateProvider provider, {
  /// True when the OUTPUT end is being moved — the end the signal leaves by.
  required bool movingSource,

  /// The end staying where it is.
  required AvNode fixedNode,
  required AvPort fixedPort,
  required CableEnd current,
}) {
  final searchController = TextEditingController();
  CableEnd? selected = current;

  return showDialog<CableEnd>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final theme = Theme.of(ctx);

        // Every connector this end could legally move to, with the mismatch
        // flag so the list can say which ones need an adapter.
        final options = <({AvNode node, AvPort port, bool mismatch})>[];
        for (final node in provider.avNodes) {
          for (final port in node.ports) {
            final match = movingSource
                ? checkPortMatch(node, port, fixedNode, fixedPort)
                : checkPortMatch(fixedNode, fixedPort, node, port);
            if (match == PortMatch.invalid) continue;
            final query = searchController.text;
            if (query.trim().isNotEmpty &&
                !searchMatches('${node.label} ${node.model} ${port.label}',
                    query)) {
              continue;
            }
            options.add((
              node: node,
              port: port,
              mismatch: match == PortMatch.signalMismatch,
            ));
          }
        }

        return AlertDialog(
          title: Text(movingSource
              ? 'Move the output end'
              : 'Move the input end'),
          content: SizedBox(
            width: 560,
            height: math.min(520, MediaQuery.of(ctx).size.height - 200),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The other end stays on ${fixedNode.label} · '
                  '${fixedPort.label}.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('cable_end_search'),
                  controller: searchController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Search',
                    hintText: 'device, model or connector',
                    prefixIcon: Icon(Icons.search, size: 20),
                  ),
                  onChanged: (_) => setLocal(() {}),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: options.isEmpty
                      ? Center(
                          child: Text(
                            'No connector on the canvas can take this end. '
                            'A cable runs from an output to an input, and an '
                            'expansion bus only meets its own kind.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        )
                      : ListView.builder(
                          itemCount: options.length,
                          itemBuilder: (ctx, i) {
                            final o = options[i];
                            final isCurrent = o.node.id == selected?.nodeId &&
                                o.port.id == selected?.portId;
                            return ListTile(
                              key: ValueKey(
                                  'cable_end_${o.node.id}_${o.port.id}'),
                              dense: true,
                              selected: isCurrent,
                              leading: Container(
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: provider.avSignalColor(o.port.signal),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              title: Text(
                                '${o.node.label} · ${o.port.label}',
                                style: const TextStyle(fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                [
                                  kSignalLabels[o.port.signal] ??
                                      o.port.signal.name,
                                  if (o.node.model.isNotEmpty) o.node.model,
                                  if (o.mismatch) 'needs an adapter',
                                ].join(' · '),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: o.mismatch
                                      ? theme.colorScheme.error
                                      : null,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => setLocal(() => selected =
                                  (nodeId: o.node.id, portId: o.port.id)),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              key: const ValueKey('cable_end_apply'),
              onPressed: selected == null
                  ? null
                  : () => Navigator.of(ctx).pop(selected),
              child: const Text('Move it here'),
            ),
          ],
        );
      },
    ),
  );
}

/// Picks a catalog model, by search.
///
/// A dropdown of a thousand Extron models is unusable and the names are
/// exactly the sort people mistype, so this matches the way the rest of the
/// app does: spaces, dashes and case ignored on both sides, so "dtpcross108"
/// finds "DTP CrossPoint 108".
///
/// Retired entries are left out. Choosing a model is specifying what to build,
/// and the Catalog tab is where a discontinued part stays visible.
Future<AvDeviceTemplate?> pickCatalogModel(
  BuildContext context,
  AppStateProvider provider, {
  required String title,
  required String actionLabel,
  String? currentModel,
  String? note,

  /// The slice of the catalog to offer. Defaults to everything active — the
  /// canvas can put any entry under a box. The estimate narrows it to the
  /// boxes, because a quote line for a switcher is not going to become a
  /// spool of Cat6.
  List<AvDeviceTemplate>? only,
}) {
  final searchController = TextEditingController();
  AvDeviceTemplate? selected;
  final entries = only ?? provider.avDeviceLibrary.active;

  return showDialog<AvDeviceTemplate>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final matches = searchCatalog(entries, searchController.text);
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 560,
            height: math.min(560, MediaQuery.of(ctx).size.height - 200),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (currentModel != null && currentModel.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('Currently $currentModel',
                        style: theme.textTheme.bodySmall),
                  ),
                TextField(
                  key: const ValueKey('catalog_swap_search'),
                  controller: searchController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Search the catalog',
                    hintText: 'model, part number or maker',
                    prefixIcon: Icon(Icons.search, size: 20),
                    helperText: 'Spaces and dashes are ignored — '
                        '"dtpcross108" finds "DTP CrossPoint 108".',
                  ),
                  onChanged: (_) => setLocal(() {}),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: matches.isEmpty
                      ? Center(
                          child: Text(
                            searchController.text.trim().isEmpty
                                ? 'The catalog is empty.'
                                : 'No model matches — add it on the Catalog '
                                    'tab first.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        )
                      : ListView.builder(
                          itemCount: matches.length,
                          itemBuilder: (ctx, i) {
                            final t = matches[i];
                            return ListTile(
                              key: ValueKey('catalog_swap_${t.model}'),
                              dense: true,
                              selected: t.model == selected?.model,
                              title: Text(
                                t.model,
                                style: const TextStyle(fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                [
                                  if (t.manufacturer.isNotEmpty)
                                    t.manufacturer,
                                  if (t.partNumber.isNotEmpty) t.partNumber,
                                  '${t.inputCount} in / ${t.outputCount} out',
                                  if (t.rackUnits > 0) '${t.rackUnits}U',
                                ].join(' · '),
                                style: const TextStyle(fontSize: 11),
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => setLocal(() => selected = t),
                            );
                          },
                        ),
                ),
                if (note != null) ...[
                  const SizedBox(height: 6),
                  Text(note, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              key: const ValueKey('catalog_swap_apply'),
              onPressed: selected == null
                  ? null
                  : () => Navigator.of(ctx).pop(selected),
              child: Text(actionLabel),
            ),
          ],
        );
      },
    ),
  );
}


/// ============================================================================
///  PUTTING A DIFFERENT PRODUCT UNDER A BOX
/// ============================================================================

/// What a swap did to the runs already drawn on the box.
typedef ModelSwapResult = ({int carried, int dropped});

/// Replaces the model under [node] with [template], in one go.
///
/// The box keeps its name, its position, its rack slot and its place in the
/// config — everything that is a fact about THIS ROOM. What comes off the
/// catalog entry is what the product is: its connectors, its rack height, its
/// power draw and its heat.
///
/// Cables already drawn are moved onto the new box's counterpart connectors by
/// [remapPorts]; a run whose connector has no counterpart is removed, because
/// leaving it pointing at a socket that no longer exists is a run the canvas
/// silently stops drawing. The count of both comes back so the caller can say
/// what happened rather than making somebody notice.
///
/// The node editor on the Signal Flow tab does the same thing the long way
/// round — it has to defer, because the connectors can be hand-edited in the
/// same dialog before Save. Anywhere the swap is the whole edit, this is it.
ModelSwapResult applyModelSwap(
  AppStateProvider provider,
  AvNode node,
  AvDeviceTemplate template, {

  /// False for the second and later boxes of a multi-unit swap, so the whole
  /// swap is one press of Undo rather than one per box.
  bool recordUndo = true,
}) {
  final swapped = withOutletNames(
    withPowerInlet(template.ports, template.powerInput),
    node.id,
    provider.roomConfig,
  );
  final remap = remapPorts(node.ports, swapped);

  // Only when the model DECIDES it — a mains box is plugged in wherever this
  // room plugs it in, and that is not the catalog's business.
  final implied = powerSourceForInput(template.powerInput);

  provider.updateAvNode(
    node.copyWith(
      model: template.model,
      ports: swapped,
      rackUnits: template.rackUnits,
      powerWatts: template.powerWatts,
      btuPerHour: template.btuPerHour,
      powerSource: implied == PowerSource.unspecified
          ? node.powerSource
          : implied,
    ),
    recordUndo: recordUndo,
  );

  var carried = 0;
  for (final c in List<AvCable>.from(provider.avCables)) {
    final fromMoved = c.fromNodeId == node.id ? remap[c.fromPortId] : null;
    final toMoved = c.toNodeId == node.id ? remap[c.toPortId] : null;
    if (fromMoved == null && toMoved == null) continue;
    provider.updateAvCable(
      c.copyWith(fromPortId: fromMoved, toPortId: toMoved),
      recordUndo: false,
    );
    carried++;
  }

  // Whatever had nowhere to go. Removed rather than left behind: a cable
  // pointing at a connector that is gone stops being drawn on the next build
  // anyway, and a quiet disappearance is the thing worth avoiding.
  final orphanedPorts = node.ports
      .map((p) => p.id)
      .where((id) => !remap.containsKey(id))
      .toSet();
  final orphaned = provider.avCables
      .where(
        (c) =>
            (c.fromNodeId == node.id && orphanedPorts.contains(c.fromPortId)) ||
            (c.toNodeId == node.id && orphanedPorts.contains(c.toPortId)),
      )
      .toList();
  for (final c in orphaned) {
    provider.removeAvCable(c.id);
  }

  return (carried: carried, dropped: orphaned.length);
}
