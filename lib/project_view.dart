import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_flow_swap_dialogs.dart' show pickCatalogModel;
import 'building_project.dart';
import 'cost_estimate.dart';
import 'live_text_field.dart';
import 'project_estimate.dart';
import 'project_swap.dart';
import 'project_workbook.dart';

/// ============================================================================
///  THE PROJECT TAB
/// ============================================================================
///  A building, quoted as one job. Three panes behind one header:
///
///    ROOMS   — which configs are on the job, what each one costs, and the
///              building total they add up to.
///    PARTS   — every part once, quantities merged across rooms, tagged to the
///              vendor that will quote it. The tagging happens here because
///              this is the only screen where the whole order is visible at
///              once: "who sells this" is a question about a part, not about
///              a room, and answering it nine times per part was the thing
///              this feature exists to stop.
///    VENDORS — the companies and the rules that tag parts to them.
///
///  THE HEADER IS ALWAYS THE TOTAL. Whichever pane is open, the figure at the
///  top is what the building costs, because that is the number somebody came
///  to this tab for and it should never require navigating to.
///
///  NOTHING HERE EDITS A ROOM. The project points at room files; it does not
///  own them. A price that is wrong is fixed on that room's own Cost tab, and
///  Refresh picks it up. That boundary is deliberate — a screen that could
///  edit nine rooms at once is a screen that can damage nine rooms at once,
///  and the rooms are the documents that took the work.
/// ============================================================================

/// Which pane is showing.
enum _ProjectPane {
  rooms('Rooms', Icons.meeting_room),
  parts('Master parts', Icons.inventory_2),
  vendors('Vendors', Icons.local_shipping);

  final String label;
  final IconData icon;
  const _ProjectPane(this.label, this.icon);
}

class ProjectView extends StatefulWidget {
  const ProjectView({super.key});

  @override
  State<ProjectView> createState() => _ProjectViewState();
}

class _ProjectViewState extends State<ProjectView> {
  _ProjectPane _pane = _ProjectPane.rooms;

  /// Master-list filter: '' for everything, otherwise a vendor id, or the
  /// sentinel below for the parts nothing claimed.
  String _vendorFilter = '';

  /// Not a vendor id: ids are always `vendor<n>`, so this can never be one
  /// by accident.
  static const String _untaggedFilter = '<untagged>';

  /// Same idea, for the parts nothing will drive.
  static const String _undrivenFilter = '<no-module>';

  String _search = '';

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    showTimedSnackBar(
      ScaffoldMessenger.of(context),
      SnackBar(
        duration: const Duration(seconds: 5),
        content: Text(message),
        backgroundColor: error ? Colors.red : null,
      ),
    );
  }

  // -------------------------------------------------------------------------
  //  FILE ACTIONS
  // -------------------------------------------------------------------------

  Future<void> _newProject(AppStateProvider provider) async {
    if (!await _confirmDiscard(provider)) return;
    final setup = provider.roomConfig['SYSTEM_SETUP'];
    provider.newProject(
      building: (setup is Map ? setup['gve_bldg']?.toString() : '') ?? '',
    );
    _snack('New project started. Add the rooms it covers.');
  }

  /// Offers to save a project with unsaved edits before it is replaced.
  /// Returns false when the user backs out entirely.
  Future<bool> _confirmDiscard(AppStateProvider provider) async {
    if (!provider.projectDirty) return true;
    final answer = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('This project has unsaved changes'),
        content: Text(
          '"${provider.projectDisplayName}" has edits that are not on disk. '
          'The rooms themselves are untouched either way — only the room '
          'list, the vendors and the tags are at stake.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('Save first'),
          ),
        ],
      ),
    );
    if (answer == 'save') return _saveProject(provider);
    return answer == 'discard';
  }

  Future<void> _openProject(AppStateProvider provider) async {
    if (!await _confirmDiscard(provider)) return;
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Open a project',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final file = picked?.files.single.path;
    if (file == null) return;
    final error = await provider.openProject(file);
    if (error.isEmpty) {
      _snack('Opened ${provider.projectDisplayName}.');
    } else {
      _snack(error, error: true);
    }
  }

  /// Returns true when the project ended up on disk.
  Future<bool> _saveProject(
    AppStateProvider provider, {
    bool as = false,
  }) async {
    var target = provider.currentProjectPath;
    if (as || target.isEmpty) {
      final suggested = _fileStem(provider.project);
      final picked = await FilePicker.saveFile(
        dialogTitle: 'Save the project',
        fileName: '$suggested$kProjectFileSuffix',
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      if (picked == null) return false;
      // The dialog hands back exactly what was typed, so a name entered
      // without an extension would land as a file nothing can open.
      target = picked.toLowerCase().endsWith('.json') ? picked : '$picked.json';
    }
    final error = await provider.saveProject(to: target);
    if (error.isNotEmpty) {
      _snack(error, error: true);
      return false;
    }
    if (mounted) {
      showSavedFileSnack(context, provider, 'The project', target);
    }
    return true;
  }

  String _fileStem(BuildingProject project) {
    final raw = project.name.trim().isNotEmpty
        ? project.name
        : project.building.trim().isNotEmpty
        ? project.building
        : 'project';
    return raw
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
        .replaceAll(RegExp(r'\s+'), '_');
  }

  // -------------------------------------------------------------------------
  //  EXPORTS
  // -------------------------------------------------------------------------

  Future<void> _exportWorkbook(
    AppStateProvider provider,
    ProjectEstimate estimate,
  ) async {
    if (estimate.rooms.isEmpty) {
      _snack('Add some rooms first — there is nothing to write.');
      return;
    }
    final picked = await FilePicker.saveFile(
      dialogTitle: 'Save the project workbook',
      fileName: '${_fileStem(provider.project)}_project.xlsx',
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
    );
    if (picked == null) return;
    final target = picked.toLowerCase().endsWith('.xlsx')
        ? picked
        : '$picked.xlsx';
    try {
      await File(
        target,
      ).writeAsBytes(buildProjectWorkbookBytes(estimate: estimate));
      if (mounted) {
        showSavedFileSnack(context, provider, 'The project workbook', target);
      }
    } catch (e) {
      _snack('The workbook could not be written: $e', error: true);
    }
  }

  /// One .xlsx per vendor, into a folder the user picks.
  ///
  /// A folder rather than a file, because the whole point is that these are
  /// several documents going to several companies. Writing them one at a time
  /// through six save dialogs would be the same work the feature is supposed
  /// to remove.
  Future<void> _exportRfqs(
    AppStateProvider provider,
    ProjectEstimate estimate,
  ) async {
    final packages = [
      for (final p in estimate.vendors)
        if (!p.isUntagged) p,
    ];
    if (packages.isEmpty) {
      _snack(
        estimate.master.isEmpty
            ? 'Nothing on the master list yet.'
            : 'No parts are tagged to a vendor yet — set up a vendor rule or '
                  'tag some parts, and each vendor gets a file.',
      );
      return;
    }

    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Where should the quote requests go?',
    );
    if (folder == null) return;

    final written = <String>[];
    final failed = <String>[];
    for (final package in packages) {
      final name = '${vendorRfqFileStem(provider.project, package)}.xlsx';
      try {
        await File(path.join(folder, name)).writeAsBytes(
          buildVendorRfqBytes(estimate: estimate, package: package),
        );
        written.add(name);
      } catch (e) {
        failed.add('$name — $e');
      }
    }

    if (!mounted) return;
    if (written.isEmpty) {
      _snack(
        'No quote requests were written: ${failed.join('; ')}',
        error: true,
      );
      return;
    }
    showSavedSnackBar(
      messenger: ScaffoldMessenger.of(context),
      theme: Theme.of(context),
      provider: provider,
      message: failed.isEmpty
          ? '${written.length} quote request'
                '${written.length == 1 ? '' : 's'} written'
          : '${written.length} written, ${failed.length} failed '
                '(${failed.first})',
      savedPath: folder,
      isFolder: true,
    );
  }

  // -------------------------------------------------------------------------
  //  BUILD
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final estimate = provider.priceProject();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, provider, estimate),
        const Divider(height: 1),
        Expanded(
          child: switch (_pane) {
            _ProjectPane.rooms => _RoomsPane(estimate: estimate),
            _ProjectPane.parts => _PartsPane(
              estimate: estimate,
              vendorFilter: _vendorFilter,
              untaggedFilter: _untaggedFilter,
              undrivenFilter: _undrivenFilter,
              search: _search,
              onVendorFilter: (v) => setState(() => _vendorFilter = v),
              onSearch: (s) => setState(() => _search = s),
            ),
            _ProjectPane.vendors => _VendorsPane(estimate: estimate),
          },
        ),
      ],
    );
  }

  Widget _header(
    BuildContext context,
    AppStateProvider provider,
    ProjectEstimate estimate,
  ) {
    final theme = Theme.of(context);
    final warnings =
        estimate.failedRooms +
        estimate.unpricedParts +
        (estimate.mixedCurrency ? 1 : 0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: LiveTextField(
                  fieldId: 'project_name_${provider.currentProjectPath}',
                  initial: provider.project.name,
                  label: 'Project',
                  hint: 'Bessey Hall AV refresh',
                  onChanged: (v) => provider.setProjectField(name: v),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 160,
                child: LiveTextField(
                  fieldId: 'project_bldg_${provider.currentProjectPath}',
                  initial: provider.project.building,
                  label: 'Building',
                  onChanged: (v) => provider.setProjectField(building: v),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 140,
                child: LiveTextField(
                  fieldId: 'project_job_${provider.currentProjectPath}',
                  initial: provider.project.jobNumber,
                  label: 'Job number',
                  onChanged: (v) => provider.setProjectField(jobNumber: v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // A Wrap rather than a Row: the strip is five items of text whose
          // width is whatever the figures happen to be, and a project total in
          // the millions on a laptop would otherwise push the last chip off
          // the edge under an overflow stripe.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // The number the tab exists for, at the size it deserves.
              _TotalChip(
                label: 'Project total',
                value: formatMoney(estimate.grandTotal, estimate.currency),
                emphasis: true,
              ),
              _TotalChip(
                label: 'Parts',
                value: formatMoney(estimate.partsTotal, estimate.currency),
              ),
              _TotalChip(
                label: 'Labor',
                value:
                    '${formatMoney(estimate.laborTotal, estimate.currency)}'
                    '  ·  ${trimNumber(estimate.laborHours)} hrs',
              ),
              _TotalChip(
                // Not just 'Rooms': the panes below are named Rooms too, and
                // one word meaning two things on one screen is a screen that
                // has to be read twice.
                label: 'Rooms priced',
                value:
                    '${estimate.costedRooms.length} of '
                    '${estimate.rooms.length}',
              ),
              if (warnings > 0)
                Tooltip(
                  message: _warningTooltip(estimate),
                  child: Chip(
                    avatar: const Icon(Icons.warning_amber, size: 18),
                    label: Text('$warnings to check'),
                    backgroundColor: theme.colorScheme.errorContainer,
                  ),
                ),
              if (provider.projectDirty)
                Text(
                  'Unsaved',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              SegmentedButton<_ProjectPane>(
                segments: [
                  for (final pane in _ProjectPane.values)
                    ButtonSegment(
                      value: pane,
                      icon: Icon(pane.icon, size: 18),
                      label: Text(pane.label),
                    ),
                ],
                selected: {_pane},
                onSelectionChanged: (s) => setState(() => _pane = s.first),
              ),
              const SizedBox(width: 12),
              // Expanded so the Wrap is CONSTRAINED and therefore actually
              // wraps. A Spacer with an unconstrained Wrap beside it lets the
              // buttons keep their natural width and run off the edge — which
              // is exactly what six of them did on anything under about 1600
              // pixels.
              Expanded(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: () => _newProject(provider),
                      icon: const Icon(Icons.note_add_outlined, size: 18),
                      label: const Text('New'),
                    ),
                    TextButton.icon(
                      onPressed: () => _openProject(provider),
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: const Text('Open'),
                    ),
                    TextButton.icon(
                      onPressed: () => _saveProject(provider),
                      icon: const Icon(Icons.save_outlined, size: 18),
                      label: const Text('Save'),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        provider.refreshProjectRooms();
                        _snack('Re-read every room from disk.');
                      },
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Refresh'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _exportWorkbook(provider, estimate),
                      icon: const Icon(Icons.table_view, size: 18),
                      label: const Text('Workbook'),
                    ),
                    FilledButton.icon(
                      onPressed: () => _exportRfqs(provider, estimate),
                      icon: const Icon(Icons.send_outlined, size: 18),
                      label: const Text('Quote requests'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _warningTooltip(ProjectEstimate estimate) => [
    if (estimate.failedRooms > 0)
      '${estimate.failedRooms} room(s) could not be read — the total is short.',
    if (estimate.unpricedParts > 0)
      '${estimate.unpricedParts} part(s) have no price anywhere.',
    if (estimate.undrivenDevices > 0)
      '${estimate.undrivenDevices} device(s) have no control module — quoted, '
          'but they will not commission as they stand.',
    if (estimate.mixedCurrency)
      'Rooms are quoted in different currencies and are being added anyway.',
  ].join('\n');
}

/// A labelled figure in the header strip.
class _TotalChip extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasis;

  const _TotalChip({
    required this.label,
    required this.value,
    this.emphasis = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: emphasis
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          Text(
            value,
            style:
                (emphasis
                        ? theme.textTheme.titleLarge
                        : theme.textTheme.titleMedium)
                    ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  ROOMS
// ---------------------------------------------------------------------------

class _RoomsPane extends StatelessWidget {
  final ProjectEstimate estimate;
  const _RoomsPane({required this.estimate});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: () async {
                  final picked = await FilePicker.pickFiles(
                    dialogTitle: 'Add room configs to the project',
                    type: FileType.custom,
                    allowedExtensions: const ['json'],
                    allowMultiple: true,
                  );
                  if (picked == null) return;
                  final problems = <String>[];
                  var added = 0;
                  for (final f in picked.files) {
                    if (f.path == null) continue;
                    final error = provider.addRoomToProject(f.path!);
                    if (error.isEmpty) {
                      added++;
                    } else {
                      problems.add(error);
                    }
                  }
                  if (!context.mounted) return;
                  showTimedSnackBar(
                    ScaffoldMessenger.of(context),
                    SnackBar(
                      duration: const Duration(seconds: 5),
                      content: Text(
                        problems.isEmpty
                            ? '$added room${added == 1 ? '' : 's'} added.'
                            : '$added added. ${problems.join(' ')}',
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add rooms…'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () {
                  final error = provider.addCurrentRoomToProject();
                  if (!context.mounted) return;
                  showTimedSnackBar(
                    ScaffoldMessenger.of(context),
                    SnackBar(
                      duration: const Duration(seconds: 5),
                      content: Text(
                        error.isEmpty ? 'Added the open room.' : error,
                      ),
                      backgroundColor: error.isEmpty ? null : Colors.red,
                    ),
                  );
                },
                icon: const Icon(Icons.playlist_add, size: 18),
                label: const Text('Add the open room'),
              ),
              // Expanded, not a Spacer: the sentence is longer than the space
              // left beside two buttons on a laptop, and an unconstrained Text
              // simply runs off the edge.
              Expanded(
                child: Text(
                  'Rooms are references. Fix a price on the room’s own Cost '
                  'tab, then Refresh.',
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (estimate.rooms.isEmpty)
          const Expanded(
            child: Center(
              child: Text(
                'No rooms on this project yet.\n\n'
                'Add the config.json files for the rooms in this building and '
                'they will be priced together.',
                textAlign: TextAlign.center,
              ),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: estimate.rooms.length + 1,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                if (index == estimate.rooms.length) {
                  return _BuildingTotals(estimate: estimate);
                }
                return _RoomRow(
                  room: estimate.rooms[index],
                  currency: estimate.currency,
                  isFirst: index == 0,
                  isLast: index == estimate.rooms.length - 1,
                );
              },
            ),
          ),
      ],
    );
  }
}

class _RoomRow extends StatelessWidget {
  final ProjectRoomCost room;
  final String currency;
  final bool isFirst;
  final bool isLast;

  const _RoomRow({
    required this.room,
    required this.currency,
    required this.isFirst,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final theme = Theme.of(context);
    final e = room.estimate;
    final dimmed = !room.ref.included;

    return Card(
      margin: EdgeInsets.zero,
      color: room.ok
          ? (dimmed ? theme.colorScheme.surfaceContainerLow : null)
          : theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Tooltip(
              message: room.ref.included
                  ? 'Counted in the project total'
                  : 'Kept on the job but out of the total — an alternate, or '
                        'a later phase',
              child: Checkbox(
                value: room.ref.included,
                onChanged: (v) => provider.updateProjectRoom(
                  room.ref.id,
                  included: v ?? true,
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    room.name,
                    style: theme.textTheme.titleSmall?.copyWith(
                      decoration: dimmed ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  Text(
                    room.ok ? room.ref.configPath : room.room.error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: room.ok
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.onErrorContainer,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (e != null) ...[
              _cell(
                context,
                'Equipment',
                formatMoney(e.equipmentTotal, currency),
              ),
              _cell(context, 'Labor', formatMoney(e.laborTotal, currency)),
              _cell(
                context,
                'Room total',
                formatMoney(e.grandTotal, currency),
                bold: true,
              ),
            ] else
              const Expanded(flex: 3, child: SizedBox()),
            if (e != null && _roomFlags(room).isNotEmpty)
              Tooltip(
                message: _roomFlags(room).join('\n'),
                child: Icon(
                  Icons.info_outline,
                  size: 18,
                  color: theme.colorScheme.tertiary,
                ),
              ),
            IconButton(
              tooltip: 'Move up',
              icon: const Icon(Icons.arrow_upward, size: 18),
              onPressed: isFirst
                  ? null
                  : () => provider.moveProjectRoom(room.ref.id, -1),
            ),
            IconButton(
              tooltip: 'Move down',
              icon: const Icon(Icons.arrow_downward, size: 18),
              onPressed: isLast
                  ? null
                  : () => provider.moveProjectRoom(room.ref.id, 1),
            ),
            IconButton(
              tooltip: 'Remove from the project (the room file is untouched)',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => provider.removeRoomFromProject(room.ref.id),
            ),
          ],
        ),
      ),
    );
  }

  static List<String> _roomFlags(ProjectRoomCost room) {
    final e = room.estimate!;
    return [
      if (room.room.isEmpty) 'Nothing drawn in this room yet.',
      if (e.unpricedLines > 0)
        '${e.unpricedLines} line(s) have no price — this room\'s total is '
            'short.',
      if (e.unratedLabor > 0)
        '${e.unratedLabor} labor line(s) have no rate on the rate card.',
      if (e.estimatedLines > 0)
        '${e.estimatedLines} line(s) priced off the base-cost card — '
            'budgetary, not quoted.',
      if (e.otherTierLines > 0)
        '${e.otherTierLines} line(s) could only be priced at the other '
            'pricing tier.',
      if (e.excludedLines > 0)
        '${e.excludedLines} line(s) are drawn but deliberately not bought.',
    ];
  }

  Widget _cell(
    BuildContext context,
    String label,
    String value, {
    bool bold = false,
  }) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: bold ? FontWeight.bold : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _BuildingTotals extends StatelessWidget {
  final ProjectEstimate estimate;
  const _BuildingTotals({required this.estimate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget line(String label, double value, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: bold
                  ? theme.textTheme.titleSmall
                  : theme.textTheme.bodyMedium,
            ),
          ),
          Text(
            formatMoney(value, estimate.currency),
            style:
                (bold ? theme.textTheme.titleSmall : theme.textTheme.bodyMedium)
                    ?.copyWith(fontWeight: bold ? FontWeight.bold : null),
          ),
        ],
      ),
    );

    return Card(
      margin: const EdgeInsets.only(top: 10),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Building total', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            line('Equipment', estimate.equipmentTotal),
            line('Rack hardware', estimate.hardwareTotal),
            line('Cabling', estimate.cablingTotal),
            line('Other items', estimate.extrasTotal),
            const Divider(),
            line('Parts subtotal', estimate.partsTotal),
            line(
              'Labor (${trimNumber(estimate.laborHours)} hrs)',
              estimate.laborTotal,
            ),
            line('Fees', estimate.feeTotal),
            line('Tax', estimate.taxTotal),
            const Divider(),
            line('Project total', estimate.grandTotal, bold: true),
            if (estimate.mixedCurrency)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Rooms on this project are quoted in different currencies. '
                  'The figures above add them as though they were the same '
                  'one — fix the room currencies before relying on any of it.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            // Fees and tax are per-room percentages, and a reader who assumes
            // otherwise will try to check the total with a calculator and
            // conclude the app is wrong.
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Fees and tax are each room’s own, applied at that '
                'room’s rates and then added — not a project-wide '
                'percentage.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  MASTER PARTS
// ---------------------------------------------------------------------------

class _PartsPane extends StatelessWidget {
  final ProjectEstimate estimate;
  final String vendorFilter;
  final String untaggedFilter;
  final String undrivenFilter;
  final String search;
  final ValueChanged<String> onVendorFilter;
  final ValueChanged<String> onSearch;

  const _PartsPane({
    required this.estimate,
    required this.vendorFilter,
    required this.untaggedFilter,
    required this.undrivenFilter,
    required this.search,
    required this.onVendorFilter,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needle = search.trim().toLowerCase();

    final lines = [
      for (final l in estimate.master)
        if (_matchesVendor(l) && _matchesSearch(l, needle)) l,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(
            children: [
              SizedBox(
                width: 260,
                child: LiveTextField(
                  fieldId: 'project_part_search',
                  initial: search,
                  label: 'Search parts',
                  hint: 'model, part number, maker',
                  onChanged: onSearch,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _filterChip(context, 'All (${estimate.master.length})', ''),
                    for (final p in estimate.vendors)
                      if (!p.isUntagged)
                        _filterChip(
                          context,
                          '${p.name} (${p.lines.length})',
                          p.vendor!.id,
                        ),
                    if (estimate.untaggedParts > 0)
                      _filterChip(
                        context,
                        'Untagged (${estimate.untaggedParts})',
                        untaggedFilter,
                        warn: true,
                      ),
                    if (estimate.master.any((l) => l.hasControlGap))
                      _filterChip(
                        context,
                        'No control module (${estimate.master.where(
                          (l) => l.hasControlGap,
                        ).length})',
                        undrivenFilter,
                        warn: true,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (estimate.master.isEmpty)
          const Expanded(
            child: Center(
              child: Text(
                'Nothing to order yet.\n\n'
                'The master list is built from the rooms on this project — '
                'add rooms that have equipment on them.',
                textAlign: TextAlign.center,
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: lines.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) return _PartsHeaderRow(theme: theme);
                return _PartRow(line: lines[index - 1], estimate: estimate);
              },
            ),
          ),
      ],
    );
  }

  bool _matchesVendor(MasterPartLine line) {
    if (vendorFilter.isEmpty) return true;
    if (vendorFilter == untaggedFilter) return line.vendor == null;
    // Not a vendor at all — the other question this list gets asked. It shares
    // the one filter because only one of these is usefully on at a time, and
    // two rows of chips would be two rows to read.
    if (vendorFilter == undrivenFilter) return line.hasControlGap;
    return line.vendor?.id == vendorFilter;
  }

  bool _matchesSearch(MasterPartLine line, String needle) {
    if (needle.isEmpty) return true;
    return '${line.description} ${line.model} ${line.partNumber} '
            '${line.manufacturer} ${line.category}'
        .toLowerCase()
        .contains(needle);
  }

  Widget _filterChip(
    BuildContext context,
    String label,
    String value, {
    bool warn = false,
  }) {
    final theme = Theme.of(context);
    return FilterChip(
      label: Text(label),
      selected: vendorFilter == value,
      onSelected: (_) => onVendorFilter(value),
      backgroundColor: warn ? theme.colorScheme.errorContainer : null,
    );
  }
}

class _PartsHeaderRow extends StatelessWidget {
  final ThemeData theme;
  const _PartsHeaderRow({required this.theme});

  @override
  Widget build(BuildContext context) {
    Widget h(String text, int flex, {TextAlign align = TextAlign.left}) =>
        Expanded(
          flex: flex,
          child: Text(
            text,
            textAlign: align,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Row(
        children: [
          h('Part', 5),
          h('Qty', 1, align: TextAlign.right),
          h('Unit', 2, align: TextAlign.right),
          h('Extended', 2, align: TextAlign.right),
          h('Vendor', 3),
          const SizedBox(width: 40),
          const SizedBox(width: 40),
        ],
      ),
    );
  }
}

class _PartRow extends StatelessWidget {
  final MasterPartLine line;
  final ProjectEstimate estimate;

  const _PartRow({required this.line, required this.estimate});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final theme = Theme.of(context);
    final currency = estimate.currency;
    final roomNames = {for (final r in estimate.rooms) r.ref.id: r.name};

    final rooms = [
      for (final id in line.roomIdsByQty())
        '${roomNames[id] ?? id} ×${trimNumber(line.qtyByRoom[id] ?? 0)}',
    ].join(', ');

    final subtitle = [
      if (line.manufacturer.isNotEmpty) line.manufacturer,
      if (line.model.isNotEmpty) line.model,
      if (line.partNumber.isNotEmpty) 'PN ${line.partNumber}',
      kMasterPartKindLabels[line.kind]!,
    ].join('  ·  ');

    // Which rooms still have no driver for this product. Named rather than
    // counted: "3 undriven" is something to go and investigate, a list of
    // rooms is something to work through.
    final undriven = [
      for (final e in line.undrivenByRoom.entries)
        '${roomNames[e.key] ?? e.key} ×${e.value}',
    ].join(', ');

    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(line.description, style: theme.textTheme.bodyMedium),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    rooms,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (line.hasControlGap)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(
                            Icons.memory,
                            size: 13,
                            color: theme.colorScheme.error,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              'No control module — $undriven',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 1,
              child: Text(
                trimNumber(line.qty),
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Tooltip(
                message: line.priceVaries
                    ? 'Rooms on this job hold different prices for this part '
                          '— one of them has a negotiated override.'
                    : '',
                child: Text(
                  line.unpriced
                      ? 'not priced'
                      : line.priceVaries
                      ? '${formatMoney(line.unitPrice, currency)}–'
                            '${formatMoney(line.maxUnitPrice, currency)}'
                      : formatMoney(line.unitPrice, currency),
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: line.unpriced ? theme.colorScheme.error : null,
                    fontStyle: line.priceVaries ? FontStyle.italic : null,
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                formatMoney(line.total, currency),
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: _VendorPicker(line: line, estimate: estimate),
            ),
            SizedBox(
              width: 40,
              child: line.tagSource == VendorTagSource.pinned
                  ? IconButton(
                      tooltip:
                          'Clear the pin — let the vendor rules decide '
                          'again',
                      icon: const Icon(Icons.push_pin, size: 18),
                      onPressed: () => provider.pinProjectPart(line.key, ''),
                    )
                  : Tooltip(
                      message: kVendorTagSourceLabels[line.tagSource] ?? '',
                      child: Icon(
                        line.tagSource == VendorTagSource.none
                            ? Icons.help_outline
                            : Icons.rule,
                        size: 18,
                        color: line.tagSource == VendorTagSource.none
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
            ),
            SizedBox(
              width: 40,
              // Only equipment can be swapped: a length of cable and a
              // blanking plate are not products with connectors to remap, and
              // the estimate prices them from their own tables anyway.
              child: line.kind == MasterPartKind.equipment
                  ? IconButton(
                      key: ValueKey('project_swap_${line.key}'),
                      tooltip: 'Swap this product in every room that has it',
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      onPressed: () => swapPartAcrossProject(
                        context,
                        provider,
                        line,
                      ),
                    )
                  : const SizedBox(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Swapping one product for another in every room that has it.
///
/// Two dialogs on purpose. The first picks the replacement — a catalog search,
/// the same one the Signal Flow tab uses. The second shows what that would
/// actually DO: how many boxes in how many rooms, how many runs carry across,
/// how many get dropped, and whether the control blocks are about to lose
/// their module.
///
/// Nothing is written between them. A bulk edit across nine files that a
/// person cannot preview is a bulk edit nobody should press, and "how many
/// cables am I about to lose" is not a question the app should make somebody
/// find out by trying it.
Future<void> swapPartAcrossProject(
  BuildContext context,
  AppStateProvider provider,
  MasterPartLine line,
) async {
  if (line.model.trim().isEmpty) {
    showTimedSnackBar(
      ScaffoldMessenger.of(context),
      const SnackBar(
        duration: Duration(seconds: 5),
        content: Text(
          'This line has no model on it, so there is nothing to match in the '
          'other rooms. Set a model on the device first.',
        ),
      ),
    );
    return;
  }

  final template = await pickCatalogModel(
    context,
    provider,
    title: 'Swap ${line.model} across the project',
    actionLabel: 'Continue',
    currentModel: line.model,
    note:
        'Every box on this product, in every room on the project, becomes the '
        'one you pick. You will see exactly what changes before anything is '
        'written.',
  );
  if (template == null || !context.mounted) return;

  if (template.model.trim().toLowerCase() == line.model.trim().toLowerCase()) {
    showTimedSnackBar(
      ScaffoldMessenger.of(context),
      const SnackBar(
        duration: Duration(seconds: 4),
        content: Text('That is the product it already is.'),
      ),
    );
    return;
  }

  final plan = provider.planProjectModelSwap(line.model, template);
  if (!context.mounted) return;

  if (plan.isEmpty) {
    showTimedSnackBar(
      ScaffoldMessenger.of(context),
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          plan.failedRooms.isEmpty
              ? 'No room on this project has a ${line.model} on its drawing.'
              : 'Nothing to swap — and ${plan.failedRooms.length} room(s) '
                    'could not be read, so they were not checked.',
        ),
      ),
    );
    return;
  }

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => _SwapPreviewDialog(plan: plan),
  );
  if (go != true || !context.mounted) return;

  final result = provider.applyProjectModelSwap(plan);
  if (!context.mounted) return;

  final rooms = result.disk.rooms + (result.openRoomBoxes > 0 ? 1 : 0);
  final boxes = result.disk.boxes + result.openRoomBoxes;
  final parts = <String>[
    '$boxes box(es) swapped to ${template.model} across $rooms room(s)',
    if (result.disk.dropped > 0) '${result.disk.dropped} run(s) dropped',
    if (result.openRoomDirty)
      'the open room changed in memory — save it to keep the change',
    if (result.disk.failures.isNotEmpty)
      '${result.disk.failures.length} room(s) failed: '
          '${result.disk.failures.first}',
  ];
  showTimedSnackBar(
    ScaffoldMessenger.of(context),
    SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(parts.join('  ·  ')),
      backgroundColor: result.disk.failures.isEmpty ? null : Colors.red,
    ),
  );
}

/// What the swap is about to do, room by room, before it does it.
class _SwapPreviewDialog extends StatelessWidget {
  final ProjectSwapPlan plan;
  const _SwapPreviewDialog({required this.plan});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget warning(IconData icon, String text, {bool severe = false}) =>
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 18,
                color: severe
                    ? theme.colorScheme.error
                    : theme.colorScheme.tertiary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: severe ? theme.colorScheme.error : null,
                  ),
                ),
              ),
            ],
          ),
        );

    return AlertDialog(
      title: Text('Swap ${plan.fromModel} → ${plan.to.model}'),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${plan.boxes} box(es) in ${plan.affectedRooms.length} room(s).',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final room in plan.affectedRooms)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                room.isOpenRoom
                                    ? '${room.roomName}  (open)'
                                    : room.roomName,
                                style: theme.textTheme.bodyMedium,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              [
                                '${room.boxes} box'
                                    '${room.boxes == 1 ? '' : 'es'}',
                                '${room.carried} run'
                                    '${room.carried == 1 ? '' : 's'} kept',
                                if (room.dropped > 0) '${room.dropped} DROPPED',
                                if (room.blocks > 0)
                                  '${room.blocks} control block'
                                      '${room.blocks == 1 ? '' : 's'}',
                              ].join('  ·  '),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: room.dropped > 0
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(),
            if (plan.dropped > 0)
              warning(
                Icons.link_off,
                '${plan.dropped} drawn run(s) land on connectors the '
                '${plan.to.model} does not have. They will be REMOVED — draw '
                'them again on the Signal Flow tab of those rooms afterwards.',
                severe: true,
              ),
            if (plan.losesModule)
              warning(
                Icons.memory,
                'No Python module claims ${plan.to.model}, so the module is '
                'cleared on all ${plan.blocks} control block(s). Those devices '
                'will show as having no control module until a driver is '
                'picked — which is what you want them to say.',
              ),
            if (plan.newModule.isNotEmpty && plan.blocks > 0)
              warning(
                Icons.check_circle_outline,
                '${plan.blocks} control block(s) move to ${plan.newModule}. IP '
                'addresses, ports and control ids are kept.',
              ),
            if (plan.anyRackHeightChanged)
              warning(
                Icons.view_day,
                'The new product is a different rack height. Boxes keep the U '
                'they start at, so check the elevations.',
              ),
            if (plan.failedRooms.isNotEmpty)
              warning(
                Icons.error_outline,
                '${plan.failedRooms.length} room(s) could not be read and were '
                'not checked: '
                '${plan.failedRooms.map((r) => r.roomName).join(', ')}. They '
                'keep the old product.',
                severe: true,
              ),
            warning(
              Icons.save,
              'This writes to the room files directly. There is no '
              'project-wide undo — a room\'s own Undo only covers the room '
              'open in the editor.',
              severe: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('project_swap_apply'),
          onPressed: () => Navigator.pop(context, true),
          child: Text('Swap ${plan.boxes} box(es)'),
        ),
      ],
    );
  }
}

/// The per-part vendor override.
class _VendorPicker extends StatelessWidget {
  final MasterPartLine line;
  final ProjectEstimate estimate;

  const _VendorPicker({required this.line, required this.estimate});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final theme = Theme.of(context);
    final vendors = estimate.project.vendors;

    if (vendors.isEmpty) {
      return Text(
        'No vendors yet',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        isDense: true,
        isExpanded: true,
        value: line.vendor?.id ?? '',
        items: [
          DropdownMenuItem(
            value: '',
            child: Text(
              'Untagged',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
          for (final v in vendors)
            DropdownMenuItem(value: v.id, child: Text(v.name)),
        ],
        onChanged: (id) {
          // Choosing the vendor the rules already picked clears the pin
          // instead of freezing it. Otherwise a glance down the column and a
          // few confirming clicks would quietly pin half the list, and the
          // next rule change would skip every part somebody had "agreed" with.
          final chosen = id ?? '';
          provider.pinProjectPart(
            line.key,
            chosen == _ruleOnly(line) ? '' : chosen,
          );
        },
      ),
    );
  }

  /// What the RULES alone would tag this part with, ignoring any pin — needed
  /// to tell "the user agreed with the rule" from "the user overrode it".
  String _ruleOnly(MasterPartLine line) {
    for (final v in estimate.project.vendors) {
      if (v.quotesManufacturer(line.manufacturer)) return v.id;
    }
    for (final v in estimate.project.vendors) {
      if (v.quotesCategory(line.category)) return v.id;
    }
    return '';
  }
}

// ---------------------------------------------------------------------------
//  VENDORS
// ---------------------------------------------------------------------------

class _VendorsPane extends StatelessWidget {
  final ProjectEstimate estimate;
  const _VendorsPane({required this.estimate});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final theme = Theme.of(context);
    final vendors = estimate.project.vendors;
    final conflicts = estimate.project.vendorConflicts;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: () => provider.addProjectVendor(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add vendor'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'A part is tagged by the FIRST vendor whose rules claim it. '
                  'Manufacturer rules are checked before category rules, so '
                  '“buy Extron direct” beats “the reseller does '
                  'screens” for an Extron screen. Order matters — move a '
                  'vendor up to give it priority.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (conflicts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Overlapping rules',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    for (final c in conflicts)
                      Text(
                        '${c.kind} "${c.rule}" is claimed by '
                        '${c.vendors.map((v) => v.name).join(' and ')}. '
                        '${c.vendors.first.name} wins.',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: vendors.isEmpty
              ? const Center(
                  child: Text(
                    'No vendors yet.\n\n'
                    'Add one per company you send quote requests to, and give '
                    'it the manufacturers or the categories it sells.',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: vendors.length,
                  itemBuilder: (context, index) => _VendorCard(
                    vendor: vendors[index],
                    package: estimate.packageFor(vendors[index].id),
                    currency: estimate.currency,
                    isFirst: index == 0,
                    isLast: index == vendors.length - 1,
                  ),
                ),
        ),
      ],
    );
  }
}

class _VendorCard extends StatelessWidget {
  final ProjectVendor vendor;
  final VendorPackage? package;
  final String currency;
  final bool isFirst;
  final bool isLast;

  const _VendorCard({
    required this.vendor,
    required this.package,
    required this.currency,
    required this.isFirst,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.read<AppStateProvider>();
    final facets = provider.catalogFacets;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: LiveTextField(
                    fieldId: 'vendor_name_${vendor.id}',
                    initial: vendor.name,
                    label: 'Vendor',
                    onChanged: (v) =>
                        provider.updateProjectVendor(vendor.copyWith(name: v)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: LiveTextField(
                    fieldId: 'vendor_contact_${vendor.id}',
                    initial: vendor.contact,
                    label: 'Contact',
                    hint: 'who the RFQ goes to',
                    onChanged: (v) => provider.updateProjectVendor(
                      vendor.copyWith(contact: v),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (package != null)
                  Chip(
                    label: Text(
                      '${package!.lines.length} lines  ·  '
                      '${formatMoney(package!.total, currency)}',
                    ),
                  ),
                IconButton(
                  tooltip: 'Higher priority',
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed: isFirst
                      ? null
                      : () => provider.moveProjectVendor(vendor.id, -1),
                ),
                IconButton(
                  tooltip: 'Lower priority',
                  icon: const Icon(Icons.arrow_downward, size: 18),
                  onPressed: isLast
                      ? null
                      : () => provider.moveProjectVendor(vendor.id, 1),
                ),
                IconButton(
                  tooltip: 'Remove this vendor and every tag pointing at it',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => provider.removeProjectVendor(vendor.id),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _RuleEditor(
              label: 'Manufacturers',
              hint: 'Extron',
              helper: 'Every part by these makers goes to this vendor.',
              values: vendor.manufacturers,
              suggestions: facets.manufacturers,
              onChanged: (v) => provider.updateProjectVendor(
                vendor.copyWith(manufacturers: v),
              ),
            ),
            const SizedBox(height: 8),
            _RuleEditor(
              label: 'Categories',
              hint: 'Camera',
              helper:
                  'Matches finer categories too — "Camera" claims '
                  '"Camera - PTZ". Checked after the manufacturer rules.',
              values: vendor.categories,
              suggestions: facets.categories,
              onChanged: (v) =>
                  provider.updateProjectVendor(vendor.copyWith(categories: v)),
            ),
            const SizedBox(height: 8),
            LiveTextField(
              fieldId: 'vendor_notes_${vendor.id}',
              initial: vendor.notes,
              label: 'Notes on the quote request',
              maxLines: 2,
              onChanged: (v) =>
                  provider.updateProjectVendor(vendor.copyWith(notes: v)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A list of rule strings as removable chips, with an autocomplete to add one.
///
/// The autocomplete draws on the catalog rather than being free text with a
/// hint, because a rule is matched EXACTLY: "Extron Electronics" typed into a
/// catalog that says "Extron" is a rule that silently matches nothing, and
/// nothing about the screen would say so.
class _RuleEditor extends StatelessWidget {
  final String label;
  final String hint;
  final String helper;
  final List<String> values;
  final List<String> suggestions;
  final ValueChanged<List<String>> onChanged;

  const _RuleEditor({
    required this.label,
    required this.hint,
    required this.helper,
    required this.values,
    required this.suggestions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unused = [
      for (final s in suggestions)
        if (!values.any((v) => v.toLowerCase() == s.toLowerCase())) s,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          helper,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final v in values)
              InputChip(
                label: Text(v),
                onDeleted: () => onChanged([
                  for (final x in values)
                    if (x != v) x,
                ]),
              ),
            SizedBox(
              width: 220,
              child: Autocomplete<String>(
                optionsBuilder: (value) {
                  final needle = value.text.trim().toLowerCase();
                  if (needle.isEmpty) return const Iterable<String>.empty();
                  return unused.where((s) => s.toLowerCase().contains(needle));
                },
                onSelected: (s) => onChanged([...values, s]),
                fieldViewBuilder:
                    (context, controller, focusNode, onFieldSubmitted) =>
                        TextField(
                          controller: controller,
                          focusNode: focusNode,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'add — e.g. $hint',
                            border: const OutlineInputBorder(),
                          ),
                          onSubmitted: (text) {
                            final value = text.trim();
                            if (value.isEmpty) return;
                            if (!values.any(
                              (v) => v.toLowerCase() == value.toLowerCase(),
                            )) {
                              onChanged([...values, value]);
                            }
                            controller.clear();
                          },
                        ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
