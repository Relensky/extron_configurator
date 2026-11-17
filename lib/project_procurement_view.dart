import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'building_project.dart';
import 'color_wheel_picker.dart';
import 'column_drag.dart';
import 'file_dialogs.dart';
import 'name_colors.dart' show kNameTintWheel;
import 'pinned_grid.dart';
import 'procurement_log.dart';
import 'procurement_sync.dart';
import 'project_estimate.dart';
import 'project_schedule.dart' show formatScheduleDate;
import 'responsive.dart' show kFloatingButtonClearance;
import 'screenshot_tools.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  THE PROCUREMENT PANE
/// ============================================================================
///  The AV procurement log, edited here and issued to the contractor as a
///  spreadsheet with the columns their scheduler uses. See procurement_log.dart.
///
///  A sheet in its own frame: the device column is frozen, the headers stay
///  on top, both bars show, and it zooms like the responsibility matrix.
/// ============================================================================

/// Which band a header box is colored in.
enum _Group { item, status, schedule, dates, notes }

/// One column after the frozen device column: the id its color is kept
/// under (see [kProcurementColumnSpecs]), the heading shown, and its width.
typedef _Col = ({String id, String label, double width});

const List<_Col> _kCols = [
  (id: 'company', label: 'Company', width: 110),
  (id: 'room', label: 'Room #', width: 90),
  (id: 'manufacturer', label: 'Manufacturer', width: 130),
  (id: 'model', label: 'Model', width: 140),
  (id: 'partNumber', label: 'Part Number', width: 140),
  (id: 'description', label: 'Equipment Description', width: 210),
  (id: 'status', label: 'Status', width: 170),
  (id: 'phase', label: 'Install Before Drywall or After Paint?', width: 150),
  (id: 'p6Id', label: 'P6 Activity ID', width: 110),
  (id: 'p6Description', label: 'P6 Activity Description', width: 190),
  (id: 'review', label: 'Review Time', width: 90),
  (id: 'lead', label: 'Lead Times (Weeks)', width: 100),
  (id: 'p6Start', label: 'P6 Start Date', width: 120),
  (
    id: 'onSite',
    label: 'Required On Site ($kProcurementOnSiteLeadDays days before P6)',
    width: 130,
  ),
  (id: 'submitBy', label: 'Date to be Submitted', width: 120),
  (id: 'released', label: 'Released', width: 80),
  (id: 'releasedOn', label: 'Actual Release Date', width: 120),
  (id: 'delivery', label: 'Estimated Delivery Date', width: 120),
  (id: 'ordered', label: 'Ordered', width: 140),
  (id: 'delivered', label: 'Delivered', width: 150),
  (id: 'notes', label: 'Notes/Comments', width: 240),
];

/// How wide a column added on the job starts.
const double _kCustomWidth = 160;

/// A column's spec on [project]: built in, or added on the job.
ProcurementColumnSpec _spec(BuildingProject project, String id) =>
    kProcurementColumnSpecs.where((c) => c.id == id).firstOrNull ??
    project.procurementColumns.firstWhere(
      (c) => c.id == id,
      orElse: () => (id: id, label: id, group: ProcurementGroup.notes),
    );

/// Built-in text columns that can be made a dropdown. Added columns always
/// can.
const Set<String> _kChoosableBuiltIns = {
  'description',
  'phase',
  'p6Id',
  'p6Description',
  'review',
  'lead',
  'notes',
};

/// Whether column [id] can be given dropdown choices.
bool procurementColumnCanChoose(String id) =>
    procurementColumnIsCustom(id) || _kChoosableBuiltIns.contains(id);

/// What [e] says in text column [id].
String _cellText(ProcurementEntry e, String id) => switch (id) {
  'description' => e.description,
  'phase' => e.installPhase,
  'p6Id' => e.p6ActivityId,
  'p6Description' => e.p6ActivityDescription,
  'review' => e.reviewTime,
  'lead' => e.leadTime,
  'notes' => e.notes,
  _ => e.custom[id] ?? '',
};

/// [e] with text column [id] set to [v].
ProcurementEntry _withCellText(ProcurementEntry e, String id, String v) =>
    switch (id) {
      'description' => e.copyWith(description: v),
      'phase' => e.copyWith(installPhase: v),
      'p6Id' => e.copyWith(p6ActivityId: v),
      'p6Description' => e.copyWith(p6ActivityDescription: v),
      'review' => e.copyWith(reviewTime: v),
      'lead' => e.copyWith(leadTime: v),
      'notes' => e.copyWith(notes: v),
      _ => e.copyWith(custom: {...e.custom, id: v}),
    };

const double _kFrozen = 260;
const double _kRow = 44;
const double _kHead = 58;
const double _kGap = 3;

/// The procurement pane, as slivers for the project tab's one scroll view.
List<Widget> procurementSlivers(
  BuildContext context,
  ProjectEstimate estimate,
) {
  final provider = context.watch<AppStateProvider>();
  // The stored lines with their names read off the rooms, and every room line
  // nobody has an entry for yet - see procurement_sync.dart.
  final entries = liveProcurement(provider.project, estimate);
  final onRooms = {
    for (final l in procurementLinesOf(estimate)) '${l.roomId}|${l.key}',
  };
  // Linked to a room line that is no longer on the job.
  final orphans = {
    for (final e in entries)
      if (e.linked && !onRooms.contains('${e.roomId}|${e.lineKey}')) e.id,
  };

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
              'Every piece of equipment and hardware on the rooms is listed '
              'here once the rooms have some. Lines can be added by hand too. '
              'Each line says who buys it, when it has to be on site, and '
              'where its submittal has got to.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      )
    else
      // A whole window tall, not whatever is left under the headings: scrolled
      // to, the grid fills the screen with its sideways bar at the foot.
      SliverLayoutBuilder(
        builder: (context, constraints) {
          final height = math.max(360.0, constraints.viewportMainAxisExtent);
          // Scrolled partway, the grid hangs below the window; its sideways
          // bar is drawn at the window's base, not out of sight. Less the
          // grid's own 8 of bottom padding.
          final below = height -
              constraints.scrollOffset -
              constraints.remainingPaintExtent -
              8;
          return SliverToBoxAdapter(
            child: SizedBox(
              height: height,
              child: _LogGrid(
                entries: entries,
                orphans: orphans,
                barLift: math.max(0.0, below),
              ),
            ),
          );
        },
      ),
    // The tab adds no clearance after this pane - see project_view.dart.
    if (entries.isEmpty)
      const SliverToBoxAdapter(
        child: SizedBox(height: kFloatingButtonClearance),
      ),
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

// ---------------------------------------------------------------------------
//  COLORS
// ---------------------------------------------------------------------------

({Color fill, Color ink}) _groupColors(ThemeData theme, _Group group) {
  final dark = theme.brightness == Brightness.dark;
  final base = switch (group) {
    _Group.item => Colors.indigo,
    _Group.status => Colors.orange,
    _Group.schedule => Colors.teal,
    _Group.dates => Colors.purple,
    _Group.notes => Colors.blueGrey,
  };
  return dark
      ? (fill: base.shade700, ink: Colors.white)
      : (fill: base.shade100, ink: base.shade900);
}

({Color fill, Color ink}) _statusColors(
  ThemeData theme,
  ProcurementStatus status,
) {
  final dark = theme.brightness == Brightness.dark;
  final MaterialColor? base = switch (status) {
    ProcurementStatus.none => null,
    ProcurementStatus.submitted => Colors.orange,
    ProcurementStatus.approved => Colors.blue,
    ProcurementStatus.released => Colors.green,
  };
  if (base == null) {
    return (
      fill: theme.colorScheme.surfaceContainerHighest,
      ink: theme.colorScheme.onSurfaceVariant,
    );
  }
  return dark
      ? (fill: base.shade800, ink: Colors.white)
      : (fill: base.shade100, ink: base.shade900);
}

/// The Delivered cell's tint: all of it, some of it, or a receipt.
({Color fill, Color ink}) _deliveredColors(ThemeData theme, String text) {
  final dark = theme.brightness == Brightness.dark;
  final MaterialColor base =
      text.contains(' of ') ? Colors.orange : Colors.green;
  return (
    fill: dark ? base.shade800 : base.shade100,
    ink: dark ? Colors.white : base.shade900,
  );
}

({Color fill, Color ink}) _companyColors(ThemeData theme, String company) {
  final dark = theme.brightness == Brightness.dark;
  final c = company.toUpperCase();
  final MaterialColor base = c.startsWith('CFCI')
      ? Colors.green
      : c.startsWith('OFCI')
      ? Colors.amber
      : c.contains('OFOI') || c.startsWith('CTS')
      ? Colors.indigo
      : Colors.blueGrey;
  return dark
      ? (fill: base.shade800, ink: Colors.white)
      : (fill: base.shade100, ink: base.shade900);
}

// ---------------------------------------------------------------------------
//  THE TOOLBAR
// ---------------------------------------------------------------------------

class _Toolbar extends StatelessWidget {
  final List<ProcurementEntry> entries;
  final ProjectEstimate estimate;

  const _Toolbar({required this.entries, required this.estimate});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    int count(ProcurementStatus s) =>
        entries.where((e) => e.status == s).length;

    Widget tally(ProcurementStatus s, String label) {
      final c = _statusColors(theme, s);
      return Chip(
        visualDensity: VisualDensity.compact,
        backgroundColor: c.fill,
        side: BorderSide.none,
        label: Text(
          '${count(s)} $label',
          style: theme.textTheme.labelMedium?.copyWith(color: c.ink),
        ),
      );
    }

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
            key: const ValueKey('procurement_columns'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const _ColumnsDialog(),
            ),
            icon: const Icon(Icons.view_column_outlined, size: 18),
            label: const Text('Columns'),
          ),
          if (provider.hiddenProcurementCount > 0)
            OutlinedButton.icon(
              key: const ValueKey('procurement_restore'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const _RestoreRoomsDialog(),
              ),
              icon: const Icon(Icons.playlist_add, size: 18),
              label: const Text('Add rooms back'),
            ),
          if (entries.isNotEmpty) ...[
            OutlinedButton.icon(
              key: const ValueKey('procurement_export_xlsx'),
              onPressed: () => _exportSpreadsheet(context),
              icon: const Icon(Icons.table_view, size: 18),
              label: const Text('Spreadsheet'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('procurement_export_image'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const _ProcurementImageDialog(),
              ),
              icon: const Icon(Icons.image_outlined, size: 18),
              label: const Text('Image'),
            ),
            Text(
              '${entries.length} line${entries.length == 1 ? '' : 's'}',
              style: theme.textTheme.bodyMedium,
            ),
            tally(ProcurementStatus.none, 'no status'),
            tally(ProcurementStatus.submitted, 'submitted'),
            tally(ProcurementStatus.approved, 'approved'),
            tally(ProcurementStatus.released, 'released'),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  THE GRID
// ---------------------------------------------------------------------------

/// A row of the grid: a room's band, or one line under it.
typedef _Row = ({
  String room,
  int count,
  ProcurementEntry? entry,
  int index,
  int group,
});

class _LogGrid extends StatefulWidget {
  final List<ProcurementEntry> entries;

  /// The ids of entries whose room line has gone from the job.
  final Set<String> orphans;

  /// How far the grid runs past the window's bottom - see PinnedGrid.barLift.
  final double barLift;

  const _LogGrid({
    required this.entries,
    this.orphans = const {},
    this.barLift = 0,
  });

  @override
  State<_LogGrid> createState() => _LogGridState();
}

class _LogGridState extends State<_LogGrid> {
  double _zoom = kGridZoomNormal;
  bool _fit = false;

  /// The columns after the frozen device column, in the job's order and at
  /// the widths they have been dragged to.
  List<_Col> _cols = _kCols;

  /// Widths while an edge is being dragged, by column id. Kept here until
  /// the drag ends, so the whole app is not rebuilt on every pixel.
  final Map<String, double> _dragWidths = {};

  static const double _kMinWidth = 60;
  static const double _kMaxWidth = 700;

  /// The column being dragged by its grip, or null.
  final ValueNotifier<String?> _columnDrag = ValueNotifier(null);

  /// Room sections folded to their heading band, by room.
  final Set<String> _foldedRooms = {};

  @override
  void dispose() {
    _columnDrag.dispose();
    super.dispose();
  }

  /// A column's width before zoom: dragged, kept with the job, or its usual.
  double _baseWidth(String id, double usual) =>
      _dragWidths[id] ??
      context.read<AppStateProvider>().project.procurementColumnWidths[id] ??
      usual;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => _sheet(context, box.maxWidth),
  );

  Widget _sheet(BuildContext context, double available) {
    final theme = Theme.of(context);
    final project = context.watch<AppStateProvider>().project;
    _cols = [
      for (final spec in project.procurementColumns)
        if (spec.id != kProcurementFixedColumn)
          () {
            final c = _kCols.where((c) => c.id == spec.id).firstOrNull ??
                (id: spec.id, label: spec.label, width: _kCustomWidth);
            return (id: c.id, label: c.label, width: _baseWidth(c.id, c.width));
          }(),
    ];
    final frozenBase = _baseWidth('device', _kFrozen);
    final natural =
        gridMetric(context, frozenBase) +
        _cols.fold<double>(0, (s, c) => s + gridMetric(context, c.width));
    final zoom = _fit
        ? gridFitZoom(natural: natural, available: available - 32)
        : _zoom;
    final zoomed = zoomedTextTheme(theme, zoom);
    double w(double base) => gridMetric(context, base) * zoom;

    final groups = procurementByRoom(widget.entries);
    final rows = <_Row>[
      for (final (gi, g) in groups.indexed) ...[
        // A band's index is its room's place, so bands can alternate.
        (room: g.room, count: g.entries.length, entry: null, index: gi,
            group: gi),
        // A folded room is its band alone.
        if (!_foldedRooms.contains(g.room))
          for (final (i, e) in g.entries.indexed)
            (room: g.room, count: 0, entry: e, index: i, group: gi),
      ],
    ];
    final allFolded =
        groups.isNotEmpty && groups.every((g) => _foldedRooms.contains(g.room));
    final rowH = w(_kRow);
    final bodyWidth = _cols.fold<double>(0, (s, c) => s + w(c.width));

    return Padding(
      // The grid runs to the window's bottom edge, so its sideways bar is
      // always there; the space for the floating Screenshot and Export
      // buttons is after its last row instead - see trailingSpace.
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Press a line to edit it. Press a status or a date to '
                  'change just that. Drag a heading by its grip to move the '
                  'column, or press it to rename, recolor or delete it. Shift '
                  'and the mouse wheel scroll sideways.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton.icon(
                key: const ValueKey('procurement_fold_all'),
                icon: Icon(
                  allFolded ? Icons.unfold_more : Icons.unfold_less,
                  size: 18,
                ),
                label: Text(allFolded ? 'Expand all' : 'Collapse all'),
                onPressed: () => setState(() {
                  if (allFolded) {
                    _foldedRooms.clear();
                  } else {
                    _foldedRooms.addAll([for (final g in groups) g.room]);
                  }
                }),
              ),
              const SizedBox(width: 8),
              GridZoomControls(
                keyPrefix: 'procurement',
                zoom: zoom,
                fitted: _fit,
                onChanged: (z) => setState(() {
                  _zoom = z;
                  _fit = false;
                }),
                onFit: () => setState(() {
                  if (_fit) _zoom = zoom;
                  _fit = !_fit;
                }),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: LayoutBuilder(
              builder: (context, frame) => PinnedGrid(
            key: const ValueKey('procurement_grid'),
            dragging: _columnDrag,
            maxHeight: frame.maxHeight,
            fillHeight: true,
            trailingSpace: kFloatingButtonClearance,
            barLift: widget.barLift,
            frozenWidth: w(frozenBase),
            headerHeight: w(_kHead),
            bodyWidth: bodyWidth,
            bodyHeight: rowH * rows.length,
            corner: _headBox(
              zoomed,
              'device',
              'Device',
              w(frozenBase),
              w,
              base: frozenBase,
            ),
            header: Row(
              children: [
                for (final c in _cols)
                  _headBox(
                    zoomed,
                    c.id,
                    c.label,
                    w(c.width),
                    w,
                    movable: true,
                    base: c.width,
                  ),
              ],
            ),
            rowCount: rows.length,
            rowExtent: rowH,
            frozenRowBuilder: (context, i) =>
                _frozenRow(context, zoomed, rows[i], w),
            bodyRowBuilder: (context, i) =>
                _bodyRow(context, zoomed, rows[i], w),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A header: a colored box, every one the same height.
  Widget _headBox(
    TextTheme zoomed,
    String id,
    String label,
    double width,
    double Function(double) w, {
    bool movable = false,
    required double base,
  }) => SizedBox(
    width: width,
    child: Stack(
      children: [
        _headTarget(zoomed, id, label, width, w, movable: movable),
        // THE EDGE THAT RESIZES. Dragged, the column follows; let go, the
        // width is kept with the job. Double-pressed, it goes back.
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          width: 8,
          // Out of the way while a column is being moved, so a drop on the
          // edge still lands.
          child: ValueListenableBuilder<String?>(
            valueListenable: _columnDrag,
            builder: (context, moving, child) =>
                IgnorePointer(ignoring: moving != null, child: child),
            child: MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              key: ValueKey('procurement_resize_$id'),
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (d) => setState(
                () => _dragWidths[id] =
                    ((_dragWidths[id] ?? base) + d.delta.dx / w(1)).clamp(
                      _kMinWidth,
                      _kMaxWidth,
                    ),
              ),
              onHorizontalDragEnd: (_) {
                final dragged = _dragWidths[id];
                if (dragged == null) return;
                context.read<AppStateProvider>().setProcurementColumnWidth(
                  id,
                  dragged.roundToDouble(),
                );
                setState(() => _dragWidths.remove(id));
              },
              onDoubleTap: () => context
                  .read<AppStateProvider>()
                  .setProcurementColumnWidth(id, null),
            ),
          ),
          ),
        ),
      ],
    ),
  );

  Widget _headTarget(
    TextTheme zoomed,
    String id,
    String label,
    double width,
    double Function(double) w, {
    bool movable = false,
  }) {
    final box = _colorBox(zoomed, id, label, width, w, movable: movable);
    if (!movable) return box;
    // The half it is dropped on says which side it lands - see
    // column_drag.dart.
    return ColumnDropTarget(
      id: id,
      dragging: _columnDrag,
      onDrop: (dragged, after) => context
          .read<AppStateProvider>()
          .moveProcurementColumn(dragged, id, after: after),
      child: box,
    );
  }

  Widget _colorBox(
    TextTheme zoomed,
    String id,
    String label,
    double width,
    double Function(double) w, {
    bool movable = false,
  }) {
    final provider = context.watch<AppStateProvider>();
    final spec = _spec(provider.project, id);
    final fill = procurementColumnColor(
      spec,
      provider.project.procurementColors,
    );
    final c = (fill: Color(fill), ink: Color(procurementInkFor(fill)));
    // The heading typed on this job, when there is one.
    final typed = provider.project.procurementColumnLabels[id]?.trim() ?? '';
    if (typed.isNotEmpty) label = typed;
    return SizedBox(
      width: width,
      height: w(_kHead),
      child: Padding(
        padding: EdgeInsets.all(_kGap),
        child: Tooltip(
          message: 'Press to rename, recolor or delete this column',
          waitDuration: const Duration(milliseconds: 600),
          child: InkWell(
          key: ValueKey('procurement_head_$id'),
          borderRadius: BorderRadius.circular(6),
          onTap: () => showProcurementColumnDialog(context, spec),
          child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.fill,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Stack(
            children: [
              Center(
                child: Padding(
                  // Room for the grip on the left only.
                  padding: EdgeInsets.only(
                    left: movable ? w(16) : w(6),
                    right: w(4),
                  ),
                  child: WholeWordText(
                    label,
                    maxLines: 3,
                    style: zoomed.labelSmall?.copyWith(
                      color: c.ink,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              if (movable)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: ColumnDragGrip(
                    key: ValueKey('procurement_grip_$id'),
                    id: id,
                    label: label,
                    width: width,
                    dragging: _columnDrag,
                    fill: c.fill,
                    ink: c.ink,
                    child: Tooltip(
                      message: 'Drag to move this column',
                      child: Icon(
                        Icons.drag_indicator,
                        size: w(16),
                        color: c.ink.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        ),
        ),
      ),
    );
  }

  // Rooms alternate between the accent and secondary colors, band and
  // lines alike, so each room reads as its own block.
  bool _secondaryRoom(_Row row) => row.group.isOdd;

  Color _bandInk(ThemeData theme, _Row row) => _secondaryRoom(row)
      ? theme.colorScheme.onSecondaryContainer
      : theme.colorScheme.onPrimaryContainer;

  Color? _rowFill(ThemeData theme, _Row row) {
    final scheme = theme.colorScheme;
    final secondary = _secondaryRoom(row);
    if (row.entry == null) {
      return secondary ? scheme.secondaryContainer : scheme.primaryContainer;
    }
    // A faint wash of the room's color, a touch deeper on every other line.
    final hue = secondary ? scheme.secondary : scheme.primary;
    return Color.alphaBlend(
      hue.withValues(alpha: row.index.isOdd ? 0.12 : 0.05),
      scheme.surface,
    );
  }

  Border _rule(ThemeData theme) => Border(
    bottom: BorderSide(color: theme.colorScheme.outlineVariant, width: 0.5),
  );

  /// Takes every line for [room] off the log, after asking.
  Future<void> _removeSection(String room) async {
    final lines = [
      for (final e in widget.entries)
        if (e.room.trim() == room) e,
    ];
    if (lines.isEmpty) return;
    final name = room.isEmpty ? 'this section' : room;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $name from the log?'),
        content: Text(
          '${lines.length} line${lines.length == 1 ? '' : 's'} come off the '
          'procurement log, with their statuses and dates. The rooms and '
          'their estimates are not changed. Lines that follow a room can be '
          'put back afterwards from the toolbar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            key: const ValueKey('procurement_remove_section_go'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    context.read<AppStateProvider>().removeProcurementEntries(lines);
  }

  Future<void> _edit(ProcurementEntry entry) async {
    final provider = context.read<AppStateProvider>();
    final edited = await showProcurementEditor(
      context,
      entry,
      recipient: _usualRecipient(provider.project.procurement),
    );
    if (edited != null) provider.updateProcurementEntry(edited);
  }

  Widget _frozenRow(
    BuildContext context,
    TextTheme zoomed,
    _Row row,
    double Function(double) w,
  ) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final entry = row.entry;
    if (entry == null) {
      return Container(
        decoration: BoxDecoration(
          color: _rowFill(theme, row),
          border: _rule(theme),
        ),
        padding: EdgeInsets.only(left: w(2)),
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            // The room folds to this band, and opens again.
            IconButton(
              key: ValueKey('procurement_fold_${row.room}'),
              tooltip: _foldedRooms.contains(row.room) ? 'Expand' : 'Collapse',
              visualDensity: VisualDensity.compact,
              iconSize: w(18),
              color: _bandInk(theme, row),
              icon: Icon(
                _foldedRooms.contains(row.room)
                    ? Icons.chevron_right
                    : Icons.expand_more,
              ),
              onPressed: () => setState(() {
                if (!_foldedRooms.remove(row.room)) _foldedRooms.add(row.room);
              }),
            ),
            Expanded(
              child: Text(
                '${row.room.isEmpty ? 'No room' : row.room}  ·  ${row.count} '
                'line${row.count == 1 ? '' : 's'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: zoomed.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: _bandInk(theme, row),
                ),
              ),
            ),
            IconButton(
              key: ValueKey('procurement_remove_section_${row.room}'),
              tooltip: 'Remove this whole section',
              visualDensity: VisualDensity.compact,
              iconSize: w(18),
              color: _bandInk(theme, row),
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => _removeSection(row.room),
            ),
          ],
        ),
      );
    }
    return Material(
      color: _rowFill(theme, row) ?? Colors.transparent,
      child: InkWell(
        key: ValueKey('procurement_row_${entry.id}'),
        onTap: () => _edit(entry),
        child: Container(
          decoration: BoxDecoration(border: _rule(theme)),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Remove this line',
                visualDensity: VisualDensity.compact,
                iconSize: w(18),
                icon: const Icon(Icons.delete_outline),
                onPressed: () => provider.removeProcurementEntry(entry),
              ),
              if (widget.orphans.contains(entry.id))
                Padding(
                  padding: EdgeInsets.only(right: w(4)),
                  child: Tooltip(
                    message: 'No longer on the room\'s estimate. The name is '
                        'the last one it had.',
                    child: Icon(
                      Icons.warning_amber_rounded,
                      size: w(16),
                      color: Colors.orange.shade700,
                    ),
                  ),
                ),
              Expanded(
                child: Tooltip(
                  message: entry.device,
                  waitDuration: const Duration(milliseconds: 600),
                  child: Text(
                    entry.device.isEmpty ? '(no device)' : entry.device,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: zoomed.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              SizedBox(width: w(6)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bodyRow(
    BuildContext context,
    TextTheme zoomed,
    _Row row,
    double Function(double) w,
  ) {
    final theme = Theme.of(context);
    final entry = row.entry;
    if (entry == null) {
      return Container(
        decoration: BoxDecoration(
          color: _rowFill(theme, row),
          border: _rule(theme),
        ),
      );
    }
    final provider = context.read<AppStateProvider>();

    Widget text(String value, {int lines = 2}) => Tooltip(
      message: value,
      waitDuration: const Duration(milliseconds: 600),
      child: Text(
        value,
        maxLines: lines,
        overflow: TextOverflow.ellipsis,
        style: zoomed.bodySmall,
      ),
    );

    Widget pill(String value, ({Color fill, Color ink}) c) => value.isEmpty
        ? const SizedBox.shrink()
        : Container(
            padding: EdgeInsets.symmetric(horizontal: w(8), vertical: w(3)),
            decoration: BoxDecoration(
              color: c.fill,
              borderRadius: BorderRadius.circular(w(12)),
            ),
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: zoomed.labelSmall?.copyWith(
                color: c.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          );

    Widget date(
      String key,
      String label,
      DateTime? value,
      ProcurementEntry Function(DateTime?) apply,
    ) => _DateCell(
      key: ValueKey('procurement_${key}_${entry.id}'),
      label: label,
      value: value,
      style: zoomed.bodySmall,
      onChanged: (d) => provider.updateProcurementEntry(apply(d)),
    );

    final phaseColors = _groupColors(theme, _Group.status);
    final cells = <Widget>[
      _CompanyCell(entry: entry, style: zoomed.labelSmall, w: w),
      text(entry.room, lines: 1),
      text(entry.manufacturer, lines: 1),
      text(entry.model, lines: 1),
      text(entry.partNumber, lines: 1),
      text(entry.description),
      _StatusCell(entry: entry, style: zoomed.labelSmall, w: w),
      pill(entry.installPhase, (
        fill: phaseColors.fill.withValues(alpha: 0.5),
        ink: phaseColors.ink,
      )),
      text(entry.p6ActivityId, lines: 1),
      text(entry.p6ActivityDescription),
      text(entry.reviewTime, lines: 1),
      text(entry.leadTime),
      date('p6', 'P6 start date', entry.p6Start,
          (d) => entry.copyWith(p6Start: d, clearP6Start: d == null)),
      text(
        entry.requiredOnSite == null
            ? ''
            : formatScheduleDate(entry.requiredOnSite!),
        lines: 1,
      ),
      date('submit', 'Date to be submitted', entry.submitBy,
          (d) => entry.copyWith(submitBy: d, clearSubmitBy: d == null)),
      entry.released
          ? Icon(Icons.check_circle, color: Colors.green.shade600, size: w(18))
          : const SizedBox.shrink(),
      date('released', 'Actual release date', entry.releasedOn,
          (d) => entry.copyWith(releasedOn: d, clearReleasedOn: d == null)),
      date('delivery', 'Estimated delivery', entry.estimatedDelivery,
          (d) => entry.copyWith(
                estimatedDelivery: d,
                clearEstimatedDelivery: d == null,
              )),
      // Read off the job's orders and delivery log - see procurement_sync.
      Tooltip(
        message: 'From the order recorded on the Equipment or Deliveries page',
        waitDuration: const Duration(milliseconds: 600),
        child: text(entry.ordered),
      ),
      Tooltip(
        message: 'From the delivery log',
        waitDuration: const Duration(milliseconds: 600),
        // Green when it has all arrived, orange while some is still to come.
        child: entry.delivered.isEmpty
            ? text('')
            : pill(entry.delivered, _deliveredColors(theme, entry.delivered)),
      ),
      text(entry.notes),
    ];

    final byId = <String, Widget>{
      for (final (i, col) in _kCols.indexed) col.id: cells[i],
    };
    // A column added on the job: pressed, its value is typed right there.
    Widget custom(String id) {
      final value = entry.custom[id] ?? '';
      return InkWell(
        key: ValueKey('procurement_custom_${id}_${entry.id}'),
        borderRadius: BorderRadius.circular(6),
        onTap: () async {
          final label = procurementColumnLabel(
            _spec(provider.project, id),
            provider.project.procurementColumnLabels,
          );
          final typed = await _askText(context, label, value);
          if (typed == null) return;
          provider.updateProcurementEntry(
            entry.copyWith(custom: {...entry.custom, id: typed}),
          );
        },
        child: SizedBox.expand(
          child: Align(alignment: Alignment.centerLeft, child: text(value)),
        ),
      );
    }

    // A column with choices: pressed, it drops down the list right there.
    Widget choice(String id, List<String> choices) {
      final value = _cellText(entry, id);
      return Builder(
        builder: (cellContext) => InkWell(
          key: ValueKey('procurement_choice_${id}_${entry.id}'),
          borderRadius: BorderRadius.circular(6),
          onTap: () async {
            final box = cellContext.findRenderObject() as RenderBox;
            final overlay =
                Overlay.of(cellContext).context.findRenderObject() as RenderBox;
            final at = box.localToGlobal(
              Offset(0, box.size.height),
              ancestor: overlay,
            );
            final picked = await showMenu<String>(
              context: cellContext,
              position: RelativeRect.fromLTRB(
                at.dx,
                at.dy,
                overlay.size.width - at.dx,
                0,
              ),
              items: [
                for (final c in choices)
                  CheckedPopupMenuItem(
                    value: c,
                    checked: c == value,
                    child: Text(c),
                  ),
                if (value.isNotEmpty) ...[
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: '', child: Text('Clear')),
                ],
              ],
            );
            if (picked == null || picked == value) return;
            provider.updateProcurementEntry(_withCellText(entry, id, picked));
          },
          child: SizedBox.expand(
            child: Row(
              children: [
                Expanded(child: text(value)),
                Icon(
                  Icons.arrow_drop_down,
                  size: w(18),
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget cellFor(String id) {
      final choices = provider.project.procurementColumnChoices[id];
      if (choices != null &&
          choices.isNotEmpty &&
          procurementColumnCanChoose(id)) {
        return choice(id, choices);
      }
      return byId[id] ?? custom(id);
    }

    return Material(
      color: _rowFill(theme, row) ?? Colors.transparent,
      child: InkWell(
        onTap: () => _edit(entry),
        child: Container(
          decoration: BoxDecoration(border: _rule(theme)),
          child: Row(
            children: [
              for (final col in _cols)
                Container(
                  width: w(col.width),
                  padding: EdgeInsets.symmetric(horizontal: w(8)),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.5,
                        ),
                      ),
                    ),
                  ),
                  child: cellFor(col.id),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Who buys it, as a colored pill with a dropdown of the companies.
class _CompanyCell extends StatelessWidget {
  final ProcurementEntry entry;
  final TextStyle? style;
  final double Function(double) w;

  const _CompanyCell({
    required this.entry,
    required this.style,
    required this.w,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final now = entry.company.trim();
    // A typed company not on the list stays offered.
    final options = [
      ...kProcurementCompanies,
      if (now.isNotEmpty && !kProcurementCompanies.contains(now)) now,
    ];
    final c = now.isEmpty
        ? (
            fill: theme.colorScheme.surfaceContainerHighest,
            ink: theme.colorScheme.onSurfaceVariant,
          )
        : _companyColors(theme, now);
    return PopupMenuButton<String>(
      key: ValueKey('procurement_company_${entry.id}'),
      tooltip: 'Set who buys it',
      onSelected: (v) =>
          provider.updateProcurementEntry(entry.copyWith(company: v)),
      itemBuilder: (ctx) => [
        for (final o in options)
          CheckedPopupMenuItem(value: o, checked: o == now, child: Text(o)),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: '',
          checked: now.isEmpty,
          child: const Text('None'),
        ),
      ],
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: w(8), vertical: w(3)),
        decoration: BoxDecoration(
          color: c.fill,
          borderRadius: BorderRadius.circular(w(12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                now.isEmpty ? 'Set company' : now,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style?.copyWith(
                  color: c.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: w(16), color: c.ink),
          ],
        ),
      ),
    );
  }
}

/// The status as a colored pill, set in one press; the recipient carries over.
class _StatusCell extends StatelessWidget {
  final ProcurementEntry entry;
  final TextStyle? style;
  final double Function(double) w;

  const _StatusCell({
    required this.entry,
    required this.style,
    required this.w,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final to = entry.statusTo.trim().isNotEmpty
        ? entry.statusTo.trim()
        : _usualRecipient(provider.project.procurement);
    final c = _statusColors(theme, entry.status);
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
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: w(8), vertical: w(3)),
        decoration: BoxDecoration(
          color: c.fill,
          borderRadius: BorderRadius.circular(w(12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                entry.statusText.isEmpty ? 'Set status' : entry.statusText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style?.copyWith(
                  color: c.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: w(16), color: c.ink),
          ],
        ),
      ),
    );
  }
}

/// A date in the grid. Pressed, it can be typed or picked off a calendar.
class _DateCell extends StatelessWidget {
  final String label;
  final DateTime? value;
  final TextStyle? style;
  final ValueChanged<DateTime?> onChanged;

  const _DateCell({
    super.key,
    required this.label,
    required this.value,
    required this.style,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () async {
        final picked = await showProcurementDateDialog(context, label, value);
        if (picked != null) onChanged(picked.date);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          children: [
            Icon(
              Icons.calendar_today_outlined,
              size: (style?.fontSize ?? 12) + 2,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                value == null ? '-' : formatScheduleDate(value!),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks for one date: typed, or picked off a calendar. Null when canceled;
/// a record with a null date when cleared.
Future<({DateTime? date})?> showProcurementDateDialog(
  BuildContext context,
  String label,
  DateTime? initial,
) {
  var value = initial;
  return showDialog<({DateTime? date})>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(label),
        content: SizedBox(
          width: 320,
          child: ProcurementDateField(
            label: label,
            value: value,
            autofocus: true,
            onChanged: (d) => setLocal(() => value = d),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop((date: null)),
            child: const Text('Clear'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('procurement_date_save'),
            onPressed: () => Navigator.of(ctx).pop((date: value)),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

/// A date that can be typed or picked off the calendar beside it.
class ProcurementDateField extends StatefulWidget {
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool autofocus;

  const ProcurementDateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.autofocus = false,
  });

  @override
  State<ProcurementDateField> createState() => _ProcurementDateFieldState();
}

class _ProcurementDateFieldState extends State<ProcurementDateField> {
  late final TextEditingController _text = TextEditingController(
    text: widget.value == null ? '' : formatScheduleDate(widget.value!),
  );
  bool _bad = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _typed(String v) {
    final parsed = parseTypedDate(v);
    setState(() => _bad = v.trim().isNotEmpty && parsed == null);
    if (!_bad) widget.onChanged(parsed);
  }

  Future<void> _calendar() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.value ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2040),
      helpText: widget.label,
    );
    if (picked == null) return;
    _text.text = formatScheduleDate(picked);
    setState(() => _bad = false);
    widget.onChanged(picked);
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _text,
    autofocus: widget.autofocus,
    onChanged: _typed,
    decoration: InputDecoration(
      labelText: widget.label,
      hintText: '3/10/2027 or 10 Mar 2027',
      isDense: true,
      errorText: _bad ? 'Not a date' : null,
      suffixIcon: IconButton(
        tooltip: 'Pick from the calendar',
        icon: const Icon(Icons.calendar_month_outlined),
        onPressed: _calendar,
      ),
    ),
  );
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
  final manufacturer = TextEditingController(text: entry.manufacturer);
  final model = TextEditingController(text: entry.model);
  final partNumber = TextEditingController(text: entry.partNumber);
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
  // Fields only for the columns this job shows; what a deleted one held is
  // kept on the line as it was.
  final project = context.read<AppStateProvider>().project;
  final columns = project.procurementColumns;
  final shownIds = {for (final c in columns) c.id};
  bool shows(String id) => shownIds.contains(id);
  // A dropdown column's choices, else [fallback].
  List<String> picks(String id, [List<String> fallback = const []]) {
    final c = project.procurementColumnChoices[id];
    return c == null || c.isEmpty ? fallback : c;
  }
  final custom = {
    for (final c in columns)
      if (procurementColumnIsCustom(c.id))
        c.id: (
          label: procurementColumnLabel(c, project.procurementColumnLabels),
          text: TextEditingController(text: entry.custom[c.id] ?? ''),
        ),
  };
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
          width: 260,
          child: ProcurementDateField(
            label: label,
            value: value,
            onChanged: (d) => setLocal(() => set(d)),
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
                  if (shows('company'))
                    field(company, 'Company', presets: kProcurementCompanies),
                  if (entry.linked)
                    SizedBox(
                      width: 536,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Room and device',
                          helperText: 'From the room. Rename or swap it on '
                              'the room or the Equipment page and it changes '
                              'here.',
                          isDense: true,
                        ),
                        child: Text('${entry.room}  -  ${entry.device}'),
                      ),
                    )
                  else ...[
                    field(room, 'Room #'),
                    field(device, 'Device', width: 536),
                    if (shows('manufacturer'))
                      field(manufacturer, 'Manufacturer'),
                    if (shows('model')) field(model, 'Model'),
                    if (shows('partNumber'))
                      field(partNumber, 'Part number'),
                  ],
                  if (shows('description'))
                    field(
                      description,
                      'Equipment description',
                      width: 536,
                      presets: picks('description'),
                    ),
                  if (shows('status') || shows('released'))
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
                  if (shows('status'))
                    field(statusTo, 'Who it goes to (e.g. DPR)'),
                  if (shows('phase'))
                    field(
                      phase,
                      'Install before drywall or after paint?',
                      presets: picks('phase', kProcurementInstallPhases),
                    ),
                  if (shows('lead'))
                    field(lead, 'Lead time (weeks)', presets: picks('lead')),
                  if (shows('p6Id'))
                    field(p6Id, 'P6 activity ID', presets: picks('p6Id')),
                  if (shows('review'))
                    field(review, 'Review time', presets: picks('review')),
                  if (shows('p6Description'))
                    field(
                      p6Desc,
                      'P6 activity description',
                      width: 536,
                      presets: picks('p6Description'),
                    ),
                  if (shows('p6Start') || shows('onSite'))
                    date('P6 start date', p6Start, (v) => p6Start = v),
                  if (shows('onSite'))
                  SizedBox(
                    width: 260,
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
                  if (shows('submitBy'))
                    date('Date to be submitted', submitBy,
                        (v) => submitBy = v),
                  if (shows('releasedOn'))
                    date('Actual release date', releasedOn,
                        (v) => releasedOn = v),
                  if (shows('delivery'))
                    date('Estimated delivery', delivery, (v) => delivery = v),
                  if (shows('notes'))
                    field(
                      notes,
                      'Notes/comments',
                      width: 536,
                      maxLines: 3,
                      presets: picks('notes'),
                    ),
                  for (final c in custom.entries)
                    KeyedSubtree(
                      key: ValueKey('procurement_editor_${c.key}'),
                      child: field(
                        c.value.text,
                        c.value.label,
                        presets: picks(c.key),
                      ),
                    ),
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
                  manufacturer: manufacturer.text.trim(),
                  model: model.text.trim(),
                  partNumber: partNumber.text.trim(),
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
                  roomId: entry.roomId,
                  lineKey: entry.lineKey,
                  excluded: entry.excluded,
                  custom: {
                    ...entry.custom,
                    for (final c in custom.entries) c.key: c.value.text.text,
                  },
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
      buildXlsx([
        procurementLogSheet(
          project.name,
          liveProcurement(project, provider.priceProject()),
          colors: project.procurementColors,
          labels: project.procurementColumnLabels,
          columns: project.procurementColumns,
          widths: project.procurementColumnWidths,
        ),
      ]),
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

// ---------------------------------------------------------------------------
//  COLUMN COLORS
// ---------------------------------------------------------------------------

/// Renames one column and picks its heading color, for this job. Both are
/// used on the page, in the picture and in the spreadsheet.
Future<void> showProcurementColumnDialog(
  BuildContext context,
  ProcurementColumnSpec column,
) {
  final provider = context.read<AppStateProvider>();
  final title = TextEditingController(
    text: procurementColumnLabel(
      column,
      provider.project.procurementColumnLabels,
    ),
  );
  final startChoices =
      provider.project.procurementColumnChoices[column.id] ?? const <String>[];
  final choices = TextEditingController(text: startChoices.join('\n'));
  var dropdown = startChoices.isNotEmpty;
  return showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final chosen = provider.project.procurementColors[column.id];
        final shown = Color(
          procurementColumnColor(column, provider.project.procurementColors),
        );
        void set(int? argb) =>
            setLocal(() => provider.setProcurementColumnColor(column.id, argb));
        final swatches = <Color>[
          for (final g in ProcurementGroup.values) Color(g.color),
          ...kNameTintWheel,
        ];
        return AlertDialog(
          key: const ValueKey('procurement_color_dialog'),
          title: const Text('Column heading'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const ValueKey('procurement_column_title'),
                  controller: title,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Title',
                    helperText: 'Blank goes back to "${column.label}"',
                    isDense: true,
                    suffixIcon: IconButton(
                      tooltip: 'Back to the usual title',
                      icon: const Icon(Icons.restart_alt, size: 18),
                      onPressed: () => setLocal(() {
                        title.text = column.label;
                        provider.setProcurementColumnLabel(column.id, '');
                      }),
                    ),
                  ),
                  // The usual title typed back is the usual title.
                  onChanged: (v) => provider.setProcurementColumnLabel(
                    column.id,
                    v.trim() == column.label ? '' : v,
                  ),
                ),
                if (procurementColumnCanChoose(column.id)) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    key: const ValueKey('procurement_column_dropdown'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Dropdown'),
                    subtitle: const Text(
                      'Cells pick from a list instead of being typed',
                    ),
                    value: dropdown,
                    onChanged: (v) => setLocal(() {
                      dropdown = v;
                      provider.setProcurementColumnChoices(
                        column.id,
                        v ? choices.text.split('\n') : const [],
                      );
                    }),
                  ),
                  if (dropdown)
                    TextField(
                      key: const ValueKey('procurement_column_choices'),
                      controller: choices,
                      minLines: 3,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: 'Choices, one per line',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => provider.setProcurementColumnChoices(
                        column.id,
                        v.split('\n'),
                      ),
                    ),
                ],
                const SizedBox(height: 16),
                Text(
                  'The title and its color are used on the page, in the '
                  'picture and in the spreadsheet.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in swatches)
                      ColorSwatchButton(
                        key: ValueKey(
                          'procurement_color_'
                          '${(c.toARGB32() & 0xFFFFFF).toRadixString(16)}',
                        ),
                        color: c,
                        selected: shown.toARGB32() == c.toARGB32(),
                        onTap: () => set(c.toARGB32()),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.colorize, size: 16),
                      label: const Text('Any other color'),
                      onPressed: () async {
                        final picked = await showColorWheelDialog(
                          ctx,
                          initial: shown,
                          title: 'Color for this column',
                        );
                        if (picked != null) set(picked.toARGB32());
                      },
                    ),
                    TextButton.icon(
                      key: const ValueKey('procurement_color_default'),
                      icon: const Icon(Icons.restart_alt, size: 16),
                      label: const Text('Default'),
                      onPressed: chosen == null ? null : () => set(null),
                    ),
                  ],
                ),
              ],
            ),
            ),
          ),
          actions: [
            if (column.id != kProcurementFixedColumn)
              TextButton.icon(
                key: const ValueKey('procurement_column_delete'),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(ctx).colorScheme.error,
                ),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Delete column'),
                onPressed: () async {
                  final go = await _confirmColumnDelete(
                    ctx,
                    procurementColumnLabel(
                      column,
                      provider.project.procurementColumnLabels,
                    ),
                    added: procurementColumnIsCustom(column.id),
                  );
                  if (go != true || !ctx.mounted) return;
                  provider.deleteProcurementColumn(column.id);
                  Navigator.of(ctx).pop();
                },
              ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Done'),
            ),
          ],
        );
      },
    ),
  );
}

/// Asks before a column goes. An added one takes what the lines said in it.
Future<bool?> _confirmColumnDelete(
  BuildContext context,
  String label, {
  required bool added,
}) => showDialog<bool>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: Text('Delete "$label"?'),
    content: Text(
      added
          ? 'The column comes off the log, along with what every line says '
                'in it.'
          : 'The column comes off the log, the picture and the spreadsheet. '
                'What the lines say in it is kept, and it can be put back '
                'from Columns.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(ctx).pop(false),
        child: const Text('Keep it'),
      ),
      FilledButton(
        key: const ValueKey('procurement_column_delete_go'),
        onPressed: () => Navigator.of(ctx).pop(true),
        child: const Text('Delete'),
      ),
    ],
  ),
);

/// Asks for one line of text. Null when canceled.
Future<String?> _askText(BuildContext context, String label, String initial) {
  final text = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(label),
      content: SizedBox(
        width: 360,
        child: TextField(
          key: const ValueKey('procurement_text_field'),
          controller: text,
          autofocus: true,
          decoration: InputDecoration(labelText: label, isDense: true),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('procurement_text_save'),
          onPressed: () => Navigator.of(ctx).pop(text.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
//  COLUMNS AND ROOMS
// ---------------------------------------------------------------------------

/// Every column on the log: built-in ones ticked on or off, added ones
/// deleted, new ones added, or all of them deleted to start again.
class _ColumnsDialog extends StatefulWidget {
  const _ColumnsDialog();

  @override
  State<_ColumnsDialog> createState() => _ColumnsDialogState();
}

class _ColumnsDialogState extends State<_ColumnsDialog> {
  final _name = TextEditingController();
  final _choices = TextEditingController();

  /// The new column is a dropdown of [_choices].
  bool _dropdown = false;

  @override
  void dispose() {
    _name.dispose();
    _choices.dispose();
    super.dispose();
  }

  void _add(AppStateProvider provider) {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final id = provider.addProcurementColumn(name);
    if (_dropdown) {
      provider.setProcurementColumnChoices(id, _choices.text.split('\n'));
    }
    _name.clear();
    _choices.clear();
    setState(() => _dropdown = false);
  }

  Future<void> _deleteAll(AppStateProvider provider) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete every column?'),
        content: const Text(
          'Every column but Device comes off the log, so it can be built up '
          'again from scratch. Added columns go with what the lines say in '
          'them; built-in ones can be ticked back on here. The lines stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep them'),
          ),
          FilledButton(
            key: const ValueKey('procurement_columns_delete_all_go'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (go == true) provider.deleteAllProcurementColumns();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final project = provider.project;
    final theme = Theme.of(context);
    final hidden = project.procurementHiddenColumns.toSet();
    final labels = project.procurementColumnLabels;
    return AlertDialog(
      key: const ValueKey('procurement_columns_dialog'),
      title: const Text('Columns'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Built in', style: theme.textTheme.titleSmall),
              for (final c in kProcurementColumnSpecs)
                CheckboxListTile(
                  key: ValueKey('procurement_column_shown_${c.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: c.id == kProcurementFixedColumn ||
                      !hidden.contains(c.id),
                  title: Text(procurementColumnLabel(c, labels)),
                  subtitle: c.id == kProcurementFixedColumn
                      ? const Text('Always on: it names the line')
                      : null,
                  onChanged: c.id == kProcurementFixedColumn
                      ? null
                      : (v) => provider.setProcurementColumnShown(
                          c.id,
                          v ?? false,
                        ),
                ),
              const SizedBox(height: 12),
              Text('Added on this job', style: theme.textTheme.titleSmall),
              if (project.procurementCustomColumns.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    'None yet.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              for (final c in project.procurementCustomColumns)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    procurementColumnLabel(
                      (id: c.id, label: c.label, group: ProcurementGroup.notes),
                      labels,
                    ),
                  ),
                  trailing: IconButton(
                    key: ValueKey('procurement_column_remove_${c.id}'),
                    tooltip: 'Delete this column',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final go = await _confirmColumnDelete(
                        context,
                        c.label,
                        added: true,
                      );
                      if (go == true) provider.deleteProcurementColumn(c.id);
                    },
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('procurement_column_new'),
                      controller: _name,
                      decoration: const InputDecoration(
                        labelText: 'New column',
                        hintText: 'e.g. Vendor quote #',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _add(provider),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    key: const ValueKey('procurement_column_add'),
                    onPressed: () => _add(provider),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add'),
                  ),
                ],
              ),
              CheckboxListTile(
                key: const ValueKey('procurement_column_new_dropdown'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Dropdown: cells pick from a list'),
                value: _dropdown,
                onChanged: (v) => setState(() => _dropdown = v ?? false),
              ),
              if (_dropdown)
                TextField(
                  key: const ValueKey('procurement_column_new_choices'),
                  controller: _choices,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Choices, one per line',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                'Press a column heading on the log to make an existing column '
                'a dropdown or change its choices.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          key: const ValueKey('procurement_columns_delete_all'),
          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
          icon: const Icon(Icons.delete_sweep_outlined, size: 18),
          label: const Text('Delete all'),
          onPressed: () => _deleteAll(provider),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// The rooms with lines taken off the log, ticked to put back.
class _RestoreRoomsDialog extends StatefulWidget {
  const _RestoreRoomsDialog();

  @override
  State<_RestoreRoomsDialog> createState() => _RestoreRoomsDialogState();
}

class _RestoreRoomsDialogState extends State<_RestoreRoomsDialog> {
  final Set<String> _picked = {};

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final rooms = provider.hiddenProcurementRooms;
    final all = rooms.isNotEmpty && _picked.length == rooms.length;
    return AlertDialog(
      key: const ValueKey('procurement_restore_dialog'),
      title: const Text('Add rooms back to the log'),
      content: SizedBox(
        width: 400,
        child: rooms.isEmpty
            ? const Text('No room has lines taken off the log.')
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CheckboxListTile(
                      key: const ValueKey('procurement_restore_all'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: all,
                      title: const Text('All rooms'),
                      onChanged: (v) => setState(() {
                        _picked.clear();
                        if (v == true) _picked.addAll(rooms.map((r) => r.key));
                      }),
                    ),
                    const Divider(height: 8),
                    for (final r in rooms)
                      CheckboxListTile(
                        key: ValueKey('procurement_restore_${r.key}'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _picked.contains(r.key),
                        title: Text(r.room.isEmpty ? 'No room' : r.room),
                        subtitle: Text(
                          '${r.lines} line${r.lines == 1 ? '' : 's'}',
                        ),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _picked.add(r.key);
                          } else {
                            _picked.remove(r.key);
                          }
                        }),
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
          key: const ValueKey('procurement_restore_go'),
          onPressed: _picked.isEmpty
              ? null
              : () {
                  provider.restoreHiddenProcurement(rooms: _picked);
                  Navigator.of(context).pop();
                },
          child: Text(
            _picked.isEmpty
                ? 'Add back'
                : 'Add back ${_picked.length} room'
                      '${_picked.length == 1 ? '' : 's'}',
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
//  THE PICTURE
// ---------------------------------------------------------------------------

/// The log as a picture: previewed, then saved, copied or annotated.
class _ProcurementImageDialog extends StatefulWidget {
  const _ProcurementImageDialog();

  @override
  State<_ProcurementImageDialog> createState() =>
      _ProcurementImageDialogState();
}

class _ProcurementImageDialogState extends State<_ProcurementImageDialog> {
  final GlobalKey _boundary = GlobalKey();
  bool _saving = false;

  String get _stem {
    final name = context.read<AppStateProvider>().project.name.trim();
    return name.isEmpty ? 'project' : name.replaceAll(RegExp(r'[^\w\-]+'), '_');
  }

  /// Two device pixels per logical one, so the picture reads on paper.
  Future<Uint8List?> _capture() async {
    setState(() => _saving = true);
    try {
      return await captureBoundary(_boundary, pixelRatio: 2.0);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _failed() => showTimedSnackBar(
    ScaffoldMessenger.of(context),
    const SnackBar(content: Text('The log could not be captured.')),
  );

  Future<void> _copy() async {
    final bytes = await _capture();
    if (!mounted) return;
    await copyPictureToClipboard(context, bytes, what: 'The log');
  }

  Future<void> _annotate() async {
    final bytes = await _capture();
    if (!mounted) return;
    if (bytes == null) return _failed();
    await showAnnotationEditor(
      context,
      bytes,
      defaultFileName: '${_stem}_AV_Procurement_Log.png',
    );
  }

  Future<void> _save() async {
    final provider = context.read<AppStateProvider>();
    final bytes = await _capture();
    if (!mounted) return;
    if (bytes == null) return _failed();
    final picked = await saveFileCompat(
      dialogTitle: 'Save the AV procurement log',
      fileName: '${_stem}_AV_Procurement_Log.png',
      type: FileType.custom,
      allowedExtensions: const ['png'],
    );
    if (picked == null) return;
    final target =
        picked.toLowerCase().endsWith('.png') ? picked : '$picked.png';
    try {
      await File(target).writeAsBytes(bytes);
      if (mounted) {
        showSavedFileSnack(context, provider, 'The procurement log', target);
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
    final project = context.watch<AppStateProvider>().project;
    return AlertDialog(
      key: const ValueKey('procurement_image_dialog'),
      title: const Text('The procurement log as a picture'),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.7,
        child: ZoomablePicturePreview(
          keyPrefix: 'procurement_image',
          magnifier: true,
          backdrop: Theme.of(context).brightness == Brightness.dark
              ? Colors.black45
              : Colors.grey[350],
          child: RepaintBoundary(
            key: _boundary,
            child: ProcurementLogPicture(
              title: project.name.trim().isEmpty
                  ? kProcurementLogSheet
                  : '${project.name.trim()} - $kProcurementLogSheet',
              entries: liveProcurement(
                project,
                context.read<AppStateProvider>().priceProject(),
              ),
              colors: project.procurementColors,
              labels: project.procurementColumnLabels,
              columns: project.procurementColumns,
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        OutlinedButton.icon(
          onPressed: _saving ? null : _annotate,
          icon: const Icon(Icons.draw_outlined, size: 18),
          label: const Text('Annotate'),
        ),
        OutlinedButton.icon(
          onPressed: _saving ? null : _copy,
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          label: const Text('Copy to clipboard'),
        ),
        FilledButton.icon(
          key: const ValueKey('procurement_save_png'),
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.download, size: 18),
          label: Text(_saving ? 'Capturing...' : 'Save as PNG'),
        ),
      ],
    );
  }
}

/// The log drawn as the document: every column, every room, on white, with
/// the column headings in the job's colors.
class ProcurementLogPicture extends StatelessWidget {
  final String title;
  final List<ProcurementEntry> entries;
  final Map<String, int> colors;
  final List<String> order;
  final Map<String, String> labels;

  /// The job's columns - see [BuildingProject.procurementColumns]. [order]
  /// is used when there are none.
  final List<ProcurementColumnSpec>? columns;

  const ProcurementLogPicture({
    super.key,
    required this.title,
    required this.entries,
    required this.colors,
    this.order = const [],
    this.labels = const {},
    this.columns,
  });

  static const double _wide = 180;
  static const double _narrow = 96;

  /// The wider columns: the ones that hold a name or a sentence.
  static const Set<String> _wideIds = {
    'device',
    'description',
    'p6Description',
    'notes',
    'status',
  };

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF1F2933);
    const cellStyle = TextStyle(fontSize: 11, color: ink);
    const line = BorderSide(color: Color(0xFFBDBDBD), width: 0.5);

    double widthOf(ProcurementColumnSpec c) =>
        _wideIds.contains(c.id) || procurementColumnIsCustom(c.id)
        ? _wide
        : _narrow;

    Widget cell(String text, double width, {Color? fill, TextStyle? style}) =>
        Container(
          width: width,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            color: fill,
            border: const Border(right: line, bottom: line),
          ),
          child: Text(text, style: style ?? cellStyle),
        );

    Widget heading(ProcurementColumnSpec c) {
      final fill = procurementColumnColor(c, colors);
      return Container(
        width: widthOf(c),
        height: 58,
        margin: const EdgeInsets.all(1.5),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Color(fill),
          borderRadius: BorderRadius.circular(5),
        ),
        child: WholeWordText(
          procurementColumnLabel(c, labels),
          maxLines: 3,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.bold,
            color: Color(procurementInkFor(fill)),
          ),
        ),
      );
    }

    final columns = this.columns ?? orderedProcurementColumns(order);

    Widget entryRow(ProcurementEntry e, int i) {
      final values = procurementValues(e);
      return Container(
        color: i.isOdd ? const Color(0xFFF5F5F5) : Colors.white,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final spec in columns)
              cell(values[spec.id] ?? '', widthOf(spec) + 3),
          ],
        ),
      );
    }

    final total = columns.fold<double>(
      0,
      (sum, c) => sum + widthOf(c) + 3,
    );

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: ink,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final c in columns) heading(c)],
          ),
          for (final (gi, group) in procurementByRoom(entries).indexed) ...[
            Container(
              width: total,
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              // Alternating shades of one hue, so the rooms stay apart.
              color: gi.isOdd
                  ? const Color(0xFFD1D6F0)
                  : const Color(0xFFE8EAF6),
              child: Text(
                group.room.isEmpty ? 'No room' : group.room,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: ink,
                ),
              ),
            ),
            for (final (i, e) in group.entries.indexed) entryRow(e, i),
          ],
        ],
      ),
    );
  }
}

/// Centered text that wraps between words and never inside one: when a
/// single word is wider than the space, the type shrinks to fit it.
class WholeWordText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final int maxLines;

  const WholeWordText(
    this.text, {
    super.key,
    this.style,
    this.maxLines = 3,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final base = DefaultTextStyle.of(context).style.merge(style);
      final scaler = MediaQuery.textScalerOf(context);
      var widest = 0.0;
      for (final word in text.split(RegExp(r'\s+'))) {
        if (word.isEmpty) continue;
        final painter = TextPainter(
          text: TextSpan(text: word, style: base),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        if (painter.width > widest) widest = painter.width;
        painter.dispose();
      }
      final room = box.maxWidth;
      // A hair of slack, so rounding never tips a word over the edge.
      final shrink = widest > 0 && room.isFinite && widest + 1 > room
          ? (room / (widest + 1)).clamp(0.5, 1.0)
          : 1.0;
      final size = base.fontSize;
      return Text(
        text,
        textAlign: TextAlign.center,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: shrink == 1.0 || size == null
            ? base
            // The spacing between letters shrinks with them, or the word
            // would still be too wide.
            : base.copyWith(
                fontSize: size * shrink,
                letterSpacing: base.letterSpacing == null
                    ? null
                    : base.letterSpacing! * shrink,
              ),
      );
    },
  );
}
