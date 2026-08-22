import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'contrast.dart';
import 'app_state.dart';
import 'control_prefill.dart';

/// ============================================================================
///  "ADD THE CONTROL SIDE" — THE REVIEW
/// ============================================================================
///  Writing twenty device blocks into a config is not something to do on a
///  single click and a hope. This shows exactly what would be created, in
///  which family, under which name and with which module, BEFORE anything is
///  written — and it puts the devices with no module at the top, because that
///  is the answer somebody has to go and find.
/// ============================================================================

/// Reviews and (on confirmation) builds the control blocks. Returns true when
/// something was written.
Future<bool> showControlPrefillDialog(
  BuildContext context,
  AppStateProvider provider,
) async {
  final plan = planControlSide(provider);

  if (plan.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nothing to add'),
        content: SizedBox(
          width: 460,
          child: Text(
            plan.alreadyConfigured > 0
                ? 'Every device on the diagram already has a control block — '
                      '${plan.alreadyConfigured} of them. Set each one\'s '
                      'python module on the Devices tab.'
                : 'There are no devices on the signal flow yet. Draw the room '
                      'first, or pick the equipment on the Cost tab, and this '
                      'builds the control blocks from it.',
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return false;
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => _ControlPrefillDialog(plan: plan),
  );
  if (confirmed != true) return false;

  final result = applyControlSide(provider, plan);
  // The room has a control system from here on, so the System and Raw JSON
  // tabs come back. Doing it here rather than making it a second button is
  // the point: building the blocks IS committing to a control system.
  provider.setRoomMode(RoomMode.full);

  if (!context.mounted) return true;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(
        '${result.created} control block'
        '${result.created == 1 ? '' : 's'} created'
        '${result.withoutModule == 0 ? '.' : ', ${result.withoutModule} with '
            'no python module — they are flagged on the Devices tab and on '
            'the exported report.'}',
      ),
    ),
  );
  return true;
}

class _ControlPrefillDialog extends StatelessWidget {
  final ControlPrefillPlan plan;

  const _ControlPrefillDialog({required this.plan});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byFamily = plan.byFamily;

    return AlertDialog(
      title: const Text('Add the control side'),
      content: SizedBox(
        width: math.min(760, MediaQuery.of(context).size.width - 100),
        height: math.min(600, MediaQuery.of(context).size.height - 180),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${plan.creatable.length} control block'
              '${plan.creatable.length == 1 ? '' : 's'} will be created from '
              'the devices on the signal flow, using this application\'s '
              'defaults for each family and naming them in order.'
              '${plan.alreadyConfigured == 0 ? '' : ' '
                  '${plan.alreadyConfigured} device'
                  '${plan.alreadyConfigured == 1 ? '' : 's'} already '
                  '${plan.alreadyConfigured == 1 ? 'has' : 'have'} a block '
                  'and ${plan.alreadyConfigured == 1 ? 'is' : 'are'} left '
                  'alone.'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            // The gap, first. This is the thing somebody has to act on, and
            // it is the whole reason this dialog exists rather than being a
            // button that silently writes blocks.
            if (plan.withoutModule.isNotEmpty)
              _banner(
                theme,
                Icons.extension_off_outlined,
                theme.colorScheme.errorContainer,
                foregroundOn(theme.colorScheme,
                    theme.colorScheme.errorContainer),
                '${plan.withoutModule.length} device'
                    '${plan.withoutModule.length == 1 ? '' : 's'} have no '
                    'python module',
                'No driver in the module library claims these models, so the '
                    'processor cannot talk to them. They are still created — '
                    'with the module left blank — and listed on the Devices '
                    'tab and in the "Devices Without a Control Module" section '
                    'of the exported report until one is chosen.',
              ),
            if (plan.unplaceable.isNotEmpty) ...[
              const SizedBox(height: 8),
              _banner(
                theme,
                Icons.help_outline,
                theme.colorScheme.surfaceContainerHighest,
                theme.colorScheme.onSurface,
                '${plan.unplaceable.length} device'
                    '${plan.unplaceable.length == 1 ? '' : 's'} do not belong '
                    'to any device family',
                'Nothing in the schema claims these, so there is nowhere to '
                    'put a control block. Usually right — a speaker or a wall '
                    'plate never had one. If a projector is on this list, its '
                    'catalog category is what needs fixing: '
                    '${plan.unplaceable.map((e) => e.nodeLabel).take(6).join(', ')}'
                    '${plan.unplaceable.length > 6 ? '…' : ''}',
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                children: [
                  for (final family in byFamily.keys) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(
                        '${family.label} — ${byFamily[family]!.length}',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    for (final entry in byFamily[family]!)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          entry.needsModule
                              ? Icons.error_outline
                              : Icons.check_circle_outline,
                          size: 18,
                          color: entry.needsModule
                              ? theme.colorScheme.error
                              : theme.colorScheme.primary,
                        ),
                        title: Text(
                          '${entry.name}   ·   ${entry.sectionKey}',
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          [
                            // Both names, because the drawn one is what is on
                            // the diagram and the new one is what is in the
                            // config — and somebody will have to match them.
                            'drawn as "${entry.nodeLabel}"',
                            if (entry.model.isNotEmpty) entry.model,
                            entry.module.isEmpty
                                ? 'NO MODULE'
                                : 'module: ${entry.module}',
                          ].join('  ·  '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: entry.needsModule
                                ? theme.colorScheme.error
                                : null,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('Create ${plan.creatable.length} device'
              '${plan.creatable.length == 1 ? '' : 's'}'),
        ),
      ],
    );
  }

  Widget _banner(
    ThemeData theme,
    IconData icon,
    Color background,
    Color foreground,
    String title,
    String body,
  ) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          body,
          style: theme.textTheme.bodySmall?.copyWith(color: foreground),
        ),
      ],
    ),
  );
}

/// The button that starts it, for the places a room's control gap is visible.
class BuildControlSideButton extends StatelessWidget {
  /// True on the control-system placeholder, where it is the primary action.
  final bool prominent;

  const BuildControlSideButton({super.key, this.prominent = false});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    // Nothing to build from is not a disabled button with no explanation —
    // the button simply isn't there, and the page around it already says the
    // room has no devices yet.
    if (provider.avNodes.where((n) => !n.isJackField).isEmpty) {
      return const SizedBox.shrink();
    }
    final label = const Text('Build the control side from the diagram');
    final icon = const Icon(Icons.auto_fix_high, size: 18);
    void go() => showControlPrefillDialog(context, provider);

    return prominent
        ? ElevatedButton.icon(icon: icon, label: label, onPressed: go)
        : OutlinedButton.icon(icon: icon, label: label, onPressed: go);
  }
}
