import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'control_prefill_dialog.dart';

/// ============================================================================
///  AV-ONLY ROOMS
/// ============================================================================
///  A room created without a control system still has devices, drawings, racks
///  and a price. What it does not have is a processor config — so the System
///  and Raw JSON tabs would be editing a document nobody has decided on yet.
///  Rather than hide them (and leave the user wondering where they went), they
///  say what state the room is in and offer the one button that changes it.
///
///  The other half is the reminder. The single thing an AV-only room is
///  missing, once the control side gets built, is which python module each
///  device runs — a processor cannot talk to a device without one. That list
///  is worth carrying in front of the user from the moment the devices exist,
///  not discovered at commissioning.
/// ============================================================================

/// Stands in for the System / Raw JSON tabs while a room has no control system.
class ControlSystemPlaceholder extends StatelessWidget {
  /// What the tab would have shown, so the message names it.
  final String tabName;

  const ControlSystemPlaceholder({super.key, required this.tabName});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.settings_suggest_outlined,
                    size: 32,
                    color: theme.disabledColor,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'No control system yet',
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'This room was created as AV only, so $tabName is set aside — '
                'it edits the processor\'s config, and nobody has committed to '
                'one for this room.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Everything else works normally: the devices, the schematic, '
                'the signal flow, the racks and the costs are all about the '
                'room rather than the processor. The devices are recorded in '
                'ordinary config blocks, so none of it is re-entered when the '
                'control side is built.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              const MissingModulesBanner(),
              const SizedBox(height: 24),
              // The one that does the work, first. A room budgeted before its
              // control config already has every device recorded on the
              // diagram; typing them all in again is the step this replaces,
              // and offering only the bare mode switch left that job to
              // whoever pressed it.
              const Align(
                alignment: Alignment.centerLeft,
                child: BuildControlSideButton(prominent: true),
              ),
              const SizedBox(height: 8),
              Text(
                'Creates a control block for every device on the signal flow, '
                'prefilled from this application\'s defaults for its family '
                'and named in order. Devices no python module claims are '
                'created with the module blank and flagged, here and on the '
                'exported report.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.disabledColor,
                ),
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Just turn the tabs on'),
                  onPressed: () => provider.setRoomMode(RoomMode.full),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Turns the System and Raw JSON tabs back on without creating '
                'anything. Nothing is discarded either way — the mode is '
                'recorded with the room.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.disabledColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lists the devices whose python module has not been chosen.
///
/// Shown on the Wizard tab and on the control-system placeholder. Renders
/// nothing at all when there is nothing to say — a banner that is always there
/// is a banner nobody reads.
class MissingModulesBanner extends StatelessWidget {
  /// True on the Wizard tab, where the banner is one item in a long page and
  /// should stay compact.
  final bool compact;

  const MissingModulesBanner({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final missing = provider.devicesMissingModules;
    // Only for a room that has not had its control side built. In a finished
    // room a box on the diagram with no config block is usually deliberate —
    // a display, a laptop input, a speaker — and flagging every one of those
    // is how a warning turns into wallpaper.
    final uncontrolled = provider.isAvOnlyRoom
        ? provider.avDevicesWithoutControl
        : const <UnmodularDevice>[];
    if (missing.isEmpty && uncontrolled.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final onError = theme.colorScheme.onErrorContainer;
    final total = missing.length + uncontrolled.length;

    Widget chips(List<UnmodularDevice> devices) {
      final shown = compact ? devices.take(8).toList() : devices;
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          // Names, not just a count: the count says there is work, the list
          // says which devices it is.
          for (final d in shown)
            Chip(
              visualDensity: VisualDensity.compact,
              label: Text(
                d.model.isEmpty ? d.name : '${d.name} · ${d.model}',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          if (compact && devices.length > shown.length)
            Chip(
              visualDensity: VisualDensity.compact,
              label: Text(
                '+${devices.length - shown.length} more',
                style: const TextStyle(fontSize: 11),
              ),
            ),
        ],
      );
    }

    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.extension_off_outlined, size: 18, color: onError),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$total device${total == 1 ? '' : 's'} the control system '
                    'cannot drive yet',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: onError,
                    ),
                  ),
                ),
              ],
            ),
            if (missing.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'No python module chosen. The processor cannot talk to a '
                'device without one — set it on the device\'s tab under '
                'Devices.',
                style: theme.textTheme.bodySmall?.copyWith(color: onError),
              ),
              const SizedBox(height: 6),
              chips(missing),
            ],
            if (uncontrolled.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'On the AV diagram but not in the room config, so there is '
                'nowhere to put a module yet.',
                style: theme.textTheme.bodySmall?.copyWith(color: onError),
              ),
              const SizedBox(height: 6),
              chips(uncontrolled),
              // The fix, next to the problem. Raising each device count by
              // hand on the Wizard tab is the same work done slower and with
              // the names left to whoever types them.
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerLeft,
                child: BuildControlSideButton(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
