import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'building_project.dart';
import 'contrast.dart';
import 'cost_estimate.dart' show formatMoney;
import 'pdf_viewer_dialog.dart';
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
            'No purchase orders on the job yet. Enter one and it can be '
            'given the equipment it bought in one pass, picked from the '
            'Bought? box on any part, and pulled onto a delivery off the '
            'packing slip - so the number is typed once instead of once per '
            'line.',
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
          // TWO WAYS IN, because a delivery is either one thing or a truck.
          // The second only appears when there is an equipment list to tick
          // against - it has nothing to offer a job whose parts are not
          // costed yet.
          if (estimate.master.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                key: const ValueKey('delivery_log_many'),
                icon: const Icon(Icons.playlist_add_check, size: 18),
                label: const Text('Log several'),
                onPressed: () => showBulkDeliveryDialog(
                  context,
                  provider: provider,
                  estimate: estimate,
                  rooms: roomChoices,
                ),
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
              'in the basement" is something the job can actually say.\n\n'
              'A delivery does not need a PO or a part on the equipment list. '
              'What went on a card is ticked as a one-off purchase and '
              'tracked here like everything else.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      )
    else ...[
      SliverToBoxAdapter(child: _PaperworkLine(project: project)),
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
    ],
    const SliverToBoxAdapter(child: SizedBox(height: 24)),
  ];
}

/// What the log is carrying that is not on a purchase order: the card
/// purchases, and the rows nobody has said anything about.
///
/// At the TOP of the list rather than left to be found by scrolling. Both
/// numbers are read at a glance and neither is visible any other way — one is
/// spend that appears on no estimate and no PO, and the other is the set of
/// rows that cannot be reconciled against anything at all.
class _PaperworkLine extends StatelessWidget {
  final BuildingProject project;

  const _PaperworkLine({required this.project});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final oneOffs = project.oneOffDeliveries.length;
    final loose = project.deliveriesNeedingPaperwork.length;
    if (oneOffs == 0 && loose == 0) return const SizedBox.shrink();

    String rows(int n) => n == 1 ? '1 delivery' : '$n deliveries';
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (loose > 0) ...[
            Icon(
              Icons.warning_amber,
              size: 16,
              color: warningOn(theme.scaffoldBackgroundColor),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              [
                if (oneOffs > 0)
                  '${rows(oneOffs)} bought as a one-off, outside the PO '
                      'process.',
                if (loose > 0)
                  '${rows(loose)} on no PO and not marked as a one-off.',
              ].join('  '),
              key: const ValueKey('delivery_paperwork_line'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: loose > 0
                    ? warningOn(theme.scaffoldBackgroundColor)
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
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
    final project = widget.provider.project;
    // Everything the job mentions anywhere, minus what already has a row -
    // see [BuildingProject.poNumbersInUse].
    final loose = [
      for (final n in project.poNumbersInUse)
        if (project.poByNumber(n) == null) n,
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('po_new_number'),
              controller: _number,
              focusNode: _focus,
              decoration: InputDecoration(
                labelText: 'Add a purchase order',
                hintText: 'PO-1188',
                helperText: loose.isEmpty
                    ? null
                    : '${loose.length} number'
                          '${loose.length == 1 ? '' : 's'} on the job have no '
                          'row yet',
                border: const OutlineInputBorder(),
                isDense: true,
                // NUMBERS THE JOB ALREADY KNOWS AND HAS NO ROW FOR. A PO
                // marked on a vendor, typed onto a part or written on a
                // delivery is a number that exists; until somebody raises the
                // row for it there is nothing to attach the order to and
                // nothing to tick equipment onto. Offering them here is the
                // difference between finding that out and retyping a number
                // off another screen.
                suffixIcon: loose.isEmpty
                    ? null
                    : PopupMenuButton<String>(
                        key: const ValueKey('po_new_pick'),
                        tooltip: 'A number the job mentions but has no row for',
                        icon: const Icon(Icons.arrow_drop_down),
                        itemBuilder: (_) => [
                          for (final n in loose)
                            PopupMenuItem(value: n, child: Text(n)),
                        ],
                        onSelected: (v) {
                          _number.text = v;
                          _focus.requestFocus();
                          setState(() {});
                        },
                      ),
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
            const SizedBox(height: 6),
            // WHAT IT BOUGHT, from the PO. The Bought? box on a part answers
            // "what did this go out on"; nothing answered "what went out on
            // this", which is the question a PO is opened with and the one
            // that has to be answered before a packing slip can be checked
            // against anything.
            //
            // Beside it, THE ORDER ITSELF - see [PoFileButtons]. The two are
            // one row because they are the two halves of the same question:
            // what we think we bought, and what the paper says we bought.
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  key: ValueKey('po_parts_${po.id}'),
                  icon: const Icon(Icons.playlist_add_check, size: 18),
                  label: Text(
                    parts.isEmpty
                        ? 'Put equipment on this PO'
                        : 'Equipment on this PO (${parts.length})',
                  ),
                  onPressed: () => showPoPartsDialog(
                    context,
                    provider: provider,
                    estimate: estimate,
                    po: po,
                  ),
                ),
                PoFileButtons(po: po, provider: provider),
              ],
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
        ? 'Nothing points at this PO yet. Tick what it bought below, or pick '
              'it in the Bought? box on a part, on the Timeline.'
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

/// Puts the equipment a purchase order bought ON that purchase order.
///
/// A PO goes to ONE vendor and covers that vendor's lines, which is why this
/// is opened from the PO and opens filtered to that vendor: "everything Extron
/// quoted went out on PO-1188" is one decision, and the Bought? box on each
/// part makes it nineteen. What happened when it was nineteen is that the
/// first three got the number and the other sixteen read on the timeline as
/// parts nobody had ordered.
///
/// Ticking is the whole interaction. A part ticked is on the PO; a part
/// unticked is off it and keeps everything else its order record says. See
/// [BuildingProject.setPartsOnPo].
Future<void> showPoPartsDialog(
  BuildContext context, {
  required AppStateProvider provider,
  required ProjectEstimate estimate,
  required ProjectPo po,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _PoPartsDialog(
      provider: provider,
      estimate: estimate,
      po: po,
    ),
  );
}

class _PoPartsDialog extends StatefulWidget {
  final AppStateProvider provider;
  final ProjectEstimate estimate;
  final ProjectPo po;

  const _PoPartsDialog({
    required this.provider,
    required this.estimate,
    required this.po,
  });

  @override
  State<_PoPartsDialog> createState() => _PoPartsDialogState();
}

class _PoPartsDialogState extends State<_PoPartsDialog> {
  /// Every part that is to be on the PO when this is saved. Seeded with what
  /// is on it already, so the box opens saying what the job currently thinks
  /// rather than empty.
  late final Set<String> _checked = {
    ...widget.provider.project.partsOnPo(widget.po.number),
  };

  final TextEditingController _search = TextEditingController();

  /// Show only the lines tagged to the PO's vendor.
  ///
  /// On by default when the PO names a vendor who has lines on the job: that
  /// is the list somebody opened this to tick, and a hundred-line master list
  /// with every other vendor mixed into it is one nobody reads to the bottom
  /// of.
  late bool _vendorOnly = _vendorLines().isNotEmpty;

  /// The day the order went in, for the parts that do not already say. The
  /// PO's own date to start with, because that is what it usually was.
  late DateTime? _ordered = widget.po.issuedOn;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The master lines this PO is most likely buying.
  ///
  /// THE PACKAGE THAT RAISED IT first, matched on the PO NUMBER - which is the
  /// link everything else on a job uses, and the only one that works before an
  /// award has given any part a supplier at all. A PO raised straight off a
  /// package is the ordinary case, and its whole line list is the answer.
  ///
  /// Failing that, every package the PO's vendor has WON: a number typed in by
  /// hand on the Deliveries pane still lines up with what that company is
  /// supplying. And failing that, the vendor's name off the row, so a PO
  /// raised on a distributor that never earned a vendor row still narrows to
  /// something.
  List<MasterPartLine> _vendorLines() {
    final project = widget.provider.project;
    final rfq = project.rfqByPoNumber(widget.po.number);
    if (rfq != null) {
      return [
        for (final m in widget.estimate.master)
          if (m.rfq?.id == rfq.id) m,
      ];
    }
    final id = widget.po.vendorId.trim();
    final name = widget.po.vendor.trim().toLowerCase();
    if (id.isEmpty && name.isEmpty) return const [];
    return [
      for (final m in widget.estimate.master)
        if (id.isNotEmpty
            ? m.vendor?.id == id
            : (m.vendor?.name.trim().toLowerCase() ?? '') == name)
          m,
    ];
  }

  /// What the list shows: the vendor's lines or all of them, narrowed by
  /// whatever has been typed in the search box.
  List<MasterPartLine> get _shown {
    final base = _vendorOnly ? _vendorLines() : widget.estimate.master;
    final needle = _search.text.trim().toLowerCase();
    if (needle.isEmpty) return base;
    return [
      for (final m in base)
        if (m.description.toLowerCase().contains(needle) ||
            m.model.toLowerCase().contains(needle) ||
            m.partNumber.toLowerCase().contains(needle))
          m,
    ];
  }

  /// The PO a part is already bought on, when it is not this one - the thing
  /// that has to be said out loud before a tick moves it.
  String _otherPo(String key) {
    final number = widget.provider.project.orderForPart(key)?.poNumber ?? '';
    if (number.trim().isEmpty) return '';
    return normalizePoNumber(number) == normalizePoNumber(widget.po.number)
        ? ''
        : number.trim();
  }

  void _save() {
    final master = widget.estimate.master;
    final names = {for (final m in master) m.key: m.description};
    // Only the parts on the MASTER LIST can be unticked here, because they are
    // the only ones this box could have shown. A PO carrying a key that has
    // since dropped off the job keeps it - that is history, not a mistake to
    // tidy away behind somebody's back.
    final onIt = <String>[];
    final offIt = <String>[];
    for (final m in master) {
      (_checked.contains(m.key) ? onIt : offIt).add(m.key);
    }
    widget.provider.setProjectPartsOnPo(
      widget.po.number,
      onIt: onIt,
      offIt: offIt,
      orderedOn: _ordered,
      expectedOn: widget.po.expectedOn,
      partNames: names,
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final shown = _shown;
    final vendor = _vendorName(widget.provider.project, widget.po);
    final number = widget.po.number.trim().isEmpty
        ? 'this PO'
        : widget.po.number.trim();

    var units = 0.0;
    for (final m in widget.estimate.master) {
      if (_checked.contains(m.key)) units += m.qty;
    }

    return AlertDialog(
      key: const ValueKey('po_parts_dialog'),
      title: Text('What is on $number'),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              vendor.isEmpty
                  ? 'Tick what this purchase order bought.'
                  : 'Tick what $vendor is supplying on this purchase order.',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('po_parts_search'),
                    controller: _search,
                    decoration: const InputDecoration(
                      labelText: 'Find a part',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 190,
                  child: _DateField(
                    label: 'Ordered',
                    value: _ordered,
                    buttonKey: const ValueKey('po_parts_ordered'),
                    onPick: (d) => setState(() => _ordered = d),
                  ),
                ),
              ],
            ),
            if (_vendorLines().isNotEmpty)
              CheckboxListTile(
                key: const ValueKey('po_parts_vendor_only'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _vendorOnly,
                title: Text(
                  vendor.isEmpty
                      ? 'Only this vendor\'s parts'
                      : 'Only $vendor\'s parts',
                  style: theme.textTheme.bodySmall,
                ),
                onChanged: (v) => setState(() => _vendorOnly = v ?? false),
              ),
            const Divider(height: 8),
            SizedBox(
              height: 320,
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        widget.estimate.master.isEmpty
                            ? 'There is no equipment on the job yet.'
                            : 'Nothing matches.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final m = shown[i];
                        final other = _otherPo(m.key);
                        return CheckboxListTile(
                          key: ValueKey('po_part_${m.key}'),
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _checked.contains(m.key),
                          title: Text(
                            m.description,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              '${formatUnits(m.qty)} on the job',
                              if (m.vendor != null) m.vendor!.name,
                              // Said out loud rather than silently moved: a
                              // part bought on another PO is a fact somebody
                              // entered, and a tick here overwrites it.
                              if (other.isNotEmpty) 'currently on $other',
                            ].join('  ·  '),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: muted,
                            ),
                          ),
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _checked.add(m.key);
                            } else {
                              _checked.remove(m.key);
                            }
                          }),
                        );
                      },
                    ),
            ),
            const Divider(height: 8),
            Text(
              _checked.isEmpty
                  ? 'Nothing on it.'
                  : '${_checked.length} part'
                        '${_checked.length == 1 ? '' : 's'}'
                        '${units > 0 ? ', ${formatUnits(units)} units' : ''}'
                        ' on $number.',
              key: const ValueKey('po_parts_count'),
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('po_parts_save'),
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
                            'PO ${row.poNumber.trim()}'
                          // A card purchase says so where the PO would be:
                          // "bought outside the process" is the answer to the
                          // same question, not the absence of one.
                          else if (row.oneOff)
                            'one-off purchase - P-Card',
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
            // NOT ON ANYTHING. Said on the card rather than only in the
            // dialog that made it, because the row somebody has to come back
            // to is found by scrolling this list - and a delivery that names
            // neither a PO nor a card is the one that cannot be reconciled
            // against an order, an invoice or a statement later.
            if (row.needsPaperwork)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber,
                      size: 16,
                      color: warningOn(theme.cardColor),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Not on a PO or an order number. Edit it to pick one, '
                        'or tick "one-off purchase" if it went on a card.',
                        key: ValueKey('delivery_no_po_${row.id}'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: warningOn(theme.cardColor),
                        ),
                      ),
                    ),
                  ],
                ),
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
          hint: 'MLIB 031, rack 3',
          initial: row.location,
          suggestions: provider.project.deliveryLocations,
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
  late bool _oneOff = widget.existing?.oneOff ?? false;

  /// The number the part dropdown filled in for itself, so switching parts can
  /// replace it without ever stepping on one somebody typed.
  String _autoPo = '';

  @override
  void initState() {
    super.initState();
    // A NEW ROW OPENS WITH THE PO ALREADY ON IT. The order record knows what
    // bought this part; making somebody read the number off the same job they
    // are standing in and retype it is how a delivery ends up on PO-1188 when
    // the part went out on PO-1204.
    if (widget.existing == null) _fillPoForPart();
  }

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

  /// What is missing from this row, said before it is saved rather than
  /// discovered in June.
  ///
  /// IT DOES NOT STOP THE SAVE. A pallet that turned up is a fact whether or
  /// not the paperwork has caught up, and a log that refuses the rows it does
  /// not like is a log people keep somewhere else. It warns, and the row is
  /// counted as unreconciled on the pane and in the workbook until somebody
  /// says what bought it — see [ProjectDelivery.needsPaperwork].
  String get _warning {
    final noPaperwork = _po.text.trim().isEmpty && !_oneOff;
    final noName = _itemName.trim().isEmpty;
    if (!noPaperwork && !noName) return '';
    if (noPaperwork && noName) {
      return 'Nothing here says what this is or what bought it. Log it '
          'anyway if that is all anybody knows - but a PO, a name, or the '
          'one-off box is what makes it findable later.';
    }
    if (noPaperwork) {
      return 'No PO on this row. Pick one above, or tick the one-off box if '
          'it went on a card - a delivery that says neither is one nobody '
          'can reconcile against an order later.';
    }
    return 'Nothing says what this is. It will read as "something not on the '
        'equipment list" everywhere it appears.';
  }

  /// The PO the job's order record says bought [key] - empty when nothing
  /// says, and for anything that is not on the equipment list.
  String _poForPart(String key) {
    if (key.isEmpty || key == _kOffList) return '';
    return widget.provider.project.orderForPart(key)?.poNumber.trim() ?? '';
  }

  /// Puts the selected part's PO in the box, if the box is free to take it.
  ///
  /// FREE MEANS EMPTY, OR STILL HOLDING WHAT THIS FILLED IN LAST TIME. A
  /// number somebody typed is what the packing slip said and outranks the
  /// order record; a number this put there is a guess, and switching parts
  /// makes it the wrong guess - so it goes, even when the new part has no PO
  /// to put in its place.
  void _fillPoForPart() {
    if (_oneOff) return;
    final typed = _po.text.trim();
    if (typed.isNotEmpty && typed != _autoPo) return;
    final number = _poForPart(_partKey);
    if (typed.isEmpty && number.isEmpty) return;
    _po.text = number;
    _autoPo = number;
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
        oneOff: _oneOff,
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
          oneOff: _oneOff,
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
                onChanged: (v) => setState(() {
                  _partKey = v ?? _kOffList;
                  _fillPoForPart();
                }),
              ),
              if (!known || _partKey == _kOffList) ...[
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('delivery_name'),
                  controller: _name,
                  // Keeps the warning below in step with what is typed: a name
                  // that arrives makes half of it go away.
                  onChanged: (_) => setState(() {}),
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
                      // A one-off went on a card. There is no PO, there was
                      // never going to be one, and a box that still invites a
                      // number invites a made-up one.
                      enabled: !_oneOff,
                      onPicked: (v) => setState(() => _po.text = v),
                      onChanged: (_) => setState(() {}),
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
              // Where the number in the PO box came from, said out loud. A
              // field that fills itself and does not say why is one people
              // distrust and retype.
              if (_autoPo.isNotEmpty && _po.text.trim() == _autoPo)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Filled in from the order: this part was bought on '
                    '$_autoPo. Type over it if the packing slip says '
                    'otherwise.',
                    key: const ValueKey('delivery_po_auto'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
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
              // BOUGHT ON A CARD. Not everything on a job is quoted: a box of
              // connectors, a replacement supply, the adapter somebody drove
              // out for on the Friday. Those never touch a quote, a vendor
              // package or a PO — and they still land on a dock and still have
              // to be found in June.
              //
              // Ticking it is what turns the warning below off, because the
              // two say opposite things: no PO and nothing said is a row
              // nobody has finished, and a one-off is a row that is COMPLETE
              // with no PO to find.
              CheckboxListTile(
                key: const ValueKey('delivery_one_off'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _oneOff,
                title: const Text('One-off purchase - P-Card'),
                subtitle: const Text(
                  'Bought outside the quote and the PO process. Tracked here, '
                  'and on nothing else.',
                ),
                onChanged: (v) => setState(() {
                  _oneOff = v ?? false;
                  if (_oneOff) {
                    _po.clear();
                    _autoPo = '';
                  } else {
                    // Unticked, the box is open again - and the order record
                    // still knows what bought this.
                    _fillPoForPart();
                  }
                }),
              ),
              if (_warning.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber,
                        size: 18,
                        color: warningOn(
                          Theme.of(context).dialogTheme.backgroundColor ??
                              Theme.of(context).colorScheme.surface,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _warning,
                          key: const ValueKey('delivery_no_po_warning'),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: warningOn(
                                  Theme.of(context)
                                          .dialogTheme
                                          .backgroundColor ??
                                      Theme.of(context).colorScheme.surface,
                                ),
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ],
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
              // WHERE IT WENT, TYPED. On every state, not just storage: a
              // pallet is delivered to an address before it is anything else,
              // and the address is often not the building on the job - a
              // central store, a contractor's warehouse, the dock on the far
              // side of campus. Offered as suggestions and never as a fixed
              // list, because the one delivery that went somewhere new is
              // exactly the one worth writing down.
              const SizedBox(height: 8),
              _LocationField(
                controller: _location,
                stored: _state == DeliveryState.stored,
                known: project.deliveryLocations,
                onPicked: (v) => setState(() => _location.text = v),
              ),
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

// ---------------------------------------------------------------------------
//  LOGGING SEVERAL AT ONCE
// ---------------------------------------------------------------------------

/// Logs a TRUCKLOAD: several parts that arrived together, at one place, on one
/// day.
///
/// ONE PLACE AND ONE DAY, TYPED ONCE. A delivery is rarely one part. Nine
/// lines come off the same pallet, go to the same dock on the same morning,
/// and logged one at a time that is nine trips through the same dialog typing
/// the same address and picking the same date - which is how a log ends up
/// with the first two rows on it and the other seven in somebody's head.
///
/// EACH ROW STILL KEEPS ITS OWN PO, taken from what the job says bought that
/// part, because one pallet can still carry two purchase orders. The number in
/// the box below is the fallback, used on the rows the job has no order record
/// for.
Future<void> showBulkDeliveryDialog(
  BuildContext context, {
  required AppStateProvider provider,
  required ProjectEstimate estimate,
  required List<({String id, String name})> rooms,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _BulkDeliveryDialog(
      provider: provider,
      estimate: estimate,
      rooms: rooms,
    ),
  );
}

class _BulkDeliveryDialog extends StatefulWidget {
  final AppStateProvider provider;
  final ProjectEstimate estimate;
  final List<({String id, String name})> rooms;

  const _BulkDeliveryDialog({
    required this.provider,
    required this.estimate,
    required this.rooms,
  });

  @override
  State<_BulkDeliveryDialog> createState() => _BulkDeliveryDialogState();
}

class _BulkDeliveryDialogState extends State<_BulkDeliveryDialog> {
  final Set<String> _checked = {};

  /// One quantity box per part, made the first time that part is drawn and
  /// kept for as long as the dialog is open - so a number typed against a row
  /// survives the search box being used to go and find another one.
  final Map<String, TextEditingController> _qty = {};

  final TextEditingController _search = TextEditingController();
  final TextEditingController _po = TextEditingController();
  final TextEditingController _location = TextEditingController();
  final TextEditingController _note = TextEditingController();
  DateTime? _delivered = today();
  DateTime? _installed;
  DeliveryState _state = DeliveryState.delivered;
  String _roomId = '';

  @override
  void dispose() {
    for (final c in _qty.values) {
      c.dispose();
    }
    _search.dispose();
    _po.dispose();
    _location.dispose();
    _note.dispose();
    super.dispose();
  }

  /// The PO the job's order record says bought [key].
  String _poForPart(String key) =>
      widget.provider.project.orderForPart(key)?.poNumber.trim() ?? '';

  /// The quantity box for [line], opened on what is still outstanding: the job
  /// buys eighteen, six are already logged, so twelve is the answer this
  /// delivery is most likely to want.
  TextEditingController _qtyFor(MasterPartLine line) =>
      _qty.putIfAbsent(line.key, () {
        final left =
            line.qty - widget.provider.project.deliveredQty(line.key);
        return TextEditingController(
          text: formatUnits(left > 0 ? left : line.qty),
        );
      });

  /// The equipment list, narrowed by whatever is in the search box.
  List<MasterPartLine> get _shown {
    final needle = _search.text.trim().toLowerCase();
    if (needle.isEmpty) return widget.estimate.master;
    return [
      for (final m in widget.estimate.master)
        if (m.description.toLowerCase().contains(needle) ||
            m.model.toLowerCase().contains(needle) ||
            m.partNumber.toLowerCase().contains(needle))
          m,
    ];
  }

  /// How many ticked rows the job cannot say a PO for. They are still logged -
  /// see [ProjectDelivery.needsPaperwork] - but this is the one moment where
  /// one number in one box fixes all of them at once.
  int get _withoutPo {
    if (_po.text.trim().isNotEmpty) return 0;
    var n = 0;
    for (final key in _checked) {
      if (_poForPart(key).isEmpty) n++;
    }
    return n;
  }

  void _save() {
    final names = {for (final m in widget.estimate.master) m.key: m.description};
    final fallback = _po.text.trim();
    final installing = _state == DeliveryState.installed;
    final where = _location.text.trim();
    var logged = 0;
    // In equipment-list order rather than tick order, so the log reads the way
    // the packing slip does.
    for (final line in widget.estimate.master) {
      if (!_checked.contains(line.key)) continue;
      final own = _poForPart(line.key);
      widget.provider.addProjectDelivery(
        partKey: line.key,
        itemName: names[line.key] ?? '',
        poNumber: own.isNotEmpty ? own : fallback,
        qty: double.tryParse(_qty[line.key]?.text.trim() ?? '') ?? 0,
        deliveredOn: _delivered,
        state: _state,
        location: _location.text,
        roomId: installing ? _roomId : '',
        installedOn: installing ? (_installed ?? _delivered ?? today()) : null,
        note: _note.text,
      );
      logged++;
    }
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 4),
        content: Text(
          '${logged == 1 ? '1 delivery' : '$logged deliveries'} logged'
          '${where.isEmpty ? '' : ' - $where'}.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final project = widget.provider.project;
    final shown = _shown;
    final missing = _withoutPo;
    final warn = warningOn(
      theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface,
    );

    return AlertDialog(
      key: const ValueKey('bulk_delivery_dialog'),
      title: const Text('Log several deliveries'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Everything that came off the same truck. Where it went and '
                'the day it landed are said once, here, and each part keeps '
                'the PO the job says bought it.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _DateField(
                      label: 'Arrived',
                      value: _delivered,
                      buttonKey: const ValueKey('bulk_delivery_arrived'),
                      onPick: (d) => setState(() => _delivered = d),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<DeliveryState>(
                      key: const ValueKey('bulk_delivery_state'),
                      initialValue: _state,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Where is it now',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final s in DeliveryState.values)
                          DropdownMenuItem(
                            value: s,
                            child: Row(
                              children: [
                                Icon(deliveryStateIcon(s), size: 16),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    s.label,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                      onChanged: (v) =>
                          setState(() => _state = v ?? DeliveryState.delivered),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _LocationField(
                controller: _location,
                stored: _state == DeliveryState.stored,
                known: project.deliveryLocations,
                onPicked: (v) => setState(() => _location.text = v),
              ),
              if (_state == DeliveryState.installed) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: const ValueKey('bulk_delivery_room'),
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
                        buttonKey: const ValueKey('bulk_delivery_installed_on'),
                        onPick: (d) => setState(() => _installed = d),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              _PoField(
                controller: _po,
                numbers: project.poNumbersInUse,
                onPicked: (v) => setState(() => _po.text = v),
                onChanged: (_) => setState(() {}),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Used only on the rows the job has no order record for. '
                  'Anything already bought on a PO keeps its own number.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('bulk_delivery_search'),
                controller: _search,
                decoration: const InputDecoration(
                  labelText: 'Find a part',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const Divider(height: 16),
              SizedBox(
                height: 240,
                child: shown.isEmpty
                    ? Center(
                        child: Text(
                          widget.estimate.master.isEmpty
                              ? 'Nothing on the equipment list to log against. '
                                    'Log these one at a time instead.'
                              : 'Nothing matches that.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: shown.length,
                        itemBuilder: (context, i) =>
                            _bulkRow(theme, muted, project, shown[i]),
                      ),
              ),
              if (missing > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber, size: 18, color: warn),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          missing == 1
                              ? '1 of these is on no purchase order. A number '
                                    'in the PO box above goes on that row.'
                              : '$missing of these are on no purchase order. '
                                    'A number in the PO box above goes on all '
                                    'of them.',
                          key: const ValueKey('bulk_delivery_no_po_warning'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: warn,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('bulk_delivery_note'),
                controller: _note,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Note',
                  hintText: 'all on one pallet, seal intact',
                  helperText: 'Signed with your name, and put on every row.',
                  border: OutlineInputBorder(),
                  isDense: true,
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
          key: const ValueKey('bulk_delivery_save'),
          onPressed: _checked.isEmpty ? null : _save,
          child: Text(_checked.isEmpty ? 'Log them' : 'Log ${_checked.length}'),
        ),
      ],
    );
  }

  /// One part on the list: whether it came, how many of it, and what the job
  /// already knows about it.
  Widget _bulkRow(
    ThemeData theme,
    Color muted,
    BuildingProject project,
    MasterPartLine line,
  ) {
    final ticked = _checked.contains(line.key);
    final po = _poForPart(line.key);
    final here = project.deliveredQty(line.key);
    return Row(
      children: [
        Expanded(
          child: CheckboxListTile(
            key: ValueKey('bulk_delivery_pick_${line.key}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: ticked,
            title: Text(
              line.description,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            subtitle: Text(
              [
                if (line.qty > 0) 'the job buys ${formatUnits(line.qty)}',
                if (here > 0) '${formatUnits(here)} already logged',
                if (po.isNotEmpty) 'bought on $po' else 'on no PO the job knows',
              ].join(' - '),
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            onChanged: (v) => setState(() {
              if (v == true) {
                _qtyFor(line);
                _checked.add(line.key);
              } else {
                _checked.remove(line.key);
              }
            }),
          ),
        ),
        SizedBox(
          width: 92,
          child: TextField(
            key: ValueKey('bulk_delivery_qty_${line.key}'),
            controller: _qtyFor(line),
            enabled: ticked,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'How many',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }
}

/// Where a delivery went: an address, a dock, a shelf — typed, with the places
/// this job has already used one click away.
///
/// TYPED, NOT PICKED. A job takes delivery wherever the vendor could get a
/// truck that week, and the delivery that matters — the one that went to the
/// wrong building, or to a store across campus — is precisely the one a
/// dropdown of known places could not have recorded. The suggestions exist so
/// the usual two or three do not get retyped into four spellings; see
/// [BuildingProject.deliveryLocations].
class _LocationField extends StatelessWidget {
  final TextEditingController controller;

  /// Whether this lot is in storage, which is the one state where the
  /// question is 'held where' rather than 'delivered to'.
  final bool stored;

  final List<String> known;
  final ValueChanged<String> onPicked;

  const _LocationField({
    required this.controller,
    required this.stored,
    required this.known,
    required this.onPicked,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey('delivery_location'),
      controller: controller,
      decoration: InputDecoration(
        labelText: stored ? 'Held where' : 'Delivered to',
        // THE ROOM IT ACTUALLY GOES IN. Held gear lands in general storage,
        // which on this estate is one specific room, and a hint naming a place
        // that does not exist is a hint somebody types over rather than one
        // that tells them the shape of the answer.
        hintText: stored
            ? 'MLIB 031'
            : 'MLIB loading dock, Central Stores, 1 Campus Drive',
        helperText: 'Any address or place - type one that is not on the list.',
        border: const OutlineInputBorder(),
        isDense: true,
        suffixIcon: known.isEmpty
            ? null
            : PopupMenuButton<String>(
                key: const ValueKey('delivery_location_pick'),
                tooltip: 'Somewhere this job has taken delivery before',
                icon: const Icon(Icons.arrow_drop_down),
                itemBuilder: (_) => [
                  for (final place in known)
                    PopupMenuItem(value: place, child: Text(place)),
                ],
                onSelected: onPicked,
              ),
      ),
    );
  }
}

/// A PO number field with the job's existing numbers one click away.
class _PoField extends StatelessWidget {
  final TextEditingController controller;
  final List<String> numbers;
  final ValueChanged<String> onPicked;

  /// False for a purchase that went on a card: there is no PO to enter, and a
  /// box that still invites a number invites a made-up one.
  final bool enabled;

  final ValueChanged<String>? onChanged;

  const _PoField({
    required this.controller,
    required this.numbers,
    required this.onPicked,
    this.enabled = true,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey('delivery_po'),
      controller: controller,
      enabled: enabled,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: 'PO',
        hintText: enabled ? null : 'a one-off has none',
        border: const OutlineInputBorder(),
        isDense: true,
        suffixIcon: (numbers.isEmpty || !enabled)
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

/// A labeled date on a dialog, with the × that takes it back off.
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

// ---------------------------------------------------------------------------
//  THE ORDER ITSELF
// ---------------------------------------------------------------------------
//  A PO row is somebody's typing: a number, a date, a figure. The argument a
//  purchase order actually gets pulled up to settle - "we ordered the 65-inch,
//  not the 55" - is settled by the DOCUMENT, and until there was somewhere to
//  put it, the signed order lived in the inbox of whoever raised it. See
//  [ProjectPo.filePath].

/// Where the order attached to [po] actually is on this machine.
///
/// Resolved against the project file exactly the way a room's config, a
/// building plan and a cutsheet are, so a job folder that has been moved or
/// handed over still finds its own paperwork.
String resolvePoFilePath(AppStateProvider provider, ProjectPo po) {
  if (po.filePath.trim().isEmpty) return '';
  return BuildingProject.resolvePath(
    po.filePath.trim(),
    provider.currentProjectPath,
  );
}

/// Picks the document a purchase order was raised as, and attaches it.
///
/// ANY file, not only a PDF. A PDF is what finance sends and it is not the
/// only thing that ever turns up - a scan, a screenshot of the ordering system,
/// the vendor's acknowledgement as an .msg - and a picker that hides those says
/// the app does not support paperwork it in fact stores perfectly well. What
/// it cannot DRAW it hands to the machine's own opener; see [openPoFile].
Future<void> attachPoFile(
  BuildContext context,
  AppStateProvider provider,
  ProjectPo po,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final picked = await FilePicker.pickFiles(
    dialogTitle: 'Pick the order for '
        '${po.number.trim().isEmpty ? 'this PO' : po.number.trim()}',
  );
  final path = picked?.files.single.path;
  if (path == null || path.isEmpty) return;
  provider.setPoFile(po.id, path);
  showTimedSnackBar(
    messenger,
    SnackBar(
      content: Text(
        'Attached. The project stores where it IS, not a copy of it - move '
        'the file and the link goes with it.',
      ),
    ),
  );
}

/// Opens the order behind a PO: IN THE APP where it can be drawn, otherwise in
/// whatever this machine opens it with.
///
/// The same bargain the plans pane and the matrix's cutsheets make, and for the
/// same reason - a PDF handed to the machine's reader is a second window that
/// has to be found again every time, and the thing somebody is doing with it
/// (checking a model number against the line they are reading) is a thing they
/// are doing HERE.
Future<void> openPoFile(
  BuildContext context,
  AppStateProvider provider,
  ProjectPo po,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final resolved = resolvePoFilePath(provider, po);
  final name = po.number.trim().isEmpty ? 'this PO' : po.number.trim();

  // SAID, NOT THROWN. An order that has been moved or renamed is a fact about
  // the file, and "the viewer failed" would send somebody looking in the wrong
  // place for it.
  if (resolved.isEmpty || !File(resolved).existsSync()) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text(
          'The order for $name is not where the project says it '
          'is${resolved.isEmpty ? '' : ' ($resolved)'}.',
        ),
      ),
    );
    return;
  }

  if (!po.isViewable) {
    final error = await provider.openInDesktop(resolved);
    if (error != null) {
      showTimedSnackBar(messenger, SnackBar(content: Text(error)));
    }
    return;
  }

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => PdfViewerDialog(
      filePath: resolved,
      title: 'Order $name',
      screenshotStem: p.basenameWithoutExtension(resolved),
      onOpenExternally: () => provider.openInDesktop(resolved),
    ),
  );
}

/// The button row a PO card carries for its attached order: open it, swap it,
/// take it off - or, when there is none, the one button that adds one.
class PoFileButtons extends StatelessWidget {
  final ProjectPo po;
  final AppStateProvider provider;

  const PoFileButtons({super.key, required this.po, required this.provider});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final attached = po.filePath.trim().isNotEmpty;

    if (!attached) {
      return OutlinedButton.icon(
        key: ValueKey('po_attach_${po.id}'),
        icon: const Icon(Icons.attach_file, size: 18),
        label: const Text('Attach the order'),
        onPressed: () => attachPoFile(context, provider, po),
      );
    }

    return Wrap(
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // THE DOCUMENT IS THE BUTTON. Named by its own file, because that is
        // what somebody recognizes - 'PO-1188 signed.pdf' says more about
        // whether this is the right paper than the word "order" ever will.
        OutlinedButton.icon(
          key: ValueKey('po_open_file_${po.id}'),
          icon: Icon(
            po.isPdf ? Icons.picture_as_pdf : Icons.description_outlined,
            size: 18,
          ),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(
              p.basename(po.filePath.trim()),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          onPressed: () => openPoFile(context, provider, po),
        ),
        IconButton(
          key: ValueKey('po_replace_file_${po.id}'),
          tooltip: 'Attach a different file',
          icon: const Icon(Icons.find_replace, size: 18),
          color: muted,
          onPressed: () => attachPoFile(context, provider, po),
        ),
        IconButton(
          key: ValueKey('po_detach_${po.id}'),
          // The FILE is left where it is. This row is a pointer at it, and
          // deleting somebody's paperwork off their disk is not something a
          // project file gets to do.
          tooltip: 'Take the link off. The file itself is left alone.',
          icon: const Icon(Icons.link_off, size: 18),
          color: muted,
          onPressed: () => provider.setPoFile(po.id, ''),
        ),
      ],
    );
  }
}
