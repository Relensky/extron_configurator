import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;

import 'app_state.dart';
import 'av_device_library.dart' show AvDeviceTemplate;
import 'building_project.dart';
import 'cost_compare.dart';
import 'cost_estimate.dart';
import 'file_dialogs.dart';
import 'history_sources.dart' show roomNameForConfig;
import 'project_estimate.dart';
import 'project_search.dart';
import 'recent_files.dart';

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

/// The project dropdown's "Open project file..." entry.
const _kOpenProjectFile = '\u0000open';

class _OtherRoomDialogState extends State<_OtherRoomDialog> {
  /// Every project offered: the open one, recent ones, then the rest.
  List<SearchProject> _projects = [];

  /// Picked with "Open project file..." - first after the open project.
  final List<SearchProject> _openedFiles = [];
  String _projectFile = '';
  List<OtherRoom> _rooms = [];

  /// Rooms opened lately, by path - drawn with a clock.
  Set<String> _recentRooms = {};
  String _picked = '';
  bool _loadingProjects = true;
  bool _loadingRooms = false;
  String _error = '';
  int _dropdownResets = 0;

  AppStateProvider get _provider => widget.provider;

  @override
  void initState() {
    super.initState();
    _projectFile = _provider.currentProjectPath;
    _projects = _ordered(const []);
    _findProjects();
    if (_projectFile.isNotEmpty) {
      _loadRooms(_projectFile);
    } else {
      _listRecentRooms();
    }
  }

  static String _norm(String p) => path.normalize(p).toLowerCase();

  /// Recent entries of [kind] whose files are still there, newest first.
  List<RecentFile> _recent(RecentKind kind) =>
      [for (final r in _provider.recentFiles[kind]) if (r.stillThere) r];

  /// The open project first, then recent ones, then [found] by name.
  List<SearchProject> _ordered(List<SearchProject> found) {
    final byPath = {for (final p in found) _norm(p.path): p};
    final seen = <String>{};
    final out = <SearchProject>[];
    void add(String file, String name) {
      if (file.isEmpty || !seen.add(_norm(file))) return;
      out.add(byPath[_norm(file)] ??
          (path: file, name: name.trim().isEmpty ? searchProjectName(file) : name));
    }

    add(_provider.currentProjectPath, _provider.project.name);
    for (final p in _openedFiles) {
      add(p.path, p.name);
    }
    for (final r in _recent(RecentKind.project)) {
      add(r.file, r.name);
    }
    for (final p in found) {
      add(p.path, p.name);
    }
    return out;
  }

  Set<String> get _recentProjects =>
      {for (final r in _recent(RecentKind.project)) _norm(r.file)};

  Future<void> _findProjects() async {
    final found = await ProjectSearch.projects(
      _provider.effectiveRootFolder,
      extra: [
        if (_provider.currentProjectPath.isNotEmpty)
          _provider.currentProjectPath,
      ],
    );
    if (!mounted) return;
    setState(() {
      _projects = _ordered(found);
      _loadingProjects = false;
    });
  }

  /// "Open project file...": any project on disk, added to the list.
  Future<void> _openProjectFile() async {
    final picked = await pickFilesCompat(
      dialogTitle: 'Which project has the room to copy from?',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final file = picked?.files.singleOrNull?.path;
    if (file == null || !mounted) return;
    setState(() {
      _openedFiles.insert(0, (path: file, name: searchProjectName(file)));
      _projects = _ordered(_projects);
      _projectFile = file;
    });
    _loadRooms(file);
  }

  /// "Room file...": a config.json picked straight off disk.
  Future<void> _openRoomFile() async {
    final picked = await pickFilesCompat(
      dialogTitle: 'Which room\'s config.json to copy from?',
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final file = picked?.files.singleOrNull?.path;
    if (file == null || !mounted) return;
    if (_same(file, _provider.currentConfigPath)) {
      setState(() => _error = 'That is the room that is open.');
      return;
    }
    final recent = _recent(RecentKind.room)
        .where((r) => _same(r.file, file))
        .firstOrNull;
    Navigator.pop(context, (
      configPath: file,
      label: roomNameForConfig(file, label: recent?.name ?? ''),
    ));
  }

  /// With no project picked: the rooms opened lately.
  void _listRecentRooms() {
    final open = _provider.currentConfigPath;
    final rooms = [
      for (final r in _recent(RecentKind.room))
        if (!_same(r.file, open))
          (configPath: r.file, label: roomNameForConfig(r.file, label: r.name)),
    ];
    setState(() {
      _rooms = rooms;
      _recentRooms = {for (final r in rooms) _norm(r.configPath)};
      _picked = '';
      _error = '';
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
      final project = _same(file, _provider.currentProjectPath)
          ? _provider.project
          : await BuildingProject.load(file);
      final open = _provider.currentConfigPath;
      // Recently opened rooms first, newest first; then the rest by name.
      final recent = _recent(RecentKind.room);
      final rank = {
        for (var i = 0; i < recent.length; i++) _norm(recent[i].file): i,
      };
      final names = {for (final r in recent) _norm(r.file): r.name};
      final rooms = <OtherRoom>[
        for (final ref in project.rooms)
          if (BuildingProject.resolvePath(ref.configPath, file)
              case final p when p.isNotEmpty && !_same(p, open))
            (
              configPath: p,
              // Folder-layout rooms are all config.json: name them by folder.
              label: roomNameForConfig(
                p,
                label: ref.label.trim().isNotEmpty
                    ? ref.label
                    : names[_norm(p)] ?? '',
              ),
            ),
      ]..sort((a, b) {
          final ra = rank[_norm(a.configPath)] ?? 1 << 20;
          final rb = rank[_norm(b.configPath)] ?? 1 << 20;
          if (ra != rb) return ra.compareTo(rb);
          return a.label.toLowerCase().compareTo(b.label.toLowerCase());
        });
      if (!mounted || file != _projectFile) return;
      setState(() {
        _rooms = rooms;
        _recentRooms = {
          for (final r in rooms)
            if (rank.containsKey(_norm(r.configPath))) _norm(r.configPath),
        };
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
    final muted = theme.colorScheme.onSurfaceVariant;
    final selected = _projects
        .where((p) => _same(p.path, _projectFile))
        .firstOrNull
        ?.path;
    final recentProjects = _recentProjects;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              // Rebuilt when a file is opened, so it shows the new pick.
              key: ValueKey('other_room_project|$selected|$_dropdownResets'),
              initialValue: selected,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Project',
                border: const OutlineInputBorder(),
                isDense: true,
                helperText: _loadingProjects
                    ? 'Looking under the Root Folder for more...'
                    : null,
              ),
              hint: const Text('No project - recent rooms are listed'),
              items: [
                DropdownMenuItem(
                  value: _kOpenProjectFile,
                  child: Row(
                    children: [
                      Icon(Icons.folder_open, size: 18, color: muted),
                      const SizedBox(width: 8),
                      const Text('Open project file...'),
                    ],
                  ),
                ),
                for (final p in _projects)
                  DropdownMenuItem(
                    value: p.path,
                    child: Row(
                      children: [
                        Icon(
                          _same(p.path, _provider.currentProjectPath)
                              ? Icons.folder_special_outlined
                              : recentProjects.contains(_norm(p.path))
                              ? Icons.history
                              : Icons.folder_outlined,
                          size: 18,
                          color: muted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _same(p.path, _provider.currentProjectPath)
                                ? '${p.name} (open project)'
                                : p.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                if (v == _kOpenProjectFile) {
                  // Back to what it showed until a file is picked.
                  setState(() => _dropdownResets++);
                  _openProjectFile();
                  return;
                }
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
                            ? 'Pick a project, or a room file below.'
                            : 'No other rooms in this project.',
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  : ListView(
                      children: [
                        for (final r in _rooms)
                          ListTile(
                            // By path: two rooms can share a name.
                            key: ValueKey('other_room_${r.configPath}'),
                            dense: true,
                            leading: Icon(
                              _recentRooms.contains(_norm(r.configPath))
                                  ? Icons.history
                                  : Icons.meeting_room_outlined,
                              size: 20,
                            ),
                            title: Text(r.label),
                            subtitle: _projectFile.isEmpty
                                ? Text(
                                    path.dirname(r.configPath),
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : null,
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
        OutlinedButton.icon(
          key: const ValueKey('other_room_file'),
          icon: const Icon(Icons.file_open_outlined, size: 18),
          label: const Text('Room file...'),
          onPressed: _openRoomFile,
        ),
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
  // Both sides as they stand now: a copy changes one, and the window stays
  // open to copy more either way.
  late CostEstimate _hereEstimate = widget.hereEstimate;
  late CostEstimate _thereEstimate = widget.thereEstimate;
  late RoomCostSettings _thereSettings = widget.thereSettings;
  late CostComparison _c = compareRoomCosts(_hereEstimate, _thereEstimate);
  bool _differencesOnly = true;
  CopyDirection _into = CopyDirection.intoHere;
  final Set<String> _picked = {};
  bool _busy = false;

  /// Parts both rooms have can be ticked, and replace the target's.
  bool _replace = false;

  /// With [_replace] on: a part only the source has, by row key, and the
  /// different part in the target it goes in place of.
  final Map<String, String> _swaps = {};

  /// What the last copy did, shown above the buttons.
  String _done = '';

  bool get _intoHere => _into == CopyDirection.intoHere;
  String get _targetName => _intoHere ? widget.hereName : widget.thereName;
  RoomCostSettings get _targetSettings =>
      _intoHere ? widget.hereSettings : _thereSettings;

  static String _rowKey(CostDiffRow r) =>
      '${r.section}|${r.name}|${r.partNumber}';

  bool _inSource(CostDiffRow r) => _intoHere ? r.inThere : r.inHere;
  bool _inTarget(CostDiffRow r) => _intoHere ? r.inHere : r.inThere;

  /// The target's lines for [r] that a replace takes off, or null when it
  /// cannot: one is drawn on the target's diagram.
  Set<String>? _replaceIds(CostDiffRow r) => typedLineIds(
    _targetSettings,
    _intoHere ? r.linesHere : r.linesThere,
    _intoHere ? r.laborHere : r.laborThere,
  );

  /// The target's parts [r] could go in place of: the same section, and
  /// not [r] itself.
  List<CostDiffRow> _swapChoices(CostDiffRow r) => [
    for (final t in _c.rows)
      if (t.section == r.section && _inTarget(t) && _rowKey(t) != _rowKey(r))
        t,
  ];

  /// The target part [r] replaces, if one was picked for it.
  CostDiffRow? _swapFor(CostDiffRow r) {
    if (!_replace || _inTarget(r)) return null;
    final key = _swaps[_rowKey(r)];
    if (key == null) return null;
    for (final t in _c.rows) {
      if (_rowKey(t) == key && _inTarget(t)) return t;
    }
    return null;
  }

  double _targetQty(CostDiffRow r) => _intoHere ? r.qtyHere : r.qtyThere;

  /// The models of [t]'s boxes on the target's AV Flow, lower case.
  List<String> _drawnModels(CostDiffRow t) => {
    for (final l in _intoHere ? t.linesHere : t.linesThere)
      ?drawnModelOfCostKey(l.key),
  }.toList();

  /// The catalog entry the source room's [r] is, for putting on a box.
  AvDeviceTemplate? _templateOf(CostDiffRow r) {
    final library = widget.provider.avDeviceLibrary;
    for (final l in _intoHere ? r.linesThere : r.linesHere) {
      final model = drawnModelOfCostKey(l.key) ?? l.model.trim();
      if (model.isEmpty) continue;
      final t = library.templateForModel(model);
      if (t != null) return t;
    }
    return null;
  }

  /// [t] is drawn on the target's AV Flow, and [r] can go on its boxes.
  bool _swapsOnDrawing(CostDiffRow r, CostDiffRow t) =>
      _replaceIds(t) == null &&
      _drawnModels(t).isNotEmpty &&
      _templateOf(r) != null;

  /// [r] can go in place of [t].
  bool _canSwap(CostDiffRow r, CostDiffRow t) =>
      _replaceIds(t) != null || _swapsOnDrawing(r, t);

  /// [r] is in both rooms in different numbers, and the target's one line
  /// can take the source's count. Null when it cannot.
  ({String key, double qty})? _qtyCopy(CostDiffRow r) {
    if (!_inSource(r) || !_inTarget(r)) return null;
    if (r.kind != CostDiffKind.qty && r.kind != CostDiffKind.qtyAndPrice) {
      return null;
    }
    final lines = _intoHere ? r.linesHere : r.linesThere;
    if (lines.length != 1) return null;
    final key = lines.single.key;
    final typed = {
      for (final i in [
        ..._targetSettings.extraEquipment,
        ..._targetSettings.extraHardware,
        ..._targetSettings.extraCables,
        ..._targetSettings.items,
      ])
        i.id,
    };
    if (!typed.contains(key) && drawnModelOfCostKey(key) == null) return null;
    return (key: key, qty: _intoHere ? r.qtyThere : r.qtyHere);
  }

  /// Gives the target the source's count on [rows].
  Future<void> _copyQtys(List<CostDiffRow> rows) async {
    final qtys = {
      for (final r in rows)
        if (_qtyCopy(r) case final c?) c.key: c.qty,
    };
    if (qtys.isEmpty) return;
    setState(() => _busy = true);
    final n = await widget.provider.setCostQtysInRoom(
      _intoHere ? '' : widget.thereConfigPath,
      qtys,
    );
    if (!mounted) return;
    if (n < 0) {
      setState(() {
        _busy = false;
        _done = '${widget.thereName}\'s cost file could not be written. '
            'No quantity was copied.';
      });
      return;
    }
    await _refresh();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _done = '$n quantit${n == 1 ? 'y' : 'ies'} copied into $_targetName.';
    });
  }

  /// The source room has it, and the target does not - or does, differently,
  /// and is being replaced.
  bool _canCopy(CostDiffRow r) {
    if (!_inSource(r)) return false;
    if (!_inTarget(r)) return true;
    return _replace && r.kind != CostDiffKind.same && _replaceIds(r) != null;
  }

  /// Both sides priced again after a copy.
  Future<void> _refresh() async {
    if (_intoHere) {
      _hereEstimate = widget.provider.roomCost;
    } else {
      final priced =
          await priceOtherRoom(widget.provider, widget.thereConfigPath);
      if (priced.estimate != null) {
        _thereEstimate = priced.estimate!;
        _thereSettings = priced.room.settings;
      }
    }
    if (!mounted) return;
    setState(() {
      _c = compareRoomCosts(_hereEstimate, _thereEstimate);
      _picked.clear();
      _swaps.clear();
    });
  }

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
    final provider = widget.provider;
    // A part drawn on the target's AV Flow is swapped on its boxes, which
    // then price as the new model; it is not added as a line as well.
    final onDrawing = <(CostDiffRow, CostDiffRow)>[
      for (final r in _pickedRows)
        if (_swapFor(r) case final t? when _swapsOnDrawing(r, t)) (r, t),
    ];
    final rows = [
      for (final r in _pickedRows)
        if (!onDrawing.any((p) => identical(p.$1, r))) r,
    ];
    final taken = <CostDiffRow>[
      for (final r in rows)
        if (_inTarget(r)) r else ?_swapFor(r),
    ];
    final replacing = <String>{for (final t in taken) ...?_replaceIds(t)};
    final set = costItemsFromRows(
      rows,
      source: _intoHere ? _thereSettings : widget.hereSettings,
      fromThere: _intoHere,
    );
    final (kept, skipped) = withoutExisting(
      set,
      target: _targetSettings,
      targetEstimate: _intoHere ? _hereEstimate : _thereEstimate,
      replacing: replacing,
    );
    if (kept.isEmpty && onDrawing.isEmpty) {
      setState(() => _done = 'Everything picked is already in $_targetName.');
      return;
    }
    final ok = await confirmCopyItems(
      context,
      provider,
      to: _targetName,
      items: kept,
      skipped: skipped,
      canUndo: _intoHere,
      replacing: replacing.length,
      takenOff: [
        for (final t in {for (final t in taken) _rowKey(t): t}.values)
          if (_replaceIds(t) != null)
            '${trimNumber(_targetQty(t))} x ${t.name}',
      ],
      swapped: [
        for (final (r, t) in onDrawing)
          '${trimNumber(_targetQty(t))} x ${t.name} becomes ${r.name}',
      ],
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    var boxes = 0;
    for (final (r, t) in onDrawing) {
      for (final model in _drawnModels(t)) {
        final done = await provider.swapModelInRoom(
          _intoHere ? '' : widget.thereConfigPath,
          model,
          _templateOf(r)!,
        );
        boxes += done.boxes;
      }
    }
    final n = kept.isEmpty
        ? 0
        : _intoHere
        ? provider.applyAvCostItems(kept,
            from: '${widget.thereName} items', replacing: replacing)
        : await provider.addCostItemsToRoomFile(
            widget.thereConfigPath, kept,
            replacing: replacing);
    if (!mounted) return;
    if (n < 0) {
      setState(() {
        _busy = false;
        _done = '${widget.thereName}\'s cost file could not be written. '
            'Nothing was copied.';
      });
      return;
    }
    await _refresh();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _done = [
        if (n > 0 || boxes == 0)
          '$n item${n == 1 ? '' : 's'} '
              '${replacing.isEmpty ? 'added to' : 'copied into'} $_targetName'
              '${replacing.isEmpty ? '' : ', replacing ${replacing.length}'}.',
        if (boxes > 0)
          '$boxes box${boxes == 1 ? '' : 'es'} on $_targetName\'s AV Flow '
              'swapped to the new model, cables kept.',
      ].join(' ');
    });
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
          onChanged: (v) => setState(() {
            if (v == true) {
              _picked.add(_rowKey(r));
            } else {
              _picked.remove(_rowKey(r));
              _swaps.remove(_rowKey(r));
            }
          }),
        );
      }
      return Tooltip(
        message: !_inSource(r)
            ? 'Not in ${_intoHere ? widget.thereName : widget.hereName}'
            : !_replace
            ? 'Already in $_targetName - tick Replace to copy over it'
            : r.kind == CostDiffKind.same
            ? 'The same in both rooms'
            : 'Drawn on $_targetName\'s diagram - change it there',
        child: const Checkbox(value: false, onChanged: null),
      );
    }

    // A part only the source has, put in place of a different one: the
    // other room's projector off, this room's on.
    Widget swap(CostDiffRow r) {
      final key = _rowKey(r);
      final chosen = _swapFor(r);
      final choices = _swapChoices(r);
      final link = small?.copyWith(color: theme.colorScheme.primary);
      return PopupMenuButton<String>(
        key: ValueKey('compare_swap_$key'),
        tooltip: 'Take one of $_targetName\'s parts off and put this on '
            'in its place',
        enabled: choices.isNotEmpty,
        onSelected: (v) => setState(() {
          if (v.isEmpty) {
            _swaps.remove(key);
          } else {
            _swaps[key] = v;
            _picked.add(key);
          }
        }),
        itemBuilder: (_) => [
          for (final t in choices)
            PopupMenuItem<String>(
              value: _rowKey(t),
              enabled: _canSwap(r, t),
              child: Text(
                '${trimNumber(_targetQty(t))} x ${t.name}'
                '${t.partNumber.isEmpty ? '' : ' (${t.partNumber})'}'
                '${_swapsOnDrawing(r, t) ? ' - swapped on the AV Flow' : ''}'
                '${_canSwap(r, t) ? '' : ' - drawn on the AV Flow, and '
                          '${r.name} is not in the catalog'}',
              ),
            ),
          if (chosen != null) ...[
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
                value: '', child: Text('Replace nothing')),
          ],
        ],
        child: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.swap_horiz, size: 14, color: link?.color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                chosen == null
                    ? (choices.isEmpty
                        ? 'Nothing in $_targetName to replace'
                        : 'Replace a part in $_targetName...')
                    : 'Replaces ${chosen.name} in $_targetName',
                style: link,
              ),
            ),
          ]),
        ),
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
              if (_replace && _inSource(r) && !_inTarget(r)) swap(r),
              if (_qtyCopy(r) case final c?)
                InkWell(
                    key: ValueKey('compare_qty_${_rowKey(r)}'),
                    onTap: _busy ? null : () => _copyQtys([r]),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.exposure, size: 14,
                            color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            'Copy quantity ${_qty(c.qty)} into $_targetName',
                            style: small?.copyWith(
                                color: theme.colorScheme.primary),
                          ),
                        ),
                      ]),
                    ),
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
              'room already has can be ticked only with Replace on. The '
              'window stays open to copy either way.',
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
                    _swaps.clear();
                  }),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      key: const ValueKey('compare_replace'),
                      value: _replace,
                      onChanged: (v) => setState(() {
                        _replace = v ?? false;
                        _swaps.clear();
                        _picked.removeWhere((k) => !copyable
                            .any((r) => _rowKey(r) == k && !_inTarget(r)));
                      }),
                    ),
                    Tooltip(
                      message: 'Parts both rooms have can be ticked too. The '
                          'copy takes the target\'s line off and puts this '
                          'one on in its place. A part only one room has can '
                          'go in place of a different one: pick it from '
                          'Replace a part.',
                      child: Text('Replace existing items', style: small),
                    ),
                  ],
                ),
                TextButton(
                  key: const ValueKey('compare_pick_all'),
                  onPressed: copyable.isEmpty
                      ? null
                      : () => setState(() => _picked
                        ..clear()
                        ..addAll(copyable.map(_rowKey))),
                  child: Text(_replace
                      ? 'Tick all ${copyable.length}'
                      : 'Tick all ${copyable.length} missing'),
                ),
                TextButton(
                  key: const ValueKey('compare_qty_all'),
                  onPressed: _busy ||
                          !c.rows.any((r) => _qtyCopy(r) != null)
                      ? null
                      : () => _copyQtys(c.rows),
                  child: Text(
                    'Copy all ${c.rows.where((r) => _qtyCopy(r) != null).length} '
                    'quantities',
                  ),
                ),
                TextButton(
                  onPressed:
                      _picked.isEmpty
                          ? null
                          : () => setState(() {
                              _picked.clear();
                              _swaps.clear();
                            }),
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
            if (_done.isNotEmpty)
              Text(
                _done,
                key: const ValueKey('compare_done'),
                style: bold?.copyWith(color: theme.colorScheme.primary),
              ),
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
          key: const ValueKey('compare_close'),
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(_done.isEmpty ? 'Close' : 'Done'),
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
/// cost items go into [to]. [skipped] are the ones [to] already has;
/// [replacing] how many of [to]'s lines come off for them.
Future<bool> confirmCopyItems(
  BuildContext context,
  AppStateProvider provider, {
  required String to,
  required CostItemSet items,
  int skipped = 0,
  bool canUndo = true,
  int replacing = 0,
  List<String> takenOff = const [],

  /// Boxes on [to]'s AV Flow that take a new model, cables kept.
  List<String> swapped = const [],
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
                    if (count > 0 || swapped.isEmpty)
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
                    if (swapped.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text('Swapped on the AV Flow in $to, cables kept',
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          )),
                      for (final line in swapped)
                        Padding(
                          padding: const EdgeInsets.only(left: 12, top: 2),
                          child: Text('• $line',
                              style: theme.textTheme.bodySmall),
                        ),
                    ],
                    if (takenOff.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text('Taken off $to',
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          )),
                      for (final line in takenOff)
                        Padding(
                          padding: const EdgeInsets.only(left: 12, top: 2),
                          child: Text('• $line',
                              style: theme.textTheme.bodySmall),
                        ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      [
                        replacing == 0
                            ? 'They are added without replacing any items.'
                            : 'They replace $replacing '
                                  'line${replacing == 1 ? '' : 's'} in $to.',
                        'Items that already exist are skipped'
                            '${skipped > 0 ? ' ($skipped here)' : ''}.',
                        canUndo
                            ? (replacing == 0
                                ? 'Undo removes them.'
                                : 'Undo puts the old lines back.')
                            : '$to is not open here, so Undo cannot take '
                                  'them back off - open it and change them.',
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
                child: Text(replacing == 0 && swapped.isEmpty
                    ? 'Add $count'
                    : 'Replace'),
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
