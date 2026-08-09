import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'av_flow_model.dart';
import 'av_flow_view.dart' show iconForAvNode;

/// ============================================================================
///  RACK ELEVATIONS
/// ============================================================================
///  The Racks page of the AV Flow tab. Frames are drawn to scale with numbered
///  U rails; any device on the canvas with a rack height can be dropped into
///  a free span. Front and rear faces are drawn side by side per frame, so a
///  device patched from the back is visible where it actually is.
///
///  Placement lives in the same sidecar as the rest of the AV diagram
///  (avRackSlots in app_state.dart), and the rack inventory section of the AV
///  report is generated straight from it.
/// ============================================================================

/// Pixels per rack unit. 22 keeps a 42U frame on screen at 100% while leaving
/// room for a device label inside a 1U block.
const double kUHeight = 22;
const double kRackInnerWidth = 250;
const double kRailWidth = 26;
const double kRackTopPad = 34;

class AvRackView extends StatefulWidget {
  /// The AV tab's shared capture key, so Export PNG grabs whichever page is
  /// showing without a second export button.
  final GlobalKey captureKey;
  final bool editMode;

  const AvRackView({
    super.key,
    required this.captureKey,
    required this.editMode,
  });

  @override
  State<AvRackView> createState() => _AvRackViewState();
}

class _AvRackViewState extends State<AvRackView> {
  final TransformationController _transform = TransformationController();

  /// Device picked up from the unracked list or from a frame, waiting for a
  /// slot to be clicked. Click-to-place rather than drag-and-drop: a drag
  /// across a scrolling, zoomable canvas is a fight, and a rack slot is a
  /// small target.
  String? _carriedNodeId;

  /// The typed-U path: enter the number instead of finding the row.
  final TextEditingController _uController = TextEditingController();
  RackFace _typedFace = RackFace.front;

  /// Which frame typed placement targets when there is more than one.
  String? _typedRackId;

  @override
  void dispose() {
    _transform.dispose();
    _uController.dispose();
    super.dispose();
  }

  /// Places the carried device at the U typed in the toolbar. With several
  /// frames on the page, the one last clicked wins; otherwise the only one.
  void _placeAtTypedU(AppStateProvider provider) {
    if (_carriedNodeId == null) return;
    final u = int.tryParse(_uController.text.trim());
    if (u == null || u < 1) {
      _snack(
        'Enter the U number the device\'s bottom rail sits at.',
        error: true,
      );
      return;
    }
    if (provider.avRacks.isEmpty) return;
    final rack = provider.avRacks.firstWhere(
      (r) => r.id == _typedRackId,
      orElse: () => provider.avRacks.first,
    );
    _place(provider, rack, _typedFace, u);
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: error ? Colors.red : null),
    );
  }

  /// Rack height for a device, never 0 — a device you are trying to rack
  /// occupies at least 1U even if nobody has filled in its height.
  int _heightOf(AvNode? node) => math.max(1, node?.rackUnits ?? 1);

  void _place(
    AppStateProvider provider,
    RackFrame rack,
    RackFace face,
    int startU, [
    RackHalf side = RackHalf.left,
  ]) {
    final nodeId = _carriedNodeId;
    if (nodeId == null) return;
    final node = provider.avNodeById(nodeId);
    final height = _heightOf(node);
    final half = _halfFor(node, side);

    if (!provider.avRackSpanIsFree(
      rackId: rack.id,
      face: face,
      startU: startU,
      heightU: height,
      half: half,
      ignoreNodeId: nodeId,
    )) {
      _snack(
        'U$startU doesn\'t have ${height}U free on the '
        '${half == RackHalf.full ? '' : '${half.name} half of the '}'
        '${face.name} of ${rack.name}.',
        error: true,
      );
      return;
    }

    provider.setAvRackSlot(
      nodeId,
      RackSlot(rackId: rack.id, startU: startU, face: face, half: half),
    );
    setState(() {
      _carriedNodeId = null;
      // Remember where the last placement went, so the next typed U lands in
      // the same frame and face without re-picking them.
      _typedRackId = rack.id;
      _typedFace = face;
      _uController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);

    final rackable = provider.avNodes.where((n) => n.rackUnits > 0).toList();
    final unracked = rackable
        .where((n) => !provider.avRackSlots.containsKey(n.id))
        .toList();

    return Column(
      children: [
        _buildRackToolbar(provider, unracked, theme),
        const Divider(height: 1),
        Expanded(
          child: provider.avRacks.isEmpty
              ? _buildEmptyState(provider, theme)
              : InteractiveViewer(
                  transformationController: _transform,
                  constrained: false,
                  minScale: 0.3,
                  maxScale: 2.5,
                  boundaryMargin: const EdgeInsets.all(200),
                  child: RepaintBoundary(
                    key: widget.captureKey,
                    child: _buildRacksCanvas(provider, theme),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(AppStateProvider provider, ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.view_day, size: 48, color: theme.disabledColor),
          const SizedBox(height: 12),
          const Text('No racks yet.'),
          const SizedBox(height: 4),
          Text(
            'Add a frame, then drag a device onto the U where it lands — or '
            'click the device and click the U.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add rack'),
            onPressed: () => _showRackDialog(provider),
          ),
        ],
      ),
    );
  }

  Widget _buildRackToolbar(
    AppStateProvider provider,
    List<AvNode> unracked,
    ThemeData theme,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add rack'),
            onPressed: () => _showRackDialog(provider),
          ),
          const SizedBox(width: 4),
          if (_carriedNodeId != null) ...[
            Chip(
              avatar: const Icon(Icons.pan_tool_alt, size: 16),
              label: Text(
                'Placing: ${provider.avNodeById(_carriedNodeId!)?.label ?? ''}'
                ' — click a U, or type one',
              ),
              onDeleted: () => setState(() => _carriedNodeId = null),
            ),
            // Typing the U beats hunting for a 22px row, especially on a 42U
            // frame where the rails scroll.
            SizedBox(
              width: 74,
              child: TextField(
                controller: _uController,
                decoration: const InputDecoration(
                  labelText: 'at U',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmitted: (_) => _placeAtTypedU(provider),
              ),
            ),
            SegmentedButton<RackFace>(
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: RackFace.front, label: Text('Front')),
                ButtonSegment(value: RackFace.rear, label: Text('Rear')),
              ],
              selected: {_typedFace},
              onSelectionChanged: (s) => setState(() => _typedFace = s.first),
            ),
            FilledButton(
              onPressed: () => _placeAtTypedU(provider),
              child: const Text('Place'),
            ),
          ] else if (unracked.isEmpty)
            Text(
              provider.avNodes.any((n) => n.rackUnits > 0)
                  ? 'Every rack-mount device is placed.'
                  : 'No device has a rack height yet — set "Rack U" in a '
                        'device\'s edit dialog on the Signal Flow page.',
              style: theme.textTheme.bodySmall,
            )
          else ...[
            Text(
              'To place — drag one in, or click it:',
              style: theme.textTheme.bodySmall,
            ),
            for (final n in unracked)
              Draggable<String>(
                data: n.id,
                dragAnchorStrategy: pointerDragAnchorStrategy,
                feedback: _dragGhost(n, theme),
                childWhenDragging: Opacity(
                  opacity: 0.35,
                  child: _unrackedChip(n, theme, onPressed: null),
                ),
                child: _unrackedChip(
                  n,
                  theme,
                  onPressed: () => setState(() => _carriedNodeId = n.id),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// A device waiting to go in, shown in the toolbar. Half-width gear says so
  /// so it's obvious why it only claims half a rail.
  Widget _unrackedChip(
    AvNode n,
    ThemeData theme, {
    required VoidCallback? onPressed,
  }) {
    return ActionChip(
      avatar: Icon(iconForAvNode(n.id, n.model), size: 16),
      label: Text('${n.label} (${n.rackUnits}U${n.isHalfRack ? ' ½' : ''})'),
      onPressed: onPressed,
    );
  }

  Widget _buildRacksCanvas(AppStateProvider provider, ThemeData theme) {
    final surface = theme.brightness == Brightness.dark
        ? const Color(0xFF15181C)
        : const Color(0xFFFAFAFA);

    // Front and rear sit side by side per frame; frames flow left to right.
    // The pitch has to account for BOTH faces, the gap between them, and the
    // trailing gap to the next frame, or the last rail is clipped.
    const faceWidth = kRackInnerWidth + kRailWidth * 2;
    const faceGap = 24.0; // between front and rear of one frame
    const frameGap = 60.0; // between frames
    const framePitch = faceWidth * 2 + faceGap + frameGap;
    final tallest = provider.avRacks.fold(0, (m, r) => math.max(m, r.heightU));

    return Container(
      width: 40 + provider.avRacks.length * framePitch,
      height: kRackTopPad + tallest * kUHeight + 90,
      color: surface,
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final rack in provider.avRacks)
            Padding(
              padding: const EdgeInsets.only(right: frameGap),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        rack.name,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '  ${rack.heightU}U',
                        style: theme.textTheme.bodySmall,
                      ),
                      if (widget.editMode) ...[
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          tooltip: 'Rename or resize this rack',
                          onPressed: () =>
                              _showRackDialog(provider, existing: rack),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 16),
                          tooltip: 'Remove this rack',
                          onPressed: () => _confirmRemoveRack(provider, rack),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildFace(provider, rack, RackFace.front, theme),
                      const SizedBox(width: faceGap),
                      _buildFace(provider, rack, RackFace.rear, theme),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFace(
    AppStateProvider provider,
    RackFrame rack,
    RackFace face,
    ThemeData theme,
  ) {
    final dark = theme.brightness == Brightness.dark;
    final occupants = provider.avRackSlots.entries
        .where((e) => e.value.rackId == rack.id && e.value.face == face)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          face == RackFace.front ? 'Front' : 'Rear',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 3),
        Container(
          width: kRackInnerWidth + kRailWidth * 2,
          height: rack.heightU * kUHeight,
          decoration: BoxDecoration(
            color: dark ? const Color(0xFF10141A) : const Color(0xFFEDEFF2),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Stack(
            children: [
              // Empty U slots: the click targets, drawn first so devices
              // land on top of them.
              for (int u = rack.heightU; u >= 1; u--)
                Positioned(
                  left: 0,
                  right: 0,
                  // U1 is the bottom rail, so it is drawn last from the top.
                  top: (rack.heightU - u) * kUHeight,
                  height: kUHeight,
                  child: _buildUSlot(provider, rack, face, u, theme),
                ),
              // Devices.
              for (final entry in occupants)
                _buildRackedDevice(provider, rack, face, entry, theme),
            ],
          ),
        ),
      ],
    );
  }

  /// One rail position. The bay between the rails is split into a left and a
  /// right target: a half-width device lands on the side you pick, and a
  /// full-width one ignores the split and takes the whole U. Each half is
  /// both a click target (for the carried device) and a drop target (for a
  /// dragged one), so both ways of placing gear go through the same rules.
  Widget _buildUSlot(
    AppStateProvider provider,
    RackFrame rack,
    RackFace face,
    int u,
    ThemeData theme,
  ) {
    Widget rail() => SizedBox(
      width: kRailWidth,
      child: Center(
        child: Text(
          '$u',
          style: TextStyle(fontSize: 9, color: theme.hintColor),
        ),
      ),
    );

    return Row(
      children: [
        rail(),
        Expanded(
          child: _buildHalfSlot(provider, rack, face, u, RackHalf.left, theme),
        ),
        Expanded(
          child: _buildHalfSlot(provider, rack, face, u, RackHalf.right, theme),
        ),
        rail(),
      ],
    );
  }

  Widget _buildHalfSlot(
    AppStateProvider provider,
    RackFrame rack,
    RackFace face,
    int u,
    RackHalf side,
    ThemeData theme,
  ) {
    return DragTarget<String>(
      key: ValueKey('u_${rack.id}_${face.name}_${u}_${side.name}'),
      onWillAcceptWithDetails: (details) =>
          _canDrop(provider, details.data, rack, face, u, side),
      onAcceptWithDetails: (details) =>
          _dropInto(provider, details.data, rack, face, u, side),
      builder: (ctx, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        final rejecting = rejected.isNotEmpty;
        // Only tint the halves while something is actually in flight or in
        // hand — an idle rack should look like a rack, not a grid of buttons.
        final carrying = _carriedNodeId != null;
        return InkWell(
          onTap: carrying ? () => _place(provider, rack, face, u, side) : null,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: theme.dividerColor.withValues(alpha: 0.5),
                  width: 0.5,
                ),
              ),
              color: hovering
                  ? theme.colorScheme.primary.withValues(alpha: 0.28)
                  : rejecting
                  ? Colors.red.withValues(alpha: 0.18)
                  : carrying
                  ? theme.colorScheme.primary.withValues(alpha: 0.06)
                  : null,
            ),
          ),
        );
      },
    );
  }

  /// Whether [nodeId] would fit at this spot — drives both the green hover
  /// tint and the refusal, so the rack never accepts a drop it can't honour.
  bool _canDrop(
    AppStateProvider provider,
    String nodeId,
    RackFrame rack,
    RackFace face,
    int u,
    RackHalf side,
  ) {
    final node = provider.avNodeById(nodeId);
    if (node == null) return false;
    return provider.avRackSpanIsFree(
      rackId: rack.id,
      face: face,
      startU: u,
      heightU: _heightOf(node),
      half: _halfFor(node, side),
      ignoreNodeId: nodeId,
    );
  }

  /// A full-width device occupies the whole rail whichever side was aimed at.
  RackHalf _halfFor(AvNode? node, RackHalf side) =>
      (node?.isHalfRack ?? false) ? side : RackHalf.full;

  void _dropInto(
    AppStateProvider provider,
    String nodeId,
    RackFrame rack,
    RackFace face,
    int u,
    RackHalf side,
  ) {
    final node = provider.avNodeById(nodeId);
    if (node == null) return;
    provider.setAvRackSlot(
      nodeId,
      RackSlot(
        rackId: rack.id,
        startU: u,
        face: face,
        half: _halfFor(node, side),
      ),
    );
    setState(() {
      _carriedNodeId = null;
      _typedRackId = rack.id;
      _typedFace = face;
      _uController.clear();
    });
  }

  /// The little block that follows the cursor during a drag.
  Widget _dragGhost(AvNode node, ThemeData theme) {
    final width = node.isHalfRack ? kRackInnerWidth / 2 : kRackInnerWidth;
    return Material(
      color: Colors.transparent,
      child: Opacity(
        opacity: 0.85,
        child: Container(
          width: width,
          height: _heightOf(node) * kUHeight,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: theme.colorScheme.primary, width: 2),
          ),
          child: Row(
            children: [
              Icon(iconForAvNode(node.id, node.model), size: 13),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  node.label,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRackedDevice(
    AppStateProvider provider,
    RackFrame rack,
    RackFace face,
    MapEntry<String, RackSlot> entry,
    ThemeData theme,
  ) {
    final node = provider.avNodeById(entry.key);
    final height = _heightOf(node);
    final slot = entry.value;
    final dark = theme.brightness == Brightness.dark;

    // startU is the BOTTOM rail, so the block's top is heightU - (startU + h - 1)
    // units down from the top of the frame.
    final topU = rack.heightU - (slot.startU + height - 1);

    // Half-width devices take one side of the rail; everything else spans it.
    final bool half = slot.half != RackHalf.full;
    final double blockWidth = half ? kRackInnerWidth / 2 : kRackInnerWidth;
    final double left =
        kRailWidth + (slot.half == RackHalf.right ? kRackInnerWidth / 2 : 0);

    return Positioned(
      left: left,
      width: blockWidth,
      top: topU * kUHeight,
      height: height * kUHeight,
      child: Tooltip(
        message:
            '${node?.label ?? entry.key}\n'
            'U${slot.startU}'
            '${height == 1 ? '' : '–U${slot.startU + height - 1}'}'
            '${half ? ' · ${slot.half.name} half' : ''}'
            '${widget.editMode ? '\nDrag to move • click to pick up • '
                      'double-click to type a U • right-click to un-rack' : ''}',
        child: _draggableIfEditing(
          provider,
          entry.key,
          node,
          theme,
          GestureDetector(
            onTap: widget.editMode
                ? () => setState(() => _carriedNodeId = entry.key)
                : null,
            // Typing the position beats dragging when the frame is tall or the
            // device needs to land on an exact U.
            onDoubleTap: widget.editMode
                ? () => _showPlacementDialog(provider, entry.key)
                : null,
            onSecondaryTap: widget.editMode
                ? () => provider.setAvRackSlot(entry.key, null)
                : null,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 1, horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF283039) : const Color(0xFFD7DEE8),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Row(
                children: [
                  Icon(iconForAvNode(entry.key, node?.model ?? ''), size: 13),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      node?.label ?? entry.key,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (!half)
                    Text(
                      '${height}U',
                      style: TextStyle(fontSize: 9, color: theme.hintColor),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Wraps a racked device in a [Draggable] while editing, so it can be
  /// picked up and dropped on another U. Outside edit mode it is inert.
  ///
  /// The dragged payload is the node id, which is all the U slots need to
  /// check the fit and re-home it.
  Widget _draggableIfEditing(
    AppStateProvider provider,
    String nodeId,
    AvNode? node,
    ThemeData theme,
    Widget child,
  ) {
    if (!widget.editMode || node == null) return child;
    return Draggable<String>(
      data: nodeId,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _dragGhost(node, theme),
      childWhenDragging: Opacity(opacity: 0.3, child: child),
      onDragStarted: () => setState(() => _carriedNodeId = null),
      child: child,
    );
  }

  /// Add ([existing] null) or resize/rename a frame. Height is a typed number
  /// with the common sizes as one-click shortcuts — plenty of rooms have a
  /// 16U or 27U frame that no preset list is going to cover.
  Future<void> _showRackDialog(
    AppStateProvider provider, {
    RackFrame? existing,
  }) async {
    final nameController = TextEditingController(
      text: existing?.name ?? 'Rack ${provider.avRacks.length + 1}',
    );
    final heightController = TextEditingController(
      text: (existing?.heightU ?? 42).toString(),
    );

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(existing == null ? 'Add rack' : 'Edit ${existing.name}'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: existing == null,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: heightController,
                  decoration: const InputDecoration(
                    labelText: 'Height (U)',
                    helperText: 'Any number of rack units',
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final entry in kRackPresets.entries)
                      ActionChip(
                        label: Text(entry.key),
                        onPressed: () => setLocal(
                          () => heightController.text = entry.value.toString(),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(existing == null ? 'Add' : 'Save'),
            ),
          ],
        ),
      ),
    );

    if (ok != true) return;
    final name = nameController.text.trim();
    final height = int.tryParse(heightController.text.trim()) ?? 0;
    if (height < 1) {
      _snack('A rack needs a height of at least 1U.', error: true);
      return;
    }

    if (existing == null) {
      provider.addAvRack(
        name.isEmpty ? 'Rack ${provider.avRacks.length + 1}' : name,
        height,
      );
      return;
    }

    // Shrinking a frame can strand devices above the new top rail; say so
    // rather than drawing them hanging off the end.
    final stranded = provider.avRackSlots.entries.where((e) {
      if (e.value.rackId != existing.id) return false;
      final h = _heightOf(provider.avNodeById(e.key));
      return e.value.startU + h - 1 > height;
    }).toList();
    for (final e in stranded) {
      provider.setAvRackSlot(e.key, null);
    }

    provider.updateAvRack(
      existing.copyWith(
        name: name.isEmpty ? existing.name : name,
        heightU: height,
      ),
    );

    if (stranded.isNotEmpty) {
      _snack(
        '${stranded.length} device${stranded.length == 1 ? '' : 's'} '
        'un-racked — ${stranded.length == 1 ? 'it no longer fits' : 'they no '
                  'longer fit'} in ${height}U.',
      );
    }
  }

  /// Retype where a device sits: frame, face, bottom rail, and its own height.
  Future<void> _showPlacementDialog(
    AppStateProvider provider,
    String nodeId,
  ) async {
    final node = provider.avNodeById(nodeId);
    if (node == null) return;
    final slot = provider.avRackSlots[nodeId];

    final startController = TextEditingController(
      text: (slot?.startU ?? 1).toString(),
    );
    final heightController = TextEditingController(
      text: _heightOf(node).toString(),
    );
    String rackId = slot?.rackId ?? provider.avRacks.first.id;
    RackFace face = slot?.face ?? RackFace.front;
    RackWidth rackWidth = node.rackWidth;
    RackHalf half = slot?.half == RackHalf.full
        ? RackHalf.left
        : (slot?.half ?? RackHalf.left);

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(node.label),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: rackId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Rack'),
                  items: [
                    for (final r in provider.avRacks)
                      DropdownMenuItem(
                        value: r.id,
                        child: Text('${r.name} (${r.heightU}U)'),
                      ),
                  ],
                  onChanged: (v) => setLocal(() => rackId = v ?? rackId),
                ),
                const SizedBox(height: 12),
                SegmentedButton<RackFace>(
                  segments: const [
                    ButtonSegment(value: RackFace.front, label: Text('Front')),
                    ButtonSegment(value: RackFace.rear, label: Text('Rear')),
                  ],
                  selected: {face},
                  onSelectionChanged: (s) => setLocal(() => face = s.first),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<RackWidth>(
                        segments: const [
                          ButtonSegment(
                            value: RackWidth.full,
                            label: Text('Full width'),
                          ),
                          ButtonSegment(
                            value: RackWidth.half,
                            label: Text('Half'),
                          ),
                        ],
                        selected: {rackWidth},
                        onSelectionChanged: (s) =>
                            setLocal(() => rackWidth = s.first),
                      ),
                    ),
                    if (rackWidth == RackWidth.half) ...[
                      const SizedBox(width: 10),
                      SegmentedButton<RackHalf>(
                        segments: const [
                          ButtonSegment(
                            value: RackHalf.left,
                            label: Text('Left'),
                          ),
                          ButtonSegment(
                            value: RackHalf.right,
                            label: Text('Right'),
                          ),
                        ],
                        selected: {half},
                        onSelectionChanged: (s) =>
                            setLocal(() => half = s.first),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: startController,
                        decoration: const InputDecoration(
                          labelText: 'Bottom rail (U)',
                          helperText: 'U1 is the floor',
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: heightController,
                        decoration: const InputDecoration(
                          labelText: 'Device height (U)',
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('unrack'),
              child: const Text('Un-rack'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('cancel'),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop('save'),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (result == null || result == 'cancel') return;
    if (result == 'unrack') {
      provider.setAvRackSlot(nodeId, null);
      return;
    }

    final height = int.tryParse(heightController.text.trim()) ?? 1;
    final startU = int.tryParse(startController.text.trim()) ?? 1;
    if (height < 1 || startU < 1) {
      _snack('U numbers start at 1.', error: true);
      return;
    }

    // Height and width live on the DEVICE, not the slot, so they have to be
    // written back before the span is checked against them.
    if (height != node.rackUnits || rackWidth != node.rackWidth) {
      provider.updateAvNode(
        node.copyWith(rackUnits: height, rackWidth: rackWidth),
      );
    }
    final slotHalf = rackWidth == RackWidth.half ? half : RackHalf.full;
    if (!provider.avRackSpanIsFree(
      rackId: rackId,
      face: face,
      startU: startU,
      heightU: height,
      half: slotHalf,
      ignoreNodeId: nodeId,
    )) {
      _snack('U$startU doesn\'t have ${height}U free there.', error: true);
      return;
    }
    provider.setAvRackSlot(
      nodeId,
      RackSlot(rackId: rackId, startU: startU, face: face, half: slotHalf),
    );
  }

  Future<void> _confirmRemoveRack(
    AppStateProvider provider,
    RackFrame rack,
  ) async {
    final occupants = provider.avRackSlots.values
        .where((s) => s.rackId == rack.id)
        .length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${rack.name}?'),
        content: Text(
          occupants == 0
              ? 'The frame is empty.'
              : '$occupants device${occupants == 1 ? '' : 's'} will be '
                    'un-racked. The devices themselves stay on the signal flow '
                    'diagram.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) provider.removeAvRack(rack.id);
  }
}
