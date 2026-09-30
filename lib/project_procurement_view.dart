import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'file_dialogs.dart';
import 'procurement_log.dart';
import 'project_estimate.dart';
import 'project_schedule.dart' show formatScheduleDate;
import 'report_tools.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  THE PROCUREMENT PANE
/// ============================================================================
///  The AV procurement log, edited here and issued to the contractor as a
///  spreadsheet with the columns their scheduler uses. See procurement_log.dart.
/// ============================================================================

/// Column widths on screen, matching [kProcurementColumns].
const List<double> _kWidths = [
  96, 80, 220, 200, 150, 120, 100, 150, 80, 90, 100, 110, 100, 70, 100, 100, 220,
];

/// The procurement pane, as slivers for the project tab's one scroll view.
List<Widget> procurementSlivers(
  BuildContext context,
  ProjectEstimate estimate,
) {
  final provider = context.watch<AppStateProvider>();
  final entries = provider.project.procurement;
  final groups = procurementByRoom(entries);

  return [
    SliverToBoxAdapter(
      child: _Toolbar(entries: entries, estimate: estimate),
    ),
    const SliverToBoxAdapter(child: Divider(height: 1)),
    if (entries.isEmpty)
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(
            child: Text(
              'Nothing on the log yet.\n\n'
              'Fill it from the rooms, or add lines by hand. Each line says '
              'who buys it, when it has to be on site, and where its '
              'submittal has got to.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      )
    else
      SliverToBoxAdapter(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _HeaderRow(),
              for (final g in groups) ...[
                _RoomHeading(room: g.room, count: g.entries.length),
                for (var i = 0; i < g.entries.length; i++)
                  _EntryRow(entry: g.entries[i], odd: i.isOdd),
              ],
            ],
          ),
        ),
      ),
    const SliverToBoxAdapter(child: SizedBox(height: 24)),
  ];
}

/// The recipient most lines already name, for a status set without one.
String _usualRecipient(List<ProcurementEntry> entries) {
  final counts = <String, int>{};
  for (final e in entries) {
    final to = e.statusTo.trim();
    if (to.isNotEmpty) counts[to] = (counts[to] ?? 0) + 1;
  }
  if (counts.isEmpty) return '';
  return (counts.entries.toList()..sort((a, b) => b.value - a.value))
      .first
      .key;
}

class _Toolbar extends StatelessWidget {
  final List<ProcurementEntry> entries;
  final ProjectEstimate estimate;

  const _Toolbar({required this.entries, required this.estimate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final released = entries.where((e) => e.released).length;
    final submitted = entries
        .where((e) => e.status != ProcurementStatus.none)
        .length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.tonalIcon(
            key: const ValueKey('procurement_add'),
            onPressed: () async {
              final added = await showProcurementEditor(
                context,
                const ProcurementEntry(id: ''),
                recipient: _usualRecipient(entries),
              );
              if (added != null) provider.addProcurementEntry(added);
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add a line'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('procurement_fill'),
            onPressed: () {
              final added = provider.fillProcurementFromRooms(estimate);
              showTimedSnackBar(
                ScaffoldMessenger.of(context),
                SnackBar(
                  content: Text(
                    added == 0
                        ? 'Every piece of equipment on the rooms is already '
                              'on the log.'
                        : '$added line${added == 1 ? '' : 's'} added from the '
                              'rooms.',
                  ),
                ),
              );
            },
            icon: const Icon(Icons.playlist_add, size: 18),
            label: const Text('Fill from the rooms'),
          ),
          if (entries.isNotEmpty)
            OutlinedButton.icon(
              key: const ValueKey('procurement_export_xlsx'),
              onPressed: () => _exportSpreadsheet(context),
              icon: const Icon(Icons.table_view, size: 18),
              label: const Text('Spreadsheet'),
            ),
          if (entries.isNotEmpty)
            Text(
              '${entries.length} line${entries.length == 1 ? '' : 's'}  ·  '
              '$submitted with a status  ·  $released released',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

Widget _cell(
  BuildContext context,
  int column,
  Widget child, {
  Color? fill,
}) => Container(
  width: _kWidths[column],
  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
  decoration: BoxDecoration(
    color: fill,
    border: Border(
      right: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
    ),
  ),
  child: child,
);

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(width: 40),
        for (var c = 0; c < kProcurementColumns.length; c++)
          _cell(
            context,
            c,
            Text(
              kProcurementColumns[c],
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            fill: theme.colorScheme.secondaryContainer,
          ),
      ],
    );
  }
}

class _RoomHeading extends StatelessWidget {
  final String room;
  final int count;

  const _RoomHeading({required this.room, required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(
        '${room.isEmpty ? 'No room' : room}  ($count)',
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  final ProcurementEntry entry;
  final bool odd;

  const _EntryRow({required this.entry, required this.odd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final fill = odd ? theme.colorScheme.surfaceContainerHighest : null;
    final values = procurementRow(entry);
    Text text(Object v) => Text(v.toString(), style: theme.textTheme.bodySmall);

    return InkWell(
      key: ValueKey('procurement_row_${entry.id}'),
      onTap: () async {
        final edited = await showProcurementEditor(
          context,
          entry,
          recipient: _usualRecipient(provider.project.procurement),
        );
        if (edited != null) provider.updateProcurementEntry(edited);
      },
      child: Container(
        color: fill,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 40,
              child: IconButton(
                tooltip: 'Remove this line',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                icon: const Icon(Icons.delete_outline),
                onPressed: () => provider.removeProcurementEntry(entry.id),
              ),
            ),
            for (var c = 0; c < values.length; c++)
              _cell(
                context,
                c,
                c == 4 ? _StatusCell(entry: entry) : text(values[c]),
              ),
          ],
        ),
      ),
    );
  }
}

/// The status, set in one press; the recipient carries over.
class _StatusCell extends StatelessWidget {
  final ProcurementEntry entry;

  const _StatusCell({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final to = entry.statusTo.trim().isNotEmpty
        ? entry.statusTo.trim()
        : _usualRecipient(provider.project.procurement);
    final color = switch (entry.status) {
      ProcurementStatus.none => theme.colorScheme.onSurfaceVariant,
      ProcurementStatus.submitted => Colors.orange.shade800,
      ProcurementStatus.approved => Colors.blue.shade700,
      ProcurementStatus.released => Colors.green.shade700,
    };
    return PopupMenuButton<ProcurementStatus>(
      key: ValueKey('procurement_status_${entry.id}'),
      tooltip: 'Set the status',
      onSelected: (s) => provider.updateProcurementEntry(
        entry.copyWith(
          status: s,
          statusTo: to,
          releasedOn: s == ProcurementStatus.released && entry.releasedOn == null
              ? DateTime.now()
              : null,
        ),
      ),
      itemBuilder: (ctx) => [
        for (final s in ProcurementStatus.values)
          PopupMenuItem(
            value: s,
            child: Text(
              s == ProcurementStatus.none
                  ? 'No status'
                  : entry.copyWith(status: s, statusTo: to).statusText,
            ),
          ),
      ],
      child: Text(
        entry.statusText.isEmpty ? '-' : entry.statusText,
        style: theme.textTheme.bodySmall?.copyWith(
          color: color,
          fontWeight: entry.status == ProcurementStatus.none
              ? null
              : FontWeight.w600,
        ),
      ),
    );
  }
}

/// Edits one line. Returns the edited line, or null when canceled.
Future<ProcurementEntry?> showProcurementEditor(
  BuildContext context,
  ProcurementEntry entry, {
  String recipient = '',
}) {
  final company = TextEditingController(text: entry.company);
  final room = TextEditingController(text: entry.room);
  final device = TextEditingController(text: entry.device);
  final description = TextEditingController(text: entry.description);
  final statusTo = TextEditingController(
    text: entry.statusTo.isEmpty ? recipient : entry.statusTo,
  );
  final phase = TextEditingController(text: entry.installPhase);
  final p6Id = TextEditingController(text: entry.p6ActivityId);
  final p6Desc = TextEditingController(text: entry.p6ActivityDescription);
  final review = TextEditingController(text: entry.reviewTime);
  final lead = TextEditingController(text: entry.leadTime);
  final notes = TextEditingController(text: entry.notes);
  var status = entry.status;
  var p6Start = entry.p6Start;
  var submitBy = entry.submitBy;
  var releasedOn = entry.releasedOn;
  var delivery = entry.estimatedDelivery;

  return showDialog<ProcurementEntry>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        Widget field(
          TextEditingController c,
          String label, {
          List<String> presets = const [],
          double width = 260,
          int maxLines = 1,
        }) => SizedBox(
          width: width,
          child: TextField(
            controller: c,
            maxLines: maxLines,
            decoration: InputDecoration(
              labelText: label,
              isDense: true,
              suffixIcon: presets.isEmpty
                  ? null
                  : PopupMenuButton<String>(
                      icon: const Icon(Icons.arrow_drop_down),
                      onSelected: (v) => setLocal(() => c.text = v),
                      itemBuilder: (_) => [
                        for (final p in presets)
                          PopupMenuItem(value: p, child: Text(p)),
                      ],
                    ),
            ),
          ),
        );

        Widget date(
          String label,
          DateTime? value,
          ValueChanged<DateTime?> set,
        ) => SizedBox(
          width: 200,
          child: InputDecorator(
            decoration: InputDecoration(labelText: label, isDense: true),
            child: Row(
              children: [
                Expanded(
                  child: TextButton(
                    style: TextButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: value ?? DateTime.now(),
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2040),
                      );
                      if (picked != null) setLocal(() => set(picked));
                    },
                    child: Text(
                      value == null ? 'Pick a date' : formatScheduleDate(value),
                    ),
                  ),
                ),
                if (value != null)
                  IconButton(
                    tooltip: 'Clear',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close),
                    onPressed: () => setLocal(() => set(null)),
                  ),
              ],
            ),
          ),
        );

        final onSite = p6Start == null
            ? null
            : entry.copyWith(p6Start: p6Start).requiredOnSite;

        return AlertDialog(
          title: Text(entry.id.isEmpty ? 'Add a procurement line' : 'Edit line'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  field(company, 'Company', presets: kProcurementCompanies),
                  field(room, 'Room #'),
                  field(device, 'Device', width: 536),
                  field(description, 'Equipment description', width: 536),
                  SizedBox(
                    width: 260,
                    child: DropdownButtonFormField<ProcurementStatus>(
                      initialValue: status,
                      decoration: const InputDecoration(
                        labelText: 'Status',
                        isDense: true,
                      ),
                      items: [
                        for (final s in ProcurementStatus.values)
                          DropdownMenuItem(
                            value: s,
                            child: Text(
                              s == ProcurementStatus.none ? 'None' : s.label,
                            ),
                          ),
                      ],
                      onChanged: (s) => setLocal(() {
                        status = s ?? ProcurementStatus.none;
                        if (status == ProcurementStatus.released) {
                          releasedOn ??= DateTime.now();
                        }
                      }),
                    ),
                  ),
                  field(statusTo, 'Who it goes to (e.g. DPR)'),
                  field(
                    phase,
                    'Install before drywall or after paint?',
                    presets: kProcurementInstallPhases,
                  ),
                  field(lead, 'Lead time (weeks)'),
                  field(p6Id, 'P6 activity ID'),
                  field(review, 'Review time'),
                  field(p6Desc, 'P6 activity description', width: 536),
                  date('P6 start date', p6Start, (v) => p6Start = v),
                  SizedBox(
                    width: 320,
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Required on site '
                            '($kProcurementOnSiteLeadDays days before P6)',
                        isDense: true,
                      ),
                      child: Text(
                        onSite == null ? '-' : formatScheduleDate(onSite),
                      ),
                    ),
                  ),
                  date('Date to be submitted', submitBy, (v) => submitBy = v),
                  date('Actual release date', releasedOn, (v) => releasedOn = v),
                  date('Estimated delivery', delivery, (v) => delivery = v),
                  field(notes, 'Notes/comments', width: 536, maxLines: 3),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('procurement_editor_save'),
              onPressed: () => Navigator.of(ctx).pop(
                ProcurementEntry(
                  id: entry.id,
                  company: company.text.trim(),
                  room: room.text.trim(),
                  device: device.text.trim(),
                  description: description.text.trim(),
                  status: status,
                  statusTo: statusTo.text.trim(),
                  installPhase: phase.text.trim(),
                  p6ActivityId: p6Id.text.trim(),
                  p6ActivityDescription: p6Desc.text.trim(),
                  reviewTime: review.text.trim(),
                  leadTime: lead.text.trim(),
                  p6Start: p6Start,
                  submitBy: submitBy,
                  releasedOn: releasedOn,
                  estimatedDelivery: delivery,
                  notes: notes.text.trim(),
                ),
              ),
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
}

/// The log as a spreadsheet for the contractor.
XlsxSheet procurementLogSheet(String projectName, List<ProcurementEntry> entries) =>
    buildStackedReportSheet(
      sheetName: 'AV Procurement Log',
      title: projectName.trim().isEmpty
          ? 'AV Procurement Log'
          : '${projectName.trim()} - AV Procurement Log',
      sections: procurementLogSections(entries),
    );

Future<void> _exportSpreadsheet(BuildContext context) async {
  final provider = context.read<AppStateProvider>();
  final project = provider.project;
  final stem = project.name.trim().isEmpty
      ? 'project'
      : project.name.trim().replaceAll(RegExp(r'[^\w\-]+'), '_');
  final picked = await saveFileCompat(
    dialogTitle: 'Save the AV procurement log',
    fileName: '${stem}_AV_Procurement_Log.xlsx',
    type: FileType.custom,
    allowedExtensions: const ['xlsx'],
  );
  if (picked == null) return;
  final target =
      picked.toLowerCase().endsWith('.xlsx') ? picked : '$picked.xlsx';
  try {
    await File(target).writeAsBytes(
      buildXlsx([procurementLogSheet(project.name, project.procurement)]),
    );
    if (context.mounted) {
      showSavedFileSnack(context, provider, 'The procurement log', target);
    }
  } catch (e) {
    if (context.mounted) {
      showTimedSnackBar(
        ScaffoldMessenger.of(context),
        SnackBar(content: Text('The log could not be written: $e')),
      );
    }
  }
}
