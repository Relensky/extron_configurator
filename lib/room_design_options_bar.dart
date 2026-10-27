import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'cost_estimate.dart' show formatMoney;
import 'room_design_options.dart';

/// The room's design options at the top of the Cost tab: one chip per
/// option with its room total, the chosen one lit. Choosing another makes
/// it the room. See room_design_options.dart.
class RoomDesignOptionsBar extends StatelessWidget {
  const RoomDesignOptionsBar({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final configPath = provider.currentConfigPath;
    if (configPath.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final options = provider.roomDesignOptions;
    // One design left is nothing to choose between.
    final choosing = options.options.length > 1;
    final estimate = provider.roomCost;
    final currency = estimate.currency;
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    String totalOf(RoomDesignOption o) {
      final total = o.id == options.active
          ? estimate.grandTotal
          : provider.designOptionTotal(configPath, o.id) ?? o.total;
      return formatMoney(total, currency);
    }

    return Card(
      key: const ValueKey('design_options_bar'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text('Design options', style: theme.textTheme.titleSmall),
                Text(
                  !choosing
                      ? 'one design - start an option to price another '
                            'build of this room'
                      : 'the chosen option is the room and goes to the '
                            'project total',
                  style: quiet,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (choosing)
                for (final o in options.options)
                  ChoiceChip(
                    key: ValueKey('design_option_${o.id}'),
                    selected: o.id == options.active,
                    label: Text('${o.name}  ${totalOf(o)}'),
                    tooltip: o.id == options.active
                        ? 'The room as it is now'
                        : 'Switch the room to ${o.name}',
                    onSelected: (_) => o.id == options.active
                        ? null
                        : _choose(context, provider, o, options),
                  ),
                TextButton.icon(
                  key: const ValueKey('design_option_new'),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('New option'),
                  onPressed: () => _create(context, provider, options),
                ),
                if (choosing)
                  PopupMenuButton<String>(
                    key: const ValueKey('design_option_menu'),
                    tooltip: 'Rename or remove options',
                    icon: const Icon(Icons.more_horiz, size: 18),
                    itemBuilder: (_) => [
                      for (final o in options.options)
                        PopupMenuItem(
                          key: ValueKey('design_option_rename_${o.id}'),
                          value: 'rename:${o.id}',
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.edit_outlined, size: 18),
                            title: Text('Rename ${o.name}...'),
                          ),
                        ),
                      const PopupMenuDivider(),
                      for (final o in options.options)
                        if (o.id != options.active)
                          PopupMenuItem(
                            key: ValueKey('design_option_remove_${o.id}'),
                            value: 'remove:${o.id}',
                            child: ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading:
                                  const Icon(Icons.delete_outline, size: 18),
                              title: Text('Remove ${o.name}...'),
                            ),
                          ),
                    ],
                    onSelected: (choice) {
                      final id = choice.substring(choice.indexOf(':') + 1);
                      final option = options.byId(id);
                      if (option == null) return;
                      choice.startsWith('rename:')
                          ? _rename(context, provider, configPath, option)
                          : _remove(context, provider, configPath, option);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> _choose(
    BuildContext context,
    AppStateProvider provider,
    RoomDesignOption option,
    RoomDesignOptions options,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final current = options.activeOption?.name ?? 'the current design';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('design_option_choose_confirm'),
        title: Text('Switch this room to ${option.name}?'),
        content: SizedBox(
          width: 460,
          child: Text(
            [
              if (provider.roomHasUnsavedChanges)
                'The room is saved first.',
              '$current is kept as it is now.',
              'Every tab, the next save and the project total use '
                  '${option.name}.',
            ].join(' '),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('design_option_choose_go'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final result = await provider.chooseRoomDesignOption(option.id);
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text(
          result.isEmpty ? 'The room is now ${option.name}.' : result,
        ),
      ),
    );
  }

  static Future<void> _create(
    BuildContext context,
    AppStateProvider provider,
    RoomDesignOptions options,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final first = options.options.isEmpty;
    final name = TextEditingController(
      text: 'Option ${options.options.isEmpty ? 2 : options.options.length + 1}',
    );
    final base = TextEditingController(text: 'Base design');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('design_option_new_dialog'),
        title: const Text('New design option'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A copy of the room as it is now - drawing, racks, plans, '
                'cabling and quote - to change into another build. '
                '${provider.roomHasUnsavedChanges ? 'The room is saved first. ' : ''}'
                'The room switches to the new option.',
              ),
              const SizedBox(height: 12),
              if (first) ...[
                TextField(
                  key: const ValueKey('design_option_base_name'),
                  controller: base,
                  decoration: const InputDecoration(
                    labelText: 'Name for the room as it is now',
                  ),
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                key: const ValueKey('design_option_name'),
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name for the new option',
                ),
                onSubmitted: (_) => Navigator.of(ctx).pop(true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('design_option_new_go'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Start option'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final result = await provider.createRoomDesignOption(
      name.text,
      firstName: base.text,
    );
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text(
          result.isEmpty
              ? 'Working on ${name.text.trim()}. Changes are saved to it.'
              : result,
        ),
      ),
    );
  }

  static Future<void> _rename(
    BuildContext context,
    AppStateProvider provider,
    String configPath,
    RoomDesignOption option,
  ) async {
    final name = TextEditingController(text: option.name);
    final typed = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rename ${option.name}'),
        content: TextField(
          key: const ValueKey('design_option_rename_field'),
          controller: name,
          autofocus: true,
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('design_option_rename_go'),
            onPressed: () => Navigator.of(ctx).pop(name.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (typed == null || typed.trim().isEmpty) return;
    provider.renameRoomDesignOption(configPath, option.id, typed);
  }

  static Future<void> _remove(
    BuildContext context,
    AppStateProvider provider,
    String configPath,
    RoomDesignOption option,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${option.name}?'),
        content: const SizedBox(
          width: 420,
          child: Text(
            'It comes off the room\'s options. Its files are kept in '
            'room_files\\design_options\\removed.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            key: const ValueKey('design_option_remove_go'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) provider.removeRoomDesignOption(configPath, option.id);
  }
}
