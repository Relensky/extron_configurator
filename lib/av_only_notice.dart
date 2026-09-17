import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'contrast.dart';
import 'app_state.dart';
import 'control_prefill_dialog.dart';

/// ============================================================================
///  ESTIMATE-ONLY ROOMS
/// ============================================================================
///  A room being priced before it is programmed. The Wizard, Devices, System
///  and Raw JSON tabs stay hidden until somebody converts it; the drawings,
///  racks and costs all work as normal.
/// ============================================================================

/// Converts an estimate-only room to a programmed room, after asking.
///
/// Offers to build control blocks from the drawing when it has devices
/// without one. Returns true when the room was converted.
Future<bool> convertToProgrammedRoom(
  BuildContext context,
  AppStateProvider provider,
) async {
  final unbuilt = provider.avDevicesWithoutControl.length;
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Convert to a programmed room?'),
      content: SizedBox(
        width: 460,
        child: Text(
          'The Wizard, Devices, System and Raw JSON tabs come back so the '
          'control system can be set up. The drawings and the estimate are '
          'kept as they are.'
          '${unbuilt == 0 ? '' : '\n\n$unbuilt device'
              '${unbuilt == 1 ? '' : 's'} on the drawing '
              '${unbuilt == 1 ? 'has' : 'have'} no control block yet.'}',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        if (unbuilt > 0)
          OutlinedButton(
            onPressed: () => Navigator.of(ctx).pop('build'),
            child: const Text('Convert and build control blocks'),
          ),
        ElevatedButton(
          onPressed: () => Navigator.of(ctx).pop('convert'),
          child: const Text('Convert'),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return false;
  if (choice == 'build') {
    // The review dialog switches the mode when it writes the blocks.
    await showControlPrefillDialog(context, provider);
  } else {
    provider.setRoomMode(RoomMode.full);
  }
  if (provider.isEstimateRoom) return false;
  provider.selectTab(AppTab.wizard.index);
  return true;
}

/// Shown only while the room is estimate-only.
class ConvertToProgrammedRoomButton extends StatelessWidget {
  final bool prominent;

  const ConvertToProgrammedRoomButton({super.key, this.prominent = false});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    if (!provider.isEstimateRoom) return const SizedBox.shrink();
    const icon = Icon(Icons.memory, size: 18);
    const label = Text('Convert to programmed room');
    void go() => convertToProgrammedRoom(context, provider);
    return prominent
        ? ElevatedButton.icon(
            key: const ValueKey('convert_to_programmed'),
            icon: icon,
            label: label,
            onPressed: go,
          )
        : OutlinedButton.icon(
            key: const ValueKey('convert_to_programmed'),
            icon: icon,
            label: label,
            onPressed: go,
          );
  }
}

/// Stands in for a tab that is hidden while the room is estimate-only, when
/// something navigates to it anyway.
class ControlSystemPlaceholder extends StatelessWidget {
  /// What the tab would have shown, so the message names it.
  final String tabName;

  const ControlSystemPlaceholder({super.key, required this.tabName});

  @override
  Widget build(BuildContext context) {
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
                    Icons.request_quote_outlined,
                    size: 32,
                    color: theme.disabledColor,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Estimate only',
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'This room is an estimate, so $tabName is hidden until it is '
                'converted to a programmed room.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'The cost estimate, schematic, AV flow, floor plan, cabling '
                'and racks all work as normal.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              const MissingModulesBanner(),
              const SizedBox(height: 24),
              const Align(
                alignment: Alignment.centerLeft,
                child: ConvertToProgrammedRoomButton(prominent: true),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The devices that are DELIBERATELY driverless, on their own.
///
/// Shown where the red card would be when the red card has nothing to say: a
/// room whose only module-less blocks are ones somebody has already settled is
/// a room with no warning to give - and the settling is still worth printing,
/// because checking a room file means confirming the things that look wrong
/// and are not.
class _SettledModulesNote extends StatelessWidget {
  final List<UnmodularDevice> devices;
  final bool compact;

  const _SettledModulesNote({required this.devices, required this.compact});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final shown = compact ? devices.take(8).toList() : devices;

    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.block, size: 18, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${devices.length} device'
                    '${devices.length == 1 ? '' : 's'} flagged as needing no '
                    'module',
                    style: theme.textTheme.titleSmall?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'The catalog says these products have no control interface, so '
              'nothing drives them anywhere. They are listed to be confirmed '
              'against the room, not to be fixed.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
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
            ),
          ],
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
    final uncontrolled = provider.isEstimateRoom
        ? provider.avDevicesWithoutControl
        : const <UnmodularDevice>[];
    // Devices somebody has already been through and marked as needing no
    // driver. Not part of the count and not on the red card - they are a note
    // under it, because "the laptop plates are deliberately driverless" is
    // worth confirming and worth nothing as a warning.
    final settled = provider.devicesNeedingNoModule;
    if (missing.isEmpty && uncontrolled.isEmpty) {
      return settled.isEmpty
          ? const SizedBox.shrink()
          : _SettledModulesNote(devices: settled, compact: compact);
    }

    final theme = Theme.of(context);
    // Measured against the fill it is painted on rather than taken from the
    // scheme, which only PREFERS this pairing and does not guarantee it.
    final onError =
        foregroundOn(theme.colorScheme, theme.colorScheme.errorContainer);
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
                'device without one - set it on the device\'s tab under '
                'Devices.',
                style: theme.textTheme.bodySmall?.copyWith(color: onError),
              ),
              const SizedBox(height: 6),
              chips(missing),
            ],
            if (settled.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '${settled.length} more '
                '${settled.length == 1 ? 'device is' : 'devices are'} flagged '
                'in the catalog as needing no module, and are not counted '
                'above.',
                style: theme.textTheme.bodySmall?.copyWith(color: onError),
              ),
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
