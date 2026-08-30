import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_flow_model.dart'
    show bendInsertIndex, kCableSwatches, latticeRoute, routeThrough;
import 'av_flow_report.dart' show cablingSections;
import 'av_flow_view.dart' show buildAvFlowModel;
import 'av_port_editor.dart' show avRowIcon;
import 'cabling_schematic.dart';
import 'color_wheel_picker.dart';
import 'diagram_capture.dart';
import 'cable_colors_dialog.dart';
import 'export_tools.dart';
import 'diagram_grid.dart';
import 'layout_tools.dart';
import 'live_text_field.dart';
import 'report_tools.dart';
import 'run_painting.dart';
import 'screenshot_tools.dart';
import 'view_zoom.dart';
import 'xlsx_writer.dart';

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

  /// Live drag, held HERE rather than written to the provider per pointer
  /// event — the same bargain the AV Flow canvas makes, and the reason this
  /// page's boxes used to stutter while that page's did not. A provider write
  /// per frame rebuilds every listener in the app, re-derives the whole
  /// drawing from the room and re-runs the lattice router for every run on the
  /// sheet, sixty times a second, for a gesture whose only real outcome is one
  /// position at the end of it.
  ///
  /// So the box is drawn under the cursor and the position is committed once,
  /// on release. [kCablingKeyId] is a legitimate value: the key panel is
  /// dragged on exactly the same terms.
  String _dragId = '';
  Offset _dragOffset = Offset.zero;

  /// Which cable type the drawing is showing, or '' for all of them.
  ///
  /// Only ever set while an export is walking the layers — the sheet on screen
  /// shows everything. It is here rather than local to the export because only
  /// a widget that is on screen can be rendered, so the way to get a picture
  /// of one layer is to make the canvas draw it and capture a frame.
  String _exportLayer = '';

  /// True while the drawing is being rendered the way it should PRINT — light
  /// theme, no colour. Held for the one frame a black-and-white export
  /// captures, then put back; see [printSkin].
  bool _printMode = false;

  /// Holds the keyboard for the drawing, so Delete removes what is selected
  /// and the arrows step between the runs on one edge. Taken when something is
  /// selected rather than on build, so the count and cable-type fields in the
  /// selection bar keep the caret.
  final FocusNode _canvasFocus = FocusNode(debugLabel: 'cabling drawing');

  /// The END being dragged: which run, which end of it, and where the pointer
  /// has it — in the same fractional coordinates the anchor is stored in.
  ///
  /// Local while the pointer is down for the reason the bend drag is: a write
  /// per pointer event re-routes every run on the sheet.
  String _endRunId = '';
  bool _endAtStart = true;
  Offset? _endFraction;

  /// The bend being dragged: which run, which of its bends, and how far it has
  /// come since the pointer went down.
  ///
  /// Held here rather than written to the provider per pointer event, which is
  /// what made routing a run feel like dragging through treacle: every move
  /// notified every listener, re-ran the router for every run on the sheet and
  /// re-laid out every caption. Now the drag is local and cheap, and the write
  /// — with its undo entry — happens once, on release.
  String _bendRunId = '';
  int _bendIndex = -1;
  Offset _bendDelta = Offset.zero;

  /// The caption being dragged, by edge key, and how far it has come since the
  /// pointer went down. Held here rather than written per frame: the label
  /// follows the cursor without a provider write, and the write happens once
  /// on release so one drag is one undo.
  String _labelDragKey = '';
  Offset _labelDrag = Offset.zero;

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
    _canvasFocus.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Selects [id] and takes the keyboard, so Delete and the arrows land on it.
  void _select(String id) {
    setState(() => _selectedId = id);
    if (id.isNotEmpty) _takeTheKeyboard();
  }

  /// Puts the keyboard back on the drawing AFTER the frame the click landed
  /// in, which is the only way it stays there.
  ///
  /// A text field dismisses itself when a click lands outside it, and the way
  /// it does that is `primaryFocus.unfocus()` — whoever is holding the focus
  /// at that moment, which by then is the drawing that just asked for it. So a
  /// straight `requestFocus()` here was granted and then immediately thrown
  /// away, and since every click went the same way the arrows were dead for
  /// the rest of the session the moment anybody typed a count. Asking a frame
  /// later is asking after the field has had its say.
  void _takeTheKeyboard() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _selectedId.isNotEmpty) _canvasFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    if (provider.roomConfig.isEmpty) {
      return const Center(child: Text('No configuration loaded.'));
    }
    final model = buildAvFlowModel(provider);
    final drawing = _asDrawn(provider, provider.cablingSchematic(model));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _toolbar(provider, drawing),
        // What is selected, and what can be done to it. Its own row under the
        // toolbar rather than more chips on the end of it: the toolbar is
        // already long enough to wrap, and "set the count in the toolbar" is
        // useless advice when the controls have wrapped off the bottom of a
        // row nobody was looking at.
        ..._selectionBar(provider, drawing),
        const Divider(height: 1),
        Expanded(
          key: _viewportKey,
          child: drawing.boxes.isEmpty
              ? _emptyState(provider)
              : Focus(
                  focusNode: _canvasFocus,
                  onKeyEvent: (_, event) =>
                      _onCanvasKey(provider, drawing, event),
                  // ANY touch of the sheet puts the keyboard back on it.
                  //
                  // Selecting used to be the only thing that did, and a click
                  // does not always reach the thing that selects: once a run
                  // is picked, its own bend handles sit over the middle of it,
                  // so clicking the run again lands on a handle and selects
                  // nothing. Type a count, click back on the wire, and the
                  // arrows stayed dead — with no way left on the page to
                  // revive them. Listening for the pointer instead means the
                  // keyboard comes back wherever on the drawing the click
                  // lands.
                  child: Listener(
                    onPointerDown: (_) {
                      if (_selectedId.isNotEmpty) _takeTheKeyboard();
                    },
                    child: InteractiveViewer(
                      transformationController: _transform,
                      constrained: false,
                      minScale: 0.15,
                      maxScale: 3.0,
                      boundaryMargin: const EdgeInsets.all(300),
                      child: RepaintBoundary(
                        key: _canvasKey,
                        // Inside the boundary, so the black-and-white export
                        // captures exactly what it draws — see [printSkin].
                        child: printSkin(
                          enabled: _printMode,
                          child: Builder(
                            builder: (ctx) => _canvas(ctx, provider, drawing),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// The drawing as it should be shown RIGHT NOW: what the room says, with a
  /// box being dragged shown under the cursor and — while an export is walking
  /// the layers — only the cable being exported on it.
  ///
  /// Its real position is written back on release, so the runs follow the box
  /// live without a provider write per pointer event.
  CablingSchematic _asDrawn(
      AppStateProvider provider, CablingSchematic drawing) {
    final dragging = _dragId.isNotEmpty &&
        _dragOffset != Offset.zero &&
        _dragId != kCablingKeyId;
    if (!dragging && _exportLayer.isEmpty) return drawing;

    return CablingSchematic(
      boxes: [
        for (final b in drawing.boxes)
          if (dragging && b.id == _dragId)
            b.copyWith(
                pos: _snapped(provider, _clamped(b.pos + _dragOffset)))
          else
            b,
      ],
      bundles: _exportLayer.isEmpty
          ? drawing.bundles
          : [
              for (final b in drawing.bundles)
                if (b.cableType == _exportLayer) b,
            ],
      overridden: drawing.overridden,
    );
  }

  /// The sheet only grows right and down, so a box cannot be dragged past the
  /// origin where it would be clipped out of the export.
  static Offset _clamped(Offset p) =>
      Offset(p.dx < 0 ? 0 : p.dx, p.dy < 0 ? 0 : p.dy);

  /// A dragged box's position, on the grid when the setting is on. The preview
  /// and the drop both go through here, so the box lands where it was shown.
  Offset _snapped(AppStateProvider provider, Offset p) =>
      snapToGrid(p, enabled: provider.snapDiagramsToGrid);

  // --- the keyboard ---------------------------------------------------------

  /// Delete removes what is selected; the arrows step between the runs sharing
  /// an edge.
  ///
  /// The arrows are here because a bundle of six runs between two places is
  /// six lines thirteen pixels apart, and picking the fourth one with a mouse
  /// is a game. Selecting any of them and pressing Down walks the stack in
  /// drawing order, which is the order the captions are printed in, so what is
  /// selected can be followed in the label block rather than on the wire.
  KeyEventResult _onCanvasKey(
    AppStateProvider provider,
    CablingSchematic drawing,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent || _selectedId.isEmpty) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      _deleteSelection(provider, drawing);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _selectedId = '';
        _runFrom = '';
      });
      return KeyEventResult.handled;
    }

    final forward = key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowRight;
    final back = key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowLeft;
    if (!forward && !back) return KeyEventResult.ignored;

    return _stepRun(drawing, forward: forward)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  /// Moves the selection one run along the stack the selected run is in, and
  /// says which one it landed on. False when there is nothing to step.
  ///
  /// The arrows and the two buttons in the selection bar both come here, so
  /// what the keyboard does and what the buttons do cannot drift apart.
  bool _stepRun(CablingSchematic drawing, {required bool forward}) {
    final bundle = drawing.bundles
        .where((b) => b.id == _selectedId)
        .firstOrNull;
    if (bundle == null) return false;

    final siblings = drawing.bundlesBetween(bundle.fromBoxId, bundle.toBoxId);
    if (siblings.length < 2) return false;
    final at = siblings.indexWhere((b) => b.id == bundle.id);
    // Wraps, so a stack of runs can be walked round without having to know
    // which end of it you are at.
    final next =
        (at + (forward ? 1 : -1) + siblings.length) % siblings.length;
    setState(() => _selectedId = siblings[next].id);
    _snack(
      '${siblings[next].label} - run ${next + 1} of ${siblings.length} '
      'between these two',
    );
    return true;
  }

  /// Takes the selected box or run off the drawing.
  ///
  /// A DERIVED item is hidden rather than deleted; see
  /// [AppStateProvider.removeCablingItem] for why deleting one would only
  /// bring it back on the next rebuild.
  void _deleteSelection(AppStateProvider provider, CablingSchematic drawing) {
    final id = _selectedId;
    if (id.isEmpty) return;
    final box = drawing.boxById(id);
    final what = box?.label ??
        drawing.bundles.where((b) => b.id == id).firstOrNull?.label ??
        'it';
    provider.removeCablingItem(id);
    setState(() {
      _selectedId = '';
      if (_runFrom == id) _runFrom = '';
    });
    _snack('$what taken off the drawing - Undo puts it back.');
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
            'locations too - add one with the zone set to Pull box, or drop a '
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
                  CablingBoxKind.device => Icons.developer_board,
                },
                size: 18,
              ),
              label: Text(kCablingBoxKindLabels[kind]!),
              onPressed: () => _select(
                provider
                    .addCablingBox(
                      kind: kind,
                      occupied: _occupied(provider, drawing),
                    )
                    .id,
              ),
            ),
          // The gear itself, drawn the way the schematic draws it, so a run
          // can be pulled to "the ceiling mic" rather than to a location code.
          OutlinedButton.icon(
            icon: const Icon(Icons.developer_board, size: 18),
            label: const Text('Device'),
            onPressed: () => _addDevice(provider, drawing),
          ),
          const SizedBox(width: 8),
          // The key is part of the drawing, not a view setting: it exports
          // with the PNG and it is what makes the colours mean anything. The
          // toggle is here for the rare sheet that carries its legend in the
          // title block instead.
          // Shared with the AV Flow and Schematic drawings — see
          // [AppStateProvider.snapDiagramsToGrid].
          FilterChip(
            key: const ValueKey('cabling_snap_to_grid'),
            avatar: const Icon(Icons.grid_4x4, size: 18),
            label: const Text('Snap to grid'),
            selected: provider.snapDiagramsToGrid,
            onSelected: (v) => provider.setSnapDiagramsToGrid(v),
          ),
          // Whether the sheet has squares on it. Never exported.
          FilterChip(
            key: const ValueKey('cabling_show_grid'),
            avatar: const Icon(Icons.grid_on, size: 18),
            label: const Text('Grid'),
            selected: provider.showDiagramGrid,
            onSelected: (v) => provider.setShowDiagramGrid(v),
          ),
          FilterChip(
            key: const ValueKey('cabling_key_toggle'),
            avatar: const Icon(Icons.legend_toggle, size: 18),
            label: const Text('Key'),
            selected: _keyShown(provider),
            onSelected: (on) => on
                ? provider.restoreCablingItem(kCablingKeyId)
                : provider.removeCablingItem(kCablingKeyId),
          ),
          // The labels themselves: how many are off the sheet, and the one
          // way back. A hidden caption cannot be right-clicked to un-hide
          // itself, so the way back cannot live on the drawing.
          Builder(
            builder: (ctx) {
              final hidden = provider.avCabling.hiddenLabels.length;
              return OutlinedButton.icon(
                key: const ValueKey('cabling_labels'),
                icon: const Icon(Icons.label_outline, size: 18),
                label: Text(
                  hidden == 0 ? 'Labels' : 'Labels ($hidden hidden)',
                ),
                onPressed: hidden == 0
                    ? null
                    : () {
                        final back = provider.showAllCablingLabels();
                        _snack(
                          'Showing $back label${back == 1 ? '' : 's'} again.',
                        );
                      },
              );
            },
          ),
          // Every cable type's colour in one place, the way the Schematic
          // tab's "Colors" button has always worked. Setting them one
          // selected run at a time is how a sheet ends up with three shades
          // of network on it.
          OutlinedButton.icon(
            key: const ValueKey('cabling_colors'),
            icon: const Icon(Icons.palette_outlined, size: 18),
            label: const Text('Cable colours'),
            onPressed: () => showCableColorsDialog(context, provider),
          ),
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
          PopupMenuButton<String>(
            key: const ValueKey('cabling_png_menu'),
            tooltip: 'Export the drawing',
            onSelected: (v) => _exportPng(provider, monochrome: v == 'bw'),
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'one', child: Text('As drawn (.png)')),
              // The one that gets printed and marked up on a clipboard. The
              // runs carry a dash pattern as well as a colour precisely so
              // this stays readable.
              PopupMenuItem(
                value: 'bw',
                child: Text('Black & white for print (.png)'),
              ),
            ],
            child: IgnorePointer(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.image_outlined, size: 18),
                label: const Text('Export PNG'),
                onPressed: () {},
              ),
            ),
          ),
          PopupMenuButton<String>(
            key: const ValueKey('cabling_schedule_menu'),
            tooltip: 'Export the run schedule',
            onSelected: (v) => v == 'copy'
                ? _copyReportText(provider)
                : _exportReport(provider, asXlsx: v == 'xlsx'),
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                value: 'xlsx',
                child: Text('Workbook with the drawings (.xlsx)'),
              ),
              PopupMenuItem(value: 'txt', child: Text('Plain text (.txt)')),
              PopupMenuItem(
                value: 'copy',
                child: Text('Copy text to clipboard'),
              ),
            ],
            child: IgnorePointer(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text('Run schedule'),
                onPressed: () {},
              ),
            ),
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
                        child: Text(
                          'Reset',
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
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
                ' - click the other box',
              ),
              onDeleted: () => setState(() => _runFrom = ''),
            ),
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

  // --- the selection bar ----------------------------------------------------

  /// The row under the toolbar: what is selected and everything that can be
  /// done to it. Nothing at all when nothing is selected, so the page stays
  /// quiet for somebody who only came to look at the drawing.
  List<Widget> _selectionBar(
    AppStateProvider provider,
    CablingSchematic drawing,
  ) {
    final box = drawing.boxById(_selectedId);
    final bundle = drawing.bundles.where((b) => b.id == _selectedId).firstOrNull;
    if (box == null && bundle == null) return const [];

    final theme = Theme.of(context);
    return [
      const Divider(height: 1),
      Container(
        width: double.infinity,
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: box != null
              ? _boxActions(provider, drawing, box)
              : _bundleActions(provider, drawing, bundle!),
        ),
      ),
    ];
  }

  /// The small caption at the head of the selection bar, so it is obvious what
  /// the controls beside it are about to change.
  Widget _selectionTitle(String kind, String name) => Padding(
    padding: const EdgeInsets.only(right: 4),
    child: RichText(
      text: TextSpan(
        style: Theme.of(context).textTheme.bodySmall,
        children: [
          TextSpan(
            text: '$kind  ',
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
          TextSpan(
            text: name,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );

  List<Widget> _boxActions(
    AppStateProvider provider,
    CablingSchematic drawing,
    CablingBox box,
  ) => [
    _selectionTitle(kCablingBoxKindLabels[box.kind] ?? 'Box', box.label),
    TextButton.icon(
      icon: const Icon(Icons.drive_file_rename_outline, size: 16),
      label: const Text('Rename'),
      onPressed: () => _renameBox(provider, box),
    ),
    // Only a hand-added device box has a shape to swap; a place derived from
    // the room is a place, not a piece of gear.
    if (box.kind == CablingBoxKind.device && !box.isDerived)
      TextButton.icon(
        icon: Icon(cablingDeviceIcon(box.shape), size: 16),
        label: const Text('Device type'),
        onPressed: () async {
          final shape = await _pickDeviceShape(box.shape);
          if (shape != null) provider.setCablingBoxShape(box.id, shape);
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
          ? 'Take it off the drawing (the room keeps the location) - or press '
                'Delete'
          : 'Delete this box - or press Delete',
      () => _deleteSelection(provider, drawing),
      danger: true,
    ),
  ];

  /// One end of the run stepper in the selection bar.
  ///
  /// Kept out of the focus order so tabbing through the bar still runs
  /// straight down the fields somebody is filling in, and so the button itself
  /// never becomes the thing holding the keyboard.
  Widget _stepButton(CablingSchematic drawing, {required bool forward}) =>
      ExcludeFocus(
        child: IconButton(
          key: ValueKey('cabling_step_${forward ? 'next' : 'prev'}'),
          icon: Icon(
            forward ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
            size: 18,
          ),
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          padding: EdgeInsets.zero,
          tooltip: forward
              ? 'The next run between these two - or the down arrow, with the '
                    'drawing selected'
              : 'The one before it - or the up arrow, with the drawing '
                    'selected',
          onPressed: () => _stepRun(drawing, forward: forward),
        ),
      );

  /// The run's count and type, edited IN the bar rather than behind a button.
  ///
  /// The count is the number somebody came to this page to change, so it is a
  /// box they can type in, not a dialog they have to find first.
  List<Widget> _bundleActions(
    AppStateProvider provider,
    CablingSchematic drawing,
    CablingBundle bundle,
  ) {
    final from = drawing.boxById(bundle.fromBoxId)?.label ?? bundle.fromBoxId;
    final to = drawing.boxById(bundle.toBoxId)?.label ?? bundle.toBoxId;
    final siblings = drawing.bundlesBetween(bundle.fromBoxId, bundle.toBoxId);
    return [
      _selectionTitle('Run', '$from  →  $to'),
      // Which of the stack this is, and how to reach the others. Six runs
      // thirteen pixels apart are not pickable with a mouse, and until this
      // said so the ones in the middle read as unselectable.
      //
      // Two BUTTONS, not a caption telling you to press a key. A label that
      // only describes a shortcut is a promise the page has to keep, and this
      // one could not: the keyboard belongs to the drawing, so the moment the
      // caret was in the count box beside it the arrows typed instead of
      // stepped. The buttons work from wherever the caret is.
      if (siblings.length > 1) ...[
        _stepButton(drawing, forward: false),
        Text(
          '${siblings.indexWhere((b) => b.id == bundle.id) + 1}'
          ' of ${siblings.length}',
          style: const TextStyle(fontSize: 11),
        ),
        _stepButton(drawing, forward: true),
      ],
      // Committed on Enter or on clicking away rather than per keystroke: the
      // count goes through the undo stack, and "13" typed a digit at a time
      // would leave "1" behind as an entry of its own.
      SizedBox(
        width: 96,
        child: LiveTextField(
          key: ValueKey('cabling_count_${bundle.id}'),
          fieldId: 'count:${bundle.id}',
          initial: bundle.count == bundle.count.roundToDouble()
              ? bundle.count.round().toString()
              : bundle.count.toStringAsFixed(1),
          label: 'Cables',
          numeric: true,
          onChanged: (_) {},
          onSubmitted: (v) => provider.setCablingBundleCount(
            bundle.id,
            v.trim().isEmpty ? null : double.tryParse(v.trim()),
          ),
        ),
      ),
      // Typed, not picked from a list: the field takes anything, because the
      // cable on a job is whatever the spec says and no list survives contact
      // with a real one. The menu beside it is only a shortcut for the dozen
      // types that get typed over and over — and it is what stops a schedule
      // carrying "Cat5e", "cat 5e" and "CAT5E" as three lines of a PO.
      SizedBox(
        width: 180,
        child: LiveTextField(
          key: ValueKey('cabling_type_${bundle.id}'),
          fieldId: 'type:${bundle.id}',
          initial: bundle.cableType,
          label: 'Cable',
          hint: 'e.g. Cat 5e',
          onChanged: (_) {},
          onSubmitted: (v) => provider.setCablingBundleType(bundle.id, v),
        ),
      ),
      PopupMenuButton<String>(
        key: ValueKey('cabling_type_menu_${bundle.id}'),
        tooltip: 'Common cable types',
        icon: const Icon(Icons.arrow_drop_down, size: 22),
        onSelected: (v) => provider.setCablingBundleType(bundle.id, v),
        itemBuilder: (ctx) => [
          for (final type in kCablingCableTypes)
            PopupMenuItem(value: type, child: Text(type)),
        ],
      ),
      // What the run lands on at each end. Typed here rather than only in the
      // dialog because these are the fields somebody fills in for run after
      // run while reading a jack schedule, and a dialog per run is a dialog
      // per run.
      SizedBox(
        width: 190,
        child: LiveTextField(
          key: ValueKey('cabling_from_label_${bundle.id}'),
          fieldId: 'fromLabel:${bundle.id}',
          initial: bundle.fromLabel,
          label: 'Lands on at $from',
          hint: 'e.g. Wall plate 2',
          onChanged: (_) {},
          onSubmitted: (v) =>
              provider.setCablingBundleEndLabel(bundle.id, fromLabel: v),
        ),
      ),
      SizedBox(
        width: 190,
        child: LiveTextField(
          key: ValueKey('cabling_to_label_${bundle.id}'),
          fieldId: 'toLabel:${bundle.id}',
          initial: bundle.toLabel,
          label: 'Lands on at $to',
          hint: 'e.g. Patch panel A',
          onChanged: (_) {},
          onSubmitted: (v) =>
              provider.setCablingBundleEndLabel(bundle.id, toLabel: v),
        ),
      ),
      // What the family name covers, when it covers more than one thing.
      if (bundle.signalSubLabel.isNotEmpty)
        Chip(
          label: Text(bundle.signalSubLabel),
          visualDensity: VisualDensity.compact,
          labelStyle: const TextStyle(fontSize: 11),
        ),
      // Which way the pull actually goes is a fact about the building, so the
      // dots on the selected line are draggable. This is the way back.
      if ((provider.avCabling.waypoints[bundle.id] ?? const []).isNotEmpty)
        TextButton.icon(
          key: ValueKey('cabling_straighten_${bundle.id}'),
          icon: const Icon(Icons.timeline, size: 16),
          label: const Text('Straighten'),
          onPressed: () =>
              provider.setCablingBundleWaypoints(bundle.id, const []),
        ),
      ..._colorPicker(provider, bundle),
      // The whole point of an edge holding more than one run: "six Cat 6a AND
      // five Cat 5e from the lectern to the pathway" is two lines of cable on
      // one route, and the drawing has to be able to say both.
      TextButton.icon(
        key: ValueKey('cabling_add_type_${bundle.id}'),
        icon: const Icon(Icons.playlist_add, size: 16),
        label: const Text('Add cable type'),
        onPressed: () {
          // No colour is chosen here any more: the key hands one out per cable
          // type, so the new line is a different colour from the one it was
          // added beside for the only reason that should ever make two lines
          // different colours — it is a different cable.
          final added = provider.addCablingBundle(
            fromBoxId: bundle.fromBoxId,
            toBoxId: bundle.toBoxId,
            cableType: '',
          );
          if (added != null) _select(added.id);
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
        'Take this run off the drawing - or press Delete',
        () => _deleteSelection(provider, drawing),
        danger: true,
      ),
    ];
  }

  /// The colours a run can be drawn in, for the sheet whose office has its own
  /// convention. The palette first, then the picker for anything the app has
  /// never heard of.
  ///
  /// Recolouring one run is an EXCEPTION now: the key gives every cable type
  /// its own colour, so the ordinary way to make two runs read alike is to
  /// give them the same cable type, not to paint them.
  List<Widget> _colorPicker(AppStateProvider provider, CablingBundle bundle) {
    final current = Color(bundle.color);
    return [
      const SizedBox(width: 4),
      for (final c in kCableSwatches)
        ColorSwatchButton(
          key: ValueKey(
            'cabling_color_${(c.toARGB32() & 0xFFFFFF).toRadixString(16)}',
          ),
          color: c,
          selected: current.toARGB32() == c.toARGB32(),
          width: 22,
          height: 20,
          onTap: () =>
              provider.setCablingBundleColor(bundle.id, c.toARGB32()),
        ),
      avRowIcon(
        Icons.colorize,
        'Any other colour',
        () async {
          final picked = await showColorWheelDialog(
            context,
            initial: current,
            title: 'Colour for ${bundle.label}',
          );
          if (picked != null) {
            provider.setCablingBundleColor(bundle.id, picked.toARGB32());
          }
        },
      ),
      // Only offered once there is something to go back to: a hand-picked
      // colour is the one thing that hides what the key says this cable is.
      if (provider.avCabling.colors.containsKey(bundle.id))
        avRowIcon(
          Icons.format_color_reset,
          'Back to the colour the key gives this cable',
          () => provider.setCablingBundleColor(bundle.id, null),
        ),
    ];
  }

  // --- right-click ----------------------------------------------------------
  //  A drawing is edited by pointing at the thing being edited. Everything
  //  here is also in the selection bar, and none of it should need a trip to
  //  the top of the page.

  /// Puts a menu where the pointer is.
  Future<T?> _menuAt<T>(Offset at, List<PopupMenuEntry<T>> items) {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final size = overlay?.size ?? MediaQuery.of(context).size;
    return showMenu<T>(
      context: context,
      position: RelativeRect.fromLTRB(
        at.dx,
        at.dy,
        size.width - at.dx,
        size.height - at.dy,
      ),
      items: items,
    );
  }

  /// The context menu for a box — a location, a pull box, a pathway, a note or
  /// a device. What is offered depends on which: only a hand-added device has
  /// an icon to swap, and a derived box is taken OFF the drawing rather than
  /// deleted (the room keeps the location).
  Future<void> _showBoxMenu(
    AppStateProvider provider,
    CablingSchematic drawing,
    CablingBox box,
    Offset at,
  ) async {
    final kind = kCablingBoxKindLabels[box.kind] ?? 'Box';
    final choice = await _menuAt<String>(at, [
      PopupMenuItem(
        enabled: false,
        height: 34,
        child: Text(
          '$kind · ${box.label}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'rename', child: Text('Rename...')),
      PopupMenuItem(
        value: 'body',
        child: Text(box.body.trim().isEmpty ? 'Add text...' : 'Edit text...'),
      ),
      if (box.kind == CablingBoxKind.device && !box.isDerived)
        const PopupMenuItem(value: 'shape', child: Text('Device type...')),
      const PopupMenuItem(value: 'run', child: Text('Draw a run from here')),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: 'delete',
        child: Text(
          box.isDerived ? 'Take it off the drawing' : 'Delete this box',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
    ]);
    if (choice == null || !mounted) return;

    switch (choice) {
      case 'rename':
        await _renameBox(provider, box);
      case 'body':
        final body = await _askFor('Text', box.body, lines: 8);
        if (body != null) provider.setCablingBoxBody(box.id, body);
      case 'shape':
        final shape = await _pickDeviceShape(box.shape);
        if (shape != null) provider.setCablingBoxShape(box.id, shape);
      case 'run':
        setState(() => _runFrom = box.id);
      case 'delete':
        _deleteSelection(provider, drawing);
    }
  }

  Future<void> _renameBox(AppStateProvider provider, CablingBox box) async {
    final name = await _askFor('Box name', box.label);
    if (name != null && name.trim().isNotEmpty) {
      provider.setCablingBoxLabel(box.id, name.trim());
    }
  }

  /// The context menu for a run.
  Future<void> _showBundleMenu(
    AppStateProvider provider,
    CablingSchematic drawing,
    CablingBundle bundle,
    Offset at,
  ) async {
    final siblings = drawing.bundlesBetween(bundle.fromBoxId, bundle.toBoxId);
    final choice = await _menuAt<String>(at, [
      PopupMenuItem(
        enabled: false,
        height: 34,
        child: Text(
          'Run · ${bundle.label}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(
        value: 'edit',
        child: Text('Edit this run...'),
      ),
      const PopupMenuItem(value: 'color', child: Text('Colour...')),
      if (siblings.length > 1)
        PopupMenuItem(
          value: 'next',
          child: Text('Next of the ${siblings.length} runs here  (↓)'),
        ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: 'delete',
        child: Text(
          'Take this run off the drawing',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
    ]);
    if (choice == null || !mounted) return;

    switch (choice) {
      case 'edit':
        await _showBundleEditor(provider, drawing, bundle);
      case 'color':
        final picked = await showColorWheelDialog(
          context,
          initial: Color(bundle.color),
          title: 'Colour for ${bundle.label}',
        );
        if (picked != null) {
          provider.setCablingBundleColor(bundle.id, picked.toARGB32());
        }
      case 'next':
        // Through the same step as the arrows and the buttons, so it also
        // says what it landed on and leaves the keyboard on the drawing —
        // closing a menu is not a reason for the arrows to stop working.
        _stepRun(drawing, forward: true);
        _takeTheKeyboard();
      case 'delete':
        _deleteSelection(provider, drawing);
    }
  }

  /// Everything about one run in one place — including what it LANDS ON at
  /// each end.
  ///
  /// The two end labels are the reason this dialog exists rather than more
  /// fields in the selection bar: a bar that already wraps on a laptop cannot
  /// take two more text boxes, and "which jack does this one land on" is the
  /// question a cabling sheet is read at the wall to answer.
  Future<void> _showBundleEditor(
    AppStateProvider provider,
    CablingSchematic drawing,
    CablingBundle bundle,
  ) async {
    final from = drawing.boxById(bundle.fromBoxId)?.label ?? bundle.fromBoxId;
    final to = drawing.boxById(bundle.toBoxId)?.label ?? bundle.toBoxId;
    final countController = TextEditingController(
      text: bundle.count == bundle.count.roundToDouble()
          ? bundle.count.round().toString()
          : bundle.count.toStringAsFixed(1),
    );
    final typeController = TextEditingController(text: bundle.cableType);
    final fromController = TextEditingController(text: bundle.fromLabel);
    final toController = TextEditingController(text: bundle.toLabel);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$from  →  $to'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'How much cable, what it is, and what it lands on at each '
                  'end. The end labels print beside their own end of the line '
                  'on this drawing and on the floor plan - leave them blank on '
                  'a run whose ends speak for themselves.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 110,
                      child: TextField(
                        key: const ValueKey('run_editor_count'),
                        controller: countController,
                        decoration: const InputDecoration(
                          labelText: 'Cables',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('run_editor_type'),
                        controller: typeController,
                        decoration: const InputDecoration(
                          labelText: 'Cable',
                          hintText: 'e.g. Cat 6a',
                        ),
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Common cable types',
                      icon: const Icon(Icons.arrow_drop_down),
                      onSelected: (v) => typeController.text = v,
                      itemBuilder: (ctx) => [
                        for (final type in kCablingCableTypes)
                          PopupMenuItem(value: type, child: Text(type)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const ValueKey('run_editor_from_label'),
                  controller: fromController,
                  decoration: InputDecoration(
                    labelText: 'Lands on at $from',
                    hintText: 'e.g. Wall plate 2, ports 1-4',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('run_editor_to_label'),
                  controller: toController,
                  decoration: InputDecoration(
                    labelText: 'Lands on at $to',
                    hintText: 'e.g. Patch panel A, ports 13-18',
                  ),
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
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true) return;

    final count = countController.text.trim();
    provider.setCablingBundleCount(
      bundle.id,
      count.isEmpty ? null : double.tryParse(count),
    );
    provider.setCablingBundleType(
      bundle.id,
      typeController.text.trim().isEmpty ? null : typeController.text,
    );
    provider.setCablingBundleEndLabel(
      bundle.id,
      fromLabel: fromController.text,
      toLabel: toController.text,
    );
  }

  // --- devices --------------------------------------------------------------

  Future<void> _addDevice(
    AppStateProvider provider,
    CablingSchematic drawing,
  ) async {
    final shape = await _pickDeviceShape('');
    if (shape == null) return;
    final box = provider.addCablingBox(
      kind: CablingBoxKind.device,
      shape: shape,
      occupied: _occupied(provider, drawing),
    );
    setState(() => _selectedId = box.id);
  }

  /// Everything already taking up room on the sheet: the boxes, and the key
  /// panel when it is on. A new box has to miss all of it.
  List<Rect> _occupied(AppStateProvider provider, CablingSchematic drawing) => [
    for (final b in drawing.boxes) b.rect,
    ?_keyRect(provider, drawing),
  ];

  /// The gear picker: the same icons the schematic uses, named the way the
  /// room talks about them.
  Future<String?> _pickDeviceShape(String current) => showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Which device?'),
      content: SizedBox(
        width: 460,
        height: 420,
        child: GridView.count(
          crossAxisCount: 3,
          childAspectRatio: 1.25,
          children: [
            for (final e in kCablingDeviceShapes.entries)
              InkWell(
                key: ValueKey('cabling_device_${e.key}'),
                onTap: () => Navigator.of(ctx).pop(e.key),
                child: Container(
                  margin: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: e.key == current
                          ? Theme.of(ctx).colorScheme.primary
                          : Theme.of(ctx).dividerColor,
                      width: e.key == current ? 2 : 1,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(e.value.icon, size: 26),
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          e.value.label,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 11),
                          maxLines: 2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );

  /// The drawing as PNG bytes, optionally rendered the way it should print.
  ///
  /// The print skin is a WIDGET, not a filter over the bytes, so the drawing is
  /// re-laid-out in the light theme before it is captured — a dark-mode capture
  /// converted to grey is a black page with pale lines on it, which a printer
  /// renders as a black page.
  Future<Uint8List?> _captureDrawing({bool monochrome = false}) async {
    if (!monochrome) return captureBoundary(_canvasKey, pixelRatio: 2.0);
    setState(() => _printMode = true);
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return null;
      return await captureBoundary(_canvasKey, pixelRatio: 2.0);
    } finally {
      if (mounted) setState(() => _printMode = false);
    }
  }

  Future<void> _exportPng(
    AppStateProvider provider, {
    bool monochrome = false,
  }) async {
    final bytes = await _captureDrawing(monochrome: monochrome);
    if (bytes == null) {
      _snack('Could not render the cabling drawing to an image.');
      return;
    }
    if (!mounted) return;
    await showCapturedPicture(
      context,
      bytes,
      title: monochrome
          ? 'The cabling drawing for printing'
          : 'The cabling drawing as a picture',
      fileName:
          '${roomFileStem(provider, monochrome ? 'cabling_bw' : 'cabling')}.png',
      what: monochrome
          ? 'The cabling drawing (black & white)'
          : 'The cabling drawing',
    );
  }

  /// The run schedule as plain text on the clipboard.
  ///
  /// The same tables the .txt file holds, without a file: what goes in an
  /// email or a ticket, which is most of the times somebody wants the
  /// schedule at all. Every report in the app offers this, in the same place
  /// on the menu.
  Future<void> _copyReportText(AppStateProvider provider) async {
    final model = buildAvFlowModel(provider);
    final sections = cablingSections(model);
    if (sections.isEmpty) {
      _snack('Nothing to report yet - the drawing is empty.');
      return;
    }
    final title = model.roomTitle.isEmpty ? 'Cabling' : model.roomTitle;
    await Clipboard.setData(
      ClipboardData(text: renderTextReport(title, sections)),
    );
    _snack('Run schedule copied to the clipboard.');
  }

  /// The run schedule, as a workbook or as plain text.
  ///
  /// The workbook is the one that gets sent to a contractor: the schedule they
  /// price against AND the drawing they pull from, with a sheet per cable so
  /// the network contractor's copy has the network runs on it and nothing
  /// else. A schedule with no drawing is a list of pairs of place names, and a
  /// drawing with no schedule is not something anybody can order against.
  Future<void> _exportReport(
    AppStateProvider provider, {
    required bool asXlsx,
  }) async {
    final model = buildAvFlowModel(provider);
    final sections = cablingSections(model);
    if (sections.isEmpty) {
      _snack('Nothing to report yet - the drawing is empty.');
      return;
    }
    final title = model.roomTitle.isEmpty ? 'Cabling' : model.roomTitle;
    final ext = asXlsx ? 'xlsx' : 'txt';
    String? out = await FilePicker.saveFile(
      dialogTitle: 'Save the cable run schedule',
      fileName: '${roomFileStem(provider, 'cabling')}.$ext',
      type: FileType.custom,
      allowedExtensions: [ext],
    );
    if (out == null) return;
    if (!out.toLowerCase().endsWith('.$ext')) out += '.$ext';
    final saved = out;

    try {
      if (asXlsx) {
        // One moment for the whole book: sheets stamped seconds apart read as
        // documents from two different exports.
        final generated = DateTime.now();
        final layers = await _captureCableLayers(provider);
        final first = layers.isEmpty ? null : layers.first;
        await File(saved).writeAsBytes(
          buildXlsx([
            buildStackedReportSheet(
              sheetName: 'Run Schedule',
              title: title,
              sections: sections,
              generated: generated,
              imageBuilder: first == null
                  ? null
                  : (anchorRow) => scaledSheetImage(first.bytes, anchorRow),
            ),
            for (final layer in layers.skip(1))
              drawingSheet(title, layer, generated),
          ]),
        );
      } else {
        await File(saved).writeAsString(renderTextReport(title, sections));
      }
      if (mounted) {
        showSavedFileSnack(context, provider, 'Cable run schedule', saved);
      }
    } catch (e) {
      _snack('Failed to save the schedule: $e');
    }
  }

  /// Renders the sheet once per cable: everything first, then one drawing per
  /// cable type.
  ///
  /// Only a widget on screen can be rendered, so the way to get a picture of
  /// one layer is to make the canvas draw that layer and capture a frame. The
  /// filter is put back afterwards — the sheet on screen shows everything.
  Future<List<({String name, String caption, Uint8List bytes})>>
  _captureCableLayers(AppStateProvider provider) async {
    final drawing = provider.cablingSchematic(buildAvFlowModel(provider));
    final types = <String>{for (final b in drawing.bundles) b.cableType}
        .where((t) => t.trim().isNotEmpty)
        .toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final out = <({String name, String caption, Uint8List bytes})>[];
    // "All" first, then one per cable, so the book reads as a set. A sheet
    // with one cable type on it gets no per-layer copy — it would be the same
    // picture twice.
    for (final layer in ['', if (types.length > 1) ...types]) {
      if (!mounted) break;
      setState(() => _exportLayer = layer);
      // Let the change actually paint before the boundary is captured;
      // without this every image would be of whatever was on screen when the
      // loop started.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) break;
      final bytes = await captureBoundary(_canvasKey, pixelRatio: 2.0);
      if (bytes == null) continue;
      out.add((
        name: layer.isEmpty ? 'All runs' : xlsxSheetName(layer),
        caption: layer.isEmpty ? 'All runs' : layer,
        bytes: bytes,
      ));
    }
    if (mounted) setState(() => _exportLayer = '');
    return out;
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

  Size _canvasSize(AppStateProvider provider, CablingSchematic drawing) {
    var w = 1200.0;
    var h = 700.0;
    for (final r in [
      for (final b in drawing.boxes) b.rect,
      ?_keyRect(provider, drawing),
    ]) {
      w = w > r.right + 80 ? w : r.right + 80;
      h = h > r.bottom + 80 ? h : r.bottom + 80;
    }
    return Size(w, h);
  }

  // --- the key --------------------------------------------------------------

  /// Whether the key is on the sheet. On by default: a drawing whose lines are
  /// colour-coded and whose key is opt-in is a drawing that gets issued
  /// without one.
  bool _keyShown(AppStateProvider provider) =>
      !provider.avCabling.hidden.contains(kCablingKeyId);

  /// Where the key is and how big it has to be, or null when it is off.
  ///
  /// The height is worked out from the number of lines rather than measured,
  /// the same bargain [CablingBox.size] makes: the canvas sizing and the
  /// overlap checks need it before anything has been laid out.
  Rect? _keyRect(AppStateProvider provider, CablingSchematic drawing) {
    if (!_keyShown(provider)) return null;
    final entries = drawing.key;
    if (entries.isEmpty) return null;
    final at = _clamped(
      (provider.avCabling.positions[kCablingKeyId] ??
              kDefaultCablingKeyPosition) +
          // Dragged live, like the boxes: the key is a panel somebody shoves
          // out of the way, and a shove that rebuilds the whole app per frame
          // is the one that feels like it is sticking.
          (_dragId == kCablingKeyId ? _dragOffset : Offset.zero),
    );
    // padding + title + gap + one row each, running a little generous: this
    // figure is what the canvas is sized against and what a new box is kept
    // out of, and a panel that reserves a few pixels too many costs nothing
    // while one that reserves too few gets landed on.
    final height = 20 + 24 + 6 + entries.length * 30.0;
    return Rect.fromLTWH(at.dx, at.dy, kCablingKeyWidth, height);
  }

  /// The key: one line per cable on the sheet, in its colour.
  ///
  /// This is the half of a colour-coded drawing that makes the colours mean
  /// anything. It is derived from the same bundles the lines are drawn from —
  /// see [CablingSchematic.key] — so it cannot fall out of step with them the
  /// way a legend somebody maintains by hand always eventually does.
  Widget _key(
    BuildContext context,
    AppStateProvider provider,
    CablingSchematic drawing,
  ) {
    final rect = _keyRect(provider, drawing)!;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;

    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      // No height: the panel sizes itself to its lines. [_keyRect]'s figure is
      // an estimate for the layout maths, and pinning the widget to it would
      // clip the last line whenever the estimate came in a pixel short.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() {
          _dragId = kCablingKeyId;
          _dragOffset = Offset.zero;
        }),
        onPanUpdate: (d) => setState(() => _dragOffset += d.delta),
        onPanEnd: (_) {
          final moved = _dragOffset;
          setState(() {
            _dragId = '';
            _dragOffset = Offset.zero;
          });
          if (moved == Offset.zero) return;
          provider.setCablingBoxPosition(
            kCablingKeyId,
            nonOverlappingPosition(
              // rect already carries the drag — see [_keyRect].
              desired: _snapped(provider, rect.topLeft),
              size: rect.size,
              others: [for (final b in drawing.boxes) b.rect],
              step: provider.snapDiagramsToGrid ? kDiagramGridStep : 16,
            ),
          );
        },
        onPanCancel: () => setState(() {
          _dragId = '';
          _dragOffset = Offset.zero;
        }),
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Container(
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF1B2026) : const Color(0xFFFAFAFA),
              border: Border.all(
                color: dark ? const Color(0xFF3A424C) : const Color(0xFF9E9E9E),
                width: 1.2,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CABLE KEY',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                    color: dark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 6),
                for (final e in drawing.key)
                  SizedBox(
                    height: 30,
                    child: Row(
                      children: [
                        // The same dash the run captions carry — colour AND
                        // pattern — so a line in the key and a line on the
                        // drawing read as the same mark rather than two
                        // different notations. The pattern is the half that
                        // still works on a black-and-white print.
                        Container(
                          width: 20,
                          height: 10,
                          margin: const EdgeInsets.only(right: 8),
                          child: CustomPaint(
                            painter: _KeySpecimenPainter(
                              color: Color(e.color),
                              style: e.style,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                // The category only when it is doing work —
                                // when two categories share a cable type and
                                // the reader has to be told which Cat 6a this
                                // colour means.
                                e.categoryMatters
                                    ? '${e.type}  (${e.category})'
                                    : e.type,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: dark ? Colors.white : Colors.black87,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                '${_cableCount(e.count)} cable'
                                '${e.count == 1 ? '' : 's'} · '
                                '${e.runs} run${e.runs == 1 ? '' : 's'}',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: dark ? Colors.white70 : Colors.black54,
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
        ),
      ),
    );
  }

  static String _cableCount(double n) =>
      n == n.roundToDouble() ? n.round().toString() : n.toStringAsFixed(1);

  Widget _canvas(
    BuildContext context,
    AppStateProvider provider,
    CablingSchematic drawing,
  ) {
    final size = _canvasSize(provider, drawing);
    final theme = Theme.of(context);
    // Worked out once and handed to both the painter and the click targets, so
    // the line you see and the line you can hit are the same line.
    final lanes = drawing.bundleLanes;
    // And the routes with them: a run goes AROUND the boxes between its two
    // ends rather than straight through them, the same guarantee the signal
    // flow gives. Computed here rather than in paint() so a repaint — a
    // hover, a selection — is not an A* search.
    final routes = _routes(provider, drawing, lanes);
    // What a caption has to stay off: the boxes and the key. A run's label
    // parked on top of a box is the drawing losing the count it exists to
    // report.
    final keepClear = <Rect>[
      for (final b in drawing.boxes) b.rect,
      ?_keyRect(provider, drawing),
    ];
    // Laid out here rather than in paint(): the boxes are what the drag pads
    // below sit on, so the label somebody grabs is the one they can see. A
    // label being dragged right now carries the live offset, so it follows the
    // cursor without a provider write per pointer event.
    final captions = _cablingCaptions(
      drawing: drawing,
      routes: routes,
      keepClear: keepClear,
      nudges: {
        for (final e in provider.avCabling.labelOffsets.entries)
          e.key: e.value,
        if (_labelDragKey.isNotEmpty)
          _labelDragKey:
              (provider.avCabling.labelOffsets[_labelDragKey] ?? Offset.zero) +
                  _labelDrag,
      },
      selectedId: _selectedId,
      overridden: drawing.overridden,
      dark: theme.brightness == Brightness.dark,
      hiddenLabels: provider.avCabling.hiddenLabels,
      canvasSize: size,
    );
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
          // The alignment grid, on the sheet but never on an export of it.
          if (provider.showDiagramGrid)
            const Positioned.fill(child: DiagramGrid()),
          // The runs go under the boxes so a bundle disappears behind the box
          // it lands on rather than crossing over the label.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _BundlePainter(
                  drawing: drawing,
                  lanes: lanes,
                  routes: routes,
                  captions: captions,
                  selectedId: _selectedId,
                  overridden: drawing.overridden,
                  keepClear: keepClear,
                  dark: theme.brightness == Brightness.dark,
                ),
              ),
            ),
          ),
          for (final bundle in drawing.bundles)
            _bundleHitTarget(context, provider, drawing, bundle, routes[bundle.id]),
          // The pads that make a caption draggable. OVER the run targets,
          // which are deliberately wide enough to cover the label — otherwise
          // the run swallows the drag and the label cannot be picked up — and
          // under the boxes, so a label dragged across one does not steal the
          // box's clicks.
          for (final caption in captions)
            _labelDragTarget(provider, drawing, caption),
          for (final box in drawing.boxes) _box(context, provider, drawing, box),
          // Over the boxes: a bend dragged near one has to stay grabbable, and
          // it is only on screen while its run is selected.
          ..._bendHandles(provider, drawing, lanes, routes),
          // Last, so it is on top of anything it has been dragged over rather
          // than half hidden behind it.
          if (_keyRect(provider, drawing) != null)
            _key(context, provider, drawing),
        ],
      ),
    );
  }

  /// The pad that makes a painted caption draggable.
  ///
  /// The sheet places every label itself, and places them well enough that most
  /// are never touched. The ones that are touched are the ones the drawing
  /// cannot reason about: a label sitting where the next revision needs a note,
  /// or over the bit of the sheet somebody is pointing at. Dragging is stored
  /// as a nudge from the automatic spot, so the label still follows its run
  /// when a box moves.
  Widget _labelDragTarget(
    AppStateProvider provider,
    CablingSchematic drawing,
    _CablingCaption caption,
  ) {
    final box = caption.box;
    // The run this caption names, so clicking the label still picks the run —
    // which is how most people select one: the label is the part of a run big
    // enough to aim at.
    final runId = drawing.bundlesByEdge[caption.edgeKey]?.first.id ?? '';
    return Positioned(
      left: box.left,
      top: box.top,
      width: box.width,
      height: box.height,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: GestureDetector(
          key: ValueKey('cabling_label_${caption.edgeKey}'),
          behavior: HitTestBehavior.opaque,
          onTap: runId.isEmpty ? null : () => _select(runId),
          onPanStart: (_) => setState(() {
            _labelDragKey = caption.edgeKey;
            _labelDrag = Offset.zero;
          }),
          onPanUpdate: (d) => setState(() => _labelDrag += d.delta),
          onPanEnd: (_) {
            final moved = _labelDrag;
            final key = _labelDragKey;
            setState(() {
              _labelDragKey = '';
              _labelDrag = Offset.zero;
            });
            if (key.isEmpty || moved == Offset.zero) return;
            provider.setCablingLabelOffset(
              key,
              (provider.avCabling.labelOffsets[key] ?? Offset.zero) + moved,
            );
          },
          onPanCancel: () => setState(() {
            _labelDragKey = '';
            _labelDrag = Offset.zero;
          }),
          // Right-click takes THIS caption off the sheet. The way back is on
          // the toolbar rather than here, because a label that is not drawn
          // cannot be right-clicked to bring itself back.
          onSecondaryTap: () {
            provider.setCablingLabelHidden(caption.edgeKey, true);
            _snack('Label hidden. "Labels" on the toolbar shows them again.');
          },
          // The way back. A label put somewhere by hand is left exactly there
          // even when something is drawn over it later, so there has to be one.
          onDoubleTap: caption.moved
              ? () => provider.setCablingLabelOffset(
                    caption.edgeKey,
                    Offset.zero,
                  )
              : null,
          child: Tooltip(
            message: caption.moved
                ? 'Click to select the run · drag to move · double-click to '
                    'put it back · right-click to hide it'
                : 'Click to select the run · drag to move · right-click to '
                    'hide it',
            waitDuration: const Duration(milliseconds: 700),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  /// A pad at the middle of a run, so a line can be clicked without
  /// hit-testing the whole canvas.
  ///
  /// Sized to cover the LABEL as well as the line: the label is the part of a
  /// run people aim at, and a target that only covered the wire itself was the
  /// reason a run looked unselectable and its count unreachable.
  /// Every run's drawn path, by bundle id.
  ///
  /// A run steps around the boxes it passes instead of crossing them: a line
  /// through the middle of the equipment rack is a line nobody can follow, and
  /// it is exactly the reason the signal flow grew a router of its own. The
  /// two boxes a run LANDS on are not obstacles to it — it has to reach them.
  /// Where each run lands on its boxes right now: what is stored, with the end
  /// under the pointer moved to where the pointer has it.
  Map<String, Offset> _anchorsWithDrag(AppStateProvider provider) {
    final stored = provider.avCabling.endAnchors;
    if (_endRunId.isEmpty || _endFraction == null) return stored;
    return {
      ...stored,
      cablingEndKey(_endRunId, _endAtStart): _endFraction!,
    };
  }

  /// The bends [bundleId] is drawn with right now: what is stored, with the
  /// bend under the pointer moved to where the pointer has it.
  ///
  /// A dragged bend is snapped square with its neighbours as it comes close to
  /// them, because cable in a building runs along walls and trays and hitting
  /// an exact right angle by dragging a dot is a thing nobody can do.
  List<Offset> _bendsOf(
    AppStateProvider provider,
    String bundleId,
    Offset from,
    Offset to,
    Map<String, Rect> rects,
  ) {
    final stored = provider.avCabling.waypoints[bundleId];
    if (bundleId != _bendRunId || _bendIndex < 0) return stored ?? const [];
    final next = List<Offset>.from(stored ?? const <Offset>[]);
    if (_bendIndex >= next.length) return next;
    final neighbours = <Offset>[
      if (_bendIndex == 0) from else next[_bendIndex - 1],
      if (_bendIndex == next.length - 1) to else next[_bendIndex + 1],
    ];
    // A bend dropped inside a box is the one place the router cannot route out
    // of, so the line would have to cross the box to reach it. Nudged clear.
    next[_bendIndex] = pushOutOfRects(
      snapToRightAngle(next[_bendIndex] + _bendDelta, neighbours),
      rects.values.toList(),
    );
    return next;
  }

  Map<String, List<Offset>> _routes(
    AppStateProvider provider,
    CablingSchematic drawing,
    Map<String, double> lanes,
  ) {
    final rects = {for (final b in drawing.boxes) b.id: b.rect};
    final out = <String, List<Offset>>{};
    for (final bundle in drawing.bundles) {
      final ends = drawing.endsOf(bundle, lanes[bundle.id] ?? 0,
        endAnchors: _anchorsWithDrag(provider));
      if (ends == null) continue;
      final obstacles = [
        for (final e in rects.entries)
          if (e.key != bundle.fromBoxId && e.key != bundle.toBoxId) e.value,
      ];
      // Bends placed by hand say which way the pull actually goes — down the
      // tray, round the corridor — which is a fact about the building the
      // router cannot know. It still keeps each leg off the boxes.
      final bends = _bendsOf(provider, bundle.id, ends.from, ends.to, rects);
      if (bends.isNotEmpty) {
        out[bundle.id] = routeThrough([ends.from, ...bends, ends.to], obstacles);
        continue;
      }
      out[bundle.id] =
          latticeRoute(ends.from, ends.to, obstacles) ??
          // No way through — a straight line at least says the two ends are
          // joined, which beats dropping the run off the drawing.
          [ends.from, ends.to];
    }
    return out;
  }

  ///
  /// Runs sharing an edge are fanned onto their own lanes, so each one has a
  /// pad of its own: on a location feeding the pathway with six Cat 6a and
  /// five Cat 5e, both lines are selectable rather than only the top one.
  Widget _bundleHitTarget(
    BuildContext context,
    AppStateProvider provider,
    CablingSchematic drawing,
    CablingBundle bundle,
    List<Offset>? route,
  ) {
    if (route == null || route.isEmpty) return const SizedBox.shrink();
    final mid = polylineMidpoint(route);
    const w = 150.0;
    final siblings = drawing.bundlesBetween(bundle.fromBoxId, bundle.toBoxId);
    // Kept to a lane's width when there are runs either side, so two pads on
    // one edge cannot cover each other and steal the click.
    final h = siblings.length > 1 ? kCablingLaneStep : 48.0;
    return Positioned(
      left: mid.dx - w / 2,
      top: mid.dy - h / 2 - (h > kCablingLaneStep ? 8 : 0),
      width: w,
      height: h,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _select(bundle.id),
          onSecondaryTapDown: (d) {
            _select(bundle.id);
            _showBundleMenu(provider, drawing, bundle, d.globalPosition);
          },
          child: Tooltip(
            message: [
              '${bundle.label}'
                  '${bundle.signalSubLabel.isEmpty ? '' : ' · ${bundle.signalSubLabel}'}',
              'Click to set the count and cable type · right-click for '
                  'everything else',
              // The way out of the one thing this drawing is genuinely awkward
              // at: six lanes thirteen pixels apart, and the one you want in
              // the middle.
              if (siblings.length > 1)
                '${siblings.length} runs between these two - arrow keys step '
                    'through them',
            ].join('\n'),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  /// Drag handles for the selected run's route: a filled dot on every bend it
  /// has been given, and a hollow one at the middle of each leg that adds one.
  ///
  /// Only on the selected run. A drawing with a dot on every corner of every
  /// line is a drawing nobody can read, and the ones that matter are the ones
  /// on the run being worked on.
  List<Widget> _bendHandles(
    AppStateProvider provider,
    CablingSchematic drawing,
    Map<String, double> lanes,
    Map<String, List<Offset>> routes,
  ) {
    if (_selectedId.isEmpty) return const [];
    final bundle = drawing.bundleById(_selectedId);
    if (bundle == null) return const [];
    final ends = drawing.endsOf(bundle, lanes[bundle.id] ?? 0,
        endAnchors: _anchorsWithDrag(provider));
    final drawn = routes[bundle.id];
    if (ends == null || drawn == null || drawn.length < 2) return const [];

    final rects = {for (final b in drawing.boxes) b.id: b.rect};
    // What is on SCREEN, drag included, so a handle sits under the pointer
    // that is dragging it.
    final bends = _bendsOf(provider, bundle.id, ends.from, ends.to, rects);
    final boxes = rects.values.toList();
    final color = Color(bundle.color);
    const r = 6.0;
    final out = <Widget>[];

    // The midpoints go down FIRST, so a bend placed on a straight leg
    // — collinear, and therefore invisible in the drawn route — keeps
    // its own handle on top of the one that would add another there.
    for (int i = 0; i < drawn.length - 1; i++) {
      final mid = (drawn[i] + drawn[i + 1]) / 2;
      out.add(
        Positioned(
          key: ValueKey('cabling_add_bend_${bundle.id}_$i'),
          left: mid.dx - r,
          top: mid.dy - r,
          child: GestureDetector(
            onTap: () => provider.setCablingBundleWaypoints(
              bundle.id,
              List<Offset>.from(bends)..insert(
                bendInsertIndex(ends.from, bends, ends.to, mid),
                pushOutOfRects(mid, boxes),
              ),
            ),
            // A square corner in one click, which is what a cable pulled
            // along a wall and then across actually does. Dragging a bend
            // until it happens to line up is the same thing done by eye.
            onSecondaryTap: () => provider.setCablingBundleWaypoints(
              bundle.id,
              List<Offset>.from(bends)..insertAll(
                bendInsertIndex(ends.from, bends, ends.to, mid),
                [
                  for (final corner in rightAngleTurn(drawn[i], drawn[i + 1]))
                    pushOutOfRects(corner, boxes),
                ],
              ),
            ),
            child: Tooltip(
              message: 'Add a bend here · right-click for a 90° turn',
              child: Container(
                width: r * 2,
                height: r * 2,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 1.5),
                ),
              ),
            ),
          ),
        ),
      );
    }
    // WHERE THE RUN LANDS on each of its two boxes. A run arrives at the
    // middle of a box by default, which is right for a one-line drawing and
    // wrong the moment somebody is describing real work: cable comes into a
    // floor box from one side, and four runs pointing at the centre of the
    // same box say nothing about which knockout each of them uses.
    for (final end in [
      (atStart: true, boxId: bundle.fromBoxId, at: ends.from),
      (atStart: false, boxId: bundle.toBoxId, at: ends.to),
    ]) {
      final box = drawing.boxById(end.boxId);
      if (box == null) continue;
      final rect = box.rect;
      out.add(
        Positioned(
          key: ValueKey(
            'cabling_end_${bundle.id}_${end.atStart ? 'from' : 'to'}',
          ),
          left: end.at.dx - r,
          top: end.at.dy - r,
          child: MouseRegion(
            cursor: SystemMouseCursors.move,
            child: GestureDetector(
              onPanStart: (_) => setState(() {
                _endRunId = bundle.id;
                _endAtStart = end.atStart;
                _endFraction = Offset(
                  rect.width == 0 ? 0.5 : (end.at.dx - rect.left) / rect.width,
                  rect.height == 0
                      ? 0.5
                      : (end.at.dy - rect.top) / rect.height,
                );
              }),
              onPanUpdate: (d) => setState(() {
                final f = _endFraction ?? const Offset(0.5, 0.5);
                _endFraction = Offset(
                  (f.dx + (rect.width == 0 ? 0 : d.delta.dx / rect.width))
                      .clamp(0.0, 1.0),
                  (f.dy + (rect.height == 0 ? 0 : d.delta.dy / rect.height))
                      .clamp(0.0, 1.0),
                );
              }),
              onPanEnd: (_) {
                final f = _endFraction;
                final id = _endRunId;
                final atStart = _endAtStart;
                setState(() {
                  _endRunId = '';
                  _endFraction = null;
                });
                if (f == null || id.isEmpty) return;
                provider.setCablingEndAnchor(id, atStart, f);
              },
              onPanCancel: () => setState(() {
                _endRunId = '';
                _endFraction = null;
              }),
              // Back to the middle of the box, which is where every run
              // starts out.
              onDoubleTap: () => provider.setCablingEndAnchor(
                bundle.id,
                end.atStart,
                null,
              ),
              child: Tooltip(
                message: 'Drag to move where this run lands on the box · '
                    'double-click to centre it',
                child: Container(
                  width: r * 2,
                  height: r * 2,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.rectangle,
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(color: color, width: 2),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    for (int i = 0; i < bends.length; i++) {
      out.add(
        Positioned(
          key: ValueKey('cabling_bend_${bundle.id}_$i'),
          left: bends[i].dx - r,
          top: bends[i].dy - r,
          child: GestureDetector(
            // Local while the pointer is down, one write on release: see
            // [_bendRunId].
            onPanStart: (_) => setState(() {
              _bendRunId = bundle.id;
              _bendIndex = i;
              _bendDelta = Offset.zero;
            }),
            onPanUpdate: (d) => setState(() => _bendDelta += d.delta),
            onPanEnd: (_) {
              final moved = _bendDelta;
              setState(() {
                _bendRunId = '';
                _bendIndex = -1;
                _bendDelta = Offset.zero;
              });
              if (moved == Offset.zero) return;
              provider.setCablingBundleWaypoints(bundle.id, bends);
            },
            onPanCancel: () => setState(() {
              _bendRunId = '';
              _bendIndex = -1;
              _bendDelta = Offset.zero;
            }),
            onDoubleTap: () => provider.setCablingBundleWaypoints(
              bundle.id,
              List<Offset>.from(bends)..removeAt(i),
            ),
            child: Tooltip(
              message: 'Drag to route this run - it snaps square with the '
                  'bends either side · double-click to drop it',
              child: Container(
                width: r * 2,
                height: r * 2,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return out;
  }

  /// Commits a box drag: one undo entry, and a landing spot clear of the rest.
  ///
  /// [box] is the PREVIEWED box, so its position already carries the drag —
  /// which is what makes this one write rather than one per pointer event.
  void _endBoxDrag(
    AppStateProvider provider,
    CablingSchematic drawing,
    CablingBox box,
  ) {
    final id = _dragId;
    final moved = _dragOffset;
    setState(() {
      _dragId = '';
      _dragOffset = Offset.zero;
    });
    if (id.isEmpty || moved == Offset.zero) return;
    provider.setCablingBoxPosition(
      id,
      nonOverlappingPosition(
        desired: _snapped(provider, _clamped(box.pos)),
        size: box.size,
        others: [
          for (final other in drawing.boxes)
            if (other.id != id) other.rect,
        ],
        // Grid-sized rings, so a box that has to slide off a neighbor stays on
        // the grid it was just snapped to.
        step: provider.snapDiagramsToGrid ? kDiagramGridStep : 16,
      ),
    );
  }

  Widget _box(
    BuildContext context,
    AppStateProvider provider,
    CablingSchematic drawing,
    CablingBox box,
  ) {
    final theme = Theme.of(context);
    final selected = box.id == _selectedId;
    final isNote = box.kind == CablingBoxKind.note;
    final isPathway = box.kind == CablingBoxKind.pathway;
    final isDevice = box.kind == CablingBoxKind.device;

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
            setState(() => _runFrom = '');
            _select(added?.id ?? '');
            if (added != null) {
              _snack('Run added - its count and cable type are in the bar '
                  'above the drawing.');
            }
            return;
          }
          _select(box.id);
        },
        // Everything that can be done to this box, where the pointer already
        // is. The selection bar has the same actions; a drawing is edited by
        // pointing at the thing, and making somebody travel to a bar at the
        // top of the page for every rename is the reason that bar was missed.
        onSecondaryTapDown: (d) =>
            _showBoxMenu(provider, drawing, box, d.globalPosition),
        onPanStart: (_) {
          _select(box.id);
          setState(() {
            _dragId = box.id;
            _dragOffset = Offset.zero;
          });
        },
        onPanUpdate: (d) => setState(() => _dragOffset += d.delta),
        // Land clear of the other boxes, the way the signal flow does. A box
        // dropped on top of another hides both and makes the runs between
        // them unreadable, so a drop that would overlap slides to the nearest
        // free spot instead.
        onPanEnd: (_) => _endBoxDrag(provider, drawing, box),
        onPanCancel: () => setState(() {
          _dragId = '';
          _dragOffset = Offset.zero;
        }),
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
                // The label the user typed, not a fixed caption: a room whose
                // route out is "Conduit to IDF-2B" said so on the drawing and
                // then had it painted over with somebody else's wording.
                ? RotatedBox(
                    quarterTurns: 3,
                    child: Center(
                      child: Text(
                        box.label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          fontStyle: FontStyle.italic,
                          color: theme.brightness == Brightness.dark
                              ? Colors.white
                              : Colors.black87,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                      // The same icon the schematic gives the same device, so
                      // the projector is the same picture on every sheet.
                      if (isDevice) ...[
                        Icon(
                          cablingDeviceIcon(box.shape),
                          size: 26,
                          color: theme.brightness == Brightness.dark
                              ? Colors.white70
                              : Colors.black87,
                        ),
                        const SizedBox(height: 4),
                      ],
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
                            // The box is sized to the text, so the text is
                            // allowed to use it. The cap is a backstop for a
                            // note somebody pasted a page into, not a limit
                            // anybody should meet.
                            overflow: TextOverflow.ellipsis,
                            maxLines: isNote ? 90 : 14,
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
///
/// Runs sharing an edge are drawn as parallel lines in their own colours, and
/// their labels are stacked into ONE block beside the middle of the edge —
/// "6x Cat 6a" over "5x Cat 5e", each with a dash of its own colour. Two
/// captions at the same midpoint would sit on top of each other, which is how
/// a drawing quietly loses half of what it is supposed to be ordering.
/// The short line drawn beside a cable's name in the key. Painted rather than
/// built out of widgets so it goes through exactly the code the drawing does:
/// a legend drawn a second way is a legend that eventually disagrees.
class _KeySpecimenPainter extends CustomPainter {
  final Color color;
  final RunLineStyle style;

  const _KeySpecimenPainter({required this.color, required this.style});

  @override
  void paint(Canvas canvas, Size size) {
    paintRunSpecimen(
      canvas: canvas,
      from: Offset(0, size.height / 2),
      to: Offset(size.width, size.height / 2),
      color: color,
      style: style,
    );
  }

  @override
  bool shouldRepaint(_KeySpecimenPainter old) =>
      old.color != color || old.style != style;
}

class _BundlePainter extends CustomPainter {
  final CablingSchematic drawing;
  final Map<String, double> lanes;

  /// The path each run actually takes, routed around the boxes in its way.
  final Map<String, List<Offset>> routes;

  final String selectedId;
  final Set<String> overridden;

  /// The boxes and the key — everything a caption must not land on.
  final List<Rect> keepClear;

  /// The caption blocks, laid out by [cablingCaptions] before the frame so the
  /// drawing and the drag pads over it cannot disagree about where a label is.
  final List<_CablingCaption> captions;

  final bool dark;

  const _BundlePainter({
    required this.drawing,
    required this.lanes,
    required this.routes,
    required this.captions,
    required this.selectedId,
    required this.overridden,
    required this.keepClear,
    required this.dark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // --- the lines ---------------------------------------------------------
    // Drawn in order, each hopping over the ones already down. Two lines
    // meeting at a point is, on a cabling drawing, indistinguishable from two
    // lines JOINING at a point, and a sheet that cannot say which is which is
    // a sheet somebody lands the wrong cable off.
    final styles = drawing.bundleLineStyles;
    final drawn = <List<Offset>>[];
    for (final bundle in drawing.bundles) {
      final route = routes[bundle.id];
      if (route == null || route.length < 2) continue;
      final offSheet = drawing.isOffSheet(bundle);
      paintRun(
        canvas: canvas,
        route: route,
        color: Color(bundle.color),
        strokeWidth: bundle.id == selectedId ? 4 : 2.4,
        style: styles[bundle.id] ?? RunLineStyle.solid,
        // Rounded corners rather than square ones: a cabling drawing shows
        // cable, and cable does not turn a right angle in a ceiling.
        cornerRadius: 9,
        hops: offSheet ? const [] : routeCrossings(route, drawn),
        offSheet: offSheet,
      );
      drawn.add(route);
    }

    // --- one caption block per edge ----------------------------------------
    // Laid out BEFORE the frame — see [cablingCaptions] — so the boxes drawn
    // here are the same boxes the page puts drag targets over. A label
    // somebody grabs has to be the label they can see.
    final taken = [...keepClear];
    for (final caption in captions) {
      _paintCaption(canvas, caption);
      taken.add(caption.box);
    }

    // What each run TERMINATES INTO, beside its own end of the line, last so
    // it sits over the runs rather than under the next one drawn. Each dodges
    // everything already down, the captions included.
    //
    // Anchored clear of the box it leaves: a run starts at the CENTRE of its
    // box and the boxes are drawn over the lines, so a label a fixed distance
    // in from the end of the route would be printed underneath the box.
    for (final bundle in drawing.bundles) {
      final route = routes[bundle.id];
      if (route == null || route.length < 2) continue;
      for (final end in [
        (text: bundle.fromLabel, atStart: true, boxId: bundle.fromBoxId),
        (text: bundle.toLabel, atStart: false, boxId: bundle.toBoxId),
      ]) {
        if (end.text.trim().isEmpty) continue;
        final anchor = runEndAnchor(
          route,
          atStart: end.atStart,
          clearOf: drawing.boxById(end.boxId)?.rect,
        );
        if (anchor == null) continue;
        final placed = paintRunEndLabel(
          canvas: canvas,
          text: end.text,
          at: anchor.at,
          towards: anchor.towards,
          color: Color(bundle.color),
          dark: dark,
          taken: taken,
        );
        if (placed != null) taken.add(placed);
      }
    }
  }

  /// Draws one caption block where [cablingCaptions] put it.
  void _paintCaption(Canvas canvas, _CablingCaption caption) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(caption.box, const Radius.circular(3)),
      Paint()..color = dark ? const Color(0xE614181C) : const Color(0xE6FFFFFF),
    );

    double y = caption.box.top + _kCaptionPad;
    final left = caption.box.left + _kCaptionPad;
    for (final row in caption.rows) {
      // The dash is the key: it is what ties "6x Cat 6a" to the line it names
      // when three run side by side — so it is stroked in that run's own
      // pattern, not just its colour, or the tie breaks the moment the sheet
      // is printed in black and white.
      paintRunSpecimen(
        canvas: canvas,
        from: Offset(left, y + row.text.height / 2),
        to: Offset(left + _kCaptionDash, y + row.text.height / 2),
        color: row.color,
        style: row.style,
      );
      row.text.paint(canvas, Offset(left + _kCaptionDash + _kCaptionGap, y));
      y += row.text.height + _kCaptionRowGap;
    }
  }

  /// [wanted] if nothing is already there, else the nearest spot that is
  /// clear.
  ///
  /// Straight up and down first, so a caption stays ON the run it names and
  /// only slides sideways when there is nowhere above or below it. Gives up
  /// after a few rings and uses the original spot rather than flinging a label
  /// across the sheet to somewhere it explains nothing — a caption a little
  /// crowded is readable; a caption pointing at the wrong line is not.
  static Rect _freeCaptionBox(Size size, Offset wanted, List<Rect> taken) {
    Rect at(Offset o) => Rect.fromLTWH(o.dx, o.dy, size.width, size.height);
    bool free(Rect r) {
      final padded = r.inflate(4);
      for (final other in taken) {
        if (padded.overlaps(other)) return false;
      }
      return true;
    }

    if (free(at(wanted))) return at(wanted);

    const step = 16.0;
    for (int ring = 1; ring <= 16; ring++) {
      for (final d in const [
        Offset(0, -1),
        Offset(0, 1),
        Offset(-1, 0),
        Offset(1, 0),
        Offset(-1, -1),
        Offset(1, -1),
        Offset(-1, 1),
        Offset(1, 1),
      ]) {
        final candidate = at(wanted + d * (ring * step));
        if (free(candidate)) return candidate;
      }
    }
    return at(wanted);
  }

  @override
  bool shouldRepaint(_BundlePainter old) =>
      old.drawing != drawing ||
      old.lanes != lanes ||
      old.routes != routes ||
      old.captions != captions ||
      old.selectedId != selectedId ||
      old.keepClear != keepClear ||
      old.dark != dark;
}

/// The padding, dash and gaps a caption block is laid out with. Shared by the
/// layout below and the painter, which is the only way the box a label is
/// dragged by can be the box it is drawn in.
const double _kCaptionPad = 3;
const double _kCaptionDash = 14;
const double _kCaptionGap = 5;
const double _kCaptionRowGap = 2;

/// One caption block: the runs it names, the box it occupies, and whether it
/// was put there by hand.
typedef _CablingCaption = ({
  /// The pair of boxes this block belongs to — [CablingSchematic.bundlesByEdge]
  /// — which is what a moved label is remembered under.
  String edgeKey,
  Rect box,

  /// True when somebody dragged this one. The sheet then leaves it exactly
  /// there instead of walking it clear of what it overlaps: a label moved by
  /// hand has been moved for a reason the drawing cannot see.
  bool moved,
  List<({TextPainter text, Color color, RunLineStyle style})> rows,
});

/// Where every run caption goes on the drawing.
///
/// One block per pair of boxes: six Cat 6a and five Cat 5e between the same
/// two places is one stack of two lines, not two labels on top of each other.
/// Each block dodges the boxes, the key and everything captioned before it —
/// unless it carries a nudge in [nudges], in which case it goes exactly where
/// it was put and the ones after it dodge IT.
///
/// Laid out here rather than inside paint() for the same reason the routes
/// are: the page needs the boxes to put drag pads over, and a label somebody
/// grabs has to be the label they can see.
List<_CablingCaption> _cablingCaptions({
  required CablingSchematic drawing,
  required Map<String, List<Offset>> routes,
  required List<Rect> keepClear,
  required Map<String, Offset> nudges,
  required String selectedId,
  required Set<String> overridden,
  required bool dark,
  /// Edge keys whose caption this sheet does not print. See
  /// [CablingOverrides.hiddenLabels].
  Set<String> hiddenLabels = const {},
  /// The sheet itself, so a label cannot be dragged off the edge of it — off
  /// the drawing is off the exported PNG, and a label the pointer has carried
  /// past the border is one the drag is cancelled on halfway.
  Size canvasSize = Size.zero,
}) {
  final styles = drawing.bundleLineStyles;
  final out = <_CablingCaption>[];
  final taken = [...keepClear];

  for (final entry in drawing.bundlesByEdge.entries) {
    if (hiddenLabels.contains(entry.key)) continue;
    final group = entry.value;
    // Halfway ALONG the route rather than halfway between the boxes: on a run
    // that detours around a rack the straight-line midpoint can land well off
    // the line it is supposed to be labelling.
    final route = routes[group.first.id];
    if (route == null || route.isEmpty) continue;

    final rows = <({TextPainter text, Color color, RunLineStyle style})>[];
    for (final bundle in group) {
      // "4x AV cabling" in the bold italic a cabling drawing labels its
      // bundles in, with the signal on a second, lighter line under it:
      // "AV cabling" is what gets pulled, "HDBaseT / DTP" is what gets landed.
      final sub = bundle.signalSubLabel;
      final edited = overridden.contains(bundle.id);
      final selected = bundle.id == selectedId;
      rows.add((
        color: Color(bundle.color),
        style: styles[bundle.id] ?? RunLineStyle.solid,
        text: TextPainter(
          text: TextSpan(
            text: '${bundle.label}${edited ? '  ✎' : ''}',
            style: TextStyle(
              color: dark ? Colors.white : Colors.black87,
              fontSize: selected ? 12.5 : 11.5,
              fontWeight: FontWeight.bold,
              fontStyle: FontStyle.italic,
              // The selected run is underlined rather than recoloured: its
              // colour is data on this drawing and must not move to say
              // "picked".
              decoration: selected ? TextDecoration.underline : null,
            ),
            children: sub.isEmpty
                ? null
                : [
                    TextSpan(
                      text: '\n$sub',
                      style: TextStyle(
                        color: dark ? Colors.white70 : Colors.black54,
                        fontSize: 10,
                        fontWeight: FontWeight.normal,
                        fontStyle: FontStyle.italic,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
          ),
          textDirection: TextDirection.ltr,
        )..layout(),
      ));
    }
    if (rows.isEmpty) continue;

    double width = 0;
    double height = 0;
    for (final row in rows) {
      final w = _kCaptionDash + _kCaptionGap + row.text.width;
      if (w > width) width = w;
      height += row.text.height + _kCaptionRowGap;
    }
    height -= _kCaptionRowGap;

    final anchor = polylineMidpoint(route);
    final wanted = Offset(anchor.dx - width / 2, anchor.dy - height - 6);
    final nudge = nudges[entry.key] ?? Offset.zero;
    final inner = nudge == Offset.zero
        ? _BundlePainter._freeCaptionBox(Size(width, height), wanted, taken)
        : Rect.fromLTWH(
            wanted.dx + nudge.dx,
            wanted.dy + nudge.dy,
            width,
            height,
          );
    var box = inner.inflate(_kCaptionPad);
    if (canvasSize != Size.zero) {
      box = Rect.fromLTWH(
        box.left.clamp(0.0, (canvasSize.width - box.width).clamp(0.0,
            double.infinity)),
        box.top.clamp(0.0, (canvasSize.height - box.height).clamp(0.0,
            double.infinity)),
        box.width,
        box.height,
      );
    }
    taken.add(box);
    out.add((
      edgeKey: entry.key,
      box: box,
      moved: nudge != Offset.zero,
      rows: rows,
    ));
  }
  return out;
}
