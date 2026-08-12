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
import 'cabling_schematic.dart';
import 'color_wheel_picker.dart';
import 'diagram_capture.dart';
import 'export_tools.dart';
import 'plan_annotations.dart';
import 'report_tools.dart';
import 'room_sidecar.dart' show AvUndoScope;
import 'undo_bar.dart';
import 'room_locations.dart';
import 'room_locations_view.dart';
import 'screenshot_tools.dart';
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

  /// Which cable runs are drawn over the plan: [_kLayerOff], [_kLayerAll], or
  /// one cable type on its own.
  ///
  /// One type at a time is how a cabling set is actually issued — the network
  /// contractor gets the network sheet and the AV contractor gets theirs — and
  /// a plan with every run on it at once is a plan nobody can trace a single
  /// pull from.
  String _cableLayer = _kLayerAll;

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
      _savedSnack(provider, 'Floor plan', outputFile);
    } catch (e) {
      _snack('Failed to save the image: $e', error: true);
    }
  }

  /// The location report, as a workbook or as plain text.
  ///
  /// The workbook is the one that gets sent: it carries the tables AND the
  /// drawing they describe — every layer of it, a sheet each — so the person
  /// reading "6 runs to the front floor box" can see which six and where they
  /// go without a second attachment. The text file stays for a quick look and
  /// for pasting into an email.
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
        final layers = await _captureCableLayers(provider);
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
            // One sheet per cable type, which is how a cabling set is issued:
            // the network contractor gets the network drawing and nobody has
            // to read around somebody else's runs.
            for (final layer in layers.skip(1))
              _layerSheet(title, layer, generated),
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

  /// One workbook sheet holding one layer's drawing and nothing else. The
  /// tables are on the Locations sheet; repeating them per layer would be five
  /// copies of one schedule with a different picture over each.
  XlsxSheet _layerSheet(
    String title,
    ({String name, String caption, Uint8List bytes}) layer,
    DateTime generated,
  ) {
    final rows = <List<dynamic>>[
      ['$title — ${layer.caption}', '', '', '', ''],
      ['Generated ${reportTimestamp(generated)}'],
      [],
    ];
    return XlsxSheet(
      name: layer.name,
      rows: rows,
      rowStyles: const {0: XlsxRowStyle.title},
      merges: const ['A1:E1'],
      image: scaledSheetImage(layer.bytes, rows.length + 1),
    );
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
                            child: _plan(provider, model, plan, drawing),
                          ),
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

  /// What the notation tool is about to draw, and what to do with whatever is
  /// selected. Only on screen while the tool is, so the page stays as quiet as
  /// it was for somebody who only came to look at the plan.
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
          if (plan != null)
            PopupMenuButton<String>(
              tooltip: 'Export the plan',
              onSelected: (v) =>
                  v == 'layers' ? _exportLayers(provider) : _exportPng(provider),
              itemBuilder: (ctx) => const [
                PopupMenuItem(value: 'one', child: Text('This view (.png)')),
                // A sheet per trade: the network contractor gets the network
                // drawing, the AV contractor gets theirs.
                PopupMenuItem(
                  value: 'layers',
                  child: Text('One image per cable type...'),
                ),
              ],
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
    AppStateProvider provider,
    AvFlowModel model,
    FloorPlan plan,
    CablingSchematic drawing,
  ) {
    final size = _imageSize;
    final theme = Theme.of(context);
    // Worked out once and handed to both the router and the captions, so the
    // line you see and the label beside it are dodging the same things.
    final obstacles = _planObstacles(provider, plan);

    return SizedBox(
      width: size.width,
      height: size.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => _onPlanTap(provider, details.localPosition),
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
            // Under the markers: a run ends AT a location, so the dot it lands
            // on should sit on top of it rather than the line crossing over.
            if (_cableLayer != _kLayerOff)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _PlanCablePainter(
                      runs: _runsOnPlan(provider, plan, drawing, obstacles),
                      // The captions dodge all of it — dots included, which
                      // the routes cannot — so a run's label never lands on
                      // the name of the place it runs to.
                      keepClear: [
                        ...obstacles.dots.values,
                        ...obstacles.always,
                      ],
                      dark: theme.brightness == Brightness.dark,
                    ),
                  ),
                ),
              ),
            // Only the locations dropped on THIS sheet. A room's locations
            // belong to the room; where they are drawn belongs to the drawing.
            for (final location in provider.avLocations)
              if (plan.markerFor(location.id) != null)
                _locationMarker(
                  provider,
                  model,
                  plan,
                  location,
                  plan.markerFor(location.id)!,
                ),
            for (final callout in plan.callouts)
              _calloutMarker(provider, model, plan, callout),
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
          ],
        ),
      ),
    );
  }

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
    if (drawable.isEmpty) return const [];

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

    return [
      for (final b in drawable)
        (
          id: b.id,
          edgeKey: edgeOf[b.id] ?? b.id,
          route: _routeOnPlan(
            from: placed[b.fromBoxId]!,
            to: placed[b.toBoxId]!,
            lane: lanes[b.id] ?? 0,
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
          fromLabel: b.fromLabel,
          toLabel: b.toLabel,
          fromDot: obstacles.dots[b.fromBoxId],
          toDot: obstacles.dots[b.toBoxId],
        ),
    ];
  }

  /// One run's path: fanned onto its lane, then stepped around whatever is
  /// printed between its two ends.
  List<Offset> _routeOnPlan({
    required Offset from,
    required Offset to,
    required double lane,
    required List<Rect> obstacles,
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
      if (!placed.contains(b.fromBoxId) || !placed.contains(b.toBoxId)) {
        continue;
      }
      seen.putIfAbsent(b.cableType, () => Color(b.color));
    }
    final types = seen.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [for (final t in types) (type: t, color: seen[t]!)];
  }

  /// How many runs cannot be drawn because an end is not on THIS sheet.
  int _unplacedRunCount(
    AppStateProvider provider,
    FloorPlan? plan,
    CablingSchematic drawing,
  ) {
    final placed = _markersOn(plan).keys.toSet();
    return drawing.bundles
        .where(
          (b) =>
              !placed.contains(b.fromBoxId) || !placed.contains(b.toBoxId),
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
          if (missing > 0)
            Tooltip(
              message: 'Both ends of a run have to be on THIS sheet before it '
                  'can be drawn. Turn on "Place locations" and click where '
                  'the missing end goes.',
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

  /// Renders the sheet once per cable layer: everything first, then one
  /// drawing per cable type.
  ///
  /// The layer picker is flipped and the canvas re-captured each time, which
  /// is the only way to get these — only a widget on screen can be rendered —
  /// and the picker is put back where it was afterwards. Shared by the PNG
  /// export and the workbook so the two cannot come out of a different set of
  /// drawings.
  ///
  /// [name] is the sheet name the workbook uses (Excel: 31 chars, no
  /// `: \ / ? * [ ]`); [caption] is what it is called in prose.
  Future<List<({String name, String caption, Uint8List bytes})>>
  _captureCableLayers(AppStateProvider provider) async {
    final model = buildAvFlowModel(provider);
    final layers = _cableLayers(
      provider,
      provider.activeFloorPlan,
      provider.cablingSchematic(model),
    );
    final out = <({String name, String caption, Uint8List bytes})>[];
    final was = _cableLayer;
    for (final layer in [_kLayerAll, ...layers.map((l) => l.type)]) {
      if (!mounted) break;
      setState(() => _cableLayer = layer);
      // Let the change actually paint before the boundary is captured;
      // without this every image would be of whatever was on screen when the
      // loop started.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) break;
      final bytes = await captureBoundary(_planKey, pixelRatio: 2.0);
      if (bytes == null) continue;
      final caption = layer == _kLayerAll ? 'All runs' : layer;
      out.add((
        name: layer == _kLayerAll ? 'All runs' : _sheetSafe(layer),
        caption: caption,
        bytes: bytes,
      ));
    }
    if (mounted) setState(() => _cableLayer = was);
    return out;
  }

  /// A cable type as a workbook sheet name: Excel refuses the punctuation and
  /// stops at 31 characters, and "Fiber (OS2)" is a real cable type.
  static String _sheetSafe(String name) {
    final cleaned = name.replaceAll(RegExp(r'[:\\/?*\[\]]'), ' ').trim();
    return cleaned.length > 31 ? cleaned.substring(0, 31) : cleaned;
  }

  /// Writes one PNG per cable type into a folder the user picks.
  ///
  /// A sheet per trade is the whole point of the layers: the network
  /// contractor gets the network drawing and the AV contractor gets theirs,
  /// and neither has to read around the other's runs.
  Future<void> _exportLayers(AppStateProvider provider) async {
    final model = buildAvFlowModel(provider);
    if (_cableLayers(
      provider,
      provider.activeFloorPlan,
      provider.cablingSchematic(model),
    ).isEmpty) {
      _snack('No cable runs land on this sheet yet.');
      return;
    }

    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Where should the layer images go?',
    );
    if (folder == null) return;

    final captured = await _captureCableLayers(provider);
    final written = <String>[];
    final failed = <String>[];
    for (final layer in captured) {
      final safe = layer.caption
          .replaceAll(RegExp(r'[^\w\-]+'), '_')
          .toLowerCase();
      try {
        final file = File(
          p.join(
            folder,
            '${roomFileStem(provider, 'floor_plan')}_$safe.png',
          ),
        );
        await file.writeAsBytes(layer.bytes);
        written.add(p.basename(file.path));
      } catch (e) {
        failed.add('${layer.caption} — $e');
      }
    }

    if (!mounted) return;
    if (failed.isEmpty && written.isNotEmpty) {
      showSavedFolderSnack(
        context,
        provider,
        'Wrote ${written.length} layer image'
        '${written.length == 1 ? '' : 's'} to ${p.basename(folder)}',
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
    const w = kLocationLabelWidth + 8;

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
              // is a plan somebody has to hover over to read.
              Container(
                margin: const EdgeInsets.only(top: 2),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                constraints: const BoxConstraints(
                  maxWidth: kLocationLabelWidth + 8,
                ),
                color: Colors.white.withValues(alpha: 0.85),
                child: Text(
                  location.name,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: kLocationLabelFontSize,
                    color: Colors.black87,
                  ),
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
      case _PlanTool.notation:
        final plan = provider.activeFloorPlan;
        if (plan == null) return;
        // Selecting, not drawing: a shape is dragged out, and a tap is how you
        // pick one up to recolour, relabel or delete it. Picking one up takes
        // the keyboard too, so Delete removes it.
        _selectNote(annotationAt(plan.annotations, at)?.id ?? '');
      case _PlanTool.none:
        setState(() => _selectedCalloutId = null);
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
              tooltip: 'Add a cable run',
              onPressed: () async {
                await showScreenSwitchEditor(context, provider, null);
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
        Text(
          'Cable between two places in this room that no device on the signal '
          'flow accounts for — a screen switch and the motor it drives, a '
          'spare conduit, somebody else\'s contract. Recorded here, they get '
          'costed, scheduled and drawn on the cabling sheet with the rest.',
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

  /// The markers and callouts already printed on the sheet.
  final List<Rect> keepClear;

  final bool dark;

  const _PlanCablePainter({
    required this.runs,
    required this.keepClear,
    required this.dark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final run in runs) {
      if (run.route.length < 2) continue;
      final path = Path()..moveTo(run.route.first.dx, run.route.first.dy);
      for (int i = 1; i < run.route.length; i++) {
        path.lineTo(run.route[i].dx, run.route[i].dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = run.color
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }

    // One caption block per pair of markers, placed after every line is down
    // so the block can be laid over its own run rather than under the next.
    final byEdge = <String, List<_PlanRun>>{};
    for (final run in runs) {
      byEdge.putIfAbsent(run.edgeKey, () => []).add(run);
    }

    // Grows as captions are placed: each one dodges the markers, the callouts
    // AND everything captioned before it.
    final taken = [...keepClear];
    for (final group in byEdge.values) {
      final placed = _paintCaption(
        canvas,
        group,
        polylineMidpoint(group.first.route),
        taken,
      );
      if (placed != null) taken.add(placed);
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
        );
        if (placed != null) taken.add(placed);
      }
    }
  }

  /// Draws one edge's stacked caption and returns the box it ended up in, or
  /// null when there was nothing to draw.
  Rect? _paintCaption(
    Canvas canvas,
    List<_PlanRun> group,
    Offset anchor,
    List<Rect> taken,
  ) {
    const dash = 13.0;
    const gap = 4.0;
    const rowGap = 2.0;

    final rows = <({TextPainter text, Color color})>[];
    for (final run in group) {
      rows.add((
        color: run.color,
        text: TextPainter(
          text: TextSpan(
            text: run.label,
            style: TextStyle(
              color: dark ? Colors.white : Colors.black87,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(),
      ));
    }
    if (rows.isEmpty) return null;

    double width = 0;
    double height = 0;
    for (final row in rows) {
      final w = dash + gap + row.text.width;
      if (w > width) width = w;
      height += row.text.height + rowGap;
    }
    height -= rowGap;

    final box = _freeCaptionBox(
      Size(width, height),
      Offset(anchor.dx - width / 2, anchor.dy - height - 6),
      taken,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(box.inflate(3), const Radius.circular(3)),
      // The plan underneath is a drawing, not a background — the label needs
      // something solid behind it or it lands on top of a wall line.
      Paint()..color = dark ? const Color(0xE6202428) : const Color(0xE6FFFFFF),
    );

    double y = box.top;
    for (final row in rows) {
      // The dash is the key: it is what ties "6x Cat 6a" to the line it names
      // when three run side by side.
      canvas.drawLine(
        Offset(box.left, y + row.text.height / 2),
        Offset(box.left + dash, y + row.text.height / 2),
        Paint()
          ..color = row.color
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
      row.text.paint(canvas, Offset(box.left + dash + gap, y));
      y += row.text.height + rowGap;
    }
    return box.inflate(3);
  }

  /// [wanted] if nothing is already there, else the nearest spot that is
  /// clear.
  ///
  /// Steps straight up and down first — a caption belongs ON its own run, and
  /// sliding it along the line keeps it pointing at the right cable — then out
  /// to the sides. Gives up and uses the original spot rather than flinging a
  /// label across the sheet to somewhere it explains nothing.
  static Rect _freeCaptionBox(Size size, Offset wanted, List<Rect> taken) {
    Rect at(Offset o) => Rect.fromLTWH(o.dx, o.dy, size.width, size.height);
    bool free(Rect r) {
      final padded = r.inflate(3);
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

  @override
  bool shouldRepaint(_PlanCablePainter old) =>
      old.runs != runs || old.keepClear != keepClear || old.dark != dark;
}

enum _PlanTool { none, location, callout, notation }

/// Sentinels for [_FloorPlanViewState._cableLayer]. Not cable types, so they
/// are spelled in a way no cable ever will be.
const String _kLayerOff = ' off';
const String _kLayerAll = ' all';

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
