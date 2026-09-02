import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;

import 'contrast.dart';
import 'app_snack.dart';
import 'app_state.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'av_flow_report.dart';
import 'av_flow_routing.dart';
import 'av_flow_routing_dialog.dart';
import 'av_flow_swap_dialogs.dart';
import 'av_port_editor.dart';
import 'color_wheel_picker.dart';
import 'control_prefill.dart';
import 'cost_estimate.dart';
import 'device_recheck_dialog.dart';
import 'diagram_capture.dart';
import 'equipment_lifecycle.dart'
    show formatEquipmentAge, kDefaultEquipmentLifeYears;
import 'dynamic_devices_view.dart' show getActiveDeviceKeys;
import 'view_zoom.dart';
import 'diagram_grid.dart';
import 'layout_tools.dart';
import 'report_tools.dart';
import 'room_locations.dart';
import 'room_locations_view.dart';
import 'room_presets.dart';
import 'screenshot_tools.dart';
import 'side_pane.dart';
import 'stepped_date_picker.dart';
import 'workbook_export.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  AV SIGNAL FLOW TAB
/// ============================================================================
///  The video/audio counterpart to the Schematic tab. Where that tab DERIVES
///  a control diagram from the config and lets you nudge it, this tab is a
///  document you draw: devices carry named connectors, and you cable output
///  to input, port to port, exactly as the room is wired.
///
///  Seeded on first visit from the config's active devices (same dev_ count
///  logic as the Devices tab) with connectors resolved from the AV device
///  library, so a room starts with its real equipment already on the canvas.
///  Everything after that is yours: add gear the control config never sees
///  (displays, wall plates, speakers, patch panels), edit any device's ports,
///  and draw the runs.
///
///  Signal types color the cables and drive a compatibility check when two
///  ports are joined. Exports: the diagram as a PNG, and a cable schedule +
///  pack list as .xlsx / .txt / clipboard.
///
///  The rack elevations and the cost estimate used to be pages of this tab and
///  are now tabs of their own (rack_tab_view.dart, cost_estimate_view.dart):
///  they answer different questions, get read by different people, and a
///  three-way segmented control was hiding two of them behind the third.
///
///  Persists to `<config>_av_flow.json` beside the working config — see the
///  AV FLOW TAB STATE block in app_state.dart.
/// ============================================================================

// ---------------------------------------------------------------------------
//  MODEL BUILDING
// ---------------------------------------------------------------------------

/// Something derived from the provider, worked out again only when the
/// provider has actually moved.
///
/// THE DRAWING TABS DERIVE THEIR MODEL IN build(), which is right — a model
/// held in State is a model that goes stale — but build() runs for two quite
/// different reasons and only one of them is a change. A drag is the other:
/// the preview offset lives in the widget's own State, every pointer event
/// calls setState, and the model was being rebuilt from a provider that had
/// not changed since the last frame. On the cabling sheet that is the whole
/// signal flow walked and every box placed against every box already placed,
/// sixty times a second, to redraw one box two pixels to the left.
///
/// So the work is held against [AppStateProvider.revision] and the drag
/// frames read it back. A real edit bumps the revision and the next build
/// recomputes, which is the behavior that was there before — this only
/// removes the repeats.
///
/// One memo holds one thing. A view deriving a model AND a schematic from it
/// keeps two, so the cheap one is not thrown away with the expensive one.
class ProviderMemo<T> {
  int _revision = -1;
  AppStateProvider? _from;
  bool _held = false;
  late T _value;

  /// [build]'s result, computed on the first ask and after every change.
  ///
  /// The provider is checked by identity as well as by revision. A revision
  /// only counts changes to the provider it came from, and two of them both
  /// early in their lives would agree on a number while disagreeing about
  /// everything else — so a swapped provider is a miss, not a coincidence.
  T of(AppStateProvider provider, T Function() build) {
    if (_held &&
        identical(_from, provider) &&
        _revision == provider.revision) {
      return _value;
    }
    _from = provider;
    _revision = provider.revision;
    _held = true;
    return _value = build();
  }
}

/// Resolves the current diagram: the stored nodes and cables, plus the canvas
/// size they need and the config devices still waiting in the palette.
AvFlowModel buildAvFlowModel(AppStateProvider provider) {
  final nodes = List<AvNode>.from(provider.avNodes);
  final byId = {for (final n in nodes) n.id: n};

  // Cables whose endpoints went away (a device removed, a port renamed out of
  // existence) are dropped from the render rather than painted into nowhere.
  final cables = provider.avCables
      .where((c) => AvFlowModel.cableIsResolvable(c, byId))
      .toList();

  // Config devices not on the canvas and not dismissed — the palette.
  final config = provider.roomConfig;
  final activeKeys = getActiveDeviceKeys(
    config,
    provider.uiSchema.deviceCountMap,
  );
  final unplaced = <AvUnplacedDevice>[];
  for (final key in activeKeys) {
    if (byId.containsKey(key)) continue;
    final dev = config[key];
    if (dev is! Map) continue;
    // Devices removed by hand are listed too, flagged. They are still in the
    // room config, so a palette that hid them made a device look as though it
    // had left the room when all that happened was somebody deleted the box.
    unplaced.add(
      AvUnplacedDevice(
        key: key,
        label: dev['name']?.toString() ?? key,
        model: dev['model']?.toString() ?? '',
        dismissed: provider.avDismissedDevices.contains(key),
      ),
    );
  }

  double maxX = 900, maxY = 560;
  for (final n in nodes) {
    maxX = math.max(maxX, n.pos.dx + n.width + 60);
    maxY = math.max(maxY, n.pos.dy + n.height + 80);
  }

  final setup = config['SYSTEM_SETUP'];
  return AvFlowModel(
    nodes: nodes,
    cables: cables,
    racks: provider.avRacks,
    rackSlots: provider.avRackSlots,
    rackItems: provider.avRackItems,
    canvasSize: Size(maxX, maxY),
    roomTitle:
        (setup is Map ? setup['gui_full_room_name']?.toString() : '') ?? '',
    unplaced: unplaced,
    locations: provider.avLocations,
    screenSwitches: provider.avScreenSwitches,
    floorPlans: provider.avFloorPlans,
    cabling: provider.avCabling,
  );
}

/// Signal-flow reading order, left to right: sources feed the switcher, the
/// switcher feeds processing, processing feeds the displays. Power and
/// anything unrecognized go in the source column so they don't split a row.
int _columnForDevice(String key) {
  // Boxes the routing put in, named after the config field that placed them:
  // a source or its transmitter reads on the left, a display's receiver on the
  // right beside the display it feeds. Without this they all fell to column 0
  // and Auto-arrange dragged every receiver across the page.
  if (key.startsWith('AVSOURCE_INPUT_')) return 0;
  if (key.startsWith('AVSOURCE_OUTPUT_')) return 3;
  if (key.startsWith('SWITCHERDEVICE_')) return 1;
  if (key.startsWith('DSPDEVICE_') || key.startsWith('RECORDERDEVICE_')) {
    return 2;
  }
  if (key.startsWith('PROJECTORDEVICE_') || key.startsWith('SCREENDEVICE_')) {
    return 3;
  }
  return 0;
}

IconData iconForAvNode(String id, String model) {
  if (id.startsWith('PROJECTORDEVICE_')) return Icons.connected_tv;
  if (id.startsWith('CAMERADEVICE_')) return Icons.videocam;
  if (id.startsWith('SWITCHERDEVICE_')) return Icons.swap_horiz;
  if (id.startsWith('DSPDEVICE_')) return Icons.equalizer;
  if (id.startsWith('USBDEVICE_')) return Icons.usb;
  if (id.startsWith('POWERDEVICE_')) return Icons.power;
  if (id.startsWith('MEDIAPORTDEVICE_')) return Icons.settings_input_hdmi;
  if (id.startsWith('WIRELESSDEVICE_')) return Icons.wifi;
  if (id.startsWith('RECORDERDEVICE_')) return Icons.fiber_manual_record;
  if (id.startsWith('SCREENDEVICE_')) return Icons.aspect_ratio;

  // Manually added gear identifies itself by model instead.
  final m = model.toLowerCase();
  if (m.contains('display') || m.contains('tv')) return Icons.tv;
  if (m.contains('laptop') || m.contains('byod')) return Icons.laptop;
  if (m.contains('pc')) return Icons.desktop_windows;
  if (m.contains('speaker')) return Icons.speaker;
  if (m.contains('amplifier') || m.contains('amp')) return Icons.volume_up;
  if (m.contains('mic')) return Icons.mic;
  if (m.contains('switch')) return Icons.lan;
  if (m.contains('patch')) return Icons.dns;
  if (m.contains('plate') || m.contains('tx')) return Icons.input;
  if (m.contains('rx') || m.contains('receiver')) return Icons.output;
  return Icons.developer_board;
}

// ---------------------------------------------------------------------------
//  THE TAB
// ---------------------------------------------------------------------------

class AvFlowView extends StatefulWidget {
  const AvFlowView({super.key});

  @override
  State<AvFlowView> createState() => _AvFlowViewState();
}

class _AvFlowViewState extends State<AvFlowView>
    with SingleTickerProviderStateMixin {
  final GlobalKey _diagramKey = GlobalKey();
  final TransformationController _transform = TransformationController();

  /// The diagram, rebuilt when the room changes rather than when the pointer
  /// moves. The drag preview is laid over it per frame — see [ProviderMemo]
  /// and [_withDragPreview].
  final ProviderMemo<AvFlowModel> _modelMemo = ProviderMemo();

  /// Drives the chevrons traveling along the selected run - see
  /// [_SignalFlowPainter].
  ///
  /// RUNS ONLY WHILE SOMETHING IS SELECTED. A canvas with nothing picked has
  /// no reason to be repainting sixty times a second, and this page is one
  /// somebody leaves open all afternoon on a laptop.
  late final AnimationController _signalFlow = AnimationController(
    vsync: this,
    // One chevron's travel from one position to the next. Slow enough to read
    // as flow rather than as flicker; a diagram is not a progress bar.
    duration: const Duration(milliseconds: 1100),
  );

  /// The window the canvas is looked at through, so "Fit to view" can measure
  /// it; the drawing itself is measured through [_diagramKey].
  final GlobalKey _viewportKey = GlobalKey();

  /// Zooms out until the whole diagram is on screen.
  void _fitToView() {
    final fitted = fitToViewport(
      controller: _transform,
      contentKey: _diagramKey,
      viewportKey: _viewportKey,
    );
    if (!fitted) _snack('The diagram is still drawing - try again.');
  }

  bool _editMode = false;
  bool _showPalette = true;

  /// Cable-drawing mode, the AV twin of the Schematic tab's "Draw Line".
  /// Dragging and connecting are separate modes on purpose: when both were
  /// live at once a click with a pixel of mouse travel became a drag, and the
  /// connection silently didn't happen.
  bool _cableMode = false;

  /// First port tapped while drawing a cable: (nodeId, portId).
  (String, String)? _pendingPort;

  /// Live drag, held locally so a moving device doesn't push a provider
  /// notification — and a rebuild of every listener in the app — per frame.
  /// Committed once on release.
  String? _dragNodeId;
  Offset _dragOffset = Offset.zero;

  /// Cable whose route handles are showing.
  String? _selectedCableId;

  /// Polylines from the last build, for cable hit-testing and handles.
  Map<String, List<Offset>> _paths = {};

  /// Where the last double-click landed. onDoubleTap carries no position and
  /// onDoubleTapDown carries no "it was a double" — so the two are paired.
  Offset? _doubleTapAt;

  /// The decoded backdrop, held so it isn't re-read from disk on every
  /// repaint, and the file it was built from so a re-import is noticed.
  ///
  /// This used to be the room's FLOOR PLAN and only ever the floor plan, on a
  /// toggle. That was the wrong picture nearly every time: a signal flow is
  /// laid out by signal, not by geometry, so a plan behind it lined up with
  /// nothing — and the drawings people did want behind it, a title block or a
  /// marked-up revision, were unreachable. Now it is whatever image the user
  /// picks; see [DiagramBackground].
  ImageProvider? _backgroundImage;
  String _backgroundPath = '';

  @override
  void initState() {
    super.initState();
    // So a workbook exported from another tab can still be illustrated with
    // this page's diagram — see diagram_capture.dart.
    registerDiagramCanvas(AppTab.avFlow, _diagramKey);
    capturingDiagram.addListener(_captureChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<AppStateProvider>();
      provider.ensureAvFlowForCurrentConfig();
      // First visit to a room with nothing drawn yet: put its real equipment
      // on the canvas so there is something to cable.
      if (provider.avNodes.isEmpty && provider.roomConfig.isNotEmpty) {
        _seedFromConfig(provider, silent: true);
      }
      // Then the cabling the config already states: every source on the
      // switcher input the System tab gives it, every display on the output
      // that feeds it, and the boxes with no config block of their own — the
      // PC, the doc cam, the DTP receivers — put in to carry it. Every visit,
      // not just the first: a doc cam added to the config last week should be
      // on the drawing this week. See [autoDrawRoutingFromConfig] for why it
      // is safe to run repeatedly.
      autoDrawRoutingFromConfig(provider);
      _syncBackgroundImage(provider);
    });
  }

  @override
  void dispose() {
    unregisterDiagramCanvas(AppTab.avFlow, _diagramKey);
    capturingDiagram.removeListener(_captureChanged);
    _transform.dispose();
    _signalFlow.dispose();
    super.dispose();
  }

  /// The color of the run the chevrons are traveling along, so they read as
  /// part of the line rather than as something dropped on top of it.
  ///
  /// Falls back to nothing visible when the selected run has gone - a cable
  /// deleted while it was selected, which is the ordinary way one is deleted.
  Color _selectedCableColor(AvFlowModel model, AppStateProvider provider) {
    final id = _selectedCableId;
    if (id == null) return Colors.transparent;
    for (final cable in model.cables) {
      if (cable.id == id) return cable.colorFor(provider.avSignalColors);
    }
    return Colors.transparent;
  }

  /// Holds the chevrons still while the drawing is being photographed.
  ///
  /// The layer takes itself off the page for a capture anyway, so this is not
  /// what keeps the chevrons out of the picture. It is that a ticker driving
  /// frames for something nobody is drawing is a ticker with nothing to do -
  /// and a capture of every tab walks four pages with a beat on each, which is
  /// long enough to be worth not spending.
  void _captureChanged() {
    if (!mounted) return;
    if (capturingDiagram.value) {
      _signalFlow.stop();
    } else if (_selectedCableId != null && !_signalFlow.isAnimating) {
      _signalFlow.repeat();
    }
  }

  /// Picks a run, or clears the selection with null.
  ///
  /// The one way it is set, so the animation cannot be left running by a path
  /// that forgot about it. Five places select a cable - the canvas, the label,
  /// a drag, a double-tap, and leaving edit mode - and a ticker still spinning
  /// after the last of them is a page quietly burning a frame budget with
  /// nothing on screen to show for it.
  void _selectCable(String? id) {
    if (_selectedCableId == id) return;
    setState(() => _selectedCableId = id);
    if (id == null) {
      _signalFlow.stop();
      // Back to the start, so the next run picked begins its travel at the
      // same place rather than wherever the last one happened to stop.
      _signalFlow.value = 0;
    } else if (!_signalFlow.isAnimating) {
      _signalFlow.repeat();
    }
  }

  /// Rebuilds [_backgroundImage] when the room's backdrop changes. Cheap when
  /// nothing moved, which is every build but the one after an import.
  void _syncBackgroundImage(AppStateProvider provider) {
    final resolved = provider.resolveFloorPlanImage(
      provider.avFlowBackground.imageFile,
    );
    if (resolved == _backgroundPath) return;
    setState(() {
      _backgroundPath = resolved;
      _backgroundImage = resolved.isEmpty || !File(resolved).existsSync()
          ? null
          : FileImage(File(resolved));
    });
  }

  /// Picks a picture, copies it in beside the config and puts it behind the
  /// canvas.
  ///
  /// The natural size is read here rather than assumed: it is what the canvas
  /// lays the image out against before the bytes have been decoded, and a
  /// guess would jump the backdrop the first time it painted.
  Future<void> _importBackground(AppStateProvider provider) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Choose a background image',
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'bmp', 'gif', 'webp'],
    );
    final picked = result?.files.single.path;
    if (picked == null) return;

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

    final stored = await provider.importRoomImage(picked, 'flow_background');
    if (!mounted) return;
    provider.setAvFlowBackgroundImage(stored, size);
    _syncBackgroundImage(provider);
  }

  /// How strongly the backdrop shows and how wide it is drawn, plus the way to
  /// take it off again.
  Future<void> _showBackgroundSettings(AppStateProvider provider) async {
    var opacity = provider.avFlowBackground.opacity;
    var scale = provider.avFlowBackground.scale;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Background image'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'A picture behind the diagram - a title block, a riser '
                  'sketch, the last revision to draw over. It is there to be '
                  'referred to, so the diagram has to stay readable on top of '
                  'it.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                Text('Opacity', style: Theme.of(ctx).textTheme.titleSmall),
                Slider(
                  value: opacity,
                  min: 0.05,
                  max: 1.0,
                  divisions: 19,
                  label: '${(opacity * 100).round()}%',
                  onChanged: (v) => setLocal(() => opacity = v),
                ),
                Text('Size', style: Theme.of(ctx).textTheme.titleSmall),
                Text(
                  'How much of the canvas width it is drawn across.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                Slider(
                  value: scale,
                  min: 0.1,
                  max: 2.0,
                  divisions: 19,
                  label: '${(scale * 100).round()}%',
                  onChanged: (v) => setLocal(() => scale = v),
                ),
                const SizedBox(height: 8),
                Text(
                  'Image: ${provider.avFlowBackground.imageFile}'
                  '\n${provider.avFlowBackground.imageSize.width.round()} × '
                  '${provider.avFlowBackground.imageSize.height.round()} px',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('remove'),
              child: Text(
                'Remove it',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('replace'),
              child: const Text('Replace...'),
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

    if (result == null || result == 'cancel' || !mounted) return;
    switch (result) {
      case 'remove':
        provider.clearAvFlowBackground();
        _syncBackgroundImage(provider);
      case 'replace':
        await _importBackground(provider);
      case 'save':
        provider.setAvFlowBackgroundView(opacity: opacity, scale: scale);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: error ? snackErrorFill(context) : null),
    );
  }

  /// "Saved" snackbar offering to open the file or its folder — see
  /// [showSavedFileSnack], which every export in the app now ends with.
  void _savedSnack(AppStateProvider provider, String label, String filePath) {
    if (!mounted) return;
    showSavedFileSnack(context, provider, label, filePath);
  }

  /// Default export file name stem: `<BLDG>_<room>_<suffix>`.
  String _fileStem(AppStateProvider provider, String suffix) {
    final setup = provider.roomConfig['SYSTEM_SETUP'] ?? {};
    final bldg = provider.bldgAbbreviation(
      (setup['gve_bldg'] ?? 'ROOM').toString(),
    );
    final room = (setup['gve_room'] ?? '').toString();
    return [
      bldg,
      if (room.isNotEmpty) room,
      suffix,
    ].join('_').replaceAll(RegExp(r'[^\w\-]+'), '_');
  }

  // -------------------------------------------------------------------------
  //  SEEDING FROM THE CONFIG
  // -------------------------------------------------------------------------

  /// Adds every active config device that isn't on the canvas yet, with ports
  /// from the AV device library and a position in its signal-flow column.
  ///
  /// [silent] is the automatic first-visit seed, and it leaves hand-removed
  /// devices off — dragging back a box somebody deliberately deleted every
  /// time the tab opens is not helpful. Pressing **Place all from config** is
  /// the opposite instruction: it means ALL of them, so it clears those
  /// removals first. That distinction is the whole point of the two paths —
  /// a matrix deleted from the canvas used to be unreachable afterwards,
  /// because both the button and the palette skipped it.
  ///
  /// [batch] is for a bigger operation that has already taken its own undo
  /// snapshot and says its own piece afterwards — **Recreate from config**
  /// places twenty boxes, and twenty presses of Undo to get back to before it
  /// is not an undo anybody uses. Returns how many boxes were added.
  int _seedFromConfig(
    AppStateProvider provider, {
    bool silent = false,
    bool batch = false,
  }) {
    final config = provider.roomConfig;
    if (config.isEmpty) return 0;
    if (!silent) provider.clearAvDismissedDevices();
    final keys = getActiveDeviceKeys(config, provider.uiSchema.deviceCountMap);
    final existing = {for (final n in provider.avNodes) n.id};

    // Running y per column, starting below whatever is already placed there.
    final columnY = <int, double>{};
    for (final n in provider.avNodes) {
      final col = (n.pos.dx / kAvAutoColumnPitch).round();
      columnY[col] = math.max(
        columnY[col] ?? kAvAutoOriginY,
        n.pos.dy + n.height + kAvAutoRowGap,
      );
    }

    int added = 0;
    for (final key in keys) {
      if (existing.contains(key)) continue;
      if (silent && provider.avDismissedDevices.contains(key)) continue;
      final dev = config[key];
      if (dev is! Map) continue;

      final model = dev['model']?.toString() ?? '';
      final template = provider.avDeviceLibrary.resolve(
        configKey: key,
        model: model,
      );
      final col = _columnForDevice(key);
      final y = columnY[col] ?? kAvAutoOriginY;

      final node = AvNode(
        id: key,
        label: dev['name']?.toString() ?? key,
        model: model,
        pos: Offset(kAvAutoOriginX + col * kAvAutoColumnPitch, y),
        // A power controller's outlets come out of the catalog as OUTLET 1..8
        // and come onto the page as OUTLET 3 · Via: the room's config is the
        // only thing that knows which outlet is which.
        ports: withOutletNames(
          withPowerInlet(template.ports, template.powerInput),
          key,
          config,
        ),
        fromConfig: true,
        rackUnits: template.rackUnits,
        powerWatts: template.powerWatts,
        btuPerHour: template.btuPerHour,
        powerSource: powerSourceForInput(template.powerInput),
      );
      provider.addAvNode(node, recordUndo: !batch);
      columnY[col] = y + node.height + kAvAutoRowGap;
      added++;
    }

    if (!silent && !batch) {
      _snack(
        added == 0
            ? 'Every config device is already on the canvas.'
            : 'Added $added device${added == 1 ? '' : 's'} from the config.',
      );
    }
    return added;
  }

  /// Throws the drawing away and takes the room off the config again: every
  /// active config device placed in its column, then every tie the config
  /// describes drawn — the switcher I/O numbers, the expansion bus, the
  /// standard USB chain and the power controller's outlets.
  ///
  /// The button exists because patching is not always the cheaper move. A
  /// drawing that has drifted from the config — devices swapped, models
  /// corrected, half the room re-numbered — takes longer to reconcile box by
  /// box than to draw again, and "draw again" was previously delete-everything
  /// by hand first.
  ///
  /// It ASKS first, and says what it will cost: hand-added boxes and
  /// hand-drawn cables are part of what goes. One press of Undo puts the whole
  /// thing back.
  Future<void> _recreateFromConfig(AppStateProvider provider) async {
    if (provider.roomConfig.isEmpty) {
      _snack('No room config is open, so there is nothing to build from.',
          error: true);
      return;
    }

    final byHand = provider.avNodes.where((n) => !n.fromConfig).length;
    final cables = provider.avCables.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recreate from config?'),
        content: Text(
          'This clears the drawing and builds it again from the config - the '
          'devices it lists, and the leads its input and output numbers '
          'describe.\n\n'
          'You have ${provider.avNodes.length} box(es)'
          '${byHand == 0 ? '' : ', $byHand of them added by hand,'} and '
          '$cables cable(s) here now. Anything you drew by hand goes with the '
          'rest.\n\n'
          'Devices that come back keep their rack rails, and one press of '
          'Undo puts the whole drawing back the way it was.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Recreate'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // One snapshot, covering the whole rebuild: the clear takes it, and every
    // step after it is told not to take another.
    provider.clearAvFlowDrawing();
    final placed = _seedFromConfig(provider, batch: true);
    final routed = autoDrawRoutingFromConfig(provider);
    final unracked = provider.pruneAvRackSlots(recordUndo: false);

    _snack(
      'Drawn again from the config: $placed device(s) placed and '
      '${routed.cablesDrawn} cable(s) run'
      '${routed.nodesAdded == 0 ? '' : ', plus ${routed.nodesAdded} box(es) '
          'the runs needed'}'
      '${unracked == 0 ? '' : '. $unracked rack placement(s) had nothing left '
          'in them and were cleared'}.',
    );
  }

  /// Re-runs the column layout over everything currently placed, so a diagram
  /// that has been dragged into a mess can be put back in reading order.
  void _autoArrange(AppStateProvider provider) {
    final columnY = <int, double>{};
    for (final node in List<AvNode>.from(provider.avNodes)) {
      final col = node.fromConfig ? _columnForDevice(node.id) : 0;
      final y = columnY[col] ?? kAvAutoOriginY;
      provider.updateAvNode(node.copyWith(
        pos: Offset(kAvAutoOriginX + col * kAvAutoColumnPitch, y),
      ));
      columnY[col] = y + node.height + kAvAutoRowGap;
    }
    _snack('Devices re-arranged into signal-flow columns.');
  }

  // -------------------------------------------------------------------------
  //  CABLING
  // -------------------------------------------------------------------------

  /// Two-tap connect: the first port arms, the second completes. Tapping the
  /// armed port again cancels.
  Future<void> _onPortTap(
    AppStateProvider provider,
    AvNode node,
    AvPort port,
  ) async {
    if (!_editMode || !_cableMode) return;

    final pending = _pendingPort;
    if (pending == null) {
      setState(() => _pendingPort = (node.id, port.id));
      return;
    }
    if (pending.$1 == node.id && pending.$2 == port.id) {
      setState(() => _pendingPort = null);
      return;
    }

    final fromNode = provider.avNodeById(pending.$1);
    final fromPort = fromNode?.portById(pending.$2);
    if (fromNode == null || fromPort == null) {
      setState(() => _pendingPort = null);
      return;
    }

    // Decide which end is the source. A user who clicks the input first means
    // the same cable, so an input-then-output pair is silently swapped.
    AvNode srcNode = fromNode, dstNode = node;
    AvPort srcPort = fromPort, dstPort = port;
    var match = checkPortMatch(srcNode, srcPort, dstNode, dstPort);
    if (match == PortMatch.invalid) {
      final swapped = checkPortMatch(node, port, fromNode, fromPort);
      if (swapped != PortMatch.invalid) {
        srcNode = node;
        srcPort = port;
        dstNode = fromNode;
        dstPort = fromPort;
        match = swapped;
      }
    }

    setState(() => _pendingPort = null);

    if (match == PortMatch.invalid) {
      _snack(
        'Can\'t connect ${fromPort.label} to ${port.label} - a cable runs '
        'from an output to an input.',
        error: true,
      );
      return;
    }

    if (match == PortMatch.signalMismatch) {
      final proceed = await _confirmMismatch(srcPort, dstPort);
      if (proceed != true) return;
    }

    final cable = provider.addAvCable(
      fromNodeId: srcNode.id,
      fromPortId: srcPort.id,
      toNodeId: dstNode.id,
      toPortId: dstPort.id,
      signal: srcPort.signal,
    );
    if (cable == null) {
      _snack('Those two ports are already cabled together.');
    }
  }

  /// Adapters are real, so a signal-type mismatch asks rather than refuses.
  Future<bool?> _confirmMismatch(AvPort from, AvPort to) {
    final fromLabel = kSignalLabels[from.signal] ?? from.signal.name;
    final toLabel = kSignalLabels[to.signal] ?? to.signal.name;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Signal types differ'),
        content: Text(
          '${from.label} carries $fromLabel, but ${to.label} '
          'expects $toLabel.\n\nDraw the cable anyway? Use this when an '
          'adapter or converter sits in the run.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Connect anyway'),
          ),
        ],
      ),
    );
  }

  /// Where a new bend belongs in a cable's waypoint list: the leg of the
  /// guide line (port, bends, port) that [at] sits closest to.
  int _bendInsertIndex(AvFlowModel model, AvCable cable, Offset at) {
    final from = model.nodeById(cable.fromNodeId);
    final to = model.nodeById(cable.toNodeId);
    if (from == null || to == null) return cable.waypoints.length;

    final guide = [
      from.anchorOf(cable.fromPortId),
      ...cable.waypoints,
      to.anchorOf(cable.toPortId),
    ];
    int best = 0;
    double bestDistance = double.infinity;
    for (int i = 0; i < guide.length - 1; i++) {
      final d = _distanceToSegment(at, guide[i], guide[i + 1]);
      if (d < bestDistance) {
        bestDistance = d;
        best = i;
      }
    }
    return best.clamp(0, cable.waypoints.length);
  }

  /// Nearest cable within [tolerance] of [point], or null.
  String? _cableAt(Offset point, {double tolerance = 9}) {
    String? best;
    double bestDistance = tolerance;
    _paths.forEach((id, points) {
      for (int i = 0; i < points.length - 1; i++) {
        final d = _distanceToSegment(point, points[i], points[i + 1]);
        if (d < bestDistance) {
          bestDistance = d;
          best = id;
        }
      }
    });
    return best;
  }

  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lengthSquared == 0) return (p - a).distance;
    var t = ((p - a).dx * ab.dx + (p - a).dy * ab.dy) / lengthSquared;
    t = t.clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  // -------------------------------------------------------------------------
  //  EXPORTS
  // -------------------------------------------------------------------------

  Future<void> _exportPng(AppStateProvider provider) async {
    final bytes = await captureBoundary(_diagramKey, pixelRatio: 2.0);
    if (bytes == null) {
      _snack('Could not render the diagram to an image.', error: true);
      return;
    }
    if (!mounted) return;
    // The picture first, the file second. A diagram is captured at its full
    // extent rather than at the window over it, so the preview is where
    // somebody sees what actually came out - and the drawing more often goes
    // into a message than into a folder, which is what the Copy button is for.
    await showCapturedPicture(
      context,
      bytes,
      title: 'The AV flow diagram as a picture',
      fileName: '${_fileStem(provider, 'av_flow')}.png',
      what: 'The diagram image',
    );
  }

  Future<void> _copyReportText(AppStateProvider provider) async {
    final model = buildAvFlowModel(provider);
    final text = renderTextReport(
      model.roomTitle,
      avReportSections(provider, model),
    );
    await Clipboard.setData(ClipboardData(text: text));
    _snack(
      'AV report copied to clipboard '
      '(${text.split('\n').length} lines).',
    );
  }

  Future<void> _exportReport(AppStateProvider provider, bool asXlsx) async {
    final model = buildAvFlowModel(provider);
    final sections = avReportSections(provider, model);

    final ext = asXlsx ? 'xlsx' : 'txt';
    String? outputFile = await FilePicker.saveFile(
      dialogTitle: 'Save AV Report',
      fileName: '${_fileStem(provider, 'av_report')}.$ext',
      type: FileType.custom,
      allowedExtensions: [ext],
    );
    if (outputFile == null) return;
    if (!outputFile.toLowerCase().endsWith('.$ext')) outputFile += '.$ext';

    try {
      if (asXlsx) {
        final png = await captureBoundary(_diagramKey, pixelRatio: 1.5);
        final bytes = buildXlsx([
          buildStackedReportSheet(
            sheetName: 'AV Report',
            title: model.roomTitle,
            sections: sections,
            imageBuilder: png == null
                ? null
                : (anchorRow) => scaledSheetImage(png, anchorRow),
          ),
        ]);
        await File(outputFile).writeAsBytes(bytes);
      } else {
        await File(
          outputFile,
        ).writeAsString(renderTextReport(model.roomTitle, sections));
      }
      _savedSnack(provider, 'AV report', outputFile);
    } catch (e) {
      _snack('Failed to save report: $e', error: true);
    }
  }

  /// The whole job in one book: control, AV flow, racks, cost — every sheet
  /// illustrated, whichever tab the export was pressed on. Shared with the
  /// Schematic tab; see workbook_export.dart, which walks the diagram tabs to
  /// capture them and therefore disposes THIS page on the way past.
  Future<void> _exportWorkbook(AppStateProvider provider) =>
      exportRoomWorkbook(context, provider);

  Future<void> _saveDiagram(AppStateProvider provider) async {
    // A wizard-built session has no file for the sidecar to sit beside yet.
    if (provider.avFlowSidecarPath.isEmpty) {
      _snack(
        'No working config file yet - choose where to save the config, '
        'then the AV setup is saved beside it.',
      );
      final bool exported = await provider.exportRoomConfig();
      if (!exported) {
        _snack(
          'AV setup not saved - the config save was canceled.',
          error: true,
        );
        return;
      }
    }
    final saved = await provider.saveAvFlow();
    _snack(
      saved.isEmpty
          ? 'Failed to save the AV setup.'
          : 'AV setup saved to $saved',
    );
  }

  // -------------------------------------------------------------------------
  //  BUILD
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    if (provider.roomConfig.isEmpty) {
      return const Center(child: Text('No configuration loaded.'));
    }
    final model = _withDragPreview(
      provider,
      _modelMemo.of(provider, () => buildAvFlowModel(provider)),
    );
    final theme = Theme.of(context);

    // A backdrop imported (or removed) elsewhere in the session has to reach
    // this canvas. Deferred a frame because the sync calls setState and this
    // is build().
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncBackgroundImage(provider);
    });

    // A RUN DELETED WHILE IT WAS SELECTED leaves its id behind. The waypoint
    // handles and the flow layer both tolerate that and simply draw nothing,
    // but the animation would go on ticking for a line that is no longer on
    // the canvas. Deferred for the same reason as the backdrop above.
    if (_selectedCableId != null &&
        !model.cables.any((c) => c.id == _selectedCableId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _selectCable(null);
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildToolbar(provider, model),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              Expanded(
                key: _viewportKey,
                child: InteractiveViewer(
                  transformationController: _transform,
                  constrained: false,
                  // Low enough that a twenty-device room fits the window.
                  minScale: 0.08,
                  maxScale: 3.0,
                  boundaryMargin: const EdgeInsets.all(400),
                  child: RepaintBoundary(
                    key: _diagramKey,
                    child: _buildCanvas(provider, model, theme),
                  ),
                ),
              ),
              // The toolbar's switch still says whether the palette is on the
              // page at all; the pane itself is what makes it resizable and
              // foldable once it is.
              if (_showPalette)
                SidePane(
                  side: PaneSide.right,
                  title: 'Devices',
                  storageKey: 'av_flow_palette',
                  initialWidth: 260,
                  child: _buildPalette(provider, model),
                ),
            ],
          ),
        ),
        if (_editMode)
          BottomPane(
            storageKey: 'av_flow_cables',
            initialHeight: 200,
            child: _buildCablePanel(provider, model),
          ),
      ],
    );
  }

  Widget _buildToolbar(AppStateProvider provider, AvFlowModel model) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('AV Signal Flow', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 4),
          FilterChip(
            avatar: Icon(
              _editMode ? Icons.edit : Icons.edit_outlined,
              size: 18,
            ),
            label: const Text('Edit'),
            selected: _editMode,
            onSelected: (v) {
              _selectCable(null);
              setState(() {
                _editMode = v;
                _cableMode = false;
                _pendingPort = null;
              });
            },
          ),
          if (_editMode)
            FilterChip(
              avatar: const Icon(Icons.cable, size: 18),
              label: Text(
                _pendingPort == null ? 'Draw Cable' : 'Pick 2nd connector...',
              ),
              selected: _cableMode,
              onSelected: (v) => setState(() {
                _cableMode = v;
                _pendingPort = null;
              }),
            ),
          FilterChip(
              avatar: const Icon(Icons.view_sidebar, size: 18),
              label: Text('Devices (${model.unplaced.length})'),
              selected: _showPalette,
              onSelected: (v) => setState(() => _showPalette = v),
            ),
          if (_editMode)
            OutlinedButton.icon(
              icon: const Icon(Icons.auto_fix_high, size: 18),
              label: const Text('Auto-arrange'),
              onPressed: () => _autoArrange(provider),
            ),
          // Shared with the Schematic and Cabling drawings — see
          // [AppStateProvider.snapDiagramsToGrid].
          if (_editMode)
            FilterChip(
              key: const ValueKey('av_snap_to_grid'),
              avatar: const Icon(Icons.grid_4x4, size: 18),
              label: const Text('Snap to grid'),
              selected: provider.snapDiagramsToGrid,
              onSelected: (v) => provider.setSnapDiagramsToGrid(v),
            ),
          // Whether the paper has squares on it — a different question from
          // where a box lands, and not gated on edit mode: the lines are for
          // reading the drawing as well as for building it. Never exported.
          FilterChip(
            key: const ValueKey('av_show_grid'),
            avatar: const Icon(Icons.grid_on, size: 18),
            label: const Text('Grid'),
            selected: provider.showDiagramGrid,
            onSelected: (v) => provider.setShowDiagramGrid(v),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.fit_screen, size: 18),
            label: const Text('Fit to view'),
            onPressed: _fitToView,
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.palette_outlined, size: 18),
            label: const Text('Colors'),
            onPressed: () => _showPaletteDialog(provider),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.place_outlined, size: 18),
            label: Text('Locations (${provider.avLocations.length})'),
            onPressed: () => showLocationManager(context, provider),
          ),
          // Any picture, behind the diagram. Not the floor plan on a toggle:
          // a signal flow is laid out by signal, so a plan behind it lines up
          // with nothing, while the drawings people actually want back there
          // — a title block, a riser sketch, the revision being drawn over —
          // had no way in at all.
          OutlinedButton.icon(
            key: const ValueKey('av_background_button'),
            icon: const Icon(Icons.wallpaper_outlined, size: 18),
            label: Text(
              provider.avFlowBackground.hasImage ? 'Background' : 'Add a background',
            ),
            onPressed: () => provider.avFlowBackground.hasImage
                ? _showBackgroundSettings(provider)
                : _importBackground(provider),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.save, size: 18),
            label: const Text('Save AV Setup'),
            onPressed: () => _saveDiagram(provider),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.image, size: 18),
            label: const Text('Export PNG'),
            onPressed: () => _exportPng(provider),
          ),
          PopupMenuButton<String>(
            tooltip: 'Export the room report',
            onSelected: (v) => switch (v) {
              'copy' => _copyReportText(provider),
              'workbook' => _exportWorkbook(provider),
              'preset' => _saveAsRoomPreset(provider),
              _ => _exportReport(provider, v == 'xlsx'),
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                value: 'workbook',
                child: Text('Full room workbook (.xlsx, 5 sheets)'),
              ),
              PopupMenuItem(
                value: 'preset',
                child: Text('Save this room as a room type...'),
              ),
              PopupMenuDivider(),
              PopupMenuItem(value: 'xlsx', child: Text('AV report (.xlsx)')),
              PopupMenuItem(
                value: 'txt',
                child: Text('Plain text report (.txt)'),
              ),
              PopupMenuItem(
                value: 'copy',
                child: Text('Copy text to clipboard'),
              ),
            ],
            child: IgnorePointer(
              child: ElevatedButton.icon(
                icon: const Icon(Icons.summarize, size: 18),
                label: const Text('Report'),
                onPressed: () {},
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- canvas -------------------------------------------------------------

  /// The model as it should be drawn RIGHT NOW: identical to what the provider
  /// holds, except that a device being dragged is shown under the cursor. Its
  /// real position is only written back on release, so the cables follow the
  /// device live without a provider write per pointer event.
  AvFlowModel _withDragPreview(AppStateProvider provider, AvFlowModel model) {
    final id = _dragNodeId;
    if (id == null || _dragOffset == Offset.zero) return model;

    final nodes = [
      for (final n in model.nodes)
        n.id == id
            ? n.copyWith(pos: _snapped(provider, _clamped(n.pos + _dragOffset)))
            : n,
    ];
    double maxX = 900, maxY = 560;
    for (final n in nodes) {
      maxX = math.max(maxX, n.pos.dx + n.width + 60);
      maxY = math.max(maxY, n.pos.dy + n.height + 80);
    }
    return AvFlowModel(
      nodes: nodes,
      cables: model.cables,
      racks: model.racks,
      rackSlots: model.rackSlots,
      rackItems: model.rackItems,
      canvasSize: Size(maxX, maxY),
      roomTitle: model.roomTitle,
      unplaced: model.unplaced,
      locations: model.locations,
      screenSwitches: model.screenSwitches,
      floorPlans: model.floorPlans,
    );
  }

  /// The canvas only grows right and down, so a device can't be pushed past
  /// the origin where it would be clipped.
  static Offset _clamped(Offset p) =>
      Offset(math.max(0, p.dx), math.max(0, p.dy));

  /// A dragged box's position, on the grid when the setting is on. Used by the
  /// live preview AND by the drop, so the box lands where it was shown.
  Offset _snapped(AppStateProvider provider, Offset p) =>
      snapToGrid(p, enabled: provider.snapDiagramsToGrid);

  void _onNodeDragStart(String nodeId) {
    setState(() {
      _dragNodeId = nodeId;
      _dragOffset = Offset.zero;
    });
  }

  void _onNodeDragUpdate(Offset delta) {
    setState(() => _dragOffset += delta);
  }

  void _onNodeDragEnd(AppStateProvider provider) {
    final id = _dragNodeId;
    final offset = _dragOffset;
    setState(() {
      _dragNodeId = null;
      _dragOffset = Offset.zero;
    });
    if (id == null || offset == Offset.zero) return;
    final node = provider.avNodeById(id);
    if (node == null) return;

    // Land clear of the other boxes. Dropping one device on top of another
    // hides both and makes the cabling unreadable, so a drop that would
    // overlap slides to the nearest free spot instead.
    provider.setAvNodePosition(
      id,
      nonOverlappingPosition(
        desired: _snapped(provider, _clamped(node.pos + offset)),
        size: node.size,
        others: [
          for (final other in provider.avNodes)
            if (other.id != id) other.rect,
        ],
        // Stepping the search by the grid keeps a box that has to slide off a
        // neighbor ON the grid: every ring it tries is a whole number of
        // squares from a square.
        step: provider.snapDiagramsToGrid ? kDiagramGridStep : 16,
      ),
    );
  }

  Widget _buildCanvas(
    AppStateProvider provider,
    AvFlowModel model,
    ThemeData theme,
  ) {
    final surface = theme.brightness == Brightness.dark
        ? const Color(0xFF15181C)
        : const Color(0xFFFAFAFA);

    final byId = model.nodesById;
    final lanes = assignCableLanes(model.cables, byId);

    // Every device is an obstacle, inflated a little so cables don't graze
    // the boxes. A run's own two endpoints are excluded — it has to reach
    // them.
    final boxes = {for (final n in model.nodes) n.id: n.rect.inflate(10)};

    // A run's own two devices are obstacles too, just barely deflated so the
    // port anchor on the boundary and the stub leaving it stay clear. Without
    // this, a cable into a port on the FAR side of its destination simply cut
    // straight through the box — drag a source past a DTP CrossPoint and the
    // line would run through the unit instead of around it.
    final endpointBoxes = {
      for (final n in model.nodes) n.id: n.rect.deflate(2),
    };

    // The room title is drawn at the top-left and goes out with the PNG, so a
    // run routed through it comes out on the issued sheet written across the
    // room name. It is not a device, so until now nothing kept the router off
    // it: the "over the top of everything" lane a run takes to get round a
    // block of boxes ([_clearBand]) goes exactly there.
    //
    // Dropped when a device has been dragged over the title: the title is
    // already covered, and an obstacle wrapped round that box's ports would
    // only make the runs into it worse.
    final titleText = avRoomTitleText(model.roomTitle);
    final titleBox = avRoomTitleRect(titleText, _roomTitleStyle(theme));
    final titleObstacle =
        model.nodes.any((n) => n.rect.overlaps(titleBox)) ? null : titleBox;

    // The page the runs have to stay on. The canvas starts at the origin and
    // is sized from the boxes, so a detour lane worked out from a box near an
    // edge — "just above the topmost one" — can land outside it, and a line
    // drawn off the canvas is a line that is simply not there. Handed to the
    // router so it picks a lane that IS on the page instead.
    final page = Rect.fromLTWH(
      0,
      0,
      model.canvasSize.width,
      model.canvasSize.height,
    );
    // Fanned after routing, not during it: the router works one cable at a
    // time and hands two cables with the same problem the same answer, so the
    // only place six runs sharing a corridor can be told apart is once all six
    // are known. Same idea as the cabling sheet's lanes.
    _paths = fanOverlappingRuns({
      for (final c in model.cables)
        c.id: routeCable(
          fromNode: byId[c.fromNodeId]!,
          toNode: byId[c.toNodeId]!,
          cable: c,
          lane: lanes[c.id] ?? 0,
          bounds: page,
          obstacles: [
            for (final e in boxes.entries)
              if (e.key != c.fromNodeId && e.key != c.toNodeId) e.value,
            endpointBoxes[c.fromNodeId]!,
            endpointBoxes[c.toNodeId]!,
            ?titleObstacle,
          ],
        ),
    });

    // The legend sits BELOW everything rather than floating over the
    // bottom-left corner, where it covered whatever device happened to be
    // there. "Everything" has to include the CABLES, not just the boxes: a
    // run detouring under the diagram, or one with a bend dragged low, can
    // reach further down than any device. Recomputed every build, so it
    // keeps clear while a device is being dragged.
    double contentBottom = 0;
    for (final n in model.nodes) {
      contentBottom = math.max(contentBottom, n.pos.dy + n.height);
    }
    for (final route in _paths.values) {
      for (final point in route) {
        contentBottom = math.max(contentBottom, point.dy);
      }
    }
    final legendTop = contentBottom + 28;
    final legendHeight = avLegendHeight(
      model.usedSignals.length,
      model.hasCustomCableColors,
      groupHeaders: avLegendGroupCount(model.usedSignals),
    );
    final canvasHeight = math.max(
      model.canvasSize.height,
      legendTop + legendHeight + 20,
    );

    final pendingPort = _pendingPort == null
        ? null
        : provider.avNodeById(_pendingPort!.$1)?.portById(_pendingPort!.$2);

    return Container(
      width: model.canvasSize.width,
      height: canvasHeight,
      color: surface,
      child: Stack(
        children: [
          // The alignment grid, under everything including the backdrop. On
          // screen only — it takes itself off the page for an export.
          if (provider.showDiagramGrid) const Positioned.fill(child: DiagramGrid()),
          // The backdrop, behind everything. Faint by default so the diagram
          // still reads over it — it is there to be referred to, not looked
          // at.
          if (_backgroundImage != null)
            Positioned(
              left: 0,
              top: 0,
              child: Opacity(
                opacity: provider.avFlowBackground.opacity,
                child: Image(
                  image: _backgroundImage!,
                  width:
                      model.canvasSize.width * provider.avFlowBackground.scale,
                  fit: BoxFit.contain,
                  alignment: Alignment.topLeft,
                ),
              ),
            ),
          // Tap-to-select-a-cable sits under the nodes but over the paint, so
          // a click on empty canvas clears the selection.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) {
                _selectCable(_cableAt(details.localPosition));
              },
              // Double-clicking a run opens it. onDoubleTapDown carries the
              // position; onDoubleTap does not, and without both the hit test
              // would have to guess where the click was.
              onDoubleTapDown: (details) =>
                  _doubleTapAt = details.localPosition,
              onDoubleTap: () {
                final at = _doubleTapAt;
                if (at == null) return;
                final hit = _cableAt(at);
                if (hit == null) return;
                final matches = model.cables.where((c) => c.id == hit);
                if (matches.isEmpty) return;
                _selectCable(hit);
                _showCableDialog(provider, matches.first);
              },
              child: CustomPaint(
                painter: _CablePainter(
                  cables: model.cables,
                  paths: _paths,
                  selectedId: _selectedCableId,
                  brightness: theme.brightness,
                  palette: provider.avSignalColors,
                ),
              ),
            ),
          ),
          // WHICH WAY THE SIGNAL GOES ON THE RUN THAT IS SELECTED. Its own
          // layer above the cables rather than part of that painter, and
          // inside a RepaintBoundary: this is the one thing on the canvas
          // repainting every frame, and it must not drag two hundred static
          // cables and a background image through the raster with it.
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: _SelectedSignalFlow(
                  progress: _signalFlow,
                  points: _selectedCableId == null
                      ? null
                      : _paths[_selectedCableId],
                  color: _selectedCableColor(model, provider),
                ),
              ),
            ),
          ),
          // Room title (part of the PNG export). Its position and style are
          // shared with [avRoomTitleRect], which is what keeps the cables off
          // it — a title drawn somewhere other than where the router thinks it
          // is would be routed through again.
          Positioned(
            left: kAvRoomTitleLeft,
            top: kAvRoomTitleTop,
            child: Text(titleText, style: _roomTitleStyle(theme)),
          ),
          // Devices. Each gets its own RepaintBoundary so dragging one does
          // not force the rest of the canvas to repaint with it.
          for (final node in model.nodes)
            Positioned(
              left: node.pos.dx,
              top: node.pos.dy,
              child: RepaintBoundary(
                child: _AvNodeBox(
                  node: node,
                  editMode: _editMode,
                  palette: provider.avSignalColors,
                  cableMode: _cableMode,
                  dragging: _dragNodeId == node.id,
                  pendingNodeId: _pendingPort?.$1,
                  pendingPortId: _pendingPort?.$2,
                  pendingPort: pendingPort,
                  racked: provider.avRackSlots.containsKey(node.id),
                  onPortTap: (port) => _onPortTap(provider, node, port),
                  // Dragging and cabling never compete: in cable mode the box
                  // is a click target only.
                  onDragStart: _editMode && !_cableMode
                      ? () => _onNodeDragStart(node.id)
                      : null,
                  onDragUpdate: _onNodeDragUpdate,
                  onDragEnd: () => _onNodeDragEnd(provider),
                  onEdit: () => _showNodeDialog(provider, node),
                ),
              ),
            ),
          // Cable numbers, above the boxes so a run crossing behind one is
          // still readable — and draggable, the same way a floor-plan callout
          // and a cabling-schematic run label are moved.
          ..._buildCableLabels(provider, model, theme, titleObstacle),
          // Route handles for the selected cable, above the boxes so they can
          // always be grabbed.
          if (_editMode && _selectedCableId != null)
            ..._buildWaypointHandles(provider, model),
          // Legend under the diagram (also part of the PNG export).
          if (model.usedSignals.isNotEmpty || model.hasCustomCableColors)
            Positioned(
              left: 16,
              top: legendTop,
              child: _AvLegend(
                signals: model.usedSignals,
                hasCustomColors: model.hasCustomCableColors,
                palette: provider.avSignalColors,
                theme: theme,
              ),
            ),
          if (model.nodes.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: Text(
                  'No devices on the canvas.\n\nUse the Devices panel to place '
                  'the room\'s equipment, or add gear the control config '
                  'doesn\'t know about.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The cable numbers, one per labeled run.
  ///
  /// Widgets rather than paint because they are DRAGGED: a run's number lands
  /// on the midpoint of its longest leg, which is right most of the time and
  /// unreadable the rest — two runs sharing a corridor put their labels on
  /// top of each other. Dragging one stores an offset from that anchor, so
  /// the label still follows the run when the route changes.
  ///
  /// Double-tap opens the run, matching a double-tap on the line itself.
  List<Widget> _buildCableLabels(
    AppStateProvider provider,
    AvFlowModel model,
    ThemeData theme,
    Rect? titleBox,
  ) {
    final widgets = <Widget>[];
    // What is already written on the page, so two runs sharing a corridor
    // don't write over each other. Only the ones still sitting where the
    // route put them are moved: a label somebody dragged is where they want
    // it, and shuffling it back would undo the drag on every repaint.
    // The room title counts as written-on already: a run's name landing on
    // top of it is the same unreadable corner as two names on top of each
    // other.
    final placed = <Rect>[?titleBox];
    for (final cable in model.cables) {
      final from = model.nodesById[cable.fromNodeId];
      final to = model.nodesById[cable.toNodeId];
      // No cable ID typed: say what the run JOINS instead of drawing nothing.
      // See [defaultCableLabel] for why this is not written into the field.
      final named = cable.label.isNotEmpty;
      final text = named
          ? cable.label
          : (from == null || to == null ? '' : defaultCableLabel(from, to));
      if (text.isEmpty) continue;
      // A lead off the power controller says which outlet it comes out of, in
      // the name the room gave it — the same name that is printed on the touch
      // panel's power page. Beside the cable number rather than in it: the
      // number is the run's own name and stays editable, and the outlet name
      // follows the config, so renaming an outlet reaches a drawing already
      // made.
      final note = _outletNoteFor(provider, model, cable);
      // Both halves are measured as one string, because both halves are what
      // has to fit without landing on the run underneath.
      final measured = note.isEmpty ? text : '$text$kPortNoteSeparator$note';
      final points = _paths[cable.id];
      if (points == null || points.length < 2) continue;
      final anchor = cableLabelAnchor(points);
      if (anchor == null) continue;

      final at = cable.labelOffset == Offset.zero
          ? _freeLabelSpot(anchor, measured, placed)
          : anchor + cable.labelOffset;
      placed.add(_labelRect(at, measured));
      final selected = _selectedCableId == cable.id;
      final color = cable.colorFor(provider.avSignalColors);
      widgets.add(
        Positioned(
          // Keyed by the run it names: it is the one reliable handle on a
          // cable, since the line itself is paint rather than a widget.
          key: ValueKey('av_cable_label_${cable.id}'),
          // Centered on the anchor. FractionalTranslation rather than measuring
          // the text: the label is as wide as whatever somebody typed in it.
          left: at.dx,
          top: at.dy,
          child: FractionalTranslation(
            translation: const Offset(-0.5, -0.5),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _selectCable(cable.id),
              onDoubleTap: () => _showCableDialog(provider, cable),
              onPanStart: _editMode
                  ? (_) {
                      _selectCable(cable.id);
                      // ONE snapshot for the whole gesture, taken before it
                      // moves: the updates below record none, so a drag is
                      // one press of Undo rather than fifty.
                      provider.updateAvCable(cable);
                    }
                  : null,
              onPanUpdate: _editMode
                  ? (d) => provider.updateAvCable(
                        cable.copyWith(
                          labelOffset: cable.labelOffset + d.delta,
                        ),
                        recordUndo: false,
                      )
                  : null,
              child: Tooltip(
                message: _editMode
                    ? 'Drag to move • double-tap to edit the run'
                    : measured,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: theme.brightness == Brightness.dark
                        ? const Color(0xFF15181C)
                        : const Color(0xFFFAFAFA),
                    borderRadius: BorderRadius.circular(3),
                    border: selected
                        ? Border.all(color: color, width: 1)
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        text,
                        style: TextStyle(
                          fontSize: 10,
                          // A typed cable ID is the run's NAME and reads as
                          // one; the endpoints are a description, so they sit
                          // back.
                          color: named ? color : color.withValues(alpha: 0.75),
                          fontWeight:
                              named ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                      // The outlet name is what the run IS FOR, not what it is
                      // called, so it sits back from the number the way the
                      // endpoint description does.
                      if (note.isNotEmpty)
                        Text(
                          '$kPortNoteSeparator$note',
                          style: TextStyle(
                            fontSize: 10,
                            color: color.withValues(alpha: 0.75),
                            fontWeight: FontWeight.w500,
                          ),
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
    return widgets;
  }

  /// What the room calls the controller outlet one end of [cable] is plugged
  /// into, or '' for a run that touches no outlet.
  ///
  /// The config is asked first, so an outlet renamed on the System tab shows
  /// its new name on a drawing that was made before the change. The port's own
  /// note — written when the controller was put on the canvas — answers for
  /// the cases where the config cannot: a controller placed by hand under an
  /// id of its own, or a saved drawing being read beside a config that no
  /// longer lists that outlet.
  ///
  /// Both ends are tried because the direction a power lead was drawn in is
  /// nobody's convention: the automatic pass draws controller → device, and a
  /// lead pulled by hand goes whichever way the hand went.
  static String _outletNoteFor(
    AppStateProvider provider,
    AvFlowModel model,
    AvCable cable,
  ) {
    for (final end in [
      (cable.fromNodeId, cable.fromPortId),
      (cable.toNodeId, cable.toPortId),
    ]) {
      if (powerOutletRef(end.$1, end.$2) == null) continue;
      final live = powerOutletName(provider.roomConfig, end.$1, end.$2);
      if (live.isNotEmpty) return live;
      return portLabelNote(
          model.nodesById[end.$1]?.portById(end.$2)?.label ?? '');
    }
    return '';
  }

  /// Draggable dots on the selected cable: one per existing waypoint (drag to
  /// move, double-tap to drop), plus a hollow dot at each segment midpoint
  /// that creates a waypoint there.
  List<Widget> _buildWaypointHandles(
    AppStateProvider provider,
    AvFlowModel model,
  ) {
    final id = _selectedCableId!;
    final matches = model.cables.where((c) => c.id == id);
    final points = _paths[id];
    if (matches.isEmpty || points == null) return const [];
    final cable = matches.first;

    final widgets = <Widget>[];
    const r = 6.0;

    for (int i = 0; i < cable.waypoints.length; i++) {
      final w = cable.waypoints[i];
      widgets.add(
        Positioned(
          left: w.dx - r,
          top: w.dy - r,
          child: GestureDetector(
            onPanUpdate: (d) {
              final next = List<Offset>.from(cable.waypoints);
              // Nudged clear of the devices: a bend dropped inside a box is
              // the one place the router cannot route out of, so the line
              // would have to cross the device to reach it.
              next[i] = pushOutOfRects(
                next[i] + d.delta,
                [for (final n in model.nodes) n.rect],
              );
              // Per pointer event: the snapshot was taken when the bend was
              // added, and one drag should be one undo, not fifty.
              provider.updateAvCable(
                cable.copyWith(waypoints: next),
                recordUndo: false,
              );
            },
            onDoubleTap: () {
              final next = List<Offset>.from(cable.waypoints)..removeAt(i);
              provider.updateAvCable(cable.copyWith(waypoints: next));
            },
            child: Tooltip(
              message: 'Drag to route • double-tap to remove',
              child: Container(
                width: r * 2,
                height: r * 2,
                decoration: BoxDecoration(
                  color: cable.colorFor(provider.avSignalColors),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
              ),
            ),
          ),
        ),
      );
    }

    for (int i = 0; i < points.length - 1; i++) {
      final mid = (points[i] + points[i + 1]) / 2;
      widgets.add(
        Positioned(
          left: mid.dx - r,
          top: mid.dy - r,
          child: GestureDetector(
            onTap: () {
              // The drawn path can hold more points than the user's bends —
              // detours around devices add their own — so the insertion slot
              // is worked out against the GUIDE line (start, bends, end)
              // rather than the rendered one, which would put the new bend in
              // the wrong place as soon as a leg had been rerouted.
              final next = List<Offset>.from(cable.waypoints);
              next.insert(
                _bendInsertIndex(model, cable, mid),
                pushOutOfRects(mid, [for (final n in model.nodes) n.rect]),
              );
              provider.updateAvCable(cable.copyWith(waypoints: next));
            },
            child: Tooltip(
              message: 'Add a bend here',
              child: Container(
                width: r * 2,
                height: r * 2,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: cable.colorFor(provider.avSignalColors),
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return widgets;
  }

  // --- palette ------------------------------------------------------------

  /// The palette's contents. The width and the header belong to the [SidePane]
  /// this is dropped into, so the column no longer sets either.
  Widget _buildPalette(AppStateProvider provider, AvFlowModel model) {
    final theme = Theme.of(context);
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              model.unplaced.isEmpty
                  ? 'Every config device is placed.'
                  : 'From the room config, not yet on the canvas:',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              children: [
                for (final d in model.unplaced)
                  Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        iconForAvNode(d.key, d.model),
                        size: 20,
                        color: d.dismissed ? theme.disabledColor : null,
                      ),
                      title: Text(
                        d.label,
                        style: TextStyle(
                          fontSize: 13,
                          color: d.dismissed ? theme.disabledColor : null,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        d.dismissed
                            ? 'Removed from the canvas - tap to put it back'
                            : (d.model.isEmpty ? d.key : d.model),
                        style: TextStyle(
                          fontSize: 11,
                          fontStyle: d.dismissed ? FontStyle.italic : null,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Icon(
                        d.dismissed ? Icons.undo : Icons.add,
                        size: 18,
                      ),
                      onTap: () => _placeConfigDevice(provider, d),
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.add_box_outlined, size: 18),
                  label: const Text('Add custom device'),
                  onPressed: () => _showAddCustomDeviceDialog(provider),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.dialpad, size: 18),
                  label: const Text('Add wall box / patch panel'),
                  onPressed: () => _showAddJackFieldDialog(provider),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.sync, size: 18),
                  label: const Text('Place all from config'),
                  onPressed: () => _seedFromConfig(provider),
                ),
                const SizedBox(height: 8),
                // The boxes are only half of what the config knows. The other
                // half is the switcher input and output numbers, which say
                // which box feeds which — and used to be read off the System
                // tab and drawn by hand.
                OutlinedButton.icon(
                  icon: const Icon(Icons.route, size: 18),
                  label: const Text('Draw the routing from config'),
                  onPressed: () => showRoutingDialog(context, provider),
                ),
                const SizedBox(height: 8),
                // The two above ADD to what is there. This one starts over:
                // for a drawing that has drifted far enough from the config
                // that reconciling it box by box costs more than drawing it
                // again.
                OutlinedButton.icon(
                  key: const ValueKey('av_flow_recreate'),
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('Recreate from config'),
                  onPressed: () => _recreateFromConfig(provider),
                ),
                const SizedBox(height: 8),
                // A device copies the catalog's rack height and draw the day
                // it is placed. This re-reads them, which is what a room
                // drawn before the part numbers were known needs.
                deviceRecheckButton(context),
                const SizedBox(height: 16),
                Text(
                  'Library: ${provider.avDeviceLibrary.modelCount} models',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  provider.avDeviceLibrary.source,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.disabledColor,
                  ),
                ),
              ],
            ),
          ),
        ],
    );
  }

  /// Puts a config device on the canvas. addAvNode drops it from the
  /// dismissed set, so re-adding one by hand also stops the automatic seed
  /// skipping it from then on.
  void _placeConfigDevice(AppStateProvider provider, AvUnplacedDevice d) {
    final template = provider.avDeviceLibrary.resolve(
      configKey: d.key,
      model: d.model,
    );
    final col = _columnForDevice(d.key);
    double y = 60;
    for (final n in provider.avNodes) {
      if ((n.pos.dx / 340).round() == col) {
        y = math.max(y, n.pos.dy + n.height + 30);
      }
    }
    provider.addAvNode(
      AvNode(
        id: d.key,
        label: d.label,
        model: d.model,
        pos: Offset(40 + col * 340.0, y),
        ports: withOutletNames(
          withPowerInlet(template.ports, template.powerInput),
          d.key,
          provider.roomConfig,
        ),
        fromConfig: true,
        rackUnits: template.rackUnits,
        powerWatts: template.powerWatts,
        btuPerHour: template.btuPerHour,
        powerSource: powerSourceForInput(template.powerInput),
      ),
    );
  }

  /// Where a hand-added box should land: below everything already drawn, in
  /// the left column.
  ///
  /// Dropping every new box at a fixed spot put it on top of whatever was
  /// there, which is survivable for a device-sized box and not for a patch
  /// panel — a rack-width strip laid over three devices hides them completely,
  /// and the user's first act is to drag it off them.
  Offset _spawnPosition(AppStateProvider provider) {
    double bottom = 60;
    for (final n in provider.avNodes) {
      bottom = math.max(bottom, n.pos.dy + n.height + 30);
    }
    return Offset(40, bottom);
  }

  /// Adds a device by picking a catalog model.
  ///
  /// A dropdown of a thousand Extron models is unusable, and the names are
  /// exactly the sort people mistype: "DTP CrossPoint 108" / "DTPCrossPoint108"
  /// / "dtp-crosspoint-108" are the same box. So this is a search box, and
  /// matching ignores spaces, dashes, underscores and case on both sides —
  /// type the digits and the right row is there.
  Future<void> _showAddCustomDeviceDialog(AppStateProvider provider) async {
    final labelController = TextEditingController();
    final searchController = TextEditingController();
    // How many of the picked model to drop on the canvas. A room with three
    // DTP HDMI 4K 233s is an ordinary room, and adding it one box at a time —
    // search, pick, name, Add, repeat — is the same six clicks three times.
    final countController = TextEditingController(text: '1');
    String? selectedModel;
    // Retired models are left out: adding a device is specifying new work.
    // The Catalog tab is where a discontinued part is still visible.
    final entries = provider.avDeviceLibrary.active;

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final matches = searchCatalog(entries, searchController.text);
          return AlertDialog(
            title: const Text('Add device'),
            content: SizedBox(
              width: 560,
              height: math.min(560, MediaQuery.of(ctx).size.height - 200),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: labelController,
                          decoration: const InputDecoration(
                            labelText: 'Name on the diagram',
                            hintText: 'e.g. Lectern wall plate',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: countController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'How many',
                            helperText: 'Numbered 1, 2, 3…',
                            helperMaxLines: 2,
                          ),
                          onChanged: (_) => setLocal(() {}),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: searchController,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Search the catalog',
                      hintText: 'model, part number or maker',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: searchController.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () => setLocal(
                                () => searchController.clear(),
                              ),
                            ),
                      helperText:
                          'Spaces and dashes are ignored - "dtpcross108" '
                          'finds "DTP CrossPoint 108".',
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: matches.isEmpty
                        ? Center(
                            child: Text(
                              searchController.text.trim().isEmpty
                                  ? 'The catalog is empty.'
                                  : 'No model matches - add it on the Catalog '
                                        'tab, or leave the search blank and '
                                        'name the device by hand.',
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
                                title: Text(
                                  t.model,
                                  style: const TextStyle(fontSize: 13),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  [
                                    if (t.manufacturer.isNotEmpty)
                                      t.manufacturer,
                                    if (t.partNumber.isNotEmpty) t.partNumber,
                                    '${t.inputCount} in / ${t.outputCount} out',
                                    if (t.rackUnits > 0) '${t.rackUnits}U',
                                  ].join(' · '),
                                  style: const TextStyle(fontSize: 11),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () =>
                                    setLocal(() => selectedModel = t.model),
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    selectedModel == null
                        ? 'Pick the closest model - the connectors it brings '
                              'can be edited on the device afterwards.'
                        : 'Selected: $selectedModel',
                    style: const TextStyle(fontSize: 12),
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
                child: Text(
                  _addCount(countController.text) == 1
                      ? 'Add'
                      : 'Add ${_addCount(countController.text)}',
                ),
              ),
            ],
          );
        },
      ),
    );

    if (created != true) return;
    final model = selectedModel ?? '';
    final template = provider.avDeviceLibrary.templateForModel(model);
    final label = labelController.text.trim();
    final base = label.isEmpty ? (model.isEmpty ? 'Device' : model) : label;
    final int count = _addCount(countController.text);

    // The ids the boxes actually land on, so the config blocks can be built
    // for exactly these devices and nothing else already on the canvas.
    final placed = <String>[];

    for (int i = 1; i <= count; i++) {
      final stored = provider.addAvNode(
        AvNode(
          id: '', // provider assigns AVNODE_<n>
          // Numbered only when there is more than one: "DTP HDMI 4K 233 1" on
          // a room with a single transmitter is a number that means nothing.
          label: count == 1 ? base : '$base $i',
          model: model,
          // Recomputed each time round, so the second box lands under the
          // first rather than on top of it.
          pos: _spawnPosition(provider),
          ports: withPowerInlet(
            template?.ports ??
                const [
                  AvPort(
                    id: 'in_1',
                    label: 'IN 1',
                    signal: SignalType.hdmi,
                    direction: PortDirection.input,
                    side: PortSide.left,
                  ),
                  AvPort(
                    id: 'out_1',
                    label: 'OUT 1',
                    signal: SignalType.hdmi,
                    direction: PortDirection.output,
                    side: PortSide.right,
                  ),
                ],
            template?.powerInput ?? PowerInput.mains,
          ),
          rackUnits: template?.rackUnits ?? 0,
          powerWatts: template?.powerWatts ?? 0,
          btuPerHour: template?.btuPerHour ?? 0,
          powerSource: powerSourceForInput(
            template?.powerInput ?? PowerInput.mains,
          ),
        ),
      );
      placed.add(stored.id);
    }

    _addPlacedDevicesToConfig(provider, placed);
  }

  /// Gives the devices just added from the catalog their config blocks.
  ///
  /// Adding a part is the moment somebody says the room HAS this box, and up
  /// to now that fact stopped at the drawing: the device sat on the canvas
  /// and on the estimate, and the control side only learned about it later,
  /// when somebody remembered to run "build the control side" over the whole
  /// room. A DSP added on Tuesday and configured on Friday is a DSP that gets
  /// configured twice or not at all.
  ///
  /// So the same machinery runs here for one device: the family comes from the
  /// catalog's device type (that is what [planControlSide] reads it for), the
  /// block gets the family's defaults, and the driver's own DEVICE_INFO
  /// defaults go on where the module library claims the model — see
  /// [applyControlSide]. Numbering is worked out against the whole config, so
  /// a device added on its own lands on the section key a full run would have
  /// given it.
  ///
  /// Nothing happens for a box no family claims — a speaker, a wall plate, a
  /// passive transmitter. Those never had a control block, and saying so on
  /// every add would be a message about the ordinary case.
  void _addPlacedDevicesToConfig(
    AppStateProvider provider,
    List<String> nodeIds,
  ) {
    if (nodeIds.isEmpty) return;
    // No room config open: the canvas can be drawn on its own, and there is
    // nowhere to put a block until there is.
    if (provider.roomConfig['SYSTEM_SETUP'] is! Map) return;

    final plan = planControlSide(provider, nodeIds: nodeIds);
    if (plan.creatable.isEmpty) return;

    final result = applyControlSide(provider, plan);
    if (result.created == 0) return;

    _snack(
      [
        '${result.created} device block${result.created == 1 ? '' : 's'} '
            'added to the config (${result.sectionKeys.join(', ')})',
        if (result.withoutModule > 0)
          '${result.withoutModule} with no python module yet - the Devices '
              'tab shows those in red',
        'fill in the address on the Devices tab',
      ].join('. '),
    );
  }

  /// How many devices the "How many" field is asking for.
  ///
  /// Clamped rather than validated: a blank or nonsense entry means one, and
  /// the cap is there because a mistyped quantity should not drop two hundred
  /// boxes on a diagram somebody then has to delete one at a time.
  static int _addCount(String text) =>
      (int.tryParse(text.trim()) ?? 1).clamp(1, 40);

  /// Adds a wall box, floor box or patch panel: a box whose "ports" are
  /// numbered jacks. Cabling a device to a jack is what lets the Jack
  /// Schedule say which device is on jack 4 of the lectern plate — the sheet
  /// you actually want when tracing a run back to the IDF.
  Future<void> _showAddJackFieldDialog(AppStateProvider provider) async {
    final labelController = TextEditingController(text: 'Wall box');
    final countController = TextEditingController(text: '6');
    // The site numbering scheme: the room number is the prefix and the jack
    // is a two-digit position under it, so jack 1 of room 1110 is "111001".
    // Seeded from the room number when there is one, because typing the room
    // number that is already on screen is the step everybody skips.
    final prefixController = TextEditingController(
      text: _defaultJackPrefix(provider),
    );
    final startController = TextEditingController(text: '01');
    SignalType signal = SignalType.network;
    // A wall box and a patch panel are the same data and two different
    // shapes, and drawing them alike is what made the flow diagram and the
    // rack elevation disagree about what the same part was.
    AvNodeKind kind = AvNodeKind.jackField;
    String locationId = kNoLocationId;

    /// The numbers this box would be given as the fields currently stand.
    List<String> candidates() {
      final count = (int.tryParse(countController.text.trim()) ?? 0).clamp(
        1,
        96,
      );
      final startText = startController.text.trim();
      final first = int.tryParse(startText) ?? 1;
      final prefix = prefixController.text.trim();
      final width = startText.length;
      return [
        for (int i = 0; i < count; i++)
          '$prefix${'${first + i}'.padLeft(width, '0')}',
      ];
    }

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          // Checked on every rebuild rather than only on Add: a number that is
          // already taken is worth knowing while it is being typed, not after
          // the box is on the canvas and has to be found and edited.
          final clashes = duplicateJackLabels(candidates(), provider.avNodes);
          return AlertDialog(
          title: const Text('Add wall box / patch panel'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<AvNodeKind>(
                  segments: const [
                    ButtonSegment(
                      value: AvNodeKind.jackField,
                      icon: Icon(Icons.dialpad, size: 16),
                      label: Text('Wall / floor box'),
                    ),
                    ButtonSegment(
                      value: AvNodeKind.patchPanel,
                      icon: Icon(Icons.dns, size: 16),
                      label: Text('Patch panel'),
                    ),
                  ],
                  selected: {kind},
                  onSelectionChanged: (s) => setLocal(() {
                    kind = s.first;
                    // The default name follows the shape, unless the user has
                    // already typed one of their own.
                    if (labelController.text.trim() == 'Wall box' ||
                        labelController.text.trim() == 'Patch panel' ||
                        labelController.text.trim().isEmpty) {
                      labelController.text = kind == AvNodeKind.patchPanel
                          ? 'Patch panel'
                          : 'Wall box';
                    }
                  }),
                ),
                const SizedBox(height: 6),
                Text(
                  kind == AvNodeKind.patchPanel
                      ? 'Drawn as a rack-width strip with every outlet in one '
                            'horizontal row, the way the part looks.'
                      : 'Drawn as a plate with its jacks down either side.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: labelController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'e.g. Lectern wall plate, IDF patch panel',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: countController,
                        decoration: const InputDecoration(
                          labelText: 'Number of jacks',
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: (_) => setLocal(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 96,
                      child: TextField(
                        controller: prefixController,
                        decoration: const InputDecoration(labelText: 'Prefix'),
                        onChanged: (_) => setLocal(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: startController,
                        decoration: const InputDecoration(
                          labelText: 'First number',
                          helperText: '01 = 2 digits',
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: (_) => setLocal(() {}),
                      ),
                    ),
                  ],
                ),
                // A jack number is the room's addressing scheme: an installer
                // at the plate finds it on the report and expects exactly one
                // thing behind it. Two boxes numbered alike is a patch made to
                // the wrong jack, found at commissioning — so it is refused
                // here, with the next free block one click away rather than
                // left to be worked out.
                if (clashes.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _JackClashBanner(
                    clashes: clashes,
                    onUseNextFree: () {
                      final startText = startController.text.trim();
                      final next = nextFreeJackStart(
                        prefix: prefixController.text.trim(),
                        start: int.tryParse(startText) ?? 1,
                        count: (int.tryParse(countController.text.trim()) ?? 1)
                            .clamp(1, 96),
                        width: startText.length,
                        nodes: provider.avNodes,
                      );
                      if (next == null) return;
                      setLocal(
                        () => startController.text =
                            '$next'.padLeft(startText.length, '0'),
                      );
                    },
                  ),
                ],
                const SizedBox(height: 12),
                DropdownButtonFormField<SignalType>(
                  initialValue: signal,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'What the jacks carry',
                  ),
                  items: [
                    for (final s in SignalType.values)
                      DropdownMenuItem(
                        value: s,
                        child: Text(kSignalLabels[s] ?? s.name),
                      ),
                  ],
                  onChanged: (v) => setLocal(() => signal = v ?? signal),
                ),
                const SizedBox(height: 12),
                _LocationField(
                  provider: provider,
                  value: locationId,
                  label: 'Where in the room',
                  onChanged: (v) => setLocal(() => locationId = v),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Jacks are bidirectional, so a run can be drawn to either '
                  'side. Rename any of them afterwards in the box\'s editor.',
                  style: TextStyle(fontSize: 12),
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
              onPressed:
                  clashes.isEmpty ? () => Navigator.of(ctx).pop(true) : null,
              child: const Text('Add'),
            ),
          ],
          );
        },
      ),
    );

    if (created != true) return;

    final count = (int.tryParse(countController.text.trim()) ?? 0).clamp(1, 96);
    final startText = startController.text.trim();
    final first = int.tryParse(startText) ?? 1;
    final prefix = prefixController.text.trim();
    // "01" means two digits: jack 2 is 02, not 2, and jack 12 is still 12.
    // The width comes from what was typed, so "1" keeps the old unpadded
    // numbering for anyone who wants it.
    final width = startText.length;
    final label = labelController.text.trim();

    final panel = kind == AvNodeKind.patchPanel;

    provider.addAvNode(
      AvNode(
        id: '',
        label: label.isEmpty ? (panel ? 'Patch panel' : 'Wall box') : label,
        model: panel
            ? '$count-port ${kSignalLabels[signal] ?? signal.name} patch panel'
            : '$count-jack ${kSignalLabels[signal] ?? signal.name} field',
        pos: _spawnPosition(provider),
        kind: kind,
        locationId: locationId,
        powerSource: PowerSource.none,
        // A panel is usually 1U per 24 ports; anything smaller is still a
        // rail, so the height is never 0 and it can go straight in a rack.
        rackUnits: panel ? math.max(1, (count / 24).ceil()) : 0,
        ports: [
          for (int i = 0; i < count; i++)
            AvPort(
              id: 'jack_${first + i}',
              label: '$prefix${'${first + i}'.padLeft(width, '0')}',
              signal: signal,
              direction: PortDirection.bidirectional,
              // A panel's outlets all sit in one row along the bottom edge.
              // A wall box alternates sides, so a 12-way plate stays compact
              // instead of running off the bottom of the page.
              side: panel
                  ? PortSide.bottom
                  : (i.isEven ? PortSide.left : PortSide.right),
            ),
        ],
      ),
    );
  }

  /// Saves the room as a reusable room type in the project root.
  ///
  /// This is the other half of the preset picker on New Room: the four shipped
  /// types are a starting point, and the ones a shop actually builds are the
  /// ones it draws. Saving from a real room is the only way those get written
  /// down without somebody hand-editing JSON.
  Future<void> _saveAsRoomPreset(AppStateProvider provider) async {
    if (provider.avNodes.isEmpty) {
      _snack(
        'There is nothing on the canvas to save as a room type.',
        error: true,
      );
      return;
    }

    final nameController = TextEditingController();
    final descriptionController = TextEditingController();
    final existing = provider.availableRoomPresets();

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final name = nameController.text.trim();
          final clash = existing.any(
            (p) => p.name.trim().toLowerCase() == name.toLowerCase(),
          );
          return AlertDialog(
            title: const Text('Save as a room type'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'The equipment, the cabling, the locations, the racks, the '
                    'screen runs and this room\'s switcher input and output '
                    'numbers are saved. The cost estimate, the floor plan, the '
                    'addresses and this room\'s name and number are not - a '
                    'price belongs to a job and a drawing belongs to a '
                    'building.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameController,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Name',
                      hintText: 'e.g. Standard lecture hall',
                      // A name that already exists overwrites that file. Said
                      // here rather than found out afterwards.
                      errorText: clash
                          ? 'A room type called "$name" already exists - '
                                'saving replaces it'
                          : null,
                      errorStyle: TextStyle(
                        color: Theme.of(ctx).colorScheme.tertiary,
                      ),
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: descriptionController,
                    decoration: const InputDecoration(
                      labelText: 'Description',
                      hintText: 'What this room type is for',
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Saved to ${provider.roomPresetFolder}',
                    style: Theme.of(ctx).textTheme.bodySmall,
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
                onPressed: name.isEmpty
                    ? null
                    : () => Navigator.of(ctx).pop(true),
                child: Text(clash ? 'Replace' : 'Save'),
              ),
            ],
          );
        },
      ),
    );

    if (saved != true) return;

    final written = saveRoomPreset(
      provider.effectiveRootFolder,
      provider.currentRoomAsPreset(
        name: nameController.text.trim(),
        description: descriptionController.text.trim(),
      ),
    );
    if (written.isEmpty) {
      _snack('Could not write the room type - see the log.', error: true);
      return;
    }
    _snack(
      'Room type saved. It is offered the next time a room is created.',
    );
  }

  /// The jack prefix a new box starts with: this room's number, falling back
  /// to the old built-in when the config has none.
  static String _defaultJackPrefix(AppStateProvider provider) {
    final setup = provider.roomConfig['SYSTEM_SETUP'];
    final room = (setup is Map ? setup['gve_room']?.toString() : null) ?? '';
    final digits = room.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.isEmpty ? '1110' : digits;
  }

  /// Recolors the signal palette for this room. Changing HDMI here moves
  /// every HDMI cable, every HDMI port dot AND the legend entry together, so
  /// the key never stops describing the drawing.
  Future<void> _showPaletteDialog(AppStateProvider provider) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Signal colors'),
          content: SizedBox(
            width: 520,
            height: math.min(560, MediaQuery.of(ctx).size.height - 220),
            child: ListView(
              children: [
                Text(
                  'A color set here applies to every cable and connector of '
                  'that type, and to the legend.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (final s in SignalType.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 168,
                          child: Text(
                            kSignalLabels[s] ?? s.name,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        Expanded(
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: [
                              for (final c in kCableSwatches)
                                ColorSwatchButton(
                                  key: ValueKey(
                                    'palette_${s.name}_'
                                    '${(c.toARGB32() & 0xFFFFFF).toRadixString(16)}',
                                  ),
                                  color: c,
                                  width: 24,
                                  height: 20,
                                  selected:
                                      provider.avSignalColor(s).toARGB32() ==
                                      c.toARGB32(),
                                  onTap: () => setLocal(
                                    () => provider.setAvSignalColor(s, c),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.colorize, size: 16),
                          tooltip: 'Pick a custom color',
                          visualDensity: VisualDensity.compact,
                          onPressed: () async {
                            final picked = await showColorWheelDialog(
                              ctx,
                              initial: provider.avSignalColor(s),
                              title: 'Color for ${kSignalLabels[s] ?? s.name}',
                            );
                            if (picked != null) {
                              setLocal(() => provider.setAvSignalColor(s, picked));
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.restart_alt, size: 16),
                          tooltip: 'Back to the default color',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setLocal(
                            () => provider.setAvSignalColor(s, null),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => setLocal(() => provider.resetAvSignalColors()),
              child: const Text('Reset all'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  // --- device / port editing ----------------------------------------------

  /// What leaving the Life field blank actually means for a box of [model].
  ///
  /// NOT a fixed "8". The field is an OVERRIDE, and the thing it overrides is
  /// different per model: the catalog's average for the product when somebody
  /// has recorded one, and the blanket cycle when nobody has. A helper that
  /// always named the blanket figure would be wrong on every model with a life
  /// on it, and would tell somebody to type a number they did not need.
  static String _lifeHelper(AppStateProvider provider, String model) {
    final catalog =
        provider.avDeviceLibrary.templateForModel(model.trim())?.lifeYears ?? 0;
    return catalog > 0
        ? 'blank = $catalog (catalog)'
        : 'blank = $kDefaultEquipmentLifeYears';
  }

  Future<void> _showNodeDialog(AppStateProvider provider, AvNode node) async {
    final labelController = TextEditingController(text: node.label);
    final modelController = TextEditingController(text: node.model);
    final noteController = TextEditingController(text: node.note);
    // Persistent, like the others: a controller rebuilt inside the dialog's
    // builder resets its text and cursor on every keystroke.
    final rackUnitsController = TextEditingController(
      text: node.rackUnits.toString(),
    );
    final wattsController = TextEditingController(
      text: node.powerWatts <= 0 ? '' : trimNumber(node.powerWatts),
    );
    final btuController = TextEditingController(
      text: node.btuPerHour <= 0 ? '' : trimNumber(node.btuPerHour),
    );
    final ports = List<AvPort>.from(node.ports);
    final lifeYearsController = TextEditingController(
      text: node.lifeYears <= 0 ? '' : node.lifeYears.toString(),
    );
    // The age record for this position: when the unit in it went in, and every
    // unit that was in it before. Held in the dialog rather than written on
    // each change so backing out changes nothing, like every other field here.
    DateTime? installedOn = node.installedOn;
    List<EquipmentSwap> swaps = node.swaps;
    PowerSource powerSource = node.powerSource;
    bool excludeFromCost = node.excludeFromCost;
    bool excludeFromControl = node.excludeFromControl;
    String locationId = node.locationId;
    // Where this box's cables move to when the model under it is swapped, as
    // old port id -> new port id. Empty until somebody does swap it; see
    // [remapPorts] for how the two connector lists are lined up.
    var portRemap = <String, String>{};
    // Owned out here rather than built inside the dialog's builder: the
    // scrollbar needs the same controller as the list it is describing, and
    // one created per rebuild loses its position on every keystroke.
    final portScroll = ScrollController();

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Edit ${node.label}'),
          content: SizedBox(
            // Wide enough for a whole port row, but never wider than the
            // window — the port rows shrink to fit whatever is left.
            width: math.min(820, MediaQuery.of(ctx).size.width - 120),
            // Sixty taller than it was, which is exactly the row the install
            // date and life added above the connector list. The list lives in
            // an Expanded, so anything added over it comes straight out of the
            // connectors — and a dialog that shows one fewer port than it used
            // to is a dialog somebody has to scroll to do what they came for.
            height: math.min(620, MediaQuery.of(ctx).size.height - 200),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: labelController,
                        decoration: const InputDecoration(labelText: 'Name'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: modelController,
                        decoration: InputDecoration(
                          labelText: 'Model',
                          // Typing a model name here renames the box and
                          // nothing else. Swapping the box for a different
                          // product means new connectors, a new rack height
                          // and a new price, which is what this fetches.
                          suffixIcon: IconButton(
                            key: const ValueKey('node_swap_model'),
                            icon: const Icon(Icons.find_replace, size: 18),
                            tooltip: 'Replace with a model from the catalog',
                            onPressed: () async {
                              final picked = await pickCatalogModel(
                                ctx,
                                provider,
                                title: 'Replace ${node.label}',
                                actionLabel: 'Replace',
                                currentModel: modelController.text.trim(),
                                note: 'The connectors come with it. Cables '
                                    'are carried over to the matching '
                                    'connector on the new box wherever there '
                                    'is one.',
                              );
                              if (picked == null) return;
                              final swapped = withOutletNames(
                                withPowerInlet(
                                  picked.ports,
                                  picked.powerInput,
                                ),
                                node.id,
                                provider.roomConfig,
                              );
                              setLocal(() {
                                portRemap = remapPorts(ports, swapped);
                                ports
                                  ..clear()
                                  ..addAll(swapped);
                                modelController.text = picked.model;
                                rackUnitsController.text =
                                    picked.rackUnits.toString();
                                wattsController.text = picked.powerWatts <= 0
                                    ? ''
                                    : trimNumber(picked.powerWatts);
                                btuController.text = picked.btuPerHour <= 0
                                    ? ''
                                    : trimNumber(picked.btuPerHour);
                                // Only when the model DECIDES it — a mains box
                                // is plugged in wherever this room plugs it
                                // in, and that is not the catalog's business.
                                final implied =
                                    powerSourceForInput(picked.powerInput);
                                if (implied != PowerSource.unspecified) {
                                  powerSource = implied;
                                }
                                // THE AGE RECORD MOVES WITH THE BOX. A
                                // different product in this position means the
                                // unit that was here came out, so it is filed
                                // and the clock starts again - the same
                                // bookkeeping planModelSwap does for every
                                // other route to a swap.
                                //
                                // Derived from the box AS IT WAS OPENED rather
                                // than from whatever the last press left
                                // behind, so trying three models before
                                // pressing Save files one replacement instead
                                // of three.
                                final replaced =
                                    picked.model.trim().toLowerCase() !=
                                        node.model.trim().toLowerCase();
                                final aged = replaced
                                    ? node.withSwapRecorded(on: DateTime.now())
                                    : node;
                                swaps = aged.swaps;
                                installedOn = aged.installedOn;
                              });
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 96,
                      child: TextField(
                        controller: rackUnitsController,
                        decoration: const InputDecoration(
                          labelText: 'Rack U',
                          helperText: '0 = none',
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Seeded from the catalog, editable here: the same model
                    // can sit behind a different supply room to room, and the
                    // power estimate is only as good as this number.
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: wattsController,
                        decoration: const InputDecoration(
                          labelText: 'Watts',
                          helperText: 'blank = unknown',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.]'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 120,
                      child: TextField(
                        controller: btuController,
                        decoration: const InputDecoration(
                          labelText: 'BTU/hr',
                          helperText: 'blank = from W',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.]'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Where in the room this box physically is. Every per-location
                // jack count, cable count and floor plan marker is built from
                // this one field, so it sits with the device's other facts
                // rather than in a page of its own nobody visits.
                _LocationField(
                  provider: provider,
                  value: locationId,
                  onChanged: (v) => setLocal(() => locationId = v),
                ),
                const SizedBox(height: 8),
                // WHEN THIS ONE WENT IN. The whole refresh plan - this room's
                // Lifecycle tab and the building's - is derived from this
                // field and nothing else, so it sits with the box's other
                // physical facts rather than on a survey screen somebody
                // visits once.
                Row(
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('node_installed_on'),
                      onPressed: () async {
                        final now = DateTime.now();
                        final picked = await showSteppedDatePicker(
                          ctx,
                          initialDate: installedOn ?? now,
                          // Twenty-five years back covers anything still
                          // running; a year forward covers gear specified now
                          // and going in next summer.
                          firstDate: DateTime(now.year - 25, 1, 1),
                          lastDate: DateTime(now.year + 1, 12, 31),
                          helpText: 'When did this go in?',
                        );
                        if (picked == null) return;
                        setLocal(() => installedOn = picked);
                      },
                      icon: const Icon(Icons.event_available, size: 18),
                      label: Text(
                        installedOn == null
                            ? 'Install date not recorded'
                            : 'Installed ${formatEquipmentDate(installedOn!)}',
                      ),
                    ),
                    if (installedOn != null)
                      IconButton(
                        key: const ValueKey('node_installed_on_clear'),
                        tooltip: 'Nobody knows when this went in',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setLocal(() => installedOn = null),
                      ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 150,
                      child: TextField(
                        key: const ValueKey('node_life_years'),
                        controller: lifeYearsController,
                        decoration: InputDecoration(
                          labelText: 'Life (years)',
                          helperText: _lifeHelper(
                            provider,
                            modelController.text,
                          ),
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (swaps.isNotEmpty)
                      Expanded(
                        child: Text(
                          'Replaced ${swaps.length} time'
                          '${swaps.length == 1 ? '' : 's'} before; the last '
                          'one lasted '
                          '${formatEquipmentAge(swaps.last.servedYears)}.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(ctx).hintColor,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: noteController,
                        decoration: const InputDecoration(
                          labelText: 'Note (shown in the pack list)',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Where the mains comes from. Recorded per device so the
                    // power report can separate "APC outlet 3" from "straight
                    // into the wall" from "PoE".
                    SizedBox(
                      width: 230,
                      child: DropdownButtonFormField<PowerSource>(
                        initialValue: powerSource,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Power'),
                        items: [
                          for (final ps in PowerSource.values)
                            DropdownMenuItem(
                              value: ps,
                              child: Text(
                                kPowerSourceLabels[ps] ?? ps.name,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                        ],
                        onChanged: (v) =>
                            setLocal(() => powerSource = v ?? powerSource),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // Drawn, and not driven. The other half of the checkbox below
                // it: a room is full of boxes the processor has no business
                // talking to, and an app that keeps asking for a config block
                // for the building's network switch is an app whose warnings
                // get ignored.
                Row(
                  children: [
                    Checkbox(
                      key: const ValueKey('node_exclude_control'),
                      value: excludeFromControl,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (v) =>
                          setLocal(() => excludeFromControl = v ?? false),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setLocal(
                          () => excludeFromControl = !excludeFromControl,
                        ),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              const TextSpan(
                                text: 'Not part of the room config',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              TextSpan(
                                text: '  - the building network switch, a '
                                    'codec another department manages, a '
                                    'passive box. It stays drawn, cabled and '
                                    'quoted; it stops being reported as '
                                    'missing a device block.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(ctx).hintColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // Drawn but not bought. The box still has to be on the page —
                // the signal goes through it and the rack has to hold it — and
                // it has no business on the quote.
                Row(
                  children: [
                    Checkbox(
                      value: excludeFromCost,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (v) =>
                          setLocal(() => excludeFromCost = v ?? false),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GestureDetector(
                        onTap: () =>
                            setLocal(() => excludeFromCost = !excludeFromCost),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              const TextSpan(
                                text: 'Not on the cost estimate',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              TextSpan(
                                text: '  - existing gear, owner-furnished, or '
                                    'somebody else\'s contract. It stays on '
                                    'the diagram, the cable schedule, the rack '
                                    'and the power report; only the money '
                                    'comes off.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(ctx).hintColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      'Connectors',
                      style: Theme.of(ctx).textTheme.titleSmall,
                    ),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Reset from library'),
                      onPressed: () {
                        final template = provider.avDeviceLibrary.resolve(
                          configKey: node.id,
                          model: modelController.text.trim(),
                        );
                        setLocal(() {
                          ports
                            ..clear()
                            ..addAll(
                              withOutletNames(
                                withPowerInlet(
                                  template.ports,
                                  template.powerInput,
                                ),
                                node.id,
                                provider.roomConfig,
                              ),
                            );
                          // The catalog's rack height and draw come back with
                          // the connectors — they describe the same box, and
                          // resetting half of it is how a device ends up 2U
                          // with a 1U model's ports.
                          rackUnitsController.text = template.rackUnits
                              .toString();
                          if (template.powerWatts > 0) {
                            wattsController.text = trimNumber(
                              template.powerWatts,
                            );
                          }
                          if (template.btuPerHour > 0) {
                            btuController.text = trimNumber(
                              template.btuPerHour,
                            );
                          }
                        });
                      },
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add port'),
                      onPressed: () =>
                          setLocal(() => ports.add(newAvPort(index: ports.length))),
                    ),
                  ],
                ),
                const Divider(),
                Expanded(
                  child: ports.isEmpty
                      ? const Center(child: Text('No connectors defined.'))
                      : Builder(
                          builder: (ctx) {
                            // Keyed on the port so a drag carries each row's
                            // text field and focus with it, rather than
                            // leaving the values behind at the old index.
                            final keys = avPortRowKeys(ports);
                            // The scrollbar used to sit on top of the rows,
                            // over the delete button and the right edge of the
                            // label field — grabbing one meant hitting the
                            // other. It gets a channel of its own now, and the
                            // list is inset clear of it.
                            return Scrollbar(
                              controller: portScroll,
                              thumbVisibility: true,
                              child: Padding(
                                padding:
                                    const EdgeInsets.only(right: kPortListScrollGutter),
                                child: ReorderableListView.builder(
                              scrollController: portScroll,
                              // The stock desktop handle is an icon floated
                              // over the bottom-right of the tile, which on a
                              // row this dense lands on top of the delete
                              // button. The row draws its own grip instead.
                              buildDefaultDragHandles: false,
                              itemCount: ports.length,
                              // onReorderItem, not onReorder: it hands over an
                              // index already corrected for the dragged row
                              // having left the list, so the off-by-one the
                              // old callback made every caller write by hand
                              // cannot be got wrong.
                              onReorderItem: (from, to) => setLocal(
                                () => ports.insert(to, ports.removeAt(from)),
                              ),
                              itemBuilder: (ctx, i) => AvPortEditorRow(
                                key: keys[i],
                                dragIndex: i,
                                port: ports[i],
                                palette: palette,
                                onChanged: (p) => setLocal(() => ports[i] = p),
                                onDelete: () =>
                                    setLocal(() => ports.removeAt(i)),
                                onMoveUp: i == 0
                                    ? null
                                    : () => setLocal(() {
                                        final p = ports.removeAt(i);
                                        ports.insert(i - 1, p);
                                      }),
                                onMoveDown: i == ports.length - 1
                                    ? null
                                    : () => setLocal(() {
                                        final p = ports.removeAt(i);
                                        ports.insert(i + 1, p);
                                      }),
                              ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('delete'),
              child: Text(
                'Remove device',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('catalog'),
              child: const Text('Save to catalog'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('copy'),
              child: const Text('Copy as JSON'),
            ),
            // No Spacer here: AlertDialog lays its actions out in an
            // OverflowBar, which is not a Flex, so an Expanded inside it
            // throws and takes the whole tab down with it.
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

    if (result == 'delete') {
      provider.removeAvNode(node.id);
      _snack('${node.label} removed, along with its cables.');
      return;
    }

    // Jack numbers renamed by hand get the same duplicate check the add
    // dialog does. This is the path that actually produces clashes in
    // practice: the numbering is right when a box is created and drifts when
    // somebody retypes a jack to match what got installed.
    if (node.isJackField && result == 'save') {
      final clashes = duplicateJackLabels(
        ports.map((p) => p.label),
        provider.avNodes,
        exceptNodeId: node.id,
      );
      if (clashes.isNotEmpty && mounted) {
        final keep = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(
              '${clashes.length} jack number'
              '${clashes.length == 1 ? '' : 's'} already in use',
            ),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'An installer finds a jack number on the report and '
                    'expects one thing behind it. Two boxes numbered alike is '
                    'a patch made to the wrong jack.',
                  ),
                  const SizedBox(height: 10),
                  for (final clash in clashes.take(8))
                    Text('${clash.label} - also on ${clash.usedBy}'),
                  if (clashes.length > 8)
                    Text('…and ${clashes.length - 8} more'),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Go back and fix them'),
              ),
              // Not a refusal: a room really can have two plates numbered the
              // same because that is what is on the wall, and the app is not
              // in a position to say otherwise. It just must not happen by
              // accident.
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Save anyway'),
              ),
            ],
          ),
        );
        if (keep != true) return;
      }
    }

    final updated = node.copyWith(
      label: labelController.text.trim().isEmpty
          ? node.label
          : labelController.text.trim(),
      model: modelController.text.trim(),
      note: noteController.text.trim(),
      rackUnits: int.tryParse(rackUnitsController.text.trim()) ?? 0,
      powerWatts: double.tryParse(wattsController.text.trim()) ?? 0,
      btuPerHour: double.tryParse(btuController.text.trim()) ?? 0,
      powerSource: powerSource,
      excludeFromCost: excludeFromCost,
      excludeFromControl: excludeFromControl,
      locationId: locationId,
      installedOn: installedOn,
      clearInstalledOn: installedOn == null,
      lifeYears: int.tryParse(lifeYearsController.text.trim()) ?? 0,
      swaps: swaps,
      ports: ports,
    );

    if (result == 'catalog' || result == 'copy') {
      final entry = AvDeviceTemplate(
        model: updated.model.isEmpty ? updated.label : updated.model,
        rackUnits: updated.rackUnits,
        powerWatts: updated.powerWatts,
        btuPerHour: updated.btuPerHour,
        powerInput: updated.ports.any((p) => p.isPowerInlet)
            ? (updated.powerSource == PowerSource.poe
                  ? PowerInput.poe
                  : PowerInput.mains)
            : PowerInput.none,
        // NOT the box's life. A position's [AvNode.lifeYears] is somebody
        // saying "this one, sooner" - the lectern PC in the teaching lab -
        // and pushing it onto the product would make one room's exception the
        // average for every room that specifies the model. The product's
        // average is typed on the Catalog tab, which is where it belongs.
        ports: updated.ports,
      );
      if (result == 'copy') {
        await Clipboard.setData(
          ClipboardData(
            text: const JsonEncoder.withIndent('  ').convert(entry.toJson()),
          ),
        );
        _snack(
          'Catalog entry copied - paste it into the "devices" array of '
          'av_devices.json.',
        );
      } else {
        // Straight into the catalog, keeping whatever price and part number
        // that model already carries: this button is about the connectors and
        // the physical facts, not about repricing the model.
        final existing = provider.avDeviceLibrary.templateForModel(entry.model);
        provider.avDeviceLibrary.upsert(
          existing == null
              ? entry
              : existing.copyWith(
                  rackUnits: entry.rackUnits,
                  powerWatts: entry.powerWatts > 0
                      ? entry.powerWatts
                      : existing.powerWatts,
                  btuPerHour: entry.btuPerHour > 0
                      ? entry.btuPerHour
                      : existing.btuPerHour,
                  powerInput: entry.powerInput,
                  ports: entry.ports,
                ),
        );
        final saved = await provider.saveAvDeviceLibrary();
        _snack(
          saved.isEmpty
              ? 'Could not save the device catalog.'
              : '${entry.model} saved to the device catalog '
                    '(${path.basename(saved)}).',
          error: saved.isEmpty,
        );
      }
    }

    // A swapped model brings a different set of connectors, and the runs
    // already drawn to this box are moved onto their counterparts on the new
    // one. What has no counterpart falls through to the sweep below, which is
    // the right order: carry across what can be carried, then say out loud
    // what could not.
    if (portRemap.isNotEmpty) {
      for (final c in List<AvCable>.from(provider.avCables)) {
        final fromMoved =
            c.fromNodeId == node.id ? portRemap[c.fromPortId] : null;
        final toMoved = c.toNodeId == node.id ? portRemap[c.toPortId] : null;
        if (fromMoved == null && toMoved == null) continue;
        provider.updateAvCable(
          c.copyWith(fromPortId: fromMoved, toPortId: toMoved),
          recordUndo: false,
        );
      }
    }

    // Cables referencing a port that was deleted or re-id'd disappear on the
    // next build (cableIsResolvable), so warn rather than silently dropping.
    final removedIds = node.ports
        .map((p) => p.id)
        .where((id) =>
            !portRemap.containsKey(id) && !ports.any((p) => p.id == id))
        .toSet();
    if (removedIds.isNotEmpty) {
      final orphaned = provider.avCables
          .where(
            (c) =>
                (c.fromNodeId == node.id &&
                    removedIds.contains(c.fromPortId)) ||
                (c.toNodeId == node.id && removedIds.contains(c.toPortId)),
          )
          .toList();
      for (final c in orphaned) {
        provider.removeAvCable(c.id);
      }
      if (orphaned.isNotEmpty) {
        _snack(
          portRemap.isEmpty
              ? '${orphaned.length} cable'
                  '${orphaned.length == 1 ? '' : 's'} removed with the '
                  'deleted connectors.'
              : '${orphaned.length} cable'
                  '${orphaned.length == 1 ? '' : 's'} removed - '
                  '${modelController.text.trim()} has no connector matching '
                  'the one ${orphaned.length == 1 ? 'it was' : 'they were'} '
                  'drawn to. Draw ${orphaned.length == 1 ? 'it' : 'them'} '
                  'again on the new box.',
        );
      }
    }

    provider.updateAvNode(updated);
  }

  /// The room's signal palette. Read on demand rather than cached: it can
  /// change from the Colors dialog while a port editor is open.
  Map<SignalType, Color> get palette =>
      context.read<AppStateProvider>().avSignalColors;

  // --- cable list ---------------------------------------------------------

  Widget _buildCablePanel(AppStateProvider provider, AvFlowModel model) {
    final theme = Theme.of(context);
    final byId = model.nodesById;

    String endpoint(String nodeId, String portId) {
      final node = byId[nodeId];
      final port = node?.portById(portId);
      return '${node?.label ?? nodeId} · ${port?.label ?? portId}';
    }

    // Cables whose endpoints vanished are not drawn; list them so a run that
    // disappeared after a device change has a visible explanation.
    final orphaned = provider.avCables.where(
      (c) => !AvFlowModel.cableIsResolvable(c, byId),
    );

    return Container(
      width: double.infinity,
      // The height belongs to the [BottomPane] this sits in, so the cable
      // list can be dragged taller — a room's worth of runs does not fit in
      // 200 pixels, and it is the list somebody is working down.
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: ListView(
        shrinkWrap: true, // one line of help shouldn't hold open the panel
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _pendingPort != null
                      ? 'Now click the connector at the other end of the cable '
                            '(click the same one again to cancel).'
                      : _cableMode
                      ? 'Click a connector, then the connector at the other '
                            'end, to draw a cable. Turn off "Draw Cable" to '
                            'move devices again.'
                      : 'Drag a device to move it. Click its header pencil to '
                            'rename it or edit its connectors. Turn on "Draw '
                            'Cable" to wire connectors together. Click a cable '
                            'to add bends.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              // Lengths are set HERE rather than one cable dialog at a time:
              // a room is usually cabled in one or two lead lengths, and
              // twenty dialogs to say so is twenty chances to miss one.
              if (model.cables.isNotEmpty)
                TextButton.icon(
                  key: const ValueKey('av_cable_lengths'),
                  icon: const Icon(Icons.straighten, size: 16),
                  label: const Text('Cable lengths'),
                  onPressed: () => _showCableLengthsDialog(provider, model),
                ),
            ],
          ),
          const SizedBox(height: 4),
          for (final c in model.cables)
            Row(
              children: [
                Container(
                  width: 26,
                  height: 4,
                  margin: const EdgeInsets.only(right: 10),
                  color: c.colorFor(provider.avSignalColors),
                ),
                SizedBox(
                  width: 44,
                  child: Text(c.id, style: theme.textTheme.bodySmall),
                ),
                Expanded(
                  child: Text(
                    '${endpoint(c.fromNodeId, c.fromPortId)}  →  '
                    '${endpoint(c.toNodeId, c.toPortId)}'
                    '${c.label.isEmpty ? '' : '   (${c.label})'}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  kSignalLabels[c.signal] ?? c.signal.name,
                  style: theme.textTheme.bodySmall,
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    formatCableLength(c.lengthFt),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  key: ValueKey('av_cable_edit_${c.id}'),
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: 'Edit this cable',
                  onPressed: () => _showCableDialog(provider, c),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: 'Remove this cable',
                  onPressed: () => provider.removeAvCable(c.id),
                ),
              ],
            ),
          for (final c in orphaned)
            Row(
              children: [
                const SizedBox(width: 36),
                Expanded(
                  child: Text(
                    '${c.id}: endpoint no longer exists '
                    '(${c.fromNodeId}·${c.fromPortId} → ${c.toNodeId}·${c.toPortId})',
                    style: TextStyle(color: theme.disabledColor),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: 'Discard this dangling cable',
                  onPressed: () => provider.removeAvCable(c.id),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// Sets the lead length on every run at once, on every run of one signal, or
  /// one run at a time — all three in one place, because "the room is all 25ft
  /// except the two in the rack" is what actually happens.
  Future<void> _showCableLengthsDialog(
    AppStateProvider provider,
    AvFlowModel model,
  ) async {
    final byId = model.nodesById;
    String endpoint(String nodeId, String portId) {
      final node = byId[nodeId];
      return '${node?.label ?? nodeId} · '
          '${node?.portById(portId)?.label ?? portId}';
    }

    double bulk = kCableLengthsFt.first;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          // Read back off the provider each rebuild so the list shows what was
          // just applied rather than the snapshot the dialog opened on.
          final cables = provider.avCables
              .where((c) => AvFlowModel.cableIsResolvable(c, byId))
              .toList();
          final signals = <SignalType>{for (final c in cables) c.signal}
              .toList()
            ..sort((a, b) => a.index.compareTo(b.index));

          return AlertDialog(
            title: const Text('Cable lengths'),
            content: SizedBox(
              width: 620,
              height: 520,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('Set every run to'),
                      const SizedBox(width: 10),
                      DropdownButton<double>(
                        key: const ValueKey('av_lengths_bulk'),
                        value: bulk,
                        items: [
                          const DropdownMenuItem(
                            value: 0.0,
                            child: Text('Not set'),
                          ),
                          for (final ft in kCableLengthsFt)
                            DropdownMenuItem(
                              value: ft,
                              child: Text(formatCableLength(ft)),
                            ),
                        ],
                        onChanged: (v) => setLocal(() => bulk = v ?? 0),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        key: const ValueKey('av_lengths_apply_all'),
                        onPressed: () {
                          final n = provider.setAllAvCableLengths(bulk);
                          setLocal(() {});
                          _snack(n == 0
                              ? 'Every run was already '
                                  '${bulk <= 0 ? 'unset' : formatCableLength(bulk)}.'
                              : 'Set $n run${n == 1 ? '' : 's'} to '
                                  '${bulk <= 0 ? 'not set' : formatCableLength(bulk)}.');
                        },
                        child: const Text('Apply to all'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Per signal type: the runs that share a length usually
                  // share a signal — every Dante drop is the same lead.
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'or just the',
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                      for (final s in signals)
                        OutlinedButton(
                          onPressed: () {
                            final n = provider.setAllAvCableLengths(
                              bulk,
                              only: s,
                            );
                            setLocal(() {});
                            _snack('Set $n ${cableTypeLabel(s)} '
                                'run${n == 1 ? '' : 's'}.');
                          },
                          child: Text(
                            '${cableTypeLabel(s)}'
                            '${cableSignalSubLabel(s).isEmpty ? '' : ' · ${cableSignalSubLabel(s)}'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                  ),
                  const Divider(height: 20),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final c in cables)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 44,
                                  child: Text(
                                    c.id,
                                    style: Theme.of(ctx).textTheme.bodySmall,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    '${endpoint(c.fromNodeId, c.fromPortId)}'
                                    '  →  '
                                    '${endpoint(c.toNodeId, c.toPortId)}',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 96,
                                  child: DropdownButton<double>(
                                    key: ValueKey('av_length_${c.id}'),
                                    isExpanded: true,
                                    value: kCableLengthsFt.contains(c.lengthFt)
                                        ? c.lengthFt
                                        : 0,
                                    items: [
                                      const DropdownMenuItem(
                                        value: 0.0,
                                        child: Text('-'),
                                      ),
                                      for (final ft in kCableLengthsFt)
                                        DropdownMenuItem(
                                          value: ft,
                                          child: Text(formatCableLength(ft)),
                                        ),
                                    ],
                                    onChanged: (v) {
                                      provider.setAvCableLength(c.id, v ?? 0);
                                      setLocal(() {});
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showCableDialog(
    AppStateProvider provider,
    AvCable cable,
  ) async {
    final labelController = TextEditingController(text: cable.label);
    SignalType signal = cable.signal;
    Offset labelOffset = cable.labelOffset;
    double lengthFt = cable.lengthFt;
    Color? colorOverride = cable.colorOverride;
    // Where the run lands. Held here rather than written straight through, so
    // Cancel still means cancel after moving an end.
    var from = (nodeId: cable.fromNodeId, portId: cable.fromPortId);
    var to = (nodeId: cable.toNodeId, portId: cable.toPortId);

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Cable ${cable.id}'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Which connectors the run lands on. Editable because a lead
                // that turned out to be on input 4 rather than input 3 is the
                // same lead: deleting and redrawing it loses the cable id, the
                // label and the length somebody had filled in.
                Text('Connection', style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 4),
                _cableEndRow(
                  ctx,
                  provider,
                  keyName: 'cable_from_end',
                  heading: 'Output',
                  end: from,
                  buttonLabel: 'Change output',
                  otherEnd: to,
                  movingSource: true,
                  onPicked: (picked) => setLocal(() {
                    // The signal follows the source unless somebody has
                    // already overridden it: moving a run onto a DTP output
                    // and leaving it drawn as HDMI helps nobody, and quietly
                    // discarding a deliberate choice helps less.
                    final oldPort =
                        provider.avNodeById(from.nodeId)?.portById(from.portId);
                    final newPort = provider
                        .avNodeById(picked.nodeId)
                        ?.portById(picked.portId);
                    if (oldPort != null &&
                        newPort != null &&
                        signal == oldPort.signal) {
                      signal = newPort.signal;
                    }
                    from = picked;
                  }),
                ),
                _cableEndRow(
                  ctx,
                  provider,
                  keyName: 'cable_to_end',
                  heading: 'Input',
                  end: to,
                  buttonLabel: 'Change input',
                  otherEnd: from,
                  movingSource: false,
                  onPicked: (picked) => setLocal(() => to = picked),
                ),
                const Divider(height: 20),
                DropdownButtonFormField<SignalType>(
                  key: ValueKey('cable_signal_${signal.name}'),
                  initialValue: signal,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Signal type'),
                  items: [
                    for (final s in SignalType.values)
                      DropdownMenuItem(
                        value: s,
                        child: Row(
                          children: [
                            Container(
                              width: 20,
                              height: 3.5,
                              margin: const EdgeInsets.only(right: 8),
                              color: provider.avSignalColor(s),
                            ),
                            Text(kSignalLabels[s] ?? s.name),
                          ],
                        ),
                      ),
                  ],
                  onChanged: (v) => setLocal(() => signal = v ?? signal),
                ),
                const SizedBox(height: 12),
                // The lead length, off a fixed list: a cable schedule is an
                // order, and a made-up lead comes in the lengths the shop
                // stocks. A run pulled to length in conduit stays unset, which
                // the counts report as its own column.
                DropdownButtonFormField<double>(
                  key: const ValueKey('cable_length'),
                  initialValue:
                      kCableLengthsFt.contains(lengthFt) ? lengthFt : 0,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Length'),
                  items: [
                    const DropdownMenuItem(value: 0.0, child: Text('Not set')),
                    for (final ft in kCableLengthsFt)
                      DropdownMenuItem(
                        value: ft,
                        child: Text(formatCableLength(ft)),
                      ),
                  ],
                  onChanged: (v) => setLocal(() => lengthFt = v ?? 0),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: labelController,
                  decoration: InputDecoration(
                    labelText: 'Label / cable ID',
                    hintText: 'e.g. HDMI-04',
                    helperText: 'Drag it on the diagram to move it',
                    // Only offered once it HAS been moved: a button that does
                    // nothing is a button somebody presses to find out.
                    suffixIcon: labelOffset == Offset.zero
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.restart_alt, size: 18),
                            tooltip: 'Put the label back on the line',
                            onPressed: () =>
                                setLocal(() => labelOffset = Offset.zero),
                          ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text('Color', style: Theme.of(ctx).textTheme.titleSmall),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        colorOverride == null
                            ? 'Following the signal type'
                            : 'Custom for this run',
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                    ),
                    if (colorOverride != null)
                      TextButton(
                        onPressed: () => setLocal(() => colorOverride = null),
                        child: const Text('Match signal'),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 2,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    // First chip resets to the signal type's own color, so
                    // the default is one click away and looks like the rest.
                    ColorSwatchButton(
                      key: const ValueKey('cable_color_default'),
                      color: provider.avSignalColor(signal),
                      selected: colorOverride == null,
                      badge: Icons.auto_awesome,
                      tooltip: 'Follow the signal type',
                      onTap: () => setLocal(() => colorOverride = null),
                    ),
                    for (final c in kCableSwatches)
                      ColorSwatchButton(
                        key: ValueKey(
                          'cable_color_'
                          '${(c.toARGB32() & 0xFFFFFF).toRadixString(16)}',
                        ),
                        color: c,
                        selected: colorOverride?.toARGB32() == c.toARGB32(),
                        onTap: () => setLocal(() => colorOverride = c),
                      ),
                    // Anything not on the row above.
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.colorize, size: 16),
                        label: const Text('Custom'),
                        onPressed: () async {
                          final picked = await showColorWheelDialog(
                            ctx,
                            initial: colorOverride ??
                                provider.avSignalColor(signal),
                            title: 'Color for cable ${cable.id}',
                          );
                          if (picked != null) {
                            setLocal(() => colorOverride = picked);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('straighten'),
              child: const Text('Clear bends'),
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

    final moved = from.nodeId != cable.fromNodeId ||
        from.portId != cable.fromPortId ||
        to.nodeId != cable.toNodeId ||
        to.portId != cable.toPortId;
    if (moved &&
        provider.avCables.any((c) =>
            c.id != cable.id &&
            c.fromNodeId == from.nodeId &&
            c.fromPortId == from.portId &&
            c.toNodeId == to.nodeId &&
            c.toPortId == to.portId)) {
      _snack(
        'Those two connectors are already cabled together - the move was not '
        'made.',
        error: true,
      );
      return;
    }

    provider.updateAvCable(
      cable.copyWith(
        fromNodeId: from.nodeId,
        fromPortId: from.portId,
        toNodeId: to.nodeId,
        toPortId: to.portId,
        signal: signal,
        label: labelController.text.trim(),
        labelOffset: labelOffset,
        lengthFt: lengthFt,
        // A route bent by hand is a route around the boxes it used to run
        // between. Landed on a different connector it describes a path that no
        // longer exists, so the bends go with the move.
        waypoints:
            result == 'straighten' || moved ? const [] : cable.waypoints,
        colorOverride: colorOverride,
        clearColorOverride: colorOverride == null,
      ),
    );
  }

  /// One end of a cable in the cable dialog: where it lands now, and a button
  /// to land it somewhere else.
  Widget _cableEndRow(
    BuildContext ctx,
    AppStateProvider provider, {
    required String keyName,
    required String heading,
    required CableEnd end,
    required CableEnd otherEnd,
    required bool movingSource,
    required String buttonLabel,
    required ValueChanged<CableEnd> onPicked,
  }) {
    final node = provider.avNodeById(end.nodeId);
    final port = node?.portById(end.portId);
    final fixedNode = provider.avNodeById(otherEnd.nodeId);
    final fixedPort = fixedNode?.portById(otherEnd.portId);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 58,
            child: Text(heading, style: Theme.of(ctx).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              '${node?.label ?? end.nodeId} · ${port?.label ?? end.portId}',
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            key: ValueKey(keyName),
            // Nothing to move it against when the other end has gone: that is
            // a cable the canvas already declines to draw.
            onPressed: fixedNode == null || fixedPort == null
                ? null
                : () async {
                    final picked = await pickCableEnd(
                      ctx,
                      provider,
                      movingSource: movingSource,
                      fixedNode: fixedNode,
                      fixedPort: fixedPort,
                      current: end,
                    );
                    if (picked != null) onPicked(picked);
                  },
            child: Text(buttonLabel),
          ),
        ],
      ),
    );
  }

}

/// How far the connector list is inset from the right so the scrollbar has a
/// channel of its own. Wide enough that the thumb never lands on the delete
/// button or the right edge of a text field, which is what made grabbing one
/// hit the other.
const double kPortListScrollGutter = 16;

// ---------------------------------------------------------------------------
//  LOCATION PICKER
// ---------------------------------------------------------------------------

/// Picks which of the room's locations something is in, with a way to add one
/// without leaving the dialog.
///
/// Making the list reachable from every editor is the whole difference between
/// locations that get filled in and a field that stays blank: nobody switches
/// tabs to define "front floor box" in the middle of adding a wall plate, so
/// the "+" defines it here and selects it.
class _LocationField extends StatelessWidget {
  final AppStateProvider provider;
  final String value;
  final String label;
  final ValueChanged<String> onChanged;

  const _LocationField({
    required this.provider,
    required this.value,
    required this.onChanged,
    this.label = 'Location in the room',
  });

  @override
  Widget build(BuildContext context) {
    // A stale id — the location was deleted while this dialog was open —
    // shows as unset rather than crashing the dropdown's value assertion.
    final known = {for (final l in provider.avLocations) l.id};
    final safe = known.contains(value) ? value : kNoLocationId;

    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: safe,
            isExpanded: true,
            decoration: InputDecoration(labelText: label),
            items: [
              const DropdownMenuItem(
                value: kNoLocationId,
                child: Text('Not recorded'),
              ),
              for (final l in provider.avLocations)
                DropdownMenuItem(
                  value: l.id,
                  child: Row(
                    children: [
                      Icon(kRoomZoneIcons[l.zone] ?? Icons.place, size: 15),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l.displayName,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        kRoomZoneCodes[l.zone] ?? '',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
            ],
            onChanged: (v) => onChanged(v ?? kNoLocationId),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          icon: const Icon(Icons.add_location_alt_outlined, size: 20),
          tooltip: 'Add a location',
          onPressed: () async {
            final created = await showLocationEditor(context, provider, null);
            if (created != null) onChanged(created.id);
          },
        ),
      ],
    );
  }
}

/// Says which jack numbers are already taken, and offers the next free block.
class _JackClashBanner extends StatelessWidget {
  final List<({String label, String usedBy})> clashes;
  final VoidCallback onUseNextFree;

  const _JackClashBanner({required this.clashes, required this.onUseNextFree});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Long clash lists are truncated: the first few make the point, and a
    // dialog that grows past the window to list forty of them cannot be
    // dismissed.
    final shown = clashes.take(5).toList();
    // Measured against the fill rather than taken from the scheme:
    // onErrorContainer on errorContainer fails WCAG on 45 of the 180
    // theme/accent combinations this app can be set to.
    final bannerInk =
        foregroundOn(theme.colorScheme, theme.colorScheme.errorContainer);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline,
                size: 18,
                color: bannerInk,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${clashes.length} jack number'
                  '${clashes.length == 1 ? ' is' : 's are'} already in use',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: bannerInk,
                  ),
                ),
              ),
              TextButton(
                onPressed: onUseNextFree,
                child: const Text('Use the next free block'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final clash in shown)
            Text(
              '${clash.label} - ${clash.usedBy}',
              style: theme.textTheme.bodySmall?.copyWith(color: bannerInk),
            ),
          if (clashes.length > shown.length)
            Text(
              '…and ${clashes.length - shown.length} more',
              style: theme.textTheme.bodySmall?.copyWith(color: bannerInk),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  NODE WIDGET
// ---------------------------------------------------------------------------

/// One device box: a header (icon, name, model) over two columns of port
/// labels, with a round handle on the edge at each port's anchor point.
class _AvNodeBox extends StatelessWidget {
  final AvNode node;
  final bool editMode;

  /// The room's signal palette, so a recolored type moves its port dots too.
  final Map<SignalType, Color> palette;

  /// Cable-drawing mode: connectors are click targets and nothing drags.
  final bool cableMode;

  /// This device is the one currently under the cursor.
  final bool dragging;

  final bool racked;
  final String? pendingNodeId;
  final String? pendingPortId;

  /// The armed port, so incompatible ports can be dimmed while cabling.
  final AvPort? pendingPort;

  final ValueChanged<AvPort> onPortTap;

  /// Null when this device can't be dragged (view mode, or cable mode).
  final VoidCallback? onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onEdit;

  const _AvNodeBox({
    required this.node,
    required this.editMode,
    required this.palette,
    required this.cableMode,
    required this.dragging,
    required this.racked,
    required this.pendingNodeId,
    required this.pendingPortId,
    required this.pendingPort,
    required this.onPortTap,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onEdit,
  });

  bool get _canDrag => onDragStart != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final width = node.width;
    final height = node.height;

    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // The box itself, and the drag surface.
          GestureDetector(
            onPanStart: _canDrag ? (_) => onDragStart!() : null,
            onPanUpdate: _canDrag ? (d) => onDragUpdate(d.delta) : null,
            onPanEnd: _canDrag ? (_) => onDragEnd() : null,
            onPanCancel: _canDrag ? onDragEnd : null,
            child: MouseRegion(
              cursor: _canDrag
                  ? (dragging
                        ? SystemMouseCursors.grabbing
                        : SystemMouseCursors.grab)
                  : MouseCursor.defer,
              child: Container(
                width: width,
                height: height,
                decoration: BoxDecoration(
                  color: dark ? const Color(0xFF1E242B) : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: dragging
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outlineVariant,
                    width: dragging ? 2 : 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: dark ? 0.4 : (dragging ? 0.28 : 0.12),
                      ),
                      blurRadius: dragging ? 12 : 5,
                      offset: Offset(0, dragging ? 5 : 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Container(
                      height: kAvNodeHeaderHeight,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: dark ? 0.22 : 0.10,
                        ),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(7),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(iconForAvNode(node.id, node.model), size: 16),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  node.label,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (node.model.isNotEmpty)
                                  Text(
                                    node.model,
                                    style: TextStyle(
                                      fontSize: 9.5,
                                      color: theme.hintColor,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                          ),
                          // Marked on the box itself, because "why is the
                          // total short" is a question asked at the diagram,
                          // not at the dialog it was set in.
                          if (node.excludeFromCost)
                            Padding(
                              padding: const EdgeInsets.only(right: 2),
                              child: Tooltip(
                                message: 'Not on the cost estimate',
                                child: Icon(
                                  Icons.money_off,
                                  size: 13,
                                  color: theme.hintColor,
                                ),
                              ),
                            ),
                          if (node.excludeFromControl)
                            Padding(
                              padding: const EdgeInsets.only(right: 2),
                              child: Tooltip(
                                message: 'Not part of the room config',
                                child: Icon(
                                  Icons.link_off,
                                  size: 13,
                                  color: theme.hintColor,
                                ),
                              ),
                            ),
                          if (racked)
                            Padding(
                              padding: const EdgeInsets.only(right: 2),
                              child: Icon(
                                Icons.view_day,
                                size: 13,
                                color: theme.hintColor,
                              ),
                            ),
                          if (editMode)
                            InkWell(
                              key: ValueKey('av_edit_${node.id}'),
                              onTap: onEdit,
                              child: const Padding(
                                padding: EdgeInsets.all(2),
                                child: Icon(Icons.edit, size: 14),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Port rows: the whole row is the tap target, label included. The
          // dot alone is a poor target — it straddles the box edge, and
          // anything outside the parent's bounds is not hit-testable at all,
          // so half of it would be dead and a near miss would land on the
          // canvas and cancel the cable being drawn.
          for (final entry in _rowLabels(node))
            Positioned(
              left: entry.$3 ? 0 : width / 2,
              top: entry.$2 - kAvPortRowHeight / 2,
              width: width / 2,
              height: kAvPortRowHeight,
              child: _portRowTarget(context, entry.$1, entry.$3),
            ),

          // A panel's outlets are its whole content, so they get their numbers
          // printed above the row rather than only in a tooltip — the number
          // is the thing you read a panel for.
          //
          // Except when there is no room for them. Past a certain port count
          // the panel stops widening and the outlets compress, and six-digit
          // jack numbers at a 12px pitch are not small text, they are a smear.
          // The tooltip still has every number.
          if (node.isPatchPanel && _jackPitch(node) >= kAvPatchLabelMinPitch)
            for (final port in node.ports)
              Positioned(
                left: node.localAnchorOf(port.id).dx - _jackPitch(node) / 2,
                top: kAvNodeHeaderHeight + 3,
                width: _jackPitch(node),
                height: 14,
                child: IgnorePointer(
                  child: Text(
                    port.label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      color: _dimmed(port)
                          ? theme.disabledColor
                          : theme.textTheme.bodySmall?.color,
                    ),
                  ),
                ),
              ),

          // Top/bottom ports have no row, so they get a square target tucked
          // just inside the edge they sit on.
          for (final port in [...node.topPorts, ...node.bottomPorts])
            _edgePortTarget(context, port, width, height),

          // The dots themselves are painted last and ignore pointers — the
          // targets above own the interaction.
          for (final port in node.ports)
            Positioned(
              left: node.localAnchorOf(port.id).dx - kAvPortHandleRadius,
              top: node.localAnchorOf(port.id).dy - kAvPortHandleRadius,
              child: IgnorePointer(child: _portDot(context, port)),
            ),
        ],
      ),
    );
  }

  /// Space each outlet of a patch panel actually gets, which is the requested
  /// pitch until the panel hits its maximum width and starts compressing.
  static double _jackPitch(AvNode node) =>
      node.ports.isEmpty ? kAvPatchJackPitch : node.width / (node.ports.length + 1);

  /// (port, rowCenterY, isLeft) for every port that gets a label row.
  static List<(AvPort, double, bool)> _rowLabels(AvNode node) {
    final rows = <(AvPort, double, bool)>[];
    for (final p in node.leftPorts) {
      rows.add((p, node.localAnchorOf(p.id).dy, true));
    }
    for (final p in node.rightPorts) {
      rows.add((p, node.localAnchorOf(p.id).dy, false));
    }
    return rows;
  }

  /// True when [port] cannot take the cable currently being drawn, so it can
  /// be faded back while the valid targets stay bright.
  bool _dimmed(AvPort port) {
    if (pendingPort == null) return false;
    if (pendingNodeId == node.id && pendingPortId == port.id) return false;
    final forward =
        pendingPort!.direction != PortDirection.input &&
        port.direction != PortDirection.output;
    final backward =
        port.direction != PortDirection.input &&
        pendingPort!.direction != PortDirection.output;
    return !(forward || backward);
  }

  Widget _portDot(BuildContext context, AvPort port) {
    final isPending = pendingNodeId == node.id && pendingPortId == port.id;
    final color = signalColor(port.signal, palette);
    return Container(
      width: kAvPortHandleRadius * 2,
      height: kAvPortHandleRadius * 2,
      decoration: BoxDecoration(
        color: _dimmed(port) ? color.withValues(alpha: 0.25) : color,
        shape: BoxShape.circle,
        border: Border.all(
          color: isPending
              ? Theme.of(context).colorScheme.primary
              : Colors.white.withValues(alpha: 0.9),
          width: isPending ? 2.5 : 1.2,
        ),
      ),
    );
  }

  /// The clickable half-row for a left- or right-side port: its label, with
  /// room at the outer end where the dot is painted over the top.
  Widget _portRowTarget(BuildContext context, AvPort port, bool isLeft) {
    final theme = Theme.of(context);
    final isPending = pendingNodeId == node.id && pendingPortId == port.id;
    // The rows cover most of the box, so outside cable mode they forward the
    // drag — otherwise a device could only be moved by its header strip. In
    // cable mode they are pure click targets, so a click that travels a pixel
    // still connects instead of turning into a drag.
    return GestureDetector(
      onTap: cableMode ? () => onPortTap(port) : null,
      onPanStart: !cableMode && _canDrag ? (_) => onDragStart!() : null,
      onPanUpdate: !cableMode && _canDrag ? (d) => onDragUpdate(d.delta) : null,
      onPanEnd: !cableMode && _canDrag ? (_) => onDragEnd() : null,
      onPanCancel: !cableMode && _canDrag ? onDragEnd : null,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: cableMode
            ? SystemMouseCursors.precise
            : (_canDrag ? SystemMouseCursors.grab : MouseCursor.defer),
        child: Tooltip(
          message:
              '${port.label} · ${kSignalLabels[port.signal]}'
              ' · ${port.direction.name}',
          waitDuration: const Duration(milliseconds: 500),
          child: Container(
            alignment: isLeft ? Alignment.centerLeft : Alignment.centerRight,
            padding: EdgeInsets.only(
              left: isLeft ? kAvPortHandleRadius + 6 : 4,
              right: isLeft ? 4 : kAvPortHandleRadius + 6,
            ),
            decoration: isPending
                ? BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(3),
                  )
                : null,
            child: Text(
              port.label,
              textAlign: isLeft ? TextAlign.left : TextAlign.right,
              style: TextStyle(
                fontSize: 10,
                color: _dimmed(port)
                    ? theme.disabledColor
                    : theme.textTheme.bodySmall?.color,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }

  /// Tap target for a top- or bottom-edge port, held fully inside the box so
  /// it is hit-testable.
  Widget _edgePortTarget(
    BuildContext context,
    AvPort port,
    double width,
    double height,
  ) {
    const size = (kAvPortHandleRadius + 4) * 2;
    final anchor = node.localAnchorOf(port.id);
    return Positioned(
      left: (anchor.dx - size / 2).clamp(0.0, width - size),
      top: port.side == PortSide.top ? 0 : height - size,
      width: size,
      height: size,
      child: GestureDetector(
        onTap: cableMode ? () => onPortTap(port) : null,
        onPanStart: !cableMode && _canDrag ? (_) => onDragStart!() : null,
        onPanUpdate: !cableMode && _canDrag
            ? (d) => onDragUpdate(d.delta)
            : null,
        onPanEnd: !cableMode && _canDrag ? (_) => onDragEnd() : null,
        onPanCancel: !cableMode && _canDrag ? onDragEnd : null,
        behavior: HitTestBehavior.opaque,
        child: Tooltip(
          message:
              '${port.label} · ${kSignalLabels[port.signal]}'
              ' · ${port.direction.name}',
          waitDuration: const Duration(milliseconds: 500),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  CABLE PAINTER
// ---------------------------------------------------------------------------

/// Where the room title is drawn on the canvas, and the style it is drawn in.
///
/// Shared between the widget that draws it and [avRoomTitleRect], which is
/// what keeps the cables and the run labels off it: a title drawn somewhere
/// other than where the router believes it is would be routed straight
/// through again.
const double kAvRoomTitleLeft = 24;
const double kAvRoomTitleTop = 16;

TextStyle? _roomTitleStyle(ThemeData theme) =>
    theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold);

/// The title a room shows on its diagram — its own, or the page's name for a
/// room that has not been named yet.
String avRoomTitleText(String roomTitle) =>
    roomTitle.isEmpty ? 'AV Signal Flow' : roomTitle;

/// The patch of canvas the room title covers, with a margin, for the router to
/// treat as solid.
///
/// Measured rather than estimated: the title is a room name of any length in
/// whatever text scale the user runs at, and a guess that comes in short is a
/// cable through the last word of it.
Rect avRoomTitleRect(String title, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: title, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  return Rect.fromLTWH(
    kAvRoomTitleLeft,
    kAvRoomTitleTop,
    painter.width,
    painter.height,
  ).inflate(12);
}

/// Where a run's label sits before anybody drags it: the midpoint of the
/// longest leg, which is the stretch with the most room for text.
///
/// Null when no leg is long enough to write on — a two-inch patch between
/// adjacent boxes is better left unlabeled on the drawing than covered by
/// its own cable number.
Offset? cableLabelAnchor(List<Offset> points) {
  var bestIndex = 0;
  var bestLength = 0.0;
  for (int i = 0; i < points.length - 1; i++) {
    final length = (points[i + 1] - points[i]).distance;
    if (length > bestLength) {
      bestLength = length;
      bestIndex = i;
    }
  }
  if (bestLength < 30) return null;
  return (points[bestIndex] + points[bestIndex + 1]) / 2;
}

/// Roughly what a run's label covers, centered on [at]. Measured from the
/// character count rather than laid out for real: this runs for every label on
/// every repaint, and a few pixels either way only decides whether two labels
/// are judged to be touching.
Rect _labelRect(Offset at, String text) {
  const height = 16.0;
  final width = 10 + text.length * 5.8;
  return Rect.fromCenter(center: at, width: width, height: height);
}

/// Somewhere near [anchor] that none of the labels in [taken] already covers.
///
/// Runs sharing a corridor land their labels within a few pixels of each
/// other — the lane offsets separate the LINES, not the text on them — and
/// two names stacked in the same spot are less use than one. Each is nudged
/// off the anchor by the smallest step that clears what is already written,
/// alternating up and down so the run keeps its label near its own line.
Offset _freeLabelSpot(Offset anchor, String text, List<Rect> taken) {
  const step = 15.0;
  for (int i = 0; i < 12; i++) {
    // 0, -15, +15, -30, +30 ...
    final dy = i == 0 ? 0.0 : ((i + 1) ~/ 2) * step * (i.isOdd ? -1 : 1);
    final at = anchor + Offset(0, dy);
    final rect = _labelRect(at, text);
    if (!taken.any(rect.overlaps)) return at;
  }
  return anchor;
}

class _CablePainter extends CustomPainter {
  final List<AvCable> cables;
  final Map<String, List<Offset>> paths;
  final String? selectedId;
  final Brightness brightness;

  /// The room's signal palette, so recoloring a type moves every run of it.
  final Map<SignalType, Color> palette;

  const _CablePainter({
    required this.cables,
    required this.paths,
    required this.selectedId,
    required this.brightness,
    required this.palette,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final cable in cables) {
      final points = paths[cable.id];
      if (points == null || points.length < 2) continue;

      final selected = cable.id == selectedId;
      final color = cable.colorFor(palette);
      final paint = Paint()
        ..color = color
        ..strokeWidth = selected ? 4.0 : 2.4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      if (selected) {
        // Halo so the selected run reads through a crowded corridor.
        canvas.drawPath(
          _polyline(points),
          Paint()
            ..color = color.withValues(alpha: 0.25)
            ..strokeWidth = 10
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round,
        );
      }
      canvas.drawPath(_polyline(points), paint);

      _drawArrowHead(canvas, points[points.length - 2], points.last, color);
      // The label is a WIDGET, not paint — see [_buildCableLabels]. It has to
      // be draggable, and a hit target you can pick up is a widget's job.
    }
  }

  /// Shallow map compare — a repaint has to happen when a signal's color
  /// changes, and Map has no useful == of its own.
  static bool _sameMap(Map<SignalType, Color> a, Map<SignalType, Color> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  /// The route as a path with its corners rounded off, so a cable reads as
  /// sweeping around an obstacle rather than hitting a hard right angle.
  /// The radius shrinks on short legs so a tight detour still draws cleanly.
  ///
  /// Shared with [_SignalFlowPainter]: the chevrons have to travel along the
  /// line that was actually drawn, corners and all, and a second copy of this
  /// would drift off it at the first turn.
  static Path polyline(List<Offset> points) => _polyline(points);

  static Path _polyline(List<Offset> points) {
    final p = Path()..moveTo(points.first.dx, points.first.dy);
    if (points.length < 3) {
      for (int i = 1; i < points.length; i++) {
        p.lineTo(points[i].dx, points[i].dy);
      }
      return p;
    }

    const maxRadius = 10.0;
    for (int i = 1; i < points.length - 1; i++) {
      final prev = points[i - 1], corner = points[i], next = points[i + 1];
      final inLen = (corner - prev).distance;
      final outLen = (next - corner).distance;
      // Never eat more than half of either leg, or neighboring corners
      // would overlap and the line would visibly cut the turn.
      final r = math.min(maxRadius, math.min(inLen, outLen) / 2);
      if (r < 0.5) {
        p.lineTo(corner.dx, corner.dy);
        continue;
      }
      final start = corner + (prev - corner) / inLen * r;
      final end = corner + (next - corner) / outLen * r;
      p.lineTo(start.dx, start.dy);
      p.quadraticBezierTo(corner.dx, corner.dy, end.dx, end.dy);
    }
    p.lineTo(points.last.dx, points.last.dy);
    return p;
  }

  /// Arrow at the destination end, so direction of signal is readable.
  void _drawArrowHead(Canvas canvas, Offset from, Offset to, Color color) {
    final direction = to - from;
    if (direction.distance < 0.5) return;
    final unit = direction / direction.distance;
    final normal = Offset(-unit.dy, unit.dx);
    const length = 9.0, half = 4.0;
    final base = to - unit * length;

    final path = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(base.dx + normal.dx * half, base.dy + normal.dy * half)
      ..lineTo(base.dx - normal.dx * half, base.dy - normal.dy * half)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _CablePainter old) =>
      old.cables != cables ||
      old.paths != paths ||
      old.selectedId != selectedId ||
      old.brightness != brightness ||
      !_sameMap(old.palette, palette);
}

// ---------------------------------------------------------------------------
//  WHICH WAY THE SIGNAL GOES
// ---------------------------------------------------------------------------

/// The chevrons traveling along the selected run.
///
/// WHY IT MOVES. A selected cable was already drawn thicker and haloed, which
/// says "this one" and nothing else. On a crowded canvas the question that
/// actually follows a click is the other one - which END is this feeding? -
/// and the static arrowhead at the destination answers it only if you can
/// find the destination, which on a run that turns four corners behind three
/// boxes is exactly what is hard. Movement answers it without being read:
/// nothing else on the diagram moves, so the eye lands on the selected run
/// and travels with it to the end it is going to.
///
/// IT IS NOT IN THE EXPORT. The chevrons are a selection affordance, they have
/// no still frame that means anything, and their phase at the instant of a
/// capture is arbitrary - a picture of one is a picture of some marks partway
/// along a line. The drawing already carries direction in the arrowhead, which
/// is what a printed sheet needs. [capturingDiagram] is the same flag the grid
/// stands down for, and it is set a frame before the photograph is taken.
class _SelectedSignalFlow extends StatelessWidget {
  /// 0 to 1, repeating: one chevron's travel from its position to the next.
  final Animation<double> progress;

  /// The selected run's route, or null when nothing is selected.
  final List<Offset>? points;

  final Color color;

  const _SelectedSignalFlow({
    required this.progress,
    required this.points,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final route = points;
    if (route == null || route.length < 2) return const SizedBox.shrink();

    return ValueListenableBuilder<bool>(
      valueListenable: capturingDiagram,
      builder: (context, capturing, _) => capturing
          ? const SizedBox.shrink()
          : AnimatedBuilder(
              animation: progress,
              builder: (context, _) => CustomPaint(
                size: Size.infinite,
                painter: _SignalFlowPainter(
                  points: route,
                  color: color,
                  phase: progress.value,
                ),
              ),
            ),
    );
  }
}

/// Paints the traveling chevrons. See [_SelectedSignalFlow] for why.
class _SignalFlowPainter extends CustomPainter {
  final List<Offset> points;
  final Color color;

  /// 0 to 1. One whole step of the pattern, so the chevrons hand over to each
  /// other and the run reads as continuous flow rather than as a burst that
  /// restarts.
  final double phase;

  const _SignalFlowPainter({
    required this.points,
    required this.color,
    required this.phase,
  });

  /// How far apart the chevrons sit along the run.
  ///
  /// Far enough apart to read as separate marks traveling rather than as a
  /// crawling dashed line, and close enough that a short run between two
  /// adjacent boxes still gets two of them.
  static const double _spacing = 30;

  /// Half the width of a chevron's V, and how far its point leads its tails.
  static const double _half = 5;
  static const double _lead = 6;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) return;
    final path = _CablePainter.polyline(points);
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return;

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (final metric in metrics) {
      final length = metric.length;
      if (length < _lead * 2) continue;

      // Starts BEHIND the beginning and runs PAST the end, so a chevron fades
      // in off the source rather than appearing out of nothing in the middle
      // of the line.
      for (var at = phase * _spacing; at < length; at += _spacing) {
        final tangent = metric.getTangentForOffset(at);
        if (tangent == null) continue;

        // Faded at both ends. A chevron sitting on top of the connector it
        // starts from, or on the arrowhead it is traveling into, reads as a
        // smudge on the drawing.
        final fade = math.min(at, length - at) / _spacing;
        final alpha = fade.clamp(0.0, 1.0);
        if (alpha <= 0.02) continue;

        final unit = tangent.vector;
        final normal = Offset(-unit.dy, unit.dx);
        final tip = tangent.position + unit * _lead;
        final back = tangent.position - unit * (_lead * 0.4);

        canvas.drawPath(
          Path()
            ..moveTo(back.dx + normal.dx * _half, back.dy + normal.dy * _half)
            ..lineTo(tip.dx, tip.dy)
            ..lineTo(back.dx - normal.dx * _half, back.dy - normal.dy * _half),
          stroke..color = color.withValues(alpha: alpha),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SignalFlowPainter old) =>
      old.phase != phase ||
      old.color != color ||
      !identical(old.points, points);
}

// ---------------------------------------------------------------------------
//  LEGEND
// ---------------------------------------------------------------------------

/// How tall [_AvLegend] will be, so the canvas can reserve room underneath
/// the diagram for it. An estimate rather than a measurement — over-shooting
/// leaves a little blank canvas, which is harmless; the widget itself still
/// lays out naturally.
double avLegendHeight(
  int signalCount,
  bool hasCustomColors, {
  /// The "AV cabling" style sub-headings the key groups its rows under.
  int groupHeaders = 0,
}) {
  const padding = 16.0; // 8 top + 8 bottom
  const title = 18.0;
  const rowHeight = 16.0;
  const customNote = 18.0;
  return padding +
      title +
      4 +
      (signalCount + groupHeaders) * rowHeight +
      (hasCustomColors ? customNote : 0);
}

/// How many family sub-headings [_AvLegend] will print for [signals].
int avLegendGroupCount(List<SignalType> signals) => {
  for (final s in signals)
    if (cableFamilyFor(s) != CableFamily.other) cableFamilyFor(s),
}.length;

/// Lists only the signal types actually on the canvas, so it stays short.
class _AvLegend extends StatelessWidget {
  final List<SignalType> signals;

  /// The room's palette, so the key matches the lines it describes.
  final Map<SignalType, Color> palette;

  /// At least one run was recolored by hand, so the key above it doesn't
  /// account for every line on the page.
  final bool hasCustomColors;

  final ThemeData theme;

  const _AvLegend({
    required this.signals,
    required this.hasCustomColors,
    required this.palette,
    required this.theme,
  });

  /// [signals] in the order they are drawn, split so the ones that share a
  /// cable family sit together under one heading. Everything else keeps its
  /// enum order and gets no heading, because "HDMI" is already its own name.
  List<({String header, List<SignalType> signals})> _grouped(
    List<SignalType> signals,
  ) {
    final out = <({String header, List<SignalType> signals})>[];
    for (final family in CableFamily.values) {
      final here = signals.where((s) => cableFamilyFor(s) == family).toList();
      if (here.isEmpty) continue;
      if (family == CableFamily.other) {
        out.add((header: '', signals: here));
      } else {
        out.add((header: kCableFamilyLabels[family]!, signals: here));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: (dark ? Colors.black : Colors.white).withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Signal types',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          // "AV cabling" as a sub-heading with the signals it covers indented
          // under it, so the key reads the way the cable schedule and the
          // cabling drawing name the same runs.
          for (final group in _grouped(signals)) ...[
            if (group.header.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 1),
                child: Text(
                  group.header,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: theme.hintColor,
                  ),
                ),
              ),
            for (final s in group.signals)
              Padding(
                padding: EdgeInsets.only(
                  top: 1.5,
                  bottom: 1.5,
                  left: group.header.isEmpty ? 0 : 10,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 22,
                      height: 3.5,
                      color: signalColor(s, palette),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      kSignalLabels[s] ?? s.name,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
          ],
          if (hasCustomColors)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Some runs are colored individually',
                style: TextStyle(
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                  color: theme.hintColor,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
