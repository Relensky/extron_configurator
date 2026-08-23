import 'app_snack.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'av_flow_swap_dialogs.dart'
    show applyControlSwap, applyModelSwap, pickCatalogModel;
import 'av_flow_view.dart' show iconForAvNode;
import 'cost_estimate.dart' show formatMoney, trimNumber;
import 'device_recheck_dialog.dart';
import 'view_zoom.dart';

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

/// How a rail somebody asked to be kept clear is drawn: a light red wash over
/// the slot, and the same red on the rail number and on anything sitting in it.
///
/// Light on purpose. This is advice — the catalog says the amplifier wants a
/// rail above it — and advice that shouts louder than the drawing gets turned
/// off. Nothing here refuses a placement; see
/// [AppStateProvider.rackClearanceWarnings].
const Color kRackClearanceWash = Color(0x26E53935);
const Color kRackClearanceInk = Color(0xFFC62828);

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

  /// The window the elevations are looked at through, so "Fit to view" can
  /// measure it. The canvas itself is measured through [widget.captureKey],
  /// which is already wrapped round exactly the drawing.
  final GlobalKey _viewportKey = GlobalKey();

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
      SnackBar(content: Text(msg), backgroundColor: error ? snackErrorFill(context) : null),
    );
  }

  /// Rack height for a device, never 0 — a device you are trying to rack
  /// occupies at least 1U even if nobody has filled in its height.
  int _heightOf(AvNode? node) => math.max(1, node?.rackUnits ?? 1);

  /// Puts the whole elevation on screen at once. On a wall of 42U frames the
  /// alternative is pinching back out and hunting for the one you want.
  void _fitToView(AppStateProvider provider) {
    if (provider.avRacks.isEmpty) return;
    final fitted = fitToViewport(
      controller: _transform,
      contentKey: widget.captureKey,
      viewportKey: _viewportKey,
    );
    if (!fitted) _snack('The elevation is still drawing - try again.');
  }

  /// Puts the carried device on [startU]. Sharing is automatic: if something
  /// is already on that rail the row re-splits to fit them side by side.
  void _place(
    AppStateProvider provider,
    RackFrame rack,
    RackFace face,
    int startU,
  ) {
    final nodeId = _carriedNodeId;
    if (nodeId == null) return;
    final height = provider.rackOccupantHeight(nodeId);

    final placed = provider.avRackPlaceSharing(
      nodeId: nodeId,
      rackId: rack.id,
      face: face,
      startU: startU,
    );
    if (!placed) {
      final occupants = provider
          .avRackOccupantsAt(rackId: rack.id, face: face, startU: startU)
          .length;
      _snack(
        occupants >= kMaxRackColumns
            ? 'U$startU of ${rack.name} already holds $occupants devices - '
                  'that is as many as one rack unit will list.'
            : 'U$startU has no room for a ${height}U item on the '
                  '${face.name} of ${rack.name}.',
        error: true,
      );
      return;
    }

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
    // Hardware that has been taken out of a frame but not deleted. It is
    // invisible on the elevation and still on the estimate, so it has to be
    // somewhere the user can see it.
    final looseHardware = provider.avRackItems
        .where((i) => !provider.avRackSlots.containsKey(i.id))
        .toList();

    return Column(
      children: [
        _buildRackToolbar(provider, unracked, looseHardware, theme),
        const Divider(height: 1),
        Expanded(
          key: _viewportKey,
          child: provider.avRacks.isEmpty
              ? _buildEmptyState(provider, theme)
              : InteractiveViewer(
                  transformationController: _transform,
                  constrained: false,
                  // Low enough that a row of 42U frames can be fitted whole.
                  minScale: 0.08,
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
            'Add a frame, then drag a device onto the U where it lands - or '
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
    List<RackItem> loose,
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
          // Vent plates, blanks, shelves, drawers — the parts that fill a rack
          // and never appear on a signal flow diagram. Always on the toolbar,
          // not only in edit mode: ordering the parts and arranging the frame
          // are different jobs, and hiding the one behind the other made the
          // button impossible to find when all you wanted was to quote a shelf.
          OutlinedButton.icon(
            icon: const Icon(Icons.dashboard_customize_outlined, size: 18),
            label: const Text('Add plate / shelf'),
            onPressed: provider.avRacks.isEmpty
                ? null
                : () => _showAddHardwareDialog(provider),
          ),
          // A box that is in the rack and not in the catalog — a Cisco switch,
          // an owner-furnished appliance, the thing nobody has a part number
          // for yet. It goes on the elevation and onto the estimate flagged as
          // needing a price.
          OutlinedButton.icon(
            icon: const Icon(Icons.add_box_outlined, size: 18),
            label: const Text('Add other device'),
            onPressed: provider.avRacks.isEmpty
                ? null
                : () => _showAddCustomDeviceDialog(provider),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.fit_screen, size: 18),
            label: const Text('Fit to view'),
            onPressed: provider.avRacks.isEmpty
                ? null
                : () => _fitToView(provider),
          ),
          // "I set the rack height and it still isn't here" has three separate
          // causes and no way to tell them apart by looking. This is the
          // button that goes and finds out.
          deviceRecheckButton(context),
          const SizedBox(width: 4),
          if (_carriedNodeId != null) ...[
            Chip(
              avatar: const Icon(Icons.pan_tool_alt, size: 16),
              label: Text(
                'Placing: ${provider.rackOccupantLabel(_carriedNodeId!)}'
                ' - click a U, or type one',
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
          ] else if (unracked.isEmpty && loose.isEmpty)
            Text(
              provider.avNodes.any((n) => n.rackUnits > 0)
                  ? 'Every rack-mount device is placed.'
                  : 'No device has a rack height yet - press "Recheck '
                        'devices" to take the heights off the catalog, or set '
                        '"Rack U" in a device\'s edit dialog on the Signal '
                        'Flow page.',
              style: theme.textTheme.bodySmall,
            )
          else ...[
            Text(
              'To place - drag one in, or click it:',
              style: theme.textTheme.bodySmall,
            ),
            for (final n in unracked)
              Draggable<String>(
                data: n.id,
                dragAnchorStrategy: pointerDragAnchorStrategy,
                feedback: _dragGhost(n.label, _heightOf(n), theme),
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
            // Hardware waiting for a rail: added unplaced, or taken back out
            // of a frame. Dragged in exactly like a device — it is the same
            // payload, an id the U slots know how to fit — or clicked and
            // clicked, or deleted, since it is priced either way.
            for (final i in loose)
              Draggable<String>(
                data: i.id,
                dragAnchorStrategy: pointerDragAnchorStrategy,
                feedback: _dragGhost(i.label, math.max(1, i.rackUnits), theme),
                childWhenDragging: Opacity(
                  opacity: 0.35,
                  child: _looseHardwareChip(provider, i, onPressed: null),
                ),
                child: _looseHardwareChip(
                  provider,
                  i,
                  onPressed: () => setState(() => _carriedNodeId = i.id),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// A plate, shelf or drawer waiting to go in, shown in the toolbar beside
  /// the unracked devices. The × deletes it: it is on the estimate from the
  /// moment it is added, placed or not.
  Widget _looseHardwareChip(
    AppStateProvider provider,
    RackItem item, {
    required VoidCallback? onPressed,
  }) {
    return InputChip(
      avatar: Icon(iconForRackItem(item.category), size: 16),
      label: Text('${item.label} (${item.rackUnits}U)'),
      onPressed: onPressed,
      onDeleted: () => provider.removeAvRackItem(item.id),
      deleteIcon: const Icon(Icons.close, size: 16),
      tooltip: 'Not in a rack - drag it onto a U, or click it and click '
          'the U. × deletes it.',
    );
  }

  /// A device waiting to go in, shown in the toolbar.
  Widget _unrackedChip(
    AvNode n,
    ThemeData theme, {
    required VoidCallback? onPressed,
  }) {
    return ActionChip(
      avatar: Icon(iconForAvNode(n.id, n.model), size: 16),
      label: Text('${n.label} (${n.rackUnits}U)'),
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
                        '  ${rack.heightU}U'
                        '${rack.kind.isEmpty ? '' : ' · ${rack.kind}'}',
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
    // The rails something in this face wants kept empty. Computed once per
    // face rather than per slot: every rail has to ask the same question.
    final warnings = provider.rackClearanceWarnings(
      rackId: rack.id,
      face: face,
      heightU: rack.heightU,
    );

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
                  child: _buildUSlot(
                    provider,
                    rack,
                    face,
                    u,
                    theme,
                    warning: warnings[u],
                  ),
                ),
              // Devices.
              for (final entry in occupants)
                _buildRackedDevice(
                  provider,
                  rack,
                  face,
                  entry,
                  theme,
                  warnings: warnings,
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// One rail position, and one drop target. There is no need to aim at a
  /// slice: dropping onto a rail that is already occupied re-splits it and
  /// puts the new box alongside, which is how a shelf of small gear —
  /// a Revolabs receiver, a DTP receiver, a micro PC — gets recorded.
  Widget _buildUSlot(
    AppStateProvider provider,
    RackFrame rack,
    RackFace face,
    int u,
    ThemeData theme, {
    /// Why something already in this frame wants this rail left empty, or null
    /// when nothing does. See [AppStateProvider.rackClearanceWarnings].
    String? warning,
  }) {
    Widget rail() => SizedBox(
      width: kRailWidth,
      child: Center(
        child: Text(
          '$u',
          style: TextStyle(
            fontSize: 9,
            // The rail number goes red with the slot, so the warning is
            // legible on a printed elevation as well as on screen.
            color: warning == null ? theme.hintColor : kRackClearanceInk,
          ),
        ),
      ),
    );

    return Row(
      children: [
        rail(),
        Expanded(
          child: _buildDropZone(provider, rack, face, u, theme,
              warning: warning),
        ),
        rail(),
      ],
    );
  }

  Widget _buildDropZone(
    AppStateProvider provider,
    RackFrame rack,
    RackFace face,
    int u,
    ThemeData theme, {
    String? warning,
  }) {
    return DragTarget<String>(
      key: ValueKey('u_${rack.id}_${face.name}_$u'),
      onWillAcceptWithDetails: (details) =>
          _canDrop(provider, details.data, rack, face, u),
      onAcceptWithDetails: (details) =>
          _dropInto(provider, details.data, rack, face, u),
      builder: (ctx, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        final rejecting = rejected.isNotEmpty;
        // Only tint while something is in flight or in hand — an idle rack
        // should look like a rack, not a grid of buttons. The clearance shade
        // is the exception: it is a fact about the frame, and it is on the
        // drawing whether or not anybody is holding something.
        final carrying = _carriedNodeId != null;
        final zone = InkWell(
          onTap: carrying ? () => _place(provider, rack, face, u) : null,
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
                  : warning != null
                  ? kRackClearanceWash
                  : null,
            ),
          ),
        );
        if (warning == null) return zone;
        return Tooltip(
          message: '$warning\nYou can still put something here.',
          child: zone,
        );
      },
    );
  }

  /// Whether [nodeId] would fit here — drives the hover tint and the refusal,
  /// so the rack never lights up green for a drop it won't honour.
  bool _canDrop(
    AppStateProvider provider,
    String nodeId,
    RackFrame rack,
    RackFace face,
    int u,
  ) {
    // A rack item is as valid a payload as a device — both take up rails.
    if (provider.avNodeById(nodeId) == null &&
        provider.avRackItemById(nodeId) == null) {
      return false;
    }

    final occupants = provider.avRackOccupantsAt(
      rackId: rack.id,
      face: face,
      startU: u,
    )..remove(nodeId);
    if (occupants.length >= kMaxRackColumns) return false;

    // Alone on the rail it needs the whole width; sharing it only needs the
    // row not to be fouled by a taller neighbor, which the placer checks.
    if (occupants.isEmpty) {
      return provider.avRackSpanIsFree(
        rackId: rack.id,
        face: face,
        startU: u,
        heightU: provider.rackOccupantHeight(nodeId),
        ignoreNodeId: nodeId,
      );
    }
    return true;
  }

  void _dropInto(
    AppStateProvider provider,
    String nodeId,
    RackFrame rack,
    RackFace face,
    int u,
  ) {
    final ok = provider.avRackPlaceSharing(
      nodeId: nodeId,
      rackId: rack.id,
      face: face,
      startU: u,
    );
    if (!ok) {
      _snack('That rack unit has no room for it.', error: true);
      return;
    }
    setState(() {
      _carriedNodeId = null;
      _typedRackId = rack.id;
      _typedFace = face;
      _uController.clear();
    });
  }

  /// The little block that follows the cursor during a drag.
  Widget _dragGhost(String label, int heightU, ThemeData theme) {
    // How wide it will end up depends on what is already on the target rail,
    // which isn't known mid-drag, so the ghost is a fixed, compact size.
    const width = kRackInnerWidth / 2;
    return Material(
      color: Colors.transparent,
      child: Opacity(
        opacity: 0.85,
        child: Container(
          width: width,
          height: heightU * kUHeight,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: theme.colorScheme.primary, width: 2),
          ),
          child: Row(
            children: [
              const Icon(Icons.drag_indicator, size: 13),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  label,
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
    ThemeData theme, {
    /// The face's kept-clear rails, so a box standing IN one says so. This is
    /// the case the shading exists for — an empty red rail is a reminder, a
    /// full one is the thing that fails on site.
    Map<int, String> warnings = const {},
  }) {
    final node = provider.avNodeById(entry.key);
    // A rail can hold a device OR a piece of rack hardware; both are keyed
    // into the same slot map, because both take up rails.
    final item = node == null ? provider.avRackItemById(entry.key) : null;
    if (node == null && item == null) return const SizedBox.shrink();
    final height = node != null ? _heightOf(node) : math.max(1, item!.rackUnits);
    final label = node?.label ?? item!.label;
    final slot = entry.value;
    final dark = theme.brightness == Brightness.dark;

    // Hardware says what it is and what it costs; a device's own tooltip is
    // already covered by the lines below.
    final String hardwareLine = item == null
        ? ''
        : '${item.category.isEmpty ? 'Rack hardware' : item.category}'
              '${item.price > 0 ? ' · '
                    '${formatMoney(item.price, provider.avCost.currency)}' : ''}'
              '\n';

    // startU is the BOTTOM rail, so the block's top is heightU - (startU + h - 1)
    // units down from the top of the frame.
    final topU = rack.heightU - (slot.startU + height - 1);

    // The rail is divided into slice.columns equal pieces and this device
    // sits in slice.column of them.
    final slice = slot.slice;
    final bool shared = slice.columns > 1;
    final double blockWidth = kRackInnerWidth / slice.columns;
    final double left = kRailWidth + kRackInnerWidth * slice.start;

    // Standing on a rail its neighbour asked to be left empty. The warning is
    // its OWN clearance ignored as readily as anyone else's — a box with a
    // rail to keep clear below it, dropped straight on top of another, is the
    // same mistake seen from the other end.
    final fouled = [
      for (int u = slot.startU; u <= slot.startU + height - 1; u++)
        if (warnings[u] != null) warnings[u]!,
    ];

    return Positioned(
      left: left,
      width: blockWidth,
      top: topU * kUHeight,
      height: height * kUHeight,
      child: Tooltip(
        message:
            '$label\n'
            '$hardwareLine'
            'U${slot.startU}'
            '${height == 1 ? '' : '–U${slot.startU + height - 1}'}'
            '${shared ? ' · ${slice.label} of the rail' : ''}'
            '${fouled.isEmpty ? '' : '\n⚠ ${fouled.join('\n⚠ ')}'}'
            '${widget.editMode ? '\nDrag to move • click to pick up • '
                      'double-click to type a U • right-click for replace, '
                      'edit and un-rack' : ''}',
        // A placed device covers the rail's drop target, so it has to accept
        // drops itself and pass them to the same sharing placer — otherwise a
        // second box could never be dropped onto an occupied rail.
        child: DragTarget<String>(
          onWillAcceptWithDetails: (d) =>
              d.data != entry.key &&
              _canDrop(provider, d.data, rack, face, slot.startU),
          onAcceptWithDetails: (d) =>
              _dropInto(provider, d.data, rack, face, slot.startU),
          builder: (ctx, candidate, rejected) => _draggableIfEditing(
            provider,
            entry.key,
            theme,
            GestureDetector(
              onTap: widget.editMode
                  // Carrying something already? Then a click here means "put
                  // it on this rail too", not "pick this one up instead".
                  ? () => _carriedNodeId != null &&
                            _carriedNodeId != entry.key
                        ? _place(provider, rack, face, slot.startU)
                        : setState(() => _carriedNodeId = entry.key)
                  : null,
            // Typing the position beats dragging when the frame is tall or the
            // device needs to land on an exact U.
              onDoubleTap: widget.editMode
                  ? () => item != null
                        ? _showHardwareEditDialog(provider, item)
                        : _showPlacementDialog(provider, entry.key)
                  : null,
              // RIGHT-CLICK USED TO UN-RACK, full stop. It still can, from
              // the menu — which is also where "this is the wrong part"
              // finally lives: the rack elevation is where a vent plate turns
              // out to be a fan panel, and until now the only way to say so
              // was to delete it, add the right one and place it again.
              onSecondaryTapDown: widget.editMode
                  ? (d) => _showRackBlockMenu(
                      provider,
                      entry.key,
                      d.globalPosition,
                    )
                  : null,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 1, horizontal: 2),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  // Hardware is drawn flatter and grayer than a device: a rack
                  // full of blanking plates should read as the background it
                  // is, with the boxes that do something standing out of it.
                  color: candidate.isNotEmpty
                      ? theme.colorScheme.primary.withValues(alpha: 0.35)
                      : item != null
                      ? (dark
                            ? const Color(0xFF1C2127)
                            : const Color(0xFFE7EAEE))
                      : (dark
                            ? const Color(0xFF283039)
                            : const Color(0xFFD7DEE8)),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color: fouled.isEmpty
                        ? theme.colorScheme.outlineVariant
                        : kRackClearanceInk,
                    width: fouled.isEmpty ? 1 : 1.6,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      item != null
                          ? iconForRackItem(item.category)
                          : iconForAvNode(entry.key, node?.model ?? ''),
                      size: 13,
                      color: item != null ? theme.hintColor : null,
                    ),
                    const SizedBox(width: 5),
                    if (fouled.isNotEmpty) ...[
                      const Icon(
                        Icons.warning_amber_rounded,
                        size: 13,
                        color: kRackClearanceInk,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        label,
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!shared)
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
    ThemeData theme,
    Widget child,
  ) {
    if (!widget.editMode) return child;
    return Draggable<String>(
      data: nodeId,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _dragGhost(
        provider.rackOccupantLabel(nodeId),
        provider.rackOccupantHeight(nodeId),
        theme,
      ),
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
    final kindController = TextEditingController(
      text: existing?.kind ?? kRackKinds.first,
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
                  runSpacing: 6,
                  children: [
                    // Heights only. Where the frame lives is the Type field
                    // below — a 12U frame is as likely to be under a lectern
                    // as on a wall.
                    for (final u in kRackHeightPresets)
                      ActionChip(
                        label: Text('${u}U'),
                        onPressed: () =>
                            setLocal(() => heightController.text = '$u'),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: kRackKinds.contains(kindController.text)
                      ? kindController.text
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Type',
                    helperText: 'Where this frame lives',
                  ),
                  items: [
                    for (final k in kRackKinds)
                      DropdownMenuItem(value: k, child: Text(k)),
                  ],
                  onChanged: (v) =>
                      setLocal(() => kindController.text = v ?? ''),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: kindController,
                  decoration: const InputDecoration(
                    labelText: 'Type (or type your own)',
                  ),
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

    final kind = kindController.text.trim();

    if (existing == null) {
      provider.addAvRack(
        name.isEmpty ? 'Rack ${provider.avRacks.length + 1}' : name,
        height,
        kind: kind,
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
        kind: kind,
      ),
    );

    if (stranded.isNotEmpty) {
      _snack(
        '${stranded.length} device${stranded.length == 1 ? '' : 's'} '
        'un-racked - ${stranded.length == 1 ? 'it no longer fits' : 'they no '
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
    // Where along a shared rail it sits. 1-based, because a row of gear reads
    // as "first, second, third", not from zero.
    int position = (slot?.slice.column ?? 0) + 1;

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
                // Width isn't a property of the device any more: it comes
                // from how many boxes share the rail. All this offers is the
                // order along it.
                if ((slot?.slice.columns ?? 1) > 1) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Shares U${slot!.startU} with '
                          '${slot.slice.columns - 1} other'
                          '${slot.slice.columns == 2 ? '' : 's'}. Position:',
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                      ),
                      SegmentedButton<int>(
                        segments: [
                          for (int i = 1; i <= slot.slice.columns; i++)
                            ButtonSegment(value: i, label: Text('$i')),
                        ],
                        selected: {position},
                        onSelectionChanged: (v) =>
                            setLocal(() => position = v.first),
                      ),
                    ],
                  ),
                ],
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

    // Height lives on the DEVICE, not the slot, so write it back before the
    // span is measured against it.
    if (height != node.rackUnits) {
      provider.updateAvNode(node.copyWith(rackUnits: height));
    }

    // Staying on the rail it is already on: this is a re-order, not a move.
    final sameRow =
        slot != null &&
        slot.rackId == rackId &&
        slot.face == face &&
        slot.startU == startU;
    if (sameRow && slot.slice.columns > 1) {
      provider.avRackReorderRow(nodeId, position - 1);
      return;
    }

    if (!provider.avRackPlaceSharing(
      nodeId: nodeId,
      rackId: rackId,
      face: face,
      startU: startU,
    )) {
      _snack('U$startU has no room for it.', error: true);
      return;
    }
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

  // -------------------------------------------------------------------------
  //  RACK HARDWARE — the parts list
  // -------------------------------------------------------------------------

  /// Adds a vent plate, blank, shelf or drawer from the parts list.
  ///
  /// The parts list IS the device catalog, filtered to the rack categories.
  /// One store rather than two: an entry there already carries a rack height,
  /// a part number and a price, which is exactly what a plate needs, and
  /// keeping a second list would mean two places to revise a price and two
  /// answers to what a 2U blank costs.
  Future<void> _showAddHardwareDialog(AppStateProvider provider) async {
    if (provider.avRacks.isEmpty) return;
    final library = provider.avDeviceLibrary;
    final parts = library.rackHardware;

    final searchController = TextEditingController();
    final uController = TextEditingController(text: '1');
    final qtyController = TextEditingController(text: '1');
    String? selectedModel = parts.isEmpty ? null : parts.first.model;
    String rackId = provider.avRacks.first.id;
    RackFace face = RackFace.front;
    // Blanks and vents almost always go on the front; a lacing bar almost
    // never does, but that is a click away rather than a guess worth making.

    final created = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final matches = searchCatalog(parts, searchController.text,
              limit: parts.length);
          return AlertDialog(
            title: const Text('Add rack hardware'),
            content: SizedBox(
              width: 560,
              height: math.min(560, MediaQuery.of(ctx).size.height - 200),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Plates, shelves and drawers occupy rails like any other '
                    'part, and are priced into the estimate. Edit or add to '
                    'the list on the Catalog tab.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: searchController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Search the parts list',
                      prefixIcon: Icon(Icons.search, size: 20),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: matches.isEmpty
                        ? Center(
                            child: Text(
                              parts.isEmpty
                                  ? 'The parts list is empty. Add entries on '
                                        'the Catalog tab under a rack '
                                        'category (Vent plate, Blank plate, '
                                        'Shelf, Drawer).'
                                  : 'Nothing matches that search.',
                              textAlign: TextAlign.center,
                              style: Theme.of(ctx).textTheme.bodySmall,
                            ),
                          )
                        : ListView.builder(
                            itemCount: matches.length,
                            itemBuilder: (ctx, i) {
                              final t = matches[i];
                              return ListTile(
                                dense: true,
                                selected: t.model == selectedModel,
                                leading: Icon(
                                  iconForRackItem(t.category),
                                  size: 20,
                                ),
                                title: Text(
                                  t.model,
                                  style: const TextStyle(fontSize: 13),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  [
                                    if (t.category.isNotEmpty) t.category,
                                    '${t.rackUnits}U',
                                    t.price > 0
                                        ? formatMoney(
                                            t.price,
                                            provider.avCost.currency,
                                          )
                                        : 'not priced',
                                    if (t.partNumber.isNotEmpty) t.partNumber,
                                  ].join(' · '),
                                  style: const TextStyle(fontSize: 11),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => setLocal(() {
                                  selectedModel = t.model;
                                  // The height comes from the part, not from
                                  // whatever was left in the box.
                                  uController.text = '1';
                                }),
                              );
                            },
                          ),
                  ),
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: rackId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Rack',
                            isDense: true,
                          ),
                          items: [
                            for (final r in provider.avRacks)
                              DropdownMenuItem(
                                value: r.id,
                                child: Text('${r.name} (${r.heightU}U)'),
                              ),
                          ],
                          onChanged: (v) => setLocal(() => rackId = v ?? rackId),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SegmentedButton<RackFace>(
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                        ),
                        segments: const [
                          ButtonSegment(
                            value: RackFace.front,
                            label: Text('Front'),
                          ),
                          ButtonSegment(
                            value: RackFace.rear,
                            label: Text('Rear'),
                          ),
                        ],
                        selected: {face},
                        onSelectionChanged: (s) =>
                            setLocal(() => face = s.first),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      SizedBox(
                        width: 130,
                        child: TextField(
                          controller: uController,
                          decoration: const InputDecoration(
                            labelText: 'Bottom rail (U)',
                            helperText: 'U1 is the floor',
                            isDense: true,
                          ),
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 130,
                        child: TextField(
                          controller: qtyController,
                          decoration: const InputDecoration(
                            labelText: 'How many',
                            helperText: 'stacked upwards',
                            isDense: true,
                          ),
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Ordering a shelf and knowing which rail it lands on are
                  // two different moments, and the parts are usually ordered
                  // first. "Add unplaced" is that moment: it puts the item in
                  // the waiting area at the top of the page, on the estimate
                  // and off the elevation, until somebody drags it in.
                  Text(
                    'Not sure where it goes yet? Add unplaced and it waits in '
                    'the toolbar until you drag it onto a U.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('cancel'),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: selectedModel == null
                    ? null
                    : () => Navigator.of(ctx).pop('hold'),
                child: const Text('Add unplaced'),
              ),
              ElevatedButton(
                onPressed: selectedModel == null
                    ? null
                    : () => Navigator.of(ctx).pop('add'),
                child: const Text('Add to rack'),
              ),
            ],
          );
        },
      ),
    );

    if (created != 'add' && created != 'hold') return;
    final template = library.templateForModel(selectedModel ?? '');
    if (template == null) return;

    // 'hold' is the same add with nowhere to put it yet: the items go on the
    // parts list and into the waiting area, and a drag lands them on a rail.
    final bool place = created == 'add';
    final startU = math.max(1, int.tryParse(uController.text.trim()) ?? 1);
    final qty = (int.tryParse(qtyController.text.trim()) ?? 1).clamp(1, 42);
    final heightU = math.max(1, template.rackUnits);

    // Several of the same plate stack up from the U asked for, because that is
    // what filling the top of a rack with blanks actually is.
    int added = 0;
    int u = startU;
    for (int i = 0; i < qty; i++) {
      final item = RackItem(
        id: '',
        catalogModel: template.model,
        label: template.model,
        category: template.category,
        partNumber: template.partNumber,
        rackUnits: heightU,
        price: template.price,
      );
      final stored = provider.addAvRackItem(
        item,
        rackId: place ? rackId : null,
        face: face,
        startU: place ? u : null,
      );
      if (stored != null) added++;
      u += heightU;
    }

    if (!mounted) return;
    if (!place) {
      // An unplaced add cannot fail to fit — there is nothing to fit into.
      _snack(
        '$added × ${template.model} waiting to be placed - drag one onto a U, '
        'or click it and click the U.',
      );
      return;
    }
    _snack(
      added == qty
          ? '$qty × ${template.model} added from U$startU up.'
          : added == 0
          ? 'Nothing added - U$startU up is already occupied. '
                'Add them unplaced and drag them in.'
          : '$added of $qty added; the rest had nowhere to go.',
      error: added < qty,
    );
  }

  /// Adds a box that is going in the rack and is not in the catalog — a Cisco
  /// switch, an owner-furnished appliance, the mini PC on the shelf.
  ///
  /// Deliberately NOT a catalog entry. A model nobody has a part number or a
  /// price for is not a price-list fact, and writing it into av_devices.json
  /// would put an unpriced entry in front of every future room. It is a fact
  /// about THIS job, so it lives on the room like any other placed item: it
  /// takes up rails on the elevation, and it appears on the estimate — under
  /// Equipment rather than Rack hardware, since it is a box — flagged "Not
  /// priced" until somebody types a figure, either on the estimate's line or
  /// back here in the item's own edit dialog.
  Future<void> _showAddCustomDeviceDialog(AppStateProvider provider) async {
    if (provider.avRacks.isEmpty) return;

    final nameController = TextEditingController();
    final partController = TextEditingController();
    final heightController = TextEditingController(text: '1');
    final uController = TextEditingController(text: '1');
    final qtyController = TextEditingController(text: '1');
    final priceController = TextEditingController();
    final notesController = TextEditingController();
    String category = kRackDeviceCategories.first;
    String rackId = provider.avRacks.first.id;
    RackFace face = RackFace.front;

    final created = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Add a device that is not in the catalog'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'For the box that is going in the rack and has no catalog '
                    'entry. It occupies rails like anything else and is quoted '
                    'with the equipment. Leave the price blank and the cost '
                    'sheet flags it as needing one.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'e.g. Cisco Catalyst 9300-24P',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: kRackDeviceCategories.contains(category)
                        ? category
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Kind',
                      helperText: 'What it is, for the estimate',
                      isDense: true,
                    ),
                    items: [
                      for (final c in kRackDeviceCategories)
                        DropdownMenuItem(value: c, child: Text(c)),
                    ],
                    onChanged: (v) => setLocal(() => category = v ?? category),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: partController,
                          decoration: const InputDecoration(
                            labelText: 'Part number (optional)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 120,
                        child: TextField(
                          controller: heightController,
                          decoration: const InputDecoration(
                            labelText: 'Height (U)',
                            isDense: true,
                          ),
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: priceController,
                    decoration: InputDecoration(
                      labelText: 'Price each (${provider.avCost.currency})',
                      helperText:
                          'Blank = the cost sheet reports it as not priced',
                      isDense: true,
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: notesController,
                    decoration: const InputDecoration(
                      labelText: 'Note (optional)',
                      isDense: true,
                    ),
                  ),
                  const Divider(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: rackId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Rack',
                            isDense: true,
                          ),
                          items: [
                            for (final r in provider.avRacks)
                              DropdownMenuItem(
                                value: r.id,
                                child: Text('${r.name} (${r.heightU}U)'),
                              ),
                          ],
                          onChanged: (v) =>
                              setLocal(() => rackId = v ?? rackId),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SegmentedButton<RackFace>(
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                        ),
                        segments: const [
                          ButtonSegment(
                            value: RackFace.front,
                            label: Text('Front'),
                          ),
                          ButtonSegment(
                            value: RackFace.rear,
                            label: Text('Rear'),
                          ),
                        ],
                        selected: {face},
                        onSelectionChanged: (s) =>
                            setLocal(() => face = s.first),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      SizedBox(
                        width: 130,
                        child: TextField(
                          controller: uController,
                          decoration: const InputDecoration(
                            labelText: 'Bottom rail (U)',
                            helperText: 'U1 is the floor',
                            isDense: true,
                          ),
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 130,
                        child: TextField(
                          controller: qtyController,
                          decoration: const InputDecoration(
                            labelText: 'How many',
                            helperText: 'stacked upwards',
                            isDense: true,
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
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('cancel'),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: nameController.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(ctx).pop('hold'),
              child: const Text('Add unplaced'),
            ),
            ElevatedButton(
              onPressed: nameController.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(ctx).pop('add'),
              child: const Text('Add to rack'),
            ),
          ],
        ),
      ),
    );

    if (created != 'add' && created != 'hold') return;
    final name = nameController.text.trim();
    if (name.isEmpty) return;

    final bool place = created == 'add';
    final heightU = math.max(1, int.tryParse(heightController.text.trim()) ?? 1);
    final startU = math.max(1, int.tryParse(uController.text.trim()) ?? 1);
    final qty = (int.tryParse(qtyController.text.trim()) ?? 1).clamp(1, 42);
    final price = double.tryParse(priceController.text.trim()) ?? 0;

    int added = 0;
    int u = startU;
    for (int i = 0; i < qty; i++) {
      final stored = provider.addAvRackItem(
        RackItem(
          id: '',
          label: name,
          category: category,
          partNumber: partController.text.trim(),
          rackUnits: heightU,
          price: price,
          notes: notesController.text.trim(),
        ),
        rackId: place ? rackId : null,
        face: face,
        startU: place ? u : null,
      );
      if (stored != null) added++;
      u += heightU;
    }

    if (!mounted) return;
    final pricedNote = price > 0
        ? ''
        : ' It is on the cost sheet under Equipment, flagged as not priced - '
              'type a price there or here.';
    if (!place) {
      _snack('$added × $name waiting to be placed.$pricedNote');
      return;
    }
    _snack(
      added == qty
          ? '$qty × $name added from U$startU up.$pricedNote'
          : added == 0
          ? 'Nothing added - U$startU up is already occupied. '
                'Add it unplaced and drag it in.'
          : '$added of $qty added; the rest had nowhere to go.$pricedNote',
      error: added < qty,
    );
  }

  /// Edits or removes one placed piece of hardware. The price is editable
  /// here because a plate bought for this job at a different price is a fact
  /// about this job, and should not rewrite the parts list.
  /// The menu on a block in a frame: replace the part, open its editor, or
  /// take it off the rail.
  ///
  /// A menu rather than three gestures, because two of these had nowhere to be
  /// discovered — the un-rack was a right-click nobody was told about, and
  /// replacing a part could only be done from the Cost tab.
  Future<void> _showRackBlockMenu(
    AppStateProvider provider,
    String id,
    Offset at,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final item = provider.avRackItemById(id);
    final node = item == null ? provider.avNodeById(id) : null;
    if (item == null && node == null) return;

    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'replace',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.find_replace, size: 18),
            title: const Text('Replace with...'),
            subtitle: Text(
              item != null
                  ? 'Another part from the catalog'
                  : 'Another model - connectors, rack height and cables move '
                        'with it',
            ),
          ),
        ),
        const PopupMenuItem(
          value: 'edit',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_note, size: 18),
            title: Text('Edit...'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'unrack',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.eject_outlined, size: 18),
            title: Text('Un-rack'),
            subtitle: Text('Stays in the room, off the rail'),
          ),
        ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'replace':
        await _replaceRacked(provider, id);
      case 'edit':
        if (item != null) {
          await _showHardwareEditDialog(provider, item);
        } else {
          await _showPlacementDialog(provider, id);
        }
      case 'unrack':
        provider.setAvRackSlot(id, null);
    }
  }

  /// Puts a different product under one block in a frame.
  ///
  /// Two kinds of block and two catalogs: a piece of rack hardware takes the
  /// parts list, a device takes the equipment list and brings its connectors,
  /// its power and the runs already drawn on it across — the same swap the
  /// quote makes, made where the elevation is being read.
  Future<void> _replaceRacked(AppStateProvider provider, String id) async {
    final item = provider.avRackItemById(id);
    final node = item == null ? provider.avNodeById(id) : null;
    final library = provider.avDeviceLibrary;
    final picked = await pickCatalogModel(
      context,
      provider,
      title: 'Replace ${item?.label ?? node?.label ?? ''}',
      actionLabel: 'Replace',
      currentModel: item != null ? item.catalogModel : (node?.model ?? ''),
      only: item != null ? library.rackHardware : library.equipment,
      note: item != null
          ? 'It keeps its rail if the new part still fits on it, and comes off '
                'it if it does not.'
          : 'The connectors come with it, the room config follows, and cables '
                'are carried over to the matching connector wherever there is '
                'one. This room\'s own settings - the address, the port - are '
                'kept.',
    );
    if (!mounted || picked == null) return;
    final messenger = ScaffoldMessenger.of(context);

    if (item != null) {
      final kept = provider.swapAvRackItem(item, picked);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${item.label} is now a ${picked.model}'
            '${kept ? '' : ' — it does not fit where it was, so it has come '
                  'off its rail'}.',
          ),
          duration: kept
              ? const Duration(seconds: 4)
              : const Duration(seconds: 8),
        ),
      );
      return;
    }

    final was = node!.model;
    final result = applyModelSwap(provider, node, picked);
    // A box seeded from the config carries the config's own section key as its
    // id, so the block behind it is found without anything having to be stored
    // to link them. Nothing to do when the drawing is all there is.
    final configured = provider.roomConfig[node.id] is Map;
    if (configured) applyControlSwap(provider, [node.id], picked.model);
    final module = provider.moduleForModel(picked.model);

    final said = [
      '${node.label} is now a ${picked.model}',
      if (was.trim().isEmpty) 'it had no model before',
      if (result.carried > 0)
        '${result.carried} cable${result.carried == 1 ? '' : 's'} carried '
            'across',
      if (result.dropped > 0)
        '${result.dropped} cable${result.dropped == 1 ? '' : 's'} dropped - '
            'the new model has no matching connector, so draw '
            '${result.dropped == 1 ? 'it' : 'them'} again on the Signal Flow '
            'page',
      if (configured && module.isEmpty)
        'no control module claims it, so the module was cleared - the Devices '
            'tab is showing it in red until one is picked',
      if (configured && module.isNotEmpty)
        'the config block moved to $module with this room\'s settings kept',
    ].join('. ');
    messenger.showSnackBar(
      SnackBar(
        content: Text('$said.'),
        duration: result.dropped > 0 || (configured && module.isEmpty)
            ? const Duration(seconds: 8)
            : const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _showHardwareEditDialog(
    AppStateProvider provider,
    RackItem item,
  ) async {
    final labelController = TextEditingController(text: item.label);
    final uController = TextEditingController(
      text: item.rackUnits.toString(),
    );
    final priceController = TextEditingController(
      text: item.price <= 0 ? '' : trimNumber(item.price),
    );
    final notesController = TextEditingController(text: item.notes);
    // Both lists, because a rail holds parts AND boxes and this is the dialog
    // for either. Which list the kind comes from is what decides whether the
    // estimate quotes it as rack hardware or as equipment, so re-typing a
    // Cisco switch as a "Blank plate" here must be possible — and must not
    // happen by accident because the dropdown had nowhere else to land.
    final kinds = [...kRackDeviceCategories, ...kRackItemCategories];
    String category = kinds.contains(item.category)
        ? item.category
        : kRackItemCategories.last;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(item.label),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: labelController,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Kind',
                    helperText: 'Rack parts are quoted as hardware; '
                        'everything else as equipment',
                  ),
                  items: [
                    for (final c in kinds)
                      DropdownMenuItem(value: c, child: Text(c)),
                  ],
                  onChanged: (v) => setLocal(() => category = v ?? category),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: uController,
                        decoration: const InputDecoration(
                          labelText: 'Height (U)',
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
                        controller: priceController,
                        decoration: InputDecoration(
                          labelText: 'Price (${provider.avCost.currency})',
                          helperText: item.catalogModel.isEmpty
                              ? 'blank = not priced'
                              : 'blank = use the parts list price',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesController,
                  decoration: const InputDecoration(labelText: 'Note'),
                ),
                if (item.catalogModel.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'From the parts list: ${item.catalogModel}',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('remove'),
              child: Text(
                'Remove',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
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
    if (result == 'remove') {
      provider.removeAvRackItem(item.id);
      return;
    }
    if (result == 'unrack') {
      provider.setAvRackSlot(item.id, null);
      return;
    }

    provider.updateAvRackItem(
      item.copyWith(
        label: labelController.text.trim().isEmpty
            ? item.label
            : labelController.text.trim(),
        category: category,
        rackUnits: math.max(1, int.tryParse(uController.text.trim()) ?? 1),
        price: double.tryParse(priceController.text.trim()) ?? 0,
        notes: notesController.text.trim(),
      ),
    );
  }
}

/// Icon for a piece of rack hardware, by kind. Deliberately plainer than the
/// device icons — these are the parts that fill the gaps.
IconData iconForRackItem(String category) {
  switch (category.trim().toLowerCase()) {
    case 'vent plate':
      return Icons.grid_on;
    case 'blank plate':
    case 'plate':
      return Icons.crop_16_9;
    case 'shelf':
    case 'clamping shelf':
      return Icons.table_rows;
    case 'drawer':
      return Icons.inbox;
    case 'cable management':
      return Icons.cable;
    // The boxes on the rails that came in through "Add other device" — drawn
    // as gear rather than as a part, because that is what they are.
    case 'network switch':
      return Icons.lan;
    case 'computer':
      return Icons.computer;
    case 'appliance':
    case 'other equipment':
      return Icons.developer_board;
    case 'amplifier':
      return Icons.speaker;
    case 'power':
      return Icons.power;
    default:
      return Icons.hardware;
  }
}
