import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'av_flow_model.dart';
import 'av_flow_view.dart' show buildAvFlowModel;
import 'contrast.dart';
import 'equipment_lifecycle.dart';
import 'project_estimate.dart' show roomCodeFromConfig;
import 'stepped_date_picker.dart';

/// ============================================================================
///  THE ROOM'S LIFECYCLE TAB
/// ============================================================================
///  What is in this room, how old it is, and the year each of it falls due.
///
///  Every other tab is about the room being BUILT. This is the only one about
///  the room as it stands — which is the state a refresh budget is written
///  against, and the state that was previously only recorded on a spreadsheet
///  somebody maintained by hand.
///
///  IT IS A SURVEY SCREEN AS MUCH AS A REPORT. The whole thing derives from one
///  field per box ([AvNode.installedOn]), and on a room nobody has surveyed
///  every one of them is blank. So the dates are editable HERE, in a list, one
///  press each — walking a room and typing eleven dates into eleven separate
///  device dialogs is the version of this feature nobody would ever finish.
///
///  THE COLOURS ARE THE RYG SHEET'S COLOURS, and they are backed by text on
///  every row. A red/amber/green chip that is only a colour is a chip that says
///  nothing to somebody printing in mono or reading with a colour deficiency,
///  and this is a document that gets printed.
/// ============================================================================

class LifecycleView extends StatelessWidget {
  const LifecycleView({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final model = buildAvFlowModel(provider);
    final room = buildRoomLifecycle(
      model: model,
      roomName: roomCodeFromConfig(provider.roomConfig),
      library: provider.avDeviceLibrary,
      tier: provider.pricingTier,
    );

    if (room.items.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Nothing to age yet.\n\n'
            'The replacement plan is built from the equipment on the AV Flow '
            'tab - add devices there and record when each of them went in.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Summary(room: room, currency: provider.currencySymbol),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: room.items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _ItemRow(
              item: room.items[i],
              currency: provider.currencySymbol,
            ),
          ),
        ),
      ],
    );
  }
}

/// The colour one condition reads in, against [surface].
///
/// Kept in one place because the chip on a row, the band in the header and the
/// project's own roll-up all have to agree — three shades of "past its life"
/// would read as three different states.
Color equipmentConditionColor(
  BuildContext context,
  EquipmentCondition condition,
) {
  final theme = Theme.of(context);
  switch (condition) {
    case EquipmentCondition.overdue:
      return errorTextOn(theme.colorScheme, theme.cardColor);
    case EquipmentCondition.ageing:
      return theme.colorScheme.tertiary;
    case EquipmentCondition.good:
      return theme.colorScheme.primary;
    case EquipmentCondition.unknown:
      return theme.colorScheme.onSurfaceVariant;
  }
}

IconData equipmentConditionIcon(EquipmentCondition condition) =>
    switch (condition) {
      EquipmentCondition.overdue => Icons.error_outline,
      EquipmentCondition.ageing => Icons.schedule,
      EquipmentCondition.good => Icons.check_circle_outline,
      EquipmentCondition.unknown => Icons.help_outline,
    };

/// The header strip: what the room reads as, and the money behind it.
class _Summary extends StatelessWidget {
  final RoomLifecycle room;
  final String currency;

  const _Summary({required this.room, required this.currency});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Wrap(
        spacing: 20,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                equipmentConditionIcon(room.condition),
                color: equipmentConditionColor(context, room.condition),
              ),
              const SizedBox(width: 8),
              Text(
                kEquipmentConditionLabels[room.condition]!,
                key: const ValueKey('lifecycle_room_condition'),
                style: theme.textTheme.titleMedium?.copyWith(
                  color: equipmentConditionColor(context, room.condition),
                ),
              ),
            ],
          ),
          for (final c in kEquipmentConditionSeverity)
            if (room.countOf(c) > 0)
              _Stat(
                label: kEquipmentConditionLabels[c]!,
                value: '${room.countOf(c)}',
                color: equipmentConditionColor(context, c),
              ),
          _Stat(
            label: 'Room last done',
            value: room.oldestInstall == null
                ? 'not recorded'
                : '${room.oldestInstall!.year}',
          ),
          _Stat(
            label: 'First replacement due',
            value: room.firstDueYear == null
                ? 'not recorded'
                : '${room.firstDueYear}',
          ),
          if (room.overdueCost > 0)
            _Stat(
              label: 'Past its life today',
              value: formatLifecycleMoney(room.overdueCost, currency),
              color: equipmentConditionColor(
                context,
                EquipmentCondition.overdue,
              ),
            ),
          _Stat(
            label: 'Full refresh',
            value: room.refreshCost <= 0
                ? 'nothing priced'
                : formatLifecycleMoney(room.refreshCost, currency),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _Stat({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.titleSmall?.copyWith(color: color),
        ),
      ],
    );
  }
}

/// One position: what it is, how old, and the date field that drives all of it.
class _ItemRow extends StatelessWidget {
  final EquipmentLife item;
  final String currency;

  const _ItemRow({required this.item, required this.currency});

  Future<void> _pickInstall(BuildContext context) async {
    final provider = context.read<AppStateProvider>();
    final now = DateTime.now();
    final picked = await showSteppedDatePicker(
      context,
      initialDate: item.installedOn ?? now,
      firstDate: DateTime(now.year - 25, 1, 1),
      lastDate: DateTime(now.year + 1, 12, 31),
      helpText: 'When did ${item.node.label} go in?',
    );
    if (picked == null) return;
    provider.setAvNodeInstalledOn(item.node.id, picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = equipmentConditionColor(context, item.condition);

    return ListTile(
      key: ValueKey('lifecycle_item_${item.node.id}'),
      leading: Tooltip(
        message: kEquipmentConditionLabels[item.condition]!,
        child: Icon(equipmentConditionIcon(item.condition), color: color),
      ),
      title: Text(
        item.node.label,
        style: theme.textTheme.titleSmall,
      ),
      subtitle: Text(
        [
          if (item.node.model.isNotEmpty) item.node.model,
          if (item.locationName.isNotEmpty) item.locationName,
          '${formatEquipmentAge(item.ageYears)} old',
          formatEquipmentDue(item),
          'life ${item.lifeYears} yrs',
          if (item.hasHistory)
            'replaced ${item.node.swaps.length}x before',
        ].join('  ·  '),
        style: theme.textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (item.replacementCost > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                formatLifecycleMoney(item.replacementCost, currency),
                style: theme.textTheme.bodyMedium,
              ),
            ),
          // The one control on the row, because the date is the one fact this
          // screen exists to collect. Everything else about the box is edited
          // where the box is drawn.
          OutlinedButton.icon(
            key: ValueKey('lifecycle_install_${item.node.id}'),
            onPressed: () => _pickInstall(context),
            icon: const Icon(Icons.event_available, size: 16),
            label: Text(
              item.installedOn == null
                  ? 'Set install date'
                  : formatEquipmentDate(item.installedOn!),
            ),
          ),
          if (item.installedOn != null)
            IconButton(
              key: ValueKey('lifecycle_install_clear_${item.node.id}'),
              tooltip: 'Nobody knows when this went in',
              icon: const Icon(Icons.close, size: 16),
              onPressed: () => context
                  .read<AppStateProvider>()
                  .setAvNodeInstalledOn(item.node.id, null),
            ),
        ],
      ),
    );
  }
}
