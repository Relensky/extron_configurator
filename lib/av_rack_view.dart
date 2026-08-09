import 'dart:math' as math;

import 'package:flutter/material.dart';
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

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red : null,
    ));
  }

  /// Rack height for a device, never 0 — a device you are trying to rack
  /// occupies at least 1U even if nobody has filled in its height.
  int _heightOf(AvNode? node) => math.max(1, node?.rackUnits ?? 1);

  void _place(AppStateProvider provider, RackFrame rack, RackFace face,
      int startU) {
    final nodeId = _carriedNodeId;
    if (nodeId == null) return;
    final node = provider.avNodeById(nodeId);
    final height = _heightOf(node);

    if (!provider.avRackSpanIsFree(
      rackId: rack.id,
      face: face,
      startU: startU,
      heightU: height,
      ignoreNodeId: nodeId,
    )) {
      _snack(
          'U$startU doesn\'t have ${height}U free on the ${face.name} of '
          '${rack.name}.',
          error: true);
      return;
    }

    provider.setAvRackSlot(
        nodeId, RackSlot(rackId: rack.id, startU: startU, face: face));
    setState(() => _carriedNodeId = null);
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
            'Add a frame, then click a device and click the U where it lands.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add rack'),
            onPressed: () => _showAddRackDialog(provider),
          ),
        ],
      ),
    );
  }

  Widget _buildRackToolbar(
      AppStateProvider provider, List<AvNode> unracked, ThemeData theme) {
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
            onPressed: () => _showAddRackDialog(provider),
          ),
          const SizedBox(width: 4),
          if (_carriedNodeId != null)
            Chip(
              avatar: const Icon(Icons.pan_tool_alt, size: 16),
              label: Text(
                  'Placing: ${provider.avNodeById(_carriedNodeId!)?.label ?? ''}'
                  ' — click a U'),
              onDeleted: () => setState(() => _carriedNodeId = null),
            )
          else if (unracked.isEmpty)
            Text(
              provider.avNodes.any((n) => n.rackUnits > 0)
                  ? 'Every rack-mount device is placed.'
                  : 'No device has a rack height yet — set "Rack U" in a '
                      'device\'s edit dialog on the Signal Flow page.',
              style: theme.textTheme.bodySmall,
            )
          else ...[
            Text('To place:', style: theme.textTheme.bodySmall),
            for (final n in unracked)
              ActionChip(
                avatar: Icon(iconForAvNode(n.id, n.model), size: 16),
                label: Text('${n.label} (${n.rackUnits}U)'),
                onPressed: () => setState(() => _carriedNodeId = n.id),
              ),
          ],
        ],
      ),
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
    final tallest =
        provider.avRacks.fold(0, (m, r) => math.max(m, r.heightU));

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
                      Text(rack.name,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      Text('  ${rack.heightU}U',
                          style: theme.textTheme.bodySmall),
                      if (widget.editMode)
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 16),
                          tooltip: 'Remove this rack',
                          onPressed: () => _confirmRemoveRack(provider, rack),
                        ),
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

  Widget _buildFace(AppStateProvider provider, RackFrame rack, RackFace face,
      ThemeData theme) {
    final dark = theme.brightness == Brightness.dark;
    final occupants = provider.avRackSlots.entries
        .where((e) => e.value.rackId == rack.id && e.value.face == face)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(face == RackFace.front ? 'Front' : 'Rear',
            style: theme.textTheme.bodySmall),
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

  Widget _buildUSlot(AppStateProvider provider, RackFrame rack, RackFace face,
      int u, ThemeData theme) {
    final carrying = _carriedNodeId != null;
    return InkWell(
      onTap: carrying ? () => _place(provider, rack, face, u) : null,
      child: Row(
        children: [
          SizedBox(
            width: kRailWidth,
            child: Center(
              child: Text('$u',
                  style: TextStyle(fontSize: 9, color: theme.hintColor)),
            ),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.5),
                      width: 0.5),
                ),
                color: carrying
                    ? theme.colorScheme.primary.withValues(alpha: 0.06)
                    : null,
              ),
            ),
          ),
          SizedBox(
            width: kRailWidth,
            child: Center(
              child: Text('$u',
                  style: TextStyle(fontSize: 9, color: theme.hintColor)),
            ),
          ),
        ],
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

    return Positioned(
      left: kRailWidth,
      width: kRackInnerWidth,
      top: topU * kUHeight,
      height: height * kUHeight,
      child: Tooltip(
        message: '${node?.label ?? entry.key}\n'
            'U${slot.startU}'
            '${height == 1 ? '' : '–U${slot.startU + height - 1}'}'
            '${widget.editMode ? '\nClick to pick up • right-click to un-rack' : ''}',
        child: GestureDetector(
          onTap: widget.editMode
              ? () => setState(() => _carriedNodeId = entry.key)
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
                        fontSize: 10, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text('${height}U',
                    style: TextStyle(fontSize: 9, color: theme.hintColor)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showAddRackDialog(AppStateProvider provider) async {
    final nameController =
        TextEditingController(text: 'Rack ${provider.avRacks.length + 1}');
    String preset = kRackPresets.keys.first;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Add rack'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: preset,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Size'),
                  items: [
                    for (final p in kRackPresets.keys)
                      DropdownMenuItem(value: p, child: Text(p)),
                  ],
                  onChanged: (v) => setLocal(() => preset = v ?? preset),
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
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (ok != true) return;
    final name = nameController.text.trim();
    provider.addAvRack(
      name.isEmpty ? 'Rack ${provider.avRacks.length + 1}' : name,
      kRackPresets[preset] ?? 42,
    );
  }

  Future<void> _confirmRemoveRack(
      AppStateProvider provider, RackFrame rack) async {
    final occupants = provider.avRackSlots.values
        .where((s) => s.rackId == rack.id)
        .length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${rack.name}?'),
        content: Text(occupants == 0
            ? 'The frame is empty.'
            : '$occupants device${occupants == 1 ? '' : 's'} will be '
                'un-racked. The devices themselves stay on the signal flow '
                'diagram.'),
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
