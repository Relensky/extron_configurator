import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'av_flow_report.dart' show cablingSections;
import 'av_flow_view.dart' show buildAvFlowModel;
import 'av_port_editor.dart' show avRowIcon;
import 'cabling_schematic.dart';
import 'diagram_capture.dart';
import 'export_tools.dart';
import 'report_tools.dart';
import 'screenshot_tools.dart';
import 'view_zoom.dart';

/// ============================================================================
///  CABLING TAB
/// ============================================================================
///  The one-line drawing the trades are handed: boxes for the places in the
///  room, pull boxes for the junctions cable routes through, and between them
///  a bundle labelled with what runs and how much of it, ending at the pathway
///  back to the telecom room.
///
///  It draws itself from the room and is then edited by hand — see
///  cabling_schematic.dart for why those are kept apart. What that means here:
///  dragging a box, renaming it, typing a different count and adding a run all
///  work, and none of them stop the counts following the signal flow when the
///  room is re-cabled. A count that HAS been typed over is badged, so the one
///  place the drawing and the room disagree is visible on the drawing.
/// ============================================================================

class CablingView extends StatefulWidget {
  const CablingView({super.key});

  @override
  State<CablingView> createState() => _CablingViewState();
}

class _CablingViewState extends State<CablingView> {
  final GlobalKey _canvasKey = GlobalKey();
  final GlobalKey _viewportKey = GlobalKey();
  final TransformationController _transform = TransformationController();

  String _selectedId = '';

  /// The box a new run is being drawn from, or '' when not drawing one.
  String _runFrom = '';

  @override
  void initState() {
    super.initState();
    registerDiagramCanvas(AppTab.cabling, _canvasKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppStateProvider>().ensureAvFlowForCurrentConfig();
    });
  }

  @override
  void dispose() {
    unregisterDiagramCanvas(AppTab.cabling, _canvasKey);
    _transform.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    if (provider.roomConfig.isEmpty) {
      return const Center(child: Text('No configuration loaded.'));
    }
    final model = buildAvFlowModel(provider);
    final drawing = provider.cablingSchematic(model);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _toolbar(provider, drawing),
        const Divider(height: 1),
        Expanded(
          key: _viewportKey,
          child: drawing.boxes.isEmpty
              ? _emptyState(provider)
              : InteractiveViewer(
                  transformationController: _transform,
                  constrained: false,
                  minScale: 0.15,
                  maxScale: 3.0,
                  boundaryMargin: const EdgeInsets.all(300),
                  child: RepaintBoundary(
                    key: _canvasKey,
                    child: _canvas(provider, drawing),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _emptyState(AppStateProvider provider) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.account_tree_outlined,
            size: 48,
            color: Theme.of(context).disabledColor,
          ),
          const SizedBox(height: 12),
          const Text('Nothing to draw yet.'),
          const SizedBox(height: 6),
          Text(
            'This drawing builds itself from where things are: name the places '
            'in the room on the Locations panel, say which place each device '
            'is in, and the boxes and the bundles between them appear here '
            'with the runs counted off the signal flow. Pull boxes are '
            'locations too — add one with the zone set to Pull box, or drop a '
            'plain box on here and wire it up by hand.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            icon: const Icon(Icons.add_box_outlined, size: 18),
            label: const Text('Add a pull box'),
            onPressed: () => provider.addCablingBox(
              kind: CablingBoxKind.pullBox,
              label: 'Pull box',
            ),
          ),
        ],
      ),
    ),
  );

  // --- toolbar --------------------------------------------------------------

  Widget _toolbar(AppStateProvider provider, CablingSchematic drawing) {
    final theme = Theme.of(context);
    final selectedBox = drawing.boxById(_selectedId);
    final selectedBundle = drawing.bundles
        .where((b) => b.id == _selectedId)
        .firstOrNull;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('Cabling', style: theme.textTheme.titleLarge),
          const SizedBox(width: 4),
          for (final kind in const [
            CablingBoxKind.pullBox,
            CablingBoxKind.location,
            CablingBoxKind.pathway,
            CablingBoxKind.note,
          ])
            OutlinedButton.icon(
              icon: Icon(
                switch (kind) {
                  CablingBoxKind.pullBox => Icons.add_box_outlined,
                  CablingBoxKind.location => Icons.crop_square,
                  CablingBoxKind.pathway => Icons.swap_vert,
                  CablingBoxKind.note => Icons.sticky_note_2_outlined,
                },
                size: 18,
              ),
              label: Text(kCablingBoxKindLabels[kind]!),
              onPressed: () {
                final box = provider.addCablingBox(kind: kind);
                setState(() => _selectedId = box.id);
              },
            ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.fit_screen, size: 18),
            label: const Text('Fit to view'),
            onPressed: () => fitToViewport(
              controller: _transform,
              contentKey: _canvasKey,
              viewportKey: _viewportKey,
            ),
          ),
          // The drawing is what the trades are handed; the schedule under it
          // is the same thing in a form somebody can price and order against.
          // Both come off this page rather than only out of Save All.
          OutlinedButton.icon(
            icon: const Icon(Icons.image_outlined, size: 18),
            label: const Text('Export PNG'),
            onPressed: () => _exportPng(provider),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.description_outlined, size: 18),
            label: const Text('Run schedule'),
            onPressed: () => _exportReport(provider),
          ),
          if (!provider.avCabling.isEmpty)
            TextButton.icon(
              icon: const Icon(Icons.restart_alt, size: 16),
              label: const Text('Reset to the room'),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Reset the drawing?'),
                    content: const Text(
                      'Every box you moved, every label and count you typed '
                      'and everything you added by hand goes, and the drawing '
                      'goes back to exactly what the room says.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text(
                          'Reset',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  provider.resetCablingSchematic();
                  setState(() => _selectedId = '');
                }
              },
            ),
          if (_runFrom.isNotEmpty)
            Chip(
              avatar: const Icon(Icons.timeline, size: 16),
              label: Text(
                'Drawing a run from '
                '${drawing.boxById(_runFrom)?.label ?? _runFrom}'
                ' — click the other box',
              ),
              onDeleted: () => setState(() => _runFrom = ''),
            ),
          if (selectedBox != null) ..._boxActions(provider, selectedBox),
          if (selectedBundle != null)
            ..._bundleActions(provider, drawing, selectedBundle),
          if (drawing.overridden.isNotEmpty)
            Tooltip(
              message: 'Typed over what the room worked out. The badge is on '
                  'the drawing so the disagreement is visible.',
              child: Chip(
                avatar: const Icon(Icons.edit_note, size: 16),
                label: Text('${drawing.overridden.length} edited'),
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _boxActions(AppStateProvider provider, CablingBox box) => [
    TextButton.icon(
      icon: const Icon(Icons.drive_file_rename_outline, size: 16),
      label: const Text('Rename'),
      onPressed: () async {
        final name = await _askFor('Box name', box.label);
        if (name != null) provider.setCablingBoxLabel(box.id, name);
      },
    ),
    TextButton.icon(
      icon: const Icon(Icons.notes, size: 16),
      label: Text(box.body.trim().isEmpty ? 'Add text' : 'Edit text'),
      onPressed: () async {
        final body = await _askFor('Text', box.body, lines: 8);
        if (body != null) provider.setCablingBoxBody(box.id, body);
      },
    ),
    TextButton.icon(
      icon: const Icon(Icons.timeline, size: 16),
      label: const Text('Draw a run'),
      onPressed: () => setState(() => _runFrom = box.id),
    ),
    avRowIcon(
      Icons.delete_outline,
      box.isDerived
          ? 'Take it off the drawing (the room keeps the location)'
          : 'Delete this box',
      () {
        provider.removeCablingItem(box.id);
        setState(() => _selectedId = '');
      },
      danger: true,
    ),
  ];

  List<Widget> _bundleActions(
    AppStateProvider provider,
    CablingSchematic drawing,
    CablingBundle bundle,
  ) => [
    Text(
      bundle.label,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
    TextButton.icon(
      icon: const Icon(Icons.tag, size: 16),
      label: const Text('Count'),
      onPressed: () async {
        final v = await _askFor('How many cables', bundle.count
            .toStringAsFixed(0));
        if (v == null) return;
        provider.setCablingBundleCount(bundle.id, double.tryParse(v.trim()));
      },
    ),
    TextButton.icon(
      icon: const Icon(Icons.cable, size: 16),
      label: const Text('Type'),
      onPressed: () async {
        final v = await _askFor('Cable type', bundle.cableType);
        if (v != null) provider.setCablingBundleType(bundle.id, v);
      },
    ),
    if (drawing.overridden.contains(bundle.id))
      TextButton.icon(
        icon: const Icon(Icons.restart_alt, size: 16),
        label: const Text('Back to the counted figure'),
        onPressed: () {
          provider.setCablingBundleCount(bundle.id, null);
          provider.setCablingBundleType(bundle.id, null);
        },
      ),
    avRowIcon(
      Icons.delete_outline,
      'Take this run off the drawing',
      () {
        provider.removeCablingItem(bundle.id);
        setState(() => _selectedId = '');
      },
      danger: true,
    ),
  ];

  Future<void> _exportPng(AppStateProvider provider) async {
    final bytes = await captureBoundary(_canvasKey, pixelRatio: 2.0);
    if (bytes == null) {
      _snack('Could not render the cabling drawing to an image.');
      return;
    }
    String? out = await FilePicker.saveFile(
      dialogTitle: 'Save the cabling drawing',
      fileName: '${roomFileStem(provider, 'cabling')}.png',
      type: FileType.custom,
      allowedExtensions: const ['png'],
    );
    if (out == null) return;
    if (!out.toLowerCase().endsWith('.png')) out += '.png';
    try {
      await File(out).writeAsBytes(bytes);
      _snack('Cabling drawing saved as $out');
    } catch (e) {
      _snack('Failed to save the image: $e');
    }
  }

  Future<void> _exportReport(AppStateProvider provider) async {
    final model = buildAvFlowModel(provider);
    final sections = cablingSections(model);
    if (sections.isEmpty) {
      _snack('Nothing to report yet — the drawing is empty.');
      return;
    }
    String? out = await FilePicker.saveFile(
      dialogTitle: 'Save the cable run schedule',
      fileName: '${roomFileStem(provider, 'cabling')}.txt',
      type: FileType.custom,
      allowedExtensions: const ['txt'],
    );
    if (out == null) return;
    if (!out.toLowerCase().endsWith('.txt')) out += '.txt';
    try {
      await File(out).writeAsString(
        renderTextReport(
          model.roomTitle.isEmpty ? 'Cabling' : model.roomTitle,
          sections,
        ),
      );
      _snack('Cable run schedule saved as $out');
    } catch (e) {
      _snack('Failed to save the schedule: $e');
    }
  }

  Future<String?> _askFor(String label, String initial, {int lines = 1}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 1,
            maxLines: lines,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // --- the drawing ----------------------------------------------------------

  Size _canvasSize(CablingSchematic drawing) {
    var w = 1200.0;
    var h = 700.0;
    for (final b in drawing.boxes) {
      w = w > b.rect.right + 80 ? w : b.rect.right + 80;
      h = h > b.rect.bottom + 80 ? h : b.rect.bottom + 80;
    }
    return Size(w, h);
  }

  Widget _canvas(AppStateProvider provider, CablingSchematic drawing) {
    final size = _canvasSize(drawing);
    final theme = Theme.of(context);
    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          Container(
            width: size.width,
            height: size.height,
            color: theme.brightness == Brightness.dark
                ? const Color(0xFF14181C)
                : Colors.white,
          ),
          // The runs go under the boxes so a bundle disappears behind the box
          // it lands on rather than crossing over the label.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _BundlePainter(
                  drawing: drawing,
                  selectedId: _selectedId,
                  overridden: drawing.overridden,
                  dark: theme.brightness == Brightness.dark,
                ),
              ),
            ),
          ),
          for (final bundle in drawing.bundles)
            _bundleHitTarget(drawing, bundle),
          for (final box in drawing.boxes) _box(provider, drawing, box),
        ],
      ),
    );
  }

  /// A small pad at the middle of a run, so a line can be clicked without
  /// hit-testing the whole canvas.
  Widget _bundleHitTarget(CablingSchematic drawing, CablingBundle bundle) {
    final from = drawing.boxById(bundle.fromBoxId);
    final to = drawing.boxById(bundle.toBoxId);
    if (from == null || to == null) return const SizedBox.shrink();
    final mid = (from.rect.center + to.rect.center) / 2;
    return Positioned(
      left: mid.dx - 26,
      top: mid.dy - 14,
      width: 52,
      height: 28,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _selectedId = bundle.id),
        child: const SizedBox.expand(),
      ),
    );
  }

  Widget _box(
    AppStateProvider provider,
    CablingSchematic drawing,
    CablingBox box,
  ) {
    final theme = Theme.of(context);
    final selected = box.id == _selectedId;
    final isNote = box.kind == CablingBoxKind.note;
    final isPathway = box.kind == CablingBoxKind.pathway;

    return Positioned(
      left: box.pos.dx,
      top: box.pos.dy,
      width: box.size.width,
      height: box.size.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_runFrom.isNotEmpty && _runFrom != box.id) {
            final added = provider.addCablingBundle(
              fromBoxId: _runFrom,
              toBoxId: box.id,
              cableType: 'Cat 6a',
            );
            setState(() {
              _runFrom = '';
              _selectedId = added?.id ?? '';
            });
            if (added != null) {
              _snack('Run added — set its count and type in the toolbar.');
            }
            return;
          }
          setState(() => _selectedId = box.id);
        },
        onPanUpdate: (d) => provider.setCablingBoxPosition(
          box.id,
          box.pos + d.delta,
          recordUndo: false,
        ),
        onPanEnd: (_) =>
            provider.setCablingBoxPosition(box.id, box.pos, recordUndo: true),
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Container(
            decoration: BoxDecoration(
              color: isNote
                  ? (theme.brightness == Brightness.dark
                        ? const Color(0xFF1B2026)
                        : const Color(0xFFFAFAFA))
                  : (theme.brightness == Brightness.dark
                        ? const Color(0xFF2A3038)
                        : const Color(0xFFDDDDDD)),
              border: Border.all(
                color: selected
                    ? theme.colorScheme.primary
                    : (theme.brightness == Brightness.dark
                          ? const Color(0xFF3A424C)
                          : const Color(0xFF9E9E9E)),
                width: selected ? 2.5 : 1.2,
              ),
              borderRadius: BorderRadius.circular(isPathway ? 3 : 4),
            ),
            padding: const EdgeInsets.all(8),
            child: isPathway
                ? const RotatedBox(
                    quarterTurns: 3,
                    child: Center(
                      child: Text(
                        'Network Pathway back to TR',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          fontStyle: FontStyle.italic,
                        ),
                        maxLines: 1,
                      ),
                    ),
                  )
                : Column(
                    crossAxisAlignment: isNote
                        ? CrossAxisAlignment.start
                        : CrossAxisAlignment.center,
                    mainAxisAlignment: isNote
                        ? MainAxisAlignment.start
                        : MainAxisAlignment.center,
                    children: [
                      Text(
                        box.label,
                        textAlign: isNote ? TextAlign.left : TextAlign.center,
                        style: TextStyle(
                          fontSize: isNote ? 13 : 12.5,
                          fontWeight: FontWeight.w600,
                          color: theme.brightness == Brightness.dark
                              ? Colors.white
                              : Colors.black87,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (box.body.trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Expanded(
                          child: Text(
                            box.body,
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.brightness == Brightness.dark
                                  ? Colors.white70
                                  : Colors.black87,
                              height: 1.35,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 14,
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// Draws the bundles and their labels.
class _BundlePainter extends CustomPainter {
  final CablingSchematic drawing;
  final String selectedId;
  final Set<String> overridden;
  final bool dark;

  const _BundlePainter({
    required this.drawing,
    required this.selectedId,
    required this.overridden,
    required this.dark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final bundle in drawing.bundles) {
      final from = drawing.boxById(bundle.fromBoxId);
      final to = drawing.boxById(bundle.toBoxId);
      if (from == null || to == null) continue;

      final a = from.rect.center;
      final b = to.rect.center;
      final selected = bundle.id == selectedId;
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = Color(bundle.color)
          ..strokeWidth = selected ? 4 : 2.4
          ..strokeCap = StrokeCap.round,
      );

      // "2x Cat 6a", set beside the middle of the run in the bold italic a
      // cabling drawing labels its bundles in.
      final edited = overridden.contains(bundle.id);
      final painter = TextPainter(
        text: TextSpan(
          text: '${bundle.label}${edited ? '  ✎' : ''}',
          style: TextStyle(
            color: dark ? Colors.white : Colors.black87,
            fontSize: 11.5,
            fontWeight: FontWeight.bold,
            fontStyle: FontStyle.italic,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final mid = (a + b) / 2;
      final at = Offset(mid.dx - painter.width / 2, mid.dy - painter.height - 4);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(at.dx, at.dy, painter.width, painter.height)
              .inflate(3),
          const Radius.circular(3),
        ),
        Paint()..color = dark ? const Color(0xE614181C) : const Color(0xE6FFFFFF),
      );
      painter.paint(canvas, at);
    }
  }

  @override
  bool shouldRepaint(_BundlePainter old) =>
      old.drawing != drawing ||
      old.selectedId != selectedId ||
      old.dark != dark;
}
