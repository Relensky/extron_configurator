import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'av_device_library.dart' show kPricingTierLabels;
import 'building_project.dart' show ManualRoom, ManualRoomItem;
import 'cost_estimate.dart' show formatMoney;
import 'manual_room_equipment.dart';

/// ============================================================================
///  WHAT IS IN A ROOM NOBODY HAS DRAWN
/// ============================================================================
///  The plan's line items carry one figure each and, until somebody draws the
///  room, no way to see behind it. A reader asked to put twenty-four thousand
///  in next year's request for AGYM 129 has every right to ask what is in AGYM
///  129, and "2 Projector" - the room type the estate's sheet priced it
///  against - is not an answer about that room.
///
///  This is the answer: the survey of the control system that runs it, by
///  model, with what each line would cost to buy today.
///
///  TWO FIGURES THAT ARE NOT THE SAME FIGURE, said plainly at the bottom
///  rather than left for somebody to discover by subtracting them. The plan's
///  cost is a REFRESH: new gear, cabling, mounting, labor. The survey's total
///  is what the boxes currently on the wall would cost to buy - no labor, no
///  cabling, and a good part of it priced off the base-cost card because the
///  catalog stopped carrying an eight-year-old projector. Neither is the
///  other, and the moment they are printed as one column somebody will
///  subtract them and call the difference labor.
///
///  AND IT IS EDITABLE, because the survey is a machine's reading of a room
///  and a machine gets rooms wrong. The poll files screen controllers as
///  control processors and reports a model that has been swapped out since;
///  somebody who has stood in the room knows better. Re-running the import
///  fixes it for everybody and is the right answer when the poll is wrong;
///  typing it here is the right answer when the ROOM is right and the poll
///  will never know - a projector borrowed to another building, a display
///  nobody ever put on the network.
///
///  A HAND EDIT IS NOT OVERWRITTEN QUIETLY: a re-import replaces the list and
///  prints every line it changed, so a correction that gets undone gets
///  undone in public. See tools/import_gve_equipment.py.
/// ============================================================================

/// Opens the report for [room]. Editing writes back through the provider, so
/// the change lands on the job and is written by the job's own Save.
Future<void> showManualRoomEquipment(
  BuildContext context,
  ManualRoom room, {
  required String currency,
}) => showDialog<void>(
  context: context,
  builder: (_) => ManualRoomEquipmentDialog(room: room, currency: currency),
);

class ManualRoomEquipmentDialog extends StatefulWidget {
  final ManualRoom room;
  final String currency;

  /// Where a saved list goes. Defaults to the open job's own line item, which
  /// is where every caller in the app wants it; a caller holding a project
  /// that is not the open one passes its own.
  final void Function(List<ManualRoomItem> items)? onSave;

  const ManualRoomEquipmentDialog({
    super.key,
    required this.room,
    required this.currency,
    this.onSave,
  });

  @override
  State<ManualRoomEquipmentDialog> createState() =>
      _ManualRoomEquipmentDialogState();
}

class _ManualRoomEquipmentDialogState extends State<ManualRoomEquipmentDialog> {
  /// The list being edited. A copy: closing without saving leaves the plan as
  /// it was, which is what makes it safe to open one of these and poke at it.
  late final List<ManualRoomItem> _items = [...widget.room.equipment];

  bool _dirty = false;

  void _change(int at, ManualRoomItem item) => setState(() {
    _items[at] = item;
    _dirty = true;
  });

  void _remove(int at) => setState(() {
    _items.removeAt(at);
    _dirty = true;
  });

  void _add() => setState(() {
    _items.add(const ManualRoomItem(model: ''));
    _dirty = true;
  });

  void _save() {
    // A row somebody added and never named is not a box in the room.
    final kept = [
      for (final item in _items)
        if (item.model.trim().isNotEmpty)
          item.copyWith(model: item.model.trim()),
    ];
    final save = widget.onSave;
    if (save != null) {
      save(kept);
    } else {
      context.read<AppStateProvider>().updateProjectManualRoomEquipment(
        widget.room.id,
        kept,
      );
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<AppStateProvider>();
    final tier = provider.pricingTier;
    final shown = widget.room.copyWith(equipment: _items);
    final total = manualRoomEquipmentTotal(
      shown,
      library: provider.avDeviceLibrary,
      baseCosts: provider.baseCosts,
      tier: tier,
    );
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    // The card's own lines, so a box typed in here is priced off the same
    // figures every other estimate in the app falls back to.
    final roles = [
      for (final c in provider.baseCosts.costs) c.category,
    ]..sort();

    return AlertDialog(
      key: const ValueKey('manual_room_equipment_dialog'),
      title: Row(
        children: [
          Expanded(child: Text('What is in ${widget.room.name}')),
          if (_dirty)
            Chip(
              label: const Text('Unsaved'),
              backgroundColor: theme.colorScheme.secondaryContainer,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      content: SizedBox(
        width: 900,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _items.isEmpty
                  ? 'Nothing has been surveyed in this room. Add what is in '
                        'there, or leave it: a line item with no survey is '
                        'still a date, a life and a figure.'
                  : 'What the control system reports is installed, priced at '
                        '${kPricingTierLabels[tier]?.toLowerCase()}. It is an '
                        'inventory, not a drawing: no positions, no cabling, '
                        'and nothing here is ordered. Correct anything the '
                        'poll got wrong.',
              style: muted,
            ),
            const SizedBox(height: 12),
            if (_items.isNotEmpty) ...[
              const _EquipmentHeaderRow(),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < _items.length; i++)
                        _EquipmentRow(
                          key: ValueKey('manual_room_equipment_row_$i'),
                          index: i,
                          item: _items[i],
                          roles: roles,
                          label: manualRoomItemLabel(
                            _items[i],
                            library: provider.avDeviceLibrary,
                          ),
                          price: manualRoomItemPrice(
                            _items[i],
                            library: provider.avDeviceLibrary,
                            baseCosts: provider.baseCosts,
                            tier: tier,
                          ),
                          currency: widget.currency,
                          onChanged: (item) => _change(i, item),
                          onRemove: () => _remove(i),
                        ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 17),
            ],
            Row(
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('manual_room_equipment_add'),
                  onPressed: _add,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add an item'),
                ),
                const SizedBox(width: 24),
                if (_items.isNotEmpty)
                  Expanded(
                    child: _Totals(
                      room: widget.room,
                      total: total,
                      currency: widget.currency,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('manual_room_equipment_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_dirty ? 'Cancel' : 'Close'),
        ),
        FilledButton(
          key: const ValueKey('manual_room_equipment_save'),
          onPressed: _dirty ? _save : null,
          child: const Text('Save to the line'),
        ),
      ],
    );
  }
}

/// The column widths, in one place, so the header and every row agree.
const double _kQtyWidth = 56;
const double _kRoleWidth = 190;
const double _kMoneyWidth = 100;
const double _kBinWidth = 40;

class _EquipmentHeaderRow extends StatelessWidget {
  const _EquipmentHeaderRow();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(width: _kQtyWidth, child: Text('QTY', style: style)),
          const SizedBox(width: 8),
          Expanded(child: Text('MODEL', style: style)),
          const SizedBox(width: 8),
          SizedBox(width: _kRoleWidth, child: Text('DOES', style: style)),
          SizedBox(
            width: _kMoneyWidth,
            child: Text('EACH', style: style, textAlign: TextAlign.right),
          ),
          SizedBox(
            width: _kMoneyWidth,
            child: Text('LINE', style: style, textAlign: TextAlign.right),
          ),
          const SizedBox(width: _kBinWidth),
        ],
      ),
    );
  }
}

/// One surveyed model: what it is, what it does, how many, and what it is
/// worth.
///
/// The money is READ ONLY and always will be. A price typed on an inventory
/// row would be a fourth figure on a screen that already has to keep two
/// apart; what a box costs is the catalog's answer or the card's, and both are
/// edited where they live. Correcting the MODEL is what moves the figure, and
/// that is the honest edit: the room has a different box in it.
class _EquipmentRow extends StatefulWidget {
  final int index;
  final ManualRoomItem item;

  /// The base-cost card's lines, for the role picker.
  final List<String> roles;

  /// The model as it should READ - see [manualRoomItemLabel].
  final String label;

  final ManualItemPrice price;
  final String currency;
  final ValueChanged<ManualRoomItem> onChanged;
  final VoidCallback onRemove;

  const _EquipmentRow({
    super.key,
    required this.index,
    required this.item,
    required this.roles,
    required this.label,
    required this.price,
    required this.currency,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  State<_EquipmentRow> createState() => _EquipmentRowState();
}

class _EquipmentRowState extends State<_EquipmentRow> {
  late final TextEditingController _model = TextEditingController(
    text: widget.item.model,
  );
  late final TextEditingController _quantity = TextEditingController(
    text: '${widget.item.quantity}',
  );

  @override
  void dispose() {
    _model.dispose();
    _quantity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final role = widget.item.category.trim();
    // A role the card has no line for is still what the survey said, so it
    // stays on the list rather than being silently reset to nothing the
    // moment somebody opens the picker.
    final options = <String>[
      '',
      ...widget.roles,
      if (role.isNotEmpty && !widget.roles.contains(role)) role,
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _kQtyWidth,
            child: TextField(
              key: ValueKey('manual_room_equipment_qty_${widget.index}'),
              controller: _quantity,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(isDense: true),
              onChanged: (v) => widget.onChanged(
                // A blank box mid-type is one, not none - the row is still a
                // box in the room while somebody is retyping the count.
                widget.item.copyWith(quantity: int.tryParse(v.trim()) ?? 1),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: ValueKey('manual_room_equipment_model_${widget.index}'),
                  controller: _model,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'model',
                  ),
                  onChanged: (v) =>
                      widget.onChanged(widget.item.copyWith(model: v)),
                ),
                // WHAT THE FIGURE IS ACTUALLY FOR, when it is not this box:
                // the successor to a retired model, or the model the card was
                // benchmarked on. And the maker, when the model alone is a
                // word like 'Controller'.
                if (widget.price.pricedAs.isNotEmpty ||
                    widget.label != widget.item.model)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      [
                        if (widget.label != widget.item.model) widget.label,
                        if (widget.price.pricedAs.isNotEmpty)
                          'priced as ${widget.price.pricedAs}',
                      ].join('  ·  '),
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: _kRoleWidth,
            child: DropdownButtonFormField<String>(
              key: ValueKey('manual_room_equipment_role_${widget.index}'),
              initialValue: options.contains(role) ? role : '',
              isExpanded: true,
              decoration: const InputDecoration(isDense: true),
              items: [
                for (final option in options)
                  DropdownMenuItem(
                    value: option,
                    child: Text(
                      option.isEmpty ? 'not priced' : option,
                      style: option.isEmpty
                          ? theme.textTheme.bodyMedium?.copyWith(color: muted)
                          : null,
                    ),
                  ),
              ],
              onChanged: (v) =>
                  widget.onChanged(widget.item.copyWith(category: v ?? '')),
            ),
          ),
          SizedBox(
            width: _kMoneyWidth,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                widget.price.unit <= 0
                    ? 'not priced'
                    : '${formatMoney(widget.price.unit, widget.currency)}'
                          '${widget.price.estimated ? ' est.' : ''}',
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: widget.price.unit <= 0 ? muted : null,
                ),
              ),
            ),
          ),
          SizedBox(
            width: _kMoneyWidth,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                widget.price.line <= 0
                    ? '-'
                    : formatMoney(widget.price.line, widget.currency),
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: widget.price.line <= 0 ? muted : null,
                ),
              ),
            ),
          ),
          SizedBox(
            width: _kBinWidth,
            child: IconButton(
              key: ValueKey('manual_room_equipment_remove_${widget.index}'),
              tooltip: 'Take this off the list',
              icon: const Icon(Icons.close, size: 18),
              onPressed: widget.onRemove,
            ),
          ),
        ],
      ),
    );
  }
}

/// The two figures, side by side, each saying what it is.
class _Totals extends StatelessWidget {
  final ManualRoom room;
  final ManualRoomEquipmentTotal total;
  final String currency;

  const _Totals({
    required this.room,
    required this.total,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${total.count} item${total.count == 1 ? '' : 's'} installed'
              '${total.unpriced > 0 ? ', ${total.unpriced} not priced' : ''}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(width: 12),
            Text(
              formatMoney(total.cost, currency),
              key: const ValueKey('manual_room_equipment_total'),
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
        Text(
          total.estimated
              ? 'To buy what is in there today. Some of it is priced off the '
                    'base-cost card rather than the catalog, marked est.'
              : 'To buy what is in there today.',
          style: muted,
        ),
        if (room.replacementCost > 0) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'On the plan, to refresh this room',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(width: 12),
              Text(
                formatMoney(room.replacementCost, currency),
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
          Text(
            'The estate\'s own figure, and the one the plan counts. It buys '
            'a NEW room, gear and cabling and mounting and labor, so it is '
            'not this list at today\'s prices and the difference is not '
            'labor.',
            textAlign: TextAlign.right,
            style: muted,
          ),
        ],
      ],
    );
  }
}
