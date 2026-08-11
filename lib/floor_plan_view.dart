import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'av_flow_model.dart';
import 'av_flow_report.dart';
import 'av_flow_view.dart' show buildAvFlowModel;
import 'diagram_capture.dart';
import 'export_tools.dart';
import 'report_tools.dart';
import 'room_locations.dart';
import 'room_locations_view.dart';
import 'screenshot_tools.dart';
import 'view_zoom.dart';

/// ============================================================================
///  FLOOR PLAN TAB
/// ============================================================================
///  The room seen from above, with the drawing set's cross-references on it.
///
///  Three things live here that have nowhere else to go:
///
///    1. WHERE THINGS ARE. The room's locations get dragged onto the plan, so
///       "front floor box" stops being a phrase and becomes a spot somebody
///       can point at. Every device and jack field naming that location is
///       then placed by implication, which is the only way this stays worth
///       maintaining — nobody drags forty boxes onto a plan.
///
///    2. THE CALL-OUTS. A numbered marker that says "the rack shown here is
///       Rack 1, described on the Racks tab of the workbook". A drawing set is
///       read by cross-reference and the plan is where the references start.
///       The app resolves the target's NAME itself, so renaming a rack cannot
///       leave the plan pointing at a name that no longer exists.
///
///    3. THE COUNTS. Runs and jacks per location, across the top, live. This
///       is the number somebody orders back boxes and conduit against, and
///       having it on the same page as the plan is what makes it get checked.
///
///  The plan image is a file beside the config — see
///  [AppStateProvider.importFloorPlanImage]. A room folder is the unit that
///  gets zipped and mailed, so the plan travels with it rather than being
///  embedded in a sidecar that is otherwise hand-readable.
/// ============================================================================

class FloorPlanView extends StatefulWidget {
  const FloorPlanView({super.key});

  @override
  State<FloorPlanView> createState() => _FloorPlanViewState();
}

class _FloorPlanViewState extends State<FloorPlanView> {
  final GlobalKey _planKey = GlobalKey();
  final GlobalKey _viewportKey = GlobalKey();
  final TransformationController _transform = TransformationController();

  /// What a click on the plan drops. Off by default: the common visit is to
  /// look at the plan, not to edit it, and a page where every stray click
  /// leaves a marker behind is a page people stop clicking on.
  _PlanTool _tool = _PlanTool.none;

  /// The decoded plan image, and the file it came from.
  ImageProvider? _image;
  String _imagePath = '';
  Size _imageSize = const Size(1200, 900);

  String? _selectedCalloutId;

  @override
  void initState() {
    super.initState();
    registerDiagramCanvas(AppTab.floorPlan, _planKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<AppStateProvider>();
      provider.ensureAvFlowForCurrentConfig();
      _syncImage(provider);
    });
  }

  @override
  void dispose() {
    unregisterDiagramCanvas(AppTab.floorPlan, _planKey);
    _transform.dispose();
    super.dispose();
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: error ? Colors.red : null),
    );
  }

  void _syncImage(AppStateProvider provider) {
    final plan = provider.primaryFloorPlan;
    final resolved = plan == null
        ? ''
        : provider.resolveFloorPlanImage(plan.imageFile);
    if (resolved == _imagePath) return;
    setState(() {
      _imagePath = resolved;
      _image = resolved.isEmpty || !File(resolved).existsSync()
          ? null
          : FileImage(File(resolved));
      _imageSize = plan?.imageSize ?? const Size(1200, 900);
    });
  }

  // --- importing ------------------------------------------------------------

  Future<void> _importPlan(AppStateProvider provider) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Choose a floor plan image',
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'bmp', 'gif', 'webp'],
    );
    final picked = result?.files.single.path;
    if (picked == null) return;

    // The natural size is read here rather than assumed: markers are stored in
    // the image's own coordinates, so a plan that opens at a different size
    // than it was marked up at would move every one of them.
    Size size;
    try {
      final bytes = await File(picked).readAsBytes();
      final decoded = await ui.instantiateImageCodec(bytes);
      final frame = await decoded.getNextFrame();
      size = Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
      frame.image.dispose();
    } catch (e) {
      _snack('That file could not be read as an image: $e', error: true);
      return;
    }

    final stored = await provider.importFloorPlanImage(picked);
    if (!mounted) return;

    final existing = provider.primaryFloorPlan;
    if (existing == null) {
      provider.addAvFloorPlan(
        FloorPlan(
          id: '',
          name: 'Floor plan',
          imageFile: stored,
          imageSize: size,
        ),
      );
    } else {
      // Replacing the image keeps the callouts and the location markers. They
      // are in the plan's coordinates, so a revised drawing of the same room
      // at the same size lands them exactly where they were — which is the
      // whole reason to re-import rather than start again.
      provider.updateAvFloorPlan(
        existing.copyWith(imageFile: stored, imageSize: size),
      );
      if (size != existing.imageSize) {
        _snack(
          'The new drawing is a different size, so the markers may need '
          'nudging.',
        );
      }
    }
    _syncImage(provider);
  }

  // --- exporting ------------------------------------------------------------

  Future<void> _exportPng(AppStateProvider provider) async {
    final bytes = await captureBoundary(_planKey, pixelRatio: 2.0);
    if (bytes == null) {
      _snack('Could not render the plan to an image.', error: true);
      return;
    }
    String? outputFile = await FilePicker.saveFile(
      dialogTitle: 'Save the floor plan image',
      fileName: '${roomFileStem(provider, 'floor_plan')}.png',
      type: FileType.custom,
      allowedExtensions: const ['png'],
    );
    if (outputFile == null) return;
    if (!outputFile.toLowerCase().endsWith('.png')) outputFile += '.png';
    try {
      await File(outputFile).writeAsBytes(bytes);
      _snack('Floor plan saved as $outputFile');
    } catch (e) {
      _snack('Failed to save the image: $e', error: true);
    }
  }

  Future<void> _exportReport(AppStateProvider provider) async {
    final model = buildAvFlowModel(provider);
    final sections = locationSections(model);
    if (sections.isEmpty) {
      _snack('Nothing to report yet — no locations, runs or callouts.');
      return;
    }
    String? outputFile = await FilePicker.saveFile(
      dialogTitle: 'Save the location report',
      fileName: '${roomFileStem(provider, 'locations')}.txt',
      type: FileType.custom,
      allowedExtensions: const ['txt'],
    );
    if (outputFile == null) return;
    if (!outputFile.toLowerCase().endsWith('.txt')) outputFile += '.txt';
    try {
      await File(outputFile).writeAsString(
        renderTextReport(
          model.roomTitle.isEmpty ? 'Floor plan' : model.roomTitle,
          sections,
        ),
      );
      _snack('Location report saved as $outputFile');
    } catch (e) {
      _snack('Failed to save the report: $e', error: true);
    }
  }

  // --- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    if (provider.roomConfig.isEmpty) {
      return const Center(child: Text('No configuration loaded.'));
    }
    final model = buildAvFlowModel(provider);
    final plan = provider.primaryFloorPlan;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncImage(provider);
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _toolbar(provider, plan),
        const Divider(height: 1),
        _CountStrip(model: model),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              Expanded(
                key: _viewportKey,
                child: plan == null
                    ? _emptyState(provider)
                    : InteractiveViewer(
                        transformationController: _transform,
                        constrained: false,
                        minScale: 0.08,
                        maxScale: 4.0,
                        boundaryMargin: const EdgeInsets.all(400),
                        child: RepaintBoundary(
                          key: _planKey,
                          child: _plan(provider, model, plan),
                        ),
                      ),
              ),
              const VerticalDivider(width: 1, thickness: 1),
              SizedBox(
                width: 320,
                child: _sidePanel(provider, model, plan),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _toolbar(AppStateProvider provider, FloorPlan? plan) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('Floor Plan', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 4),
          OutlinedButton.icon(
            icon: const Icon(Icons.image_outlined, size: 18),
            label: Text(plan == null ? 'Import a plan' : 'Replace the image'),
            onPressed: () => _importPlan(provider),
          ),
          if (plan != null) ...[
            FilterChip(
              avatar: const Icon(Icons.add_location_alt_outlined, size: 18),
              label: const Text('Place locations'),
              selected: _tool == _PlanTool.location,
              onSelected: (v) => setState(
                () => _tool = v ? _PlanTool.location : _PlanTool.none,
              ),
            ),
            FilterChip(
              avatar: const Icon(Icons.pin_drop_outlined, size: 18),
              label: const Text('Add callouts'),
              selected: _tool == _PlanTool.callout,
              onSelected: (v) => setState(
                () => _tool = v ? _PlanTool.callout : _PlanTool.none,
              ),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.fit_screen, size: 18),
              label: const Text('Fit to view'),
              onPressed: () {
                final fitted = fitToViewport(
                  controller: _transform,
                  contentKey: _planKey,
                  viewportKey: _viewportKey,
                );
                if (!fitted) _snack('The plan is still drawing — try again.');
              },
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Plan settings'),
              onPressed: () => _showPlanSettings(provider, plan),
            ),
          ],
          OutlinedButton.icon(
            icon: const Icon(Icons.place_outlined, size: 18),
            label: Text('Locations (${provider.avLocations.length})'),
            onPressed: () => showLocationManager(context, provider),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.undo, size: 18),
            label: Text(
              provider.canUndoAvFlow ? 'Undo: ${provider.avUndoLabel}' : 'Undo',
            ),
            onPressed: provider.canUndoAvFlow
                ? () {
                    final undone = provider.undoAvFlow();
                    if (undone.isNotEmpty) _snack('Undid: $undone');
                  }
                : null,
          ),
          if (plan != null)
            ElevatedButton.icon(
              icon: const Icon(Icons.image, size: 18),
              label: const Text('Export PNG'),
              onPressed: () => _exportPng(provider),
            ),
          ElevatedButton.icon(
            icon: const Icon(Icons.summarize, size: 18),
            label: const Text('Location report'),
            onPressed: () => _exportReport(provider),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(AppStateProvider provider) => Center(
    child: Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.map_outlined,
            size: 64,
            color: Theme.of(context).disabledColor,
          ),
          const SizedBox(height: 20),
          Text(
            'No floor plan imported yet.',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          const SizedBox(
            width: 480,
            child: Text(
              'Import the room\'s plan, then drag its locations onto it. Every '
              'device and jack field that names a location is placed with it, '
              'so the plan stays worth keeping without dragging each box on '
              'by hand.\n\nThe counts above and the location report work '
              'whether or not a plan is imported.',
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            icon: const Icon(Icons.image_outlined, size: 18),
            label: const Text('Import a floor plan'),
            onPressed: () => _importPlan(provider),
          ),
        ],
      ),
    ),
  );

  /// The plan itself: image, location markers, callouts.
  Widget _plan(
    AppStateProvider provider,
    AvFlowModel model,
    FloorPlan plan,
  ) {
    final size = _imageSize;
    final theme = Theme.of(context);

    return SizedBox(
      width: size.width,
      height: size.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => _onPlanTap(provider, details.localPosition),
        child: Stack(
          children: [
            Container(
              width: size.width,
              height: size.height,
              color: theme.brightness == Brightness.dark
                  // The plan is a white drawing; a white mat under it keeps a
                  // transparent PNG from reading as a hole in dark mode.
                  ? const Color(0xFFF3F3F3)
                  : Colors.white,
              child: _image == null
                  ? Center(
                      child: Text(
                        'The plan image could not be found at\n$_imagePath',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : Image(image: _image!, fit: BoxFit.fill),
            ),
            for (final location in provider.avLocations)
              if (location.isPlaced)
                _locationMarker(provider, model, location),
            for (final callout in plan.callouts)
              _calloutMarker(provider, model, plan, callout),
          ],
        ),
      ),
    );
  }

  Widget _locationMarker(
    AppStateProvider provider,
    AvFlowModel model,
    RoomLocation location,
  ) {
    final here = model.nodes.where((n) => n.locationId == location.id);
    final jacks = here
        .where((n) => n.isJackField)
        .fold(0, (sum, n) => sum + n.ports.length);
    final devices = here.where((n) => !n.isJackField).length;
    const r = kLocationMarkerRadius;

    return Positioned(
      left: location.planPos.dx - r,
      top: location.planPos.dy - r,
      child: GestureDetector(
        onPanUpdate: (d) => provider.moveAvLocationMarker(
          location.id,
          location.planPos + d.delta,
          // One drag is one undo, not one per pointer event.
          recordUndo: false,
        ),
        onDoubleTap: () => showLocationEditor(context, provider, location),
        child: Tooltip(
          message:
              '${location.displayName}\n'
              '${kRoomZoneLabels[location.zone] ?? ''}\n'
              '$devices device${devices == 1 ? '' : 's'}, '
              '$jacks jack${jacks == 1 ? '' : 's'}\n'
              'Drag to move · double-click to edit',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: r * 2,
                height: r * 2,
                decoration: BoxDecoration(
                  color: const Color(0xFF1565C0),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                alignment: Alignment.center,
                child: Text(
                  location.callout.trim().isEmpty
                      ? '•'
                      : location.callout.trim(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              // The name under the dot, because a plan of unlabeled circles
              // is a plan somebody has to hover over to read.
              Container(
                margin: const EdgeInsets.only(top: 2),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                color: Colors.white.withValues(alpha: 0.85),
                child: Text(
                  location.name,
                  style: const TextStyle(fontSize: 10, color: Colors.black87),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _calloutMarker(
    AppStateProvider provider,
    AvFlowModel model,
    FloorPlan plan,
    FloorPlanCallout callout,
  ) {
    const r = kCalloutMarkerRadius;
    final selected = _selectedCalloutId == callout.id;
    final target = _calloutSubtitle(model, callout);

    return Positioned(
      left: callout.pos.dx - r,
      top: callout.pos.dy - r,
      child: GestureDetector(
        onTap: () => setState(() => _selectedCalloutId = callout.id),
        onPanUpdate: (d) => provider.updateAvCallout(
          plan.id,
          callout.copyWith(pos: callout.pos + d.delta),
          recordUndo: false,
        ),
        onDoubleTap: () => _showCalloutEditor(provider, model, plan, callout),
        child: Tooltip(
          message: [
            'Callout ${callout.tag}',
            if (target.isNotEmpty) target,
            if (callout.workbookSheet.isNotEmpty)
              'Workbook: ${callout.workbookSheet}'
                  '${callout.workbookRef.isEmpty ? '' : ' · ${callout.workbookRef}'}',
            'Drag to move · double-click to edit',
          ].join('\n'),
          child: Container(
            width: r * 2,
            height: r * 2,
            decoration: BoxDecoration(
              color: const Color(0xFFD84315),
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? Colors.yellow : Colors.white,
                width: selected ? 3 : 2,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              callout.tag,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onPlanTap(AppStateProvider provider, Offset at) {
    switch (_tool) {
      case _PlanTool.none:
        setState(() => _selectedCalloutId = null);
      case _PlanTool.location:
        _placeLocationAt(provider, at);
      case _PlanTool.callout:
        final plan = provider.primaryFloorPlan;
        if (plan == null) return;
        provider.addAvCallout(
          plan.id,
          FloorPlanCallout(
            id: '',
            tag: provider.nextCalloutTag(plan.id),
            pos: at,
          ),
        );
    }
  }

  /// Drops the next location that isn't on the plan yet at [at]. Asks which
  /// one when several are waiting, because guessing puts the wrong marker
  /// somewhere plausible, which is worse than asking.
  Future<void> _placeLocationAt(AppStateProvider provider, Offset at) async {
    final waiting = provider.avLocations.where((l) => !l.isPlaced).toList();
    if (waiting.isEmpty) {
      _snack(
        'Every location is already on the plan. Drag them to move, or add '
        'another under "Locations".',
      );
      return;
    }
    if (waiting.length == 1) {
      provider.moveAvLocationMarker(waiting.first.id, at);
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Which location goes here?'),
        children: [
          for (final l in waiting)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(l.id),
              child: Row(
                children: [
                  Icon(kRoomZoneIcons[l.zone] ?? Icons.place, size: 18),
                  const SizedBox(width: 10),
                  Text(l.displayName),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked != null) provider.moveAvLocationMarker(picked, at);
  }

  // --- the side panel -------------------------------------------------------

  Widget _sidePanel(
    AppStateProvider provider,
    AvFlowModel model,
    FloorPlan? plan,
  ) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Callouts', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'What each marker on the plan refers to, and where in the exported '
          'workbook that thing is described.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (plan == null || plan.callouts.isEmpty)
          Text(
            plan == null
                ? 'Import a plan to start placing callouts.'
                : 'None yet. Turn on "Add callouts" and click the plan.',
            style: theme.textTheme.bodySmall,
          )
        else
          for (final c in plan.callouts)
            Card(
              margin: const EdgeInsets.only(bottom: 6),
              color: _selectedCalloutId == c.id
                  ? theme.colorScheme.surfaceContainerHighest
                  : null,
              child: ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 13,
                  backgroundColor: const Color(0xFFD84315),
                  child: Text(
                    c.tag,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                title: Text(
                  _calloutSubtitle(model, c).isEmpty
                      ? (c.note.isEmpty ? 'Note' : c.note)
                      : _calloutSubtitle(model, c),
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  c.workbookSheet.isEmpty
                      ? 'No workbook reference'
                      : '${c.workbookSheet}'
                            '${c.workbookRef.isEmpty ? '' : ' · ${c.workbookRef}'}',
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => setState(() => _selectedCalloutId = c.id),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      tooltip: 'Edit',
                      onPressed: () =>
                          _showCalloutEditor(provider, model, plan, c),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: 'Remove',
                      onPressed: () => provider.removeAvCallout(plan.id, c.id),
                    ),
                  ],
                ),
              ),
            ),
        const Divider(height: 28),
        Row(
          children: [
            Expanded(
              child: Text(
                'Screen / shade runs',
                style: theme.textTheme.titleSmall,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 20),
              tooltip: 'Add a control run',
              onPressed: () async {
                await showScreenSwitchEditor(context, provider, null);
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
        Text(
          'A switch at one place and a motor at another, with a run between '
          'them. Neither end is a box on the signal flow.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        if (provider.avScreenSwitches.isEmpty)
          Text('None recorded.', style: theme.textTheme.bodySmall)
        else
          for (final s in provider.avScreenSwitches)
            Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.toggle_on_outlined),
                title: Text(s.label, style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                  '${_end(provider, s.startLocationId, s.startNote)} '
                  '→ ${_end(provider, s.endLocationId, s.endNote)}'
                  '${s.cableType.isEmpty ? '' : '\n${s.cableType}'}'
                  '${s.runFeet <= 0 ? '' : ' · ${s.runFeet.toStringAsFixed(0)} ft'}',
                  style: theme.textTheme.bodySmall,
                ),
                isThreeLine: s.cableType.isNotEmpty,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      tooltip: 'Edit',
                      onPressed: () async {
                        await showScreenSwitchEditor(context, provider, s);
                        if (mounted) setState(() {});
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: 'Remove',
                      onPressed: () => provider.removeAvScreenSwitch(s.id),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  static String _end(
    AppStateProvider provider,
    String locationId,
    String note,
  ) {
    final name = provider.avLocationName(locationId);
    if (name.isNotEmpty) return name;
    return note.isEmpty ? '(not recorded)' : note;
  }

  String _calloutSubtitle(AvFlowModel model, FloorPlanCallout c) {
    switch (c.target) {
      case CalloutTarget.rack:
        for (final r in model.racks) {
          if (r.id == c.targetId) return 'Rack: ${r.name}';
        }
        return c.targetId.isEmpty ? '' : 'Rack (removed)';
      case CalloutTarget.device:
        final node = model.nodesById[c.targetId];
        return node == null
            ? (c.targetId.isEmpty ? '' : 'Device (removed)')
            : 'Device: ${node.label}';
      case CalloutTarget.location:
        final l = model.locationById(c.targetId);
        return l == null
            ? (c.targetId.isEmpty ? '' : 'Location (removed)')
            : 'Location: ${l.name}';
      case CalloutTarget.sheet:
        return c.workbookSheet.isEmpty
            ? 'Workbook sheet'
            : 'Sheet: ${c.workbookSheet}';
      case CalloutTarget.note:
        return '';
    }
  }

  // --- dialogs --------------------------------------------------------------

  Future<void> _showPlanSettings(
    AppStateProvider provider,
    FloorPlan plan,
  ) async {
    final nameController = TextEditingController(text: plan.name);
    final scaleController = TextEditingController(
      text: plan.pixelsPerFoot <= 0
          ? ''
          : plan.pixelsPerFoot.toStringAsFixed(2),
    );
    double opacity = plan.opacity;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Floor plan settings'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: scaleController,
                  decoration: const InputDecoration(
                    labelText: 'Scale (plan pixels per foot)',
                    helperText: 'Leave blank if the plan is not to scale',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Opacity behind the signal flow',
                  style: Theme.of(ctx).textTheme.titleSmall,
                ),
                Text(
                  'How strongly the plan shows through on the AV Flow tab. '
                  'This page always draws it fully.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                Slider(
                  value: opacity,
                  min: 0.05,
                  max: 1.0,
                  divisions: 19,
                  label: '${(opacity * 100).round()}%',
                  onChanged: (v) => setLocal(() => opacity = v),
                ),
                const SizedBox(height: 8),
                Text(
                  'Image: ${plan.imageFile.isEmpty ? '(none)' : plan.imageFile}'
                  '\n${plan.imageSize.width.round()} × '
                  '${plan.imageSize.height.round()} px',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('remove'),
              child: const Text(
                'Remove the plan',
                style: TextStyle(color: Colors.red),
              ),
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
      provider.removeAvFloorPlan(plan.id);
      _syncImage(provider);
      return;
    }
    provider.updateAvFloorPlan(
      plan.copyWith(
        name: nameController.text.trim().isEmpty
            ? plan.name
            : nameController.text.trim(),
        opacity: opacity,
        pixelsPerFoot: double.tryParse(scaleController.text.trim()) ?? 0,
      ),
    );
  }

  Future<void> _showCalloutEditor(
    AppStateProvider provider,
    AvFlowModel model,
    FloorPlan plan,
    FloorPlanCallout callout,
  ) async {
    final tagController = TextEditingController(text: callout.tag);
    final refController = TextEditingController(text: callout.workbookRef);
    final noteController = TextEditingController(text: callout.note);
    CalloutTarget target = callout.target;
    String targetId = callout.targetId;
    String sheet = callout.workbookSheet;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          // The choices for the current target kind. Rebuilt per target so
          // switching from "rack" to "device" cannot leave a rack id selected
          // in a device dropdown.
          final options = switch (target) {
            CalloutTarget.rack => [
              for (final r in model.racks) (id: r.id, label: r.name),
            ],
            CalloutTarget.device => [
              for (final n in model.nodes) (id: n.id, label: n.label),
            ],
            CalloutTarget.location => [
              for (final l in model.locations) (id: l.id, label: l.displayName),
            ],
            _ => const <({String id, String label})>[],
          };
          final known = {for (final o in options) o.id};
          final safeTarget = known.contains(targetId) ? targetId : '';

          return AlertDialog(
            title: Text('Callout ${callout.tag}'),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'A marker on the plan and the thing it points at. The name '
                    'is resolved from the room, so renaming a rack cannot '
                    'leave the plan pointing at a name that no longer exists.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: tagController,
                          decoration: const InputDecoration(labelText: 'Tag'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<CalloutTarget>(
                          initialValue: target,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Refers to',
                          ),
                          items: [
                            for (final t in CalloutTarget.values)
                              DropdownMenuItem(
                                value: t,
                                child: Text(
                                  kCalloutTargetLabels[t] ?? t.name,
                                ),
                              ),
                          ],
                          onChanged: (v) => setLocal(() {
                            target = v ?? target;
                            targetId = '';
                          }),
                        ),
                      ),
                    ],
                  ),
                  if (options.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: safeTarget.isEmpty ? null : safeTarget,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'Which ${kCalloutTargetLabels[target]
                            ?.toLowerCase()}',
                      ),
                      items: [
                        for (final o in options)
                          DropdownMenuItem(value: o.id, child: Text(o.label)),
                      ],
                      onChanged: (v) => setLocal(() => targetId = v ?? ''),
                    ),
                  ],
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: sheet.isEmpty ? '' : sheet,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Workbook sheet',
                      helperText:
                          'Which tab of the exported room workbook describes '
                          'this',
                    ),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('None')),
                      for (final s in kFloorPlanWorkbookSheets)
                        DropdownMenuItem(value: s, child: Text(s)),
                    ],
                    onChanged: (v) => setLocal(() => sheet = v ?? ''),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: refController,
                    decoration: const InputDecoration(
                      labelText: 'Reference on that sheet',
                      hintText: 'e.g. Rack Inventory, cable C12, row 40',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteController,
                    decoration: const InputDecoration(labelText: 'Note'),
                    maxLines: 2,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('delete'),
                child: const Text(
                  'Remove',
                  style: TextStyle(color: Colors.red),
                ),
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
          );
        },
      ),
    );

    if (result == null || result == 'cancel') return;
    if (result == 'delete') {
      provider.removeAvCallout(plan.id, callout.id);
      return;
    }
    provider.updateAvCallout(
      plan.id,
      callout.copyWith(
        tag: tagController.text.trim().isEmpty
            ? callout.tag
            : tagController.text.trim(),
        target: target,
        targetId: targetId,
        workbookSheet: sheet,
        workbookRef: refController.text.trim(),
        note: noteController.text.trim(),
      ),
    );
  }
}

/// What clicking the plan does.
enum _PlanTool { none, location, callout }

/// The sheets a callout can point into. The room workbook's four, plus the
/// location sheet this tab adds — named rather than indexed so adding a tab
/// to the book cannot repoint every callout in every saved room.
const List<String> kFloorPlanWorkbookSheets = [
  'Control',
  'AV Flow',
  'Racks',
  'Cost Estimate',
  'Locations',
];

// ---------------------------------------------------------------------------
//  THE COUNTS
// ---------------------------------------------------------------------------

/// Runs and jacks per location, live across the top of the plan.
///
/// This is the number that gets ordered against — back boxes, conduit,
/// terminations — and it is here rather than only in the export because a
/// figure you have to run a report to see is a figure nobody checks while
/// there is still time to change it.
class _CountStrip extends StatelessWidget {
  final AvFlowModel model;

  const _CountStrip({required this.model});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tallies = countLinesByLocation(model);

    if (tallies.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text(
          model.locations.isEmpty
              ? 'No locations yet — add some under "Locations" and set them on '
                    'each device, and the jack and cable counts appear here.'
              : 'Nothing is recorded at any location yet.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    return SizedBox(
      height: 92,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          for (final tally in tallies)
            Card(
              margin: const EdgeInsets.only(right: 8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(
                          kRoomZoneIcons[tally.zone] ?? Icons.place,
                          size: 15,
                        ),
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 220),
                          child: Text(
                            tally.name,
                            style: theme.textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${tally.jacks} jack${tally.jacks == 1 ? '' : 's'} · '
                      '${tally.lines} line${tally.lines == 1 ? '' : 's'}',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 2),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260),
                      child: Text(
                        tally.bySignal.entries
                            .map(
                              (e) =>
                                  '${kSignalCodes[e.key] ?? e.key.name} '
                                  '×${e.value}',
                            )
                            .join('  '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One location's tallies for the strip.
typedef LocationTally = ({
  String id,
  String name,
  RoomZone zone,
  int jacks,
  int lines,
  Map<SignalType, int> bySignal,
});

/// Jack and line counts per location, in zone order, leaving out places where
/// nothing has landed.
///
/// Shares its counting rule with the report's Line Counts by Location: a run
/// counts at both ends when they are in different places, once when they are
/// in the same one. The two must agree — a strip that says four and a report
/// that says six is a strip nobody trusts again.
List<LocationTally> countLinesByLocation(AvFlowModel model) {
  final byId = model.nodesById;
  final signalCounts = <String, Map<SignalType, int>>{};

  void bump(String locationId, SignalType signal) {
    if (locationId.isEmpty) return;
    signalCounts.putIfAbsent(locationId, () => {});
    signalCounts[locationId]![signal] =
        (signalCounts[locationId]![signal] ?? 0) + 1;
  }

  for (final c in model.cables) {
    final from = byId[c.fromNodeId]?.locationId ?? kNoLocationId;
    final to = byId[c.toNodeId]?.locationId ?? kNoLocationId;
    bump(from, c.signal);
    if (to != from) bump(to, c.signal);
  }

  final out = <LocationTally>[];
  for (final zone in RoomZone.values) {
    for (final location in model.locations.where((l) => l.zone == zone)) {
      final jacks = model.nodes
          .where((n) => n.isJackField && n.locationId == location.id)
          .fold(0, (sum, n) => sum + n.ports.length);
      final bySignal = signalCounts[location.id] ?? const <SignalType, int>{};
      final lines = bySignal.values.fold(0, (a, b) => a + b);
      if (jacks == 0 && lines == 0) continue;
      out.add((
        id: location.id,
        name: location.displayName,
        zone: location.zone,
        jacks: jacks,
        lines: lines,
        bySignal: Map.fromEntries(
          bySignal.entries.toList()
            ..sort((a, b) => math.max(-1, b.value.compareTo(a.value))),
        ),
      ));
    }
  }
  return out;
}
