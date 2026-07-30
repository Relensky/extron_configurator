import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;

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
enum ConnType { network, serial, soe, relay, touchpanel }

const Map<ConnType, Color> kConnColors = {
  ConnType.network: Color(0xFF42A5F5), // blue
  ConnType.serial: Color(0xFFFFA726), // orange
  ConnType.soe: Color(0xFFFDD835), // yellow
  ConnType.relay: Color(0xFFAB47BC), // purple
  ConnType.touchpanel: Color(0xFF26A69A), // teal
};

const Map<ConnType, String> kConnLabels = {
  ConnType.network: 'Network (via IDF)',
  ConnType.serial: 'Serial (COM)',
  ConnType.soe: 'Serial over Ethernet (via Switcher)',
  ConnType.relay: 'Relay',
  ConnType.touchpanel: 'Touch Panel',
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
  final bool custom; // user-drawn (editable endpoints/color/label)
  final int customIndex; // index into provider.schematicLinks when custom
  final double width;
  final ConnType? kind; // the built-in category for auto edges (legend name)

  const SchematicEdge({
    required this.fromId,
    required this.toId,
    required this.color,
    this.label = '',
    this.custom = false,
    this.customIndex = -1,
    this.width = 2.5,
    this.kind,
  });

  /// Identity used to suppress an auto edge ("fromId>toId").
  String get autoId => '$fromId>$toId';
}

/// The fully resolved diagram: nodes (with positions), edges, canvas size.
class SchematicModel {
  final List<SchematicNode> nodes;
  final List<SchematicEdge> edges;
  final Size canvasSize;
  final String roomTitle;

  /// Auto edges suppressed by the user (edit panel offers a restore).
  final List<SchematicEdge> hiddenEdges;

  SchematicModel(this.nodes, this.edges, this.canvasSize, this.roomTitle,
      [this.hiddenEdges = const []]);

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
      if (comType == 'serialoverethernet') return ConnType.soe;
      if (comType == 'relay') return ConnType.relay;
      return ConnType.network;
    }

    final networkKeys =
        deviceKeys.where((k) => connOf(k) == ConnType.network).toList();
    final soeKeys =
        deviceKeys.where((k) => connOf(k) == ConnType.soe).toList();
    final directKeys = deviceKeys
        .where((k) =>
            connOf(k) != ConnType.network && connOf(k) != ConnType.soe)
        .toList();

    // Serial-over-ethernet devices ride the switcher's HDBaseT/DTP serial
    // ports, so their line targets the room switcher; with no switcher in
    // the room they fall back to the processor directly.
    final String soeTarget = deviceKeys.firstWhere(
        (k) => k.startsWith('SWITCHERDEVICE_'),
        orElse: () => 'PROCESSOR');

    // LEFT column: network devices, with SoE devices slotted in directly
    // after their switcher — the short adjacent line can't cross anything.
    // No switcher in the room: SoE devices go to the right column and line
    // straight to the processor like the other direct connections.
    final List<String> leftKeys = [];
    for (final k in networkKeys) {
      leftKeys.add(k);
      if (k == soeTarget) leftKeys.addAll(soeKeys.where((s) => s != k));
    }
    if (soeTarget == 'PROCESSOR' || !leftKeys.any(soeKeys.contains)) {
      directKeys.addAll(soeKeys.where((s) => !leftKeys.contains(s)));
    }

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

    final int rows = math.max(leftKeys.length, directKeys.length);
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
      conn: ConnType.network,
      pos: autoPos('PROCESSOR', Offset(colProcessorX, processorY)),
    ));

    // IDF between the network column and the processor.
    if (hasIdf) {
      double idfY = processorY;
      if (leftKeys.isNotEmpty) {
        final mid = (leftKeys.length - 1) / 2;
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
      // The processor is just another network drop on the IDF.
      edges.add(SchematicEdge(
        fromId: 'IDF',
        toId: 'PROCESSOR',
        color: kConnColors[ConnType.network]!,
        width: 3.5,
        kind: ConnType.network,
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
            kind: ConnType.network,
          ));
          break;
        case ConnType.serial:
          edges.add(SchematicEdge(
            fromId: key,
            toId: 'PROCESSOR',
            color: kConnColors[ConnType.serial]!,
            label: dev['serial_port']?.toString() ?? 'COM?',
            kind: ConnType.serial,
          ));
          break;
        case ConnType.soe:
          edges.add(SchematicEdge(
            fromId: key,
            // The room switcher carries the serial line; no switcher in the
            // room (or the switcher itself is SoE) -> straight to processor.
            toId: soeTarget == key ? 'PROCESSOR' : soeTarget,
            color: kConnColors[ConnType.soe]!,
            label: dev['serial_port']?.toString() ?? 'SoE',
            kind: ConnType.soe,
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
            kind: ConnType.relay,
          ));
      }
    }

    for (int i = 0; i < leftKeys.length; i++) {
      addDevice(leftKeys[i], i, colNetworkX);
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
        kind: ConnType.touchpanel,
      ));
    }

    // Auto edges the user deleted/re-routed are pulled aside (still listed
    // greyed-out in the edit panel so they can be restored).
    final List<SchematicEdge> hiddenEdges = [];
    edges.removeWhere((e) {
      if (provider.schematicHiddenEdges.contains(e.autoId)) {
        hiddenEdges.add(e);
        return true;
      }
      return false;
    });

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
      hiddenEdges,
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

  /// "Saved" snackbar for a written file, offering the two things you actually
  /// want next: open it, or open the folder it landed in (with the file
  /// selected). A SnackBar only takes one `action`, so both buttons live in the
  /// content row.
  ///
  /// Held for 10s rather than the default 4 — a file dialog has just closed and
  /// the buttons are no use if they're gone before the eye gets back.
  void _savedSnack(AppStateProvider provider, String label, String filePath) {
    if (!mounted) return;

    Future<void> run(Future<String?> Function() action) async {
      final error = await action();
      if (error != null) _snack(error, error: true);
    }

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 10),
      content: Row(
        children: [
          // The name alone: a full path is long enough to push the buttons off
          // a narrow window, and "Open Folder" is what a path gets read for.
          Expanded(
            child: Text('$label saved as ${path.basename(filePath)}',
                overflow: TextOverflow.ellipsis),
          ),
          TextButton(
            onPressed: () => run(() => provider.openInDesktop(filePath)),
            child: const Text('OPEN FILE'),
          ),
          TextButton(
            onPressed: () => run(() => provider.revealInFileManager(filePath)),
            child: const Text('OPEN FOLDER'),
          ),
        ],
      ),
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
      _savedSnack(provider, 'Schematic image', outputFile);
    } catch (e) {
      _snack('Failed to save image: $e', error: true);
    }
  }


  /// "Copy text to clipboard" on the Report menu: the same plain-text report
  /// the .txt export writes, without touching the disk.
  Future<void> _copyReportText(AppStateProvider provider) async {
    final model = SchematicModel.build(provider);
    final text = _textReport(model.roomTitle, reportSections(provider, model));
    await Clipboard.setData(ClipboardData(text: text));
    _snack('Device report copied to clipboard '
        '(${text.split('\n').length} lines).');
  }

  Future<void> _exportReport(AppStateProvider provider, bool asXlsx) async {
    final model = SchematicModel.build(provider);
    final sections = reportSections(provider, model);

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
        // ONE sheet, sections stacked like the text report, with the
        // schematic image dropped in underneath. Title/header rows are
        // padded with blank cells to the section's widest row, so their
        // background band runs the full width of the data beneath them
        // (auto column widths already size each column to its longest
        // value); data rows are padded the same and zebra-striped.
        List<dynamic> pad(List<dynamic> row, int width) =>
            [...row, ...List.filled(math.max(0, width - row.length), '')];
        int widthOf(ReportSection s) =>
            s.rows.fold(s.header.length,
                (m, r) => math.max(m, r.length));

        final rows = <List<dynamic>>[];
        final rowStyles = <int, int>{};
        final overflowRows = <int>{};
        final int reportWidth =
            sections.fold(1, (w, s) => math.max(w, widthOf(s)));
        // Row 1 carries the room and nothing else, merged across A:E so the
        // title band reads as one cell instead of a value stuck in column A.
        rows.add(pad([model.roomTitle], reportWidth));
        rowStyles[0] = XlsxRowStyle.title;
        for (final s in sections) {
          // 2-column sections (System) sit in columns A and B. Their VALUE
          // cell is excluded from column auto-sizing, so a long room/building
          // name overflows right into the empty cells instead of stretching
          // column B, which the Devices table also uses.
          final bool twoColumn = s.header.length == 2;
          final int width = twoColumn ? 2 : widthOf(s);
          rows.add([]);
          rowStyles[rows.length] = XlsxRowStyle.title;
          rows.add(pad([s.title], width));
          rowStyles[rows.length] = XlsxRowStyle.header;
          rows.add(pad(s.header, width));
          for (int i = 0; i < s.rows.length; i++) {
            if (i.isOdd) rowStyles[rows.length] = XlsxRowStyle.zebra;
            if (twoColumn) overflowRows.add(rows.length);
            rows.add(pad(s.rows[i], width));
          }
        }

        // Diagram image below the tables, scaled to ~900px wide.
        XlsxImage? image;
        final png = await captureBoundary(_diagramKey, pixelRatio: 1.5);
        if (png != null) {
          final size = XlsxImage.pngSize(png);
          if (size != null) {
            const targetW = 900;
            image = XlsxImage(
              pngBytes: png,
              anchorCol: 0,
              anchorRow: rows.length + 1,
              widthPx: targetW,
              heightPx: (size.$2 * targetW / size.$1).round(),
            );
          }
        }

        final bytes = buildXlsx([
          XlsxSheet(
            name: 'Room Report',
            rows: rows,
            rowStyles: rowStyles,
            overflowRows: overflowRows,
            merges: const ['A1:E1'],
            image: image,
          ),
        ]);
        await File(outputFile).writeAsBytes(bytes);
      } else {
        await File(outputFile).writeAsString(_textReport(model.roomTitle, sections));
      }
      _savedSnack(provider, 'Device report', outputFile);
    } catch (e) {
      _snack('Failed to save report: $e', error: true);
    }
  }

  /// Fixed-width plain-text rendering of the same report sections.
  String _textReport(
      String roomTitle,
      List<ReportSection> sections) {
    final buffer = StringBuffer();
    buffer.writeln(roomTitle); // the room and nothing else, like the xlsx
    buffer.writeln();
    for (final s in sections) {
      buffer.writeln(s.title);
      buffer.writeln('=' * s.title.length);
      final all = [s.header, ...s.rows];
      final widths = <int>[];
      for (final row in all) {
        for (int c = 0; c < row.length; c++) {
          final len = row[c].toString().length;
          if (c >= widths.length) {
            widths.add(len);
          } else if (len > widths[c]) {
            widths[c] = len;
          }
        }
      }
      for (int r = 0; r < all.length; r++) {
        buffer.writeln([
          for (int c = 0; c < all[r].length; c++)
            all[r][c].toString().padRight(widths[c]),
        ].join('  '));
        if (r == 0) buffer.writeln(widths.map((w) => '-' * w).join('  '));
      }
      buffer.writeln();
    }
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
    _showLineDialog(provider, fromId: from, toId: node.id);
  }

  /// The one line dialog, used for every case:
  ///   * a NEW line (tap two nodes in Draw Line mode)
  ///   * EDITING a user-drawn line ([customIndex] >= 0)
  ///   * EDITING an auto line ([hideAutoId] set) — saving suppresses the
  ///     auto line and adds an editable copy, so a serial-over-ethernet
  ///     projector can be re-routed to Switcher 2 while keeping its label.
  /// Endpoints are editable via dropdowns in every case.
  Future<void> _showLineDialog(
    AppStateProvider provider, {
    required String fromId,
    required String toId,
    Color? initialColor,
    String initialLabel = '',
    int customIndex = -1,
    String? hideAutoId,
  }) async {
    final model = SchematicModel.build(provider);
    Color picked = initialColor ?? kLinkSwatches.first;
    // Editing an auto line whose color isn't a swatch: offer it as an extra
    // swatch so "keep the current color" stays possible.
    final List<Color> swatches = [
      if (!kLinkSwatches.contains(picked)) picked,
      ...kLinkSwatches,
    ];
    String label = initialLabel;
    String from = fromId;
    String to = toId;
    final bool isNew = customIndex < 0 && hideAutoId == null;

    DropdownButtonFormField<String> nodePicker(String current, String title,
            void Function(String) onChanged) =>
        DropdownButtonFormField<String>(
          initialValue: current,
          isExpanded: true,
          decoration: InputDecoration(
              labelText: title, border: const OutlineInputBorder()),
          items: model.nodes
              .map((n) => DropdownMenuItem(
                  value: n.id,
                  child: Text(n.title, overflow: TextOverflow.ellipsis)))
              .toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        );

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isNew ? 'New Connection Line' : 'Edit Connection Line'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                nodePicker(from, 'From', (v) => from = v),
                const SizedBox(height: 12),
                nodePicker(to, 'To', (v) => to = v),
                const SizedBox(height: 16),
                const Text('Line color:'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: swatches.map((c) {
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
                TextFormField(
                  initialValue: label,
                  decoration: const InputDecoration(
                    labelText: 'Label (optional)',
                    hintText: 'e.g. HDMI, USB-C, COM3',
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
                child: Text(isNew ? 'Add Line' : 'Save Line')),
          ],
        ),
      ),
    );

    if (ok != true || from == to) return;
    final hex =
        picked.toARGB32().toRadixString(16).toUpperCase().substring(2);
    if (customIndex >= 0) {
      provider.updateSchematicLinkAt(customIndex, from, to, hex, label);
    } else {
      if (hideAutoId != null) provider.hideSchematicEdge(hideAutoId);
      provider.addSchematicLink(from, to, hex, label);
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
                // Wizard-built session with no file yet: prompt to save the
                // config first (which ties the file to the session), then
                // write the layout sidecar next to it right after.
                if (provider.schematicSidecarPath.isEmpty) {
                  _snack('No working config file yet — choose where to save '
                      'the config, then the layout is saved beside it.');
                  final bool exported = await provider.exportRoomConfig();
                  if (!exported) {
                    _snack('Layout not saved — the config save was cancelled.',
                        error: true);
                    return;
                  }
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
            onSelected: (v) => v == 'copy'
                ? _copyReportText(provider)
                : _exportReport(provider, v == 'xlsx'),
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                  value: 'xlsx', child: Text('Excel report (.xlsx)')),
              PopupMenuItem(
                  value: 'txt', child: Text('Plain text report (.txt)')),
              PopupMenuItem(
                  value: 'copy', child: Text('Copy text to clipboard')),
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

  /// Edit-mode line list: EVERY line on the diagram — auto-generated and
  /// user-drawn — with edit + delete on each row. Editing an auto line
  /// converts it to a user line (so its route/color/label become editable);
  /// deleted auto lines stay listed greyed-out with a restore button.
  Widget _buildEditPanel(AppStateProvider provider, SchematicModel model) {
    final theme = Theme.of(context);
    String edgeText(SchematicEdge e) =>
        '${model.nodeById(e.fromId)?.title ?? e.fromId}  →  '
        '${model.nodeById(e.toId)?.title ?? e.toId}'
        '${e.label.isEmpty ? '' : '   (${e.label})'}';

    Widget swatch(Color c, {bool dim = false}) => Container(
          width: 26,
          height: 4,
          margin: const EdgeInsets.only(right: 10),
          color: dim ? c.withValues(alpha: 0.35) : c,
        );

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 190),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: ListView(
        children: [
          Text(
            'Drag boxes to rearrange. "Draw Line" + tap two boxes adds a '
            'line. Edit any line below to re-route or recolor it (editing an '
            'auto line makes it yours); deleted auto lines can be restored.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          for (final e in model.edges)
            Row(
              children: [
                swatch(e.color),
                Expanded(
                  child: Text(edgeText(e), overflow: TextOverflow.ellipsis),
                ),
                Text(
                  e.custom ? 'Custom' : (kConnLabels[e.kind] ?? 'Auto'),
                  style: theme.textTheme.bodySmall,
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: e.custom
                      ? 'Edit this line'
                      : 'Edit this line (re-route, recolor, relabel)',
                  onPressed: () => _showLineDialog(
                    provider,
                    fromId: e.fromId,
                    toId: e.toId,
                    initialColor: e.color,
                    initialLabel: e.label,
                    customIndex: e.custom ? e.customIndex : -1,
                    hideAutoId: e.custom ? null : e.autoId,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: 'Remove this line',
                  onPressed: () => e.custom
                      ? provider.removeSchematicLinkAt(e.customIndex)
                      : provider.hideSchematicEdge(e.autoId),
                ),
              ],
            ),
          for (final e in model.hiddenEdges)
            Row(
              children: [
                swatch(e.color, dim: true),
                Expanded(
                  child: Text(
                    edgeText(e),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: theme.disabledColor,
                        decoration: TextDecoration.lineThrough),
                  ),
                ),
                Text('Removed', style: theme.textTheme.bodySmall),
                IconButton(
                  icon: const Icon(Icons.restore, size: 20),
                  tooltip: 'Restore this auto line',
                  onPressed: () => provider.restoreSchematicEdge(e.autoId),
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

/// Draws every connection line plus its label, avoiding overlaps:
///   * a line whose straight path would cut through an unrelated node box
///     curves around it instead (so dragged arrangements stay readable)
///   * labels are painted in a SECOND pass — no line ever covers a label —
///     and each label slides along its line to a spot clear of node boxes
///     and of the labels already placed
class _EdgePainter extends CustomPainter {
  final SchematicModel model;
  final Brightness brightness;

  _EdgePainter(this.model, this.brightness);

  /// True when the segment [a]->[b] passes through [rect] (sampled — cheap
  /// and plenty accurate for box-sized obstacles).
  static bool _segmentHitsRect(Offset a, Offset b, Rect rect) {
    const int samples = 24;
    for (int i = 1; i < samples; i++) {
      if (rect.contains(Offset.lerp(a, b, i / samples)!)) return true;
    }
    return false;
  }

  /// Point on the quadratic bezier (a, control, b) at [t].
  static Offset _bezier(Offset a, Offset c, Offset b, double t) {
    final u = 1 - t;
    return a * (u * u) + c * (2 * u * t) + b * (t * t);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Inflated node boxes = obstacles for lines and no-go zones for labels.
    final Map<String, Rect> nodeRects = {
      for (final n in model.nodes)
        n.id: Rect.fromLTWH(
                n.pos.dx, n.pos.dy, kNodeWidth, kNodeHeight)
            .inflate(6),
    };

    // --- PASS 1: lines (collect each edge's label-anchor curve) ------------
    final List<(SchematicEdge, Offset, Offset?, Offset)> labeled = [];
    for (final edge in model.edges) {
      final from = model.nodeById(edge.fromId);
      final to = model.nodeById(edge.toId);
      if (from == null || to == null) continue;
      final a = from.center;
      final b = to.center;

      // Nodes (other than the endpoints) the straight line would cut through.
      Rect? blocked;
      for (final entry in nodeRects.entries) {
        if (entry.key == edge.fromId || entry.key == edge.toId) continue;
        if (_segmentHitsRect(a, b, entry.value)) {
          blocked = entry.value;
          break;
        }
      }

      final paint = Paint()
        ..color = edge.color
        ..strokeWidth = edge.width
        ..style = PaintingStyle.stroke;

      Offset? control;
      if (blocked != null) {
        // Curve around the box: bend away from its center, far enough that
        // the curve's apex clears the box whichever way the line grazes it.
        final mid = Offset.lerp(a, b, 0.5)!;
        final dir = b - a;
        final len = dir.distance;
        if (len > 1) {
          Offset perp = Offset(-dir.dy / len, dir.dx / len);
          if ((blocked.center - mid).dx * perp.dx +
                  (blocked.center - mid).dy * perp.dy >
              0) {
            perp = -perp; // push away from the obstacle, not into it
          }
          control = mid + perp * (kNodeHeight * 2.4);
          final path = Path()
            ..moveTo(a.dx, a.dy)
            ..quadraticBezierTo(control.dx, control.dy, b.dx, b.dy);
          canvas.drawPath(path, paint);
        } else {
          canvas.drawLine(a, b, paint);
        }
      } else {
        canvas.drawLine(a, b, paint);
      }

      if (edge.label.isNotEmpty) labeled.add((edge, a, control, b));
    }

    // --- PASS 2: labels (drawn over every line, dodging collisions) --------
    final List<Rect> placed = [];
    for (final (edge, a, control, b) in labeled) {
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

      Rect rectAt(double t) {
        final p = control == null
            ? Offset.lerp(a, b, t)!
            : _bezier(a, control, b, t);
        return Rect.fromCenter(
            center: p,
            width: textPainter.width + 10,
            height: textPainter.height + 4);
      }

      // Slide along the line until the label is clear of node boxes and of
      // the labels already placed; the middle spot wins ties.
      Rect bg = rectAt(0.5);
      for (final t in const [0.5, 0.4, 0.6, 0.3, 0.7, 0.22, 0.78, 0.15]) {
        final candidate = rectAt(t);
        final bool clear = !placed.any((r) => r.overlaps(candidate)) &&
            !nodeRects.values.any((r) => r.overlaps(candidate));
        if (clear) {
          bg = candidate;
          break;
        }
      }
      placed.add(bg);

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
          canvas,
          bg.center -
              Offset(textPainter.width / 2, textPainter.height / 2));
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

// ============================================================================
//  DEVICE REPORT
// ============================================================================
//  Report content lives outside the widget: [reportSections] is a pure
//  function of the loaded config plus the schematic (which supplies the
//  connection list and the dev_-count-filtered device set), so the .xlsx, the
//  .txt and the clipboard copy all render the same thing — and it can be
//  tested without pumping a widget.

/// One report section: a title, a header row, and data rows.
typedef ReportSection = ({
  String title,
  List<String> header,
  List<List<dynamic>> rows,
});

/// Friendly display name for a config key: the schema label when one is
/// defined, otherwise the key title-cased with common AV acronyms upper-
/// cased (input_doc_cam -> "Doc Cam"). [stripPrefix] removes a section
/// prefix like "input_" first.
///
/// [section] is the config block the key lives in, so a schema "labelWhen"
/// can pick the label from a sibling value — input_usb reports as "VGA over
/// USB" when SYSTEM_SETUP's gui_usb_or_vga is VGA, and "USB" otherwise.
String _friendlyKey(AppStateProvider provider, String key,
    {String? stripPrefix, Map<String, dynamic> section = const {}}) {
  final label = provider.uiSchema.labelFor(key, section);
  if (label != null && label.isNotEmpty) return label;
  var k = key;
  if (stripPrefix != null && k.startsWith(stripPrefix)) {
    k = k.substring(stripPrefix.length);
  }
  const acronyms = {
    'pc', 'hdmi', 'usb', 'vga', 'dvd', 'br', 'cc', 'cc2', 'ip', 'gui',
    'gve', 'ntp', 'ald', 'tlp', 'poe', 'dsp', 'wl', 'tv', 'aud', 'inst',
  };
  return k
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => acronyms.contains(w.toLowerCase())
          ? w.toUpperCase()
          : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

/// Display form of a config value: touch-panel \r line breaks become
/// spaces, null becomes ''.
String _friendlyValue(dynamic v) =>
    (v ?? '').toString().replaceAll(r'\r', ' ');

/// The report name of the device in config section [sectionKey]: its 'name'
/// property, falling back to the schematic node title. Blank for a null,
/// absent, or inactive section — a device the dev_ counts exclude is left out
/// of the diagram and the Devices table, so an I/O row must not name it
/// either. Blank is also what an I/O key with no device on the end reports.
String _deviceNameFor(
    AppStateProvider provider, SchematicModel model, String? sectionKey) {
  if (sectionKey == null) return '';
  final node = model.nodeById(sectionKey);
  if (node == null) return ''; // not an active device in this room
  final dev = provider.roomConfig[sectionKey];
  final name = (dev is Map) ? _friendlyValue(dev['name']) : '';
  return name.isNotEmpty ? name : node.title;
}

/// REPORT-ONLY names for the switcher I/O keys, spelled out for whoever reads
/// the report rather than edits the config: the tech-facing "AUD Cam" / "Proj
/// 1" shorthand stays on the device tabs (and in ui_schema.json), while the
/// report says what the signal actually is. Keys with no entry keep their
/// [_friendlyKey] spelling.
const Map<String, String> _reportIoNames = {
  'input_aud_cam': 'Audience Camera',
  'input_inst_cam': 'Instructor Camera',
  'output_audio': 'Audio Output (Amplifier)',
  'output_audio_ald': 'Assisted Listening',
  'output_cc': 'Capture Card',
  'output_proj_1': 'Display Device 1',
  'output_proj_2': 'Display Device 2',
  'output_proj_3': 'Display Device 3',
  'output_proj_4': 'Display Device 4',
};

/// The config device section an I/O key feeds, so the report can name the
/// hardware behind a generic label ("Display Device 1" -> "Projector -
/// PT-FW430U"). Only one-to-one pairings the config guarantees are listed:
/// the projector/display outputs by number, the two cameras by the project's
/// Inst = 1 / Aud = 2 convention (CAMERADEVICE_1 carries Lbl_InstCam_Model),
/// and the wireless input. Everything else reports a blank Device.
const Map<String, String> _reportIoDevice = {
  'input_inst_cam': 'CAMERADEVICE_1',
  'input_aud_cam': 'CAMERADEVICE_2',
  'input_wireless': 'WIRELESSDEVICE_1',
  'output_proj_1': 'PROJECTORDEVICE_1',
  'output_proj_2': 'PROJECTORDEVICE_2',
  'output_proj_3': 'PROJECTORDEVICE_3',
  'output_proj_4': 'PROJECTORDEVICE_4',
};

/// One report section: a title, a header row, and data rows.
/// Shared by the single-sheet xlsx and the plain-text report.
List<ReportSection> reportSections(AppStateProvider provider, SchematicModel model) {
  final config = provider.roomConfig;
  final Map<String, dynamic> setup =
      (config['SYSTEM_SETUP'] is Map) ? config['SYSTEM_SETUP'] : {};

  // --- System summary (friendly names + resolved building name) ---
  final String rawBldg = setup['gve_bldg']?.toString() ?? '';
  final String fullBldg = provider.fullBuildingNameForCode(rawBldg);
  final deviceCount =
      model.nodes.where((n) => config.containsKey(n.id)).length;
  final String tlp = _friendlyValue(setup['gve_id_tlp_1']);

  // The GVE room IDs, in key order (gve_id_room_1, _2, ...). "N/A" entries
  // are dropped the same way an unused touch panel is.
  final roomIdKeys = setup.keys
      .where((k) => k.startsWith('gve_id_room'))
      .toList()
    ..sort();

  // Panel layout and the source list read as their schema descriptions
  // ("3_Cams_Dev" -> "Menu Tabs: 3 - Cameras & Devices") rather than the
  // raw tokens the processor stores.
  final String panelLayout = provider.uiSchema
      .optionLabelFor('gui_tab', setup['gui_tab']?.toString() ?? '');
  final String sources =
      provider.uiSchema.comboLabelFor('gui_inputs', setup) ?? '';

  // Python tracebacks are opt-in per room — a conversion no longer adds the
  // ENVIRONMENT block — so the report only speaks up when the room actually
  // carries the setting, and says which way it is set.
  final env = config['ENVIRONMENT'];
  final String tracebacks = (env is Map && env.containsKey('traceback_allowed'))
      ? (env['traceback_allowed'] == true ? 'Allowed' : 'Not allowed')
      : '';

  // Rows with no value (e.g. the GUI/touch-panel keys were deleted from
  // SYSTEM_SETUP) are left out instead of printing blanks.
  final systemRows = <List<dynamic>>[
    ['Room', _friendlyValue(setup['gui_full_room_name'])],
    ['Building', fullBldg.isEmpty ? rawBldg : fullBldg],
    ['Room Number', _friendlyValue(setup['gve_room'])],
    for (final k in roomIdKeys)
      [
        _friendlyKey(provider, k, section: setup),
        _friendlyValue(setup[k]),
      ],
    ['Processor', _friendlyValue(setup['processor1'])],
    ['Processor IP', provider.selectedProcessorIp],
    if (tlp.isNotEmpty && tlp.toUpperCase() != 'N/A') ...[
      ['Touch Panel', tlp],
      ['Panel Layout', panelLayout],
    ],
    ['Sources', sources],
    ['Python Tracebacks', tracebacks],
    ['Device Count', deviceCount.toString()],
    ['Generated', DateTime.now().toLocal().toString().split('.').first],
  ]..removeWhere((r) {
      final v = r[1].toString();
      return v.isEmpty || v.toUpperCase() == 'N/A';
    });

  // --- Inputs / Outputs from SYSTEM_SETUP (friendly names) ---
  // Third column: the device on the other end of that switcher port, named
  // as the config names it, so "Display Device 2" reads as real hardware.
  // Rows still sort by the raw config key, so the order matches the config.
  List<List<dynamic>> prefixed(String prefix) {
    final keys = setup.keys
        .where((k) => k.startsWith(prefix) && setup[k] != null)
        .toList()
      ..sort();
    return [
      for (final k in keys)
        [
          _reportIoNames[k] ??
              _friendlyKey(provider, k, stripPrefix: prefix, section: setup),
          _friendlyValue(setup[k]),
          _deviceNameFor(provider, model, _reportIoDevice[k]),
        ]
    ];
  }

  // --- Power outlets (only the outlets the config actually carries) ---
  // Outlet 10 must sort after outlet 9, so order by the trailing number
  // rather than by key text.
  int outletNumber(String k) =>
      int.tryParse(RegExp(r'(\d+)$').firstMatch(k)?.group(1) ?? '') ?? 0;
  final outletKeys = setup.keys
      .where((k) =>
          k.startsWith('power1_outlet_') &&
          !k.endsWith('_action') &&
          _friendlyValue(setup[k]).isNotEmpty)
      .toList()
    ..sort((a, b) => outletNumber(a).compareTo(outletNumber(b)));
  final powerRows = <List<dynamic>>[
    for (final k in outletKeys)
      [
        'Outlet ${outletNumber(k)}',
        _friendlyValue(setup[k]),
        _friendlyValue(setup['${k}_action']),
      ]
  ];

  // --- Camera presets (gui_preset_name_<camera>_<n>) ---
  const presetCameras = {'inst': 'Instructor', 'aud': 'Audience'};
  const presetPrefix = 'gui_preset_name_';
  final presetKeys = setup.keys
      .where((k) =>
          k.startsWith(presetPrefix) &&
          _friendlyValue(setup[k]).isNotEmpty)
      .toList()
    ..sort();
  final presetRows = <List<dynamic>>[
    for (final k in presetKeys)
      [
        // "gui_preset_name_inst_2" -> camera "inst", preset "2"
        presetCameras[
                k.substring(presetPrefix.length).split('_').first] ??
            _friendlyKey(provider, k.substring(presetPrefix.length)),
        'Preset ${outletNumber(k)}',
        _friendlyValue(setup[k]),
      ]
  ];

  // --- Devices ---
  final deviceRows = <List<dynamic>>[];
  // --- Audio groups: which DSP/switcher group number each function uses ---
  final audioGroupRows = <List<dynamic>>[];
  for (final node in model.nodes) {
    if (!config.containsKey(node.id)) continue; // processor/IDF/panel
    final dev = config[node.id];
    final family = provider.uiSchema.deviceTypeForSection(node.id);
    final String deviceName = _deviceNameFor(provider, model, node.id);
    deviceRows.add([
      deviceName,
      family?.label ?? '',
      _friendlyValue(dev['model']),
      _friendlyValue(dev['gve_id']),
      kConnLabels[node.conn] ?? '',
      _friendlyValue(dev['ip_address']),
      _friendlyValue(dev['protocol']),
      _friendlyValue(dev['net_port']),
      _friendlyValue(dev['serial_port']),
      _friendlyValue(dev['keep_alive_command']),
      _friendlyValue(dev['module']),
    ]);

    // Any device carrying group_ keys (DSPs and switchers today) lists what
    // each audio group number is tied to.
    if (dev is! Map) continue;
    final groupKeys = dev.keys
        .map((k) => k.toString())
        .where((k) => k.startsWith('group_') && _friendlyValue(dev[k]).isNotEmpty)
        .toList()
      ..sort();
    for (final k in groupKeys) {
      audioGroupRows.add([
        deviceName,
        _friendlyKey(provider, k, stripPrefix: 'group_'),
        _friendlyValue(dev[k]),
      ]);
    }
  }

  // --- Connections (as drawn, including user re-routes) ---
  final connectionRows = <List<dynamic>>[
    for (final e in model.edges)
      [
        model.nodeById(e.fromId)?.title ?? e.fromId,
        model.nodeById(e.toId)?.title ?? e.toId,
        e.custom ? 'Custom' : (kConnLabels[e.kind] ?? 'Auto'),
        e.label,
      ]
  ];

  return [
    (title: 'System', header: ['Setting', 'Value'], rows: systemRows),
    (
      title: 'Inputs',
      header: ['Input', 'Switcher Input', 'Device'],
      rows: prefixed('input_')
    ),
    (
      title: 'Outputs',
      header: ['Output', 'Switcher Output', 'Device'],
      rows: prefixed('output_')
    ),
    // Sections with nothing to say are dropped below rather than printing a
    // bare header — a room with no power controller or no camera presets
    // shouldn't grow empty tables.
    (
      title: 'Power Outlets',
      header: ['Outlet', 'Name', 'Action'],
      rows: powerRows
    ),
    (
      title: 'Camera Presets',
      header: ['Camera', 'Preset', 'Name'],
      rows: presetRows
    ),
    (
      title: 'Devices',
      header: [
        'Name', 'Type', 'Model', 'GVE ID', 'Connection', 'IP Address',
        'Protocol', 'Network Port', 'Serial Port', 'Keep Alive',
        'Python Module',
      ],
      rows: deviceRows
    ),
    (
      title: 'Audio Groups',
      header: ['Device', 'Group', 'Number'],
      rows: audioGroupRows
    ),
    (
      title: 'Connections',
      header: ['From', 'To', 'Kind', 'Label'],
      rows: connectionRows
    ),
  ].where((s) => s.rows.isNotEmpty).toList();
}
