import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'contrast.dart';
import 'app_state.dart';
import 'av_flow_routing.dart';

/// ============================================================================
///  "DRAW THE ROUTING" — THE REVIEW
/// ============================================================================
///  The mirror of the control-side review, and for the same reason: this reads
///  numbers out of a config and turns them into cables, and a cable drawn to
///  the wrong socket is worse than no cable because it looks checked. So every
///  tie is shown with the config key it came from and the value that key held,
///  BEFORE anything is drawn — 'output_proj_1 = 3B' next to 'DTP OUT 003B →
///  HDBaseT' is a line somebody can verify against the rack in ten seconds.
///
///  The ties that could NOT be resolved go at the top, because they are the
///  work: an output whose number names no connector the catalog knows about is
///  either a catalog entry to fix or a cable to draw by hand, and it is the one
///  thing this feature cannot do for you.
/// ============================================================================

/// Reviews and (on confirmation) draws the config's routing. Returns true when
/// something was drawn.
Future<bool> showRoutingDialog(
  BuildContext context,
  AppStateProvider provider,
) async {
  final plan = planRoutingFromConfig(provider);

  if (plan.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nothing to draw'),
        content: SizedBox(
          width: 480,
          child: Text(
            plan.unresolved.isNotEmpty
                ? plan.unresolved.first.reason
                : plan.alreadyDrawn > 0
                    ? 'Every tie the config states is already on the diagram - '
                        '${plan.alreadyDrawn} of them. Change a switcher input '
                        'or output number on the System tab and press this '
                        'again to draw the difference.'
                    : 'This room states no switcher input or output numbers '
                        'yet. Fill in the input_ and output_ fields on the '
                        'System tab and they become the cabling here.',
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
    builder: (ctx) => _RoutingDialog(plan: plan),
  );
  if (confirmed != true) return false;

  final result = applyRoutingFromConfig(provider, plan);

  if (!context.mounted) return true;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(
        '${result.cablesDrawn} cable'
        '${result.cablesDrawn == 1 ? '' : 's'} drawn'
        '${result.nodesAdded == 0 ? '' : ', ${result.nodesAdded} box'
            '${result.nodesAdded == 1 ? '' : 'es'} added'}'
        '${result.unresolved == 0 ? '.' : ', ${result.unresolved} tie'
            '${result.unresolved == 1 ? '' : 's'} the numbers did not '
            'resolve - draw those by hand.'}',
      ),
    ),
  );
  return true;
}

class _RoutingDialog extends StatelessWidget {
  final RoutingPlan plan;

  const _RoutingDialog({required this.plan});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sources =
        plan.cables.where((c) => c.configKey.startsWith('input_')).toList();
    final destinations =
        plan.cables.where((c) => c.configKey.startsWith('output_')).toList();

    return AlertDialog(
      title: const Text('Draw the routing from the config'),
      content: SizedBox(
        width: math.min(820, MediaQuery.of(context).size.width - 100),
        height: math.min(620, MediaQuery.of(context).size.height - 180),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${plan.cables.length} cable'
              '${plan.cables.length == 1 ? '' : 's'} will be drawn from the '
              'switcher input and output numbers in SYSTEM_SETUP, landing on '
              'the connector each display\'s own "input" names, plus a mains '
              'lead for every power controller outlet whose name matches a '
              'box on the canvas.'
              '${plan.newNodes.isEmpty ? '' : ' ${plan.newNodes.length} '
                  'box${plan.newNodes.length == 1 ? '' : 'es'} the config '
                  'needs but has no device block for - the PC, the doc cam, '
                  'the laptop plates, and the transmitter or receiver every '
                  'DTP run needs at its HDMI end - will be added to the '
                  'canvas.'}'
              '${plan.alreadyDrawn == 0 ? '' : ' ${plan.alreadyDrawn} tie'
                  '${plan.alreadyDrawn == 1 ? ' is' : 's are'} already drawn '
                  'and left alone.'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            if (plan.unresolved.isNotEmpty)
              _banner(
                theme,
                Icons.report_problem_outlined,
                theme.colorScheme.errorContainer,
                // Measured, not assumed: onErrorContainer on errorContainer
                // fails WCAG on 45 of this app's 180 theme/accent
                // combinations.
                foregroundOn(theme.colorScheme,
                    theme.colorScheme.errorContainer),
                '${plan.unresolved.length} tie'
                    '${plan.unresolved.length == 1 ? '' : 's'} could not be '
                    'placed',
                'Nothing is drawn for these. Each one says why - usually a '
                    'connector this model\'s catalog entry spells differently '
                    'from the front panel, or a number left over from a room '
                    'that has since changed.',
              ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                children: [
                  for (final tie in plan.unresolved)
                    ListTile(
                      dense: true,
                      leading: Icon(Icons.close,
                          size: 18, color: theme.colorScheme.error),
                      title: Text(
                        '${tie.configKey}'
                        '${tie.value.isEmpty ? '' : ' = ${tie.value}'}',
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.error,
                        ),
                      ),
                      subtitle: Text(tie.reason,
                          style: theme.textTheme.bodySmall),
                      isThreeLine: tie.reason.length > 90,
                    ),
                  if (sources.isNotEmpty)
                    _heading(theme, 'Sources into the switcher',
                        sources.length),
                  for (final cable in sources) _cableTile(theme, cable),
                  if (destinations.isNotEmpty)
                    _heading(theme, 'Switcher outputs to their destinations',
                        destinations.length),
                  for (final cable in destinations) _cableTile(theme, cable),
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
          child: Text('Draw ${plan.cables.length} cable'
              '${plan.cables.length == 1 ? '' : 's'}'),
        ),
      ],
    );
  }

  Widget _heading(ThemeData theme, String text, int count) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text('$text - $count', style: theme.textTheme.titleSmall),
      );

  Widget _cableTile(ThemeData theme, RoutedCable cable) => ListTile(
        dense: true,
        leading: Icon(Icons.cable, size: 18, color: theme.colorScheme.primary),
        title: Text(cable.summary, style: const TextStyle(fontSize: 13)),
        // The config key and its value, because that is the thing being
        // trusted: if this line is wrong, that field is what to fix.
        subtitle: Text(
          '${cable.configKey} = ${cable.value}  ·  ${cable.signal.name}',
          style: theme.textTheme.bodySmall,
          overflow: TextOverflow.ellipsis,
        ),
      );

  Widget _banner(
    ThemeData theme,
    IconData icon,
    Color background,
    Color foreground,
    String title,
    String body,
  ) =>
      Container(
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
                  child: Text(title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(color: foreground)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(body,
                style:
                    theme.textTheme.bodySmall?.copyWith(color: foreground)),
          ],
        ),
      );
}
