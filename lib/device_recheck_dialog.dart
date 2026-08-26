import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'contrast.dart';
import 'device_recheck.dart';

/// ============================================================================
///  RECHECK DEVICES
/// ============================================================================
///  "I added the rack height and the device still isn't in the rack builder."
///
///  There are three separate reasons for that and no way to tell them apart by
///  looking (see device_recheck.dart). This is the one button that goes and
///  finds out: it reports every device whose figures have drifted from the
///  catalog, every line quoted on the Cost tab that is rack-mount gear nobody
///  has drawn, and every rack placement pointing at a frame that no longer
///  exists.
///
///  Nothing is applied until it is asked for, and each finding is applied on
///  its own. A recheck that rewrote the room on open would be a worse bug than
///  the one it fixes — a rack height typed by hand because this room's shelf is
///  deeper than the catalog assumes is a decision, not a mistake.
/// ============================================================================

Future<void> showDeviceRecheckDialog(BuildContext context) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => const _DeviceRecheckDialog(),
    );

class _DeviceRecheckDialog extends StatefulWidget {
  const _DeviceRecheckDialog();

  @override
  State<_DeviceRecheckDialog> createState() => _DeviceRecheckDialogState();
}

class _DeviceRecheckDialogState extends State<_DeviceRecheckDialog> {
  /// The findings as of the last time the check was RUN, not as of this
  /// rebuild. Applying a fix makes that finding stop existing, so a dialog
  /// that re-checked on every frame would delete each row as you pressed its
  /// button — and empty itself the moment you fixed the last one, which reads
  /// as the dialog crashing rather than as the work being done.
  late DeviceRecheck _result;

  /// What has been dealt with this visit, so a fixed row reads as done.
  final Set<String> _done = {};

  @override
  void initState() {
    super.initState();
    _result = _run();
  }

  DeviceRecheck _run() {
    final provider = context.read<AppStateProvider>();
    return recheckDevices(
      nodes: provider.avNodes,
      library: provider.avDeviceLibrary,
      cost: provider.avCost,
      racks: provider.avRacks,
      slots: provider.avRackSlots,
      rackItems: provider.avRackItems,
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final theme = Theme.of(context);
    final result = _result;

    return AlertDialog(
      title: Row(
        children: [
          const Text('Recheck devices'),
          const SizedBox(width: 12),
          if (!result.isClean)
            Chip(
              // TWO FILLS, SO TWO INKS. This chip is green-ish when the work
              // is done and red when it is not, and its label carried neither
              // - so it inherited the page's ink onto whichever of the two it
              // happened to be painting. On Classic with a dark blue accent
              // secondaryContainer IS a dark blue and the page's ink is
              // near-black: 1.07:1.
              label: Text(
                _done.length >= result.findings
                    ? 'all ${result.findings} dealt with'
                    : '${result.findings - _done.length} to look at',
                style: TextStyle(
                  fontSize: 12,
                  color: foregroundOn(
                    theme.colorScheme,
                    _done.length >= result.findings
                        ? theme.colorScheme.secondaryContainer
                        : theme.colorScheme.errorContainer,
                  ),
                ),
              ),
              backgroundColor: _done.length >= result.findings
                  ? theme.colorScheme.secondaryContainer
                  : theme.colorScheme.errorContainer,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      content: SizedBox(
        width: 820,
        height: 520,
        child: result.isClean
            ? _cleanState(theme, result)
            : ListView(
                children: [
                  if (result.specChanges.isNotEmpty)
                    _section(
                      theme,
                      title: 'Figures that have drifted from the catalog',
                      blurb:
                          'A device copies its rack height, draw and heat off '
                          'the catalog when it goes on the diagram. Filling '
                          'those in afterwards - which is the normal order - '
                          'leaves the copy behind, and a rack height of 0 is '
                          'what keeps a device out of the rack builder.',
                      children: [
                        for (final change in result.specChanges)
                          _specRow(provider, theme, change),
                      ],
                      action: result.specChanges.every(
                        (c) => _done.contains('spec:${c.before.id}'),
                      )
                          ? null
                          : TextButton.icon(
                              icon: const Icon(Icons.done_all, size: 16),
                              label: Text(
                                'Update all ${result.specChanges.length}',
                              ),
                              onPressed: () {
                                var n = 0;
                                for (final c in result.specChanges) {
                                  if (_done.contains('spec:${c.before.id}')) {
                                    continue;
                                  }
                                  provider.updateAvNode(c.after);
                                  _done.add('spec:${c.before.id}');
                                  n++;
                                }
                                setState(() {});
                                _snack(
                                  'Updated $n device${n == 1 ? '' : 's'} from '
                                  'the catalog.',
                                );
                              },
                            ),
                    ),
                  if (result.quoted.isNotEmpty)
                    _section(
                      theme,
                      title: 'Quoted on the Cost tab, never drawn',
                      blurb:
                          'These lines are rack-mount gear the estimate is '
                          'already buying, but a cost line is a price and not '
                          'a device - nothing on the diagram or in a frame '
                          'matches them. Putting one across moves it onto the '
                          'room and takes the cost line away, so the money is '
                          'counted once.',
                      children: [
                        for (final q in result.quoted)
                          _quotedRow(provider, theme, q),
                      ],
                    ),
                  if (result.orphans.isNotEmpty)
                    _section(
                      theme,
                      title: 'Racked into nothing',
                      blurb:
                          'These placements name a frame that has been '
                          'deleted, or something the room no longer has. They '
                          'are invisible twice over: no elevation can draw '
                          'them, and the "to place" list skips them because '
                          'the room thinks they are already racked.',
                      children: [
                        for (final o in result.orphans)
                          _orphanRow(provider, theme, o),
                      ],
                    ),
                ],
              ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Check again'),
          onPressed: () => setState(() {
            _result = _run();
            _done.clear();
          }),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _cleanState(ThemeData theme, DeviceRecheck result) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.check_circle_outline,
          size: 48,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 12),
        const Text('Everything checks out.'),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            'Every device on the diagram agrees with the catalog entry for '
            'its model, every rack-mount line on the estimate is on the room, '
            'and every rack placement points at a frame that exists. '
            '${result.rackableDevices} device'
            '${result.rackableDevices == 1 ? '' : 's'} carry a rack height.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    ),
  );

  Widget _section(
    ThemeData theme, {
    required String title,
    required String blurb,
    required List<Widget> children,
    Widget? action,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
            ?action,
          ],
        ),
        Text(blurb, style: theme.textTheme.bodySmall),
        const Divider(),
        ...children,
      ],
    ),
  );

  Widget _specRow(
    AppStateProvider provider,
    ThemeData theme,
    DeviceSpecChange change,
  ) {
    final fixed = _done.contains('spec:${change.before.id}');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  change.label,
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  change.model.isEmpty ? '-' : change.model,
                  style: TextStyle(fontSize: 11, color: theme.disabledColor),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(
              change.fields.join(' · '),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          SizedBox(
            width: 140,
            child: fixed
                ? _doneChip(theme, 'Updated')
                : TextButton(
                    onPressed: () {
                      provider.updateAvNode(change.after);
                      setState(() => _done.add('spec:${change.before.id}'));
                    },
                    child: const Text('Update'),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _quotedRow(
    AppStateProvider provider,
    ThemeData theme,
    QuotedNotPlaced quoted,
  ) {
    final fixed = _done.contains('quoted:${quoted.item.id}');
    final equipment = quoted.kind == QuotedKind.equipment;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  quoted.qty == 1
                      ? quoted.label
                      : '${quoted.label} ×${quoted.qty}',
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${quoted.template.model} · ${quoted.rackUnits}U · '
                  '${equipment ? 'equipment line' : 'rack hardware line'}',
                  style: TextStyle(fontSize: 11, color: theme.disabledColor),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(
              equipment
                  ? 'Goes on the signal flow diagram, then into a frame on '
                        'the Racks tab'
                  : 'Goes onto the Racks tab as hardware waiting to be placed',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          SizedBox(
            width: 140,
            child: fixed
                ? _doneChip(theme, 'Moved')
                : TextButton(
                    onPressed: () {
                      final moved = equipment
                          ? provider
                                .promoteAvCostEquipmentToDiagram(
                                  quoted.item.id,
                                  at: const Offset(40, 60),
                                )
                                .length
                          : provider
                                .promoteAvCostHardwareToRacks(quoted.item.id)
                                .length;
                      if (moved == 0) {
                        _snack('Could not move ${quoted.label}.');
                        return;
                      }
                      setState(() => _done.add('quoted:${quoted.item.id}'));
                      _snack(
                        equipment
                            ? '$moved device${moved == 1 ? '' : 's'} added to '
                                  'the diagram - place ${moved == 1 ? 'it' : 'them'} '
                                  'on the Racks tab.'
                            : '$moved item${moved == 1 ? '' : 's'} added to '
                                  'the Racks tab, waiting to be placed.',
                      );
                    },
                    child: Text(equipment ? 'Put on room' : 'Add to racks'),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _orphanRow(
    AppStateProvider provider,
    ThemeData theme,
    OrphanedPlacement orphan,
  ) {
    final fixed = _done.contains('orphan:${orphan.occupantId}');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              orphan.label,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(
              orphan.reason,
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.error,
              ),
            ),
          ),
          SizedBox(
            width: 140,
            child: fixed
                ? _doneChip(theme, 'Un-racked')
                : TextButton(
                    onPressed: () {
                      provider.clearAvRackPlacement(orphan.occupantId);
                      setState(
                        () => _done.add('orphan:${orphan.occupantId}'),
                      );
                    },
                    child: const Text('Un-rack'),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _doneChip(ThemeData theme, String label) => Row(
    children: [
      Icon(Icons.check, size: 16, color: theme.colorScheme.primary),
      const SizedBox(width: 4),
      Text(
        label,
        style: TextStyle(fontSize: 12, color: theme.colorScheme.primary),
      ),
    ],
  );
}

/// The toolbar button, so the Racks and Signal Flow pages offer the same thing
/// in the same words.
Widget deviceRecheckButton(BuildContext context, {bool dense = false}) =>
    OutlinedButton.icon(
      icon: const Icon(Icons.fact_check_outlined, size: 18),
      label: const Text('Recheck devices'),
      style: dense
          ? const ButtonStyle(visualDensity: VisualDensity.compact)
          : null,
      onPressed: () => showDeviceRecheckDialog(context),
    );
