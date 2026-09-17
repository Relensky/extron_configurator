import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'cost_estimate.dart' show formatMoney;

/// True for a catalog category that means a control processor.
bool isControlProcessorCategory(String category) {
  const wanted = 'Control processor';
  return category.trim().toLowerCase() == wanted.toLowerCase() ||
      catalogCategorySuggestion(category) == wanted;
}

/// The catalog's control processors, retired models left out.
List<AvDeviceTemplate> catalogProcessors(AvDeviceLibrary library) => [
  for (final t in library.active)
    if (isControlProcessorCategory(t.category)) t,
];

/// Stands in for the control schematic until the room has a processor.
class NoProcessorPrompt extends StatelessWidget {
  const NoProcessorPrompt({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.memory, size: 32, color: theme.disabledColor),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'No processor in this room',
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'The control schematic is drawn around the room\'s processor. '
                'Add one to build it.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  ElevatedButton.icon(
                    key: const ValueKey('add_processor_from_catalog'),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add a processor from the catalog'),
                    onPressed: () => showAddProcessorDialog(context, provider),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('choose_deployment_processor'),
                    icon: const Icon(Icons.settings_ethernet, size: 18),
                    label: const Text('Choose a deployment processor'),
                    onPressed: () =>
                        provider.selectTab(AppTab.appConfig.index),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'A processor from the catalog goes on the AV flow and the cost '
                'estimate. A deployment processor is picked in App Config.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Picks a control processor from the catalog and draws it on the AV flow,
/// which also puts it on the cost estimate. Returns the box added, or null.
Future<AvNode?> showAddProcessorDialog(
  BuildContext context,
  AppStateProvider provider,
) async {
  final processors = catalogProcessors(provider.avDeviceLibrary);
  final search = TextEditingController();
  String? picked;

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final matches = searchCatalog(
          processors,
          search.text,
          limit: processors.length,
        );
        return AlertDialog(
          title: const Text('Add a processor'),
          content: SizedBox(
            width: 520,
            height: math.min(480, MediaQuery.of(ctx).size.height - 200),
            child: Column(
              children: [
                TextField(
                  controller: search,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Search the control processors',
                    prefixIcon: Icon(Icons.search, size: 20),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setLocal(() {}),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: matches.isEmpty
                      ? const Center(
                          child: Text(
                            'No control processors in the catalog match.',
                          ),
                        )
                      : ListView.builder(
                          itemCount: matches.length,
                          itemBuilder: (ctx, i) {
                            final t = matches[i];
                            final price = t.priceForTier(provider.pricingTier);
                            return ListTile(
                              dense: true,
                              selected: t.model == picked,
                              leading: const Icon(Icons.memory, size: 20),
                              title: Text(t.model),
                              subtitle: Text(
                                price.price > 0
                                    ? formatMoney(
                                        price.price,
                                        provider.currencySymbol,
                                      )
                                    : 'not priced',
                              ),
                              onTap: () => setLocal(() => picked = t.model),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: picked == null
                  ? null
                  : () => Navigator.of(ctx).pop(true),
              child: const Text('Add'),
            ),
          ],
        );
      },
    ),
  );
  // Not disposed here: the dialog is still animating closed and reads it.
  if (ok != true || picked == null) return null;
  return addCatalogProcessor(provider, picked!);
}

/// Draws [model] on the AV flow below everything already there.
AvNode? addCatalogProcessor(AppStateProvider provider, String model) {
  final template = provider.avDeviceLibrary.templateForModel(model);
  if (template == null) return null;
  double y = 60;
  for (final n in provider.avNodes) {
    y = math.max(y, n.pos.dy + n.height + 30);
  }
  return provider.addAvNode(
    AvNode(
      id: '',
      label: template.model,
      model: template.model,
      pos: Offset(40, y),
      ports: withPowerInlet(template.ports, template.powerInput),
      rackUnits: template.rackUnits,
      powerWatts: template.powerWatts,
      btuPerHour: template.btuPerHour,
      powerSource: powerSourceForInput(template.powerInput),
    ),
  );
}
