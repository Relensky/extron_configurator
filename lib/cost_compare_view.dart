import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;

import 'app_state.dart';
import 'building_project.dart';
import 'cost_compare.dart';
import 'cost_estimate.dart';
import 'project_estimate.dart';
import 'project_search.dart';

/// A room picked to compare with or copy from: its config file and its name.
typedef OtherRoom = ({String configPath, String label});

/// Asks for a room in the open project or any project under the Root Folder.
/// The open room is left off the list.
Future<OtherRoom?> pickOtherRoom(
  BuildContext context,
  AppStateProvider provider, {
  required String title,
  required String action,
}) =>
    showDialog<OtherRoom>(
      context: context,
      builder: (_) => _OtherRoomDialog(
        provider: provider,
        title: title,
        action: action,
      ),
    );

class _OtherRoomDialog extends StatefulWidget {
  final AppStateProvider provider;
  final String title;
  final String action;
  const _OtherRoomDialog({
    required this.provider,
    required this.title,
    required this.action,
  });

  @override
  State<_OtherRoomDialog> createState() => _OtherRoomDialogState();
}

class _OtherRoomDialogState extends State<_OtherRoomDialog> {
  List<SearchProject> _projects = [];
  String _projectFile = '';
  List<OtherRoom> _rooms = [];
  String _picked = '';
  bool _loadingProjects = true;
  bool _loadingRooms = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _projectFile = widget.provider.currentProjectPath;
    _findProjects();
    if (_projectFile.isNotEmpty) _loadRooms(_projectFile);
  }

  Future<void> _findProjects() async {
    final found = await ProjectSearch.projects(
      widget.provider.effectiveRootFolder,
      extra: [
        if (widget.provider.currentProjectPath.isNotEmpty)
          widget.provider.currentProjectPath,
      ],
    );
    if (!mounted) return;
    setState(() {
      _projects = found;
      _loadingProjects = false;
    });
  }

  Future<void> _loadRooms(String file) async {
    setState(() {
      _loadingRooms = true;
      _rooms = [];
      _picked = '';
      _error = '';
    });
    try {
      // The open project as it stands, unsaved rooms and all.
      final project = _same(file, widget.provider.currentProjectPath)
          ? widget.provider.project
          : await BuildingProject.load(file);
      final open = widget.provider.currentConfigPath;
      final rooms = <OtherRoom>[
        for (final ref in project.rooms)
          if (BuildingProject.resolvePath(ref.configPath, file)
              case final p when p.isNotEmpty && !_same(p, open))
            (
              configPath: p,
              label: ref.label.trim().isNotEmpty
                  ? ref.label.trim()
                  : path.basenameWithoutExtension(p),
            ),
      ]..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      if (!mounted || file != _projectFile) return;
      setState(() {
        _rooms = rooms;
        _loadingRooms = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingRooms = false;
        _error = 'That project could not be read: $e';
      });
    }
  }

  static bool _same(String a, String b) =>
      a.isNotEmpty &&
      b.isNotEmpty &&
      path.normalize(a).toLowerCase() == path.normalize(b).toLowerCase();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasProject =
        _projects.any((p) => _same(p.path, _projectFile));
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_loadingProjects && _projects.isEmpty)
              const LinearProgressIndicator()
            else
              DropdownButtonFormField<String>(
                key: const ValueKey('other_room_project'),
                initialValue: hasProject ? _projectFile : null,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Project',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final p in _projects)
                    DropdownMenuItem(
                      value: p.path,
                      child: Text(
                        _same(p.path, widget.provider.currentProjectPath)
                            ? '${p.name} (open project)'
                            : p.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  _projectFile = v;
                  _loadRooms(v);
                },
              ),
            const SizedBox(height: 10),
            Expanded(
              child: _loadingRooms
                  ? const Center(child: CircularProgressIndicator())
                  : _error.isNotEmpty
                  ? Center(child: Text(_error, textAlign: TextAlign.center))
                  : _rooms.isEmpty
                  ? Center(
                      child: Text(
                        _projectFile.isEmpty
                            ? 'Pick a project to list its rooms.'
                            : 'No other rooms in this project.',
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  : ListView(
                      children: [
                        for (final r in _rooms)
                          ListTile(
                            key: ValueKey('other_room_${r.label}'),
                            dense: true,
                            leading: const Icon(Icons.meeting_room_outlined,
                                size: 20),
                            title: Text(r.label),
                            selected: r.configPath == _picked,
                            onTap: () =>
                                setState(() => _picked = r.configPath),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('other_room_go'),
          onPressed: _picked.isEmpty
              ? null
              : () => Navigator.pop(
                    context,
                    _rooms.firstWhere((r) => r.configPath == _picked),
                  ),
          child: Text(widget.action),
        ),
      ],
    );
  }
}

/// [room] read and priced the way this PC prices the open room: the same
/// catalog, rate card, base costs and tier. Its own tax rate if it has one,
/// else the rate the open room is on.
Future<({LoadedRoom room, CostEstimate? estimate})> priceOtherRoom(
  AppStateProvider provider,
  String configPath,
) async {
  final room = await readRoomFromDiskAsync(configPath);
  if (!room.ok) return (room: room, estimate: null);
  final settings = room.settings.ownTaxRate
      ? room.settings
      : (copyCostSettings(room.settings)
          ..taxPercent = provider.baseTaxPercent);
  final estimate = computeRoomCost(
    model: room.model,
    library: provider.avDeviceLibrary,
    settings: settings,
    rates: provider.laborRates,
    baseCosts: provider.baseCosts,
    tier: provider.pricingTier,
  );
  return (room: room, estimate: estimate);
}

/// The open room's name, for the comparison's column heading.
String _thisRoomName(AppStateProvider provider) {
  final ref = provider.openProjectRoom;
  if (ref != null && ref.label.trim().isNotEmpty) return ref.label.trim();
  final setup = provider.roomConfig['SYSTEM_SETUP'];
  final name = setup is Map ? setup['gui_full_room_name']?.toString() : null;
  return name == null || name.trim().isEmpty ? 'This room' : name.trim();
}


/// Picks another room and shows the two cost pages side by side, with the
/// parts one room has and the other does not ready to copy across.
/// [copying] only changes the picker's wording, for Cost items > Copy.
Future<void> showCompareRoomCosts(
  BuildContext context,
  AppStateProvider provider, {
  bool copying = false,
}) async {
  final other = await pickOtherRoom(
    context,
    provider,
    title: copying
        ? 'Copy cost items from another room'
        : 'Compare costs with another room',
    action: copying ? 'Next' : 'Compare',
  );
  if (other == null || !context.mounted) return;
  final priced = await priceOtherRoom(provider, other.configPath);
  if (!context.mounted) return;
  final estimate = priced.estimate;
  if (estimate == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${other.label} could not be read: ${priced.room.error}'),
    ));
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => CostCompareDialog(
      provider: provider,
      hereName: _thisRoomName(provider),
      thereName: other.label,
      thereConfigPath: other.configPath,
      hereEstimate: provider.roomCost,
      thereEstimate: estimate,
      hereSettings: provider.avCost,
      thereSettings: priced.room.settings,
      currency: provider.roomCost.currency,
    ),
  );
}

/// Which way the comparison copies.
enum CopyDirection { intoHere, intoThere }

/// The two rooms' parts side by side, each part that only one room has
/// ticked to copy into the other.
class CostCompareDialog extends StatefulWidget {
  final AppStateProvider provider;
  final String hereName;
  final String thereName;

  /// The other room's config, written to when copying into it. '' offers no
  /// copying that way.
  final String thereConfigPath;
  final CostEstimate hereEstimate;
  final CostEstimate thereEstimate;
  final RoomCostSettings hereSettings;
  final RoomCostSettings thereSettings;
  final String currency;

  const CostCompareDialog({
    super.key,
    required this.provider,
    required this.hereName,
    required this.thereName,
    required this.hereEstimate,
    required this.thereEstimate,
    required this.hereSettings,
    required this.thereSettings,
    required this.currency,
    this.thereConfigPath = '',
  });

  @override
  State<CostCompareDialog> createState() => _CostCompareDialogState();
}

class _CostCompareDialogState extends State<CostCompareDialog> {
  late final CostComparison _c =
      compareRoomCosts(widget.hereEstimate, widget.thereEstimate);
  bool _differencesOnly = true;
  CopyDirection _into = CopyDirection.intoHere;
  final Set<String> _picked = {};
  bool _busy = false;

  bool get _intoHere => _into == CopyDirection.intoHere;
  String get _targetName => _intoHere ? widget.hereName : widget.thereName;

  static String _rowKey(CostDiffRow r) =>
      '${r.section}|${r.name}|${r.partNumber}';

  /// The source room has it and the target does not.
  bool _canCopy(CostDiffRow r) =>
      _intoHere ? r.inThere && !r.inHere : r.inHere && !r.inThere;

  bool _inTarget(CostDiffRow r) => _intoHere ? r.inHere : r.inThere;

  List<CostDiffRow> get _pickedRows => [
    for (final r in _c.rows)
      if (_canCopy(r) && _picked.contains(_rowKey(r))) r,
  ];

  String _money(double v) => formatMoney(v, widget.currency);
  String _qty(double v) => v == 0 ? '-' : trimNumber(v);
  String _diff(double d) =>
      d.abs() < 0.005 ? '-' : '${d > 0 ? '+' : ''}${_money(d)}';

  String _kindLabel(CostDiffKind kind) => switch (kind) {
    CostDiffKind.same => 'Same',
    CostDiffKind.onlyHere => 'Only in ${widget.hereName}',
    CostDiffKind.onlyThere => 'Only in ${widget.thereName}',
    CostDiffKind.qty => 'Quantity differs',
    CostDiffKind.price => 'Price differs',
    CostDiffKind.qtyAndPrice => 'Quantity and price differ',
  };

  Color _kindColor(ThemeData theme, CostDiffKind kind) => switch (kind) {
    CostDiffKind.same => theme.colorScheme.onSurfaceVariant,
    CostDiffKind.onlyHere || CostDiffKind.onlyThere => theme.colorScheme.tertiary,
    _ => theme.colorScheme.error,
  };

  Future<void> _copy() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final provider = widget.provider;
    final set = costItemsFromRows(
      _pickedRows,
      source: _intoHere ? widget.thereSettings : widget.hereSettings,
      fromThere: _intoHere,
    );
    final (kept, skipped) = withoutExisting(
      set,
      target: _intoHere ? widget.hereSettings : widget.thereSettings,
      targetEstimate: _intoHere ? widget.hereEstimate : widget.thereEstimate,
    );
    if (kept.isEmpty) {
      messenger.showSnackBar(SnackBar(
        content: Text('Everything picked is already in $_targetName.'),
      ));
      return;
    }
    final ok = await confirmCopyItems(
      context,
      provider,
      to: _targetName,
      items: kept,
      skipped: skipped,
      canUndo: _intoHere,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final n = _intoHere
        ? provider.applyAvCostItems(kept, from: '${widget.thereName} items')
        : await provider.addCostItemsToRoomFile(widget.thereConfigPath, kept);
    if (!mounted) return;
    setState(() => _busy = false);
    if (n < 0) {
      messenger.showSnackBar(SnackBar(
        content: Text('${widget.thereName}\'s cost file could not be '
            'written. Nothing was copied.'),
      ));
      return;
    }
    navigator.pop();
    messenger.showSnackBar(SnackBar(
      content: Text('$n item${n == 1 ? '' : 's'} added to $_targetName.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = _c;
    final rows = _differencesOnly ? c.differences : c.rows;
    final small = theme.textTheme.bodySmall;
    final bold = small?.copyWith(fontWeight: FontWeight.w600);
    final flag = bold?.copyWith(color: theme.colorScheme.error);
    final copyable = [for (final r in c.rows) if (_canCopy(r)) r];
    final picked = _pickedRows.length;

    Widget cell(String text, {TextStyle? style, bool right = true}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Text(text,
          style: style ?? small,
          textAlign: right ? TextAlign.right : TextAlign.left),
    );

    Widget pick(CostDiffRow r) {
      if (_canCopy(r)) {
        return Checkbox(
          key: ValueKey('compare_pick_${_rowKey(r)}'),
          value: _picked.contains(_rowKey(r)),
          onChanged: (v) => setState(() => v == true
              ? _picked.add(_rowKey(r))
              : _picked.remove(_rowKey(r))),
        );
      }
      return Tooltip(
        message: _inTarget(r)
            ? 'Already in $_targetName'
            : 'Not in ${_intoHere ? widget.thereName : widget.hereName}',
        child: const Checkbox(value: false, onChanged: null),
      );
    }

    final table = <TableRow>[
      TableRow(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: theme.dividerColor)),
        ),
        children: [
          const SizedBox.shrink(),
          cell('Part', style: bold, right: false),
          cell('Qty\n${widget.hereName}', style: bold),
          cell('Qty\n${widget.thereName}', style: bold),
          cell('Unit\n${widget.hereName}', style: bold),
          cell('Unit\n${widget.thereName}', style: bold),
          cell('Difference', style: bold),
        ],
      ),
    ];
    String? section;
    for (final r in rows) {
      if (r.section != section) {
        section = r.section;
        table.add(TableRow(children: [
          const SizedBox.shrink(),
          Padding(
            padding: const EdgeInsets.only(top: 10, left: 6, bottom: 2),
            child: Text(r.section,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                )),
          ),
          for (var i = 0; i < 5; i++) const SizedBox.shrink(),
        ]));
      }
      final kind = r.kind;
      final priceDiff =
          kind == CostDiffKind.price || kind == CostDiffKind.qtyAndPrice;
      final qtyDiff =
          kind == CostDiffKind.qty || kind == CostDiffKind.qtyAndPrice;
      table.add(TableRow(children: [
        pick(r),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(r.name, style: theme.textTheme.bodyMedium),
              Text(
                [
                  if (r.manufacturer.isNotEmpty) r.manufacturer,
                  if (r.partNumber.isNotEmpty) r.partNumber,
                  _kindLabel(kind),
                ].join(' · '),
                style: small?.copyWith(color: _kindColor(theme, kind)),
              ),
            ],
          ),
        ),
        cell(_qty(r.qtyHere), style: qtyDiff ? flag : null),
        cell(_qty(r.qtyThere), style: qtyDiff ? flag : null),
        cell(r.inHere ? _money(r.unitHere) : '-',
            style: priceDiff ? flag : null),
        cell(r.inThere ? _money(r.unitThere) : '-',
            style: priceDiff ? flag : null),
        cell(_diff(r.totalDifference)),
      ]));
    }

    final totals = <TableRow>[
      TableRow(children: [
        cell('', right: false),
        cell(widget.hereName, style: bold),
        cell(widget.thereName, style: bold),
        cell('Difference', style: bold),
      ]),
      for (final s in c.sections)
        if (s.here != 0 || s.there != 0)
          TableRow(children: [
            cell(s.section, right: false),
            cell(_money(s.here)),
            cell(_money(s.there)),
            cell(_diff(s.here - s.there)),
          ]),
      TableRow(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        children: [
          cell('Grand total', style: bold, right: false),
          cell(_money(c.grandHere), style: bold),
          cell(_money(c.grandThere), style: bold),
          cell(_diff(c.grandHere - c.grandThere), style: bold),
        ],
      ),
    ];

    return AlertDialog(
      title: Text('${widget.hereName} vs ${widget.thereName}'),
      content: SizedBox(
        width: 980,
        height: 640,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Parts are matched by part number, else by model. '
              '${c.differences.length} of ${c.rows.length} differ. Both '
              'rooms are priced at today\'s catalog prices plus any price '
              'typed in each room. Tick the parts to copy; a part the other '
              'room already has cannot be ticked.',
              style: small,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<CopyDirection>(
                  key: const ValueKey('compare_direction'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: CopyDirection.intoHere,
                      icon: const Icon(Icons.arrow_back, size: 16),
                      label: Text('Copy into ${widget.hereName}'),
                    ),
                    ButtonSegment(
                      value: CopyDirection.intoThere,
                      enabled: widget.thereConfigPath.isNotEmpty,
                      icon: const Icon(Icons.arrow_forward, size: 16),
                      label: Text('Copy into ${widget.thereName}'),
                    ),
                  ],
                  selected: {_into},
                  onSelectionChanged: (v) => setState(() {
                    _into = v.single;
                    _picked.clear();
                  }),
                ),
                TextButton(
                  key: const ValueKey('compare_pick_all'),
                  onPressed: copyable.isEmpty
                      ? null
                      : () => setState(() => _picked
                        ..clear()
                        ..addAll(copyable.map(_rowKey))),
                  child: Text('Tick all ${copyable.length} missing'),
                ),
                TextButton(
                  onPressed:
                      _picked.isEmpty ? null : () => setState(_picked.clear),
                  child: const Text('Clear'),
                ),
                FilterChip(
                  key: const ValueKey('compare_differences_only'),
                  label: const Text('Differences only'),
                  selected: _differencesOnly,
                  onSelected: (v) => setState(() => _differencesOnly = v),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        'The two rooms buy the same parts at the same prices.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : SingleChildScrollView(
                      child: Table(
                        columnWidths: const {
                          0: FixedColumnWidth(40),
                          1: FlexColumnWidth(3),
                          2: FlexColumnWidth(1),
                          3: FlexColumnWidth(1),
                          4: FlexColumnWidth(1.3),
                          5: FlexColumnWidth(1.3),
                          6: FlexColumnWidth(1.3),
                        },
                        defaultVerticalAlignment:
                            TableCellVerticalAlignment.middle,
                        children: table,
                      ),
                    ),
            ),
            const Divider(),
            Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: 560,
                child: Table(
                  key: const ValueKey('compare_totals'),
                  columnWidths: const {0: FlexColumnWidth(1.4)},
                  children: totals,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          key: const ValueKey('compare_copy'),
          icon: _busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(_intoHere ? Icons.arrow_back : Icons.arrow_forward,
                  size: 18),
          label: Text(picked == 0
              ? 'Copy into $_targetName'
              : 'Copy $picked into $_targetName'),
          onPressed: picked == 0 || _busy ? null : _copy,
        ),
      ],
    );
  }
}

/// "Adding 3 items from the listed categories:" and the list, before any
/// cost items go into [to]. [skipped] are the ones [to] already has.
Future<bool> confirmCopyItems(
  BuildContext context,
  AppStateProvider provider, {
  required String to,
  required CostItemSet items,
  int skipped = 0,
  bool canUndo = true,
}) async {
  final sections = costItemSections(
    items,
    rateNames: {for (final r in provider.laborRates.rates) r.id: r.name},
  );
  final count = sections.values.fold<int>(0, (n, l) => n + l.length);
  return await showDialog<bool>(
        context: context,
        builder: (ctx) {
          final theme = Theme.of(ctx);
          return AlertDialog(
            title: Text('Copy into $to'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  key: const ValueKey('copy_items_list'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Adding $count item${count == 1 ? '' : 's'} from the '
                      'listed categories:',
                      style: theme.textTheme.bodyMedium,
                    ),
                    for (final e in sections.entries) ...[
                      const SizedBox(height: 8),
                      Text(e.key,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          )),
                      for (final line in e.value)
                        Padding(
                          padding: const EdgeInsets.only(left: 12, top: 2),
                          child: Text('• $line',
                              style: theme.textTheme.bodySmall),
                        ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      [
                        'They are added without replacing any items.',
                        'Items that already exist are skipped'
                            '${skipped > 0 ? ' ($skipped here)' : ''}.',
                        canUndo
                            ? 'Undo removes them.'
                            : '$to is not open here, so Undo cannot take '
                                  'them back off - open it and delete them.',
                      ].join(' '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const ValueKey('copy_items_go'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('Add $count'),
              ),
            ],
          );
        },
      ) ??
      false;
}

/// Cost items > Copy from another room: the comparison, ready to tick.
Future<void> copyCostItemsFromRoom(
  BuildContext context,
  AppStateProvider provider,
) =>
    showCompareRoomCosts(context, provider, copying: true);

/// Saves this room's cost items as a preset on the shared Root Folder.
Future<void> saveCostPresetFromRoom(
  BuildContext context,
  AppStateProvider provider,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final items = CostItemSet.fromSettings(provider.avCost);
  if (items.isEmpty) {
    messenger.showSnackBar(const SnackBar(
      content: Text('This room has no cost items to save - add equipment, '
          'hardware, cable, labor, other items or fees first.'),
    ));
    return;
  }
  final root = provider.effectiveRootFolder;
  final existing = await loadCostPresets(root);
  if (!context.mounted) return;
  final name = TextEditingController();
  final description = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final taken = existing.any((p) =>
            p.name.trim().toLowerCase() == name.text.trim().toLowerCase());
        return AlertDialog(
          title: const Text('Save cost preset'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Saves ${items.summary} - with the prices, spares and '
                  'shipping typed on them - to the "$kCostPresetFolder" '
                  'folder under the Root Folder, where everybody can apply '
                  'it. Devices counted off the diagram are not included.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('cost_preset_name'),
                  controller: name,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    helperText:
                        taken ? 'Replaces the preset of the same name.' : null,
                  ),
                  onChanged: (_) => setLocal(() {}),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: description,
                  decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('cost_preset_save'),
              onPressed: name.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
  if (ok != true) return;
  try {
    await saveCostPreset(
      root,
      CostPreset(
        name: name.text.trim(),
        description: description.text.trim(),
        items: items,
        savedBy: Platform.environment['USERNAME'] ?? '',
        savedAt: DateTime.now().toIso8601String(),
      ),
    );
    messenger.showSnackBar(SnackBar(
      content: Text('Cost preset "${name.text.trim()}" saved.'),
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(
      content: Text('The preset could not be saved: $e'),
    ));
  }
}

/// Lists the cost presets on the Root Folder and adds the one picked.
Future<void> applyCostPresetToRoom(
  BuildContext context,
  AppStateProvider provider,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final presets = await loadCostPresets(provider.effectiveRootFolder);
  if (!context.mounted) return;
  if (presets.isEmpty) {
    messenger.showSnackBar(const SnackBar(
      content: Text('No cost presets yet. Save one from a room with '
          'Cost items > Save as cost preset.'),
    ));
    return;
  }
  final picked = await showDialog<CostPreset>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Apply cost preset'),
      content: SizedBox(
        width: 480,
        height: 400,
        child: ListView(
          children: [
            for (final p in presets)
              ListTile(
                key: ValueKey('cost_preset_${p.name}'),
                leading: const Icon(Icons.request_quote_outlined),
                title: Text(p.name),
                subtitle: Text([
                  if (p.description.isNotEmpty) p.description,
                  p.items.summary,
                  if (p.savedBy.isNotEmpty) 'saved by ${p.savedBy}',
                ].join(' · ')),
                onTap: () => Navigator.pop(ctx, p),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
  if (picked == null || !context.mounted) return;
  final here = _thisRoomName(provider);
  final (kept, skipped) = withoutExisting(
    picked.items,
    target: provider.avCost,
    targetEstimate: provider.roomCost,
  );
  if (kept.isEmpty) {
    messenger.showSnackBar(SnackBar(
      content: Text('Everything in "${picked.name}" is already in $here.'),
    ));
    return;
  }
  if (!await confirmCopyItems(context, provider,
      to: here, items: kept, skipped: skipped)) {
    return;
  }
  final n = provider.applyAvCostItems(kept, from: picked.name);
  messenger.showSnackBar(SnackBar(
    content: Text('$n item${n == 1 ? '' : 's'} added from "${picked.name}".'),
  ));
}
