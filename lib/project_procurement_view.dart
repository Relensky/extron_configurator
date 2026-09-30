import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'file_dialogs.dart';
import 'pinned_grid.dart';
import 'procurement_log.dart';
import 'project_estimate.dart';
import 'project_schedule.dart' show formatScheduleDate;
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

/// One column after the frozen device column.
typedef _Col = ({String label, double width, _Group group});

const List<_Col> _kCols = [
  (label: 'Company', width: 110, group: _Group.item),
  (label: 'Room #', width: 90, group: _Group.item),
  (label: 'Equipment Description', width: 210, group: _Group.item),
  (label: 'Status', width: 170, group: _Group.status),
  (label: 'Install Before Drywall or After Paint?', width: 150, group: _Group.status),
  (label: 'P6 Activity ID', width: 110, group: _Group.schedule),
  (label: 'P6 Activity Description', width: 190, group: _Group.schedule),
  (label: 'Review Time', width: 90, group: _Group.schedule),
  (label: 'Lead Times (Weeks)', width: 100, group: _Group.schedule),
  (label: 'P6 Start Date', width: 120, group: _Group.dates),
  (label: 'Required On Site ($kProcurementOnSiteLeadDays days before P6)', width: 130, group: _Group.dates),
  (label: 'Date to be Submitted', width: 120, group: _Group.dates),
  (label: 'Released', width: 80, group: _Group.dates),
  (label: 'Actual Release Date', width: 120, group: _Group.dates),
  (label: 'Estimated Delivery Date', width: 120, group: _Group.dates),
  (label: 'Notes/Comments', width: 240, group: _Group.notes),
];

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
  final entries = provider.project.procurement;

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
      SliverToBoxAdapter(child: _LogGrid(entries: entries)),
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
          if (entries.isNotEmpty) ...[
            OutlinedButton.icon(
              key: const ValueKey('procurement_export_xlsx'),
              onPressed: () => _exportSpreadsheet(context),
              icon: const Icon(Icons.table_view, size: 18),
              label: const Text('Spreadsheet'),
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
typedef _Row = ({String room, int count, ProcurementEntry? entry, int index});

class _LogGrid extends StatefulWidget {
  final List<ProcurementEntry> entries;

  const _LogGrid({required this.entries});

  @override
  State<_LogGrid> createState() => _LogGridState();
}

class _LogGridState extends State<_LogGrid> {
  double _zoom = kGridZoomNormal;
  bool _fit = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => _sheet(context, box.maxWidth),
  );

  Widget _sheet(BuildContext context, double available) {
    final theme = Theme.of(context);
    final natural =
        gridMetric(context, _kFrozen) +
        _kCols.fold<double>(0, (s, c) => s + gridMetric(context, c.width));
    final zoom = _fit
        ? gridFitZoom(natural: natural, available: available - 32)
        : _zoom;
    final zoomed = zoomedTextTheme(theme, zoom);
    double w(double base) => gridMetric(context, base) * zoom;

    final rows = <_Row>[
      for (final g in procurementByRoom(widget.entries)) ...[
        (room: g.room, count: g.entries.length, entry: null, index: 0),
        for (final (i, e) in g.entries.indexed)
          (room: g.room, count: 0, entry: e, index: i),
      ],
    ];
    final rowH = w(_kRow);
    final bodyWidth = _kCols.fold<double>(0, (s, c) => s + w(c.width));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Press a line to edit it. Press a status or a date to '
                  'change just that.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
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
          PinnedGrid(
            key: const ValueKey('procurement_grid'),
            frozenWidth: w(_kFrozen),
            headerHeight: w(_kHead),
            bodyWidth: bodyWidth,
            bodyHeight: rowH * rows.length,
            corner: _headBox(zoomed, 'Device', _Group.item, w(_kFrozen), w),
            header: Row(
              children: [
                for (final c in _kCols)
                  _headBox(zoomed, c.label, c.group, w(c.width), w),
              ],
            ),
            rowCount: rows.length,
            rowExtent: rowH,
            frozenRowBuilder: (context, i) =>
                _frozenRow(context, zoomed, rows[i], w),
            bodyRowBuilder: (context, i) =>
                _bodyRow(context, zoomed, rows[i], w),
          ),
        ],
      ),
    );
  }

  /// A header: a colored box, every one the same height.
  Widget _headBox(
    TextTheme zoomed,
    String label,
    _Group group,
    double width,
    double Function(double) w,
  ) {
    final c = _groupColors(Theme.of(context), group);
    return SizedBox(
      width: width,
      height: w(_kHead),
      child: Padding(
        padding: EdgeInsets.all(_kGap),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.fill,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: w(6)),
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: zoomed.labelSmall?.copyWith(
                  color: c.ink,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color? _rowFill(ThemeData theme, _Row row) {
    if (row.entry == null) return theme.colorScheme.primaryContainer;
    return row.index.isOdd
        ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6)
        : null;
  }

  Border _rule(ThemeData theme) => Border(
    bottom: BorderSide(color: theme.colorScheme.outlineVariant, width: 0.5),
  );

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
        padding: EdgeInsets.symmetric(horizontal: w(10)),
        alignment: Alignment.centerLeft,
        child: Text(
          '${row.room.isEmpty ? 'No room' : row.room}  ·  ${row.count} '
          'line${row.count == 1 ? '' : 's'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: zoomed.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onPrimaryContainer,
          ),
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
                onPressed: () => provider.removeProcurementEntry(entry.id),
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
      pill(entry.company, _companyColors(theme, entry.company)),
      text(entry.room, lines: 1),
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
      text(entry.notes),
    ];

    return Material(
      color: _rowFill(theme, row) ?? Colors.transparent,
      child: InkWell(
        onTap: () => _edit(entry),
        child: Container(
          decoration: BoxDecoration(border: _rule(theme)),
          child: Row(
            children: [
              for (var c = 0; c < _kCols.length; c++)
                Container(
                  width: w(_kCols[c].width),
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
                  child: cells[c],
                ),
            ],
          ),
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
                  date('Date to be submitted', submitBy, (v) => submitBy = v),
                  date('Actual release date', releasedOn,
                      (v) => releasedOn = v),
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
