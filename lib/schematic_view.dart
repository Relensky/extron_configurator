import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'app_snack.dart';
import 'app_state.dart';
import 'color_wheel_picker.dart';
import 'diagram_capture.dart';
import 'layout_tools.dart';
import 'report_tools.dart';
import 'screenshot_tools.dart';
import 'view_zoom.dart';
import 'side_pane.dart';
import 'workbook_export.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  CONTROL SCHEMATIC TAB
/// ============================================================================
///  Auto-draws the room's CONTROL topology from the loaded config — how each
///  device talks to the processor. The signal path (what plugs into what) is
///  the AV Flow tab's job; these two are deliberately separate documents.
///
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
///  `<config>_control_schematic.json` sidecar via Save Layout. (Diagrams
///  saved before the rename used `<config>_schematic.json`; those are read
///  as-is and move to the new name the next time the layout is saved.)
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

/// The color a connection category is drawn in, honouring the room's
/// overrides. Nothing reads [kConnColors] directly except this — recoloring
/// a category has to move the lines, the box borders AND the legend together
/// or the key stops describing the drawing.
Color connColor(ConnType conn, AppStateProvider provider) =>
    provider.schematicConnColor(conn.index, kConnColors[conn]!);

/// Swatches offered when drawing a custom line.
const List<Color> kLinkSwatches = [
  Color(0xFF42A5F5), Color(0xFFFFA726), Color(0xFFAB47BC), Color(0xFF26A69A),
  Color(0xFF66BB6A), Color(0xFFEF5350), Color(0xFFFFEE58), Color(0xFF8D6E63),
  Color(0xFF78909C), Color(0xFFEC407A), Color(0xFF7E57C2), Color(0xFF29B6F6),
];

const double kNodeWidth = 190;
const double kNodeHeight = 78;

/// How a box added by hand is drawn: a dashed border in a neutral grey.
///
/// Deliberately NOT one of the [kConnColors]. On this drawing a colour means
/// "this is how the processor talks to it", and the whole point of a related
/// box is that the processor does not — colouring it network-blue because it
/// happens to be a network switch would say the opposite of the truth. The
/// dashes and the grey say "here, and real, but not driven from here"; the
/// legend spells it out.
const Color kRelatedNodeColor = Color(0xFF8D95A0);

/// Icons offered for a hand-added box, keyed by a name the sidecar stores.
///
/// A stable string rather than the icon's code point: a font upgrade that
/// renumbers a glyph must not turn last year's UPS into an arrow.
const Map<String, ({String label, IconData icon})> kRelatedNodeIcons = {
  'device': (label: 'Generic device', icon: Icons.developer_board),
  'switch': (label: 'Network switch', icon: Icons.lan),
  'pc': (label: 'PC / server', icon: Icons.computer),
  'laptop': (label: 'Laptop / guest device', icon: Icons.laptop),
  'display': (label: 'Display / TV', icon: Icons.tv),
  'projector': (label: 'Projector', icon: Icons.connected_tv),
  'camera': (label: 'Camera', icon: Icons.videocam),
  'speaker': (label: 'Speaker / amp', icon: Icons.speaker),
  'mic': (label: 'Microphone', icon: Icons.mic),
  'plate': (label: 'Wall plate / floor box', icon: Icons.power_input),
  'power': (label: 'Power / UPS', icon: Icons.power),
  'rack': (label: 'Rack / cabinet', icon: Icons.dns),
  'phone': (label: 'Phone / intercom', icon: Icons.phone),
  'sensor': (label: 'Sensor', icon: Icons.sensors),
};

const String kDefaultRelatedNodeIcon = 'device';

IconData relatedNodeIcon(String key) =>
    (kRelatedNodeIcons[key] ?? kRelatedNodeIcons[kDefaultRelatedNodeIcon]!)
        .icon;

/// One box on the diagram.
class SchematicNode {
  final String id; // device key, 'PROCESSOR', 'IDF', 'TOUCHPANEL', 'EXTRA_n'
  final String title;
  final String subtitle;
  final IconData icon;
  final ConnType conn; // colors the border/icon
  final int tabCount; // >0: draw the window-with-tabs touch panel icon
  final Offset pos; // top-left on the canvas

  /// Added by hand rather than read off the config: equipment in the room that
  /// the control system does not talk to. Drawn dashed, in [kRelatedNodeColor],
  /// and reported separately from the devices the processor drives.
  final bool related;

  /// Index into [AppStateProvider.schematicExtraNodes] when [related].
  final int relatedIndex;

  const SchematicNode({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.conn,
    this.tabCount = 0,
    required this.pos,
    this.related = false,
    this.relatedIndex = -1,
  });

  Offset get center => pos + const Offset(kNodeWidth / 2, kNodeHeight / 2);

  /// The same node at a different spot — used for the live drag preview,
  /// which moves a box (and the lines attached to it) without writing the
  /// new position to the provider on every pointer event.
  SchematicNode movedTo(Offset newPos) => SchematicNode(
        id: id,
        title: title,
        subtitle: subtitle,
        icon: icon,
        conn: conn,
        tabCount: tabCount,
        pos: newPos,
        related: related,
        relatedIndex: relatedIndex,
      );
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
        color: connColor(ConnType.network, provider),
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
            color: connColor(ConnType.network, provider),
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
            color: connColor(ConnType.serial, provider),
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
            color: connColor(ConnType.soe, provider),
            // An SoE device reaches its hardware by ip_address + net_port and
            // carries no serial_port of its own, so the plain label is normal.
            label: (dev['serial_port']?.toString().trim().isNotEmpty ?? false)
                ? dev['serial_port'].toString()
                : 'SoE',
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
            color: connColor(ConnType.relay, provider),
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
        color: connColor(ConnType.touchpanel, provider),
        label: 'PoE',
        kind: ConnType.touchpanel,
      ));
    }

    // Boxes the user added for equipment the control system does not talk to.
    // They come after the derived nodes so a line may run to them, and they
    // auto-lay-out in a row along the bottom — there is no column for them,
    // because there is no connection to the processor that would put them in
    // one. Dragging moves them like anything else.
    final double relatedRowY = rowStart + rows * rowSpacing + 24;
    for (int i = 0; i < provider.schematicExtraNodes.length; i++) {
      final extra = provider.schematicExtraNodes[i];
      final id = extra['id'] ?? '';
      if (id.isEmpty) continue;
      nodes.add(SchematicNode(
        id: id,
        title: extra['title'] ?? id,
        subtitle: extra['subtitle'] ?? '',
        icon: relatedNodeIcon(extra['icon'] ?? ''),
        // Never drawn in a category colour — see [kRelatedNodeColor] — but the
        // field is not nullable, so it carries the one the box is not.
        conn: ConnType.network,
        related: true,
        relatedIndex: i,
        pos: autoPos(
          id,
          Offset(colNetworkX + i * (kNodeWidth + 30), relatedRowY),
        ),
      ));
    }

    // Auto edges the user deleted/re-routed are pulled aside (still listed
    // grayed-out in the edit panel so they can be restored).
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
            ? connColor(ConnType.network, provider)
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

  /// The window the canvas is looked at through, so "Fit to view" can measure
  /// it; the drawing itself is measured through [_diagramKey].
  final GlobalKey _viewportKey = GlobalKey();

  /// Zooms out until the whole schematic is on screen.
  void _fitToView() {
    final fitted = fitToViewport(
      controller: _transform,
      contentKey: _diagramKey,
      viewportKey: _viewportKey,
    );
    if (!fitted) _snack('The schematic is still drawing — try again.');
  }

  bool _editMode = false;
  bool _linkMode = false;
  String? _pendingLinkFrom; // first node tapped while drawing a line

  /// Live drag, held locally: writing the position to the provider on every
  /// pointer move rebuilt every listener in the app (nav rail, app bar, the
  /// lot) for each frame of the drag. Committed once on release.
  String? _dragNodeId;
  Offset _dragStartPos = Offset.zero;
  Offset _dragOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    // So a workbook exported from another tab can still be illustrated with
    // this page's schematic — see diagram_capture.dart.
    registerDiagramCanvas(AppTab.schematic, _diagramKey);
    // Load (or reset) the persisted layout for the currently open config.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppStateProvider>().ensureSchematicLayoutForCurrentConfig();
      }
    });
  }

  @override
  void dispose() {
    unregisterDiagramCanvas(AppTab.schematic, _diagramKey);
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
  /// selected). See [showSavedFileSnack] — every export in the app ends with
  /// the same bar now, rather than each tab keeping its own copy.
  void _savedSnack(AppStateProvider provider, String label, String filePath) {
    if (!mounted) return;
    showSavedFileSnack(context, provider, label, filePath);
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
      _snack('Could not render the control schematic to an image.',
          error: true);
      return;
    }
    String? outputFile = await FilePicker.saveFile(
      dialogTitle: 'Save Control Schematic Image',
      fileName: '${_fileStem(provider, 'control_schematic')}.png',
      type: FileType.custom,
      allowedExtensions: ['png'],
    );
    if (outputFile == null) return;
    if (!outputFile.toLowerCase().endsWith('.png')) outputFile += '.png';
    try {
      await File(outputFile).writeAsBytes(bytes);
      _savedSnack(provider, 'Control schematic image', outputFile);
    } catch (e) {
      _snack('Failed to save image: $e', error: true);
    }
  }


  /// "Copy text to clipboard" on the Report menu: the same plain-text report
  /// the .txt export writes, without touching the disk.
  Future<void> _copyReportText(AppStateProvider provider) async {
    final model = SchematicModel.build(provider);
    final text =
        renderTextReport(model.roomTitle, reportSections(provider, model));
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
        // schematic image dropped in underneath. The banding, padding and
        // column-width rules are shared with the AV Flow tab's cable
        // schedule — see buildStackedReportSheet.
        final png = await captureBoundary(_diagramKey, pixelRatio: 1.5);
        final bytes = buildXlsx([
          buildStackedReportSheet(
            sheetName: 'Room Report',
            title: model.roomTitle,
            sections: sections,
            imageBuilder: png == null
                ? null
                : (anchorRow) => scaledSheetImage(png, anchorRow),
          ),
        ]);
        await File(outputFile).writeAsBytes(bytes);
      } else {
        await File(outputFile)
            .writeAsString(renderTextReport(model.roomTitle, sections));
      }
      _savedSnack(provider, 'Device report', outputFile);
    } catch (e) {
      _snack('Failed to save report: $e', error: true);
    }
  }

  /// The whole job in one book: control (with the room's estimated power
  /// draw), AV flow, racks and the cost estimate — every sheet illustrated
  /// with its own diagram, whichever tab the export was pressed on. Shared
  /// with the AV Flow tab; see workbook_export.dart, which walks the diagram
  /// tabs to capture them and therefore disposes THIS page on the way past.
  Future<void> _exportWorkbook(AppStateProvider provider) =>
      exportRoomWorkbook(context, provider);

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

  /// Adds or edits a box for equipment that is in the room but not in the
  /// control system. [index] >= 0 edits the entry at that spot in
  /// [AppStateProvider.schematicExtraNodes].
  ///
  /// It asks for a name, a detail line and an icon, and nothing else. There is
  /// deliberately no IP, port or protocol: those describe how the processor
  /// talks to a device, and the whole point of this box is that it does not.
  Future<void> _showRelatedDeviceDialog(
    AppStateProvider provider, {
    int index = -1,
  }) async {
    final existing =
        (index >= 0 && index < provider.schematicExtraNodes.length)
            ? provider.schematicExtraNodes[index]
            : null;
    String title = existing?['title'] ?? '';
    String subtitle = existing?['subtitle'] ?? '';
    String icon = existing?['icon']?.isNotEmpty == true
        ? existing!['icon']!
        : kDefaultRelatedNodeIcon;

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add Device' : 'Edit Device'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'A box for equipment the control system does not talk to '
                    'but the room depends on — the building switch, a UPS, '
                    'the room PC, a wall plate. It is drawn dashed, kept out '
                    'of the device report, and can be joined to anything on '
                    'the diagram with Draw Line.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    initialValue: title,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'e.g. Building network switch',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setDialogState(() => title = v),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: subtitle,
                    decoration: const InputDecoration(
                      labelText: 'Detail (optional)',
                      hintText: 'e.g. Cisco 9200 • IDF 2B',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => subtitle = v,
                  ),
                  const SizedBox(height: 16),
                  const Text('Icon:'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final e in kRelatedNodeIcons.entries)
                        Tooltip(
                          message: e.value.label,
                          child: InkWell(
                            key: ValueKey('related_icon_${e.key}'),
                            borderRadius: BorderRadius.circular(6),
                            onTap: () => setDialogState(() => icon = e.key),
                            child: Container(
                              width: 40,
                              height: 36,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: icon == e.key
                                      ? Theme.of(ctx).colorScheme.primary
                                      : Theme.of(ctx).dividerColor,
                                  width: icon == e.key ? 2.4 : 1,
                                ),
                              ),
                              child: Icon(e.value.icon,
                                  size: 20, color: kRelatedNodeColor),
                            ),
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
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              // A nameless box is a box nobody can read or link to by name.
              onPressed: title.trim().isEmpty
                  ? null
                  : () => Navigator.of(ctx).pop(true),
              child: Text(existing == null ? 'Add Device' : 'Save Device'),
            ),
          ],
        ),
      ),
    );

    if (ok != true || title.trim().isEmpty) return;
    if (existing == null) {
      provider.addSchematicExtraNode(
        title: title,
        subtitle: subtitle,
        icon: icon,
      );
      _snack('$title added. Use "Draw Line" to join it to the diagram.');
    } else {
      provider.updateSchematicExtraNodeAt(
        index,
        title: title,
        subtitle: subtitle,
        icon: icon,
      );
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
    final model = _withDragPreview(SchematicModel.build(provider));
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildToolbar(provider),
        const Divider(height: 1),
        Expanded(
          key: _viewportKey,
          child: InteractiveViewer(
            transformationController: _transform,
            constrained: false,
            // Low enough that a room full of devices fits the window.
            minScale: 0.08,
            maxScale: 3.0,
            boundaryMargin: const EdgeInsets.all(400),
            child: RepaintBoundary(
              key: _diagramKey,
              child: _buildCanvas(provider, model, theme),
            ),
          ),
        ),
        // Dragged taller by its top edge: the list of lines in it is as long
        // as the room is, and 190 pixels of it was a scroll bar with three
        // rows behind it.
        if (_editMode)
          BottomPane(
            storageKey: 'schematic_edit',
            child: _buildEditPanel(provider, model),
          ),
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
          Text('Control Schematic',
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
          // Equipment the config knows nothing about, because the control
          // system does not talk to it — the switch the processor lands on,
          // the room PC, a UPS. Without this the drawing could only show what
          // is driven, and the reader had to infer the rest.
          if (_editMode)
            OutlinedButton.icon(
              key: const ValueKey('schematic_add_device'),
              icon: const Icon(Icons.add_box_outlined, size: 18),
              label: const Text('Add device'),
              onPressed: () => _showRelatedDeviceDialog(provider),
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
                    _snack('Layout not saved — the config save was canceled.',
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
          OutlinedButton.icon(
            icon: const Icon(Icons.fit_screen, size: 18),
            label: const Text('Fit to view'),
            onPressed: _fitToView,
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.palette_outlined, size: 18),
            label: const Text('Colors'),
            onPressed: () => _showColorsDialog(provider),
          ),
          // Undoes the last layout edit: a moved node, a drawn or deleted
          // line, a color, a Reset Layout.
          OutlinedButton.icon(
            icon: const Icon(Icons.undo, size: 18),
            label: Text(
              provider.canUndoSchematic
                  ? 'Undo: ${provider.schematicUndoLabel}'
                  : 'Undo',
            ),
            onPressed: provider.canUndoSchematic
                ? () {
                    final undone = provider.undoSchematic();
                    if (undone.isNotEmpty) _snack('Undid: $undone');
                  }
                : null,
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.image, size: 18),
            label: const Text('Export PNG'),
            onPressed: () => _exportPng(provider),
          ),
          PopupMenuButton<String>(
            tooltip: 'Export device report',
            onSelected: (v) => switch (v) {
              'copy' => _copyReportText(provider),
              'workbook' => _exportWorkbook(provider),
              _ => _exportReport(provider, v == 'xlsx'),
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                  value: 'workbook',
                  child: Text('Full room workbook (.xlsx, 4 sheets)')),
              PopupMenuDivider(),
              PopupMenuItem(
                  value: 'xlsx', child: Text('Device report (.xlsx)')),
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

  /// Recolors the connection categories for this room. Changing Network
  /// here moves every network line, every network box border AND the legend
  /// entry together, so the key never stops describing the drawing.
  Future<void> _showColorsDialog(AppStateProvider provider) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Line colors'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'A color set here applies to every line of that kind, to '
                  'the device boxes, and to the legend.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                for (final conn in ConnType.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 168,
                          child: Text(kConnLabels[conn]!,
                              style: const TextStyle(fontSize: 12)),
                        ),
                        Expanded(
                          child: Wrap(
                            spacing: 2,
                            runSpacing: 2,
                            children: [
                              for (final c in kLinkSwatches)
                                ColorSwatchButton(
                                  key: ValueKey('conn_color_${conn.name}_'
                                      '${(c.toARGB32() & 0xFFFFFF).toRadixString(16)}'),
                                  color: c,
                                  width: 24,
                                  height: 20,
                                  selected:
                                      connColor(conn, provider).toARGB32() ==
                                          c.toARGB32(),
                                  onTap: () => setLocal(() => provider
                                      .setSchematicConnColor(conn.index, c)),
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
                              initial: connColor(conn, provider),
                              title: 'Color for ${kConnLabels[conn]}',
                            );
                            if (picked != null) {
                              setLocal(() => provider.setSchematicConnColor(
                                  conn.index, picked));
                            }
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.restart_alt, size: 16),
                          tooltip: 'Back to the default color',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setLocal(() =>
                              provider.setSchematicConnColor(conn.index, null)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  setLocal(() => provider.resetSchematicConnColors()),
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

  Widget _buildCanvas(
      AppStateProvider provider, SchematicModel model, ThemeData theme) {
    final surface = theme.brightness == Brightness.dark
        ? const Color(0xFF15181C)
        : const Color(0xFFFAFAFA);
    // The legend sits BELOW the diagram rather than floating over the
    // bottom-left corner, where it covered whatever box happened to be
    // there. The canvas grows to make room for it.
    // Includes the curves, not just the boxes: a line bending around an
    // obstacle can reach lower than anything else on the page. Recomputed
    // every build, so it stays clear while a box is being dragged.
    final contentBottom = schematicContentBottom(model);
    final legendTop = contentBottom + 28;
    final canvasHeight = math.max(
        model.canvasSize.height,
        legendTop + legendHeight(model.nodes.any((n) => n.related)) + 20);

    return Container(
      width: model.canvasSize.width,
      height: canvasHeight,
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
              model.roomTitle.isEmpty ? 'Control Schematic' : model.roomTitle,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          // Nodes. Each gets its own RepaintBoundary so dragging one doesn't
          // force the others to repaint with it.
          for (final node in model.nodes)
            Positioned(
              left: node.pos.dx,
              top: node.pos.dy,
              child: RepaintBoundary(
                child: GestureDetector(
                  onTap: () => _onNodeTap(provider, node),
                  onPanStart: _canDrag
                      ? (_) => _onNodeDragStart(node.id, node.pos)
                      : null,
                  onPanUpdate:
                      _canDrag ? (d) => _onNodeDragUpdate(d.delta) : null,
                  onPanEnd: _canDrag ? (_) => _onNodeDragEnd(provider) : null,
                  onPanCancel: _canDrag ? () => _onNodeDragEnd(provider) : null,
                  child: MouseRegion(
                    cursor: _canDrag
                        ? (_dragNodeId == node.id
                            ? SystemMouseCursors.grabbing
                            : SystemMouseCursors.grab)
                        : MouseCursor.defer,
                    child: _NodeBox(
                      node: node,
                      connColor: node.related
                          ? kRelatedNodeColor
                          : connColor(node.conn, provider),
                      highlighted: _pendingLinkFrom == node.id,
                      editMode: _editMode,
                      dragging: _dragNodeId == node.id,
                    ),
                  ),
                ),
              ),
            ),
          // Legend under the diagram (also part of the PNG export).
          Positioned(
            left: 16,
            top: legendTop,
            child: _Legend(
              theme: theme,
              provider: provider,
              hasRelated: model.nodes.any((n) => n.related),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  //  DRAGGING
  // -------------------------------------------------------------------------

  /// Boxes move in edit mode, except while a line is being drawn — then a
  /// click is picking the line's endpoints, not grabbing a box.
  bool get _canDrag => _editMode && !_linkMode;

  /// The canvas only grows right and down, so a box can't be pushed past the
  /// origin where it would be clipped.
  static Offset _clamped(Offset p) =>
      Offset(math.max(0, p.dx), math.max(0, p.dy));

  /// The model as it should be drawn right now: the box under the cursor sits
  /// at its dragged spot, so it AND the lines attached to it follow live while
  /// the provider stays untouched until release.
  SchematicModel _withDragPreview(SchematicModel model) {
    final id = _dragNodeId;
    if (id == null || _dragOffset == Offset.zero) return model;

    final nodes = [
      for (final n in model.nodes)
        n.id == id ? n.movedTo(_clamped(n.pos + _dragOffset)) : n,
    ];
    double maxX = model.canvasSize.width, maxY = model.canvasSize.height;
    for (final n in nodes) {
      maxX = math.max(maxX, n.pos.dx + kNodeWidth + 30);
      maxY = math.max(maxY, n.pos.dy + kNodeHeight + 30);
    }
    return SchematicModel(nodes, model.edges, Size(maxX, maxY), model.roomTitle,
        model.hiddenEdges);
  }

  /// [startPos] is captured here rather than read back on release: by then
  /// the model the view holds is the PREVIEW, whose position already includes
  /// the drag, and committing from that would apply the offset twice.
  void _onNodeDragStart(String nodeId, Offset startPos) {
    setState(() {
      _dragNodeId = nodeId;
      _dragStartPos = startPos;
      _dragOffset = Offset.zero;
    });
  }

  void _onNodeDragUpdate(Offset delta) {
    // delta is already in canvas coordinates — the GestureDetector lives
    // inside the InteractiveViewer transform.
    setState(() => _dragOffset += delta);
  }

  void _onNodeDragEnd(AppStateProvider provider) {
    final id = _dragNodeId;
    final offset = _dragOffset;
    final startPos = _dragStartPos;
    setState(() {
      _dragNodeId = null;
      _dragOffset = Offset.zero;
    });
    if (id == null || offset == Offset.zero) return;

    // Land clear of the other boxes: dropping one on top of another hides
    // both and makes the lines impossible to follow.
    final model = SchematicModel.build(provider);
    provider.setSchematicPosition(
      id,
      nonOverlappingPosition(
        desired: _clamped(startPos + offset),
        size: const Size(kNodeWidth, kNodeHeight),
        others: [
          for (final n in model.nodes)
            if (n.id != id)
              Rect.fromLTWH(n.pos.dx, n.pos.dy, kNodeWidth, kNodeHeight),
        ],
      ),
    );
  }

  /// Edit-mode line list: EVERY line on the diagram — auto-generated and
  /// user-drawn — with edit + delete on each row. Editing an auto line
  /// converts it to a user line (so its route/color/label become editable);
  /// deleted auto lines stay listed grayed-out with a restore button.
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
      // The height belongs to the [BottomPane] this sits in, so it can be
      // dragged; the panel itself fills whatever it is given.
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: ListView(
        children: [
          Text(
            'Drag boxes to rearrange. "Draw Line" + tap two boxes adds a '
            'line. Edit any line below to re-route or recolor it (editing an '
            'auto line makes it yours); deleted auto lines can be restored. '
            '"Add device" draws equipment the control system does not talk to.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          // The hand-added boxes first: they are the only ones on the diagram
          // that exist nowhere else, so this list is the only place they can
          // be renamed or taken off again.
          for (final node in model.nodes.where((n) => n.related))
            Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Icon(node.icon, size: 18, color: kRelatedNodeColor),
                ),
                Expanded(
                  child: Text(
                    node.subtitle.isEmpty
                        ? node.title
                        : '${node.title}   (${node.subtitle})',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(kRelatedLegendLabel, style: theme.textTheme.bodySmall),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: 'Rename this device or change its icon',
                  onPressed: () => _showRelatedDeviceDialog(
                    provider,
                    index: node.relatedIndex,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: 'Remove this device and the lines drawn to it',
                  onPressed: () =>
                      provider.removeSchematicExtraNodeAt(node.relatedIndex),
                ),
              ],
            ),
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

/// How tall [_Legend] is, so the canvas can reserve room for it beneath the
/// diagram. An estimate: one row per connection type — plus the related-
/// equipment row when the drawing has any — and the container's own padding.
/// Over-shooting just leaves a little blank canvas.
double legendHeight(bool hasRelated) =>
    16 + (ConnType.values.length + (hasRelated ? 1 : 0)) * 18.0;

/// One device/processor/IDF box.
class _NodeBox extends StatelessWidget {
  final SchematicNode node;

  /// Resolved through the room's palette by the canvas, so a recolored
  /// category moves its boxes as well as its lines.
  final Color connColor;
  final bool highlighted;
  final bool editMode;

  /// This box is the one under the cursor: it lifts off the page a little so
  /// it reads as picked up.
  final bool dragging;

  const _NodeBox(
      {required this.node,
      required this.connColor,
      required this.highlighted,
      required this.editMode,
      this.dragging = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connColor = this.connColor;
    final edgeColor = (highlighted || dragging)
        ? theme.colorScheme.primary
        : connColor;
    final edgeWidth = highlighted ? 3.0 : (dragging ? 2.4 : 1.6);
    return Container(
      width: kNodeWidth,
      height: kNodeHeight,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(8),
        // A related box is outlined in dashes by the painter below instead —
        // a solid border here would draw underneath them.
        border: node.related
            ? null
            : Border.all(color: edgeColor, width: edgeWidth),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dragging ? 0.4 : 0.25),
            blurRadius: dragging ? 11 : 4,
            offset: Offset(1, dragging ? 5 : 2),
          ),
        ],
      ),
      foregroundDecoration: node.related
          ? _DashedBorderDecoration(color: edgeColor, width: edgeWidth)
          : null,
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

/// The dashed outline round a hand-added box.
///
/// A [Decoration] rather than a wrapping CustomPaint so it lays over the box's
/// own rounded rectangle exactly, at the same radius, whatever the box is
/// doing (highlighted for a line, lifted while dragged).
class _DashedBorderDecoration extends Decoration {
  final Color color;
  final double width;

  const _DashedBorderDecoration({required this.color, required this.width});

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _DashedBorderPainter(color, width);
}

class _DashedBorderPainter extends BoxPainter {
  final Color color;
  final double width;

  _DashedBorderPainter(this.color, this.width);

  /// Dash and gap, in logical pixels. Long enough to read as deliberate at the
  /// zoom a whole room is looked at, short enough to stay a rectangle.
  static const double _dash = 6;
  static const double _gap = 4;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration cfg) {
    final size = cfg.size;
    if (size == null) return;
    final rect = RRect.fromRectAndRadius(
      (offset & size).deflate(width / 2),
      const Radius.circular(8),
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;

    for (final metric in (Path()..addRRect(rect)).computeMetrics()) {
      double at = 0;
      while (at < metric.length) {
        final end = math.min(at + _dash, metric.length);
        canvas.drawPath(metric.extractPath(at, end), paint);
        at = end + _gap;
      }
    }
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
/// Node boxes inflated into obstacles — what lines bend around and what
/// labels keep clear of.
Map<String, Rect> schematicNodeRects(SchematicModel model) => {
      for (final n in model.nodes)
        n.id: Rect.fromLTWH(n.pos.dx, n.pos.dy, kNodeWidth, kNodeHeight)
            .inflate(6),
    };

/// The control point a line bends through to get around a box in its way, or
/// null when the straight run is clear.
///
/// Extracted from the painter so the canvas can work out how far down the
/// drawing actually reaches — the legend sits below all of it, and a curve
/// swinging around a box can dip lower than any box.
Offset? schematicEdgeControl(
  SchematicModel model,
  SchematicEdge edge,
  Map<String, Rect> nodeRects,
) {
  final from = model.nodeById(edge.fromId);
  final to = model.nodeById(edge.toId);
  if (from == null || to == null) return null;
  final a = from.center;
  final b = to.center;

  Rect? blocked;
  for (final entry in nodeRects.entries) {
    if (entry.key == edge.fromId || entry.key == edge.toId) continue;
    if (_EdgePainter._segmentHitsRect(a, b, entry.value)) {
      blocked = entry.value;
      break;
    }
  }
  if (blocked == null) return null;

  final mid = Offset.lerp(a, b, 0.5)!;
  final dir = b - a;
  final len = dir.distance;
  if (len <= 1) return null;

  Offset perp = Offset(-dir.dy / len, dir.dx / len);
  if ((blocked.center - mid).dx * perp.dx +
          (blocked.center - mid).dy * perp.dy >
      0) {
    perp = -perp; // push away from the obstacle, not into it
  }
  return mid + perp * (kNodeHeight * 2.4);
}

/// The lowest point anything drawn reaches: boxes, straight lines, and the
/// curves that bend around them.
double schematicContentBottom(SchematicModel model) {
  double bottom = 0;
  for (final n in model.nodes) {
    bottom = math.max(bottom, n.pos.dy + kNodeHeight);
  }

  final rects = schematicNodeRects(model);
  for (final edge in model.edges) {
    final from = model.nodeById(edge.fromId);
    final to = model.nodeById(edge.toId);
    if (from == null || to == null) continue;
    final a = from.center;
    final b = to.center;
    final control = schematicEdgeControl(model, edge, rects);
    if (control == null) {
      bottom = math.max(bottom, math.max(a.dy, b.dy));
      continue;
    }
    // Sample the curve rather than solving it — nine points is plenty for
    // deciding where a legend goes.
    for (int i = 0; i <= 8; i++) {
      bottom = math.max(
          bottom, _EdgePainter._bezier(a, control, b, i / 8).dy);
    }
  }
  return bottom;
}

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
    final Map<String, Rect> nodeRects = schematicNodeRects(model);

    // --- PASS 1: lines (collect each edge's label-anchor curve) ------------
    final List<(SchematicEdge, Offset, Offset?, Offset)> labeled = [];
    for (final edge in model.edges) {
      final from = model.nodeById(edge.fromId);
      final to = model.nodeById(edge.toId);
      if (from == null || to == null) continue;
      final a = from.center;
      final b = to.center;

      final paint = Paint()
        ..color = edge.color
        ..strokeWidth = edge.width
        ..style = PaintingStyle.stroke;

      // Curve around any box in the way, bending away from its center far
      // enough that the apex clears it whichever way the line grazes.
      final Offset? control = schematicEdgeControl(model, edge, nodeRects);
      if (control != null) {
        canvas.drawPath(
          Path()
            ..moveTo(a.dx, a.dy)
            ..quadraticBezierTo(control.dx, control.dy, b.dx, b.dy),
          paint,
        );
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

  /// The room's line colors, so the key matches what is drawn.
  final AppStateProvider provider;

  /// Whether the drawing carries any hand-added boxes. The row is only printed
  /// when there is something on the page it explains.
  final bool hasRelated;

  const _Legend({
    required this.theme,
    required this.provider,
    this.hasRelated = false,
  });

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
                      width: 22, height: 3.5, color: connColor(conn, provider)),
                  const SizedBox(width: 8),
                  Text(kConnLabels[conn]!,
                      style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
          // The dashed box, explained in the same words the edit panel uses.
          if (hasRelated)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 22,
                    height: 12,
                    child: CustomPaint(
                      painter: _DashedSpecimenPainter(kRelatedNodeColor),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(kRelatedLegendLabel,
                      style: TextStyle(fontSize: 11)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// What the dashed box means, in one line — used by the legend and by the
/// report section, so the drawing and the paperwork say the same thing.
const String kRelatedLegendLabel = 'Related equipment (not controlled)';

/// A little dashed rectangle, so the legend row looks like what it explains.
class _DashedSpecimenPainter extends CustomPainter {
  final Color color;

  _DashedSpecimenPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.7, 1.7, size.width - 1.4, size.height - 3.4),
      const Radius.circular(2),
    );
    for (final metric in (Path()..addRRect(rect)).computeMetrics()) {
      double at = 0;
      while (at < metric.length) {
        final end = math.min(at + 3.0, metric.length);
        canvas.drawPath(metric.extractPath(at, end), paint);
        at = end + 2.0;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedSpecimenPainter old) => old.color != color;
}

// ============================================================================
//  DEVICE REPORT
// ============================================================================
//  Report content lives outside the widget: [reportSections] is a pure
//  function of the loaded config plus the schematic (which supplies the
//  connection list and the dev_-count-filtered device set), so the .xlsx, the
//  .txt and the clipboard copy all render the same thing — and it can be
//  tested without pumping a widget.

//  [ReportSection], the fixed-width text renderer and the banded .xlsx sheet
//  builder are shared with the AV Flow tab — see report_tools.dart.

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

/// How an outlet's reboot capability reads in the report. Blank when the room
/// carries neither key, so a config without the settings shows an empty cell
/// rather than asserting something about the hardware.
String _rebootLabel(dynamic supportsReboot, dynamic rebootOnly) {
  if (supportsReboot == null && rebootOnly == null) return '';
  if (rebootOnly == true) return 'Reboot only';
  if (supportsReboot == true) return 'Reboot supported';
  return 'No reboot';
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

  // Which ControlScript build the processor runs ('pro'/'xi'). Every converted
  // room carries it, but a report is also run on files that predate the key,
  // so the row drops out rather than printing a blank when it isn't there.
  final String controlScript = (env is Map)
      ? provider.uiSchema.optionLabelFor(
          'controlscript_profile',
          env['controlscript_profile']?.toString() ?? '',
          sectionKey: 'ENVIRONMENT',
        )
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
    ['ControlScript Profile', controlScript],
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
  // An outlet is `power1_outlet_<N>` and nothing more. Matching on the prefix
  // alone swept up its companions — `_supports_reboot` / `_reboot_only` —
  // each of which would have reported as its own nameless "Outlet 0" row,
  // since neither ends in the outlet's number.
  final outletPattern = RegExp(r'^power1_outlet_\d+$');
  final outletKeys = setup.keys
      .where((k) =>
          outletPattern.hasMatch(k) && _friendlyValue(setup[k]).isNotEmpty)
      .toList()
    ..sort((a, b) => outletNumber(a).compareTo(outletNumber(b)));
  final powerRows = <List<dynamic>>[
    for (final k in outletKeys)
      [
        'Outlet ${outletNumber(k)}',
        _friendlyValue(setup[k]),
        // Blank rather than "false" when the key is absent, so a room without
        // the reboot settings reports an empty cell instead of a claim.
        _rebootLabel(setup['${k}_supports_reboot'], setup['${k}_reboot_only']),
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

  // --- Related equipment (the hand-added boxes) ---
  // Its own section rather than extra rows on Devices: that table is what the
  // control system drives, and every column on it — IP, protocol, port,
  // module — is a question about a device the processor talks to. A switch
  // the room depends on belongs on the paperwork, but not as a controlled
  // device with eight blank columns.
  final relatedRows = <List<dynamic>>[
    for (final node in model.nodes)
      if (node.related)
        [
          node.title,
          node.subtitle,
          // What it is joined to on the diagram, which is the reason it is
          // drawn at all.
          [
            for (final e in model.edges)
              if (e.fromId == node.id)
                model.nodeById(e.toId)?.title ?? e.toId
              else if (e.toId == node.id)
                model.nodeById(e.fromId)?.title ?? e.fromId,
          ].join(', '),
        ]
  ];

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
      header: ['Outlet', 'Name', 'Reboot'],
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
      title: 'Related Equipment',
      header: ['Name', 'Detail', 'Connected To'],
      rows: relatedRows
    ),
    (
      title: 'Connections',
      header: ['From', 'To', 'Kind', 'Label'],
      rows: connectionRows
    ),
  ].where((s) => s.rows.isNotEmpty).toList();
}
