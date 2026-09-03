import 'package:flutter/material.dart';
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
///  129, and "2 Projector" — the room type the estate's sheet priced it
///  against — is not an answer about that room.
///
///  This is the answer: the survey of the control system that runs it, by
///  model, with what each line would cost to buy today.
///
///  TWO FIGURES THAT ARE NOT THE SAME FIGURE, said plainly at the bottom
///  rather than left for somebody to discover by subtracting them. The plan's
///  cost is a REFRESH: new gear, cabling, mounting, labor. The survey's total
///  is what the boxes currently on the wall would cost to buy — no labor, no
///  cabling, and a good part of it priced off the base-cost card because the
///  catalog stopped carrying an eight-year-old projector. Neither is the
///  other, and the moment they are printed as one column somebody will
///  subtract them and call the difference labor.
///
///  READ ONLY. The survey is a record of what was found, and a room's
///  equipment is corrected by re-running the import or by drawing the room —
///  not by typing over the inventory on a budget screen.
/// ============================================================================

Future<void> showManualRoomEquipment(
  BuildContext context,
  ManualRoom room, {
  required String currency,
}) => showDialog<void>(
  context: context,
  builder: (_) => ManualRoomEquipmentDialog(room: room, currency: currency),
);

class ManualRoomEquipmentDialog extends StatelessWidget {
  final ManualRoom room;
  final String currency;

  const ManualRoomEquipmentDialog({
    super.key,
    required this.room,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<AppStateProvider>();
    final tier = provider.pricingTier;
    final total = manualRoomEquipmentTotal(
      room,
      library: provider.avDeviceLibrary,
      baseCosts: provider.baseCosts,
      tier: tier,
    );
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return AlertDialog(
      key: const ValueKey('manual_room_equipment_dialog'),
      title: Text('What is in ${room.name}'),
      content: SizedBox(
        width: 820,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              room.equipment.isEmpty
                  ? 'Nothing has been surveyed in this room. A line item with '
                        'no survey is still a date, a life and a figure: see '
                        'its notes for the room type it was priced against.'
                  : 'What the control system reports is installed, priced at '
                        '${kPricingTierLabels[tier]?.toLowerCase()}. It is an '
                        'inventory, not a drawing: no positions, no cabling, '
                        'and nothing here is ordered.',
              style: muted,
            ),
            if (room.equipment.isNotEmpty) ...[
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _EquipmentHeaderRow(),
                      const Divider(height: 1),
                      for (final item in room.equipment)
                        _EquipmentRow(
                          item: item,
                          label: manualRoomItemLabel(
                            item,
                            library: provider.avDeviceLibrary,
                          ),
                          price: manualRoomItemPrice(
                            item,
                            library: provider.avDeviceLibrary,
                            baseCosts: provider.baseCosts,
                            tier: tier,
                          ),
                          currency: currency,
                        ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 17),
              _Totals(room: room, total: total, currency: currency),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('manual_room_equipment_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// The column widths, in one place, so the header and every row agree.
const double _kQtyWidth = 44;
const double _kRoleWidth = 150;
const double _kMoneyWidth = 110;

class _EquipmentHeaderRow extends StatelessWidget {
  const _EquipmentHeaderRow();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: _kQtyWidth, child: Text('QTY', style: style)),
          Expanded(child: Text('MODEL', style: style)),
          SizedBox(width: _kRoleWidth, child: Text('DOES', style: style)),
          SizedBox(
            width: _kMoneyWidth,
            child: Text('EACH', style: style, textAlign: TextAlign.right),
          ),
          SizedBox(
            width: _kMoneyWidth,
            child: Text('LINE', style: style, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

/// One surveyed model, and what it is worth.
///
/// A figure off the base-cost card is marked on the row rather than in a
/// footnote — an estimate a reader has to look up is an estimate a reader
/// treats as a quote.
class _EquipmentRow extends StatelessWidget {
  final ManualRoomItem item;

  /// The model as it should READ - see [manualRoomItemLabel].
  final String label;

  final ManualItemPrice price;
  final String currency;

  const _EquipmentRow({
    required this.item,
    required this.label,
    required this.price,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final role = item.category.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _kQtyWidth,
            child: Text('${item.quantity}', style: theme.textTheme.bodyMedium),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodyMedium),
                // WHAT THE FIGURE IS ACTUALLY FOR, when it is not this box:
                // the successor to a retired model, or the model the card was
                // benchmarked on.
                if (price.pricedAs.isNotEmpty)
                  Text(
                    'priced as ${price.pricedAs}',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: _kRoleWidth,
            child: Text(
              role.isEmpty ? '-' : role,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
          ),
          SizedBox(
            width: _kMoneyWidth,
            child: Text(
              price.unit <= 0
                  ? 'not priced'
                  : '${formatMoney(price.unit, currency)}'
                        '${price.estimated ? ' est.' : ''}',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: price.unit <= 0 ? muted : null,
              ),
            ),
          ),
          SizedBox(
            width: _kMoneyWidth,
            child: Text(
              price.line <= 0 ? '-' : formatMoney(price.line, currency),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: price.line <= 0 ? muted : null,
              ),
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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${total.count} item${total.count == 1 ? '' : 's'} installed'
                '${total.unpriced > 0 ? ', ${total.unpriced} not priced' : ''}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Text(
              formatMoney(total.cost, currency),
              key: const ValueKey('manual_room_equipment_total'),
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          total.estimated
              ? 'To buy what is in there today. Some of it is priced off the '
                    'base-cost card rather than the catalog, marked est.'
              : 'To buy what is in there today.',
          style: muted,
        ),
        if (room.replacementCost > 0) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  'On the plan, to refresh this room',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              Text(
                formatMoney(room.replacementCost, currency),
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'The estate\'s own figure, and the one the plan counts. It buys a '
            'NEW room, gear and cabling and mounting and labor, so it is not '
            'this list at today\'s prices and the difference is not labor.',
            style: muted,
          ),
        ],
      ],
    );
  }
}
