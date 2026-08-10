import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;

import 'app_state.dart';
import 'av_device_library.dart';
import 'av_flow_model.dart';
import 'av_flow_report.dart';
import 'av_rack_view.dart';
import 'color_wheel_picker.dart';
import 'dynamic_devices_view.dart' show getActiveDeviceKeys;
import 'layout_tools.dart';
import 'report_tools.dart';
import 'screenshot_tools.dart';
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
///  ports are joined. The Racks toggle swaps the canvas for front/rear rack
///  elevations. Exports: the diagram as a PNG, and a cable schedule + pack
///  list as .xlsx / .txt / clipboard.
///
///  Persists to `<config>_av_flow.json` beside the working config — see the
///  AV FLOW TAB STATE block in app_state.dart.
/// ============================================================================

/// Which page of the tab is showing.
enum AvPage { flow, racks }

// ---------------------------------------------------------------------------
//  MODEL BUILDING
// ---------------------------------------------------------------------------

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
    if (provider.avDismissedDevices.contains(key)) continue;
    final dev = config[key];
    if (dev is! Map) continue;
    unplaced.add(
      AvUnplacedDevice(
        key: key,
        label: dev['name']?.toString() ?? key,
        model: dev['model']?.toString() ?? '',
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
    canvasSize: Size(maxX, maxY),
    roomTitle:
        (setup is Map ? setup['gui_full_room_name']?.toString() : '') ?? '',
    unplaced: unplaced,
  );
}

/// Signal-flow reading order, left to right: sources feed the switcher, the
/// switcher feeds processing, processing feeds the displays. Power and
/// anything unrecognized go in the source column so they don't split a row.
int _columnForDevice(String key) {
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

class _AvFlowViewState extends State<AvFlowView> {
  final GlobalKey _diagramKey = GlobalKey();
  final TransformationController _transform = TransformationController();

  AvPage _page = AvPage.flow;
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<AppStateProvider>();
      provider.ensureAvFlowForCurrentConfig();
      // First visit to a room with nothing drawn yet: put its real equipment
      // on the canvas so there is something to cable.
      if (provider.avNodes.isEmpty && provider.roomConfig.isNotEmpty) {
        _seedFromConfig(provider, silent: true);
      }
    });
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: error ? Colors.red : null),
    );
  }

  /// "Saved" snackbar offering to open the file or its folder. Mirrors the
  /// Schematic tab's, including the 10s hold — a file dialog has just closed.
  void _savedSnack(AppStateProvider provider, String label, String filePath) {
    if (!mounted) return;

    Future<void> run(Future<String?> Function() action) async {
      final error = await action();
      if (error != null) _snack(error, error: true);
    }

    final Color actionColor =
        Theme.of(context).snackBarTheme.actionTextColor ??
        Theme.of(context).colorScheme.onInverseSurface;
    final ButtonStyle actionStyle = TextButton.styleFrom(
      foregroundColor: actionColor,
      textStyle: const TextStyle(fontWeight: FontWeight.bold),
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 10),
        content: Row(
          children: [
            Expanded(
              child: Text(
                '$label saved as ${path.basename(filePath)}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              style: actionStyle,
              onPressed: () => run(() => provider.openInDesktop(filePath)),
              child: const Text('OPEN FILE'),
            ),
            TextButton(
              style: actionStyle,
              onPressed: () =>
                  run(() => provider.revealInFileManager(filePath)),
              child: const Text('OPEN FOLDER'),
            ),
          ],
        ),
      ),
    );
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
  /// Devices the user removed stay removed — they are in avDismissedDevices.
  void _seedFromConfig(AppStateProvider provider, {bool silent = false}) {
    final config = provider.roomConfig;
    if (config.isEmpty) return;
    final keys = getActiveDeviceKeys(config, provider.uiSchema.deviceCountMap);
    final existing = {for (final n in provider.avNodes) n.id};

    // Running y per column, starting below whatever is already placed there.
    final columnY = <int, double>{};
    for (final n in provider.avNodes) {
      final col = (n.pos.dx / 340).round();
      columnY[col] = math.max(columnY[col] ?? 60, n.pos.dy + n.height + 30);
    }

    int added = 0;
    for (final key in keys) {
      if (existing.contains(key)) continue;
      if (provider.avDismissedDevices.contains(key)) continue;
      final dev = config[key];
      if (dev is! Map) continue;

      final model = dev['model']?.toString() ?? '';
      final template = provider.avDeviceLibrary.resolve(
        configKey: key,
        model: model,
      );
      final col = _columnForDevice(key);
      final y = columnY[col] ?? 60;

      final node = AvNode(
        id: key,
        label: dev['name']?.toString() ?? key,
        model: model,
        pos: Offset(40 + col * 340.0, y),
        ports: template.ports,
        fromConfig: true,
        rackUnits: template.rackUnits,
      );
      provider.addAvNode(node);
      columnY[col] = y + node.height + 30;
      added++;
    }

    if (!silent) {
      _snack(
        added == 0
            ? 'Every config device is already on the canvas.'
            : 'Added $added device${added == 1 ? '' : 's'} from the config.',
      );
    }
  }

  /// Re-runs the column layout over everything currently placed, so a diagram
  /// that has been dragged into a mess can be put back in reading order.
  void _autoArrange(AppStateProvider provider) {
    final columnY = <int, double>{};
    for (final node in List<AvNode>.from(provider.avNodes)) {
      final col = node.fromConfig ? _columnForDevice(node.id) : 0;
      final y = columnY[col] ?? 60;
      provider.updateAvNode(node.copyWith(pos: Offset(40 + col * 340.0, y)));
      columnY[col] = y + node.height + 30;
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
        'Can\'t connect ${fromPort.label} to ${port.label} — a cable runs '
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
    final suffix = _page == AvPage.racks ? 'racks' : 'av_flow';
    String? outputFile = await FilePicker.saveFile(
      dialogTitle: _page == AvPage.racks
          ? 'Save Rack Elevation Image'
          : 'Save AV Flow Image',
      fileName: '${_fileStem(provider, suffix)}.png',
      type: FileType.custom,
      allowedExtensions: ['png'],
    );
    if (outputFile == null) return;
    if (!outputFile.toLowerCase().endsWith('.png')) outputFile += '.png';
    try {
      await File(outputFile).writeAsBytes(bytes);
      _savedSnack(provider, 'Diagram image', outputFile);
    } catch (e) {
      _snack('Failed to save image: $e', error: true);
    }
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

  Future<void> _saveDiagram(AppStateProvider provider) async {
    // A wizard-built session has no file for the sidecar to sit beside yet.
    if (provider.avFlowSidecarPath.isEmpty) {
      _snack(
        'No working config file yet — choose where to save the config, '
        'then the AV flow is saved beside it.',
      );
      final bool exported = await provider.exportRoomConfig();
      if (!exported) {
        _snack(
          'AV flow not saved — the config save was cancelled.',
          error: true,
        );
        return;
      }
    }
    final saved = await provider.saveAvFlow();
    _snack(
      saved.isEmpty ? 'Failed to save the AV flow.' : 'AV flow saved to $saved',
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
    final model = _withDragPreview(buildAvFlowModel(provider));
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildToolbar(provider, model),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: _page == AvPage.racks
                    ? AvRackView(captureKey: _diagramKey, editMode: _editMode)
                    : InteractiveViewer(
                        transformationController: _transform,
                        constrained: false,
                        minScale: 0.25,
                        maxScale: 3.0,
                        boundaryMargin: const EdgeInsets.all(400),
                        child: RepaintBoundary(
                          key: _diagramKey,
                          child: _buildCanvas(provider, model, theme),
                        ),
                      ),
              ),
              if (_showPalette) ...[
                const VerticalDivider(width: 1, thickness: 1),
                _buildPalette(provider, model),
              ],
            ],
          ),
        ),
        if (_editMode && _page == AvPage.flow)
          _buildCablePanel(provider, model),
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
          SegmentedButton<AvPage>(
            segments: const [
              ButtonSegment(
                value: AvPage.flow,
                icon: Icon(Icons.cable, size: 18),
                label: Text('Signal Flow'),
              ),
              ButtonSegment(
                value: AvPage.racks,
                icon: Icon(Icons.view_day, size: 18),
                label: Text('Racks'),
              ),
            ],
            selected: {_page},
            onSelectionChanged: (s) => setState(() {
              _page = s.first;
              _pendingPort = null;
              _selectedCableId = null;
            }),
          ),
          FilterChip(
            avatar: Icon(
              _editMode ? Icons.edit : Icons.edit_outlined,
              size: 18,
            ),
            label: const Text('Edit'),
            selected: _editMode,
            onSelected: (v) => setState(() {
              _editMode = v;
              _cableMode = false;
              _pendingPort = null;
              _selectedCableId = null;
            }),
          ),
          if (_editMode && _page == AvPage.flow)
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
          if (_editMode && _page == AvPage.flow)
            OutlinedButton.icon(
              icon: const Icon(Icons.auto_fix_high, size: 18),
              label: const Text('Auto-arrange'),
              onPressed: () => _autoArrange(provider),
            ),
          OutlinedButton.icon(
            icon: const Icon(Icons.palette_outlined, size: 18),
            label: const Text('Colors'),
            onPressed: () => _showPaletteDialog(provider),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.save, size: 18),
            label: const Text('Save AV Flow'),
            onPressed: () => _saveDiagram(provider),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.image, size: 18),
            label: const Text('Export PNG'),
            onPressed: () => _exportPng(provider),
          ),
          PopupMenuButton<String>(
            tooltip: 'Export cable schedule & pack list',
            onSelected: (v) => v == 'copy'
                ? _copyReportText(provider)
                : _exportReport(provider, v == 'xlsx'),
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'xlsx', child: Text('Excel report (.xlsx)')),
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
  AvFlowModel _withDragPreview(AvFlowModel model) {
    final id = _dragNodeId;
    if (id == null || _dragOffset == Offset.zero) return model;

    final nodes = [
      for (final n in model.nodes)
        n.id == id ? n.copyWith(pos: _clamped(n.pos + _dragOffset)) : n,
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
      canvasSize: Size(maxX, maxY),
      roomTitle: model.roomTitle,
      unplaced: model.unplaced,
    );
  }

  /// The canvas only grows right and down, so a device can't be pushed past
  /// the origin where it would be clipped.
  static Offset _clamped(Offset p) =>
      Offset(math.max(0, p.dx), math.max(0, p.dy));

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
        desired: _clamped(node.pos + offset),
        size: node.size,
        others: [
          for (final other in provider.avNodes)
            if (other.id != id) other.rect,
        ],
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
    _paths = {
      for (final c in model.cables)
        c.id: routeCable(
          fromNode: byId[c.fromNodeId]!,
          toNode: byId[c.toNodeId]!,
          cable: c,
          lane: lanes[c.id] ?? 0,
          obstacles: [
            for (final e in boxes.entries)
              if (e.key != c.fromNodeId && e.key != c.toNodeId) e.value,
            endpointBoxes[c.fromNodeId]!,
            endpointBoxes[c.toNodeId]!,
          ],
        ),
    };

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
          // Tap-to-select-a-cable sits under the nodes but over the paint, so
          // a click on empty canvas clears the selection.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) {
                final hit = _cableAt(details.localPosition);
                setState(() => _selectedCableId = hit);
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
          // Room title (part of the PNG export).
          Positioned(
            left: 24,
            top: 16,
            child: Text(
              model.roomTitle.isEmpty ? 'AV Signal Flow' : model.roomTitle,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
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
              provider.updateAvCable(cable.copyWith(waypoints: next));
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

  Widget _buildPalette(AppStateProvider provider, AvFlowModel model) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text('Devices', style: theme.textTheme.titleSmall),
          ),
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
                      leading: Icon(iconForAvNode(d.key, d.model), size: 20),
                      title: Text(
                        d.label,
                        style: const TextStyle(fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        d.model.isEmpty ? d.key : d.model,
                        style: const TextStyle(fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.add, size: 18),
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
      ),
    );
  }

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
        ports: template.ports,
        fromConfig: true,
        rackUnits: template.rackUnits,
      ),
    );
  }

  Future<void> _showAddCustomDeviceDialog(AppStateProvider provider) async {
    final labelController = TextEditingController();
    String? selectedModel;
    final models = provider.avDeviceLibrary.knownModels;

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Add device'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: labelController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Name on the diagram',
                    hintText: 'e.g. Lectern wall plate',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedModel,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Model (supplies the connectors)',
                  ),
                  items: [
                    for (final m in models)
                      DropdownMenuItem(value: m, child: Text(m)),
                  ],
                  onChanged: (v) => setLocal(() => selectedModel = v),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Pick the closest model — the ports it brings can be edited '
                  'on the device afterwards.',
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
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (created != true) return;
    final model = selectedModel ?? '';
    final template = provider.avDeviceLibrary.templateForModel(model);
    final label = labelController.text.trim();
    provider.addAvNode(
      AvNode(
        id: '', // provider assigns AVNODE_<n>
        label: label.isEmpty ? (model.isEmpty ? 'Device' : model) : label,
        model: model,
        pos: const Offset(40, 60),
        ports:
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
        rackUnits: template?.rackUnits ?? 0,
      ),
    );
  }

  /// Adds a wall box, floor box or patch panel: a box whose "ports" are
  /// numbered jacks. Cabling a device to a jack is what lets the Jack
  /// Schedule say which device is on jack 4 of the lectern plate — the sheet
  /// you actually want when tracing a run back to the IDF.
  Future<void> _showAddJackFieldDialog(AppStateProvider provider) async {
    final labelController = TextEditingController(text: 'Wall box');
    final countController = TextEditingController(text: '6');
    final prefixController = TextEditingController(text: 'J');
    final startController = TextEditingController(text: '1');
    SignalType signal = SignalType.network;

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Add wall box / patch panel'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 96,
                      child: TextField(
                        controller: prefixController,
                        decoration: const InputDecoration(labelText: 'Prefix'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: startController,
                        decoration: const InputDecoration(
                          labelText: 'First number',
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
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (created != true) return;

    final count = (int.tryParse(countController.text.trim()) ?? 0).clamp(1, 96);
    final first = int.tryParse(startController.text.trim()) ?? 1;
    final prefix = prefixController.text.trim();
    final label = labelController.text.trim();

    provider.addAvNode(
      AvNode(
        id: '',
        label: label.isEmpty ? 'Wall box' : label,
        model: '$count-jack ${kSignalLabels[signal] ?? signal.name} field',
        pos: const Offset(40, 60),
        kind: AvNodeKind.jackField,
        powerSource: PowerSource.none,
        ports: [
          for (int i = 0; i < count; i++)
            AvPort(
              id: 'jack_${first + i}',
              label: '$prefix${first + i}',
              signal: signal,
              direction: PortDirection.bidirectional,
              // Jacks alternate sides so a 12-way panel stays compact
              // instead of running off the bottom of the page.
              side: i.isEven ? PortSide.left : PortSide.right,
            ),
        ],
      ),
    );
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

  Future<void> _showNodeDialog(AppStateProvider provider, AvNode node) async {
    final labelController = TextEditingController(text: node.label);
    final modelController = TextEditingController(text: node.model);
    final noteController = TextEditingController(text: node.note);
    // Persistent, like the others: a controller rebuilt inside the dialog's
    // builder resets its text and cursor on every keystroke.
    final rackUnitsController = TextEditingController(
      text: node.rackUnits.toString(),
    );
    final ports = List<AvPort>.from(node.ports);
    PowerSource powerSource = node.powerSource;

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Edit ${node.label}'),
          content: SizedBox(
            // Wide enough for a whole port row, but never wider than the
            // window — the port rows shrink to fit whatever is left.
            width: math.min(820, MediaQuery.of(ctx).size.width - 120),
            height: math.min(560, MediaQuery.of(ctx).size.height - 200),
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
                        decoration: const InputDecoration(labelText: 'Model'),
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
                const SizedBox(height: 12),
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
                            ..addAll(template.ports);
                        });
                      },
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add port'),
                      onPressed: () => setLocal(
                        () => ports.add(
                          AvPort(
                            id: 'port_${DateTime.now().microsecondsSinceEpoch}',
                            label: 'NEW ${ports.length + 1}',
                            signal: SignalType.hdmi,
                            direction: PortDirection.input,
                            side: PortSide.left,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const Divider(),
                Expanded(
                  child: ports.isEmpty
                      ? const Center(child: Text('No connectors defined.'))
                      : ListView.builder(
                          itemCount: ports.length,
                          itemBuilder: (ctx, i) => _portEditorRow(
                            ports[i],
                            onChanged: (p) => setLocal(() => ports[i] = p),
                            onDelete: () => setLocal(() => ports.removeAt(i)),
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
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('delete'),
              child: const Text(
                'Remove device',
                style: TextStyle(color: Colors.red),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('copy'),
              child: const Text('Copy as av_devices.json'),
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

    final updated = node.copyWith(
      label: labelController.text.trim().isEmpty
          ? node.label
          : labelController.text.trim(),
      model: modelController.text.trim(),
      note: noteController.text.trim(),
      rackUnits: int.tryParse(rackUnitsController.text.trim()) ?? 0,
      powerSource: powerSource,
      ports: ports,
    );

    if (result == 'copy') {
      final entry = AvDeviceTemplate(
        model: updated.model.isEmpty ? updated.label : updated.model,
        rackUnits: updated.rackUnits,
        ports: updated.ports,
      );
      await Clipboard.setData(
        ClipboardData(
          text: const JsonEncoder.withIndent('  ').convert(entry.toJson()),
        ),
      );
      _snack(
        'Library entry copied — paste it into the "devices" array of '
        'av_devices.json.',
      );
    }

    // Cables referencing a port that was deleted or re-id'd disappear on the
    // next build (cableIsResolvable), so warn rather than silently dropping.
    final removedIds = node.ports
        .map((p) => p.id)
        .where((id) => !ports.any((p) => p.id == id))
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
          '${orphaned.length} cable${orphaned.length == 1 ? '' : 's'} '
          'removed with the deleted connectors.',
        );
      }
    }

    provider.updateAvNode(updated);
  }

  /// The room's signal palette. Read on demand rather than cached: it can
  /// change from the Colors dialog while a port editor is open.
  Map<SignalType, Color> get palette =>
      context.read<AppStateProvider>().avSignalColors;

  /// Tight icon button for the port rows — the stock 48px ones plus the
  /// fields no longer fit across the dialog.
  Widget _rowIcon(
    IconData icon,
    String tooltip,
    VoidCallback? onPressed, {
    bool danger = false,
  }) {
    return IconButton(
      icon: Icon(icon, size: 18),
      color: danger ? Colors.red.shade400 : null,
      onPressed: onPressed,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
    );
  }

  Widget _portEditorRow(
    AvPort port, {
    required ValueChanged<AvPort> onChanged,
    required VoidCallback onDelete,
    VoidCallback? onMoveUp,
    VoidCallback? onMoveDown,
  }) {
    return Padding(
      // Keyed on the port so reordering moves each row's field state with it
      // rather than leaving the values behind at the old index.
      key: ValueKey(port.id),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: signalColor(port.signal, palette),
              shape: BoxShape.circle,
            ),
          ),
          // Flexible, not fixed: the fixed widths used to add up to more than
          // the dialog, which pushed the delete button off the right edge
          // where it could not be seen OR clicked.
          Expanded(
            child: _PortLabelField(
              portId: port.id,
              initialLabel: port.label,
              onChanged: (v) => onChanged(port.copyWith(label: v)),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 150,
            child: DropdownButtonFormField<SignalType>(
              initialValue: port.signal,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                for (final s in SignalType.values)
                  DropdownMenuItem(
                    value: s,
                    child: Text(
                      kSignalLabels[s] ?? s.name,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
              onChanged: (v) =>
                  v == null ? null : onChanged(port.copyWith(signal: v)),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 104,
            child: DropdownButtonFormField<PortDirection>(
              initialValue: port.direction,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: PortDirection.input,
                  child: Text('Input', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: PortDirection.output,
                  child: Text('Output', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: PortDirection.bidirectional,
                  child: Text('Both', style: TextStyle(fontSize: 12)),
                ),
              ],
              onChanged: (v) => v == null
                  ? null
                  : onChanged(
                      port.copyWith(
                        direction: v,
                        // Keep the box readable: an output that stays on the
                        // left reads as an input at a glance.
                        side: v == PortDirection.output
                            ? PortSide.right
                            : (port.side == PortSide.right
                                  ? PortSide.left
                                  : port.side),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: DropdownButtonFormField<PortSide>(
              initialValue: port.side,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: PortSide.left,
                  child: Text('Left', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: PortSide.right,
                  child: Text('Right', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: PortSide.top,
                  child: Text('Top', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: PortSide.bottom,
                  child: Text('Bottom', style: TextStyle(fontSize: 12)),
                ),
              ],
              onChanged: (v) =>
                  v == null ? null : onChanged(port.copyWith(side: v)),
            ),
          ),
          _rowIcon(Icons.arrow_upward, 'Move up', onMoveUp),
          _rowIcon(Icons.arrow_downward, 'Move down', onMoveDown),
          _rowIcon(Icons.delete_outline, 'Delete port', onDelete, danger: true),
        ],
      ),
    );
  }

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
      constraints: const BoxConstraints(maxHeight: 200),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: ListView(
        shrinkWrap: true, // one line of help shouldn't hold open 200px
        children: [
          Text(
            _pendingPort != null
                ? 'Now click the connector at the other end of the cable '
                      '(click the same one again to cancel).'
                : _cableMode
                ? 'Click a connector, then the connector at the other end, '
                      'to draw a cable. Turn off "Draw Cable" to move '
                      'devices again.'
                : 'Drag a device to move it. Click its header pencil to '
                      'rename it or edit its connectors. Turn on "Draw '
                      'Cable" to wire connectors together. Click a cable to '
                      'add bends.',
            style: theme.textTheme.bodySmall,
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

  Future<void> _showCableDialog(
    AppStateProvider provider,
    AvCable cable,
  ) async {
    final labelController = TextEditingController(text: cable.label);
    SignalType signal = cable.signal;
    Color? colorOverride = cable.colorOverride;

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
                DropdownButtonFormField<SignalType>(
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
                TextField(
                  controller: labelController,
                  decoration: const InputDecoration(
                    labelText: 'Label / cable ID',
                    hintText: 'e.g. HDMI-04, 50ft',
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
    provider.updateAvCable(
      cable.copyWith(
        signal: signal,
        label: labelController.text.trim(),
        waypoints: result == 'straighten' ? const [] : cable.waypoints,
        colorOverride: colorOverride,
        clearColorOverride: colorOverride == null,
      ),
    );
  }

}

/// The port editor's name field. It owns its controller so typing doesn't
/// rebuild the text out from under the cursor — the row above it rebuilds on
/// every keystroke to keep the live port list in sync.
class _PortLabelField extends StatefulWidget {
  final String portId;
  final String initialLabel;
  final ValueChanged<String> onChanged;

  const _PortLabelField({
    required this.portId,
    required this.initialLabel,
    required this.onChanged,
  });

  @override
  State<_PortLabelField> createState() => _PortLabelFieldState();
}

class _PortLabelFieldState extends State<_PortLabelField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialLabel,
  );

  @override
  void didUpdateWidget(covariant _PortLabelField old) {
    super.didUpdateWidget(old);
    // Only when this row now represents a DIFFERENT port (Reset from library
    // replaces the whole list) — never on the user's own keystrokes.
    if (old.portId != widget.portId) {
      _controller.text = widget.initialLabel;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    decoration: const InputDecoration(
      isDense: true,
      border: OutlineInputBorder(),
    ),
    onChanged: widget.onChanged,
  );
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
      if (cable.label.isNotEmpty) {
        _drawLabel(canvas, points, cable.label, color);
      }
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
      // Never eat more than half of either leg, or neighbouring corners
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

  void _drawLabel(
    Canvas canvas,
    List<Offset> points,
    String label,
    Color color,
  ) {
    // Midpoint of the longest segment: the most room for text.
    var bestIndex = 0;
    var bestLength = 0.0;
    for (int i = 0; i < points.length - 1; i++) {
      final length = (points[i + 1] - points[i]).distance;
      if (length > bestLength) {
        bestLength = length;
        bestIndex = i;
      }
    }
    if (bestLength < 30) return;
    final mid = (points[bestIndex] + points[bestIndex + 1]) / 2;

    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final rect = Rect.fromCenter(
      center: mid,
      width: painter.width + 8,
      height: painter.height + 3,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()
        ..color = brightness == Brightness.dark
            ? const Color(0xFF15181C)
            : const Color(0xFFFAFAFA),
    );
    painter.paint(canvas, rect.topLeft + const Offset(4, 1.5));
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
//  LEGEND
// ---------------------------------------------------------------------------

/// How tall [_AvLegend] will be, so the canvas can reserve room underneath
/// the diagram for it. An estimate rather than a measurement — over-shooting
/// leaves a little blank canvas, which is harmless; the widget itself still
/// lays out naturally.
double avLegendHeight(int signalCount, bool hasCustomColors) {
  const padding = 16.0; // 8 top + 8 bottom
  const title = 18.0;
  const rowHeight = 16.0;
  const customNote = 18.0;
  return padding +
      title +
      4 +
      signalCount * rowHeight +
      (hasCustomColors ? customNote : 0);
}

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
          for (final s in signals)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1.5),
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
