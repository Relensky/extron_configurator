import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'collapsible_bar.dart';
import 'diagram_capture.dart';
import 'av_device_library.dart';
import 'export_tools.dart';
import 'mount_spec.dart';
import 'room_locations.dart';
import 'screenshot_tools.dart';
import 'wall_elevation.dart';

/// ============================================================================
///  WALLS TAB
/// ============================================================================
///  A wall straight on, with a side section beside it, for working out where
///  a display, its mount and everything around it go. Drag to move; the panel
///  on the right types exact sizes and heights; the list under it is the
///  check. See wall_elevation.dart for the model and the rules.
/// ============================================================================

class WallElevationView extends StatefulWidget {
  const WallElevationView({super.key});

  @override
  State<WallElevationView> createState() => _WallElevationViewState();
}

class _WallElevationViewState extends State<WallElevationView> {
  final GlobalKey _captureKey = GlobalKey();
  final FocusNode _canvasFocus = FocusNode(debugLabel: 'wall canvas');

  String _wallId = '';
  String _itemId = '';

  /// The item being dragged, and how far, in inches.
  String _dragId = '';
  Offset _drag = Offset.zero;

  /// Snap for drags, inches.
  double _snap = 0.5;

  /// Drawn as the mounting layout; kept across visits to the tab.
  static bool _mounting = false;

  @override
  void initState() {
    super.initState();
    registerDiagramCanvas(AppTab.walls, _captureKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppStateProvider>().ensureAvFlowForCurrentConfig();
    });
  }

  @override
  void dispose() {
    unregisterDiagramCanvas(AppTab.walls, _captureKey);
    _canvasFocus.dispose();
    super.dispose();
  }

  WallView? _wall(AppStateProvider p) {
    final walls = p.avWallViews;
    if (walls.isEmpty) return null;
    return walls.where((w) => w.id == _wallId).firstOrNull ?? walls.first;
  }

  void _save(
    AppStateProvider p,
    WallView next,
    String label, {
    String coalesce = '',
  }) => p.updateWallView(next, label, coalesce: coalesce);

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    if (provider.roomConfig.isEmpty) {
      return const Center(child: Text('No configuration loaded.'));
    }
    final wall = _wall(provider);
    final folded = BarFolds.isFolded('walls_header');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PageTitle('Walls', folded: folded),
              FoldButton(
                id: 'walls_header',
                name: 'the wall buttons',
                onChanged: () => setState(() {}),
              ),
              if (!folded) ..._toolbar(provider, wall),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: wall == null
              ? _empty(provider)
              : _body(provider, wall),
        ),
      ],
    );
  }

  List<Widget> _toolbar(AppStateProvider p, WallView? wall) => [
    if (p.avWallViews.isNotEmpty)
      ToolGroup(
        header: const ToolGroupName('Wall'),
        children: [
          DropdownButton<String>(
            key: const ValueKey('wall_picker'),
            value: wall?.id,
            underline: const SizedBox.shrink(),
            items: [
              for (final w in p.avWallViews)
                DropdownMenuItem(value: w.id, child: Text(w.name)),
            ],
            onChanged: (id) => setState(() {
              _wallId = id ?? '';
              _itemId = '';
            }),
          ),
          IconButton(
            key: const ValueKey('wall_edit'),
            tooltip: 'Name, length and ceiling height',
            icon: const Icon(Icons.edit, size: 18),
            onPressed: wall == null ? null : () => _editWall(p, wall),
          ),
          IconButton(
            key: const ValueKey('wall_remove'),
            tooltip: 'Remove this wall',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: wall == null ? null : () => _removeWall(p, wall),
          ),
        ],
      ),
    OutlinedButton.icon(
      key: const ValueKey('wall_add'),
      icon: const Icon(Icons.add, size: 18),
      label: const Text('Add wall'),
      onPressed: () => _addWall(p),
    ),
    if (wall != null) _addItemButton(p, wall),
    if (wall != null)
      ToolGroup(
        header: const ToolGroupName('Snap'),
        children: [
          DropdownButton<double>(
            key: const ValueKey('wall_snap'),
            value: _snap,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 0.125, child: Text('1/8"')),
              DropdownMenuItem(value: 0.5, child: Text('1/2"')),
              DropdownMenuItem(value: 1.0, child: Text('1"')),
              DropdownMenuItem(value: 6.0, child: Text('6"')),
            ],
            onChanged: (v) => setState(() => _snap = v ?? 0.5),
          ),
        ],
      ),
    if (wall != null)
      SegmentedButton<bool>(
        key: const ValueKey('wall_view_mode'),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: false,
            icon: Icon(Icons.view_quilt_outlined, size: 18),
            label: Text('Elevation'),
            tooltip: 'The wall and everything on it, with the side section',
          ),
          ButtonSegment(
            value: true,
            icon: Icon(Icons.straighten, size: 18),
            label: Text('Mounting'),
            tooltip: 'Where each mount goes, dimensioned, with a schedule',
          ),
        ],
        selected: {_mounting},
        onSelectionChanged: (v) => setState(() => _mounting = v.first),
      ),
    if (wall != null)
      ElevatedButton.icon(
        key: const ValueKey('wall_export_png'),
        icon: const Icon(Icons.image, size: 18),
        label: const Text('Export PNG'),
        onPressed: () => _exportPng(p, wall),
      ),
  ];

  Widget _addItemButton(AppStateProvider p, WallView wall) {
    final groups = <String, List<WallItemPreset>>{};
    for (final preset in kWallItemPresets) {
      groups.putIfAbsent(preset.group, () => []).add(preset);
    }
    return PopupMenuButton<Object>(
      key: const ValueKey('wall_add_item'),
      tooltip: 'Put something on this wall',
      onSelected: (v) {
        if (v == 'catalog') {
          _addFromCatalog(p, wall);
          return;
        }
        if (v == 'qpro') {
          final next = withDisplayOnMount(
            wall,
            kNewlineQPro86,
            kNewlineTiltMount,
          );
          final added = next.items.firstWhere(
            (i) => i.kind == WallItemKind.display && !wall.items.contains(i),
            orElse: () => next.items.last,
          );
          _save(p, next, 'Add ${added.name} on its mount');
          setState(() => _itemId = added.id);
        } else if (v is WallItemPreset) {
          final item = placePreset(wall, v.item);
          _save(p, wall.withItem(item), 'Add ${item.name}');
          setState(() => _itemId = item.id);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem<Object>(
          key: ValueKey('wall_add_catalog'),
          value: 'catalog',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.inventory_2),
            title: Text('From the catalog...'),
          ),
        ),
        const PopupMenuItem<Object>(
          key: ValueKey('wall_add_qpro'),
          value: 'qpro',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.tv),
            title: Text('Newline Q Pro 86" on its tilt mount'),
          ),
        ),
        for (final g in groups.entries) ...[
          const PopupMenuDivider(),
          PopupMenuItem<Object>(
            enabled: false,
            height: 28,
            child: Text(
              g.key.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          for (final preset in g.value)
            PopupMenuItem<Object>(
              value: preset,
              child: ListTile(
                dense: true,
                leading: Icon(preset.item.kind.icon),
                title: Text(preset.name),
              ),
            ),
        ],
      ],
      child: const Chip(
        avatar: Icon(Icons.add_box_outlined, size: 18),
        label: Text('Add item'),
      ),
    );
  }

  Widget _empty(AppStateProvider p) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.tv, size: 48),
        const SizedBox(height: 12),
        const Text('No walls yet.'),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('wall_add_empty'),
          icon: const Icon(Icons.add),
          label: const Text('Add a wall'),
          onPressed: () => _addWall(p),
        ),
      ],
    ),
  );

  Widget _body(AppStateProvider p, WallView wall) {
    final shown = _preview(wall);
    final issues = checkWall(shown);
    final selected = shown.item(_itemId);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _canvas(p, wall, shown, issues)),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 360,
          child: ListView(
            // Its own padding drops the chat button's clearance; add it back.
            padding: EdgeInsets.fromLTRB(
              12,
              12,
              12,
              12 + MediaQuery.paddingOf(context).bottom,
            ),
            children: [
              _itemList(shown, issues),
              const SizedBox(height: 12),
              if (selected != null) ...[
                _ItemEditor(
                  key: ValueKey('wall_editor_${wall.id}_${selected.id}'),
                  wall: shown,
                  item: selected,
                  onChanged: (next, label, coalesce) => _save(
                    p,
                    wall.withItem(next),
                    label,
                    coalesce: coalesce,
                  ),
                  onRemove: () => _removeItem(p, wall, selected),
                  onDuplicate: () => _duplicate(p, wall, selected),
                  onWall: (next, label) => _save(p, next, label),
                  catalog: selected.model.trim().isEmpty
                      ? null
                      : p.avDeviceLibrary.templateForModel(selected.model),
                ),
                const SizedBox(height: 12),
              ],
              _issueList(p, wall, issues),
            ],
          ),
        ),
      ],
    );
  }

  /// [wall] with the drag in progress applied, so the check runs live.
  WallView _preview(WallView wall) {
    if (_dragId.isEmpty) return wall;
    final i = wall.item(_dragId);
    if (i == null) return wall;
    return wall.withItem(_moved(i, _drag, wall));
  }

  double _snapTo(double v) => (v / _snap).round() * _snap;

  WallItem _moved(WallItem i, Offset by, WallView wall) => i.copyWith(
    x: _snapTo(i.x + by.dx),
    y: math.max(0, _snapTo(i.y + by.dy)),
  );

  Widget _canvas(
    AppStateProvider p,
    WallView wall,
    WallView shown,
    List<WallIssue> issues,
  ) {
    return LayoutBuilder(
      builder: (context, box) {
        final layout = _WallLayout.fit(shown, box.biggest, mounting: _mounting);
        return Focus(
          focusNode: _canvasFocus,
          onKeyEvent: (_, e) => _onKey(p, wall, e),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              _canvasFocus.requestFocus();
              final hit = layout.hit(shown, d.localPosition);
              setState(() => _itemId = hit?.id ?? '');
            },
            onPanStart: (d) {
              _canvasFocus.requestFocus();
              var hit = layout.hit(shown, d.localPosition);
              if (hit == null) return;
              // A mount on a display moves with it.
              if (hit.kind == WallItemKind.mount) {
                hit = shown.displayOn(hit.id) ?? hit;
              }
              if (hit.locked) {
                setState(() => _itemId = hit!.id);
                return;
              }
              setState(() {
                _itemId = hit!.id;
                _dragId = hit.id;
                _drag = Offset.zero;
              });
            },
            onPanUpdate: (d) {
              if (_dragId.isEmpty) return;
              setState(() {
                _drag += Offset(
                  d.delta.dx / layout.scale,
                  -d.delta.dy / layout.scale,
                );
              });
            },
            onPanEnd: (_) {
              final i = wall.item(_dragId);
              if (i != null && _drag != Offset.zero) {
                final moved = _moved(i, _drag, wall);
                final hung = hangOnDrop(wall.withItem(moved), moved.id);
                if (hung != null) {
                  _save(p, hung.wall, hung.label);
                } else {
                  _save(p, wall.withItem(moved), 'Move ${i.name}');
                }
              }
              setState(() {
                _dragId = '';
                _drag = Offset.zero;
              });
            },
            child: RepaintBoundary(
              key: _captureKey,
              // Warning flags are for the screen; a saved picture leaves
              // them off.
              child: ValueListenableBuilder<bool>(
                valueListenable: capturingDiagram,
                builder: (context, capturing, _) => CustomPaint(
                  size: box.biggest,
                  painter: _WallElevationPainter(
                    wall: shown,
                    issues: issues,
                    selectedId: _itemId,
                    layout: layout,
                    mounting: _mounting,
                    flags: !capturing,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  KeyEventResult _onKey(AppStateProvider p, WallView wall, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    var i = wall.item(_itemId);
    if (i == null) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _itemId = '');
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.delete) {
      _removeItem(p, wall, i);
      return KeyEventResult.handled;
    }
    final step = HardwareKeyboard.instance.isShiftPressed ? 6.0 : _snap;
    final by = switch (e.logicalKey) {
      LogicalKeyboardKey.arrowLeft => Offset(-step, 0),
      LogicalKeyboardKey.arrowRight => Offset(step, 0),
      LogicalKeyboardKey.arrowUp => Offset(0, step),
      LogicalKeyboardKey.arrowDown => Offset(0, -step),
      _ => null,
    };
    if (by == null) return KeyEventResult.ignored;
    if (i.kind == WallItemKind.mount) i = wall.displayOn(i.id) ?? i;
    if (i.locked) return KeyEventResult.handled;
    _save(
      p,
      wall.withItem(i.copyWith(x: i.x + by.dx, y: math.max(0, i.y + by.dy))),
      'Nudge ${i.name}',
      coalesce: 'wall_nudge_${i.id}',
    );
    return KeyEventResult.handled;
  }

  Widget _itemList(WallView wall, List<WallIssue> issues) {
    final theme = Theme.of(context);
    final worst = _worstByItem(issues);
    final items = [...wall.items]..sort((a, b) => a.x.compareTo(b.x));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('On this wall', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        if (items.isEmpty)
          Text(
            'Nothing yet. Use Add item.',
            style: theme.textTheme.bodySmall,
          ),
        for (final i in items)
          InkWell(
            key: ValueKey('wall_item_row_${i.id}'),
            onTap: () => setState(() => _itemId = i.id),
            child: Container(
              color: i.id == _itemId
                  ? theme.colorScheme.primaryContainer
                  : null,
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
              child: Row(
                children: [
                  Icon(i.kind.icon, size: 16, color: i.kind.color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(i.name, overflow: TextOverflow.ellipsis),
                  ),
                  Text(
                    '${inchesLabel(i.y)} AFF',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (worst[i.id] case final level?) ...[
                    const SizedBox(width: 6),
                    _levelIcon(level, 16),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// The check: what clashes and fits, then the accessibility findings in a
  /// box of their own.
  Widget _issueList(AppStateProvider p, WallView wall, List<WallIssue> issues) {
    final theme = Theme.of(context);
    final general = [for (final i in issues) if (!i.access) i];
    final access = [for (final i in issues) if (i.access) i];

    Widget none() => Row(
      children: [
        const Icon(Icons.check_circle, color: Colors.green, size: 18),
        const SizedBox(width: 8),
        Text('Nothing found.', style: theme.textTheme.bodySmall),
      ],
    );

    Widget row(WallIssue issue) => InkWell(
      onTap: issue.itemIds.isEmpty
          ? null
          : () => setState(() => _itemId = issue.itemIds.first),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _levelIcon(issue.level, 18),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(issue.text, style: theme.textTheme.bodySmall),
                  if (issue.advice.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        issue.advice,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  if (issue.railFor.isNotEmpty)
                    TextButton.icon(
                      key: ValueKey('wall_add_cane_rail_${issue.railFor}'),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.horizontal_rule, size: 16),
                      label: const Text('Add cane rail'),
                      onPressed: () {
                        final next = withCaneRail(wall, issue.railFor);
                        final rail = next.items.last;
                        _save(p, next, 'Add a cane rail');
                        setState(() => _itemId = rail.id);
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Check', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        if (general.isEmpty) none(),
        for (final issue in general) row(issue),
        const SizedBox(height: 12),
        Container(
          key: const ValueKey('wall_access_box'),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.accessible, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Accessibility - ADA and California CBC 11B',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (access.isEmpty) none(),
              for (final issue in access) row(issue),
              const SizedBox(height: 4),
              Text(
                'Recommendations from the drawing, not a code review.',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _exportPng(AppStateProvider p, WallView wall) async {
    final messenger = ScaffoldMessenger.of(context);
    // Drawn without the selection.
    final was = _itemId;
    setState(() => _itemId = '');
    final bytes = await captureBoundary(_captureKey, pixelRatio: 2.0);
    if (mounted) setState(() => _itemId = was);
    if (bytes == null) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Nothing to export.'),
          backgroundColor: snackErrorFillOn(messenger),
        ),
      );
      return;
    }
    if (!mounted) return;
    final stem = wall.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    await showCapturedPicture(
      context,
      bytes,
      title: _mounting ? '${wall.name} mounting' : '${wall.name} as a picture',
      fileName: _mounting
          ? '${roomFileStem(p, 'wall_mounting_$stem')}.png'
          : '${roomFileStem(p, 'wall_$stem')}.png',
      what: _mounting ? 'The mounting layout' : 'The wall elevation',
    );
  }

  // --- walls ---------------------------------------------------------------

  Future<void> _addWall(AppStateProvider p) async {
    final got = await _wallDialog(context, p, title: 'Add a wall');
    if (got == null || !mounted) return;
    final id = p.addWallView(
      name: got.name,
      widthIn: got.widthIn,
      heightIn: got.heightIn,
    );
    setState(() {
      _wallId = id;
      _itemId = '';
    });
  }

  Future<void> _editWall(AppStateProvider p, WallView wall) async {
    final got = await _wallDialog(context, p, title: 'Edit wall', wall: wall);
    if (got == null || !mounted) return;
    _save(
      p,
      wall.copyWith(
        name: got.name.trim().isEmpty ? wall.name : got.name.trim(),
        widthIn: math.max(12, got.widthIn),
        heightIn: math.max(0, got.heightIn),
      ),
      'Edit ${wall.name}',
    );
  }

  Future<void> _removeWall(AppStateProvider p, WallView wall) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${wall.name}?'),
        content: Text(
          wall.items.isEmpty
              ? 'It has nothing on it.'
              : 'It has ${wall.items.length} item'
                  '${wall.items.length == 1 ? '' : 's'} on it. Undo puts it '
                  'back.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('wall_remove_confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    p.removeWallView(wall.id);
    setState(() {
      _wallId = '';
      _itemId = '';
    });
  }

  // --- items ---------------------------------------------------------------

  Future<void> _addFromCatalog(AppStateProvider p, WallView wall) async {
    final picked = await showDialog<AvDeviceTemplate>(
      context: context,
      builder: (context) => _CatalogPicker(library: p.avDeviceLibrary),
    );
    if (picked == null || !mounted) return;
    final spec = picked.mounting!;
    final item = placePreset(
      wall,
      wallItemFromSpec(
        spec.hasSize ? spec : withStandInSize(spec),
        model: picked.model,
        label: picked.model,
        weightLb: picked.weightLbs,
      ),
    );
    _save(p, wall.withItem(item), 'Add ${item.name}');
    setState(() => _itemId = item.id);
  }

  void _removeItem(AppStateProvider p, WallView wall, WallItem i) {
    _save(p, wall.withoutItem(i.id), 'Remove ${i.name}');
    setState(() => _itemId = '');
  }

  void _duplicate(AppStateProvider p, WallView wall, WallItem i) {
    final copy = i.copyWith(
      id: wall.nextItemId(),
      x: i.x + 6,
      mountId: '',
      standoff: i.mountId.isEmpty ? i.standoff : 0,
      locked: false,
    );
    _save(p, wall.withItem(copy), 'Copy ${i.name}');
    setState(() => _itemId = copy.id);
  }
}

/// A VESA pattern as a dropdown value.
String _vesaKey(double w, double h) => '${w.round()}x${h.round()}';

Map<String, WallIssueLevel> _worstByItem(List<WallIssue> issues) {
  final out = <String, WallIssueLevel>{};
  for (final issue in issues) {
    for (final id in issue.itemIds) {
      final was = out[id];
      if (was == null || issue.level.index < was.index) out[id] = issue.level;
    }
  }
  return out;
}

Color _levelColor(WallIssueLevel level) => switch (level) {
  WallIssueLevel.problem => const Color(0xFFD32F2F),
  WallIssueLevel.warning => const Color(0xFFEF6C00),
  WallIssueLevel.note => const Color(0xFF1976D2),
};

Widget _levelIcon(WallIssueLevel level, double size) => Icon(
  switch (level) {
    WallIssueLevel.problem => Icons.error,
    WallIssueLevel.warning => Icons.warning_amber,
    WallIssueLevel.note => Icons.info_outline,
  },
  size: size,
  color: _levelColor(level),
);

// ---------------------------------------------------------------------------
//  THE WALL DIALOG
// ---------------------------------------------------------------------------

typedef _WallSize = ({String name, double widthIn, double heightIn});

/// A wall the floor plan already knows, for filling in the dialog.
typedef _PlanWall = ({String label, String name, double widthIn, double heightIn});

List<_PlanWall> _planWalls(AppStateProvider p) {
  final out = <_PlanWall>[];
  for (final plan in p.avFloorPlans) {
    final walls = plan.walls;
    final ppf = plan.pixelsPerFoot;
    if (walls == null || ppf <= 0) continue;
    for (final e in walls.named.entries) {
      final along = e.value == PlanWallSide.top || e.value == PlanWallSide.bottom
          ? walls.rect.width
          : walls.rect.height;
      out.add((
        label: '${e.key} wall, ${plan.name}',
        name: '${e.key} wall',
        widthIn: (along / ppf * 12 * 2).round() / 2,
        heightIn: walls.ceilingFt * 12,
      ));
    }
  }
  return out;
}

Future<_WallSize?> _wallDialog(
  BuildContext context,
  AppStateProvider p, {
  required String title,
  WallView? wall,
}) {
  final name = TextEditingController(text: wall?.name ?? 'Front wall');
  final width = TextEditingController(
    text: wall == null ? "20'" : inchesLabel(wall.widthIn),
  );
  final height = TextEditingController(
    text: wall == null
        ? "9'"
        : wall.heightIn > 0
            ? inchesLabel(wall.heightIn)
            : '',
  );
  final fromPlan = _planWalls(p);
  return showDialog<_WallSize>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final w = parseInchesText(width.text);
        final h = height.text.trim().isEmpty ? 0.0 : parseInchesText(height.text);
        final ok = w != null && w >= 12 && h != null && h >= 0;
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (fromPlan.isNotEmpty) ...[
                  DropdownButtonFormField<int>(
                    key: const ValueKey('wall_from_plan'),
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'From the floor plan',
                    ),
                    items: [
                      for (var i = 0; i < fromPlan.length; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Text(fromPlan[i].label),
                        ),
                    ],
                    onChanged: (i) {
                      if (i == null) return;
                      final pw = fromPlan[i];
                      setState(() {
                        name.text = pw.name;
                        width.text = inchesLabel(pw.widthIn);
                        height.text =
                            pw.heightIn > 0 ? inchesLabel(pw.heightIn) : '';
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                ],
                TextField(
                  key: const ValueKey('wall_name'),
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                TextField(
                  key: const ValueKey('wall_width'),
                  controller: width,
                  decoration: const InputDecoration(
                    labelText: 'Length',
                    helperText: 'Inches, or feet and inches: 240, 20\', 19\' 6"',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  key: const ValueKey('wall_height'),
                  controller: height,
                  decoration: const InputDecoration(
                    labelText: 'Floor to ceiling',
                    helperText: 'Blank when not known',
                  ),
                  onChanged: (_) => setState(() {}),
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
              key: const ValueKey('wall_dialog_ok'),
              onPressed: ok
                  ? () => Navigator.pop(context, (
                      name: name.text,
                      widthIn: w,
                      heightIn: h,
                    ))
                  : null,
              child: const Text('OK'),
            ),
          ],
        );
      },
    ),
  );
}

// ---------------------------------------------------------------------------
//  THE ITEM EDITOR
// ---------------------------------------------------------------------------

class _ItemEditor extends StatelessWidget {
  final WallView wall;
  final WallItem item;
  final void Function(WallItem next, String label, String coalesce) onChanged;
  final VoidCallback onRemove;
  final VoidCallback onDuplicate;

  /// For an edit that touches more than this item.
  final void Function(WallView next, String label) onWall;

  /// The catalog product it was added from, when there is one.
  final AvDeviceTemplate? catalog;

  const _ItemEditor({
    super.key,
    required this.wall,
    required this.item,
    required this.onChanged,
    required this.onRemove,
    required this.onDuplicate,
    required this.onWall,
    this.catalog,
  });

  /// [m]'s own settings: on a display's panel with its size too, on the
  /// mount's own panel without (its Size section has them).
  List<Widget> _mountSize(
    WallItem m,
    Widget Function(Widget, Widget) pair,
  ) {
    final onDisplay = m.id != item.id;
    Widget num(
      String field,
      String label,
      double value,
      WallItem Function(double v) apply, {
      bool inches = true,
    }) => _NumField(
      key: ValueKey('wall_mount_$field'),
      label: label,
      value: value,
      inches: inches,
      enabled: !m.locked,
      onCommit: (v) => onChanged(
        apply(math.max(0, v)),
        'Set ${m.name} $field',
        'wall_${wall.id}_${m.id}_$field',
      ),
    );

    // The largest pattern it takes, from the standard sizes.
    final largest = _vesaKey(m.vesaW, m.vesaH);
    final vesaPicker = DropdownButtonFormField<String>(
      key: const ValueKey('wall_mount_vesa_preset'),
      isExpanded: true,
      initialValue: largest,
      decoration: const InputDecoration(labelText: 'Largest VESA it takes'),
      items: [
        for (final (w, h) in kVesaPatterns)
          DropdownMenuItem(
            value: _vesaKey(w, h),
            child: Text(w > 0 ? '${w.round()} x ${h.round()} mm' : 'Not set'),
          ),
        if (!kVesaPatterns.any((p) => _vesaKey(p.$1, p.$2) == largest))
          DropdownMenuItem(
            value: largest,
            child: Text(vesaLabel(m.vesaW, m.vesaH).isEmpty
                ? 'Not set'
                : vesaLabel(m.vesaW, m.vesaH)),
          ),
      ],
      onChanged: m.locked
          ? null
          : (v) {
              final p = kVesaPatterns
                  .where((p) => _vesaKey(p.$1, p.$2) == v)
                  .firstOrNull;
              if (p == null) return;
              onChanged(
                m.copyWith(vesaW: p.$1, vesaH: p.$2),
                'Set ${m.name} VESA',
                '',
              );
            },
    );

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
    );

    return [
      heading('What it takes'),
      pair(
        num('capacity', 'Holds up to, lb', m.capacityLb,
            (v) => m.copyWith(capacityLb: v),
            inches: false),
        num('maxTilt', 'Tilts, degrees', m.maxTiltDeg,
            (v) => m.copyWith(maxTiltDeg: v),
            inches: false),
      ),
      vesaPicker,
      pair(
        num('vesaW', 'Largest VESA wide, mm', m.vesaW,
            (v) => m.copyWith(vesaW: v),
            inches: false),
        num('vesaH', 'Largest VESA high, mm', m.vesaH,
            (v) => m.copyWith(vesaH: v),
            inches: false),
      ),
      pair(
        num('vesaMinW', 'Smallest VESA wide, mm', m.vesaMinW,
            (v) => m.copyWith(vesaMinW: v),
            inches: false),
        num('vesaMinH', 'Smallest VESA high, mm', m.vesaMinH,
            (v) => m.copyWith(vesaMinH: v),
            inches: false),
      ),
      heading('Plate and arms'),
      if (onDisplay) ...[
        pair(
          num('w', 'Mount width', m.width, (v) => m.copyWith(width: math.max(0.1, v))),
          num('h', 'Arm length', m.height, (v) => m.copyWith(height: math.max(0.1, v))),
        ),
        pair(
          num('d', 'Off the wall', m.depth, (v) => m.copyWith(depth: v)),
          num('plateH', 'Wall plate height', m.plateHeight,
              (v) => m.copyWith(plateHeight: v)),
        ),
      ] else
        num('plateH', 'Wall plate height', m.plateHeight,
            (v) => m.copyWith(plateHeight: v)),
      pair(
        num('armW', 'Arm width', m.armWidth, (v) => m.copyWith(armWidth: v)),
        const SizedBox.shrink(),
      ),
      pair(
        num('armMin', 'Arms apart, least', m.armSpanMin,
            (v) => m.copyWith(armSpanMin: v)),
        num('armMax', 'Arms apart, most', m.armSpanMax,
            (v) => m.copyWith(armSpanMax: v)),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i = item;
    final onMount = i.kind == WallItemKind.display &&
        i.mountId.isNotEmpty &&
        wall.item(i.mountId) != null;
    final hungOn = i.kind == WallItemKind.mount ? wall.displayOn(i.id) : null;
    void set(WallItem next, String field) => onChanged(
      next,
      'Set ${i.name} $field',
      'wall_${wall.id}_${i.id}_$field',
    );

    Widget num(
      String field,
      String label,
      double value,
      WallItem Function(double v) apply, {
      bool enabled = true,
      bool inches = true,
      double min = 0,
    }) => _NumField(
      key: ValueKey('wall_field_$field'),
      label: label,
      value: value,
      inches: inches,
      enabled: enabled && !i.locked,
      onCommit: (v) => set(apply(math.max(min, v)), field),
    );

    Widget pair(Widget a, Widget b) => Row(
      children: [
        Expanded(child: a),
        const SizedBox(width: 8),
        Expanded(child: b),
      ],
    );

    final mounts = [
      for (final m in wall.items)
        if (m.kind == WallItemKind.mount &&
            (wall.displayOn(m.id) == null || m.id == i.mountId))
          m,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(i.kind.icon, color: i.kind.color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(i.name, style: theme.textTheme.titleSmall),
            ),
            IconButton(
              key: const ValueKey('wall_item_lock'),
              tooltip: i.locked ? 'Unlock' : 'Lock in place',
              icon: Icon(i.locked ? Icons.lock : Icons.lock_open, size: 18),
              onPressed: () => onChanged(
                i.copyWith(locked: !i.locked),
                i.locked ? 'Unlock ${i.name}' : 'Lock ${i.name}',
                '',
              ),
            ),
            IconButton(
              key: const ValueKey('wall_item_duplicate'),
              tooltip: 'Copy',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: onDuplicate,
            ),
            IconButton(
              key: const ValueKey('wall_item_remove'),
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: onRemove,
            ),
          ],
        ),
        _TextFieldRow(
          key: const ValueKey('wall_field_label'),
          label: 'Name',
          value: i.label,
          onCommit: (v) => set(i.copyWith(label: v), 'name'),
        ),
        _TextFieldRow(
          key: const ValueKey('wall_field_model'),
          label: 'Model',
          value: i.model,
          onCommit: (v) => set(i.copyWith(model: v), 'model'),
        ),
        if (catalog?.mounting case final spec? when spec.hasSize &&
            differsFromSpec(i, spec, weightLb: catalog!.weightLbs))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Its sizes differ from the catalog\'s ${catalog!.model}.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  key: const ValueKey('wall_use_catalog'),
                  onPressed: i.locked
                      ? null
                      : () => onChanged(
                            withSpecSizes(i, spec, weightLb: catalog!.weightLbs),
                            'Use the catalog sizes for ${i.name}',
                            '',
                          ),
                  child: const Text('Use catalog sizes'),
                ),
              ],
            ),
          ),
        DropdownButtonFormField<WallItemKind>(
          key: const ValueKey('wall_field_kind'),
          isExpanded: true,
          initialValue: i.kind,
          decoration: const InputDecoration(labelText: 'Kind'),
          items: [
            for (final k in WallItemKind.values)
              DropdownMenuItem(value: k, child: Text(k.label)),
          ],
          onChanged: (k) {
            if (k == null || k == i.kind) return;
            onChanged(
              i.copyWith(
                kind: k,
                mountId: k == WallItemKind.display ? i.mountId : '',
              ),
              'Make ${i.name} a ${k.label.toLowerCase()}',
              '',
            );
          },
        ),
        const SizedBox(height: 8),
        Text('Where', style: theme.textTheme.labelLarge),
        pair(
          num('x', 'From the left end', i.x, (v) => i.copyWith(x: v),
              enabled: hungOn == null, min: -10000),
          num(
            'right',
            'From the right end',
            wall.widthIn - i.right,
            (v) => i.copyWith(x: wall.widthIn - v - i.width),
            enabled: hungOn == null,
            min: -10000,
          ),
        ),
        pair(
          num('y', 'Bottom above floor', i.y, (v) => i.copyWith(y: v),
              enabled: hungOn == null),
          num(
            'center',
            'Center above floor',
            i.centerY,
            (v) => i.copyWith(y: v - i.height / 2),
            enabled: hungOn == null,
          ),
        ),
        pair(
          num(
            'topAff',
            'Top above floor',
            i.top,
            (v) => i.copyWith(y: v - i.height),
            enabled: hungOn == null,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('wall_item_center'),
              icon: const Icon(Icons.align_horizontal_center, size: 18),
              label: const Text('Center on wall'),
              onPressed: hungOn != null || i.locked
                  ? null
                  : () => onChanged(
                        i.copyWith(x: (wall.widthIn - i.width) / 2),
                        'Center ${i.name}',
                        '',
                      ),
            ),
          ),
        ),
        if (hungOn != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Hangs ${hungOn.name}: it moves with it.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 8),
        Text('Size', style: theme.textTheme.labelLarge),
        pair(
          num('w', 'Width', i.width, (v) => i.copyWith(width: v), min: 0.1),
          num('h', 'Height', i.height, (v) => i.copyWith(height: v), min: 0.1),
        ),
        pair(
          num('d', 'Depth', i.depth, (v) => i.copyWith(depth: v)),
          num(
            'standoff',
            'Back off the wall',
            i.standoff,
            (v) => i.copyWith(standoff: v),
            enabled: !onMount,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Sticks out ${inchesLabel(i.front)} from the wall.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        if (i.kind == WallItemKind.display) ...[
          const SizedBox(height: 8),
          Text('VESA', style: theme.textTheme.labelLarge),
          DropdownButtonFormField<String>(
            key: const ValueKey('wall_field_vesa_preset'),
            isExpanded: true,
            initialValue: _vesaKey(i.vesaW, i.vesaH),
            decoration: const InputDecoration(labelText: 'Pattern'),
            items: [
              for (final (w, h) in kVesaPatterns)
                DropdownMenuItem(
                  value: _vesaKey(w, h),
                  child: Text(w > 0 ? '${w.round()} x ${h.round()} mm' : 'None'),
                ),
              if (!kVesaPatterns.any((p) => _vesaKey(p.$1, p.$2) == _vesaKey(i.vesaW, i.vesaH)))
                DropdownMenuItem(
                  value: _vesaKey(i.vesaW, i.vesaH),
                  child: Text(i.vesaW > 0
                      ? '${i.vesaW.round()} x ${i.vesaH.round()} mm'
                      : 'None'),
                ),
            ],
            onChanged: i.locked
                ? null
                : (v) {
                    final p = kVesaPatterns
                        .where((p) => _vesaKey(p.$1, p.$2) == v)
                        .firstOrNull;
                    if (p == null) return;
                    onChanged(
                      i.copyWith(vesaW: p.$1, vesaH: p.$2),
                      'Set ${i.name} VESA',
                      '',
                    );
                  },
          ),
          pair(
            num('vesaW', 'Wide, mm', i.vesaW, (v) => i.copyWith(vesaW: v),
                inches: false),
            num('vesaH', 'High, mm', i.vesaH, (v) => i.copyWith(vesaH: v),
                inches: false),
          ),
          pair(
            num(
              'vesaHoleLeft',
              'Left holes in from its left',
              i.vesaCenterX - i.x - i.vesaWIn / 2,
              (v) => i.copyWith(vesaLeft: math.max(0.01, v + i.vesaWIn / 2)),
            ),
            num(
              'vesaHoleUp',
              'Low holes up from its bottom',
              i.vesaCenterY - i.y - i.vesaHIn / 2,
              (v) => i.copyWith(vesaUp: math.max(0.01, v + i.vesaHIn / 2)),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  i.vesaW > 0
                      ? 'Holes ${inchesLabel(i.vesaWIn)} apart across, '
                          '${inchesLabel(i.vesaHIn)} up and down; center '
                          '${inchesLabel(i.vesaCenterX - i.x)} from its left, '
                          '${inchesLabel(i.vesaCenterY - i.y)} up.'
                      : 'No VESA pattern set.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              TextButton(
                key: const ValueKey('wall_vesa_center'),
                onPressed: i.locked || (i.vesaLeft == 0 && i.vesaUp == 0)
                    ? null
                    : () => onChanged(
                          i.copyWith(vesaLeft: 0, vesaUp: 0),
                          'Center ${i.name} VESA',
                          '',
                        ),
                child: const Text('Center it'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Mount', style: theme.textTheme.labelLarge),
          DropdownButtonFormField<String>(
            key: const ValueKey('wall_field_mount'),
            isExpanded: true,
            initialValue: onMount ? i.mountId : '',
            decoration: const InputDecoration(labelText: 'Hangs on'),
            items: [
              const DropdownMenuItem(value: '', child: Text('Nothing')),
              for (final m in mounts)
                DropdownMenuItem(value: m.id, child: Text(m.name)),
              for (final p in kWallItemPresets)
                if (p.item.kind == WallItemKind.mount)
                  DropdownMenuItem(
                    value: 'new:${p.name}',
                    child: Text('New: ${p.name}'),
                  ),
            ],
            onChanged: (id) {
              final v = id ?? '';
              if (v.startsWith('new:')) {
                final p = kWallItemPresets.firstWhere(
                  (p) => p.name == v.substring(4),
                );
                final m = placePreset(wall, p.item);
                onWall(
                  wall
                      .withItem(m)
                      .withItem(i.copyWith(mountId: m.id)),
                  'Hang ${i.name} on a new ${m.name}',
                );
                return;
              }
              onChanged(
                i.copyWith(mountId: v, standoff: v.isEmpty ? 0 : i.standoff),
                v.isEmpty
                    ? 'Take ${i.name} off its mount'
                    : 'Hang ${i.name} on its mount',
                '',
              );
            },
          ),
          if (onMount) ..._mountSize(wall.item(i.mountId)!, pair),
          pair(
            num('tilt', 'Tilt, degrees', i.tiltDeg, (v) => i.copyWith(tiltDeg: v),
                inches: false, min: -45),
            num('lb', 'Weight, lb', i.weightLb, (v) => i.copyWith(weightLb: v),
                inches: false),
          ),
        ],
        if (i.kind == WallItemKind.mount) ...[
          const SizedBox(height: 8),
          Text('Mount', style: theme.textTheme.labelLarge),
          DropdownButtonFormField<String>(
            key: const ValueKey('wall_field_holds'),
            isExpanded: true,
            initialValue: hungOn?.id ?? '',
            decoration: const InputDecoration(
              labelText: 'Holds',
              helperText: 'Or drag the mount onto a display',
            ),
            items: [
              const DropdownMenuItem(value: '', child: Text('Nothing')),
              for (final d in wall.items)
                if (d.kind == WallItemKind.display &&
                    (d.mountId.isEmpty ||
                        d.mountId == i.id ||
                        wall.item(d.mountId) == null))
                  DropdownMenuItem(value: d.id, child: Text(d.name)),
            ],
            onChanged: i.locked
                ? null
                : (id) {
                    final next = hangMount(wall, i.id, id ?? '');
                    final d = wall.item(id ?? '');
                    onWall(
                      next,
                      d == null
                          ? 'Take ${i.name} off ${hungOn?.name ?? 'its display'}'
                          : 'Hang ${d.name} on ${i.name}',
                    );
                  },
          ),
          ..._mountSize(i, pair),
        ],
        if (i.kind.showsImage || i.touch || i.kind == WallItemKind.touchPanel) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            key: const ValueKey('wall_field_touch'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Touch'),
            subtitle: const Text('Checked against the 15" to 48" reach range'),
            value: i.touch,
            onChanged: i.locked
                ? null
                : (v) => onChanged(
                      i.copyWith(touch: v),
                      v ? 'Make ${i.name} touch' : 'Make ${i.name} non-touch',
                      '',
                    ),
          ),
          pair(
            num('activeW', 'Picture width', i.activeW,
                (v) => i.copyWith(activeW: v)),
            num('activeH', 'Picture height', i.activeH,
                (v) => i.copyWith(activeH: v)),
          ),
          num('activeUp', 'Picture bottom above its frame bottom', i.activeUp,
              (v) => i.copyWith(activeUp: v)),
        ],
        const SizedBox(height: 8),
        _TextFieldRow(
          key: const ValueKey('wall_field_note'),
          label: 'Note',
          value: i.note,
          maxLines: 3,
          onCommit: (v) => set(i.copyWith(note: v), 'note'),
        ),
      ],
    );
  }
}

/// Catalog products with wall mounting sizes, searchable.
class _CatalogPicker extends StatefulWidget {
  final AvDeviceLibrary library;
  const _CatalogPicker({required this.library});

  @override
  State<_CatalogPicker> createState() => _CatalogPickerState();
}

class _CatalogPickerState extends State<_CatalogPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Anything with sizes, and anything set as a display or wall mount.
    final sized = [
      for (final t in widget.library.all)
        if (t.mounting case final m?
            when m.hasSize || m.role != MountRole.other)
          t,
    ];
    final shown = _query.trim().isEmpty
        ? (sized..sort((a, b) => a.model.toLowerCase().compareTo(b.model.toLowerCase())))
        : searchCatalog(sized, _query);
    return AlertDialog(
      title: const Text('Add from the catalog'),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('wall_catalog_search'),
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Model, maker or part number',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        sized.isEmpty
                            ? 'No catalog product is set as a display or wall '
                                'mount yet. Set it on the Catalog tab, under '
                                'Wall mounting.'
                            : 'Nothing matches.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  : ListView(
                      children: [
                        for (final t in shown)
                          ListTile(
                            key: ValueKey('wall_catalog_${t.model}'),
                            dense: true,
                            leading: Icon(
                              t.mounting!.role == MountRole.mount
                                  ? Icons.vertical_split
                                  : t.mounting!.role == MountRole.display
                                      ? Icons.tv
                                      : Icons.crop_square,
                            ),
                            title: Text(t.model),
                            subtitle: Text(
                              t.mounting!.hasSize
                                  ? t.mounting!.summary
                                  : '${t.mounting!.role.label}, no size in '
                                      'the catalog yet: placed at a stand-in '
                                      'size',
                            ),
                            onTap: () => Navigator.pop(context, t),
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
      ],
    );
  }
}

/// A length or number that commits on Enter or on leaving the field.
class _NumField extends StatefulWidget {
  final String label;
  final double value;
  final bool inches;
  final bool enabled;
  final ValueChanged<double> onCommit;

  const _NumField({
    super.key,
    required this.label,
    required this.value,
    required this.onCommit,
    this.inches = true,
    this.enabled = true,
  });

  @override
  State<_NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<_NumField> {
  late final TextEditingController _text =
      TextEditingController(text: _show(widget.value));
  final FocusNode _focus = FocusNode();
  bool _bad = false;

  String _show(double v) {
    if (!widget.inches) {
      return v.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
    }
    final s = v.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
    return '$s"';
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_NumField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && old.value != widget.value) {
      _text.text = _show(widget.value);
      _bad = false;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final raw = _text.text;
    final v = widget.inches
        ? parseInchesText(raw)
        : double.tryParse(raw.trim().replaceAll(RegExp(r'[^0-9.\-]'), ''));
    if (v == null || !v.isFinite) {
      setState(() => _bad = raw.trim().isNotEmpty);
      return;
    }
    setState(() => _bad = false);
    if ((v - widget.value).abs() > 1e-6) widget.onCommit(v);
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _text,
    focusNode: _focus,
    enabled: widget.enabled,
    decoration: InputDecoration(
      labelText: widget.label,
      isDense: true,
      errorText: _bad ? 'Not a number' : null,
    ),
    onSubmitted: (_) => _commit(),
  );
}

/// Text that commits on Enter or on leaving the field.
class _TextFieldRow extends StatefulWidget {
  final String label;
  final String value;
  final int maxLines;
  final ValueChanged<String> onCommit;

  const _TextFieldRow({
    super.key,
    required this.label,
    required this.value,
    required this.onCommit,
    this.maxLines = 1,
  });

  @override
  State<_TextFieldRow> createState() => _TextFieldRowState();
}

class _TextFieldRowState extends State<_TextFieldRow> {
  late final TextEditingController _text =
      TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(_TextFieldRow old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && old.value != widget.value) {
      _text.text = widget.value;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    if (_text.text != widget.value) widget.onCommit(_text.text);
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _text,
    focusNode: _focus,
    maxLines: widget.maxLines,
    minLines: 1,
    decoration: InputDecoration(labelText: widget.label, isDense: true),
    onSubmitted: (_) => _commit(),
  );
}

// ---------------------------------------------------------------------------
//  THE DRAWING
// ---------------------------------------------------------------------------

/// Where the elevation and the section sit on the canvas, and the scale.
@immutable
class _WallLayout {
  /// Pixels per inch.
  final double scale;

  /// The elevation's floor at the wall's left end, in pixels.
  final Offset origin;

  /// The section's wall face, in pixels along x.
  final double sectionX;

  /// How deep the section is drawn, inches.
  final double sectionDepth;

  /// The drawing's height in inches.
  final double tallest;

  /// The side area holds the mounting schedule instead of the section.
  final bool mounting;

  const _WallLayout({
    required this.scale,
    required this.origin,
    required this.sectionX,
    required this.sectionDepth,
    required this.tallest,
    this.mounting = false,
  });

  /// The mounting schedule's width, pixels.
  static const double scheduleWidth = 280;

  static const double _left = 56, _right = 24, _top = 36, _bottom = 52;
  static const double _gap = 72;

  factory _WallLayout.fit(WallView wall, Size size, {bool mounting = false}) {
    var front = 0.0;
    var top = wall.heightIn > 0 ? wall.heightIn : 96.0;
    for (final i in wall.items) {
      front = math.max(front, i.front);
      top = math.max(top, i.top);
    }
    final sectionDepth = math.max(30.0, front + 14);
    final tallest = top + 6;
    final across = mounting ? wall.widthIn : wall.widthIn + sectionDepth;
    final availW = math.max(
      40.0,
      size.width - _left - _right - _gap - (mounting ? scheduleWidth : 0),
    );
    final availH = math.max(40.0, size.height - _top - _bottom);
    final scale = math.max(0.2, math.min(availW / across, availH / tallest));
    final origin = Offset(_left, _top + tallest * scale);
    return _WallLayout(
      scale: scale,
      origin: origin,
      sectionX: _left + wall.widthIn * scale + _gap,
      sectionDepth: sectionDepth,
      tallest: tallest,
      mounting: mounting,
    );
  }

  /// A point on the elevation.
  Offset at(double x, double y) =>
      Offset(origin.dx + x * scale, origin.dy - y * scale);

  /// A point on the section, [d] out from the wall.
  Offset side(double d, double y) =>
      Offset(sectionX + d * scale, origin.dy - y * scale);

  Rect rectOf(Rect r) => Rect.fromPoints(at(r.left, r.top), at(r.right, r.bottom));

  /// The item under [p]: the frontmost on the elevation, or on the section.
  WallItem? hit(WallView wall, Offset p) {
    final x = (p.dx - origin.dx) / scale;
    final y = (origin.dy - p.dy) / scale;
    WallItem? best;
    for (final i in wall.items) {
      if (x < i.x || x > i.right || y < i.y || y > i.top) continue;
      if (best == null ||
          i.front > best.front ||
          (i.front == best.front && i.width * i.height < best.width * best.height)) {
        best = i;
      }
    }
    if (best != null || mounting) return best;
    final d = (p.dx - sectionX) / scale;
    for (final i in wall.items) {
      if (d >= i.back - 0.5 && d <= i.front + 0.5 && y >= i.y && y <= i.top) {
        return i;
      }
    }
    return null;
  }
}

/// Draws the wall straight on and its section, with the selected item's
/// dimensions and the clashes outlined.
class _WallElevationPainter extends CustomPainter {
  final WallView wall;
  final List<WallIssue> issues;
  final String selectedId;
  final _WallLayout layout;

  /// Drawn as the mounting layout: mounts called out, the rest faint.
  final bool mounting;

  /// Problems and warnings flagged on the drawing.
  final bool flags;

  _WallElevationPainter({
    required this.wall,
    required this.issues,
    required this.selectedId,
    required this.layout,
    this.mounting = false,
    this.flags = true,
  });

  static const Color _paper = Color(0xFFFFFFFF);
  static const Color _ink = Color(0xFF37474F);
  static const Color _faint = Color(0xFFECEFF1);
  static const Color _select = Color(0xFF1565C0);
  static const Color _callout = Color(0xFFD84315);
  static const Color _ghost = Color(0xFFB0BEC5);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _paper);
    _paintWall(canvas);
    if (mounting) {
      _paintMounting(canvas);
      final sel = wall.item(selectedId);
      if (sel != null) {
        canvas.drawRect(
          layout.rectOf(sel.face).inflate(3),
          Paint()
            ..color = _select
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
      if (flags) _paintFlags(canvas, size);
      return;
    }
    final worst = _worstByItem(issues);
    final order = [...wall.items]..sort((a, b) {
      final byBack = a.back.compareTo(b.back);
      return byBack != 0 ? byBack : (b.width * b.height).compareTo(a.width * a.height);
    });
    for (final i in order) {
      _paintItem(canvas, i);
    }
    // Hidden lines: anything with something in front of it.
    for (final i in order) {
      if (_covered(i)) _paintHidden(canvas, i);
    }
    for (final i in order) {
      final level = worst[i.id];
      if (level == null || level == WallIssueLevel.note) continue;
      canvas.drawRect(
        layout.rectOf(i.face).inflate(1.5),
        Paint()
          ..color = _levelColor(level)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
    _paintSection(canvas, worst);
    final sel = wall.item(selectedId);
    if (sel != null) _paintSelected(canvas, sel);
    if (flags) _paintFlags(canvas, size);
    _caption(canvas);
  }

  /// A flag on each item with a problem or warning, with what is wrong. On
  /// the mounting layout a mount's findings sit on its plate.
  void _paintFlags(Canvas canvas, Size size) {
    final byItem = <String, List<WallIssue>>{};
    for (final issue in issues) {
      if (issue.level == WallIssueLevel.note || issue.itemIds.isEmpty) continue;
      var id = issue.itemIds.first;
      if (mounting) {
        final m = issue.itemIds
            .map(wall.item)
            .where((i) => i?.kind == WallItemKind.mount)
            .firstOrNull;
        if (m == null) continue;
        id = m.id;
      }
      byItem.putIfAbsent(id, () => []).add(issue);
    }
    for (final e in byItem.entries) {
      final i = wall.item(e.key);
      if (i == null) continue;
      final found = e.value
        ..sort((a, b) => a.level.index.compareTo(b.level.index));
      final color = _levelColor(found.first.level);
      final r = layout.rectOf(
        mounting && i.kind == WallItemKind.mount ? i.wallFootprint : i.face,
      );
      final at = r.topRight;
      canvas.drawCircle(at, 10, Paint()..color = color);
      canvas.drawCircle(
        at,
        10,
        Paint()
          ..color = _paper
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      _text(
        canvas,
        found.length > 1 ? '${found.length}' : '!',
        at,
        size: 11,
        bold: true,
        color: _paper,
      );
      final more = found.length > 1 ? ' (+${found.length - 1} more)' : '';
      const room = 260.0;
      final right = at.dx + 14 + room > size.width;
      _text(
        canvas,
        '${found.first.text}$more',
        at + Offset(right ? -14 : 14, 0),
        align: right ? TextAlign.right : TextAlign.left,
        size: 10,
        bold: true,
        color: color,
        maxWidth: room,
        paper: true,
      );
    }
  }

  bool _covered(WallItem i) => wall.items.any((o) =>
      o.id != i.id &&
      o.back >= i.front - 0.01 &&
      o.back > i.back &&
      !o.kind.isOpening &&
      o.face.overlaps(i.face));

  // --- the wall --------------------------------------------------------------

  void _paintWall(Canvas canvas) {
    final s = layout.scale;
    final h = wall.heightIn > 0 ? wall.heightIn : layout.tallest - 6;
    final rect = Rect.fromPoints(layout.at(0, 0), layout.at(wall.widthIn, h));
    canvas.drawRect(rect, Paint()..color = const Color(0xFFF7F7F5));
    // A foot grid.
    final grid = Paint()
      ..color = _faint
      ..strokeWidth = 1;
    for (var x = 12.0; x < wall.widthIn; x += 12) {
      canvas.drawLine(layout.at(x, 0), layout.at(x, h), grid);
    }
    for (var y = 12.0; y < h; y += 12) {
      canvas.drawLine(layout.at(0, y), layout.at(wall.widthIn, y), grid);
    }
    final edge = Paint()
      ..color = _ink
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(layout.at(0, 0), layout.at(0, h), edge);
    canvas.drawLine(layout.at(wall.widthIn, 0), layout.at(wall.widthIn, h), edge);
    // Floor, under both views.
    final floor = Paint()
      ..color = _ink
      ..strokeWidth = 2.5;
    canvas.drawLine(
      layout.at(-4, 0),
      layout.at(wall.widthIn + 4, 0),
      floor,
    );
    if (!mounting) {
      canvas.drawLine(
        layout.side(-4, 0),
        layout.side(layout.sectionDepth, 0),
        floor,
      );
    }
    // Ceiling.
    if (wall.heightIn > 0) {
      _dashed(
        canvas,
        layout.at(0, wall.heightIn),
        layout.at(wall.widthIn, wall.heightIn),
        edge,
      );
      if (!mounting) {
        _dashed(
          canvas,
          layout.side(0, wall.heightIn),
          layout.side(layout.sectionDepth, wall.heightIn),
          edge,
        );
      }
      _text(
        canvas,
        'CLG ${inchesLabel(wall.heightIn)}',
        (mounting
                ? layout.at(wall.widthIn, wall.heightIn)
                : layout.side(layout.sectionDepth, wall.heightIn)) +
            const Offset(-2, -8),
        align: TextAlign.right,
        size: 10,
      );
    }
    // A height ruler down the left.
    for (var y = 0.0; y <= h + 0.01; y += 12) {
      final p = layout.at(0, y);
      canvas.drawLine(p, p - const Offset(6, 0), edge);
      if (s * 12 >= 14 || y % 24 == 0) {
        _text(
          canvas,
          "${(y / 12).round()}'",
          p - const Offset(9, 0),
          align: TextAlign.right,
          size: 9,
        );
      }
    }
    // Overall length under the floor.
    _dimH(canvas, 0, wall.widthIn, -10, inchesLabel(wall.widthIn), elevation: true);
  }

  // --- items -----------------------------------------------------------------

  void _paintItem(Canvas canvas, WallItem i) {
    final r = layout.rectOf(i.face);
    final c = i.kind.color;
    switch (i.kind) {
      case WallItemKind.display:
        canvas.drawRect(r, Paint()..color = const Color(0xFF212121));
        final a = layout.rectOf(i.activeFace);
        canvas.drawRect(a, Paint()..color = const Color(0xFF37474F));
        _label(canvas, i, r, const Color(0xFFFFFFFF));
        _paintVesa(canvas, i);
      case WallItemKind.mount:
        _paintMount(canvas, i, dashed: false);
      case WallItemKind.door:
        canvas.drawRect(r, Paint()..color = const Color(0xFFEFEBE9));
        _stroke(canvas, r, c, 1.5);
        canvas.drawCircle(
          layout.at(i.right - 3, i.y + 36),
          math.max(2, 1.2 * layout.scale),
          Paint()..color = c,
        );
        _label(canvas, i, r, c);
      case WallItemKind.window:
        canvas.drawRect(r, Paint()..color = const Color(0x334FC3F7));
        _stroke(canvas, r, c, 1.5);
        canvas.drawLine(r.topCenter, r.bottomCenter, Paint()..color = c);
        canvas.drawLine(r.centerLeft, r.centerRight, Paint()..color = c);
        _label(canvas, i, r, c);
      case WallItemKind.outlet:
      case WallItemKind.lightSwitch:
      case WallItemKind.recessedBox:
        canvas.drawRect(r, Paint()..color = c.withValues(alpha: 0.25));
        _stroke(canvas, r, c, 1.2);
        if (i.kind == WallItemKind.recessedBox) {
          _stroke(canvas, r.deflate(math.min(r.width, r.height) * 0.15), c, 0.8);
        }
        _label(canvas, i, r, c, below: true);
      default:
        canvas.drawRect(
          r,
          Paint()..color = c.withValues(alpha: i.kind.onFloor ? 0.35 : 0.22),
        );
        _stroke(canvas, r, c, 1.5);
        if (i.touch && i.kind != WallItemKind.display) {
          _stroke(canvas, layout.rectOf(i.activeFace), c, 0.8);
        }
        _label(
          canvas,
          i,
          r,
          Color.lerp(c, const Color(0xFF000000), 0.4)!,
          below: r.height < 14,
        );
    }
  }

  /// A display's VESA holes, on its back: rings with a cross through the
  /// pattern's center.
  void _paintVesa(Canvas canvas, WallItem d) {
    final holes = d.vesaHoles;
    if (holes.isEmpty) return;
    const ink = Color(0xFFB0BEC5);
    final ring = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final r = math.max(2.5, 0.3 * layout.scale);
    for (final h in holes) {
      canvas.drawCircle(layout.at(h.dx, h.dy), r, ring);
    }
    final c = layout.at(d.vesaCenterX, d.vesaCenterY);
    final thin = Paint()
      ..color = ink
      ..strokeWidth = 0.8;
    canvas.drawLine(c - const Offset(5, 0), c + const Offset(5, 0), thin);
    canvas.drawLine(c - const Offset(0, 5), c + const Offset(0, 5), thin);
  }

  /// A mount: the plate on the wall and the two arms at its display's holes.
  void _paintMount(Canvas canvas, WallItem m, {required bool dashed}) {
    final c = m.kind.color;
    final plate = layout.rectOf(m.wallFootprint);
    final d = wall.displayOn(m.id);
    final holes = d != null && d.vesaW > 0
        ? d.vesaW * kInPerMm
        : math.min(m.width - 2, m.vesaW * kInPerMm);
    final armW = m.armDrawWidth;
    final arms = [
      for (final cx in [m.centerX - holes / 2, m.centerX + holes / 2])
        layout.rectOf(Rect.fromLTRB(cx - armW / 2, m.y, cx + armW / 2, m.top)),
    ];
    if (dashed) {
      final ink = Paint()
        ..color = c
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke;
      _dashedRect(canvas, plate, ink);
      for (final a in arms) {
        _dashedRect(canvas, a, ink);
      }
      return;
    }
    canvas.drawRect(plate, Paint()..color = c.withValues(alpha: 0.45));
    _stroke(canvas, plate, c, 1.2);
    for (final a in arms) {
      canvas.drawRect(a, Paint()..color = c);
    }
    if (d == null) _label(canvas, m, layout.rectOf(m.face), c, below: true);
  }

  void _paintHidden(Canvas canvas, WallItem i) {
    if (i.kind == WallItemKind.mount) {
      _paintMount(canvas, i, dashed: true);
      return;
    }
    _dashedRect(
      canvas,
      layout.rectOf(i.face),
      Paint()
        ..color = i.kind.color
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke,
    );
    final r = layout.rectOf(i.face);
    _text(
      canvas,
      i.name,
      Offset(r.center.dx, r.bottom + 7),
      size: 9,
      color: i.kind.color,
    );
  }

  void _label(
    Canvas canvas,
    WallItem i,
    Rect r,
    Color color, {
    bool below = false,
  }) {
    if (below) {
      _text(canvas, i.name, Offset(r.center.dx, r.bottom + 7), size: 9, color: color);
      return;
    }
    if (r.width < 30 || r.height < 12) return;
    _text(canvas, i.name, r.center, size: 11, color: color, maxWidth: r.width - 4);
  }

  // --- the mounting layout ---------------------------------------------------

  /// Mounts called out and dimensioned for the installer, with a schedule
  /// beside the wall; everything else faint, there only to measure around.
  void _paintMounting(Canvas canvas) {
    final ghost = Paint()
      ..color = _ghost
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final i in wall.items) {
      if (i.kind == WallItemKind.mount) continue;
      final r = layout.rectOf(i.face);
      switch (i.kind) {
        case WallItemKind.display:
          _dashedRect(canvas, r, ghost);
          if (r.width >= 30 && r.height >= 24) {
            _text(
              canvas,
              i.name,
              Offset(r.center.dx, r.top + 9),
              size: 9,
              color: _ghost,
              maxWidth: r.width - 4,
            );
          }
        // Boxes in the wall matter: the plate and its anchors must miss them.
        case WallItemKind.outlet ||
            WallItemKind.recessedBox ||
            WallItemKind.lightSwitch:
          final c = i.kind.color;
          canvas.drawRect(r, Paint()..color = c.withValues(alpha: 0.2));
          _stroke(canvas, r, c, 1);
          _label(canvas, i, r, c, below: true);
        default:
          canvas.drawRect(r, Paint()..color = _faint.withValues(alpha: 0.6));
          canvas.drawRect(r, ghost);
          _label(canvas, i, r, _ghost, below: r.height < 14);
      }
    }
    final placements = mountPlacements(wall);
    for (final m in placements) {
      _paintPlacement(canvas, m);
    }
    _paintSchedule(canvas, placements);
    _text(
      canvas,
      '${wall.name.toUpperCase()} - MOUNTING LAYOUT',
      Offset(layout.at(wall.widthIn / 2, 0).dx, _captionY),
      size: 11,
      bold: true,
    );
  }

  /// One mount: its plate, arms and holes, its tag, and dimensions from the
  /// floor and both wall ends to its center line.
  void _paintPlacement(Canvas canvas, MountPlacement m) {
    final plate = layout.rectOf(m.plate);
    canvas.drawRect(plate, Paint()..color = _callout.withValues(alpha: 0.16));
    final holes = m.holes;
    final armW = m.mount.armDrawWidth;
    for (final cx in {for (final h in holes) h.dx}) {
      canvas.drawRect(
        layout.rectOf(
          Rect.fromLTRB(cx - armW / 2, m.mount.y, cx + armW / 2, m.mount.top),
        ),
        Paint()..color = _callout.withValues(alpha: 0.32),
      );
    }
    _stroke(canvas, plate, _callout, 2);
    // Holes: a ring with a cross.
    final hr = math.max(3.0, 0.3 * layout.scale);
    final ring = Paint()
      ..color = _callout
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final thin = Paint()
      ..color = _callout
      ..strokeWidth = 0.8;
    for (final h in holes) {
      final c = layout.at(h.dx, h.dy);
      canvas.drawCircle(c, hr, ring);
      canvas.drawLine(c - Offset(hr + 2, 0), c + Offset(hr + 2, 0), thin);
      canvas.drawLine(c - Offset(0, hr + 2), c + Offset(0, hr + 2), thin);
    }
    // Center lines.
    final cl = Paint()
      ..color = _callout
      ..strokeWidth = 1;
    _dashed(
      canvas,
      layout.at(m.plateLeft - 3, m.centerY),
      layout.at(m.plateRight + 3, m.centerY),
      cl,
    );
    _dashed(
      canvas,
      layout.at(m.centerX, m.plateBottom - 3),
      layout.at(m.centerX, m.plateTop + 3),
      cl,
    );
    // Clear of the plate, its arms and its holes.
    var low = math.min(m.plateBottom, m.mount.y);
    var high = math.max(m.plateTop, m.mount.top);
    for (final h in holes) {
      low = math.min(low, h.dy);
      high = math.max(high, h.dy);
    }
    // Along the wall: each end to the center line, under the mount.
    final under = math.max(2.0, low - 5);
    _dimH(canvas, 0, m.centerX, under, inchesLabel(m.fromLeft),
        color: _callout, bold: true);
    _dimH(canvas, m.centerX, wall.widthIn, under, inchesLabel(m.fromRight),
        color: _callout, bold: true);
    // Plate width over it.
    _dimH(canvas, m.plateLeft, m.plateRight, high + 4,
        inchesLabel(m.plateWidth), color: _callout);
    // Up from the floor: to the plate's bottom, the plate, its center line.
    final left = m.plateLeft - 4;
    _dimV(canvas, 0, m.plateBottom, left, inchesLabel(m.plateBottom),
        color: _callout, labelLeft: true, bold: true);
    _dimV(canvas, m.plateBottom, m.plateTop, left, inchesLabel(m.plateHeight),
        color: _callout, labelLeft: true);
    _dimV(canvas, 0, m.centerY, m.plateRight + 4,
        'CL ${inchesLabel(m.centerY)} AFF', color: _callout, bold: true);
    // Hole spacing across the top pair.
    if (holes.length == 4) {
      _dimH(
        canvas,
        holes[2].dx,
        holes[3].dx,
        high + 4 + 14 / layout.scale,
        inchesLabel(holes[3].dx - holes[2].dx),
        color: _callout,
      );
    }
    final corner = layout.at(m.plateLeft, high);
    final at = corner + const Offset(-16, -16);
    canvas.drawLine(at, corner, Paint()
      ..color = _callout
      ..strokeWidth = 1.2);
    _tag(canvas, at, m.tag);
  }

  void _tag(Canvas canvas, Offset c, String tag) {
    canvas.drawCircle(c, 11, Paint()..color = _callout);
    _text(canvas, tag, c, size: 10, bold: true, color: const Color(0xFFFFFFFF));
  }

  /// The mounts as a list beside the wall, one block each.
  void _paintSchedule(Canvas canvas, List<MountPlacement> placements) {
    final x0 = layout.sectionX;
    final x1 = x0 + _WallLayout.scheduleWidth;
    var y = 36.0;
    _text(canvas, 'MOUNTING SCHEDULE', Offset(x0, y),
        align: TextAlign.left, size: 11, bold: true);
    y += 18;
    if (placements.isEmpty) {
      _text(canvas, 'No wall mounts on this wall.', Offset(x0, y),
          align: TextAlign.left, size: 10, color: _ghost);
      return;
    }
    final rule = Paint()
      ..color = _faint
      ..strokeWidth = 1;
    for (final m in placements) {
      canvas.drawLine(Offset(x0, y - 8), Offset(x1, y - 8), rule);
      y += 6;
      _tag(canvas, Offset(x0 + 11, y), m.tag);
      _text(
        canvas,
        m.mount.model.trim().isNotEmpty ? m.mount.model.trim() : m.mount.name,
        Offset(x0 + 28, y),
        align: TextAlign.left,
        size: 10,
        bold: true,
        maxWidth: x1 - x0 - 28,
      );
      y += 18;
      final d = m.display;
      final vesa = vesaLabel(m.vesaWmm, m.vesaHmm);
      final rows = <(String, String)>[
        if (d != null) ('Holds', d.name),
        ('Plate CL from left end', inchesLabel(m.fromLeft)),
        ('Plate CL from right end', inchesLabel(m.fromRight)),
        ('Plate CL AFF', inchesLabel(m.centerY)),
        (
          'Plate bottom / top AFF',
          '${inchesLabel(m.plateBottom)} / ${inchesLabel(m.plateTop)}',
        ),
        ('Plate width', inchesLabel(m.plateWidth)),
        if (vesa.isNotEmpty) ('VESA', vesa),
        if (vesa.isNotEmpty)
          (
            'Hole spacing',
            '${inchesLabel(m.vesaWmm * kInPerMm)} x '
                '${inchesLabel(m.vesaHmm * kInPerMm)}',
          ),
        if (d != null)
          (
            'Display bottom / top AFF',
            '${inchesLabel(d.y)} / ${inchesLabel(d.top)}',
          ),
        if (d != null) ('Display off wall', inchesLabel(m.offWall)),
      ];
      for (final (label, value) in rows) {
        _text(canvas, label, Offset(x0 + 6, y),
            align: TextAlign.left, size: 10, maxWidth: 150);
        _text(canvas, value, Offset(x1 - 4, y),
            align: TextAlign.right,
            size: 10,
            bold: true,
            color: label == 'Holds' ? _ink : _callout,
            maxWidth: x1 - x0 - 160);
        y += 15;
      }
      y += 12;
    }
  }

  // --- the section -----------------------------------------------------------

  void _paintSection(Canvas canvas, Map<String, WallIssueLevel> worst) {
    final h = wall.heightIn > 0 ? wall.heightIn : layout.tallest - 6;
    final face = Paint()
      ..color = _ink
      ..strokeWidth = 3;
    // The wall, hatched behind its face.
    final wallRect = Rect.fromPoints(layout.side(-4, 0), layout.side(0, h));
    canvas.drawRect(wallRect, Paint()..color = const Color(0xFFCFD8DC));
    canvas.drawLine(layout.side(0, 0), layout.side(0, h), face);
    // Where more than 4" out is too far.
    final zone = Rect.fromPoints(
      layout.side(kMaxProtrusionIn, kCaneDetectIn),
      layout.side(layout.sectionDepth, kHeadroomIn),
    );
    canvas.drawRect(zone, Paint()..color = const Color(0x14D32F2F));
    final zoneInk = Paint()
      ..color = const Color(0x99D32F2F)
      ..strokeWidth = 1;
    _dashed(
      canvas,
      layout.side(kMaxProtrusionIn, kCaneDetectIn),
      layout.side(kMaxProtrusionIn, kHeadroomIn),
      zoneInk,
    );
    for (final y in const [kCaneDetectIn, kHeadroomIn]) {
      _dashed(
        canvas,
        layout.side(kMaxProtrusionIn, y),
        layout.side(layout.sectionDepth, y),
        zoneInk,
      );
      _text(
        canvas,
        inchesLabel(y),
        layout.side(layout.sectionDepth, y) + const Offset(-2, -7),
        align: TextAlign.right,
        size: 9,
        color: const Color(0xFFC62828),
      );
    }
    _text(
      canvas,
      '4"',
      layout.side(kMaxProtrusionIn, kHeadroomIn) + const Offset(0, -8),
      size: 9,
      color: const Color(0xFFC62828),
    );

    final order = [...wall.items]..sort((a, b) => a.back.compareTo(b.back));
    for (final i in order) {
      final path = _sectionPath(i);
      final c = i.kind == WallItemKind.display ? const Color(0xFF212121) : i.kind.color;
      canvas.drawPath(
        path,
        Paint()..color = c.withValues(alpha: i.kind == WallItemKind.display ? 0.85 : 0.35),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = i.id == selectedId ? _select : c
          ..style = PaintingStyle.stroke
          ..strokeWidth = i.id == selectedId ? 2 : 1,
      );
      final level = worst[i.id];
      if (level != null && level != WallIssueLevel.note) {
        canvas.drawPath(
          path,
          Paint()
            ..color = _levelColor(level)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  /// [i] seen from the side: back to front, bottom to top, tilted about its
  /// VESA center.
  Path _sectionPath(WallItem i) {
    final t = i.tiltDeg * math.pi / 180;
    final pivotY = i.vesaCenterY;
    final pivotD = i.standoff;
    Offset turn(double d, double y) {
      final dd = d - pivotD, dy = y - pivotY;
      final nd = dd * math.cos(t) + dy * math.sin(t);
      final ny = -dd * math.sin(t) + dy * math.cos(t);
      return layout.side(pivotD + nd, pivotY + ny);
    }

    final corners = [
      turn(i.back, i.y),
      turn(i.back + i.depth, i.y),
      turn(i.back + i.depth, i.top),
      turn(i.back, i.top),
    ];
    // Flat things still show as a line.
    if (i.depth < 0.2) {
      final a = layout.side(i.back, i.y), b = layout.side(i.back + 0.4, i.top);
      return Path()..addRect(Rect.fromPoints(a, b));
    }
    return Path()..addPolygon(corners, true);
  }

  // --- the selection ---------------------------------------------------------

  void _paintSelected(Canvas canvas, WallItem i) {
    final r = layout.rectOf(i.face);
    canvas.drawRect(
      r.inflate(3),
      Paint()
        ..color = _select
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // Across: wall end to item, item, item to wall end.
    final dimY = i.top + 4;
    if (i.x > 0.05) {
      _dimH(canvas, 0, i.x, dimY, inchesLabel(i.x), elevation: true);
    }
    _dimH(canvas, i.x, i.right, dimY, inchesLabel(i.width), elevation: true);
    if (wall.widthIn - i.right > 0.05) {
      _dimH(
        canvas,
        i.right,
        wall.widthIn,
        dimY,
        inchesLabel(wall.widthIn - i.right),
        elevation: true,
      );
    }
    // Up: floor to bottom, then the item.
    final dimX = i.right + 4;
    if (i.y > 0.05) _dimV(canvas, 0, i.y, dimX, inchesLabel(i.y));
    _dimV(canvas, i.y, i.top, dimX, inchesLabel(i.height));
    // Center line.
    final cl = Paint()
      ..color = _select
      ..strokeWidth = 1;
    _dashed(
      canvas,
      layout.at(i.x - 3, i.centerY),
      layout.at(i.right + 3, i.centerY),
      cl,
    );
    _text(
      canvas,
      'CL ${inchesLabel(i.centerY)} AFF',
      layout.at(i.x - 4, i.centerY),
      align: TextAlign.right,
      size: 10,
      color: _select,
    );
    // How far it stands out, on the section.
    final p = Paint()
      ..color = _select
      ..strokeWidth = 1;
    final y = i.top + 3;
    canvas.drawLine(layout.side(0, y), layout.side(i.front, y), p);
    canvas.drawLine(layout.side(0, y - 1.5), layout.side(0, y + 1.5), p);
    canvas.drawLine(layout.side(i.front, y - 1.5), layout.side(i.front, y + 1.5), p);
    _text(
      canvas,
      inchesLabel(i.front),
      layout.side(i.front, y) + const Offset(4, 0),
      align: TextAlign.left,
      size: 10,
      color: _select,
    );
  }

  /// The caption's line, clear of the overall length under the floor.
  double get _captionY => layout.origin.dy + math.max(36.0, 10 * layout.scale + 20);

  void _caption(Canvas canvas) {
    final under = _captionY;
    _text(
      canvas,
      wall.name.toUpperCase(),
      Offset(layout.at(wall.widthIn / 2, 0).dx, under),
      size: 11,
      bold: true,
    );
    _text(
      canvas,
      'SECTION',
      Offset(layout.side(layout.sectionDepth / 2, 0).dx, under),
      size: 11,
      bold: true,
    );
  }

  // --- drawing helpers -------------------------------------------------------

  void _stroke(Canvas canvas, Rect r, Color c, double w) => canvas.drawRect(
    r,
    Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w,
  );

  void _dimH(
    Canvas canvas,
    double x0,
    double x1,
    double y,
    String label, {
    bool elevation = true,
    Color color = _select,
    bool bold = false,
  }) {
    final ink = Paint()
      ..color = color
      ..strokeWidth = 1;
    final a = layout.at(x0, y), b = layout.at(x1, y);
    canvas.drawLine(a, b, ink);
    canvas.drawLine(a + const Offset(0, -4), a + const Offset(0, 4), ink);
    canvas.drawLine(b + const Offset(0, -4), b + const Offset(0, 4), ink);
    _text(
      canvas,
      label,
      Offset.lerp(a, b, 0.5)! + const Offset(0, -7),
      size: 10,
      color: color,
      bold: bold,
      paper: bold,
    );
  }

  void _dimV(
    Canvas canvas,
    double y0,
    double y1,
    double x,
    String label, {
    Color color = _select,
    bool labelLeft = false,
    bool bold = false,
  }) {
    final ink = Paint()
      ..color = color
      ..strokeWidth = 1;
    final a = layout.at(x, y0), b = layout.at(x, y1);
    canvas.drawLine(a, b, ink);
    canvas.drawLine(a + const Offset(-4, 0), a + const Offset(4, 0), ink);
    canvas.drawLine(b + const Offset(-4, 0), b + const Offset(4, 0), ink);
    _text(
      canvas,
      label,
      Offset.lerp(a, b, 0.5)! + Offset(labelLeft ? -5 : 5, 0),
      align: labelLeft ? TextAlign.right : TextAlign.left,
      size: 10,
      color: color,
      bold: bold,
      paper: bold,
    );
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint ink) {
    final len = (b - a).distance;
    if (len < 1) return;
    final dir = (b - a) / len;
    for (var t = 0.0; t < len; t += 9) {
      canvas.drawLine(a + dir * t, a + dir * math.min(t + 5, len), ink);
    }
  }

  void _dashedRect(Canvas canvas, Rect r, Paint ink) {
    _dashed(canvas, r.topLeft, r.topRight, ink);
    _dashed(canvas, r.topRight, r.bottomRight, ink);
    _dashed(canvas, r.bottomRight, r.bottomLeft, ink);
    _dashed(canvas, r.bottomLeft, r.topLeft, ink);
  }

  void _text(
    Canvas canvas,
    String text,
    Offset at, {
    TextAlign align = TextAlign.center,
    double size = 10,
    Color color = _ink,
    bool bold = false,
    double? maxWidth,
    bool paper = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          color: color,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth ?? double.infinity);
    final dx = switch (align) {
      TextAlign.right => at.dx - tp.width,
      TextAlign.left => at.dx,
      _ => at.dx - tp.width / 2,
    };
    final topLeft = Offset(dx, at.dy - tp.height / 2);
    // A knockout so a label reads over lines behind it.
    if (paper) {
      canvas.drawRect(
        (topLeft & tp.size).inflate(1.5),
        Paint()..color = const Color(0xF2FFFFFF),
      );
    }
    tp.paint(canvas, topLeft);
  }

  @override
  bool shouldRepaint(_WallElevationPainter old) =>
      old.wall != wall ||
      old.selectedId != selectedId ||
      old.layout.scale != layout.scale ||
      old.layout.origin != layout.origin ||
      old.mounting != mounting ||
      old.flags != flags ||
      old.issues.map((i) => i.text).join('\n') !=
          issues.map((i) => i.text).join('\n');
}

