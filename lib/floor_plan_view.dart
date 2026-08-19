import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'av_flow_model.dart';
import 'av_flow_report.dart';
import 'av_flow_view.dart' show buildAvFlowModel;
import 'av_port_editor.dart' show avRowIcon;
import 'cable_colors_dialog.dart';
import 'cabling_schematic.dart';
import 'color_wheel_picker.dart';
import 'diagram_capture.dart';
import 'export_tools.dart';
import 'layout_tools.dart'
    show pushOutOfRects, rightAngleTurn, snapToRightAngle;
import 'live_text_field.dart';
import 'plan_annotations.dart';
import 'report_tools.dart';
import 'room_sidecar.dart' show AvUndoScope;
import 'run_painting.dart';
import 'undo_bar.dart';
import 'room_locations.dart';
import 'room_locations_view.dart';
import 'screenshot_tools.dart';
import 'side_pane.dart';
import 'view_zoom.dart';
import 'xlsx_writer.dart';

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

/// The sheets worth putting on paper.
///
/// A sheet used to need an image: without one it rendered as the message
/// saying so, and a picture of that message illustrates nothing. A sheet with
/// no image is now blank paper you can lay the room out on, so the test is
/// whether anything has been PLACED on it — a marker, an annotation — rather
/// than whether a drawing sits behind it.
///
/// A sheet somebody named and then did nothing with is still skipped, which is
/// the half of the old rule that was always right.
List<FloorPlan> sheetsWorthDrawing(AppStateProvider provider) => provider
    .avFloorPlans
    .where((s) =>
        s.hasImage || s.markers.isNotEmpty || s.annotations.isNotEmpty)
    .toList();

/// Paper colours offered before the wheel. Papers, not paints: a sheet is
/// something drawn on, and a saturated one makes every marker on it harder to
/// read rather than easier.
/// The colours a sheet can be painted, dark first.
///
/// Every one of them is DECISIVELY dark or decisively light — nothing in the
/// middle. The ink a sheet prints in is chosen from the paper (see
/// [FloorPlan.paperIsDark]), so a mid-grey is the one paper where neither the
/// light ink nor the dark ink has a contrast ratio worth having: the old slate
/// and grey entries were exactly that, and a name plate on them was a plate
/// somebody had to lean in to read. Each of these clears 4.5:1 against the ink
/// it gets, which is the WCAG figure for body text — see the paper test.
const List<Color> kPaperSwatches = [
  Color(0xFF000000), // black — the default
  Color(0xFF10141A), // near-black
  Color(0xFF13202B), // dark slate
  Color(0xFF1B1B2E), // dark navy
  Color(0xFF12251A), // dark green
  Color(0xFF2B2B2B), // charcoal
  Color(0xFFFFFFFF), // white
  Color(0xFFF3F3F3), // near-white
  Color(0xFFE3E5E8), // cool white
  Color(0xFFF6F1E7), // buff
  Color(0xFFE8F0E8), // pale green
  Color(0xFFE7EEF6), // pale blue
];

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

  /// What the notation tool draws, and in what. Sticky between shapes: a
  /// drawing gets marked up in bursts of the same colour.
  PlanShape _shape = PlanShape.arrow;
  int _noteColor = kPlanAnnotationColors.first;
  double _noteStroke = 3;

  /// The shape being dragged out right now, and the one under the cursor.
  PlanAnnotation? _draft;
  String _selectedNoteId = '';
  AnnotationGrip _grip = AnnotationGrip.none;

  /// Holds the keyboard for the drawing area, so Delete removes the selected
  /// shape. Focus is taken when something is picked up rather than on build,
  /// so a text field elsewhere on the page never loses the caret to it.
  final FocusNode _planFocus = FocusNode(debugLabel: 'floor plan notation');

  /// The decoded plan image, and the file it came from.
  ImageProvider? _image;
  String _imagePath = '';
  Size _imageSize = const Size(1200, 900);

  String? _selectedCalloutId;

  /// The run being worked on, by bundle id, or '' when none is.
  ///
  /// A run is picked up by clicking its line. While one is held the sheet
  /// grows a bar for its cable count and shows the handles that steer it, and
  /// nothing else on the drawing changes — a selection is a thing to edit, not
  /// a mark on the paper, so it is cleared before the sheet is exported.
  String _selectedRunId = '';

  /// Which cable runs are drawn over the plan: [_kLayerOff], [_kLayerAll], or
  /// one cable type on its own.
  ///
  /// One type at a time is how a cabling set is actually issued — the network
  /// contractor gets the network sheet and the AV contractor gets theirs — and
  /// a plan with every run on it at once is a plan nobody can trace a single
  /// pull from.
  String _cableLayer = _kLayerAll;

  /// True while the sheet is being drawn the way it should PRINT — light
  /// theme, no colour. Held for the one frame a black-and-white export
  /// captures, then put back; see [printSkin] and [_exportPng].
  bool _printMode = false;

  /// How far the key has been dragged since the pointer went down, or null
  /// while nobody is dragging it. Live, so the panel follows the cursor
  /// without a provider write (and an undo entry) per frame.
  Offset? _keyDrag;

  /// The bend being dragged: which run, which of its bends, and how far it has
  /// come since the pointer went down.
  ///
  /// Held here rather than written to the provider per pointer event, which is
  /// what made steering a run on the plan feel like dragging through treacle:
  /// every move notified every listener, re-routed every run on the sheet and
  /// re-laid out every caption. Now the drag is local and cheap, and the write
  /// — with its undo entry — happens once, on release.
  String _bendRunId = '';
  int _bendIndex = -1;
  Offset _bendDelta = Offset.zero;

  /// The caption being dragged, by [_PlanRun.edgeKey], and how far it has come
  /// since the pointer went down. Held here for the same reason [_keyDrag] is:
  /// the label follows the cursor without a write, and the write happens once
  /// on release so one drag is one undo.
  String _labelDragKey = '';
  Offset _labelDrag = Offset.zero;

  @override
  void initState() {
    super.initState();
    registerDiagramCanvas(AppTab.floorPlan, _planKey);
    // How the rest of the app gets at the OTHER sheets. One canvas key only
    // ever yields the sheet on screen, and every export in the app wants the
    // whole set — see [capturePlanSheets].
    registerPlanSheetCapture(_captureSheets);
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
    unregisterPlanSheetCapture(_captureSheets);
    _transform.dispose();
    _planFocus.dispose();
    super.dispose();
  }

  /// Selects a shape and takes the keyboard, so Delete lands on it.
  void _selectNote(String id) {
    setState(() => _selectedNoteId = id);
    if (id.isNotEmpty) _planFocus.requestFocus();
  }

  /// Delete / Backspace removes whatever is selected on the drawing.
  ///
  /// Every other handled key is passed through, so typing into the label
  /// dialog — or anywhere else on the page — is untouched.
  KeyEventResult _onPlanKey(FloorPlan? plan, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final isDelete = event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace;
    if (!isDelete || plan == null || _selectedNoteId.isEmpty) {
      return KeyEventResult.ignored;
    }
    context.read<AppStateProvider>().removeAvAnnotation(
      plan.id,
      _selectedNoteId,
    );
    setState(() => _selectedNoteId = '');
    return KeyEventResult.handled;
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: error ? Colors.red : null),
    );
  }

  void _savedSnack(AppStateProvider provider, String what, String file) {
    if (!mounted) return;
    showSavedFileSnack(context, provider, what, file);
  }

  void _syncImage(AppStateProvider provider) {
    final plan = provider.activeFloorPlan;
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

    final existing = provider.activeFloorPlan;
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

  /// EVERY sheet in the room as PNG bytes — the one drawing-capture the whole
  /// app goes through, registered with [registerPlanSheetCapture] so the
  /// exports that live elsewhere can ask for the set without knowing how this
  /// page works.
  ///
  /// Only a widget on screen can be rendered, so the sheets are fetched the
  /// only way there is: point the page at each one, let it paint, capture it,
  /// and put the sheet picker back where it was. Before this every exporter
  /// captured whichever sheet happened to be open, which is how a set gets
  /// issued with the ceiling plan missing.
  ///
  /// [perLayer] adds one drawing per cable type after each sheet's own, which
  /// is how a cabling set is issued: the network contractor gets the network
  /// drawing of each storey and nobody has to read around somebody else's
  /// runs. Without it each sheet is captured once, showing whatever the layer
  /// picker is set to.
  ///
  /// [monochrome] renders them the way they should print. The print skin is a
  /// WIDGET, not a filter over the bytes, so the drawing is re-laid-out in the
  /// light theme before it is captured — a dark-mode capture converted to grey
  /// is a black page with pale lines on it, which a printer renders as a black
  /// page. It is held for exactly as long as the walk takes and then put back,
  /// so the tab the user is looking at does not change colour under them.
  Future<List<PlanDrawing>> _captureSheets({
    bool perLayer = false,
    bool monochrome = false,
  }) async {
    final provider = context.read<AppStateProvider>();
    final drawing = provider.cablingSchematic(buildAvFlowModel(provider));
    final startingSheet = provider.activeFloorPlan?.id ?? '';
    final drawn = sheetsWorthDrawing(provider);
    final sheets = <FloorPlan?>[
      if (drawn.isEmpty) provider.activeFloorPlan else ...drawn,
    ];
    final many = sheets.length > 1;

    final out = <PlanDrawing>[];
    // The report's own tables are already on a sheet called Locations, so no
    // drawing may claim that name.
    final taken = <String>{'locations'};
    final wasLayer = _cableLayer;
    // A run held for editing carries drag handles, and a selection is a thing
    // being edited rather than a mark on the paper: the handles must not turn
    // up on a sheet somebody is issued. Put it down for the walk and pick it
    // back up after.
    final heldRun = _selectedRunId;
    if (heldRun.isNotEmpty || monochrome) {
      setState(() {
        _selectedRunId = '';
        if (monochrome) _printMode = true;
      });
      await WidgetsBinding.instance.endOfFrame;
    }

    try {
      for (final sheet in sheets) {
        if (!mounted) break;
        if (sheet != null && sheet.id != (provider.activeFloorPlan?.id ?? '')) {
          if (!await _showSheet(provider, sheet)) break;
        }

        // Per sheet: a cable type only earns a layer on the plan it actually
        // lands on.
        final layers = perLayer
            ? _cableLayers(provider, sheet, drawing).map((l) => l.type)
            : const <String>[];
        final wanted = [
          if (perLayer) _kLayerAll else _cableLayer,
          ...layers,
        ];
        for (final layer in wanted) {
          if (!mounted) break;
          if (layer != _cableLayer) {
            setState(() => _cableLayer = layer);
            // Let the change actually paint before the boundary is captured;
            // without this every image would be of whatever was on screen when
            // the loop started.
            await WidgetsBinding.instance.endOfFrame;
            if (!mounted) break;
          }
          final bytes = await captureBoundary(_planKey, pixelRatio: 2.0);
          if (bytes == null) continue;
          // What this drawing is called. One-per-sheet is named for the sheet;
          // per-layer is named for the layer, with the sheet in front of it
          // only once there is more than one — a room with a single plan reads
          // exactly as it always has.
          final planName = sheet?.name.trim() ?? '';
          final String caption;
          if (!perLayer) {
            caption = planName.isEmpty ? 'Floor plan' : planName;
          } else {
            final what = layer == _kLayerAll ? 'All runs' : layer;
            caption = many && planName.isNotEmpty ? '$planName — $what' : what;
          }
          out.add((
            name: uniqueXlsxSheetName(caption, taken),
            caption: caption,
            bytes: bytes,
          ));
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _cableLayer = wasLayer;
          _selectedRunId = heldRun;
          _printMode = false;
        });
        if (startingSheet.isNotEmpty) provider.selectFloorPlan(startingSheet);
      }
    }
    return out;
  }

  /// Puts [sheet] on screen and waits until its drawing is actually there.
  ///
  /// The drawing behind a sheet is a file that has to be read and decoded, and
  /// a capture taken before it is ready is a picture of the PREVIOUS sheet —
  /// which is how two plans come out of an export with the same image on them.
  /// False when the page went away mid-walk.
  Future<bool> _showSheet(AppStateProvider provider, FloorPlan sheet) async {
    provider.selectFloorPlan(sheet.id);
    _syncImage(provider);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return false;
    final image = _image;
    if (image != null) {
      try {
        await precacheImage(image, context);
      } catch (_) {
        // A missing or unreadable drawing is not worth failing the whole
        // export over: the sheet comes out the way the page shows it.
      }
    }
    if (!mounted) return false;
    await WidgetsBinding.instance.endOfFrame;
    return mounted;
  }

  /// The plan as an image — every sheet in the room, as the page is showing
  /// them.
  ///
  /// A room with one sheet writes one file, picked and named the way it always
  /// was. A room with several writes one per sheet into a folder, because a
  /// drawing set is the set: handing over the storey that happened to be open
  /// is how the other one goes missing.
  Future<void> _exportPng(
    AppStateProvider provider, {
    bool monochrome = false,
  }) async {
    final stem = roomFileStem(
      provider,
      monochrome ? 'floor_plan_bw' : 'floor_plan',
    );
    final what = monochrome ? 'Floor plan (black & white)' : 'Floor plan';

    if (sheetsWorthDrawing(provider).length > 1) {
      final folder = await FilePicker.getDirectoryPath(
        dialogTitle: monochrome
            ? 'Where should the sheets for printing go?'
            : 'Where should the sheet images go?',
      );
      if (folder == null) return;
      await _writePngFolder(
        provider,
        folder,
        await _captureSheets(monochrome: monochrome),
        monochrome ? 'sheet for printing' : 'sheet image',
        suffix: monochrome ? 'floor_plan_bw' : 'floor_plan',
      );
      return;
    }

    final drawings = await _captureSheets(monochrome: monochrome);
    if (drawings.isEmpty) {
      _snack('Could not render the plan to an image.', error: true);
      return;
    }
    String? outputFile = await FilePicker.saveFile(
      dialogTitle: monochrome
          ? 'Save the floor plan for printing'
          : 'Save the floor plan image',
      fileName: '$stem.png',
      type: FileType.custom,
      allowedExtensions: const ['png'],
    );
    if (outputFile == null) return;
    if (!outputFile.toLowerCase().endsWith('.png')) outputFile += '.png';
    try {
      await File(outputFile).writeAsBytes(drawings.first.bytes);
      _savedSnack(provider, what, outputFile);
    } catch (e) {
      _snack('Failed to save the image: $e', error: true);
    }
  }

  /// The location report, as a workbook or as plain text.
  ///
  /// The workbook is the one that gets sent: it carries the tables AND the
  /// drawings they describe — every sheet in the room, every layer of each, a
  /// tab apiece — so the person reading "6 runs to the front floor box" can
  /// see which six and where they go without a second attachment. The text
  /// file stays for a quick look and for pasting into an email.
  Future<void> _exportReport(
    AppStateProvider provider, {
    required bool asXlsx,
  }) async {
    final model = buildAvFlowModel(provider);
    final sections = locationSections(model);
    if (sections.isEmpty) {
      _snack('Nothing to report yet — no locations, runs or callouts.');
      return;
    }
    final title = model.roomTitle.isEmpty ? 'Floor plan' : model.roomTitle;
    final ext = asXlsx ? 'xlsx' : 'txt';
    String? outputFile = await FilePicker.saveFile(
      dialogTitle: 'Save the location report',
      fileName: '${roomFileStem(provider, 'locations')}.$ext',
      type: FileType.custom,
      allowedExtensions: [ext],
    );
    if (outputFile == null) return;
    if (!outputFile.toLowerCase().endsWith('.$ext')) outputFile += '.$ext';

    try {
      if (asXlsx) {
        // One moment for the whole book: sheets stamped seconds apart read as
        // documents from two different exports.
        final generated = DateTime.now();
        // Every plan in the room, not just the one that happened to be open:
        // a set issued with the ceiling plan missing is a set somebody has to
        // ask for again.
        final layers = await _captureSheets(perLayer: true);
        final first = layers.isEmpty ? null : layers.first;
        await File(outputFile).writeAsBytes(
          buildXlsx([
            buildStackedReportSheet(
              sheetName: 'Locations',
              title: title,
              sections: sections,
              generated: generated,
              imageBuilder: first == null
                  ? null
                  : (anchorRow) => scaledSheetImage(first.bytes, anchorRow),
            ),
            // One sheet per plan per cable type, which is how a cabling set is
            // issued: the network contractor gets the network drawing of each
            // storey and nobody has to read around somebody else's runs. The
            // first one is already printed above, under the tables.
            for (final layer in layers.skip(1))
              drawingSheet(title, layer, generated),
          ]),
        );
      } else {
        await File(outputFile).writeAsString(
          renderTextReport(title, sections),
        );
      }
      _savedSnack(provider, 'Location report', outputFile);
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
    final plan = provider.activeFloorPlan;
    // Built once and handed down: the layer chips, the runs and the count of
    // what could not be placed are three readings of the same drawing.
    final drawing = provider.cablingSchematic(model);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncImage(provider);
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _toolbar(provider, plan),
        _sheetBar(provider, plan),
        if (plan != null) _layerBar(provider, plan, drawing),
        if (plan != null && _selectedRunId.isNotEmpty)
          _runBar(provider, plan, drawing),
        if (_tool == _PlanTool.notation && plan != null)
          _notationBar(provider, plan),
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
                    : Focus(
                        focusNode: _planFocus,
                        onKeyEvent: (_, event) => _onPlanKey(plan, event),
                        child: InteractiveViewer(
                          transformationController: _transform,
                          constrained: false,
                          // A drag has to draw rather than shove the sheet
                          // sideways while the notation tool is on. Zoom still
                          // works — that is the scroll wheel, not a drag.
                          panEnabled: _tool != _PlanTool.notation,
                          minScale: 0.08,
                          maxScale: 4.0,
                          boundaryMargin: const EdgeInsets.all(400),
                          child: RepaintBoundary(
                            key: _planKey,
                            // Inside the boundary, so the black-and-white
                            // export captures exactly what it draws — see
                            // [printSkin]. A Builder because the drawing reads
                            // the theme this substitutes.
                            child: printSkin(
                              enabled: _printMode,
                              child: Builder(
                                builder: (ctx) =>
                                    _plan(ctx, provider, model, plan, drawing),
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
              // Draggable and foldable: the sheet is the point of this page,
              // and on a laptop the list beside it is a third of the window.
              SidePane(
                side: PaneSide.right,
                title: 'Sheet & locations',
                storageKey: 'floor_plan_side',
                child: _sidePanel(provider, model, plan),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// What the notation tool is about to draw, and what to do with whatever is
  /// selected. Only on screen while the tool is, so the page stays as quiet as
  /// it was for somebody who only came to look at the plan.
  /// The bar for the run being worked on: what it is, how many cables are in
  /// it, and the way back from a route steered by hand.
  ///
  /// A bar rather than a dialog, and the same fields the Cabling tab puts in
  /// its own selection bar. The count is the number somebody came to the
  /// drawing to change — typing it should not mean answering a modal — and
  /// while the bar is up the bends are on the line, so the two halves of
  /// "this pull is bigger than we thought and it goes the other way round"
  /// are one visit.
  Widget _runBar(
    AppStateProvider provider,
    FloorPlan plan,
    CablingSchematic drawing,
  ) {
    final theme = Theme.of(context);
    final bundle = drawing.bundleById(_selectedRunId);
    if (bundle == null) return const SizedBox.shrink();
    final from = drawing.boxById(bundle.fromBoxId)?.label ?? bundle.fromBoxId;
    final to = drawing.boxById(bundle.toBoxId)?.label ?? bundle.toBoxId;
    final bends = plan.waypointsFor(bundle.id);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Container(
            width: 22,
            height: 4,
            margin: const EdgeInsets.only(right: 2),
            color: Color(bundle.color),
          ),
          Text('$from  →  $to', style: theme.textTheme.bodySmall),
          // Committed on Enter or on clicking away rather than per keystroke,
          // exactly as on the Cabling tab: the count goes through the undo
          // stack, and "13" typed a digit at a time would leave "1" behind as
          // an entry of its own.
          SizedBox(
            width: 96,
            child: LiveTextField(
              key: ValueKey('plan_run_count_${bundle.id}'),
              fieldId: 'planCount:${bundle.id}',
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
          Text(
            bundle.cableType.trim().isEmpty ? 'Cable' : bundle.cableType,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(width: 8),
          Text(
            bends.isEmpty
                ? 'Drag a hollow dot onto the line to turn it'
                : '${bends.length} bend${bends.length == 1 ? '' : 's'} on this '
                      'sheet',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.disabledColor,
            ),
          ),
          if (bends.isNotEmpty)
            TextButton.icon(
              key: const ValueKey('plan_straighten_run'),
              icon: const Icon(Icons.timeline, size: 16),
              label: const Text('Straighten'),
              onPressed: () =>
                  provider.setAvRunWaypoints(plan.id, bundle.id, const []),
            ),
          TextButton.icon(
            icon: const Icon(Icons.close, size: 16),
            label: const Text('Done'),
            onPressed: () => setState(() => _selectedRunId = ''),
          ),
        ],
      ),
    );
  }

  Widget _notationBar(AppStateProvider provider, FloorPlan plan) {
    final theme = Theme.of(context);
    final selected =
        plan.annotations.where((a) => a.id == _selectedNoteId).firstOrNull;

    /// Edits the selected shape, or sets the default for the next one when
    /// nothing is selected — so the same two controls do both jobs.
    void apply({int? color, double? stroke}) {
      setState(() {
        if (color != null) _noteColor = color;
        if (stroke != null) _noteStroke = stroke;
      });
      if (selected == null) return;
      provider.updateAvAnnotation(
        plan.id,
        selected.copyWith(color: color, strokeWidth: stroke),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SegmentedButton<PlanShape>(
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              for (final s in PlanShape.values)
                ButtonSegment(
                  value: s,
                  icon: Icon(
                    switch (s) {
                      PlanShape.arrow => Icons.arrow_outward,
                      PlanShape.line => Icons.horizontal_rule,
                      PlanShape.rectangle => Icons.crop_square,
                      PlanShape.ellipse => Icons.circle_outlined,
                      PlanShape.text => Icons.title,
                    },
                    size: 16,
                  ),
                  tooltip: kPlanShapeLabels[s],
                ),
            ],
            selected: {_shape},
            onSelectionChanged: (s) => setState(() => _shape = s.first),
            showSelectedIcon: false,
          ),
          for (final c in kPlanAnnotationColors)
            Tooltip(
              message: 'Draw in this colour',
              child: InkWell(
                onTap: () => apply(color: c),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: (selected?.color ?? _noteColor) == c
                          ? theme.colorScheme.primary
                          : theme.dividerColor,
                      width: (selected?.color ?? _noteColor) == c ? 3 : 1,
                    ),
                  ),
                ),
              ),
            ),
          SizedBox(
            width: 130,
            child: Slider(
              value: (selected?.strokeWidth ?? _noteStroke).clamp(1, 10),
              min: 1,
              max: 10,
              divisions: 9,
              label: 'Weight '
                  '${(selected?.strokeWidth ?? _noteStroke).round()}',
              onChanged: (v) => apply(stroke: v),
            ),
          ),
          if (selected == null)
            Text(
              _shape == PlanShape.text
                  ? 'Drag out a box for the text.'
                  : 'Drag to draw. Click a shape to pick it up.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.disabledColor,
              ),
            )
          else ...[
            TextButton.icon(
              icon: const Icon(Icons.text_fields, size: 16),
              label: Text(
                selected.text.trim().isEmpty ? 'Add label' : 'Edit label',
              ),
              onPressed: () async {
                final text = await _askForText(selected.text);
                if (text == null) return;
                provider.updateAvAnnotation(
                  plan.id,
                  selected.copyWith(text: text.trim()),
                );
              },
            ),
            Tooltip(
              message: 'Or press Delete',
              child: TextButton.icon(
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Delete'),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                onPressed: () {
                  provider.removeAvAnnotation(plan.id, selected.id);
                  setState(() => _selectedNoteId = '');
                },
              ),
            ),
          ],
          const SizedBox(width: 4),
          Text(
            '${plan.annotations.length} on this sheet',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.disabledColor,
            ),
          ),
        ],
      ),
    );
  }

  /// The sheet bar: one chip per plan, plus the ways to get another.
  ///
  /// A room has more than one sheet as soon as it has more than one storey, a
  /// reflected ceiling plan beside the furniture plan, or a demolition sheet
  /// beside the new work. The model always held a LIST of plans; until now the
  /// page only ever opened the first one, so the second was unreachable.
  ///
  /// Hidden entirely when there is nothing to choose between: a bar with one
  /// chip on it is a row of pixels asking to be ignored.
  Widget _sheetBar(AppStateProvider provider, FloorPlan? active) {
    final sheets = provider.avFloorPlans;
    if (sheets.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Icon(Icons.layers_outlined, size: 16, color: theme.disabledColor),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (int i = 0; i < sheets.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: InputChip(
                        selected: sheets[i].id == active?.id,
                        showCheckmark: false,
                        avatar: Icon(
                          sheets[i].hasImage
                              ? Icons.map_outlined
                              // A sheet with no drawing behind it yet is still
                              // a sheet — named and ordered before the PDF for
                              // it turns up.
                              : Icons.insert_drive_file_outlined,
                          size: 16,
                        ),
                        label: Text(
                          sheets[i].name.trim().isEmpty
                              ? 'Sheet ${i + 1}'
                              : sheets[i].name,
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: () => provider.selectFloorPlan(sheets[i].id),
                        onDeleted: sheets.length == 1
                            ? null
                            : () => _confirmRemoveSheet(provider, sheets[i]),
                        deleteIcon: const Icon(Icons.close, size: 14),
                        deleteButtonTooltipMessage: 'Remove this sheet',
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add sheet'),
            onPressed: () => _renameSheet(
              provider,
              provider.addFloorPlanSheet(),
              title: 'New sheet',
            ),
          ),
          if (active != null) ...[
            avRowIcon(
              Icons.drive_file_rename_outline,
              'Rename this sheet',
              () => _renameSheet(provider, active, title: 'Rename sheet'),
            ),
            avRowIcon(
              Icons.copy_all_outlined,
              // The way a reflected ceiling plan gets started: from the
              // furniture plan that already has every marker on it.
              'Duplicate this sheet with its callouts and markers',
              () => provider.duplicateFloorPlanSheet(active.id),
            ),
            avRowIcon(
              Icons.arrow_back,
              'Move this sheet earlier',
              sheets.first.id == active.id
                  ? null
                  : () => provider.moveFloorPlanSheet(
                        active.id,
                        sheets.indexWhere((p) => p.id == active.id) - 1,
                      ),
            ),
            avRowIcon(
              Icons.arrow_forward,
              'Move this sheet later',
              sheets.last.id == active.id
                  ? null
                  : () => provider.moveFloorPlanSheet(
                        active.id,
                        sheets.indexWhere((p) => p.id == active.id) + 1,
                      ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _renameSheet(
    AppStateProvider provider,
    FloorPlan sheet, {
    required String title,
  }) async {
    final controller = TextEditingController(text: sheet.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Sheet name',
              hintText: 'e.g. Level 2, Reflected ceiling, Demolition',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
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
    if (name == null || name.trim().isEmpty) return;
    provider.updateAvFloorPlan(sheet.copyWith(name: name.trim()));
  }

  Future<void> _confirmRemoveSheet(
    AppStateProvider provider,
    FloorPlan sheet,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${sheet.name}?'),
        content: Text(
          sheet.callouts.isEmpty && sheet.markers.isEmpty
              ? 'The sheet goes; the drawing file it points at stays where it '
                  'is.'
              : 'The sheet goes, and with it '
                  '${[
                    if (sheet.callouts.isNotEmpty)
                      '${sheet.callouts.length} callout'
                          '${sheet.callouts.length == 1 ? '' : 's'}',
                    if (sheet.markers.isNotEmpty)
                      '${sheet.markers.length} location marker'
                          '${sheet.markers.length == 1 ? '' : 's'}',
                  ].join(' and ')}. The drawing file it points at stays where '
                  'it is, and the room\'s locations themselves are not touched '
                  '— they belong to the room, and only where they are DRAWN '
                  'belongs to this sheet.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Remove',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (ok == true) provider.removeAvFloorPlan(sheet.id);
  }

  /// Picks what this sheet's paper is painted.
  ///
  /// Per sheet rather than per room, like everything else a sheet owns: the
  /// blank layout sheet and an imported architectural export want different
  /// backgrounds, and one shared colour would make the second unreadable to
  /// fix the first.
  Future<void> _showPaperColorDialog(
    AppStateProvider provider,
    FloorPlan plan,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final sheet = provider.avFloorPlanById(plan.id) ?? plan;
          return AlertDialog(
            title: Text('Colour for ${sheet.name}'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sheet.hasImage
                        ? 'What sits behind the drawing. An architect export '
                            'is black ink on nothing, so a scan that brings no '
                            'background of its own wants one of the light '
                            'papers under it.'
                        : 'This sheet has no drawing, so the colour IS the '
                            'sheet.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Everything printed on the sheet — run labels, the key — '
                    'takes its ink from the paper, so every colour here reads '
                    'either way.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 2,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ColorSwatchButton(
                        key: const ValueKey('paper_follow_theme'),
                        color: FloorPlan.kPaperDefault,
                        selected: sheet.paperColor == null,
                        badge: Icons.auto_awesome,
                        tooltip: 'Default (black)',
                        onTap: () {
                          provider.setAvPlanPaperColor(sheet.id, null);
                          setLocal(() {});
                        },
                      ),
                      for (final c in kPaperSwatches)
                        ColorSwatchButton(
                          key: ValueKey('paper_'
                              '${(c.toARGB32() & 0xFFFFFF).toRadixString(16)}'),
                          color: c,
                          selected:
                              sheet.paperColor?.toARGB32() == c.toARGB32(),
                          onTap: () {
                            provider.setAvPlanPaperColor(sheet.id, c);
                            setLocal(() {});
                          },
                        ),
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.colorize, size: 16),
                          label: const Text('Custom'),
                          onPressed: () async {
                            final picked = await showColorWheelDialog(
                              ctx,
                              initial: sheet.paper,
                              title: 'Colour for ${sheet.name}',
                            );
                            if (picked != null) {
                              provider.setAvPlanPaperColor(sheet.id, picked);
                              setLocal(() {});
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
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
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
          if (plan != null)
            OutlinedButton.icon(
              key: const ValueKey('plan_paper_color'),
              icon: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: plan.paper,
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              label: const Text('Sheet colour'),
              onPressed: () => _showPaperColorDialog(provider, plan),
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
            // Everything a drawing has to say that a marker cannot: which way
            // the cable leaves, which corner is out of scope, "core drill
            // here".
            FilterChip(
              avatar: const Icon(Icons.draw_outlined, size: 18),
              label: const Text('Notation'),
              selected: _tool == _PlanTool.notation,
              onSelected: (v) => setState(() {
                _tool = v ? _PlanTool.notation : _PlanTool.none;
                if (!v) _selectedNoteId = '';
              }),
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
            // The legend that travels with the exported image. On by default:
            // a sheet coded by icon, colour and dash pattern whose key is
            // opt-in is a sheet that gets mailed out without one.
            FilterChip(
              avatar: const Icon(Icons.legend_toggle, size: 18),
              label: const Text('Key'),
              tooltip: 'Draw the key on the sheet — it is part of the '
                  'exported image',
              selected: !plan.keyHidden,
              onSelected: (v) => provider.updateAvFloorPlan(
                plan.copyWith(keyHidden: !v),
              ),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Plan settings'),
              onPressed: () => _showPlanSettings(provider, plan),
            ),
          ],
          OutlinedButton.icon(
            icon: const Icon(Icons.place_outlined, size: 18),
            // How many of the room's places are on THIS sheet, out of how many
            // there are. A bare total said nothing about the drawing in front
            // of you, which is the number that matters once a room has more
            // than one sheet.
            label: Text(
              plan == null
                  ? 'Locations (${provider.avLocations.length})'
                  : 'Locations (${plan.markers.length}'
                        '/${provider.avLocations.length} on this sheet)',
            ),
            onPressed: () => showLocationManager(context, provider),
          ),
          // The sheets, the places on them and the notation drawn on them.
          ...avUndoRedoButtons(
            provider,
            AvUndoScope.floorPlans,
            onDone: (m) => _snack(m),
          ),
          // How many captions are off the sheet, and the one way back.
          Builder(
            builder: (ctx) {
              final hidden = provider.avCabling.hiddenLabels.length;
              return OutlinedButton.icon(
                key: const ValueKey('plan_labels'),
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
          // Every cable type's colour, the same dialog the Cabling tab
          // opens: the two are drawings of one room's cable, and a network
          // run blue on one and green on the other is two sheets nobody can
          // read together.
          OutlinedButton.icon(
            key: const ValueKey('plan_cable_colors'),
            icon: const Icon(Icons.palette_outlined, size: 18),
            label: const Text('Cable colours'),
            onPressed: () => showCableColorsDialog(
              context,
              provider,
              provider.cablingSchematic(buildAvFlowModel(provider)),
            ),
          ),
          // How the writing on this sheet is printed. On the toolbar rather
          // than buried in a settings page: a plan is recoloured while looking
          // at the plan, usually because the drawing underneath it is dark
          // exactly where the labels landed.
          if (plan != null)
            OutlinedButton.icon(
              key: const ValueKey('plan_label_colors'),
              icon: const Icon(Icons.format_color_text, size: 18),
              label: const Text('Label colours'),
              onPressed: () => _showLabelColorDialog(provider, plan),
            ),
          if (plan != null)
            PopupMenuButton<String>(
              tooltip: 'Export the plan',
              onSelected: (v) => switch (v) {
                'layers' => _exportLayers(provider),
                'bw' => _exportPng(provider, monochrome: true),
                _ => _exportPng(provider),
              },
              // The menu says how many files each of these writes, because
              // that decides whether it asks for a file or a folder: a room
              // with one sheet still writes one image, exactly as before.
              itemBuilder: (ctx) {
                final drawn = sheetsWorthDrawing(provider).length;
                final each = drawn > 1
                    ? 'Every sheet ($drawn .png files)'
                    : 'This view (.png)';
                return [
                  PopupMenuItem(value: 'one', child: Text(each)),
                  // The one that gets printed and marked up on a clipboard.
                  // The runs carry a dash pattern as well as a colour
                  // precisely so this stays readable.
                  PopupMenuItem(
                    value: 'bw',
                    child: Text(
                      drawn > 1
                          ? 'Every sheet, black & white for print (.png)'
                          : 'This view, black & white for print (.png)',
                    ),
                  ),
                  // A drawing per trade: the network contractor gets the
                  // network drawing, the AV contractor gets theirs.
                  const PopupMenuItem(
                    value: 'layers',
                    child: Text('One image per sheet and cable type...'),
                  ),
                ];
              },
              child: IgnorePointer(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.image, size: 18),
                  label: const Text('Export PNG'),
                  onPressed: () {},
                ),
              ),
            ),
          PopupMenuButton<String>(
            key: const ValueKey('plan_report_menu'),
            tooltip: 'Export the location report',
            onSelected: (v) => _exportReport(provider, asXlsx: v == 'xlsx'),
            itemBuilder: (ctx) => const [
              PopupMenuItem(
                value: 'xlsx',
                child: Text('Workbook with the drawings (.xlsx)'),
              ),
              PopupMenuItem(value: 'txt', child: Text('Plain text (.txt)')),
            ],
            child: IgnorePointer(
              child: ElevatedButton.icon(
                icon: const Icon(Icons.summarize, size: 18),
                label: const Text('Location report'),
                onPressed: () {},
              ),
            ),
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

  /// The plan itself: image, cable runs, location markers, callouts.
  Widget _plan(
    BuildContext context,
    AppStateProvider provider,
    AvFlowModel model,
    FloorPlan plan,
    CablingSchematic drawing,
  ) {
    // The IMAGE, and the SHEET it is mounted on: an architectural export draws
    // to its own border, so the key and the notes need paper of their own.
    // Everything on the drawing is in sheet coordinates — see
    // [AppStateProvider.setAvPlanMargins], which shifts the contents when a
    // left or top margin is added so nothing slides off the wall it was on.
    final size = _imageSize;
    final sheet = plan.sheetSize;
    // What the paper is for THIS frame, and therefore which way the ink goes.
    //
    // A sheet being drawn for print is ink on white whatever the paper is set
    // to: a black background is a black page out of a printer, and the
    // black-and-white export exists precisely so a sheet can be photocopied
    // and marked up on a clipboard. See [printSkin].
    final paper = _printMode ? const Color(0xFFFFFFFF) : plan.paper;
    final darkPaper = _printMode ? false : plan.paperIsDark;
    // Worked out once and handed to both the router and the captions, so the
    // line you see and the label beside it are dodging the same things.
    final obstacles = _planObstacles(provider, plan);
    // And once more for the key: the legend has to list the runs that are
    // actually drawn, in the colour and dash pattern they are actually drawn
    // in, or it is a legend to a different sheet.
    final runs = _cableLayer == _kLayerOff
        ? const <_PlanRun>[]
        : _runsOnPlan(provider, plan, drawing, obstacles);
    // The captions dodge all of it — dots included, which the routes cannot —
    // so a run's label never lands on the name of the place it runs to.
    final keepClear = [...obstacles.dots.values, ...obstacles.always];
    // Laid out here rather than in paint(): the boxes are what the drag
    // targets below sit on, so the label somebody grabs is the one they can
    // see. A label being dragged right now carries the live offset, so it
    // follows the cursor without a provider write per pointer event.
    final captions = _planCaptions(
      runs: runs,
      keepClear: keepClear,
      nudges: {
        for (final e in plan.runLabelOffsets.entries) e.key: e.value,
        if (_labelDragKey.isNotEmpty)
          _labelDragKey: plan.labelOffsetFor(_labelDragKey) + _labelDrag,
      },
      // The ink follows the PAPER, not the app theme: what is printed on the
      // sheet has to read against the sheet, and the sheet is black by default
      // whichever way the app is set. A run label picked from the theme was
      // black ink on black paper for anybody working in light mode.
      dark: darkPaper,
      style: plan.styleFor(PlanTextKind.wiring),
      hiddenLabels: provider.avCabling.hiddenLabels,
    );

    return SizedBox(
      width: sheet.width,
      height: sheet.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // The runs are handed over with the tap: they were just routed for
        // this frame, and a lattice search is not something to repeat to find
        // out what was clicked.
        onTapUp: (details) =>
            _onPlanTap(provider, details.localPosition, drawing, runs),
        // Drawing and dragging notation. Only wired up while the tool is on,
        // so an ordinary visit still pans the sheet with the same gesture.
        onPanStart: _tool == _PlanTool.notation
            ? (d) => _noteDragStart(plan, d.localPosition)
            : null,
        onPanUpdate: _tool == _PlanTool.notation
            ? (d) => _noteDragUpdate(provider, plan, d)
            : null,
        onPanEnd: _tool == _PlanTool.notation
            ? (_) => _noteDragEnd(provider, plan)
            : null,
        child: Stack(
          children: [
            // The paper: the image's own area plus whatever blank space has
            // been added round it, in one colour so the margin cannot be told
            // from the sheet in the exported PNG.
            Container(
              width: sheet.width,
              height: sheet.height,
              // The paper. A sheet with a drawing wants something near-white
              // behind it — an architect's export is black ink on nothing and
              // a transparent PNG would read as a hole — but a BLANK sheet is
              // nothing but paper, and a full white rectangle in a dark room
              // is what people turn the lights on for. So the default follows
              // the theme, and a room that wants its own says so.
              color: paper,
            ),
            Positioned(
              left: plan.margins.left,
              top: plan.margins.top,
              width: size.width,
              height: size.height,
              // Three states, and only one of them is a problem. A sheet
              // with a drawing shows it. A sheet that never had one is BLANK
              // PAPER — the room laid out on nothing, which is what you want
              // before the architect's PDF turns up and is how the room
              // presets ship. A sheet whose image has gone missing is the
              // only one that gets a message, and it earns it.
              child: _image != null
                  ? Image(image: _image!, fit: BoxFit.fill)
                  : plan.hasImage
                      ? Center(
                          child: Text(
                            'The plan image could not be found at\n'
                            '$_imagePath',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : const SizedBox.shrink(),
            ),
            // Under the markers: a run ends AT a location, so the dot it lands
            // on should sit on top of it rather than the line crossing over.
            if (_cableLayer != _kLayerOff)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _PlanCablePainter(
                      runs: runs,
                      captions: captions,
                      keepClear: keepClear,
                      // Against the paper — see the captions above.
                      dark: darkPaper,
                      style: plan.styleFor(PlanTextKind.wiring),
                    ),
                  ),
                ),
              ),
            // Only the locations dropped on THIS sheet. A room's locations
            // belong to the room; where they are drawn belongs to the drawing.
            for (final location in provider.avLocations)
              if (plan.markerFor(location.id) != null)
                _locationMarker(
                  context,
                  provider,
                  model,
                  plan,
                  location,
                  plan.markerFor(location.id)!,
                ),
            for (final callout in plan.callouts)
              _calloutMarker(context, provider, model, plan, callout),
            // Over the markers: notation is a mark-up ON the drawing, and an
            // arrow that disappeared behind a location dot would be pointing
            // at nothing anybody can see.
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: PlanAnnotationPainter(
                    notes: plan.annotations,
                    draft: _draft,
                    selectedId: _tool == _PlanTool.notation
                        ? _selectedNoteId
                        : '',
                  ),
                ),
              ),
            ),
            // The captions are painted, so this is what makes them grabbable:
            // an invisible pad over each block. Invisible on purpose — it must
            // not turn up in the exported sheet, and the label under it is
            // already the thing you can see.
            for (final caption in captions)
              _labelDragTarget(provider, plan, caption),
            // The selected run's bends, over everything the run is drawn over.
            // Not in the export: nothing is selected on a sheet being written
            // to a file, because the tab clears the selection before it
            // captures — see [_captureCableLayers].
            ..._bendHandles(provider, plan, runs),
            // Last, so nothing is drawn over it. INSIDE the boundary that gets
            // captured, which is the whole point: the exported PNG and the
            // sheet in the workbook carry the key with them, instead of being
            // a marked-up drawing whose marks nobody can read.
            if (!plan.keyHidden)
              _keyPanel(context, provider, model, plan, runs),
          ],
        ),
      ),
    );
  }

  // --- the key --------------------------------------------------------------

  /// The legend, drawn ON the sheet: what the marker icons mean, which cable
  /// each line is, what the callouts point at, and what the mark-up colours
  /// were used for.
  ///
  /// It lives inside the captured [RepaintBoundary] deliberately. A plan
  /// exported as a PNG and mailed to a contractor is read away from this app,
  /// and every convention on it — a ceiling icon, a dashed line, a squiggle
  /// leaving the page, a red arrow — means nothing on its own. A key that is
  /// only on screen is a key nobody who needs it ever sees.
  Widget _keyPanel(
    BuildContext context,
    AppStateProvider provider,
    AvFlowModel model,
    FloorPlan plan,
    List<_PlanRun> runs,
  ) {
    // The key is printed ON the sheet and exported with it, so it reads
    // against the paper rather than against the app theme — and against white
    // when the sheet is being drawn for print.
    final dark = !_printMode && plan.paperIsDark;

    // Only the surfaces actually on this sheet: a legend listing all ten zones
    // when the drawing shows three is a legend people stop reading.
    final zones = <RoomZone>[];
    for (final location in provider.avLocations) {
      if (plan.markerFor(location.id) == null) continue;
      if (zones.contains(location.zone)) continue;
      zones.add(location.zone);
    }
    zones.sort(
      (a, b) => RoomZone.values.indexOf(a).compareTo(RoomZone.values.indexOf(b)),
    );

    // One line per run, deduplicated: the same cable drawn on three legs is
    // one entry, not three.
    final cables = <String, _PlanRun>{};
    for (final run in runs) {
      cables.putIfAbsent(run.label, () => run);
    }

    // The mark-up colours in use, with what was written in them.
    final notes = <int, List<String>>{};
    for (final a in plan.annotations) {
      notes.putIfAbsent(a.color, () => []);
      if (a.text.trim().isNotEmpty) notes[a.color]!.add(a.text.trim());
    }

    final bool empty =
        zones.isEmpty && cables.isEmpty && plan.callouts.isEmpty && notes.isEmpty;
    if (empty) return const SizedBox.shrink();

    final at = plan.keyPos + (_keyDrag ?? Offset.zero);

    return Positioned(
      left: at.dx,
      top: at.dy,
      width: _kPlanKeyWidth,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => setState(() => _keyDrag = Offset.zero),
        onPanUpdate: (d) =>
            setState(() => _keyDrag = (_keyDrag ?? Offset.zero) + d.delta),
        onPanEnd: (_) {
          final moved = _keyDrag ?? Offset.zero;
          setState(() => _keyDrag = null);
          if (moved == Offset.zero) return;
          // Kept on the sheet: a key dragged off the top-left corner is a key
          // that is not in the exported image either.
          provider.updateAvFloorPlan(
            plan.copyWith(
              // Clamped to the SHEET, not to the image: the blank margin is
              // exactly where a key is supposed to end up.
              keyPos: Offset(
                (plan.keyPos.dx + moved.dx).clamp(
                  0.0,
                  math.max(0.0, plan.sheetSize.width - _kPlanKeyWidth),
                ),
                (plan.keyPos.dy + moved.dy).clamp(
                  0.0,
                  math.max(0.0, plan.sheetSize.height - 60),
                ),
              ),
            ),
          );
        },
        onPanCancel: () => setState(() => _keyDrag = null),
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Container(
            decoration: BoxDecoration(
              color: dark ? const Color(0xF21B2026) : const Color(0xF2FAFAFA),
              border: Border.all(
                color: dark ? const Color(0xFF3A424C) : const Color(0xFF9E9E9E),
                width: 1.2,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            padding: const EdgeInsets.all(9),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'KEY — ${plan.name}'.toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                          color: dark ? Colors.white : Colors.black87,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Not in the captured image is the point of hiding it, so
                    // the control is on the toolbar rather than here — see
                    // [_toolbar]. This is only the drag handle hint.
                    Icon(
                      Icons.drag_indicator,
                      size: 13,
                      color: dark ? Colors.white38 : Colors.black26,
                    ),
                  ],
                ),
                if (zones.isNotEmpty) ...[
                  _keyHeading('Mounting surface', dark),
                  for (final zone in zones)
                    _keyRow(
                      dark,
                      leading: Icon(
                        kRoomZoneIcons[zone] ?? Icons.place,
                        size: 13,
                        color: dark ? Colors.white70 : Colors.black87,
                      ),
                      text: kRoomZoneLabels[zone] ?? zone.name,
                    ),
                ],
                if (cables.isNotEmpty) ...[
                  _keyHeading('Cable runs', dark),
                  for (final run in cables.values.take(_kPlanKeyMaxRows))
                    _keyRow(
                      dark,
                      leading: SizedBox(
                        width: _kPlanKeySwatch,
                        height: 12,
                        child: CustomPaint(
                          painter: _RunSpecimenPainter(
                            color: run.color,
                            style: run.style,
                            offSheet: run.offSheet,
                          ),
                        ),
                      ),
                      text: run.label,
                    ),
                  _keyRow(
                    dark,
                    leading: SizedBox(
                      width: _kPlanKeySwatch,
                      height: 12,
                      child: CustomPaint(
                        painter: _RunSpecimenPainter(
                          color: dark ? Colors.white70 : Colors.black54,
                          style: RunLineStyle.solid,
                          offSheet: true,
                        ),
                      ),
                    ),
                    text: 'Continues off this sheet',
                  ),
                  if (cables.length > _kPlanKeyMaxRows)
                    _keyMore(dark, cables.length - _kPlanKeyMaxRows),
                ],
                if (plan.callouts.isNotEmpty) ...[
                  _keyHeading('Callouts', dark),
                  for (final c in plan.callouts.take(_kPlanKeyMaxRows))
                    _keyRow(
                      dark,
                      leading: CircleAvatar(
                        radius: 7,
                        backgroundColor: const Color(0xFFD84315),
                        child: Text(
                          c.tag,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 8,
                          ),
                        ),
                      ),
                      text: [
                        if (_calloutSubtitle(model, c).isNotEmpty)
                          _calloutSubtitle(model, c),
                        if (c.workbookSheet.isNotEmpty)
                          'see ${c.workbookSheet}'
                              '${c.workbookRef.isEmpty ? '' : ' · ${c.workbookRef}'}',
                        if (c.note.isNotEmpty) c.note,
                      ].join(' — '),
                    ),
                  if (plan.callouts.length > _kPlanKeyMaxRows)
                    _keyMore(dark, plan.callouts.length - _kPlanKeyMaxRows),
                ],
                if (notes.isNotEmpty) ...[
                  _keyHeading('Notation', dark),
                  for (final e in notes.entries.take(_kPlanKeyMaxRows))
                    _keyRow(
                      dark,
                      leading: Container(
                        width: _kPlanKeySwatch,
                        height: 8,
                        decoration: BoxDecoration(
                          color: Color(e.value.isEmpty ? e.key : e.key),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      text: e.value.isEmpty
                          ? 'Mark-up'
                          : e.value.toSet().join(' · '),
                    ),
                  if (notes.length > _kPlanKeyMaxRows)
                    _keyMore(dark, notes.length - _kPlanKeyMaxRows),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _keyHeading(String text, bool dark) => Padding(
    padding: const EdgeInsets.only(top: 7, bottom: 2),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 8.5,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.6,
        color: dark ? Colors.white54 : Colors.black45,
      ),
    ),
  );

  /// The line that owns up to a section being longer than the panel.
  ///
  /// A key clipped at the bottom of the sheet is worse than a short one: it
  /// looks complete and is not. The full list is in the location report, which
  /// is where a sheet with forty runs on it has to be read from anyway.
  Widget _keyMore(bool dark, int hidden) => Padding(
    padding: const EdgeInsets.only(top: 1),
    child: Text(
      '+$hidden more — see the location report',
      style: TextStyle(
        fontSize: 8.5,
        fontStyle: FontStyle.italic,
        color: dark ? Colors.white54 : Colors.black45,
      ),
    ),
  );

  Widget _keyRow(bool dark, {required Widget leading, required String text}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _kPlanKeySwatch,
              child: Center(child: leading),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 9.5,
                  color: dark ? Colors.white : Colors.black87,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );

  // --- cable runs over the plan ---------------------------------------------

  /// Where each location sits ON THIS SHEET, keyed the way the cabling drawing
  /// names its boxes so a bundle can be looked up straight against it.
  ///
  /// A sheet only knows about the locations somebody dropped on IT — see
  /// [FloorPlan.markers]. That is what makes a second sheet a second drawing
  /// rather than a second copy of the first.
  Map<String, Offset> _markersOn(FloorPlan? plan) => {
    if (plan != null)
      for (final e in plan.markers.entries) 'loc:${e.key}': e.value,
  };

  /// The bends [runId] is drawn with right now: what the sheet has stored,
  /// with the bend under the pointer moved to where the pointer has it.
  ///
  /// A dragged bend is snapped square with its neighbours as it comes close to
  /// them, because cable in a building runs along walls and trays, and hitting
  /// an exact right angle by dragging a dot is a thing nobody can do.
  List<Offset> _bendsOf(
    FloorPlan plan,
    String runId,
    Offset from,
    Offset to,
    List<Rect> keepOut,
  ) {
    final stored = plan.waypointsFor(runId);
    if (runId != _bendRunId || _bendIndex < 0 || _bendIndex >= stored.length) {
      return stored;
    }
    final next = List<Offset>.from(stored);
    final neighbours = <Offset>[
      if (_bendIndex == 0) from else next[_bendIndex - 1],
      if (_bendIndex == next.length - 1) to else next[_bendIndex + 1],
    ];
    next[_bendIndex] = pushOutOfRects(
      snapToRightAngle(next[_bendIndex] + _bendDelta, neighbours),
      keepOut,
    );
    return next;
  }

  /// The runs the cabling drawing knows about, resolved onto this sheet and
  /// routed clear of everything already printed on it.
  ///
  /// Only runs whose BOTH ends are on THIS sheet can be drawn — a line to a
  /// location that is not on the plan would have to point somewhere arbitrary,
  /// and a plan that invents where cable goes is worse than one that leaves it
  /// out. [_unplacedRunCount] says how many were left out, so the omission is
  /// visible rather than silent.
  List<_PlanRun> _runsOnPlan(
    AppStateProvider provider,
    FloorPlan plan,
    CablingSchematic drawing,
    ({Map<String, Rect> dots, List<Rect> always}) obstacles,
  ) {
    final placed = _markersOn(plan);

    final drawable = [
      for (final b in drawing.bundles)
        if (placed.containsKey(b.fromBoxId) &&
            placed.containsKey(b.toBoxId) &&
            _layerMatches(b.cableType))
          b,
    ];

    // Runs sharing a pair of markers are fanned apart, the same way the
    // cabling drawing fans them, so six Cat 6a and five Cat 5e between the
    // same two places read as two pulls.
    final byEdge = <String, List<CablingBundle>>{};
    for (final b in drawable) {
      final ends = [b.fromBoxId, b.toBoxId]..sort();
      byEdge.putIfAbsent('${ends[0]}|${ends[1]}', () => []).add(b);
    }
    final lanes = <String, double>{};
    final edgeOf = <String, String>{};
    for (final e in byEdge.entries) {
      for (int i = 0; i < e.value.length; i++) {
        lanes[e.value[i].id] =
            (i - (e.value.length - 1) / 2) * kCablingLaneStep;
        edgeOf[e.value[i].id] = e.key;
      }
    }
    // The dash pattern comes off the CABLE, not the lane, so this sheet, the
    // cabling drawing and both keys strike a Cat 6a the same way — and so the
    // black-and-white print still tells the pulls apart.
    final styles = drawing.bundleLineStyles;

    return [
      for (final b in drawable)
        (
          id: b.id,
          edgeKey: edgeOf[b.id] ?? b.id,
          route: _routeOnPlan(
            from: placed[b.fromBoxId]!,
            to: placed[b.toBoxId]!,
            lane: lanes[b.id] ?? 0,
            bends: _bendsOf(
              plan,
              b.id,
              placed[b.fromBoxId]!,
              placed[b.toBoxId]!,
              [...obstacles.dots.values, ...obstacles.always],
            ),
            // The two dots this run LANDS on are not obstacles to it: it has
            // to reach them. Everything else on the sheet still is — including
            // the names under those two dots.
            obstacles: [
              for (final e in obstacles.dots.entries)
                if (e.key != b.fromBoxId && e.key != b.toBoxId) e.value,
              ...obstacles.always,
            ],
          ),
          color: Color(b.color),
          label: b.label,
          style: styles[b.id] ?? RunLineStyle.solid,
          offSheet: drawing.isOffSheet(b),
          fromLabel: b.fromLabel,
          toLabel: b.toLabel,
          fromDot: obstacles.dots[b.fromBoxId],
          toDot: obstacles.dots[b.toBoxId],
        ),
      ..._offSheetRuns(provider, plan, drawing, placed),
    ];
  }

  /// The runs with ONE end on this sheet, drawn as a squiggle leaving the page.
  ///
  /// A pull to the IDF is the ordinary case of this and the reason it exists:
  /// the telecom room is not somewhere that can be marked on a plan of one
  /// teaching space, so the run used to be counted in the "not on this sheet"
  /// warning and drawn nowhere. A line that stops at the border reads as a
  /// cable that stops at the border, so it leaves as a break symbol, labelled
  /// with where it is going.
  List<_PlanRun> _offSheetRuns(
    AppStateProvider provider,
    FloorPlan plan,
    CablingSchematic drawing,
    Map<String, Offset> placed,
  ) {
    final out = <_PlanRun>[];
    // Fanned by how many have already left the same marker, so three runs out
    // of one rack do not become one thick squiggle.
    final leaving = <String, int>{};

    for (final b in drawing.bundles) {
      if (!_layerMatches(b.cableType)) continue;
      final bool fromHere = placed.containsKey(b.fromBoxId);
      final bool toHere = placed.containsKey(b.toBoxId);
      if (fromHere == toHere) continue; // both on the sheet, or neither

      final String hereId = fromHere ? b.fromBoxId : b.toBoxId;
      final String awayId = fromHere ? b.toBoxId : b.fromBoxId;
      final Offset at = placed[hereId]!;
      final int index = leaving.update(hereId, (n) => n + 1, ifAbsent: () => 0);

      out.add((
        id: '${b.id}$_kOffSheetSuffix',
        // Its own caption block, keyed on the marker it leaves and where it is
        // going, so every run out of the rack to the IDF is captioned once.
        edgeKey: 'off|$hereId|$awayId',
        route: _offSheetStub(at, plan, index),
        color: Color(b.color),
        label: '${b.label} → ${drawing.boxById(awayId)?.label ?? 'off sheet'}',
        style: drawing.bundleLineStyles[b.id] ?? RunLineStyle.solid,
        offSheet: true,
        fromLabel: '',
        toLabel: '',
        fromDot: locationDotBounds(at),
        toDot: null,
      ));
    }
    return out;
  }

  /// A short stub from [at] towards the nearest edge of the sheet, stepped
  /// sideways by [index] so several leaving the same place stay apart.
  List<Offset> _offSheetStub(Offset at, FloorPlan plan, int index) {
    final size = plan.sheetSize;
    // Whichever border is closest — a run leaving the room should head for the
    // way out, not across the drawing to the far side of it.
    final distances = <Offset, double>{
      const Offset(-1, 0): at.dx,
      const Offset(1, 0): size.width - at.dx,
      const Offset(0, -1): at.dy,
      const Offset(0, 1): size.height - at.dy,
    };
    var direction = const Offset(1, 0);
    var best = double.infinity;
    distances.forEach((d, distance) {
      if (distance < best) {
        best = distance;
        direction = d;
      }
    });

    const length = 64.0;
    final normal = Offset(-direction.dy, direction.dx) * (index * 14.0);
    final start = at + normal;
    final reach = math.min(length, math.max(28.0, best - 6));
    return [start, start + direction * reach];
  }

  /// One run's path: fanned onto its lane, then stepped around whatever is
  /// printed between its two ends.
  List<Offset> _routeOnPlan({
    required Offset from,
    required Offset to,
    required double lane,
    required List<Rect> obstacles,
    List<Offset> bends = const [],
  }) {
    var a = from;
    var b = to;
    final d = b - a;
    final length = d.distance;
    if (length > 0 && lane != 0) {
      final normal = Offset(-d.dy / length, d.dx / length) * lane;
      a += normal;
      b += normal;
    }
    // Bends dragged onto this sheet say which way the cable actually goes,
    // which is a fact about the building rather than about the geometry. The
    // router still keeps each leg off what is printed.
    if (bends.isNotEmpty) return routeThrough([a, ...bends, b], obstacles);
    // A straight line when nothing is in the way, which is the common case and
    // the one a cabling sheet reads best.
    return latticeRoute(a, b, obstacles) ?? [a, b];
  }

  /// Everything already printed on the sheet that a cable run should go round,
  /// split by whether a run may cross it to reach its own end.
  ///
  ///   * [dots] are the location markers, keyed the way the runs name their
  ///     ends. A run has to REACH the two it joins, so those two come out of
  ///     the list for that run — otherwise there is no way in.
  ///
  ///   * [always] is everything no run may cross whatever it is doing: the
  ///     names under the dots and the callouts. The name is what makes the dot
  ///     mean anything, and a run coming in sideways across the label of the
  ///     very place it runs to is the drawing rubbing out its own caption on
  ///     the last few pixels of the pull.
  ({Map<String, Rect> dots, List<Rect> always}) _planObstacles(
    AppStateProvider provider,
    FloorPlan plan,
  ) {
    final dots = <String, Rect>{};
    final always = <Rect>[];
    for (final e in plan.markers.entries) {
      final location = provider.avLocationById(e.key);
      if (location == null) continue;
      dots['loc:${e.key}'] = locationDotBounds(e.value);
      final label = locationLabelBounds(e.value, location.name);
      if (label != null) always.add(label);
    }
    for (final c in plan.callouts) {
      always.add(
        Rect.fromCenter(
          center: c.pos,
          width: kCalloutMarkerRadius * 2 + 6,
          height: kCalloutMarkerRadius * 2 + 6,
        ),
      );
    }
    return (dots: dots, always: always);
  }

  bool _layerMatches(String cableType) =>
      _cableLayer == _kLayerAll || _cableLayer == cableType;

  /// The colour keys every run of [cableType] is filed under.
  ///
  /// Plural because a cable type can be pulled under more than one category —
  /// AV Cat 6a and network Cat 6a are two different pulls the key colours
  /// apart — while this bar has ONE chip for "Cat 6a". Recolouring the chip
  /// means the layer being looked at, so it takes both.
  Set<String> _colorKeysFor(CablingSchematic drawing, String cableType) => {
    for (final b in drawing.bundles)
      if (b.cableType == cableType) cablingColorKey(b),
  };

  Future<void> _pickCableTypeColor(
    AppStateProvider provider,
    CablingSchematic drawing,
    ({String type, Color color}) layer,
  ) async {
    final picked = await showColorWheelDialog(
      context,
      initial: layer.color,
      title: 'Colour for ${layer.type}',
    );
    if (picked == null) return;
    provider.setCablingTypeColor(
      _colorKeysFor(drawing, layer.type),
      picked.toARGB32(),
    );
  }

  /// What the writing on this sheet is printed in — a plate and an ink per
  /// kind of label.
  ///
  /// One dialog for all three because they are read against each other: the
  /// point of giving the runs a yellow plate is that the location names are
  /// white, and choosing them on separate screens is choosing them blind.
  Future<void> _showLabelColorDialog(
    AppStateProvider provider,
    FloorPlan plan,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          // Read live off the provider so the sheet behind the dialog and the
          // swatches in it cannot disagree.
          final sheet = provider.avFloorPlanById(plan.id) ?? plan;
          final theme = Theme.of(ctx);

          Future<void> pick(
            PlanTextKind kind, {
            required bool background,
          }) async {
            final style = sheet.styleFor(kind);
            final fallback = _defaultLabelColors(kind, onDarkPaper: sheet.paperIsDark);
            final picked = await showColorWheelDialog(
              ctx,
              initial: background
                  ? planLabelBackground(style, fallback.background)
                  : planLabelInk(style, fallback.ink),
              title: background
                  ? 'Background for ${kPlanTextKindLabels[kind]?.toLowerCase()}'
                  : 'Text colour for '
                      '${kPlanTextKindLabels[kind]?.toLowerCase()}',
            );
            if (picked == null) return;
            provider.setAvPlanLabelStyle(
              plan.id,
              kind,
              background
                  ? style.copyWith(background: picked.toARGB32())
                  : style.copyWith(ink: picked.toARGB32()),
            );
            setLocal(() {});
          }

          Widget swatch(
            PlanTextKind kind, {
            required bool background,
          }) {
            final style = sheet.styleFor(kind);
            final fallback = _defaultLabelColors(kind, onDarkPaper: sheet.paperIsDark);
            final color = background
                ? planLabelBackground(style, fallback.background)
                : planLabelInk(style, fallback.ink);
            return Tooltip(
              message: background ? 'Background' : 'Text',
              child: InkWell(
                onTap: () => pick(kind, background: background),
                child: Container(
                  width: 46,
                  height: 28,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: theme.dividerColor),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    background
                        ? Icons.format_color_fill
                        : Icons.text_fields,
                    size: 13,
                    // Whichever of black or white can be seen on it.
                    color: ThemeData.estimateBrightnessForColor(color) ==
                            Brightness.dark
                        ? Colors.white70
                        : Colors.black54,
                  ),
                ),
              ),
            );
          }

          return AlertDialog(
            title: const Text('Label colours on this sheet'),
            content: SizedBox(
              width: 470,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'An architectural plan is a line drawing, and text dropped '
                    'straight onto one lands on a wall. Every label is printed '
                    'on a plate; this is what colour that plate and the words '
                    'on it are, on ${sheet.name}.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 14),
                  for (final kind in PlanTextKind.values)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  kPlanTextKindLabels[kind] ?? kind.name,
                                  style: theme.textTheme.titleSmall,
                                ),
                                Text(
                                  _labelKindHint(kind),
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          // Painted the way it will actually print, so the
                          // decision is made on the thing rather than on two
                          // squares of colour.
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: planLabelBackground(
                                sheet.styleFor(kind),
                                _defaultLabelColors(kind, onDarkPaper: sheet.paperIsDark).background,
                              ),
                              borderRadius: BorderRadius.circular(3),
                              border: Border.all(color: theme.dividerColor),
                            ),
                            child: Text(
                              kind == PlanTextKind.callout ? '1' : 'Sample',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: planLabelInk(
                                  sheet.styleFor(kind),
                                  _defaultLabelColors(kind, onDarkPaper: sheet.paperIsDark).ink,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          swatch(kind, background: true),
                          const SizedBox(width: 6),
                          swatch(kind, background: false),
                          IconButton(
                            icon: const Icon(Icons.restart_alt, size: 18),
                            tooltip: 'Back to the standard colours',
                            onPressed: sheet.styleFor(kind).isDefault
                                ? null
                                : () {
                                    provider.setAvPlanLabelStyle(
                                      plan.id,
                                      kind,
                                      PlanLabelStyle.unset,
                                    );
                                    setLocal(() {});
                                  },
                          ),
                        ],
                      ),
                    ),
                  Text(
                    'Standard colours follow the light or dark drawing they '
                    'are on. A colour set here is used on both.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.disabledColor,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Done'),
              ),
            ],
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  /// What each kind of label is printed in when the sheet says nothing — the
  /// same figures the markers and the painter fall back to.
  ({Color background, Color ink}) _defaultLabelColors(
    PlanTextKind kind, {
    required bool onDarkPaper,
  }) {
    // Against the PAPER, not the app theme: this is what the sheet prints, and
    // the sheet is the same colour in either theme.
    final dark = onDarkPaper;
    return switch (kind) {
      PlanTextKind.location => (
        background: const Color(0xD9FFFFFF),
        ink: Colors.black87,
      ),
      PlanTextKind.callout => (
        background: const Color(0xFFD84315),
        ink: Colors.white,
      ),
      PlanTextKind.wiring => (
        background: dark ? const Color(0xE6202428) : const Color(0xE6FFFFFF),
        ink: dark ? Colors.white : Colors.black87,
      ),
    };
  }

  String _labelKindHint(PlanTextKind kind) => switch (kind) {
    PlanTextKind.location => 'The name plate under each location dot.',
    PlanTextKind.callout => 'The numbered markers and their tags.',
    PlanTextKind.wiring => 'Cable counts and what each run lands on.',
  };

  /// The cable types this sheet could show, in the order the drawing lists
  /// them, each with the colour it is drawn in.
  List<({String type, Color color})> _cableLayers(
    AppStateProvider provider,
    FloorPlan? plan,
    CablingSchematic drawing,
  ) {
    final placed = _markersOn(plan).keys.toSet();
    final seen = <String, Color>{};
    for (final b in drawing.bundles) {
      // ONE end is enough: a run with the other end off the sheet is drawn as
      // a squiggle leaving the page, so its cable belongs on the layer bar.
      if (!placed.contains(b.fromBoxId) && !placed.contains(b.toBoxId)) {
        continue;
      }
      seen.putIfAbsent(b.cableType, () => Color(b.color));
    }
    final types = seen.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [for (final t in types) (type: t, color: seen[t]!)];
  }

  /// How many runs cannot be drawn at all because NEITHER end is on this
  /// sheet.
  ///
  /// One end is enough to draw something honest — the run leaves the page as a
  /// squiggle labelled with where it is going — so those are no longer counted
  /// here. With neither end placed there is nowhere to start the line from,
  /// and a plan that invents where cable goes is worse than one that says how
  /// much it is leaving out.
  int _unplacedRunCount(
    AppStateProvider provider,
    FloorPlan? plan,
    CablingSchematic drawing,
  ) {
    final placed = _markersOn(plan).keys.toSet();
    return drawing.bundles
        .where(
          (b) =>
              !placed.contains(b.fromBoxId) && !placed.contains(b.toBoxId),
        )
        .length;
  }

  /// The layer picker: off, everything, or one cable type on its own.
  Widget _layerBar(
    AppStateProvider provider,
    FloorPlan plan,
    CablingSchematic drawing,
  ) {
    final theme = Theme.of(context);
    final layers = _cableLayers(provider, plan, drawing);
    final missing = _unplacedRunCount(provider, plan, drawing);
    // The bar has to survive having nothing to draw: a room whose markers are
    // not placed yet is exactly the room that needs telling how many runs are
    // missing, and hiding the bar would take the warning with it.
    if (layers.isEmpty && missing == 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('Cable runs', style: theme.textTheme.bodySmall),
          if (layers.isNotEmpty) ...[
            ChoiceChip(
              label: const Text('Off'),
              visualDensity: VisualDensity.compact,
              selected: _cableLayer == _kLayerOff,
              onSelected: (_) => setState(() => _cableLayer = _kLayerOff),
            ),
            ChoiceChip(
              label: const Text('All'),
              visualDensity: VisualDensity.compact,
              selected: _cableLayer == _kLayerAll,
              onSelected: (_) => setState(() => _cableLayer = _kLayerAll),
            ),
          ],
          for (final layer in layers)
            // Right-click recolours the cable rather than the line: a drawing
            // set says "network is green", and saying it here beats clicking
            // every network run on the sheet and hoping none was missed.
            GestureDetector(
              onSecondaryTap: () =>
                  _pickCableTypeColor(provider, drawing, layer),
              child: ChoiceChip(
                key: ValueKey('plan_layer_${layer.type}'),
                avatar: CircleAvatar(backgroundColor: layer.color, radius: 7),
                label: Text(layer.type),
                tooltip: 'Show only this cable · right-click to recolour it',
                visualDensity: VisualDensity.compact,
                selected: _cableLayer == layer.type,
                onSelected: (_) => setState(() => _cableLayer = layer.type),
              ),
            ),
          // The same thing on a button, for the layer being looked at: a
          // feature only reachable by right-clicking is a feature nobody finds.
          for (final layer in layers)
            if (_cableLayer == layer.type) ...[
              avRowIcon(
                Icons.colorize,
                'Colour for ${layer.type}',
                () => _pickCableTypeColor(provider, drawing, layer),
              ),
              if (provider.hasCablingTypeColor(
                _colorKeysFor(drawing, layer.type),
              ))
                avRowIcon(
                  Icons.format_color_reset,
                  'Back to the colour the key gives this cable',
                  () => provider.setCablingTypeColor(
                    _colorKeysFor(drawing, layer.type),
                    null,
                  ),
                ),
            ],
          // A run is a painted line, so nothing about it says it can be
          // clicked. Said once, next to the layer chips, rather than left to
          // be discovered.
          if (layers.isNotEmpty && _cableLayer != _kLayerOff)
            Text(
              '· click a run to set its cable count or route it',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.disabledColor,
              ),
            ),
          if (missing > 0)
            Tooltip(
              message: 'At least one end of a run has to be on THIS sheet '
                  'before it can be drawn — with one end placed it leaves the '
                  'page as a squiggle. Turn on "Place locations" and click '
                  'where the missing end goes.',
              child: Text(
                '$missing run${missing == 1 ? '' : 's'} not on this sheet',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Writes one PNG per sheet per cable type into a folder the user picks.
  ///
  /// A drawing per trade is the whole point of the layers: the network
  /// contractor gets the network drawing and the AV contractor gets theirs,
  /// and neither has to read around the other's runs. Every sheet in the room,
  /// because a set issued for one storey is not the set.
  Future<void> _exportLayers(AppStateProvider provider) async {
    final model = buildAvFlowModel(provider);
    final drawing = provider.cablingSchematic(model);
    if (provider.avFloorPlans.every(
      (sheet) => _cableLayers(provider, sheet, drawing).isEmpty,
    )) {
      _snack('No cable runs land on any of the sheets yet.');
      return;
    }

    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Where should the layer images go?',
    );
    if (folder == null) return;

    await _writePngFolder(
      provider,
      folder,
      await _captureSheets(perLayer: true),
      'layer image',
    );
  }

  /// Writes captured drawings into [folder], one PNG each, named for the room
  /// and then for the drawing. Shared by the two exports that produce a set of
  /// images rather than a single file.
  Future<void> _writePngFolder(
    AppStateProvider provider,
    String folder,
    List<PlanDrawing> drawings,
    String what, {
    String suffix = 'floor_plan',
  }) async {
    final written = <String>[];
    final failed = <String>[];
    for (final drawing in drawings) {
      final safe = drawing.caption
          .replaceAll(RegExp(r'[^\w\-]+'), '_')
          .toLowerCase();
      try {
        final file = File(
          p.join(folder, '${roomFileStem(provider, suffix)}_$safe.png'),
        );
        await file.writeAsBytes(drawing.bytes);
        written.add(p.basename(file.path));
      } catch (e) {
        failed.add('${drawing.caption} — $e');
      }
    }

    if (!mounted) return;
    if (failed.isEmpty && written.isNotEmpty) {
      showSavedFolderSnack(
        context,
        provider,
        'Wrote ${written.length} $what${written.length == 1 ? '' : 's'} '
        'to ${p.basename(folder)}',
        folder,
      );
    } else {
      _snack(
        'Wrote ${written.length}; could not write ${failed.join(', ')}',
        error: true,
      );
    }
  }

  // --- drawing notation -----------------------------------------------------

  /// Takes hold of whatever is under the pointer: a handle or the body of the
  /// selected shape, or — on empty drawing — the start of a new one.
  void _noteDragStart(FloorPlan plan, Offset at) {
    final selected = plan.annotations
        .where((a) => a.id == _selectedNoteId)
        .firstOrNull;
    if (selected != null) {
      final grip = gripAt(selected, at);
      if (grip != AnnotationGrip.none) {
        setState(() => _grip = grip);
        return;
      }
    }
    final under = annotationAt(plan.annotations, at);
    if (under != null) {
      setState(() {
        _selectedNoteId = under.id;
        _grip = AnnotationGrip.body;
      });
      _planFocus.requestFocus();
      return;
    }
    setState(() {
      _selectedNoteId = '';
      _grip = AnnotationGrip.none;
      _draft = PlanAnnotation(
        id: '',
        shape: _shape,
        start: at,
        end: at,
        color: _noteColor,
        strokeWidth: _noteStroke,
      );
    });
  }

  void _noteDragUpdate(
    AppStateProvider provider,
    FloorPlan plan,
    DragUpdateDetails d,
  ) {
    if (_draft != null) {
      setState(() => _draft = _draft!.copyWith(end: d.localPosition));
      return;
    }
    if (_grip == AnnotationGrip.none) return;
    final note = plan.annotations
        .where((a) => a.id == _selectedNoteId)
        .firstOrNull;
    if (note == null) return;
    // recordUndo false: one entry for the whole drag, pushed when it ends.
    provider.updateAvAnnotation(
      plan.id,
      dragAnnotation(note, _grip, d.delta),
      recordUndo: false,
    );
  }

  Future<void> _noteDragEnd(AppStateProvider provider, FloorPlan plan) async {
    final draft = _draft;
    setState(() {
      _draft = null;
      _grip = AnnotationGrip.none;
    });
    if (draft == null) return;
    // A click rather than a drag: nothing was drawn, so nothing is added.
    // Text is exempt — it sizes itself to what gets typed.
    if (draft.isDegenerate) return;

    if (draft.shape == PlanShape.text) {
      final text = await _askForText('');
      if (text == null || text.trim().isEmpty) return;
      final stored = provider.addAvAnnotation(
        plan.id,
        draft.copyWith(text: text.trim()),
      );
      if (stored != null) setState(() => _selectedNoteId = stored.id);
      return;
    }

    final stored = provider.addAvAnnotation(plan.id, draft);
    if (stored != null) setState(() => _selectedNoteId = stored.id);
  }

  Future<String?> _askForText(String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Note text'),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 4,
            minLines: 1,
            decoration: const InputDecoration(
              hintText: 'e.g. Core drill here — conduit up to ceiling',
              border: OutlineInputBorder(),
            ),
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

  Widget _locationMarker(
    BuildContext context,
    AppStateProvider provider,
    AvFlowModel model,
    FloorPlan plan,
    RoomLocation location,
    Offset at,
  ) {
    final here = model.nodes.where((n) => n.locationId == location.id);
    final jacks = here
        .where((n) => n.isJackField)
        .fold(0, (sum, n) => sum + n.ports.length);
    final devices = here.where((n) => !n.isJackField).length;
    const r = kLocationMarkerRadius;
    // A fixed-width column centred on the marker's coordinates, so the DOT
    // lands on them whatever the name under it measures. Sized to the column
    // rather than the dot, a long name shunted the dot sideways and every
    // cable run then ended somewhere the eye could see it did not.
    //
    // Wide enough for the zone badge as well as the name, so the plate can
    // reach the width [locationLabelBounds] tells the router to keep off.
    const w = kLocationLabelWidth + 8 + kLocationZoneBadgeWidth;

    return Positioned(
      left: at.dx - w / 2,
      top: at.dy - r,
      width: w,
      child: GestureDetector(
        onPanUpdate: (d) => provider.moveAvLocationMarker(
          plan.id,
          location.id,
          at + d.delta,
          // One drag is one undo, not one per pointer event.
          recordUndo: false,
        ),
        onDoubleTap: () => showLocationEditor(context, provider, location),
        // Taking a marker off ONE sheet without deleting the location: the
        // place is still where the gear is, it just does not belong on this
        // drawing. There was no way to say that while a marker was a property
        // of the room.
        onSecondaryTap: () {
          provider.removeAvLocationMarker(plan.id, location.id);
          _snack(
            '${location.name} taken off ${plan.name}. The location itself is '
            'untouched — undo, or click the sheet again to put it back.',
          );
        },
        child: Tooltip(
          message:
              '${location.displayName}\n'
              '${kRoomZoneLabels[location.zone] ?? ''}\n'
              '$devices device${devices == 1 ? '' : 's'}, '
              '$jacks jack${jacks == 1 ? '' : 's'}\n'
              'On ${plan.name}\n'
              'Drag to move · double-click to edit · '
              'right-click to take it off this sheet',
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
              // is a plan somebody has to hover over to read — with the zone
              // glyph in front of it, which is what the key's "mounting
              // surface" section is a legend FOR. Without it that section
              // explained a convention the sheet never used.
              //
              // Only when there IS a name: [locationLabelBounds] returns no
              // plate for a nameless location, and a plate drawn where the
              // routing believes there is none is a plate runs cross.
              if (location.name.trim().isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  constraints: const BoxConstraints(maxWidth: w),
                  // The plate and the ink this sheet prints location names in.
                  color: planLabelBackground(
                    plan.styleFor(PlanTextKind.location),
                    const Color(0xD9FFFFFF),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        kRoomZoneIcons[location.zone] ?? Icons.place,
                        size: kLocationZoneIconSize,
                        color: planLabelInk(
                          plan.styleFor(PlanTextKind.location),
                          Colors.black87,
                        ),
                        semanticLabel: kRoomZoneLabels[location.zone],
                      ),
                      const SizedBox(width: kLocationZoneIconGap),
                      Flexible(
                        child: Text(
                          location.name,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: kLocationLabelFontSize,
                            color: planLabelInk(
                              plan.styleFor(PlanTextKind.location),
                              Colors.black87,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _calloutMarker(
    BuildContext context,
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
              // The marker IS the plate its tag is printed on, so recolouring
              // callout text recolours the disc.
              color: planLabelBackground(
                plan.styleFor(PlanTextKind.callout),
                const Color(0xFFD84315),
              ),
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? Colors.yellow : Colors.white,
                width: selected ? 3 : 2,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              callout.tag,
              style: TextStyle(
                color: planLabelInk(
                  plan.styleFor(PlanTextKind.callout),
                  Colors.white,
                ),
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onPlanTap(
    AppStateProvider provider,
    Offset at,
    CablingSchematic drawing,
    List<_PlanRun> runs,
  ) {
    switch (_tool) {
      case _PlanTool.notation:
        final plan = provider.activeFloorPlan;
        if (plan == null) return;
        // Selecting, not drawing: a shape is dragged out, and a tap is how you
        // pick one up to recolour, relabel or delete it. Picking one up takes
        // the keyboard too, so Delete removes it.
        _selectNote(annotationAt(plan.annotations, at)?.id ?? '');
      case _PlanTool.none:
        // Clicking a run picks it up: its count and the way it is routed are
        // both things that get worked out standing in front of the plan, and
        // both used to mean leaving for the Cabling tab. A click on bare paper
        // puts it down again.
        final bundle = _runAt(drawing, runs, at);
        setState(() {
          _selectedCalloutId = null;
          _selectedRunId = bundle?.id ?? '';
        });
      case _PlanTool.location:
        _placeLocationAt(provider, at);
      case _PlanTool.callout:
        final plan = provider.activeFloorPlan;
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

  /// The bundle whose line was tapped, or null when the tap missed them all.
  CablingBundle? _runAt(
    CablingSchematic drawing,
    List<_PlanRun> runs,
    Offset at,
  ) {
    final hitId = runIdNearest(
      {for (final run in runs) run.id: run.route},
      at,
    );
    if (hitId.isEmpty) return null;
    // A run leaving the page is drawn under a suffixed id so it can be fanned
    // separately; the cable it belongs to is the one without it.
    final id = hitId.endsWith(_kOffSheetSuffix)
        ? hitId.substring(0, hitId.length - _kOffSheetSuffix.length)
        : hitId;
    for (final b in drawing.bundles) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// The pad that makes a painted caption draggable.
  ///
  /// The sheet places every label itself, and places them well enough that
  /// most are never touched. The ones that are touched are the ones the
  /// drawing cannot reason about: a label sitting over the door swing, or over
  /// the bit of the plan the note beside it is pointing at. Dragging is stored
  /// as a nudge from the automatic spot, so the label still follows its run
  /// when a marker moves.
  Widget _labelDragTarget(
    AppStateProvider provider,
    FloorPlan plan,
    _PlanCaption caption,
  ) {
    final box = caption.box;
    return Positioned(
      left: box.left,
      top: box.top,
      width: box.width,
      height: box.height,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: GestureDetector(
          key: ValueKey('plan_label_${caption.edgeKey}'),
          behavior: HitTestBehavior.opaque,
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
            provider.setAvRunLabelOffset(
              plan.id,
              key,
              plan.labelOffsetFor(key) + moved,
            );
          },
          onPanCancel: () => setState(() {
            _labelDragKey = '';
            _labelDrag = Offset.zero;
          }),
          // Right-click takes THIS caption off both sheets. The way back is on
          // the toolbar: a label that is not drawn cannot be right-clicked to
          // bring itself back.
          onSecondaryTap: () {
            provider.setCablingLabelHidden(caption.edgeKey, true);
            _snack('Label hidden. "Labels" on the toolbar shows them again.');
          },
          // The way back. A label put somewhere by hand is left exactly there
          // even when something is drawn over it later, so there has to be one.
          onDoubleTap: caption.moved
              ? () => provider.setAvRunLabelOffset(
                  plan.id,
                  caption.edgeKey,
                  Offset.zero,
                )
              : null,
          child: Tooltip(
            message: caption.moved
                ? 'Drag to move this label · double-click to put it back where '
                      'the sheet had it'
                : 'Drag to move this label',
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  /// Drag handles for the selected run: a filled dot on every bend it has
  /// been given, and a hollow one at the middle of each leg that adds one.
  ///
  /// The router decides how a run gets from one marker to the other, and it
  /// decides well enough for a drawing to be issued — but which side of the
  /// room the cable is actually pulled down is a fact about the building. A
  /// bend is how that gets said, and it is held per sheet: the same pull is
  /// drawn differently on a floor plan and a reflected ceiling plan.
  List<Widget> _bendHandles(
    AppStateProvider provider,
    FloorPlan plan,
    List<_PlanRun> runs,
  ) {
    if (_selectedRunId.isEmpty) return const [];
    final drawn = <_PlanRun>[
      for (final r in runs)
        if (r.id == _selectedRunId) r,
    ];
    if (drawn.isEmpty) return const [];
    final route = drawn.first.route;
    if (route.length < 2) return const [];

    // A bend may not be dropped on top of a marker or a caption: the router
    // cannot get out of one, so the line would have to cross what it is meant
    // to keep off in order to reach it.
    final obstacles = _planObstacles(provider, plan);
    final keepOut = [...obstacles.dots.values, ...obstacles.always];
    // What is on SCREEN, drag included, so a handle sits under the pointer
    // dragging it.
    final bends = _bendsOf(
      plan,
      _selectedRunId,
      route.first,
      route.last,
      keepOut,
    );
    final color = drawn.first.color;
    const r = 6.0;
    final out = <Widget>[];

    // The midpoints go down FIRST, so a bend placed on a straight leg
    // — collinear, and therefore invisible in the drawn route — keeps
    // its own handle on top of the one that would add another there.
    for (int i = 0; i < route.length - 1; i++) {
      final mid = (route[i] + route[i + 1]) / 2;
      out.add(
        Positioned(
          key: ValueKey('plan_add_bend_${_selectedRunId}_$i'),
          left: mid.dx - r,
          top: mid.dy - r,
          child: GestureDetector(
            onTap: () => provider.setAvRunWaypoints(
              plan.id,
              _selectedRunId,
              List<Offset>.from(bends)..insert(
                bendInsertIndex(route.first, bends, route.last, mid),
                pushOutOfRects(mid, keepOut),
              ),
            ),
            // A square corner in one click, which is what a cable pulled
            // along a wall and then across actually does.
            onSecondaryTap: () => provider.setAvRunWaypoints(
              plan.id,
              _selectedRunId,
              List<Offset>.from(bends)..insertAll(
                bendInsertIndex(route.first, bends, route.last, mid),
                [
                  for (final corner in rightAngleTurn(route[i], route[i + 1]))
                    pushOutOfRects(corner, keepOut),
                ],
              ),
            ),
            child: Tooltip(
              message: 'Add a bend here · right-click for a 90° turn',
              child: Container(
                width: r * 2,
                height: r * 2,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.75),
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 1.5),
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
          key: ValueKey('plan_bend_${_selectedRunId}_$i'),
          left: bends[i].dx - r,
          top: bends[i].dy - r,
          child: GestureDetector(
            // Local while the pointer is down, one write on release: see
            // [_bendRunId].
            onPanStart: (_) => setState(() {
              _bendRunId = _selectedRunId;
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
              provider.setAvRunWaypoints(plan.id, _selectedRunId, bends);
            },
            onPanCancel: () => setState(() {
              _bendRunId = '';
              _bendIndex = -1;
              _bendDelta = Offset.zero;
            }),
            onDoubleTap: () => provider.setAvRunWaypoints(
              plan.id,
              _selectedRunId,
              List<Offset>.from(bends)..removeAt(i),
            ),
            child: Tooltip(
              message: 'Drag to route this run — it snaps square with the '
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

  /// Drops the next location that isn't on THIS SHEET yet at [at]. Asks which
  /// one when several are waiting, because guessing puts the wrong marker
  /// somewhere plausible, which is worse than asking.
  ///
  /// "Not on this sheet" rather than "not on any plan": a location can
  /// legitimately be on the furniture plan and the reflected ceiling plan
  /// both, and a sheet that refused to show it because another sheet already
  /// did would make the second drawing impossible to complete.
  Future<void> _placeLocationAt(AppStateProvider provider, Offset at) async {
    final plan = provider.activeFloorPlan;
    if (plan == null) return;
    final waiting = provider.avLocations
        .where((l) => !plan.hasMarker(l.id))
        .toList();
    if (waiting.isEmpty) {
      _snack(
        'Every location is already on ${plan.name}. Drag them to move, or add '
        'another under "Locations".',
      );
      return;
    }
    if (waiting.length == 1) {
      provider.moveAvLocationMarker(plan.id, waiting.first.id, at);
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Which location goes here on ${plan.name}?'),
        children: [
          for (final l in waiting)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(l.id),
              child: Row(
                children: [
                  Icon(kRoomZoneIcons[l.zone] ?? Icons.place, size: 18),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l.displayName)),
                  // Where else it is already drawn, so a sheet does not get a
                  // second copy of something by accident.
                  if (provider.isLocationOnAnySheet(l.id))
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: Text(
                        'on ${provider.sheetsShowing(l.id).map((p) => p.name).join(', ')}',
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked != null) provider.moveAvLocationMarker(plan.id, picked, at);
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
                'Cabling Runs',
                style: theme.textTheme.titleSmall,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 20),
              tooltip: 'Add low voltage or other runs to document',
              onPressed: () async {
                await showScreenSwitchEditor(context, provider, null);
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
        Text(
          'Add low voltage or other runs to document for contractors, or '
          'internal use. Lines added transfer to the cabling tab.',
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
                title: Text(
                  s.cableNumber.trim().isEmpty
                      ? s.label
                      : '${s.cableNumber.trim()} · ${s.label}',
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  // The whole pull, pull boxes and all — the line on the plan
                  // is the path, so the list beside it has to be too.
                  [
                    _end(provider, s.startLocationId, s.startNote),
                    for (final id in s.viaLocationIds)
                      _end(provider, id, '(location removed)'),
                    _end(provider, s.endLocationId, s.endNote),
                  ].join(' → ') +
                      (s.cableType.isEmpty ? '' : '\n${s.cableType}') +
                      (s.runFeet <= 0
                          ? ''
                          : ' · ${s.runFeet.toStringAsFixed(0)} ft'),
                  style: theme.textTheme.bodySmall,
                ),
                isThreeLine: s.cableType.isNotEmpty,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      tooltip: 'Edit Cable Run',
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
    // Blank space round the drawing, one box per side. Whole pixels of the
    // plan image, which is the unit everything else on this dialog is in.
    String px(double v) => v <= 0 ? '' : v.round().toString();
    final marginControllers = {
      'Left': TextEditingController(text: px(plan.margins.left)),
      'Top': TextEditingController(text: px(plan.margins.top)),
      'Right': TextEditingController(text: px(plan.margins.right)),
      'Bottom': TextEditingController(text: px(plan.margins.bottom)),
    };
    final scaleController = TextEditingController(
      text: plan.pixelsPerFoot <= 0
          ? ''
          : plan.pixelsPerFoot.toStringAsFixed(2),
    );

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
                const SizedBox(height: 18),
                Text('Blank space round the drawing',
                    style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  'An architectural export draws all the way to its border, so '
                  'the key, the callout list and the notes end up on top of the '
                  'walls. This is paper added round the plan for them to sit '
                  'on. It is part of the sheet, so it is in the exported image '
                  'and in the workbook — and everything already drawn moves '
                  'with the plan rather than sliding off it.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (final side in marginControllers.keys) ...[
                      Expanded(
                        child: TextField(
                          key: ValueKey('plan_margin_${side.toLowerCase()}'),
                          controller: marginControllers[side],
                          decoration: InputDecoration(
                            labelText: side,
                            hintText: '0',
                            isDense: true,
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      if (side != 'Bottom') const SizedBox(width: 8),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
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
        pixelsPerFoot: double.tryParse(scaleController.text.trim()) ?? 0,
      ),
    );
    // Through its own call: growing the left or top margin has to shift what
    // is already drawn by the same amount, which is not something copyWith
    // can do for itself.
    double margin(String side) =>
        double.tryParse(marginControllers[side]!.text.trim()) ?? 0;
    provider.setAvPlanMargins(
      plan.id,
      EdgeInsets.fromLTRB(
        margin('Left'),
        margin('Top'),
        margin('Right'),
        margin('Bottom'),
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
/// One cable run as it lands on a plan sheet, already routed.
typedef _PlanRun = ({
  String id,

  /// The pair of markers this run joins, so runs sharing an edge can be
  /// captioned as one block instead of one caption on top of another.
  String edgeKey,
  List<Offset> route,
  Color color,
  String label,

  /// How the line is stroked, over and above its colour: runs sharing a pair
  /// of markers each get their own dash pattern, because a fan of three
  /// parallel lines is only readable while the colours can be told apart.
  RunLineStyle style,

  /// True when the run carries on past this sheet — to the IDF, or simply to
  /// a location nobody has placed on this drawing. Drawn as a squiggle
  /// heading off the page rather than a line that stops for no reason.
  bool offSheet,

  /// What the run lands on at each end, printed beside that end of the line.
  /// Empty prints nothing — see [CablingBundle.fromLabel].
  String fromLabel,
  String toLabel,

  /// The marker at each end, so an end label can be anchored just clear of the
  /// dot the run lands on rather than on top of it.
  Rect? fromDot,
  Rect? toDot,
});

/// Draws the cable runs over the plan, each in the colour the cabling drawing
/// gives it and labelled with what it carries.
///
/// Two things a cabling sheet has to get right, and neither is the line
/// itself:
///
///   * THE ROUTE goes round the markers and callouts between its two ends —
///     computed upstream, in [_FloorPlanViewState._runsOnPlan], because a
///     lattice search is not something to repeat on every hover.
///
///   * THE CAPTION goes somewhere nothing else already is. Runs sharing a pair
///     of markers get ONE stacked block, and a block that would land on a
///     location's name, a callout or another caption is walked clear of it.
///     A drawing whose labels cover each other is a drawing that under-reports
///     the job, which is the one thing this sheet exists not to do.
class _PlanCablePainter extends CustomPainter {
  final List<_PlanRun> runs;

  /// The caption blocks, laid out by [_planCaptions] before the frame so the
  /// drawing and the drag targets over it cannot disagree about where a label
  /// is.
  final List<_PlanCaption> captions;

  /// The markers and callouts already printed on the sheet.
  final List<Rect> keepClear;

  final bool dark;

  /// What this sheet prints cable-run text in. See [PlanLabelStyle]: an unset
  /// style leaves the theme's own plate, which is what every sheet drawn
  /// before this existed still gets.
  final PlanLabelStyle style;

  const _PlanCablePainter({
    required this.runs,
    required this.captions,
    required this.keepClear,
    required this.dark,
    this.style = PlanLabelStyle.unset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Each run hops over the ones already down. On a plan the lines cross
    // constantly — that is what a room looks like from above — and two lines
    // meeting at a point is indistinguishable from two lines joining at one
    // unless the drawing says which is on top.
    final drawn = <List<Offset>>[];
    for (final run in runs) {
      if (run.route.length < 2) continue;
      paintRun(
        canvas: canvas,
        route: run.route,
        color: run.color,
        strokeWidth: 3,
        style: run.style,
        hops: run.offSheet ? const [] : routeCrossings(run.route, drawn),
        offSheet: run.offSheet,
      );
      drawn.add(run.route);
    }

    // The caption blocks were laid out before the frame — see [_planCaptions] —
    // so the boxes drawn here are the same boxes the tab put drag targets on.
    // Drawn after every line is down, so a block sits over its own run rather
    // than under the next one.
    final taken = [...keepClear];
    for (final caption in captions) {
      _paintCaption(canvas, caption);
      taken.add(caption.box);
    }

    // The end labels last, so what a run TERMINATES INTO is on top of the
    // lines rather than under the next one drawn. Each dodges everything
    // already down, the run captions included.
    //
    // Anchored clear of the marker the run lands on — a dot here rather than
    // the wide box the cabling sheet has, so the walk stops almost at once and
    // the label sits right at the end, which is where it belongs on a plan.
    for (final run in runs) {
      for (final end in [
        (text: run.fromLabel, atStart: true, dot: run.fromDot),
        (text: run.toLabel, atStart: false, dot: run.toDot),
      ]) {
        if (end.text.trim().isEmpty) continue;
        final anchor = runEndAnchor(
          run.route,
          atStart: end.atStart,
          clearOf: end.dot,
        );
        if (anchor == null) continue;
        final placed = paintRunEndLabel(
          canvas: canvas,
          text: end.text,
          at: anchor.at,
          towards: anchor.towards,
          color: run.color,
          dark: dark,
          taken: taken,
          background: style.background == 0 ? null : Color(style.background),
          ink: style.ink == 0 ? null : Color(style.ink),
        );
        if (placed != null) taken.add(placed);
      }
    }
  }

  /// Draws one caption block where [_planCaptions] put it.
  void _paintCaption(Canvas canvas, _PlanCaption caption) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(caption.box, const Radius.circular(3)),
      // The plan underneath is a drawing, not a background — the label needs
      // something solid behind it or it lands on top of a wall line.
      Paint()
        ..color = planLabelBackground(
          style,
          dark ? const Color(0xE6202428) : const Color(0xE6FFFFFF),
        ),
    );

    double y = caption.box.top + _kCaptionPad;
    final left = caption.box.left + _kCaptionPad;
    for (final row in caption.rows) {
      // The dash is the key: it is what ties "6x Cat 6a" to the line it names
      // when three run side by side — in that run's own pattern as well as its
      // colour, so the tie survives a black-and-white print.
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

  @override
  bool shouldRepaint(_PlanCablePainter old) =>
      old.runs != runs ||
      old.captions != captions ||
      old.keepClear != keepClear ||
      old.dark != dark ||
      old.style.background != style.background ||
      old.style.ink != style.ink;
}

/// The padding, dash and gaps a caption block is laid out with. Shared by the
/// layout below and the painter, which is the only way the box a label is
/// dragged by can be the box it is drawn in.
const double _kCaptionPad = 3;
const double _kCaptionDash = 13;
const double _kCaptionGap = 4;
const double _kCaptionRowGap = 2;

/// One caption block: the runs it names, and the box it occupies.
typedef _PlanCaption = ({
  /// The pair of markers this block belongs to — [_PlanRun.edgeKey] — which is
  /// what a moved label is remembered under.
  String edgeKey,
  Rect box,

  /// True when somebody put this one where it is. The sheet then leaves it
  /// exactly there instead of walking it clear of what it overlaps: a label
  /// moved by hand has been moved for a reason the drawing cannot see.
  bool moved,
  List<({TextPainter text, Color color, RunLineStyle style})> rows,
});

/// Where every run caption goes on the sheet.
///
/// One block per pair of markers: six Cat 6a and five Cat 5e between the same
/// two places is one stack of two lines, not two labels on top of each other.
/// Each block dodges the markers, the callouts and everything captioned before
/// it — unless it carries a nudge in [nudges], in which case it goes exactly
/// where it was put and the ones after it dodge IT.
///
/// Laid out here rather than inside paint() for the same reason the routes
/// are: the tab needs the boxes to put drag targets over, and a label the user
/// grabs has to be the label they can see.
List<_PlanCaption> _planCaptions({
  required List<_PlanRun> runs,
  required List<Rect> keepClear,
  required Map<String, Offset> nudges,
  required bool dark,
  PlanLabelStyle style = PlanLabelStyle.unset,
  /// Edge keys whose caption is not printed. Held against the RUN rather than
  /// the sheet, so a label taken off the cabling drawing is off this one too:
  /// it is the same cable, and a label that reappears on the other sheet is a
  /// label somebody has to hide twice.
  Set<String> hiddenLabels = const {},
}) {
  final byEdge = <String, List<_PlanRun>>{};
  for (final run in runs) {
    if (hiddenLabels.contains(run.edgeKey)) continue;
    byEdge.putIfAbsent(run.edgeKey, () => []).add(run);
  }

  final out = <_PlanCaption>[];
  final taken = [...keepClear];
  for (final entry in byEdge.entries) {
    final group = entry.value;
    final rows = <({TextPainter text, Color color, RunLineStyle style})>[];
    for (final run in group) {
      rows.add((
        color: run.color,
        style: run.style,
        text: TextPainter(
          text: TextSpan(
            text: run.label,
            style: TextStyle(
              color: planLabelInk(style, dark ? Colors.white : Colors.black87),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
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

    final anchor = polylineMidpoint(group.first.route);
    final wanted = Offset(anchor.dx - width / 2, anchor.dy - height - 6);
    final nudge = nudges[entry.key] ?? Offset.zero;
    final inner = nudge == Offset.zero
        ? _freeCaptionBox(Size(width, height), wanted, taken)
        : Rect.fromLTWH(
            wanted.dx + nudge.dx,
            wanted.dy + nudge.dy,
            width,
            height,
          );
    final box = inner.inflate(_kCaptionPad);
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

/// [wanted] if nothing is already there, else the nearest spot that is clear.
///
/// Steps straight up and down first — a caption belongs ON its own run, and
/// sliding it along the line keeps it pointing at the right cable — then out
/// to the sides. Gives up and uses the original spot rather than flinging a
/// label across the sheet to somewhere it explains nothing.
Rect _freeCaptionBox(Size size, Offset wanted, List<Rect> taken) {
  Rect at(Offset o) => Rect.fromLTWH(o.dx, o.dy, size.width, size.height);
  bool free(Rect r) {
    final padded = r.inflate(_kCaptionPad);
    for (final other in taken) {
      if (padded.overlaps(other)) return false;
    }
    return true;
  }

  if (free(at(wanted))) return at(wanted);

  const step = 15.0;
  for (int ring = 1; ring <= 14; ring++) {
    for (final d in const [
      Offset(0, -1),
      Offset(0, 1),
      Offset(-1, 0),
      Offset(1, 0),
      Offset(-1, -1),
      Offset(1, -1),
    ]) {
      final candidate = at(wanted + d * (ring * step));
      if (free(candidate)) return candidate;
    }
  }
  return at(wanted);
}

/// The short specimen of a run drawn beside its name in the key — the same
/// colour, the same dash pattern, the same squiggle. Painted rather than built
/// out of widgets so it goes through exactly the code the drawing does: a
/// legend drawn a second way is a legend that eventually disagrees.
class _RunSpecimenPainter extends CustomPainter {
  final Color color;
  final RunLineStyle style;
  final bool offSheet;

  const _RunSpecimenPainter({
    required this.color,
    required this.style,
    required this.offSheet,
  });

  @override
  void paint(Canvas canvas, Size size) {
    paintRunSpecimen(
      canvas: canvas,
      from: Offset(0, size.height / 2),
      to: Offset(size.width, size.height / 2),
      color: color,
      style: style,
      strokeWidth: 2.4,
      offSheet: offSheet,
    );
  }

  @override
  bool shouldRepaint(_RunSpecimenPainter old) =>
      old.color != color || old.style != style || old.offSheet != offSheet;
}

enum _PlanTool { none, location, callout, notation }

/// Sentinels for [_FloorPlanViewState._cableLayer]. Not cable types, so they
/// are spelled in a way no cable ever will be.
const String _kLayerOff = ' off';
const String _kLayerAll = ' all';

/// How wide the key panel is drawn, and how much of that the swatch column
/// takes. Fixed, because a legend whose width follows its longest cable name
/// jumps around the drawing every time somebody retypes one.
const double _kPlanKeyWidth = 226;
const double _kPlanKeySwatch = 22;

/// How many lines a section of the key prints before it says how many it left
/// out. A panel taller than the drawing is clipped by the sheet, and a key
/// clipped at the bottom looks complete when it is not.
const int _kPlanKeyMaxRows = 12;

/// Added to a bundle id for the stub drawn when only ONE of its ends is on the
/// sheet — see [_FloorPlanViewState._offSheetRuns]. Keeps the stub from
/// colliding with the real run's id if both ever appear at once.
const String _kOffSheetSuffix = ' off-sheet';

/// How near a tap has to land to count as hitting a run.
///
/// A 2px line is not something a mouse can be asked to hit. It stays under
/// half [kCablingLaneStep] so the slack cannot reach the pull fanned out
/// beside it: clicking between two runs picks the nearer, never the wrong one
/// of a pair.
const double kRunTapSlack = 7;

/// Which drawn run a click at [at] landed on: the id whose route passes
/// nearest, or '' when nothing is within [slack].
///
/// [routes] is id -> the polyline actually drawn for it, dodges and all, so
/// this answers against the line on the page rather than the straight one
/// between its two ends.
String runIdNearest(
  Map<String, List<Offset>> routes,
  Offset at, {
  double slack = kRunTapSlack,
}) {
  String hit = '';
  double best = slack;
  for (final entry in routes.entries) {
    final route = entry.value;
    for (int i = 0; i < route.length - 1; i++) {
      final d = distanceToSegment(at, route[i], route[i + 1]);
      if (d < best) {
        best = d;
        hit = entry.key;
      }
    }
  }
  return hit;
}

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
