import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'building_project.dart';
import 'project_estimate.dart';
import 'report_tools.dart';
import 'responsibility_matrix.dart';
import 'screenshot_tools.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  THE RESPONSIBILITY PANE
/// ============================================================================
///  The roles and responsibilities matrix, edited and issued. See
///  responsibility_matrix.dart for what the document is and why it is a row per
///  scope item rather than a column per one.
///
///  TWO WAYS OUT, because it is read by two different audiences:
///
///    * A SPREADSHEET, for the people who work from it — the contractor prices
///      the totals column, and a spreadsheet is what a price gets typed into.
///    * A PICTURE, for the people who only have to see it — it goes in a
///      submittal, in a slide, in an email to a dean. Those readers do not want
///      a file to open, and a screenshot somebody takes by hand is one that
///      cuts off the last two rows.
///
///  The picture is produced from a PREVIEW somebody looks at first rather than
///  captured off this pane. What is on this pane is an editor — it has buttons
///  on every row and it is as wide as the window — and photographing an editor
///  produces a picture with delete buttons in it. The preview is the document.
/// ============================================================================

/// The matrix pane, as slivers for the project tab's one scroll view.
///
/// [estimate] is taken and unused: every pane on the tab has the same
/// signature, and this one is about the job's scope rather than its price. A
/// pane that could not be called the same way as the others is a pane the
/// switch above it has to special-case.
List<Widget> responsibilitySlivers(
  BuildContext context,
  // ignore: avoid_unused_constructor_parameters
  ProjectEstimate estimate,
) {
  final provider = context.watch<AppStateProvider>();
  final project = provider.project;
  final items = project.responsibility;
  // The code on the door - 'BSS 101' - not the file the room is stored in.
  // Only this layer has both the job's room list and the configs behind it.
  final columns = project.responsibilityRoomColumns(
    names: estimate.roomCodeNames,
  );

  return [
    SliverToBoxAdapter(child: _Toolbar(project: project, columns: columns)),
    const SliverToBoxAdapter(child: Divider(height: 1)),
    if (items.isNotEmpty)
      SliverToBoxAdapter(
        child: _MatrixGrid(project: project, columns: columns),
      ),
    if (items.isNotEmpty) const SliverToBoxAdapter(child: Divider(height: 1)),
    if (items.isEmpty)
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(
            child: Text(
              'Nothing agreed yet.\n\n'
              'The matrix says who buys each piece of scope and who installs '
              'it - the thing that is discovered on site when it was never '
              'written down. Start it from the usual lines and edit from '
              'there.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      )
    else
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, i) => _ItemRow(
            item: items[i],
            columns: columns,
            first: i == 0,
            last: i == items.length - 1,
          ),
          childCount: items.length,
        ),
      ),
    const SliverToBoxAdapter(child: SizedBox(height: 24)),
  ];
}

class _Toolbar extends StatelessWidget {
  final BuildingProject project;
  final List<({String id, String name})> columns;

  const _Toolbar({required this.project, required this.columns});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final items = project.responsibility;
    final open = items.where((i) => i.unassigned).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.tonalIcon(
            key: const ValueKey('responsibility_add'),
            onPressed: () async {
              final item = provider.addResponsibilityItem();
              if (!context.mounted) return;
              await showResponsibilityEditor(context, item.id, columns);
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add a line'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('responsibility_starters'),
            onPressed: () {
              final added = provider.addStarterResponsibilityItems();
              showTimedSnackBar(
                ScaffoldMessenger.of(context),
                SnackBar(
                  content: Text(
                    added == 0
                        ? 'Every one of the usual lines is already on the '
                            'matrix.'
                        : '$added line${added == 1 ? '' : 's'} added. Edit the '
                            'parties and quantities to suit the job.',
                  ),
                ),
              );
            },
            icon: const Icon(Icons.playlist_add, size: 18),
            label: const Text('Add the usual lines'),
          ),
          if (items.isNotEmpty) ...[
            OutlinedButton.icon(
              key: const ValueKey('responsibility_export_xlsx'),
              onPressed: () => _exportSpreadsheet(context, project, columns),
              icon: const Icon(Icons.table_view, size: 18),
              label: const Text('Spreadsheet'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('responsibility_export_image'),
              onPressed: () =>
                  showResponsibilityImage(context, project, columns),
              icon: const Icon(Icons.image_outlined, size: 18),
              label: const Text('Image'),
            ),
          ],
          if (open > 0)
            Text(
              '$open line${open == 1 ? '' : 's'} with nobody named. A matrix '
              'issued with blanks reads as agreed.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  THE MATRIX ITSELF
// ---------------------------------------------------------------------------

/// The matrix as a grid: rooms down the left, scope across the top.
///
/// THE ROOM COLUMN DOES NOT MOVE. A job with thirty scope items is far wider
/// than any window, and a grid where the room names scroll off to the left is
/// one where the number under your finger belongs to a room you can no longer
/// see — which is the exact mistake this document exists to prevent. So the
/// names are painted in a fixed column and only the scope columns scroll.
///
/// The two halves are laid out with the SAME fixed row heights rather than
/// with intrinsic ones, because that is the only way two independent columns
/// stay on the same line as each other. Every height here is shared by both.
class _MatrixGrid extends StatelessWidget {
  final BuildingProject project;
  final List<({String id, String name})> columns;

  const _MatrixGrid({required this.project, required this.columns});

  /// Room names, and the scope name over each column.
  static const double _headRow = 58;

  /// The two party rows under each scope name.
  static const double _partyRow = 20;

  /// One room, and the totals row.
  static const double _bodyRow = 26;

  static const double _roomColumn = 168;
  static const double _itemColumn = 104;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = project.responsibility;
    if (items.isEmpty || columns.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _frozenColumn(theme),
          Expanded(
            child: Scrollbar(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final item in items) _itemColumnFor(context, item),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The half that stays put: what each row IS.
  Widget _frozenColumn(ThemeData theme) => SizedBox(
    width: _roomColumn,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _cell(
          height: _headRow,
          align: Alignment.bottomLeft,
          child: Text('ROOM', style: _headStyle(theme)),
        ),
        _cell(
          height: _partyRow,
          child: Text('Furnished by', style: _metaStyle(theme)),
        ),
        _cell(
          height: _partyRow,
          child: Text('Installed by', style: _metaStyle(theme)),
        ),
        for (final room in columns)
          _cell(
            height: _bodyRow,
            child: Text(
              room.name,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        _cell(
          height: _bodyRow,
          child: Text('Totals', style: _headStyle(theme)),
        ),
      ],
    ),
  );

  /// One scope item, top to bottom.
  Widget _itemColumnFor(BuildContext context, ResponsibilityItem item) {
    final theme = Theme.of(context);
    final unassigned = item.unassigned;

    return SizedBox(
      width: _itemColumn,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The heading is the way IN to the line: everything about it except
          // the quantities is prose, and prose is edited in the dialog.
          InkWell(
            key: ValueKey('matrix_head_${item.id}'),
            onTap: () => showResponsibilityEditor(context, item.id, columns),
            child: _cell(
              height: _headRow,
              align: Alignment.bottomLeft,
              child: Text(
                item.scope,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          _cell(
            height: _partyRow,
            child: Text(
              item.furnishedBy.isEmpty ? '-' : item.furnishedBy,
              overflow: TextOverflow.ellipsis,
              style: _metaStyle(theme).copyWith(
                color: unassigned && item.furnishedBy.isEmpty
                    ? theme.colorScheme.error
                    : null,
              ),
            ),
          ),
          _cell(
            height: _partyRow,
            child: Text(
              item.installedBy.isEmpty ? '-' : item.installedBy,
              overflow: TextOverflow.ellipsis,
              style: _metaStyle(theme).copyWith(
                color: unassigned && item.installedBy.isEmpty
                    ? theme.colorScheme.error
                    : null,
              ),
            ),
          ),
          for (final room in columns)
            InkWell(
              key: ValueKey('matrix_cell_${item.id}_${room.id}'),
              onTap: () => _editQty(context, item, room),
              child: _cell(
                height: _bodyRow,
                align: Alignment.center,
                child: Text(
                  formatResponsibilityQty(item.qtyByRoom[room.id] ?? 0),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          _cell(
            height: _bodyRow,
            align: Alignment.center,
            child: Text(
              formatResponsibilityQty(item.total),
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Sets one cell. A dialog rather than an inline field: thirty columns of
  /// live text fields is thirty focus nodes and thirty controllers on a grid
  /// most of whose cells are empty.
  Future<void> _editQty(
    BuildContext context,
    ResponsibilityItem item,
    ({String id, String name}) room,
  ) async {
    final provider = context.read<AppStateProvider>();
    final typed = await showDialog<double>(
      context: context,
      builder: (_) => _QtyDialog(
        title: '${item.scope} in ${room.name}',
        initial: item.qtyByRoom[room.id] ?? 0,
      ),
    );
    if (typed == null) return;
    provider.setResponsibilityQty(item.id, room.id, typed);
  }

  static TextStyle? _headStyle(ThemeData theme) =>
      theme.textTheme.labelSmall?.copyWith(
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.onSurfaceVariant,
      );

  static TextStyle _metaStyle(ThemeData theme) =>
      theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ) ??
      const TextStyle(fontSize: 11);

  static Widget _cell({
    required double height,
    required Widget child,
    Alignment align = Alignment.centerLeft,
  }) => Container(
    height: height,
    alignment: align,
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: child,
  );
}

/// How many of one thing in one room.
///
/// Its own widget so the controller is owned by a State. A controller made in
/// the caller and disposed when the dialog's future completes is torn out from
/// under a field the exit animation is still building — see the same note on
/// [_ResponsibilityEditorDialog].
class _QtyDialog extends StatefulWidget {
  final String title;
  final double initial;

  const _QtyDialog({required this.title, required this.initial});

  @override
  State<_QtyDialog> createState() => _QtyDialogState();
}

class _QtyDialogState extends State<_QtyDialog> {
  late final TextEditingController _qty = TextEditingController(
    text: widget.initial > 0 ? formatResponsibilityQty(widget.initial) : '',
  );

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(
    double.tryParse(_qty.text.trim()) ?? 0,
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('matrix_qty_dialog'),
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('matrix_qty_field'),
      controller: _qty,
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(
        labelText: 'How many',
        helperText: 'Blank or 0 takes this room off the line.',
        border: OutlineInputBorder(),
      ),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('matrix_qty_save'),
        onPressed: _save,
        child: const Text('Set'),
      ),
    ],
  );
}

/// One line of the matrix on the editor.
class _ItemRow extends StatelessWidget {
  final ResponsibilityItem item;
  final List<({String id, String name})> columns;
  final bool first;
  final bool last;

  const _ItemRow({
    required this.item,
    required this.columns,
    required this.first,
    required this.last,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final rooms = columns
        .where((c) => (item.qtyByRoom[c.id] ?? 0) > 0)
        .map((c) => '${c.name} ×${formatResponsibilityQty(item.qtyByRoom[c.id]!)}')
        .join('  ·  ');

    return ListTile(
      key: ValueKey('responsibility_row_${item.id}'),
      title: Row(
        children: [
          Expanded(
            child: Text(item.scope, style: theme.textTheme.titleSmall),
          ),
          if (item.total > 0)
            Text(
              '${formatResponsibilityQty(item.total)} total',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Furnished by '
            '${item.furnishedBy.isEmpty ? 'NOBODY YET' : item.furnishedBy}'
            '  ·  installed by '
            '${item.installedBy.isEmpty ? 'NOBODY YET' : item.installedBy}'
            '${item.neededBy.isEmpty ? '' : '  ·  needed by ${item.neededBy}'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: item.unassigned
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (rooms.isNotEmpty)
            Text(rooms, style: theme.textTheme.bodySmall),
          if (item.work.isNotEmpty)
            Text(
              item.work,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Move up the sheet',
            icon: const Icon(Icons.arrow_upward, size: 18),
            onPressed:
                first ? null : () => provider.moveResponsibilityItem(item.id, -1),
          ),
          IconButton(
            tooltip: 'Move down the sheet',
            icon: const Icon(Icons.arrow_downward, size: 18),
            onPressed:
                last ? null : () => provider.moveResponsibilityItem(item.id, 1),
          ),
          IconButton(
            key: ValueKey('responsibility_edit_${item.id}'),
            tooltip: 'Edit this line',
            icon: const Icon(Icons.edit, size: 18),
            onPressed: () =>
                showResponsibilityEditor(context, item.id, columns),
          ),
          IconButton(
            key: ValueKey('responsibility_delete_${item.id}'),
            tooltip: 'Take it off the matrix',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () => provider.removeResponsibilityItem(item.id),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  EDITING ONE LINE
// ---------------------------------------------------------------------------

/// The editor for one line: the parties, the quantities per room, and the
/// prose.
///
/// One dialog rather than inline fields on the row because a line has nine
/// fields on it and four of them are prose. A row wide enough to edit them all
/// in place is a row nobody can read the sheet from, and the sheet is what this
/// pane is for.
Future<void> showResponsibilityEditor(
  BuildContext context,
  String itemId,
  List<({String id, String name})> columns,
) async {
  final provider = context.read<AppStateProvider>();
  final item = provider.project.responsibilityById(itemId);
  if (item == null) return;

  await showDialog<void>(
    context: context,
    builder: (_) => _ResponsibilityEditorDialog(item: item, columns: columns),
  );
}

/// The editor's own widget, so its controllers are owned by a State.
///
/// NOT a bag of controllers made in the function above and disposed when the
/// dialog's future completes. That future finishes when the route is popped,
/// and the route keeps BUILDING through its exit animation — so disposing
/// there tears the controllers out from under fields that are still on screen
/// for another two hundred milliseconds. Owned here, they go when the widget
/// goes, which is after the last frame that used them.
class _ResponsibilityEditorDialog extends StatefulWidget {
  final ResponsibilityItem item;
  final List<({String id, String name})> columns;

  const _ResponsibilityEditorDialog({
    required this.item,
    required this.columns,
  });

  @override
  State<_ResponsibilityEditorDialog> createState() =>
      _ResponsibilityEditorDialogState();
}

class _ResponsibilityEditorDialogState
    extends State<_ResponsibilityEditorDialog> {
  late final TextEditingController _scope =
      TextEditingController(text: widget.item.scope);
  late final TextEditingController _furnished =
      TextEditingController(text: widget.item.furnishedBy);
  late final TextEditingController _installed =
      TextEditingController(text: widget.item.installedBy);
  late final TextEditingController _needed =
      TextEditingController(text: widget.item.neededBy);
  late final TextEditingController _work =
      TextEditingController(text: widget.item.work);
  late final TextEditingController _link =
      TextEditingController(text: widget.item.productLink);
  late final TextEditingController _notes =
      TextEditingController(text: widget.item.notes);
  late final Map<String, TextEditingController> _qty = {
    for (final room in widget.columns)
      room.id: TextEditingController(
        text: (widget.item.qtyByRoom[room.id] ?? 0) > 0
            ? formatResponsibilityQty(widget.item.qtyByRoom[room.id]!)
            : '',
      ),
  };

  @override
  void dispose() {
    _scope.dispose();
    _furnished.dispose();
    _installed.dispose();
    _needed.dispose();
    _work.dispose();
    _link.dispose();
    _notes.dispose();
    for (final c in _qty.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final counts = <String, double>{};
    for (final room in widget.columns) {
      final value = double.tryParse(_qty[room.id]!.text.trim()) ?? 0;
      if (value > 0) counts[room.id] = value;
    }
    context.read<AppStateProvider>().updateResponsibilityItem(
      widget.item.copyWith(
        // A scope typed empty keeps the name it had: the row has to stay
        // findable on the sheet, and a blank line is one nobody can delete
        // because they cannot tell which one it is.
        scope: _scope.text.trim().isEmpty
            ? widget.item.scope
            : _scope.text.trim(),
        furnishedBy: _furnished.text.trim(),
        installedBy: _installed.text.trim(),
        neededBy: _needed.text.trim(),
        qtyByRoom: counts,
        work: _work.text.trim(),
        productLink: _link.text.trim(),
        notes: _notes.text.trim(),
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final columns = widget.columns;
    return AlertDialog(
      key: const ValueKey('responsibility_editor'),
      title: const Text('Scope, and whose job it is'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('responsibility_scope'),
                controller: _scope,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Scope',
                  hintText: 'Ceiling speakers',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _PartyField(
                      fieldKey: const ValueKey('responsibility_furnished'),
                      controller: _furnished,
                      label: 'Furnished by',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _PartyField(
                      fieldKey: const ValueKey('responsibility_installed'),
                      controller: _installed,
                      label: 'Installed by',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _needed,
                      decoration: const InputDecoration(
                        labelText: 'Needed by',
                        hintText: 'TBD',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              if (columns.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'HOW MANY, PER ROOM',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final room in columns)
                      SizedBox(
                        width: 130,
                        child: TextField(
                          key: ValueKey('responsibility_qty_${room.id}'),
                          controller: _qty[room.id],
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: room.name,
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('responsibility_work'),
                controller: _work,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'What the work is',
                  helperText: 'The words this gets read in on site.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _link,
                decoration: const InputDecoration(
                  labelText: 'Product or cutsheet',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Notes and open questions',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('responsibility_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('responsibility_save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// A party field: free text with the usual answers one press away.
///
/// An [Autocomplete] rather than a dropdown because a real matrix names actual
/// parties — "CTS Chico", "CFCI", "Valley/DPR" — and a closed list would force
/// those into a generic word that loses the point of writing it down.
class _PartyField extends StatelessWidget {
  final Key fieldKey;
  final TextEditingController controller;
  final String label;

  const _PartyField({
    required this.fieldKey,
    required this.controller,
    required this.label,
  });

  @override
  Widget build(BuildContext context) => TextField(
    key: fieldKey,
    controller: controller,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      suffixIcon: PopupMenuButton<String>(
        tooltip: 'The usual answers',
        icon: const Icon(Icons.arrow_drop_down),
        itemBuilder: (_) => [
          for (final party in kResponsibilityParties)
            PopupMenuItem(value: party, child: Text(party)),
        ],
        onSelected: (value) => controller.text = value,
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
//  ISSUING IT
// ---------------------------------------------------------------------------

/// The matrix as a one-sheet .xlsx.
Future<void> _exportSpreadsheet(
  BuildContext context,
  BuildingProject project,
  List<({String id, String name})> columns,
) async {
  final provider = context.read<AppStateProvider>();
  final sections = responsibilityMatrixSections(
    project.responsibility,
    roomNames: columns,
  );
  if (sections.isEmpty) return;

  final stem = project.name.trim().isEmpty
      ? 'project'
      : project.name.trim().replaceAll(RegExp(r'[^\w\-]+'), '_');
  final picked = await FilePicker.saveFile(
    dialogTitle: 'Save the responsibility matrix',
    fileName: '${stem}_responsibility.xlsx',
    type: FileType.custom,
    allowedExtensions: const ['xlsx'],
  );
  if (picked == null) return;
  final target =
      picked.toLowerCase().endsWith('.xlsx') ? picked : '$picked.xlsx';

  try {
    await File(target).writeAsBytes(
      buildXlsx([
        buildStackedReportSheet(
          sheetName: 'Responsibility',
          title: project.name.trim().isEmpty
              ? 'Roles and responsibilities'
              : '${project.name} - roles and responsibilities',
          sections: sections,
        ),
      ]),
    );
    if (context.mounted) {
      showSavedFileSnack(
        context,
        provider,
        'The responsibility matrix',
        target,
      );
    }
  } catch (e) {
    if (context.mounted) {
      showTimedSnackBar(
        ScaffoldMessenger.of(context),
        SnackBar(content: Text('The matrix could not be written: $e')),
      );
    }
  }
}

/// Shows the matrix as it will be PICTURED, and offers to save the picture.
Future<void> showResponsibilityImage(
  BuildContext context,
  BuildingProject project,
  List<({String id, String name})> columns,
) => showDialog<void>(
  context: context,
  builder: (_) =>
      _ResponsibilityImageDialog(project: project, columns: columns),
);

class _ResponsibilityImageDialog extends StatefulWidget {
  final BuildingProject project;
  final List<({String id, String name})> columns;

  const _ResponsibilityImageDialog({
    required this.project,
    required this.columns,
  });

  @override
  State<_ResponsibilityImageDialog> createState() =>
      _ResponsibilityImageDialogState();
}

class _ResponsibilityImageDialogState
    extends State<_ResponsibilityImageDialog> {
  final GlobalKey _boundary = GlobalKey();
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    final provider = context.read<AppStateProvider>();
    Uint8List? bytes;
    try {
      // Two pixels per logical one: the picture goes into a submittal and is
      // read on paper, where a screen-resolution capture of a table of small
      // type is unreadable.
      bytes = await captureBoundary(_boundary, pixelRatio: 2.0);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (bytes == null) {
      if (mounted) {
        showTimedSnackBar(
          ScaffoldMessenger.of(context),
          const SnackBar(content: Text('The matrix could not be captured.')),
        );
      }
      return;
    }

    final stem = widget.project.name.trim().isEmpty
        ? 'project'
        : widget.project.name.trim().replaceAll(RegExp(r'[^\w\-]+'), '_');
    final picked = await FilePicker.saveFile(
      dialogTitle: 'Save the responsibility matrix',
      fileName: '${stem}_responsibility.png',
      type: FileType.custom,
      allowedExtensions: const ['png'],
    );
    if (picked == null) return;
    final target =
        picked.toLowerCase().endsWith('.png') ? picked : '$picked.png';
    try {
      await File(target).writeAsBytes(bytes);
      if (mounted) {
        showSavedFileSnack(
          context,
          provider,
          'The responsibility matrix',
          target,
        );
      }
    } catch (e) {
      if (mounted) {
        showTimedSnackBar(
          ScaffoldMessenger.of(context),
          SnackBar(content: Text('The picture could not be written: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final columns = widget.columns;

    return AlertDialog(
      key: const ValueKey('responsibility_image_dialog'),
      title: const Text('The matrix as a picture'),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.7,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SingleChildScrollView(
            child: RepaintBoundary(
              key: _boundary,
              // Light, uncoloured, on white — the same treatment every drawing
              // that leaves this app gets, because this leaves it to be
              // printed and photocopied like the rest of them.
              child: printSkin(
                enabled: true,
                child: _MatrixTable(project: project, columns: columns),
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          key: const ValueKey('responsibility_save_png'),
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.download, size: 18),
          label: Text(_saving ? 'Capturing…' : 'Save as PNG'),
        ),
      ],
    );
  }
}

/// The matrix, drawn as the document rather than as an editor.
class _MatrixTable extends StatelessWidget {
  final BuildingProject project;
  final List<({String id, String name})> columns;

  const _MatrixTable({required this.project, required this.columns});

  @override
  Widget build(BuildContext context) {
    final items = project.responsibility;
    const headStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.bold,
      color: Colors.black,
    );
    const cellStyle = TextStyle(fontSize: 11, color: Colors.black);

    Widget cell(String text, {TextStyle style = cellStyle}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Text(text, style: style),
        );

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            project.name.trim().isEmpty
                ? 'Roles and responsibilities'
                : '${project.name} - roles and responsibilities',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
          Text(
            'Generated ${reportTimestamp()}',
            style: const TextStyle(fontSize: 10, color: Colors.black54),
          ),
          const SizedBox(height: 12),
          Table(
            defaultVerticalAlignment: TableCellVerticalAlignment.top,
            border: TableBorder.all(color: Colors.black26, width: 0.6),
            columnWidths: {
              0: const FixedColumnWidth(170),
              1: const FixedColumnWidth(95),
              2: const FixedColumnWidth(95),
              3: const FixedColumnWidth(90),
              for (var i = 0; i < columns.length; i++)
                4 + i: const FixedColumnWidth(62),
              4 + columns.length: const FixedColumnWidth(56),
              5 + columns.length: const FixedColumnWidth(300),
            },
            children: [
              TableRow(
                decoration: const BoxDecoration(color: Color(0xFFEDEDED)),
                children: [
                  cell('Scope', style: headStyle),
                  cell('Furnished by', style: headStyle),
                  cell('Installed by', style: headStyle),
                  cell('Needed by', style: headStyle),
                  for (final room in columns) cell(room.name, style: headStyle),
                  cell('Total', style: headStyle),
                  cell('What the work is', style: headStyle),
                ],
              ),
              for (final item in items)
                TableRow(
                  children: [
                    cell(item.scope),
                    cell(item.furnishedBy),
                    cell(item.installedBy),
                    cell(item.neededBy),
                    for (final room in columns)
                      cell(
                        formatResponsibilityQty(item.qtyByRoom[room.id] ?? 0),
                      ),
                    cell(formatResponsibilityQty(item.total)),
                    cell(item.work),
                  ],
                ),
              if (columns.isNotEmpty)
                TableRow(
                  decoration: const BoxDecoration(color: Color(0xFFF6F6F6)),
                  children: [
                    cell('Totals', style: headStyle),
                    cell(''),
                    cell(''),
                    cell(''),
                    for (final room in columns)
                      cell(
                        formatResponsibilityQty(
                          items.fold<double>(
                            0,
                            (sum, i) => sum + (i.qtyByRoom[room.id] ?? 0),
                          ),
                        ),
                        style: headStyle,
                      ),
                    cell(
                      formatResponsibilityQty(
                        items.fold<double>(0, (sum, i) => sum + i.total),
                      ),
                      style: headStyle,
                    ),
                    cell(''),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}
