import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';

import 'app_state.dart';
import 'screenshot_tools.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  ROOM SCHEMATIC TAB
/// ============================================================================
///  Auto-draws the room's control topology from the loaded config:
///    * every active device block (same dev_ count logic as the Devices tab)
///      becomes a node with a device-type icon
///    * Network devices (com_type "Network") connect to a Network IDF node,
///      which uplinks to the processor
///    * Serial devices draw a direct line to the processor labeled with
///      their COM port; relay-controlled screens draw a relay line labeled
///      with their relay ports
///    * the touch panel (SYSTEM_SETUP gve_id_tlp_1) is drawn as a window
///      icon with one tab per gui_tab page (e.g. "4_Cams_Mic_Dev" = 4 tabs)
///  Each connection type has its own color (legend bottom-left, included in
///  the PNG export). Edit mode allows dragging nodes and drawing extra lines
///  in any color between any two nodes; the layout persists to a
///  `<config>_schematic.json` sidecar via Save Layout.
///  Exports: the diagram as a PNG, and a device report as .xlsx or .txt.
/// ============================================================================

/// The built-in connection categories and their line colors (the legend).
enum ConnType { network, serial, relay, touchpanel, trunk }

const Map<ConnType, Color> kConnColors = {
  ConnType.network: Color(0xFF42A5F5), // blue
  ConnType.serial: Color(0xFFFFA726), // orange
  ConnType.relay: Color(0xFFAB47BC), // purple
  ConnType.touchpanel: Color(0xFF26A69A), // teal
  ConnType.trunk: Color(0xFF66BB6A), // green
};

const Map<ConnType, String> kConnLabels = {
  ConnType.network: 'Network (via IDF)',
  ConnType.serial: 'Serial (COM)',
  ConnType.relay: 'Relay',
  ConnType.touchpanel: 'Touch Panel',
  ConnType.trunk: 'IDF Uplink',
};

/// Swatches offered when drawing a custom line.
const List<Color> kLinkSwatches = [
  Color(0xFF42A5F5), Color(0xFFFFA726), Color(0xFFAB47BC), Color(0xFF26A69A),
  Color(0xFF66BB6A), Color(0xFFEF5350), Color(0xFFFFEE58), Color(0xFF8D6E63),
  Color(0xFF78909C), Color(0xFFEC407A), Color(0xFF7E57C2), Color(0xFF29B6F6),
];

const double kNodeWidth = 190;
const double kNodeHeight = 78;

/// One box on the diagram.
class SchematicNode {
  final String id; // device key, 'PROCESSOR', 'IDF', 'TOUCHPANEL'
  final String title;
  final String subtitle;
  final IconData icon;
  final ConnType conn; // colors the border/icon
  final int tabCount; // >0: draw the window-with-tabs touch panel icon
  final Offset pos; // top-left on the canvas

  const SchematicNode({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.conn,
    this.tabCount = 0,
    required this.pos,
  });

  Offset get center => pos + const Offset(kNodeWidth / 2, kNodeHeight / 2);
}

/// One line on the diagram.
class SchematicEdge {
  final String fromId;
  final String toId;
  final Color color;
  final String label;
  final bool custom; // user-drawn (deletable from the edit panel)
  final int customIndex; // index into provider.schematicLinks when custom
  final double width;

  const SchematicEdge({
    required this.fromId,
    required this.toId,
    required this.color,
    this.label = '',
    this.custom = false,
    this.customIndex = -1,
    this.width = 2.5,
  });
}

/// The fully resolved diagram: nodes (with positions), edges, canvas size.
class SchematicModel {
  final List<SchematicNode> nodes;
  final List<SchematicEdge> edges;
  final Size canvasSize;
  final String roomTitle;

  SchematicModel(this.nodes, this.edges, this.canvasSize, this.roomTitle);

  SchematicNode? nodeById(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// Builds the diagram from the loaded config, honoring dragged positions.
  static SchematicModel build(AppStateProvider provider) {
    final config = provider.roomConfig;
    final Map<String, dynamic> systemSetup =
        (config['SYSTEM_SETUP'] is Map) ? config['SYSTEM_SETUP'] : {};

    // --- Active device keys, same dev_ count logic as the Devices tab ---
    final List<String> deviceKeys = [];
    provider.uiSchema.deviceCountMap.forEach((countKey, prefix) {
      final countVal = systemSetup[countKey];
      if (countVal == null) return;
      final count = (countVal.toString().toLowerCase() == 'yes')
          ? 1
          : (int.tryParse(countVal.toString()) ?? 0);
      for (int i = 1; i <= count; i++) {
        if (config.containsKey('$prefix$i')) deviceKeys.add('$prefix$i');
      }
    });

    // --- Classify every device by how it talks to the processor ---
    final String screenControl =
        systemSetup['dev_screen_control']?.toString() ?? '';
    ConnType connOf(String key) {
      final dev = config[key];
      final comType = dev['com_type']?.toString().toLowerCase() ?? '';
      if (key.startsWith('SCREENDEVICE_') &&
          screenControl.toLowerCase() == 'relay') {
        return ConnType.relay;
      }
      if (comType == 'serial') return ConnType.serial;
      if (comType == 'relay') return ConnType.relay;
      return ConnType.network;
    }

    final networkKeys =
        deviceKeys.where((k) => connOf(k) == ConnType.network).toList();
    final directKeys =
        deviceKeys.where((k) => connOf(k) != ConnType.network).toList();

    // --- Touch panel node (window icon with one tab per gui_tab page) ---
    final String tlpId = systemSetup['gve_id_tlp_1']?.toString() ?? '';
    final bool hasTouchPanel =
        tlpId.isNotEmpty && tlpId.toUpperCase() != 'N/A';
    final String guiTab = systemSetup['gui_tab']?.toString() ?? '';
    final int tabCount =
        int.tryParse(guiTab.split('_').first)?.clamp(1, 8) ?? 1;

    final bool hasIdf = networkKeys.isNotEmpty || hasTouchPanel;

    // --- Auto layout: network column | IDF | processor | direct column ---
    const double colNetworkX = 30;
    const double colIdfX = 470;
    const double colProcessorX = 740;
    const double colDirectX = 1020;
    const double rowStart = 96;
    const double rowSpacing = 102;

    final int rows = math.max(networkKeys.length, directKeys.length);
    final double canvasH = math.max(
        560, rowStart + rows * rowSpacing + (hasTouchPanel ? 180 : 60));
    const double canvasW = colDirectX + kNodeWidth + 30;

    Offset autoPos(String id, Offset fallback) =>
        provider.schematicPositions[id] ?? fallback;

    final List<SchematicNode> nodes = [];
    final List<SchematicEdge> edges = [];

    // Processor: vertical center.
    final processorY = canvasH / 2 - kNodeHeight / 2;
    final String processorName =
        systemSetup['processor1']?.toString() ?? 'Processor';
    final String processorIp = provider.selectedProcessorIp;
    nodes.add(SchematicNode(
      id: 'PROCESSOR',
      title: 'Processor',
      subtitle: processorIp.isEmpty
          ? processorName
          : '$processorName • $processorIp',
      icon: Icons.memory,
      conn: ConnType.trunk,
      pos: autoPos('PROCESSOR', Offset(colProcessorX, processorY)),
    ));

    // IDF between the network column and the processor.
    if (hasIdf) {
      double idfY = processorY;
      if (networkKeys.isNotEmpty) {
        final mid = (networkKeys.length - 1) / 2;
        idfY = rowStart + mid * rowSpacing;
      }
      nodes.add(SchematicNode(
        id: 'IDF',
        title: 'Network IDF',
        subtitle: 'Building switch',
        icon: Icons.lan,
        conn: ConnType.network,
        pos: autoPos('IDF', Offset(colIdfX, idfY)),
      ));
      edges.add(SchematicEdge(
        fromId: 'IDF',
        toId: 'PROCESSOR',
        color: kConnColors[ConnType.trunk]!,
        label: 'Uplink',
        width: 3.5,
      ));
    }

    // Device nodes + their connection edges.
    void addDevice(String key, int row, double colX) {
      final dev = config[key];
      final conn = connOf(key);
      final model = dev['model']?.toString() ?? '';
      final ip = dev['ip_address']?.toString() ?? '';
      final subtitleBits = [
        if (model.isNotEmpty) model,
        if (conn == ConnType.network && ip.isNotEmpty) ip,
      ];
      nodes.add(SchematicNode(
        id: key,
        title: dev['name']?.toString() ?? key,
        subtitle: subtitleBits.join(' • '),
        icon: _iconForDevice(key),
        conn: conn,
        pos: autoPos(key, Offset(colX, rowStart + row * rowSpacing)),
      ));

      switch (conn) {
        case ConnType.network:
          final protocol = dev['protocol']?.toString() ?? '';
          final netPort = dev['net_port']?.toString() ?? '';
          edges.add(SchematicEdge(
            fromId: key,
            toId: 'IDF',
            color: kConnColors[ConnType.network]!,
            label: [protocol, if (netPort.isNotEmpty && netPort != '0') netPort]
                .where((s) => s.isNotEmpty)
                .join(' '),
          ));
          break;
        case ConnType.serial:
          edges.add(SchematicEdge(
            fromId: key,
            toId: 'PROCESSOR',
            color: kConnColors[ConnType.serial]!,
            label: dev['serial_port']?.toString() ?? 'COM?',
          ));
          break;
        default: // relay
          final relays = [
            dev['relay_port_up'],
            dev['relay_port_down'],
            dev['relay_port_stop'],
          ].where((r) => r != null && r.toString().isNotEmpty).join('/');
          edges.add(SchematicEdge(
            fromId: key,
            toId: 'PROCESSOR',
            color: kConnColors[ConnType.relay]!,
            label: relays.isEmpty ? 'Relay' : relays,
          ));
      }
    }

    for (int i = 0; i < networkKeys.length; i++) {
      addDevice(networkKeys[i], i, colNetworkX);
    }
    for (int i = 0; i < directKeys.length; i++) {
      addDevice(directKeys[i], i, colDirectX);
    }

    // Touch panel below the processor, linked to the IDF.
    if (hasTouchPanel) {
      nodes.add(SchematicNode(
        id: 'TOUCHPANEL',
        title: 'Touch Panel',
        subtitle: '$tlpId • $tabCount tab${tabCount == 1 ? '' : 's'}',
        icon: Icons.tab, // replaced by the custom-painted window icon
        conn: ConnType.touchpanel,
        tabCount: tabCount,
        pos: autoPos(
            'TOUCHPANEL', Offset(colProcessorX, processorY + kNodeHeight + 60)),
      ));
      edges.add(SchematicEdge(
        fromId: 'TOUCHPANEL',
        toId: hasIdf ? 'IDF' : 'PROCESSOR',
        color: kConnColors[ConnType.touchpanel]!,
        label: 'PoE',
      ));
    }

    // User-drawn lines (only between nodes that still exist).
    final ids = nodes.map((n) => n.id).toSet();
    for (int i = 0; i < provider.schematicLinks.length; i++) {
      final link = provider.schematicLinks[i];
      final from = link['from'] ?? '';
      final to = link['to'] ?? '';
      if (!ids.contains(from) || !ids.contains(to)) continue;
      final colorVal = int.tryParse(link['color'] ?? '', radix: 16);
      edges.add(SchematicEdge(
        fromId: from,
        toId: to,
        color: colorVal == null
            ? kConnColors[ConnType.network]!
            : Color(0xFF000000 | colorVal),
        label: link['label'] ?? '',
        custom: true,
        customIndex: i,
      ));
    }

    // Grow the canvas to cover dragged positions so nothing gets clipped.
    double maxX = canvasW, maxY = canvasH;
    for (final n in nodes) {
      maxX = math.max(maxX, n.pos.dx + kNodeWidth + 30);
      maxY = math.max(maxY, n.pos.dy + kNodeHeight + 30);
    }

    return SchematicModel(
      nodes,
      edges,
      Size(maxX, maxY),
      systemSetup['gui_full_room_name']?.toString() ?? '',
    );
  }

  static IconData _iconForDevice(String key) {
    if (key.startsWith('PROJECTORDEVICE_')) return Icons.connected_tv;
    if (key.startsWith('CAMERADEVICE_')) return Icons.videocam;
    if (key.startsWith('SWITCHERDEVICE_')) return Icons.swap_horiz;
    if (key.startsWith('DSPDEVICE_')) return Icons.equalizer;
    if (key.startsWith('USBDEVICE_')) return Icons.usb;
    if (key.startsWith('POWERDEVICE_')) return Icons.power;
    if (key.startsWith('MEDIAPORTDEVICE_')) return Icons.settings_input_hdmi;
    if (key.startsWith('WIRELESSDEVICE_')) return Icons.wifi;
    if (key.startsWith('RECORDERDEVICE_')) return Icons.fiber_manual_record;
    if (key.startsWith('SCREENDEVICE_')) return Icons.aspect_ratio;
    return Icons.developer_board; // schema-added families get a generic chip
  }
}

class SchematicView extends StatefulWidget {
  const SchematicView({super.key});

  @override
  State<SchematicView> createState() => _SchematicViewState();
}

class _SchematicViewState extends State<SchematicView> {
  final GlobalKey _diagramKey = GlobalKey();
  final TransformationController _transform = TransformationController();

  bool _editMode = false;
  bool _linkMode = false;
  String? _pendingLinkFrom; // first node tapped while drawing a line

  @override
  void initState() {
    super.initState();
    // Load (or reset) the persisted layout for the currently open config.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppStateProvider>().ensureSchematicLayoutForCurrentConfig();
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red : null,
    ));
  }

  /// Default export file name stem: `<BLDG>_<room>_schematic`.
  String _fileStem(AppStateProvider provider, String suffix) {
    final setup = provider.roomConfig['SYSTEM_SETUP'] ?? {};
    final bldg =
        provider.bldgAbbreviation((setup['gve_bldg'] ?? 'ROOM').toString());
    final room = (setup['gve_room'] ?? '').toString();
    return [bldg, if (room.isNotEmpty) room, suffix]
        .join('_')
        .replaceAll(RegExp(r'[^\w\-]+'), '_');
  }

  // -------------------------------------------------------------------------
  //  EXPORTS
  // -------------------------------------------------------------------------

  Future<void> _exportPng(AppStateProvider provider) async {
    final bytes = await captureBoundary(_diagramKey, pixelRatio: 2.0);
    if (bytes == null) {
      _snack('Could not render the schematic to an image.', error: true);
      return;
    }
    String? outputFile = await FilePicker.saveFile(
      dialogTitle: 'Save Schematic Image',
      fileName: '${_fileStem(provider, 'schematic')}.png',
      type: FileType.custom,
      allowedExtensions: ['png'],
    );
    if (outputFile == null) return;
    if (!outputFile.toLowerCase().endsWith('.png')) outputFile += '.png';
    try {
      await File(outputFile).writeAsBytes(bytes);
      _snack('Schematic image saved to $outputFile');
    } catch (e) {
      _snack('Failed to save image: $e', error: true);
    }
  }

  /// Rows shared by the xlsx and text reports: one line per active device.
  List<List<dynamic>> _deviceReportRows(
      AppStateProvider provider, SchematicModel model) {
    final config = provider.roomConfig;
    final rows = <List<dynamic>>[
      [
        'Device Key', 'Name', 'Type', 'Model', 'Module', 'Connection',
        'IP Address', 'Protocol', 'Net Port', 'Serial Port', 'Keep Alive',
      ],
    ];
    for (final node in model.nodes) {
      if (!config.containsKey(node.id)) continue; // processor/IDF/panel
      final dev = config[node.id];
      final family = provider.uiSchema.deviceTypeForSection(node.id);
      rows.add([
        node.id,
        dev['name']?.toString() ?? '',
        family?.label ?? '',
        dev['model']?.toString() ?? '',
        dev['module']?.toString() ?? '',
        kConnLabels[node.conn] ?? '',
        dev['ip_address']?.toString() ?? '',
        dev['protocol']?.toString() ?? '',
        dev['net_port']?.toString() ?? '',
        dev['serial_port']?.toString() ?? '',
        dev['keep_alive_command']?.toString() ?? '',
      ]);
    }
    return rows;
  }

  List<List<dynamic>> _connectionReportRows(SchematicModel model) {
    final rows = <List<dynamic>>[
      ['From', 'To', 'Kind', 'Label'],
    ];
    for (final e in model.edges) {
      final from = model.nodeById(e.fromId)?.title ?? e.fromId;
      final to = model.nodeById(e.toId)?.title ?? e.toId;
      String kind = 'Custom';
      if (!e.custom) {
        for (final entry in kConnColors.entries) {
          if (entry.value == e.color) kind = kConnLabels[entry.key]!;
        }
      }
      rows.add([from, to, kind, e.label]);
    }
    return rows;
  }

  Future<void> _exportReport(AppStateProvider provider, bool asXlsx) async {
    final model = SchematicModel.build(provider);
    final setup = provider.roomConfig['SYSTEM_SETUP'] ?? {};
    final deviceRows = _deviceReportRows(provider, model);
    final connectionRows = _connectionReportRows(model);
    final systemRows = <List<dynamic>>[
      ['Setting', 'Value'],
      ['Room', setup['gui_full_room_name']?.toString() ?? ''],
      ['Building', setup['gve_bldg']?.toString() ?? ''],
      ['Room Number', setup['gve_room']?.toString() ?? ''],
      ['Processor', setup['processor1']?.toString() ?? ''],
      ['Processor IP', provider.selectedProcessorIp],
      ['Touch Panel', setup['gve_id_tlp_1']?.toString() ?? ''],
      ['GUI Tab Layout', setup['gui_tab']?.toString() ?? ''],
      ['Device Count', (deviceRows.length - 1).toString()],
      ['Generated', DateTime.now().toLocal().toString().split('.').first],
    ];

    final ext = asXlsx ? 'xlsx' : 'txt';
    String? outputFile = await FilePicker.saveFile(
      dialogTitle: 'Save Device Report',
      fileName: '${_fileStem(provider, 'device_report')}.$ext',
      type: FileType.custom,
      allowedExtensions: [ext],
    );
    if (outputFile == null) return;
    if (!outputFile.toLowerCase().endsWith('.$ext')) outputFile += '.$ext';

    try {
      if (asXlsx) {
        final bytes = buildXlsx([
          XlsxSheet(name: 'Devices', rows: deviceRows, columnWidths: {
            0: 22, 1: 38, 2: 24, 3: 26, 4: 42, 5: 18, 6: 16, 7: 10, 8: 10,
            9: 12, 10: 18,
          }),
          XlsxSheet(name: 'Connections', rows: connectionRows, columnWidths: {
            0: 38, 1: 38, 2: 18, 3: 16,
          }),
          XlsxSheet(name: 'System', rows: systemRows, columnWidths: {
            0: 18, 1: 44,
          }),
        ]);
        await File(outputFile).writeAsBytes(bytes);
      } else {
        await File(outputFile).writeAsString(_textReport(
            model.roomTitle, systemRows, deviceRows, connectionRows));
      }
      _snack('Device report saved to $outputFile');
    } catch (e) {
      _snack('Failed to save report: $e', error: true);
    }
  }

  /// Fixed-width plain-text rendering of the same three report tables.
  String _textReport(String roomTitle, List<List<dynamic>> system,
      List<List<dynamic>> devices, List<List<dynamic>> connections) {
    final buffer = StringBuffer();
    void table(String heading, List<List<dynamic>> rows) {
      buffer.writeln(heading);
      buffer.writeln('=' * heading.length);
      final widths = <int>[];
      for (final row in rows) {
        for (int c = 0; c < row.length; c++) {
          final len = row[c].toString().length;
          if (c >= widths.length) {
            widths.add(len);
          } else if (len > widths[c]) {
            widths[c] = len;
          }
        }
      }
      for (int r = 0; r < rows.length; r++) {
        buffer.writeln([
          for (int c = 0; c < rows[r].length; c++)
            rows[r][c].toString().padRight(widths[c]),
        ].join('  '));
        if (r == 0) {
          buffer.writeln(widths.map((w) => '-' * w).join('  '));
        }
      }
      buffer.writeln();
    }

    buffer.writeln('ROOM DEVICE REPORT — $roomTitle');
    buffer.writeln();
    table('System', system);
    table('Devices', devices);
    table('Connections', connections);
    return buffer.toString();
  }

  // -------------------------------------------------------------------------
  //  EDIT MODE — drawing custom lines
  // -------------------------------------------------------------------------

  void _onNodeTap(AppStateProvider provider, SchematicNode node) {
    if (!_editMode || !_linkMode) return;
    if (_pendingLinkFrom == null) {
      setState(() => _pendingLinkFrom = node.id);
      return;
    }
    if (_pendingLinkFrom == node.id) {
      setState(() => _pendingLinkFrom = null); // tap again = cancel
      return;
    }
    final from = _pendingLinkFrom!;
    setState(() => _pendingLinkFrom = null);
    _showNewLinkDialog(provider, from, node.id);
  }

  Future<void> _showNewLinkDialog(
      AppStateProvider provider, String fromId, String toId) async {
    Color picked = kLinkSwatches.first;
    String label = '';
    final model = SchematicModel.build(provider);
    final fromTitle = model.nodeById(fromId)?.title ?? fromId;
    final toTitle = model.nodeById(toId)?.title ?? toId;

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('New Connection Line'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$fromTitle  →  $toTitle'),
                const SizedBox(height: 16),
                const Text('Line color:'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: kLinkSwatches.map((c) {
                    final selected = c == picked;
                    return InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => setDialogState(() => picked = c),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: selected
                              ? Border.all(
                                  color:
                                      Theme.of(ctx).colorScheme.onSurface,
                                  width: 3)
                              : Border.all(color: Colors.black26),
                        ),
                        child: selected
                            ? const Icon(Icons.check,
                                size: 16, color: Colors.white)
                            : null,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'Label (optional)',
                    hintText: 'e.g. HDMI, USB-C, Audio',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => label = v,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Add Line')),
          ],
        ),
      ),
    );

    if (ok == true) {
      final hex = picked
          .toARGB32()
          .toRadixString(16)
          .toUpperCase()
          .substring(2); // RRGGBB
      provider.addSchematicLink(fromId, toId, hex, label);
    }
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
    final model = SchematicModel.build(provider);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildToolbar(provider),
        const Divider(height: 1),
        Expanded(
          child: InteractiveViewer(
            transformationController: _transform,
            constrained: false,
            minScale: 0.3,
            maxScale: 3.0,
            boundaryMargin: const EdgeInsets.all(400),
            child: RepaintBoundary(
              key: _diagramKey,
              child: _buildCanvas(provider, model, theme),
            ),
          ),
        ),
        if (_editMode) _buildEditPanel(provider, model),
      ],
    );
  }

  Widget _buildToolbar(AppStateProvider provider) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('Room Schematic',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(width: 12),
          FilterChip(
            avatar: Icon(_editMode ? Icons.edit : Icons.edit_outlined,
                size: 18),
            label: const Text('Edit'),
            selected: _editMode,
            onSelected: (v) => setState(() {
              _editMode = v;
              if (!v) {
                _linkMode = false;
                _pendingLinkFrom = null;
              }
            }),
          ),
          if (_editMode)
            FilterChip(
              avatar: const Icon(Icons.timeline, size: 18),
              label: Text(_pendingLinkFrom == null
                  ? 'Draw Line'
                  : 'Pick 2nd node...'),
              selected: _linkMode,
              onSelected: (v) => setState(() {
                _linkMode = v;
                _pendingLinkFrom = null;
              }),
            ),
          if (_editMode)
            OutlinedButton.icon(
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('Reset Layout'),
              onPressed: () => provider.resetSchematicPositions(),
            ),
          if (_editMode)
            OutlinedButton.icon(
              icon: const Icon(Icons.save, size: 18),
              label: const Text('Save Layout'),
              onPressed: () async {
                if (provider.schematicSidecarPath.isEmpty) {
                  _snack(
                      'No working config file yet — save/export the config '
                      'first so the layout has somewhere to live.',
                      error: true);
                  return;
                }
                final saved = await provider.saveSchematicLayout();
                _snack(saved.isEmpty
                    ? 'Failed to save layout.'
                    : 'Layout saved to $saved');
              },
            ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.image, size: 18),
            label: const Text('Export PNG'),
            onPressed: () => _exportPng(provider),
          ),
          PopupMenuButton<String>(
            tooltip: 'Export device report',
            onSelected: (v) => _exportReport(provider, v == 'xlsx'),
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                  value: 'xlsx', child: Text('Excel report (.xlsx)')),
              PopupMenuItem(
                  value: 'txt', child: Text('Plain text report (.txt)')),
            ],
            child: IgnorePointer(
              // The menu handles taps; the button is just the visual.
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

  Widget _buildCanvas(
      AppStateProvider provider, SchematicModel model, ThemeData theme) {
    final surface = theme.brightness == Brightness.dark
        ? const Color(0xFF15181C)
        : const Color(0xFFFAFAFA);
    return Container(
      width: model.canvasSize.width,
      height: model.canvasSize.height,
      color: surface,
      child: Stack(
        children: [
          // Connection lines under everything.
          Positioned.fill(
            child: CustomPaint(
              painter: _EdgePainter(model, theme.brightness),
            ),
          ),
          // Room title (part of the PNG export).
          Positioned(
            left: 24,
            top: 16,
            child: Text(
              model.roomTitle.isEmpty ? 'Room Schematic' : model.roomTitle,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          // Nodes.
          for (final node in model.nodes)
            Positioned(
              left: node.pos.dx,
              top: node.pos.dy,
              child: GestureDetector(
                onTap: () => _onNodeTap(provider, node),
                onPanUpdate: _editMode && !_linkMode
                    ? (details) {
                        // delta is already in canvas coordinates (the
                        // GestureDetector lives inside the InteractiveViewer
                        // transform). Clamp to the canvas origin — it only
                        // grows right/down, so negative spots would clip.
                        final p = node.pos + details.delta;
                        provider.setSchematicPosition(node.id,
                            Offset(math.max(0, p.dx), math.max(0, p.dy)));
                      }
                    : null,
                child: _NodeBox(
                  node: node,
                  highlighted: _pendingLinkFrom == node.id,
                  editMode: _editMode,
                ),
              ),
            ),
          // Legend bottom-left (also part of the PNG export).
          Positioned(left: 16, bottom: 12, child: _Legend(theme: theme)),
        ],
      ),
    );
  }

  Widget _buildEditPanel(AppStateProvider provider, SchematicModel model) {
    final custom = model.edges.where((e) => e.custom).toList();
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 140),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: custom.isEmpty
          ? const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  'Edit mode: drag boxes to rearrange. Turn on "Draw Line" and '
                  'tap two boxes to add a colored connection. Custom lines '
                  'appear here for removal.'),
            )
          : ListView(
              children: [
                for (final e in custom)
                  Row(
                    children: [
                      Container(
                        width: 26,
                        height: 4,
                        margin: const EdgeInsets.only(right: 10),
                        color: e.color,
                      ),
                      Expanded(
                        child: Text(
                          '${model.nodeById(e.fromId)?.title ?? e.fromId}  →  '
                          '${model.nodeById(e.toId)?.title ?? e.toId}'
                          '${e.label.isEmpty ? '' : '   (${e.label})'}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        tooltip: 'Remove this line',
                        onPressed: () =>
                            provider.removeSchematicLinkAt(e.customIndex),
                      ),
                    ],
                  ),
              ],
            ),
    );
  }
}

/// One device/processor/IDF box.
class _NodeBox extends StatelessWidget {
  final SchematicNode node;
  final bool highlighted;
  final bool editMode;

  const _NodeBox(
      {required this.node, required this.highlighted, required this.editMode});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connColor = kConnColors[node.conn]!;
    return Container(
      width: kNodeWidth,
      height: kNodeHeight,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: highlighted ? theme.colorScheme.primary : connColor,
          width: highlighted ? 3 : 1.6,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 4,
            offset: const Offset(1, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          node.tabCount > 0
              ? CustomPaint(
                  size: const Size(34, 30),
                  painter: _TabbedWindowIconPainter(
                      tabCount: node.tabCount, color: connColor),
                )
              : Icon(node.icon, size: 30, color: connColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  node.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 12),
                ),
                if (node.subtitle.isNotEmpty)
                  Text(
                    node.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10.5,
                        color: theme.textTheme.bodySmall?.color),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The touch panel icon: a window outline with [tabCount] tabs on top.
class _TabbedWindowIconPainter extends CustomPainter {
  final int tabCount;
  final Color color;

  _TabbedWindowIconPainter({required this.tabCount, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    final fill = Paint()..color = color;

    const tabH = 6.0;
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, tabH, size.width, size.height - tabH),
      const Radius.circular(3),
    );
    canvas.drawRRect(body, stroke);

    // Tabs across the top edge: filled little rectangles.
    final n = tabCount.clamp(1, 8);
    const gap = 2.0;
    final tabW = (size.width - gap * (n + 1)) / n;
    for (int i = 0; i < n; i++) {
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(gap + i * (tabW + gap), 0, tabW, tabH + 2),
          topLeft: const Radius.circular(2),
          topRight: const Radius.circular(2),
        ),
        fill,
      );
    }
    // A screen line inside the window body for a hint of UI.
    canvas.drawLine(
      Offset(4, tabH + 8),
      Offset(size.width - 4, tabH + 8),
      stroke..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(_TabbedWindowIconPainter old) =>
      old.tabCount != tabCount || old.color != color;
}

/// Draws every connection line plus its midpoint label.
class _EdgePainter extends CustomPainter {
  final SchematicModel model;
  final Brightness brightness;

  _EdgePainter(this.model, this.brightness);

  @override
  void paint(Canvas canvas, Size size) {
    for (final edge in model.edges) {
      final from = model.nodeById(edge.fromId);
      final to = model.nodeById(edge.toId);
      if (from == null || to == null) continue;

      final paint = Paint()
        ..color = edge.color
        ..strokeWidth = edge.width
        ..style = PaintingStyle.stroke;
      canvas.drawLine(from.center, to.center, paint);

      if (edge.label.isEmpty) continue;
      final mid = Offset(
        (from.center.dx + to.center.dx) / 2,
        (from.center.dy + to.center.dy) / 2,
      );
      final textPainter = TextPainter(
        text: TextSpan(
          text: edge.label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: brightness == Brightness.dark
                ? Colors.white
                : Colors.black87,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final bg = Rect.fromCenter(
        center: mid,
        width: textPainter.width + 10,
        height: textPainter.height + 4,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(bg, const Radius.circular(4)),
        Paint()
          ..color = brightness == Brightness.dark
              ? const Color(0xE0202429)
              : const Color(0xF0FFFFFF),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(bg, const Radius.circular(4)),
        Paint()
          ..color = edge.color.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      textPainter.paint(
          canvas, mid - Offset(textPainter.width / 2, textPainter.height / 2));
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) => true;
}

/// Color key for the built-in connection types.
class _Legend extends StatelessWidget {
  final ThemeData theme;

  const _Legend({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final conn in ConnType.values)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                      width: 22, height: 3.5, color: kConnColors[conn]),
                  const SizedBox(width: 8),
                  Text(kConnLabels[conn]!,
                      style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
