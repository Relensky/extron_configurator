import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'building_project.dart';
import 'contrast.dart';
import 'cost_estimate.dart' show formatMoney;
import 'project_estimate.dart';
import 'project_schedule.dart' show formatScheduleDate;
import 'project_timeline_view.dart'
    show ClearDateButton, showProjectDatePicker;

/// ============================================================================
///  THE PAPERWORK AND THE PALLET
/// ============================================================================
///  Two questions that the rest of this tab could not answer, and that get
///  asked every week of a live job:
///
///    WHAT IS ON PO-1188, AND HAS ANY OF IT LANDED?
///    WHERE IS THE KIT — on the dock, on a shelf, or in the room?
///
///  The Timeline answers when each part has to be BOUGHT, and stops at the day
///  it arrives. The gap between arriving and being installed is where a job
///  actually loses things: eighteen wall plates arrive in March, six go into
///  103 in April, and in June nobody can say whether the other twelve are in
///  the basement or were never delivered at all.
///
///  SO AN ARRIVAL IS A ROW, NOT A TICK. Each one says what came, how many, on
///  which PO, when, and where it is now — and a part that turns up in three
///  shipments has three rows, which is what happened. See [ProjectDelivery].
///
///  EVERY NOTE IS SIGNED. The commentary a delivery attracts is written by
///  several people over several weeks and none of it should overwrite the rest,
///  so notes here are a list of entries with a name and a time on each rather
///  than one shared paragraph. The name is the Windows login, taken rather than
///  typed — see [ProjectNote].
///
///  NOTHING HERE CHANGES A PRICE. This pane records what happened to kit that
///  was already quoted; it cannot add a part to the job or alter what one
///  costs, which is why every edit on it leaves the estimate alone.
/// ============================================================================

/// The deliveries pane, as slivers for the project tab's one scroll view.
List<Widget> deliveriesSlivers(BuildContext context, ProjectEstimate estimate) {
  final provider = context.watch<AppStateProvider>();
  final project = provider.project;

  // The building code and room number - 'BSS 103' - the same way every other
  // pane names a room. See [ProjectRoomCost.codeName].
  final roomNames = estimate.roomCodeNames;
  final roomChoices = [
    for (final r in estimate.rooms)
      (id: r.ref.id, name: roomNames[r.ref.id] ?? r.ref.label),
  ];

  // Newest arrival first: a delivery log is read from the top, and what landed
  // this week is what somebody is looking for.
  final deliveries = [...project.deliveries]
    ..sort((a, b) {
      final ad = a.deliveredOn;
      final bd = b.deliveredOn;
      if (ad == null && bd == null) return b.id.compareTo(a.id);
      if (ad == null) return 1;
      if (bd == null) return -1;
      final byDate = bd.compareTo(ad);
      return byDate != 0 ? byDate : b.id.compareTo(a.id);
    });

  return [
    SliverToBoxAdapter(child: _AddPoBar(provider: provider)),
    if (project.purchaseOrders.isEmpty)
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(28, 4, 16, 8),
          child: Text(
            'No purchase orders on the job yet. A PO entered here can be '
            'picked from the Bought? box on any part, so the number is typed '
            'once instead of once per line.',
          ),
        ),
      )
    else ...[
      SliverToBoxAdapter(
        child: _SectionLabel(
          text: 'PURCHASE ORDERS (${project.purchaseOrders.length})',
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        sliver: SliverList.builder(
          itemCount: project.purchaseOrders.length,
          itemBuilder: (context, i) => _PoCard(
            po: project.purchaseOrders[i],
            provider: provider,
            estimate: estimate,
          ),
        ),
      ),
    ],
    SliverToBoxAdapter(
      child: Row(
        children: [
          Expanded(
            child: _SectionLabel(
              text: deliveries.isEmpty
                  ? 'DELIVERED'
                  : 'DELIVERED (${_onHandSummary(project)})',
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton.tonalIcon(
              key: const ValueKey('delivery_log_new'),
              icon: const Icon(Icons.add_box_outlined, size: 18),
              label: const Text('Log a delivery'),
              onPressed: () => showDeliveryDialog(
                context,
                provider: provider,
                estimate: estimate,
                rooms: roomChoices,
              ),
            ),
          ),
        ],
      ),
    ),
    if (deliveries.isEmpty)
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Center(
            child: Text(
              'Nothing logged as arrived.\n\n'
              'Log what turns up as it turns up: what came, how many, and '
              'where it went. A part that arrives in three shipments is three '
              'entries, so "six of the eighteen are in 103 and the rest are '
              'in the basement" is something the job can actually say.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      )
    else
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        sliver: SliverList.builder(
          itemCount: deliveries.length,
          itemBuilder: (context, i) => _DeliveryCard(
            row: deliveries[i],
            provider: provider,
            estimate: estimate,
            rooms: roomChoices,
            roomNames: roomNames,
          ),
        ),
      ),
    const SliverToBoxAdapter(child: SizedBox(height: 24)),
  ];
}

/// '14 units, 6 not in a room yet' - the figure the section heading carries,
/// and the one thing a delivery log is opened to find out.
String _onHandSummary(BuildingProject project) {
  var onHand = 0.0;
  var installed = 0.0;
  var rows = 0;
  for (final d in project.deliveries) {
    if (!d.isOnHand) continue;
    rows++;
    onHand += d.qty;
    if (d.isInstalled) installed += d.qty;
  }
  if (onHand == 0) return '$rows';
  final waiting = onHand - installed;
  return waiting == 0
      ? '${formatUnits(onHand)} units, all installed'
      : '${formatUnits(onHand)} units, ${formatUnits(waiting)} not in a room '
          'yet';
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 12, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  THE PURCHASE ORDERS
// ---------------------------------------------------------------------------

/// The row at the top that PO numbers are entered from.
///
/// A field and a button rather than a dialog, for the reason the to-do list's
/// add bar is one: the number is usually being read off an email, and a modal
/// between reading it and writing it down is enough friction to lose it. The
/// rest of the PO - who it went to, when it was raised, what it came to - is
/// filled in on the card afterwards, or never.
class _AddPoBar extends StatefulWidget {
  final AppStateProvider provider;

  const _AddPoBar({required this.provider});

  @override
  State<_AddPoBar> createState() => _AddPoBarState();
}

class _AddPoBarState extends State<_AddPoBar> {
  final TextEditingController _number = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _number.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _add() {
    final number = _number.text.trim();
    if (number.isEmpty) return;
    final existing = widget.provider.project.poByNumber(number);
    widget.provider.addProjectPo(number: number);
    _number.clear();
    _focus.requestFocus();
    setState(() {});
    if (existing != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${existing.number} is already on the job.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('po_new_number'),
              controller: _number,
              focusNode: _focus,
              decoration: const InputDecoration(
                labelText: 'Add a purchase order',
                hintText: 'PO-1188',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _add(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            key: const ValueKey('po_new_add'),
            onPressed: _add,
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

/// One purchase order: what it is, what is on it, and how much of that landed.
class _PoCard extends StatelessWidget {
  final ProjectPo po;
  final AppStateProvider provider;
  final ProjectEstimate estimate;

  const _PoCard({
    required this.po,
    required this.provider,
    required this.estimate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final project = provider.project;

    // What is on it, and how much of that is here. Counted off the ORDER
    // records rather than the delivery log, because the order is what says a
    // part was bought on this PO; the log says what turned up against it.
    final parts = project.partsOnPo(po.number);
    final names = {for (final m in estimate.master) m.key: m.description};
    final received = [
      for (final key in parts)
        if (project.orderForPart(key)?.isReceived == true) key,
    ];
    final landed = project.deliveriesForPo(po.number);

    return Card(
      key: ValueKey('po_card_${po.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.receipt_long, size: 18, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        po.number.trim().isEmpty ? 'PO' : po.number.trim(),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        [
                          _vendorName(project, po),
                          if (po.issuedOn != null)
                            'raised ${formatScheduleDate(po.issuedOn!)}',
                          if (po.expectedOn != null)
                            'promised ${formatScheduleDate(po.expectedOn!)}',
                          if (po.amount > 0)
                            formatMoney(po.amount, estimate.currency),
                        ].where((s) => s.isNotEmpty).join('  ·  '),
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: ValueKey('po_edit_${po.id}'),
                  tooltip: 'Edit this purchase order',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () => showPoDialog(context, provider, po),
                ),
                IconButton(
                  key: ValueKey('po_delete_${po.id}'),
                  tooltip: 'Take this purchase order off the job',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => provider.removeProjectPo(po.id),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _poSummary(
                parts: parts.length,
                received: received.length,
                landed: landed.length,
              ),
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            if (parts.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final key in parts.take(8))
                    Chip(
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                      label: Text(
                        names[key] ?? key,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  if (parts.length > 8)
                    Text(
                      '+${parts.length - 8} more',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                ],
              ),
            ],
            _NoteThread(
              notes: po.notes,
              fieldKey: 'po_note_${po.id}',
              onAdd: (text) => provider.addProjectPoNote(po.id, text),
            ),
          ],
        ),
      ),
    );
  }
}

/// What a PO card says under its number: how much is on it, and how much of
/// that has landed.
///
/// The parts come off the ORDER records - a part says which PO bought it - and
/// the deliveries off the arrival log, so a PO with parts on it and nothing
/// logged is a PO nobody has received yet rather than an empty one.
String _poSummary({
  required int parts,
  required int received,
  required int landed,
}) {
  String deliveries(int n) => n == 1 ? '1 delivery' : '$n deliveries';
  if (parts == 0) {
    return landed == 0
        ? 'Nothing points at this PO yet. Pick it in the Bought? box on a '
              'part, on the Timeline.'
        : '${deliveries(landed)} logged against it.';
  }
  return '$parts part${parts == 1 ? '' : 's'} bought on it - $received marked '
      'arrived'
      '${landed == 0 ? '' : ', ${deliveries(landed)} logged'}.';
}

/// Who a PO went to: the vendor on the job's list, or whatever was typed.
String _vendorName(BuildingProject project, ProjectPo po) {
  if (po.vendorId.isNotEmpty) {
    for (final v in project.vendors) {
      if (v.id == po.vendorId) return v.name;
    }
  }
  return po.vendor.trim();
}

/// Edits everything on a PO except the note thread.
Future<void> showPoDialog(
  BuildContext context,
  AppStateProvider provider,
  ProjectPo po,
) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _PoDialog(provider: provider, po: po),
  );
}

class _PoDialog extends StatefulWidget {
  final AppStateProvider provider;
  final ProjectPo po;

  const _PoDialog({required this.provider, required this.po});

  @override
  State<_PoDialog> createState() => _PoDialogState();
}

class _PoDialogState extends State<_PoDialog> {
  late final TextEditingController _number = TextEditingController(
    text: widget.po.number,
  );
  late final TextEditingController _vendor = TextEditingController(
    text: widget.po.vendor,
  );
  late final TextEditingController _amount = TextEditingController(
    text: widget.po.amount > 0 ? widget.po.amount.toStringAsFixed(2) : '',
  );
  late String _vendorId = widget.po.vendorId;
  late DateTime? _issued = widget.po.issuedOn;
  late DateTime? _expected = widget.po.expectedOn;
  String _error = '';

  @override
  void dispose() {
    _number.dispose();
    _vendor.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _save() {
    // The NUMBER goes through its own call, because changing it has to carry
    // every part and delivery that named the old one across with it - see
    // [BuildingProject.renamePo].
    final number = _number.text.trim();
    if (number.isEmpty) {
      setState(() => _error = 'A purchase order needs a number.');
      return;
    }
    if (number != widget.po.number &&
        !widget.provider.renameProjectPo(widget.po.id, number)) {
      setState(
        () => _error = 'The job already has a purchase order numbered '
            '$number.',
      );
      return;
    }

    final current =
        widget.provider.project.poById(widget.po.id) ?? widget.po;
    widget.provider.updateProjectPo(
      current.copyWith(
        vendorId: _vendorId,
        vendor: _vendorId.isEmpty ? _vendor.text.trim() : '',
        issuedOn: _issued,
        clearIssuedOn: _issued == null,
        expectedOn: _expected,
        clearExpectedOn: _expected == null,
        amount: double.tryParse(_amount.text.trim()) ?? 0,
      ),
      summary: 'details edited',
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vendors = widget.provider.project.vendors;

    return AlertDialog(
      title: const Text('Purchase order'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('po_dialog_number'),
                controller: _number,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'PO number',
                  helperText: 'Changing it moves every part and delivery that '
                      'names it.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: const ValueKey('po_dialog_vendor'),
                initialValue:
                    vendors.any((v) => v.id == _vendorId) ? _vendorId : '',
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Went to',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(
                    value: '',
                    child: Text('Somebody else - typed below'),
                  ),
                  for (final v in vendors)
                    DropdownMenuItem(
                      value: v.id,
                      child: Text(v.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _vendorId = v ?? ''),
              ),
              if (_vendorId.isEmpty) ...[
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('po_dialog_vendor_text'),
                  controller: _vendor,
                  decoration: const InputDecoration(
                    labelText: 'Vendor',
                    hintText: 'the distributor, the reseller, whoever it was',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _DateField(
                      label: 'Raised',
                      value: _issued,
                      buttonKey: const ValueKey('po_dialog_issued'),
                      onPick: (d) => setState(() => _issued = d),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _DateField(
                      label: 'Promised',
                      value: _expected,
                      buttonKey: const ValueKey('po_dialog_expected'),
                      onPick: (d) => setState(() => _expected = d),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('po_dialog_amount'),
                controller: _amount,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Raised for',
                  prefixText: widget.provider.project.currency,
                  helperText: 'What the PO was written for. Blank when nobody '
                      'has said.',
                  border: const OutlineInputBorder(),
                ),
              ),
              if (_error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _error,
                  key: const ValueKey('po_dialog_error'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: errorTextOn(theme.colorScheme, theme.cardColor),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('po_dialog_save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
//  THE DELIVERIES
// ---------------------------------------------------------------------------

/// The icon a state reads as. Kept beside the state rather than at each call
/// site, so the card, the dialog and the parts list cannot disagree.
IconData deliveryStateIcon(DeliveryState state) => switch (state) {
  DeliveryState.delivered => Icons.local_shipping_outlined,
  DeliveryState.stored => Icons.warehouse_outlined,
  DeliveryState.installed => Icons.check_circle_outline,
  DeliveryState.returned => Icons.undo,
};

/// One arrival: what came, where it is, and what people have said about it.
class _DeliveryCard extends StatelessWidget {
  final ProjectDelivery row;
  final AppStateProvider provider;
  final ProjectEstimate estimate;
  final List<({String id, String name})> rooms;
  final Map<String, String> roomNames;

  const _DeliveryCard({
    required this.row,
    required this.provider,
    required this.estimate,
    required this.rooms,
    required this.roomNames,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final qty = formatUnits(row.qty);
    final name = row.itemName.trim().isEmpty
        ? 'Something not on the equipment list'
        : row.itemName.trim();
    final room = roomNames[row.roomId] ?? '';

    return Card(
      key: ValueKey('delivery_card_${row.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(deliveryStateIcon(row.state), size: 18, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        qty.isEmpty ? name : '$qty x $name',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          // A lot that went back is not on the job any more,
                          // and reads as struck through rather than as one of
                          // the rows saying where the kit is.
                          decoration: row.isOnHand
                              ? null
                              : TextDecoration.lineThrough,
                        ),
                      ),
                      Text(
                        [
                          if (row.deliveredOn != null)
                            'arrived ${formatScheduleDate(row.deliveredOn!)}',
                          if (row.poNumber.trim().isNotEmpty)
                            'PO ${row.poNumber.trim()}',
                          if (row.state == DeliveryState.installed &&
                              room.isNotEmpty)
                            'in $room',
                          if (row.state == DeliveryState.installed &&
                              row.installedOn != null)
                            'installed '
                                '${formatScheduleDate(row.installedOn!)}',
                          if (row.state != DeliveryState.installed)
                            row.whereText,
                        ].where((s) => s.isNotEmpty).join('  ·  '),
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: ValueKey('delivery_edit_${row.id}'),
                  tooltip: 'Edit this delivery',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () => showDeliveryDialog(
                    context,
                    provider: provider,
                    estimate: estimate,
                    rooms: rooms,
                    existing: row,
                  ),
                ),
                IconButton(
                  key: ValueKey('delivery_delete_${row.id}'),
                  tooltip: 'Remove this delivery record',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => provider.removeProjectDelivery(row.id),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // WHERE IT IS, as one gesture. Moving a pallet from the dock to a
            // shelf to a room is the thing this pane is opened for, so it is a
            // row of buttons on the card rather than a dialog to open first.
            _WhereRow(row: row, provider: provider, rooms: rooms),
            _NoteThread(
              notes: row.notes,
              fieldKey: 'delivery_note_${row.id}',
              onAdd: (text) => provider.addProjectDeliveryNote(row.id, text),
              onRemove: (i) => provider.removeProjectDeliveryNote(row.id, i),
            ),
          ],
        ),
      ),
    );
  }
}

/// The four places a lot can be, as a segmented row.
class _WhereRow extends StatelessWidget {
  final ProjectDelivery row;
  final AppStateProvider provider;
  final List<({String id, String name})> rooms;

  const _WhereRow({
    required this.row,
    required this.provider,
    required this.rooms,
  });

  Future<void> _pick(BuildContext context, DeliveryState state) async {
    if (state == row.state) return;
    switch (state) {
      case DeliveryState.stored:
        final where = await _askText(
          context,
          title: 'Into storage',
          label: 'Where is it being held?',
          hint: 'Bessey basement, rack 3',
          initial: row.location,
          suggestions: provider.project.storageLocations,
        );
        if (where == null) return;
        provider.setProjectDeliveryState(
          row.id,
          DeliveryState.stored,
          location: where,
        );
      case DeliveryState.installed:
        final roomId = await _askRoom(context, rooms, row.roomId);
        if (roomId == null) return;
        provider.setProjectDeliveryState(
          row.id,
          DeliveryState.installed,
          roomId: roomId,
        );
      case DeliveryState.delivered:
      case DeliveryState.returned:
        provider.setProjectDeliveryState(row.id, state);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<DeliveryState>(
          key: ValueKey('delivery_state_${row.id}'),
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          segments: [
            for (final s in DeliveryState.values)
              ButtonSegment(
                value: s,
                icon: Icon(deliveryStateIcon(s), size: 16),
                label: Text(s.label),
              ),
          ],
          selected: {row.state},
          onSelectionChanged: (set) => _pick(context, set.first),
        ),
      ),
    );
  }
}

/// Asks for one line of text, offering what the job has typed before.
///
/// Suggestions rather than a fixed list, because a storage place is described
/// rather than enumerated - and retyping 'Bessey basement, rack 3' is how one
/// shelf becomes four spellings that no filter can put back together.
Future<String?> _askText(
  BuildContext context, {
  required String title,
  required String label,
  String hint = '',
  String initial = '',
  List<String> suggestions = const [],
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextPrompt(
    title: title,
    label: label,
    hint: hint,
    initial: initial,
    suggestions: suggestions,
  ),
);

/// The box behind [_askText].
///
/// Its own widget rather than a controller built beside the [showDialog] call,
/// because a controller disposed the moment the dialog pops is one the CLOSING
/// ANIMATION then rebuilds the field against - which throws, and did.
class _TextPrompt extends StatefulWidget {
  final String title;
  final String label;
  final String hint;
  final String initial;
  final List<String> suggestions;

  const _TextPrompt({
    required this.title,
    required this.label,
    required this.hint,
    required this.initial,
    required this.suggestions,
  });

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const ValueKey('delivery_where_text'),
            controller: _text,
            autofocus: true,
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: widget.hint,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          if (widget.suggestions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final s in widget.suggestions.take(6))
                  ActionChip(
                    label: Text(s),
                    onPressed: () => _text.text = s,
                  ),
              ],
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('delivery_where_save'),
        onPressed: () => Navigator.of(context).pop(_text.text),
        child: const Text('Save'),
      ),
    ],
  );
}

/// Asks which room a lot went into. '' is a real answer - "it is installed,
/// and which room is not something I can say from here" is better recorded
/// than refused.
Future<String?> _askRoom(
  BuildContext context,
  List<({String id, String name})> rooms,
  String initial,
) async {
  if (rooms.isEmpty) return '';
  var choice = rooms.any((r) => r.id == initial) ? initial : '';
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Installed'),
      content: SizedBox(
        width: 380,
        child: StatefulBuilder(
          builder: (context, setState) => DropdownButtonFormField<String>(
            key: const ValueKey('delivery_install_room'),
            initialValue: choice,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Which room did it go into?',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem(value: '', child: Text('Not saying')),
              for (final r in rooms)
                DropdownMenuItem(
                  value: r.id,
                  child: Text(r.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() => choice = v ?? ''),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('delivery_install_save'),
          onPressed: () => Navigator.of(ctx).pop(choice),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
//  THE SIGNED NOTES
// ---------------------------------------------------------------------------

/// A thread of signed notes, and the box that adds to it.
///
/// Append-only by design: an entry says what one person knew on one day, and
/// a later correction is another entry rather than a rewrite of theirs. See
/// the note above [ProjectNote].
class _NoteThread extends StatefulWidget {
  final List<ProjectNote> notes;

  /// Distinguishes this box from every other one on the pane, so the text in
  /// it belongs to the row it was typed on.
  final String fieldKey;

  final ValueChanged<String> onAdd;

  /// Null on a thread nothing can be removed from - a PO's, where the note is
  /// usually the only record of a call with the vendor.
  final ValueChanged<int>? onRemove;

  const _NoteThread({
    required this.notes,
    required this.fieldKey,
    required this.onAdd,
    this.onRemove,
  });

  @override
  State<_NoteThread> createState() => _NoteThreadState();
}

class _NoteThreadState extends State<_NoteThread> {
  final TextEditingController _text = TextEditingController();

  /// Whether the older entries are showing. Collapsed by default: a row with
  /// eleven notes on it should not push the next row off the screen.
  bool _expanded = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _add() {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    widget.onAdd(text);
    _text.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    // Newest last, the way a conversation reads.
    final notes = widget.notes;
    final hidden = _expanded ? 0 : (notes.length - 2).clamp(0, notes.length);
    final showing = notes.sublist(hidden);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hidden > 0)
          TextButton(
            key: ValueKey('${widget.fieldKey}_expand'),
            onPressed: () => setState(() => _expanded = true),
            child: Text('Show $hidden earlier note${hidden == 1 ? '' : 's'}'),
          ),
        for (var i = 0; i < showing.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: theme.textTheme.bodySmall,
                      children: [
                        TextSpan(text: showing[i].text),
                        TextSpan(
                          text: '   ${_signature(showing[i])}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.onRemove != null)
                  IconButton(
                    key: ValueKey('${widget.fieldKey}_remove_${hidden + i}'),
                    tooltip: 'Remove this note',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 14),
                    onPressed: () => widget.onRemove!(hidden + i),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey(widget.fieldKey),
                  controller: _text,
                  decoration: const InputDecoration(
                    hintText: 'Add a note - it is signed and dated for you',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  style: theme.textTheme.bodySmall,
                  onSubmitted: (_) => _add(),
                ),
              ),
              IconButton(
                key: ValueKey('${widget.fieldKey}_add'),
                tooltip: 'Add this note',
                icon: const Icon(Icons.send, size: 16),
                onPressed: _add,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// '- dstanley, 12 Mar 2026 14:32'. The name first, because on a thread of
/// four the question is who said it before it is when.
String _signature(ProjectNote note) {
  final when = '${formatScheduleDate(note.at)} '
      '${note.at.hour.toString().padLeft(2, '0')}:'
      '${note.at.minute.toString().padLeft(2, '0')}';
  return note.user.isEmpty ? '- $when' : '- ${note.user}, $when';
}

// ---------------------------------------------------------------------------
//  LOGGING ONE
// ---------------------------------------------------------------------------

/// Logs an arrival, or edits one already logged.
///
/// The one dialog on this pane, because an arrival is genuinely several facts
/// at once - what, how many, on which PO, when, where - and asking for them in
/// sequence off the card would be five gestures for one pallet.
Future<void> showDeliveryDialog(
  BuildContext context, {
  required AppStateProvider provider,
  required ProjectEstimate estimate,
  required List<({String id, String name})> rooms,
  ProjectDelivery? existing,
  String partKey = '',
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _DeliveryDialog(
      provider: provider,
      estimate: estimate,
      rooms: rooms,
      existing: existing,
      partKey: partKey,
    ),
  );
}

/// The sentinel the part dropdown uses for "not on the equipment list".
///
/// Not a master key - those always carry a '|' - so it can never collide with
/// one, the same trick the parts list's filters use.
const String _kOffList = '<off-list>';

class _DeliveryDialog extends StatefulWidget {
  final AppStateProvider provider;
  final ProjectEstimate estimate;
  final List<({String id, String name})> rooms;
  final ProjectDelivery? existing;

  /// Which part the dialog opens on, when it was opened FROM one.
  final String partKey;

  const _DeliveryDialog({
    required this.provider,
    required this.estimate,
    required this.rooms,
    this.existing,
    this.partKey = '',
  });

  @override
  State<_DeliveryDialog> createState() => _DeliveryDialogState();
}

class _DeliveryDialogState extends State<_DeliveryDialog> {
  late String _partKey = widget.existing?.partKey ?? widget.partKey;
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.itemName ?? '',
  );
  late final TextEditingController _qty = TextEditingController(
    text: widget.existing == null ? '' : formatUnits(widget.existing!.qty),
  );
  late final TextEditingController _po = TextEditingController(
    text: widget.existing?.poNumber ?? '',
  );
  late final TextEditingController _location = TextEditingController(
    text: widget.existing?.location ?? '',
  );
  late final TextEditingController _note = TextEditingController();
  late DateTime? _delivered = widget.existing?.deliveredOn ?? today();
  late DateTime? _installed = widget.existing?.installedOn;
  late DeliveryState _state =
      widget.existing?.state ?? DeliveryState.delivered;
  late String _roomId = widget.existing?.roomId ?? '';

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    _po.dispose();
    _location.dispose();
    _note.dispose();
    super.dispose();
  }

  /// What the row is called: the part's own description when it is on the
  /// list, otherwise whatever was typed.
  String get _itemName {
    if (_partKey.isNotEmpty && _partKey != _kOffList) {
      for (final m in widget.estimate.master) {
        if (m.key == _partKey) return m.description;
      }
    }
    return _name.text.trim();
  }

  void _save() {
    final key = _partKey == _kOffList ? '' : _partKey;
    final qty = double.tryParse(_qty.text.trim()) ?? 0;
    final existing = widget.existing;
    if (existing == null) {
      widget.provider.addProjectDelivery(
        partKey: key,
        itemName: _itemName,
        poNumber: _po.text,
        qty: qty,
        deliveredOn: _delivered,
        state: _state,
        location: _location.text,
        roomId: _state == DeliveryState.installed ? _roomId : '',
        installedOn: _state == DeliveryState.installed
            ? (_installed ?? _delivered ?? today())
            : null,
        note: _note.text,
      );
    } else {
      widget.provider.updateProjectDelivery(
        existing.copyWith(
          partKey: key,
          itemName: _itemName,
          poNumber: _po.text.trim(),
          qty: qty,
          deliveredOn: _delivered,
          clearDeliveredOn: _delivered == null,
          state: _state,
          location: _location.text,
          roomId: _state == DeliveryState.installed ? _roomId : '',
          installedOn: _state == DeliveryState.installed
              ? (_installed ?? _delivered ?? today())
              : null,
          clearInstalledOn: _state != DeliveryState.installed,
        ),
        summary: 'edited - ${_state.phrase}',
      );
      if (_note.text.trim().isNotEmpty) {
        widget.provider.addProjectDeliveryNote(existing.id, _note.text);
      }
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.provider.project;
    final poNumbers = project.poNumbersInUse;
    // Only the parts the job actually buys. A delivery of something that is
    // not on the list is still loggable - that is what the last entry is for.
    final master = widget.estimate.master;
    final known = master.any((m) => m.key == _partKey);

    return AlertDialog(
      title: Text(widget.existing == null ? 'Log a delivery' : 'Delivery'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                key: const ValueKey('delivery_part'),
                initialValue: known ? _partKey : _kOffList,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'What arrived',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final m in master)
                    DropdownMenuItem(
                      value: m.key,
                      child: Text(
                        m.description,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  const DropdownMenuItem(
                    value: _kOffList,
                    child: Text('Something not on the equipment list'),
                  ),
                ],
                onChanged: (v) => setState(() => _partKey = v ?? _kOffList),
              ),
              if (!known || _partKey == _kOffList) ...[
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('delivery_name'),
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'What is it',
                    hintText: 'a loaner, a box of connectors, a tool',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 110,
                    child: TextField(
                      key: const ValueKey('delivery_qty'),
                      controller: _qty,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: 'How many',
                        hintText: _partKey.isEmpty || _partKey == _kOffList
                            ? ''
                            : formatUnits(_qtyOnJob(master, _partKey)),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _PoField(
                      controller: _po,
                      numbers: poNumbers,
                      onPicked: (v) => setState(() => _po.text = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _DateField(
                      label: 'Arrived',
                      value: _delivered,
                      buttonKey: const ValueKey('delivery_arrived'),
                      onPick: (d) => setState(() => _delivered = d),
                    ),
                  ),
                ],
              ),
              if (_partKey.isNotEmpty && _partKey != _kOffList)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _alreadyHere(project, master, _partKey),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              DropdownButtonFormField<DeliveryState>(
                key: const ValueKey('delivery_state'),
                initialValue: _state,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Where is it now',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final s in DeliveryState.values)
                    DropdownMenuItem(
                      value: s,
                      child: Row(
                        children: [
                          Icon(deliveryStateIcon(s), size: 16),
                          const SizedBox(width: 8),
                          Text(s.label),
                        ],
                      ),
                    ),
                ],
                onChanged: (v) =>
                    setState(() => _state = v ?? DeliveryState.delivered),
              ),
              if (_state == DeliveryState.stored) ...[
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('delivery_location'),
                  controller: _location,
                  decoration: InputDecoration(
                    labelText: 'Held where',
                    hintText: project.storageLocations.isEmpty
                        ? 'Bessey basement, rack 3'
                        : project.storageLocations.first,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
              if (_state == DeliveryState.installed) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: const ValueKey('delivery_room'),
                        initialValue: widget.rooms.any((r) => r.id == _roomId)
                            ? _roomId
                            : '',
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'In which room',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: Text('Not saying'),
                          ),
                          for (final r in widget.rooms)
                            DropdownMenuItem(
                              value: r.id,
                              child: Text(
                                r.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _roomId = v ?? ''),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _DateField(
                        label: 'Installed',
                        value: _installed ?? _delivered,
                        buttonKey: const ValueKey('delivery_installed_on'),
                        onPick: (d) => setState(() => _installed = d),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('delivery_note'),
                controller: _note,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Note',
                  hintText: '2 of the 6 arrived damaged, Extron collecting',
                  helperText: 'Signed with your name and the time.',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('delivery_save'),
          onPressed: _save,
          child: Text(widget.existing == null ? 'Log it' : 'Save'),
        ),
      ],
    );
  }
}

/// How many of a part the job is buying, for the "how many" hint.
double _qtyOnJob(List<MasterPartLine> master, String key) {
  for (final m in master) {
    if (m.key == key) return m.qty;
  }
  return 0;
}

/// 'The job buys 18. 6 already logged as arrived, 6 in a room.' — the sentence
/// that stops the same pallet being logged twice.
String _alreadyHere(
  BuildingProject project,
  List<MasterPartLine> master,
  String key,
) {
  final ordered = _qtyOnJob(master, key);
  final here = project.deliveredQty(key);
  final installed = project.installedQty(key);
  final parts = <String>[
    if (ordered > 0) 'The job buys ${formatUnits(ordered)}.',
    if (here > 0)
      '${formatUnits(here)} already logged as arrived'
          '${installed > 0 ? ', ${formatUnits(installed)} in a room' : ''}.',
  ];
  return parts.isEmpty ? '' : parts.join(' ');
}

/// A PO number field with the job's existing numbers one click away.
class _PoField extends StatelessWidget {
  final TextEditingController controller;
  final List<String> numbers;
  final ValueChanged<String> onPicked;

  const _PoField({
    required this.controller,
    required this.numbers,
    required this.onPicked,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey('delivery_po'),
      controller: controller,
      decoration: InputDecoration(
        labelText: 'PO',
        border: const OutlineInputBorder(),
        isDense: true,
        suffixIcon: numbers.isEmpty
            ? null
            : PopupMenuButton<String>(
                key: const ValueKey('delivery_po_pick'),
                tooltip: 'Pick a purchase order on the job',
                icon: const Icon(Icons.arrow_drop_down),
                itemBuilder: (_) => [
                  for (final n in numbers)
                    PopupMenuItem(value: n, child: Text(n)),
                ],
                onSelected: onPicked,
              ),
      ),
    );
  }
}

/// A labelled date on a dialog, with the × that takes it back off.
class _DateField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onPick;
  final Key? buttonKey;

  const _DateField({
    required this.label,
    required this.value,
    required this.onPick,
    this.buttonKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            key: buttonKey,
            onPressed: () async {
              final picked = await showProjectDatePicker(
                context,
                initial: value,
                title: label,
              );
              if (picked == null) return;
              onPick(picked.date);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelSmall),
                Text(
                  value == null ? 'not set' : formatScheduleDate(value!),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontStyle: value == null ? FontStyle.italic : null,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (value != null)
          ClearDateButton(
            tooltip: 'Take the $label date back off',
            onPressed: () => onPick(null),
          ),
      ],
    );
  }
}
