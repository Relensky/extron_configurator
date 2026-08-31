import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'building_project.dart';
import 'color_wheel_picker.dart';
import 'contrast.dart';
import 'name_colors.dart';
import 'pdf_viewer_dialog.dart';
import 'pinned_grid.dart';
import 'project_estimate.dart';
import 'report_tools.dart';
import 'responsibility_matrix.dart';
import 'screenshot_tools.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  THE RESPONSIBILITY PANE
/// ============================================================================
///  The roles and responsibilities matrix, edited and issued. See
///  responsibility_matrix.dart for what the document is and why it is a row per
///  scope item rather than a column per one.
///
///  TWO WAYS OUT, because it is read by two different audiences:
///
///    * A SPREADSHEET, for the people who work from it — the contractor prices
///      the totals column, and a spreadsheet is what a price gets typed into.
///    * A PICTURE, for the people who only have to see it — it goes in a
///      submittal, in a slide, in an email to a dean. Those readers do not want
///      a file to open, and a screenshot somebody takes by hand is one that
///      cuts off the last two rows.
///
///  The picture is produced from a PREVIEW somebody looks at first rather than
///  captured off this pane. What is on this pane is an editor — it has buttons
///  on every row and it is as wide as the window — and photographing an editor
///  produces a picture with delete buttons in it. The preview is the document.
///
///  A COLOUR PER PARTY. The question this sheet is read for is whose job a line
///  is, and the answer was black text in a narrow column on a grid thirty
///  columns wide. Each party now carries its own colour — the same one wherever
///  its name appears, from [tintForName] — so the contractor's share of the
///  sheet is visible without reading a single cell, and the lines nobody has
///  been named on stay grey, because an unagreed line must never read as an
///  agreed one. The name is still written in every cell: the colour is a second
///  way to read the sheet, never the only one.
/// ============================================================================

/// The matrix pane, as slivers for the project tab's one scroll view.
///
/// [estimate] is taken and unused: every pane on the tab has the same
/// signature, and this one is about the job's scope rather than its price. A
/// pane that could not be called the same way as the others is a pane the
/// switch above it has to special-case.
List<Widget> responsibilitySlivers(
  BuildContext context,
  // ignore: avoid_unused_constructor_parameters
  ProjectEstimate estimate,
) {
  final provider = context.watch<AppStateProvider>();
  final project = provider.project;
  final items = project.responsibility;
  // The code on the door - 'BSS 101' - not the file the room is stored in.
  // Only this layer has both the job's room list and the configs behind it.
  final columns = project.responsibilityRoomColumns(
    names: estimate.roomCodeNames,
  );

  return [
    SliverToBoxAdapter(child: _Toolbar(project: project, columns: columns)),
    const SliverToBoxAdapter(child: Divider(height: 1)),
    if (items.isNotEmpty)
      SliverToBoxAdapter(
        child: _MatrixGrid(project: project, columns: columns),
      ),
    if (items.isNotEmpty) const SliverToBoxAdapter(child: Divider(height: 1)),
    if (items.isEmpty)
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(
            child: Text(
              'Nothing agreed yet.\n\n'
              'The matrix says who buys each piece of scope and who installs '
              'it - the thing that is discovered on site when it was never '
              'written down. Start it from the usual lines and edit from '
              'there.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      )
    else
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, i) => _ItemRow(
            item: items[i],
            columns: columns,
            first: i == 0,
            last: i == items.length - 1,
          ),
          childCount: items.length,
        ),
      ),
    const SliverToBoxAdapter(child: SizedBox(height: 24)),
  ];
}

// ---------------------------------------------------------------------------
//  THE CUTSHEET
// ---------------------------------------------------------------------------
//  Every line on this matrix has a product behind it, and the argument the
//  document exists to settle - is THIS the screen we agreed - is settled by
//  looking at the cutsheet. Before this the link was a string in a dialog:
//  something to select, copy, and paste into a browser, which is three steps
//  more than anybody takes while reading a sheet.

/// Where a cutsheet actually is on this machine, for a link that is a file.
///
/// Resolved against the project file exactly the way a room's config path and
/// a building plan are, so a job folder that has been moved or handed over
/// still finds its own documents.
String resolveCutsheetPath(AppStateProvider provider, ResponsibilityItem item) {
  if (item.productLink.trim().isEmpty || item.productIsUrl) return '';
  return BuildingProject.resolvePath(
    item.productLink.trim(),
    provider.currentProjectPath,
  );
}

/// Opens the cutsheet behind one line: IN THE APP where it can be drawn,
/// otherwise in whatever this machine opens it with.
///
/// The same bargain the plans pane makes, and for the same reason - a PDF
/// handed to the machine's reader is a second window that has to be found
/// again every time, and the thing somebody is doing with it (checking a model
/// number against the line they are reading) is a thing they are doing HERE.
Future<void> openResponsibilityCutsheet(
  BuildContext context,
  ResponsibilityItem item,
) async {
  final provider = context.read<AppStateProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final link = item.productLink.trim();
  if (link.isEmpty) return;

  // A web page is the browser's job. Nothing in this app renders one, and
  // pretending otherwise would be a blank panel with a URL at the top.
  if (item.productIsUrl) {
    final uri = Uri.tryParse(link);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      showTimedSnackBar(
        messenger,
        SnackBar(content: Text('Could not open $link')),
      );
    }
    return;
  }

  final resolved = resolveCutsheetPath(provider, item);
  // SAID, NOT THROWN. A cutsheet that has been moved is a fact about the file,
  // and "the viewer failed" would send somebody looking in the wrong place.
  if (resolved.isEmpty || !File(resolved).existsSync()) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text(
          'The cutsheet for ${item.scope} is not where the matrix says it '
          'is${resolved.isEmpty ? '' : ' ($resolved)'}.',
        ),
      ),
    );
    return;
  }

  final extension = path.extension(resolved).replaceFirst('.', '').toLowerCase();
  if (!kViewablePlanExtensions.contains(extension)) {
    final error = await provider.openInDesktop(resolved);
    if (error != null) {
      showTimedSnackBar(messenger, SnackBar(content: Text(error)));
    }
    return;
  }

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => PdfViewerDialog(
      filePath: resolved,
      title: item.productName,
      screenshotStem: path.basenameWithoutExtension(resolved),
      onOpenExternally: () => provider.openInDesktop(resolved),
    ),
  );
}

/// The way in to a cutsheet, wherever a line is being read.
///
/// Named rather than iconic: 'NEC-P525UL.pdf' says which document is behind
/// the line, and a bare paperclip says only that one is.
class CutsheetLink extends StatelessWidget {
  final ResponsibilityItem item;

  /// Drawn small enough to sit inside a grid column head.
  final bool compact;

  const CutsheetLink({super.key, required this.item, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (item.productLink.trim().isEmpty) return const SizedBox.shrink();

    final icon = item.productIsUrl
        ? Icons.open_in_new
        : Icons.picture_as_pdf_outlined;

    // ON THE GRID IT IS A WHOLE ROW, not an icon.
    //
    // It was a 22-pixel icon button sharing a cell with the scope name, inside
    // the InkWell that opens the editor - the smallest target on the sheet, in
    // front of a bigger one that does something else. Here it fills the cell
    // it is given, so the press is the row.
    //
    // The word rather than the file name: the column is 116 wide and
    // 'NEC-P525UL.pdf' ellipsises to 'NEC-P…' in it, which says less than
    // 'PDF' does. The file name is on the tooltip and on the editor list
    // below, where there is room to read it.
    if (compact) {
      return Tooltip(
        message: 'Open ${item.productName}',
        child: InkWell(
          key: ValueKey('matrix_cutsheet_${item.id}'),
          onTap: () => openResponsibilityCutsheet(context, item),
          child: SizedBox.expand(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: gridMetric(context, 15),
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    item.productIsUrl ? 'Link' : 'PDF',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return TextButton.icon(
      key: ValueKey('responsibility_cutsheet_${item.id}'),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () => openResponsibilityCutsheet(context, item),
      icon: Icon(icon, size: gridMetric(context, 16)),
      label: Text(item.productName),
    );
  }
}

class _Toolbar extends StatelessWidget {
  final BuildingProject project;
  final List<({String id, String name})> columns;

  const _Toolbar({required this.project, required this.columns});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final items = project.responsibility;
    final open = items.where((i) => i.unassigned).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.tonalIcon(
            key: const ValueKey('responsibility_add'),
            onPressed: () async {
              final item = provider.addResponsibilityItem();
              if (!context.mounted) return;
              await showResponsibilityEditor(context, item.id, columns);
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add a line'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('responsibility_starters'),
            onPressed: () {
              final added = provider.addStarterResponsibilityItems();
              showTimedSnackBar(
                ScaffoldMessenger.of(context),
                SnackBar(
                  content: Text(
                    added == 0
                        ? 'Every one of the usual lines is already on the '
                            'matrix.'
                        : '$added line${added == 1 ? '' : 's'} added. Edit the '
                            'parties and quantities to suit the job.',
                  ),
                ),
              );
            },
            icon: const Icon(Icons.playlist_add, size: 18),
            label: const Text('Add the usual lines'),
          ),
          if (items.isNotEmpty) ...[
            OutlinedButton.icon(
              key: const ValueKey('responsibility_export_xlsx'),
              onPressed: () => _exportSpreadsheet(context, project, columns),
              icon: const Icon(Icons.table_view, size: 18),
              label: const Text('Spreadsheet'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('responsibility_export_image'),
              onPressed: () =>
                  showResponsibilityImage(context, project, columns),
              icon: const Icon(Icons.image_outlined, size: 18),
              label: const Text('Image'),
            ),
          ],
          if (open > 0)
            Text(
              '$open line${open == 1 ? '' : 's'} with nobody named. A matrix '
              'issued with blanks reads as agreed.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          // The key to the colours on the grid below, built from the parties
          // actually named on this job - and the place they are SET. A colour
          // is chosen by pressing the colour, which is the only control on
          // this pane whose meaning is already on screen.
          if (items.isNotEmpty)
            NameTintKey(
              key: const ValueKey('responsibility_party_key'),
              title: 'PARTIES',
              names: partiesOn(items),
              keyPrefix: 'responsibility_party',
              colorOf: (name) {
                final assigned = project.partyColor(name);
                return assigned == null ? null : Color(assigned);
              },
              onTap: (name) => showPartyColorDialog(context, name),
            ),
        ],
      ),
    );
  }
}

/// Every party named on [items], furnishers and installers together, in the
/// order they first appear on the sheet.
///
/// One list rather than two, because a party is one party: the contractor who
/// installs the screens and furnishes the ceiling boxes has to be the same
/// colour in both rows or the colour stops meaning anybody.
List<String> partiesOn(List<ResponsibilityItem> items) {
  final seen = <String>{};
  final out = <String>[];
  for (final item in items) {
    for (final party in [item.furnishedBy, item.installedBy]) {
      final key = normalisedName(party);
      if (key.isEmpty || !seen.add(key)) continue;
      out.add(party.trim());
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
//  THE COLOUR A PARTY READS IN
// ---------------------------------------------------------------------------
//  Every party already derives a stable colour from its own name, which is
//  what makes a matrix legible the moment it is started and before anybody has
//  set anything up. What a derived colour cannot do is AGREE with anything
//  outside this app - and this is the one document here that is issued into
//  somebody else's stack of paper. The general contractor has been blue on
//  every drawing in the submittal for a year; the campus colour-codes its
//  trades; the last matrix that went out was coloured by hand in Excel. A hue
//  nobody can change is a hue that argues with all three.
//
//  So the colour is assignable, exactly the way a vendor's is (see
//  [showVendorColorDialog]) - the same twelve swatches, the same way back to
//  automatic - and it carries into the picture and the spreadsheet, because
//  those are the copies anybody outside this room will ever see.

/// The palette a party's colour is chosen from.
///
/// The same twelve the derived colours come out of, so a chosen colour and a
/// derived one belong to one set rather than looking like two systems on one
/// sheet. Any other colour is one press further on, through the wheel.
const List<Color> kResponsibilityPalette = kNameTintWheel;

/// Picks the colour [party] reads in, everywhere it appears.
Future<void> showPartyColorDialog(BuildContext context, String party) async {
  final named = party.trim();
  if (named.isEmpty) return;
  final provider = context.read<AppStateProvider>();

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        // Re-read the project every rebuild: the swatch that reads as chosen
        // has to be the one the job actually holds.
        final assigned = provider.project.partyColor(named);
        final shown = resolveTint(assigned: assigned, name: named);

        return AlertDialog(
          key: const ValueKey('responsibility_party_color_dialog'),
          title: Text('Colour for $named'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Every line $named furnishes or installs is marked in this '
                  'colour - on the grid, in the picture that goes in the '
                  'submittal, and in the spreadsheet the contractor prices.',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in kResponsibilityPalette)
                      ColorSwatchButton(
                        key: ValueKey(
                          'party_color_${responsibilityPartyKey(named)}_'
                          '${(c.toARGB32() & 0xFFFFFF).toRadixString(16)}',
                        ),
                        color: c,
                        selected: shown.toARGB32() == c.toARGB32(),
                        onTap: () => setLocal(
                          () => provider.setResponsibilityPartyColor(
                            named,
                            c.toARGB32(),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                // A Wrap rather than a Row: two labelled buttons are wider
                // than the dialog at anything above the default text size, and
                // an Automatic button half off the edge is the way back to the
                // derived colour that cannot be pressed.
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('party_color_custom'),
                      icon: const Icon(Icons.colorize, size: 16),
                      label: const Text('Any other colour'),
                      onPressed: () async {
                        final picked = await showColorWheelDialog(
                          ctx,
                          initial: shown,
                          title: 'Colour for $named',
                        );
                        if (picked == null) return;
                        setLocal(
                          () => provider.setResponsibilityPartyColor(
                            named,
                            picked.toARGB32(),
                          ),
                        );
                      },
                    ),
                    // Back to the colour the name gives it. Disabled while
                    // nothing has been assigned, so the button also says
                    // whether this party's colour was chosen or derived.
                    TextButton.icon(
                      key: const ValueKey('party_color_auto'),
                      icon: const Icon(Icons.auto_awesome, size: 16),
                      label: const Text('Automatic'),
                      onPressed: assigned == null
                          ? null
                          : () => setLocal(
                              () => provider.setResponsibilityPartyColor(
                                named,
                                null,
                              ),
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            ElevatedButton(
              key: const ValueKey('party_color_done'),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Done'),
            ),
          ],
        );
      },
    ),
  );
}

// ---------------------------------------------------------------------------
//  THE MATRIX ITSELF
// ---------------------------------------------------------------------------

/// The matrix as a grid: rooms down the left, scope across the top.
///
/// THE ROOM COLUMN DOES NOT MOVE. A job with thirty scope items is far wider
/// than any window, and a grid where the room names scroll off to the left is
/// one where the number under your finger belongs to a room you can no longer
/// see — which is the exact mistake this document exists to prevent. So the
/// names are painted in a fixed column and only the scope columns scroll.
///
/// The two halves are laid out with the SAME fixed row heights rather than
/// with intrinsic ones, because that is the only way two independent columns
/// stay on the same line as each other. Every height here is shared by both.
/// The five sizes the two halves of the matrix are both laid out on.
typedef _Metrics = ({
  double headRow,

  /// The cutsheet's OWN row under every scope name - see [_MatrixGrid].
  double cutsheetRow,

  double partyRow,
  double bodyRow,
  double roomColumn,
  double itemColumn,
});

class _MatrixGrid extends StatefulWidget {
  final BuildingProject project;
  final List<({String id, String name})> columns;

  const _MatrixGrid({required this.project, required this.columns});

  @override
  State<_MatrixGrid> createState() => _MatrixGridState();
}

/// ============================================================================
///  READING ACROSS A SHEET THIRTY COLUMNS WIDE
/// ============================================================================
///  Two things were missing from this grid, and both are about the same
///  failure: reading a quantity off the wrong line.
///
///    THE ROW UNDER THE POINTER IS LIT. A room name on the frozen left edge
///    and a number twenty-eight columns to the right of it are two hand-widths
///    apart on a laptop, with nine identical rows between them. The band on
///    alternate rows helps and is not enough - it says "this is an odd row",
///    not "this is YOUR row". Hovering anything on a line now washes the whole
///    line, frozen half included, in the accent colour: the eye tracks a
///    moving highlight across a page in a way it cannot track a fixed stripe.
///
///    THE SHEET ZOOMS. It is the same document as the replacement plan - wider
///    than any window, read both for a figure and for its shape - and it gets
///    the same control: steps out to see the whole agreement, steps in to read
///    a quantity, and one press that fits it to the window. See
///    [GridZoomControls]. Fitted by default, because the first question this
///    sheet is opened with is "how much of it has nobody claimed", and that is
///    a question about the whole sheet.
class _MatrixGridState extends State<_MatrixGrid> {
  /// The room row under the pointer, or null. A [ValueNotifier] rather than
  /// [State.setState]: this grid builds every one of its cells eagerly (a
  /// forty-room job with thirty scope items is twelve hundred of them), and
  /// rebuilding all of it each time the pointer crosses a row boundary is a
  /// sheet that stutters as it is read. Only the rows listen.
  final ValueNotifier<int?> _hover = ValueNotifier<int?>(null);

  /// How big the sheet is being read at. See [GridZoomControls].
  double _zoom = kGridZoomNormal;

  /// Whether the size is taken from the WINDOW rather than from the steps.
  /// On by default and re-measured on every layout, so it keeps fitting when
  /// the window is resized or the side pane is folded away.
  bool _fit = true;

  @override
  void dispose() {
    _hover.dispose();
    super.dispose();
  }

  /// EVERY MEASUREMENT ON THE SHEET IS THE READER'S MEASUREMENT.
  ///
  /// These were fixed pixels, which on a display at 150% left a 20-pixel party
  /// row with a chip in it that no longer fitted and a 104-pixel column whose
  /// scope name had been ellipsised down to two words. The base numbers are
  /// unchanged; what is new is that they grow with the type ([gridMetric]) and
  /// then with the reader's own zoom on top of it - the display scale is what
  /// the machine says this person needs, and the zoom is what THIS sheet needs
  /// this minute.
  ///
  /// The frozen half and the scrolling half are two independent Columns laid
  /// out on the SAME heights, so every one of these is read once and passed to
  /// both - a metric computed twice is two halves that drift apart.
  static _Metrics _metrics(
    BuildContext context, {
    required double zoom,
    required double roomColumn,
  }) => (
    headRow: gridMetric(context, 60) * zoom,
    cutsheetRow: gridMetric(context, 26) * zoom,
    partyRow: gridMetric(context, 24) * zoom,
    bodyRow: gridMetric(context, 28) * zoom,
    roomColumn: roomColumn * zoom,
    itemColumn: naturalItemColumn(context) * zoom,
  );

  /// The width one scope column takes before any zoom - what a fit is measured
  /// against.
  static double naturalItemColumn(BuildContext context) =>
      gridMetric(context, 116);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => _sheet(context, box.maxWidth),
  );

  Widget _sheet(BuildContext context, double available) {
    final theme = Theme.of(context);
    final columns = widget.columns;
    final items = widget.project.responsibility;
    if (items.isEmpty || columns.isEmpty) {
      return const SizedBox.shrink();
    }

    // WIDE ENOUGH FOR THE NAMES IT ACTUALLY CARRIES - see
    // [PinnedGrid.frozenWidthFor]. The column was a flat 176 pixels chosen for
    // 'BSS 103', and a job whose rooms are called 'Lecture Hall (north)' got a
    // frozen column of ellipses, which names nothing.
    final naturalRoom = PinnedGrid.frozenWidthFor(
      context,
      [for (final room in columns) room.name],
      theme.textTheme.bodyMedium,
      min: gridMetric(context, 150),
      max: gridMetric(context, 320),
    );

    // FITTING SCALES THE SHEET, IT DOES NOT DROP COLUMNS. Every scope item is
    // on the sheet at every size; what changes is how much of it is on screen
    // at once.
    final zoom = _fit
        ? gridFitZoom(
            natural: naturalRoom + naturalItemColumn(context) * items.length,
            available: available - 32,
          )
        : _zoom;

    final m = _metrics(context, zoom: zoom, roomColumn: naturalRoom);

    // The type goes with the boxes. A cell at half size with the same figure
    // in it is a cell with an ellipsis where the quantity was.
    final zoomed = zoomedTextTheme(theme, zoom);

    // Rooms, and then the totals line under them.
    final bodyRows = columns.length + 1;

    // THE CUTSHEET GETS A ROW OF ITS OWN.
    //
    // It used to be a 22-pixel icon wedged onto the end of the scope name,
    // inside the same InkWell that opens the editor - so a press that missed
    // it by three pixels opened a dialog instead of the document, and the
    // document is the thing this sheet gets opened to settle. A row of its own
    // is the width of the whole column and cannot be pressed by accident from
    // anywhere else.
    //
    // ONE DECISION FOR THE WHOLE GRID, not one per column. The frozen half and
    // the scrolling half are laid out on the same heights, so a row that some
    // columns had and others did not would be two halves that no longer line
    // up. A job with no cutsheets anywhere keeps the row off and the sheet
    // stays as short as it was.
    final anyCutsheet = items.any((i) => i.productLink.trim().isNotEmpty);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Hover a line to light it right across the sheet.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              GridZoomControls(
                keyPrefix: 'matrix',
                zoom: zoom,
                fitted: _fit,
                onChanged: (z) => setState(() {
                  _zoom = z;
                  _fit = false;
                }),
                onFit: () => setState(() {
                  // Leaving the fit keeps the size it fitted to, so the sheet
                  // does not jump back to 100% under the reader.
                  if (_fit) _zoom = zoom;
                  _fit = !_fit;
                }),
              ),
            ],
          ),
          // ITS OWN FRAME, SCROLLING BOTH WAYS. A job with thirty scope items
          // and forty rooms is wider and taller than any window it is read in,
          // and laid out at full size inside the tab's scroll view it pushed
          // the item list under it off the bottom and gave no bar to say the
          // columns carried on past the right edge. What is pinned is what
          // says a cell's meaning: the room down the side, the scope and the
          // two parties across the top.
          PinnedGrid(
            frozenWidth: m.roomColumn,
            headerHeight:
                m.headRow + (anyCutsheet ? m.cutsheetRow : 0) + m.partyRow * 2,
            bodyWidth: m.itemColumn * items.length,
            bodyHeight: m.bodyRow * bodyRows,
            corner: _frozenHead(theme, zoomed, m, anyCutsheet),
            header: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final item in items)
                  _itemHead(context, zoomed, item, m, anyCutsheet),
              ],
            ),
            frozen: _frozenBody(theme, zoomed, m),
            // ROW-MAJOR, and that is not a detail. Laid out as a column per
            // scope item, a "row" was not a widget at all and there was
            // nothing for a pointer to enter; one Row per room gives the
            // highlight something to live on, and costs one listener a line
            // instead of one a cell.
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, room) in columns.indexed)
                  _bodyRow(context, zoomed, m, i, room),
                _totalsRow(theme, zoomed, m),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The corner: what the frozen column is, and what the two rows under every
  /// scope name are.
  Widget _frozenHead(
    ThemeData theme,
    TextTheme zoomed,
    _Metrics m,
    bool anyCutsheet,
  ) {
    final line = _line(theme);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _cell(
          height: m.headRow,
          align: Alignment.bottomLeft,
          line: line,
          fill: _headFill(theme),
          strongRight: true,
          child: Text('ROOM', style: _headStyle(theme, zoomed)),
        ),
        if (anyCutsheet)
          _cell(
            height: m.cutsheetRow,
            line: line,
            fill: _headFill(theme),
            strongRight: true,
            child: Text('Cutsheet', style: _metaStyle(theme, zoomed)),
          ),
        _cell(
          height: m.partyRow,
          line: line,
          strongRight: true,
          child: Text('Furnished by', style: _metaStyle(theme, zoomed)),
        ),
        _cell(
          height: m.partyRow,
          line: line,
          strongRight: true,
          strongBottom: true,
          child: Text('Installed by', style: _metaStyle(theme, zoomed)),
        ),
      ],
    );
  }

  /// The half that stays put: what each row IS.
  Widget _frozenBody(ThemeData theme, TextTheme zoomed, _Metrics m) {
    final line = _line(theme);
    final columns = widget.columns;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, room) in columns.indexed)
          _hoverRow(
            index: i,
            builder: (lit) => _cell(
              height: m.bodyRow,
              line: line,
              fill: _rowFill(theme, i, lit),
              strongRight: true,
              strongBottom: i == columns.length - 1,
              child: Text(
                room.name,
                overflow: TextOverflow.ellipsis,
                style: zoomed.bodyMedium?.copyWith(
                  fontWeight: lit ? FontWeight.w600 : null,
                ),
              ),
            ),
          ),
        _cell(
          height: m.bodyRow,
          line: line,
          fill: _totalsFill(theme),
          strongRight: true,
          child: Text('Totals', style: _headStyle(theme, zoomed)),
        ),
      ],
    );
  }

  /// One room's line across every scope column, lit as a whole when the
  /// pointer is anywhere on it.
  Widget _bodyRow(
    BuildContext context,
    TextTheme zoomed,
    _Metrics m,
    int index,
    ({String id, String name}) room,
  ) {
    final theme = Theme.of(context);
    final line = _line(theme);
    final items = widget.project.responsibility;
    final last = index == widget.columns.length - 1;

    return _hoverRow(
      index: index,
      builder: (lit) {
        final fill = _rowFill(theme, index, lit);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final item in items)
              SizedBox(
                width: m.itemColumn,
                child: InkWell(
                  key: ValueKey('matrix_cell_${item.id}_${room.id}'),
                  onTap: () => _editQty(context, item, room),
                  child: _cell(
                    height: m.bodyRow,
                    align: Alignment.center,
                    line: line,
                    // The band and the highlight both run across the whole
                    // row, frozen half included, which is what makes a
                    // quantity readable against the room name thirty columns
                    // to its left.
                    fill: fill,
                    strongBottom: last,
                    child: Text(
                      formatResponsibilityQty(item.qtyByRoom[room.id] ?? 0),
                      style: zoomed.bodyMedium?.copyWith(
                        fontWeight: lit ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// The line under the rooms: what each scope item comes to across the job.
  Widget _totalsRow(ThemeData theme, TextTheme zoomed, _Metrics m) {
    final line = _line(theme);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in widget.project.responsibility)
          SizedBox(
            width: m.itemColumn,
            child: _cell(
              height: m.bodyRow,
              align: Alignment.center,
              line: line,
              fill: _totalsFill(theme),
              child: Text(
                formatResponsibilityQty(item.total),
                style: zoomed.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          ),
      ],
    );
  }

  /// Wraps one line of the sheet so that entering it anywhere lights it
  /// everywhere.
  ///
  /// The notifier is shared by both halves, which is the whole point: the
  /// pointer is over the scrolling half and the room name it belongs to is in
  /// the frozen one.
  Widget _hoverRow({
    required int index,
    required Widget Function(bool lit) builder,
  }) => MouseRegion(
    opaque: false,
    onEnter: (_) => _hover.value = index,
    // Only when it is still this row's. The two halves both report the same
    // line, so leaving one of them while still inside the other must not put
    // the highlight out.
    onExit: (_) {
      if (_hover.value == index) _hover.value = null;
    },
    child: ValueListenableBuilder<int?>(
      valueListenable: _hover,
      builder: (context, hovered, _) => builder(hovered == index),
    ),
  );

  /// Sets one cell. A dialog rather than an inline field: thirty columns of
  /// live text fields is thirty focus nodes and thirty controllers on a grid
  /// most of whose cells are empty.
  Future<void> _editQty(
    BuildContext context,
    ResponsibilityItem item,
    ({String id, String name}) room,
  ) async {
    final provider = context.read<AppStateProvider>();
    final typed = await showDialog<double>(
      context: context,
      builder: (_) => _QtyDialog(
        title: '${item.scope} in ${room.name}',
        initial: item.qtyByRoom[room.id] ?? 0,
      ),
    );
    if (typed == null) return;
    provider.setResponsibilityQty(item.id, room.id, typed);
  }

  /// One scope item's heading: its name, whose job it is, and the way to its
  /// cutsheet.
  ///
  /// THE HEAD IS ALSO THE HANDLE. The order of the columns is content on this
  /// document - it is grouped the way the work is sequenced, everything in the
  /// ceiling together - and on a sheet of thirty, nudging a column into place
  /// with the arrow buttons on the editor list below is a job nobody finishes.
  /// Dragging it is one gesture that lands where it was let go.
  Widget _itemHead(
    BuildContext context,
    TextTheme zoomed,
    ResponsibilityItem item,
    _Metrics m,
    bool anyCutsheet,
  ) {
    final theme = Theme.of(context);
    final line = _line(theme);
    final index = widget.project.responsibility.indexWhere(
      (i) => i.id == item.id,
    );

    final head = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The heading is the way IN to the line: everything about it except
        // the quantities is prose, and prose is edited in the dialog. The
        // cutsheet sits beside it because it is the one thing on the line
        // somebody wants to LOOK at rather than edit.
        InkWell(
          key: ValueKey('matrix_head_${item.id}'),
          onTap: () =>
              showResponsibilityEditor(context, item.id, widget.columns),
          child: _cell(
            height: m.headRow,
            align: Alignment.bottomLeft,
            line: line,
            fill: _headFill(theme),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _ColumnGrip(item: item, width: m.itemColumn),
                Expanded(
                  child: Text(
                    item.scope,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: zoomed.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // THE DOCUMENT, ON A LINE OF ITS OWN. Full column width, outside the
        // heading's own InkWell, so opening it is a press anywhere along the
        // row rather than a press on a 22-pixel icon inside a bigger target
        // that does something else.
        if (anyCutsheet)
          _cell(
            height: m.cutsheetRow,
            align: Alignment.center,
            line: line,
            fill: _headFill(theme),
            child: item.productLink.trim().isEmpty
                ? const SizedBox.shrink()
                : CutsheetLink(item: item, compact: true),
          ),
        // WHOSE JOB IT IS, IN ITS OWN COLOUR. Two rows under every scope
        // name, and the pair of them is what the sheet is read for.
        _cell(
          height: m.partyRow,
          line: line,
          child: _PartyCell(
            party: item.furnishedBy,
            missing: item.furnishedBy.trim().isEmpty,
          ),
        ),
        _cell(
          height: m.partyRow,
          line: line,
          strongBottom: true,
          child: _PartyCell(
            party: item.installedBy,
            missing: item.installedBy.trim().isEmpty,
          ),
        ),
      ],
    );

    // WHAT THE LINE SAYS, WHERE THE LINE IS. The prose lives in a dialog, so
    // the sheet itself used to be the one place it could not be read.
    //
    // A PLAIN MESSAGE, and never a styled one. Flutter's tooltip paints itself
    // WHITE on a dark theme and dark grey on a light one, and picks its text
    // colour to match; a colour chosen here instead was light text on the
    // white box - a tooltip that opened as an empty white rectangle. The
    // default is the only thing that is right on both themes.
    final described = Tooltip(
      message: [
        item.scope,
        if (item.work.trim().isNotEmpty) item.work.trim(),
        if (item.notes.trim().isNotEmpty) 'Notes: ${item.notes.trim()}',
        if (item.productName.isNotEmpty) 'Cutsheet: ${item.productName}',
      ].join('\n\n'),
      child: head,
    );

    return SizedBox(
      width: m.itemColumn,
      // DROPPED ON A HEAD, dragged by the grip inside it. A column is its
      // heading as far as anybody reading the sheet is concerned, so the head
      // is the target - but it is NOT the handle: dragging the head is how the
      // sheet is panned sideways, and a grid that reordered itself every time
      // somebody scrolled it would be unusable.
      child: DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != item.id,
        onAcceptWithDetails: (d) => context
            .read<AppStateProvider>()
            .reorderResponsibilityItem(d.data, index),
        builder: (context, candidate, _) => Container(
          decoration: candidate.isEmpty
              ? null
              : BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                  ),
                ),
          child: described,
        ),
      ),
    );
  }

  static TextStyle? _headStyle(ThemeData theme, TextTheme zoomed) =>
      zoomed.labelMedium?.copyWith(
        fontWeight: FontWeight.bold,
        color: theme.colorScheme.onSurfaceVariant,
      );

  static TextStyle _metaStyle(ThemeData theme, TextTheme zoomed) =>
      zoomed.labelMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ) ??
      const TextStyle(fontSize: 11);

  /// One cell, RULED.
  ///
  /// A matrix without lines on it is a spreadsheet screenshot with the grid
  /// turned off: thirty columns of numbers whose row you lose halfway across,
  /// which on this document means reading a quantity against the wrong room.
  /// So every cell draws its own bottom and right rule, alternate room rows
  /// are banded, and the two blocks that are not room rows - the parties at the
  /// top and the totals at the bottom - are separated by a heavier line.
  ///
  /// THE RULES ARE DRAWN TO BE SEEN. They were hairlines - 0.6 of a pixel of
  /// outlineVariant, which on a light theme at 100% is a grid you have to go
  /// looking for. A sheet whose lines have to be looked for is a sheet read
  /// without them.
  ///
  /// THE BORDERS GO ON EVERY CELL, both halves included. The frozen column and
  /// the scrolling columns are two independent Columns laid out on the same
  /// fixed heights; a rule on one and not the other would take a pixel off one
  /// side's rows and put the two halves permanently out of line.
  static Widget _cell({
    required double height,
    required Widget child,
    Alignment align = Alignment.centerLeft,
    Color? line,
    Color? fill,
    bool strongBottom = false,
    bool strongRight = false,
  }) => Container(
    height: height,
    alignment: align,
    padding: const EdgeInsets.symmetric(horizontal: 4),
    decoration: line == null
        ? null
        : BoxDecoration(
            color: fill,
            border: Border(
              bottom: BorderSide(
                color: line,
                width: strongBottom ? 1.6 : 0.9,
              ),
              right: BorderSide(
                color: line,
                width: strongRight ? 1.6 : 0.9,
              ),
            ),
          ),
    child: child,
  );

  /// The colour the rules are drawn in.
  ///
  /// [ColorScheme.outlineVariant] rather than [ThemeData.dividerColor]: the
  /// divider colour is tuned for one line between two blocks of content, and a
  /// grid of it on a dark theme measured as a grid that is not there.
  static Color _line(ThemeData theme) => theme.colorScheme.outlineVariant;

  /// What one room row is washed in: the highlight when the pointer is on it,
  /// otherwise the band on alternate rows.
  ///
  /// THE HIGHLIGHT IS THE ACCENT AND THE BAND IS NOT. A band has to stay a
  /// guide - the colours that mean something on this sheet are the parties' -
  /// so it is grey and faint. The highlight is a different KIND of mark: it is
  /// where the reader is, it lasts only as long as the pointer is there, and
  /// it has to be findable across two feet of grid, so it is tinted and
  /// several times stronger.
  static Color? _rowFill(ThemeData theme, int index, bool lit) {
    if (lit) return theme.colorScheme.primary.withValues(alpha: 0.16);
    return index.isOdd
        ? theme.colorScheme.onSurface.withValues(alpha: 0.055)
        : null;
  }

  /// Behind the totals line - one of the two blocks that is not a room row.
  /// Faint, and enough to say the grid has ends.
  static Color _totalsFill(ThemeData theme) =>
      theme.colorScheme.onSurface.withValues(alpha: 0.07);

  /// Behind the scope headings, the other one.
  static Color _headFill(ThemeData theme) =>
      theme.colorScheme.onSurface.withValues(alpha: 0.04);
}
/// The handle a column is dragged by.
///
/// ITS OWN TARGET, not the whole heading. The sheet is panned sideways by
/// dragging it, and a grid that reordered its columns every time somebody
/// scrolled across it would be a grid nobody dared touch. Small, at the left
/// edge of the head, drawn as the same grip every reorderable list in this app
/// uses - so the one thing it says is "this moves".
class _ColumnGrip extends StatelessWidget {
  final ResponsibilityItem item;
  final double width;

  const _ColumnGrip({required this.item, required this.width});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grip = Tooltip(
      message: 'Drag to move this column',
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Icon(
          Icons.drag_indicator,
          size: gridMetric(context, 14),
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );

    return Draggable<String>(
      key: ValueKey('matrix_grip_${item.id}'),
      data: item.id,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        elevation: 4,
        child: Container(
          width: width,
          padding: const EdgeInsets.all(8),
          color: theme.colorScheme.surfaceContainerHigh,
          child: Text(
            item.scope,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: grip),
      child: grip,
    );
  }
}

/// One party's name on the grid, in that party's colour.
///
/// A cell nobody has been named in reads NOBODY in the error colour rather
/// than as a dash: a blank on this sheet is the exact thing it exists to
/// catch, and the tinted chips around it would otherwise make an empty cell
/// look like one more quiet agreement.
class _PartyCell extends StatelessWidget {
  final String party;
  final bool missing;

  /// What an unnamed party reads as. The grid's columns are a hundred pixels
  /// wide and take the short form; the list underneath has room for the one
  /// that says it is not finished yet.
  final String missingLabel;

  const _PartyCell({
    required this.party,
    required this.missing,
    this.missingLabel = 'NOBODY',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (missing) {
      return Text(
        missingLabel,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.error,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    // The colour the JOB gave this party, where somebody gave it one. Read off
    // the project here rather than passed down, because every cell on a sheet
    // of thirty lines has to change the moment the colour does, and threading
    // one map through four call sites is four chances for one of them to go on
    // showing yesterday's colour.
    final assigned = context.watch<AppStateProvider>().project.partyColor(
      party,
    );
    return Align(
      alignment: Alignment.centerLeft,
      child: NameTintChip(
        name: party,
        color: assigned == null ? null : Color(assigned),
      ),
    );
  }
}

/// How many of one thing in one room.
///
/// Its own widget so the controller is owned by a State. A controller made in
/// the caller and disposed when the dialog's future completes is torn out from
/// under a field the exit animation is still building — see the same note on
/// [_ResponsibilityEditorDialog].
class _QtyDialog extends StatefulWidget {
  final String title;
  final double initial;

  const _QtyDialog({required this.title, required this.initial});

  @override
  State<_QtyDialog> createState() => _QtyDialogState();
}

class _QtyDialogState extends State<_QtyDialog> {
  late final TextEditingController _qty = TextEditingController(
    text: widget.initial > 0 ? formatResponsibilityQty(widget.initial) : '',
  );

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(
    double.tryParse(_qty.text.trim()) ?? 0,
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('matrix_qty_dialog'),
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('matrix_qty_field'),
      controller: _qty,
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(
        labelText: 'How many',
        helperText: 'Blank or 0 takes this room off the line.',
        border: OutlineInputBorder(),
      ),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('matrix_qty_save'),
        onPressed: _save,
        child: const Text('Set'),
      ),
    ],
  );
}

/// One line of the matrix on the editor.
class _ItemRow extends StatelessWidget {
  final ResponsibilityItem item;
  final List<({String id, String name})> columns;
  final bool first;
  final bool last;

  const _ItemRow({
    required this.item,
    required this.columns,
    required this.first,
    required this.last,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.read<AppStateProvider>();
    final rooms = columns
        .where((c) => (item.qtyByRoom[c.id] ?? 0) > 0)
        .map((c) => '${c.name} ×${formatResponsibilityQty(item.qtyByRoom[c.id]!)}')
        .join('  ·  ');

    return ListTile(
      key: ValueKey('responsibility_row_${item.id}'),
      title: Row(
        children: [
          Expanded(
            child: Text(item.scope, style: theme.textTheme.titleSmall),
          ),
          if (item.total > 0)
            Text(
              '${formatResponsibilityQty(item.total)} total',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The parties as chips, in their colours, so a row on the editor and
          // the same row on the grid above read as the same line.
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Furnished by',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              _PartyCell(
                party: item.furnishedBy,
                missing: item.furnishedBy.trim().isEmpty,
                missingLabel: 'NOBODY YET',
              ),
              Text(
                'installed by',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              _PartyCell(
                party: item.installedBy,
                missing: item.installedBy.trim().isEmpty,
                missingLabel: 'NOBODY YET',
              ),
              if (item.neededBy.isNotEmpty)
                Text(
                  '·  needed by ${item.neededBy}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          if (rooms.isNotEmpty)
            Text(rooms, style: theme.textTheme.bodySmall),
          if (item.work.isNotEmpty)
            Text(
              item.work,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          // WHAT IS STILL OPEN, ON THE ROW. A note that can only be seen by
          // opening the editor is a note nobody reads, and "a size not
          // settled" is exactly the kind of thing that has to be visible while
          // the sheet is being agreed.
          if (item.notes.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.sticky_note_2_outlined,
                    size: 14,
                    color: theme.colorScheme.tertiary,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      item.notes.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.tertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // The product, as a document to open rather than a string to copy.
          if (item.productLink.trim().isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: CutsheetLink(item: item),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Move up the sheet',
            icon: const Icon(Icons.arrow_upward, size: 18),
            onPressed:
                first ? null : () => provider.moveResponsibilityItem(item.id, -1),
          ),
          IconButton(
            tooltip: 'Move down the sheet',
            icon: const Icon(Icons.arrow_downward, size: 18),
            onPressed:
                last ? null : () => provider.moveResponsibilityItem(item.id, 1),
          ),
          IconButton(
            key: ValueKey('responsibility_edit_${item.id}'),
            tooltip: 'Edit this line',
            icon: const Icon(Icons.edit, size: 18),
            onPressed: () =>
                showResponsibilityEditor(context, item.id, columns),
          ),
          IconButton(
            key: ValueKey('responsibility_delete_${item.id}'),
            tooltip: 'Take it off the matrix',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () => provider.removeResponsibilityItem(item.id),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
//  EDITING ONE LINE
// ---------------------------------------------------------------------------

/// The editor for one line: the parties, the quantities per room, and the
/// prose.
///
/// One dialog rather than inline fields on the row because a line has nine
/// fields on it and four of them are prose. A row wide enough to edit them all
/// in place is a row nobody can read the sheet from, and the sheet is what this
/// pane is for.
Future<void> showResponsibilityEditor(
  BuildContext context,
  String itemId,
  List<({String id, String name})> columns,
) async {
  final provider = context.read<AppStateProvider>();
  final item = provider.project.responsibilityById(itemId);
  if (item == null) return;

  await showDialog<void>(
    context: context,
    builder: (_) => _ResponsibilityEditorDialog(item: item, columns: columns),
  );
}

/// The editor's own widget, so its controllers are owned by a State.
///
/// NOT a bag of controllers made in the function above and disposed when the
/// dialog's future completes. That future finishes when the route is popped,
/// and the route keeps BUILDING through its exit animation — so disposing
/// there tears the controllers out from under fields that are still on screen
/// for another two hundred milliseconds. Owned here, they go when the widget
/// goes, which is after the last frame that used them.
class _ResponsibilityEditorDialog extends StatefulWidget {
  final ResponsibilityItem item;
  final List<({String id, String name})> columns;

  const _ResponsibilityEditorDialog({
    required this.item,
    required this.columns,
  });

  @override
  State<_ResponsibilityEditorDialog> createState() =>
      _ResponsibilityEditorDialogState();
}

class _ResponsibilityEditorDialogState
    extends State<_ResponsibilityEditorDialog> {
  late final TextEditingController _scope =
      TextEditingController(text: widget.item.scope);
  late final TextEditingController _furnished =
      TextEditingController(text: widget.item.furnishedBy);
  late final TextEditingController _installed =
      TextEditingController(text: widget.item.installedBy);
  late final TextEditingController _needed =
      TextEditingController(text: widget.item.neededBy);
  late final TextEditingController _work =
      TextEditingController(text: widget.item.work);
  late final TextEditingController _link =
      TextEditingController(text: widget.item.productLink);
  late final TextEditingController _notes =
      TextEditingController(text: widget.item.notes);
  late final Map<String, TextEditingController> _qty = {
    for (final room in widget.columns)
      room.id: TextEditingController(
        text: (widget.item.qtyByRoom[room.id] ?? 0) > 0
            ? formatResponsibilityQty(widget.item.qtyByRoom[room.id]!)
            : '',
      ),
  };

  /// Picks a cutsheet off disk into the product field.
  Future<void> _pickCutsheet() async {
    final provider = context.read<AppStateProvider>();
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Choose the cutsheet for this line',
    );
    final chosen = picked?.files.firstOrNull?.path;
    if (chosen == null) return;
    setState(
      () => _link.text = BuildingProject.storePath(
        path.normalize(chosen),
        provider.currentProjectPath,
      ),
    );
  }

  @override
  void dispose() {
    _scope.dispose();
    _furnished.dispose();
    _installed.dispose();
    _needed.dispose();
    _work.dispose();
    _link.dispose();
    _notes.dispose();
    for (final c in _qty.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Takes this line off the matrix and closes the editor.
  ///
  /// IT ASKS FIRST, and the row's own delete button does not. The difference
  /// is what is in front of somebody at the time: on the sheet the button sits
  /// under a row they can see and re-add in seconds, and in here it sits an
  /// inch from Save, on a line that may be nine fields of prose somebody has
  /// just spent ten minutes writing. One question is the cheapest possible
  /// insurance against the worst possible slip.
  ///
  /// The scope is IN the question. "Delete this line?" in a dialog that opened
  /// over another dialog is a question nobody can answer without cancelling
  /// out of it to look.
  Future<void> _delete() async {
    final provider = context.read<AppStateProvider>();
    final navigator = Navigator.of(context);
    final scope = widget.item.scope.trim().isEmpty
        ? 'this line'
        : widget.item.scope.trim();

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('responsibility_delete_confirm'),
        title: const Text('Take it off the matrix?'),
        content: Text(
          '$scope comes off the sheet, with whose job it is, the quantities '
          'per room and the notes on it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            key: const ValueKey('responsibility_delete_confirm_go'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (go != true) return;

    provider.removeResponsibilityItem(widget.item.id);
    // The editor goes with the line it was editing. Popped through the
    // navigator captured above rather than through a context whose widget has
    // just lost the thing it is showing.
    navigator.pop();
  }

  void _save() {
    final counts = <String, double>{};
    for (final room in widget.columns) {
      final value = double.tryParse(_qty[room.id]!.text.trim()) ?? 0;
      if (value > 0) counts[room.id] = value;
    }
    context.read<AppStateProvider>().updateResponsibilityItem(
      widget.item.copyWith(
        // A scope typed empty keeps the name it had: the row has to stay
        // findable on the sheet, and a blank line is one nobody can delete
        // because they cannot tell which one it is.
        scope: _scope.text.trim().isEmpty
            ? widget.item.scope
            : _scope.text.trim(),
        furnishedBy: _furnished.text.trim(),
        installedBy: _installed.text.trim(),
        neededBy: _needed.text.trim(),
        qtyByRoom: counts,
        work: _work.text.trim(),
        productLink: _link.text.trim(),
        notes: _notes.text.trim(),
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final columns = widget.columns;
    return AlertDialog(
      key: const ValueKey('responsibility_editor'),
      title: const Text('Scope, and whose job it is'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('responsibility_scope'),
                controller: _scope,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Scope',
                  hintText: 'Ceiling speakers',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _PartyField(
                      fieldKey: const ValueKey('responsibility_furnished'),
                      controller: _furnished,
                      label: 'Furnished by',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _PartyField(
                      fieldKey: const ValueKey('responsibility_installed'),
                      controller: _installed,
                      label: 'Installed by',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _needed,
                      decoration: const InputDecoration(
                        labelText: 'Needed by',
                        hintText: 'TBD',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              if (columns.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'HOW MANY, PER ROOM',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final room in columns)
                      SizedBox(
                        width: 130,
                        child: TextField(
                          key: ValueKey('responsibility_qty_${room.id}'),
                          controller: _qty[room.id],
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: room.name,
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('responsibility_work'),
                controller: _work,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'What the work is',
                  helperText: 'The words this gets read in on site.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              // A LINK OR A FILE, in one field. Half the cutsheets on a job
              // are a manufacturer's page somebody pasted and half are a PDF
              // in the job folder; forcing either into the shape of the other
              // is how the field stops being filled in. The button picks the
              // second kind and stores it the way a plan is stored - relative
              // to the project when it lives under it, so a job folder that
              // gets handed over still finds its own documents.
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('responsibility_link'),
                      controller: _link,
                      decoration: const InputDecoration(
                        labelText: 'Product or cutsheet',
                        helperText: 'A web page, or a file on disk that opens '
                            'in the app',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('responsibility_pick_cutsheet'),
                    onPressed: _pickCutsheet,
                    icon: const Icon(Icons.attach_file, size: 18),
                    label: const Text('Choose file…'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Notes and open questions',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        // DELETE IS ON THIS DIALOG BECAUSE THIS IS WHERE THE LINE IS READ. The
        // sheet's own row carries a delete too, but by the time somebody has
        // opened the editor and read the nine fields on it, the row is behind
        // a dialog - and closing the editor to go and find the row again is
        // how a line that should have gone stays on the matrix.
        //
        // Leftmost and in the error ink: it is the one action here that cannot
        // be taken back, and it must not read as a third way of saying Cancel.
        TextButton.icon(
          key: const ValueKey('responsibility_delete_line'),
          onPressed: _delete,
          icon: const Icon(Icons.delete_outline, size: 18),
          label: const Text('Delete line'),
          style: TextButton.styleFrom(
            foregroundColor: errorTextOn(
              Theme.of(context).colorScheme,
              Theme.of(context).dialogTheme.backgroundColor ??
                  Theme.of(context).colorScheme.surfaceContainerHigh,
            ),
          ),
        ),
        TextButton(
          key: const ValueKey('responsibility_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('responsibility_save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// A party field: free text with the usual answers one press away.
///
/// An [Autocomplete] rather than a dropdown because a real matrix names actual
/// parties — "CTS Chico", "CFCI", "Valley/DPR" — and a closed list would force
/// those into a generic word that loses the point of writing it down.
class _PartyField extends StatelessWidget {
  final Key fieldKey;
  final TextEditingController controller;
  final String label;

  const _PartyField({
    required this.fieldKey,
    required this.controller,
    required this.label,
  });

  @override
  Widget build(BuildContext context) => TextField(
    key: fieldKey,
    controller: controller,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      suffixIcon: PopupMenuButton<String>(
        tooltip: 'The usual answers',
        icon: const Icon(Icons.arrow_drop_down),
        itemBuilder: (_) => [
          for (final party in kResponsibilityParties)
            PopupMenuItem(value: party, child: Text(party)),
        ],
        onSelected: (value) => controller.text = value,
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
//  ISSUING IT
// ---------------------------------------------------------------------------

/// The matrix as a one-sheet .xlsx.
Future<void> _exportSpreadsheet(
  BuildContext context,
  BuildingProject project,
  List<({String id, String name})> columns,
) async {
  final provider = context.read<AppStateProvider>();
  final sections = responsibilityMatrixSections(
    project.responsibility,
    roomNames: columns,
    // The colours travel with the document. This copy is the one the
    // contractor prices from, and a party that is blue on the screen it was
    // agreed on and orange in the file that was sent is two parties as far as
    // the reader is concerned.
    partyColors: project.partyColors,
  );
  if (sections.isEmpty) return;

  final stem = project.name.trim().isEmpty
      ? 'project'
      : project.name.trim().replaceAll(RegExp(r'[^\w\-]+'), '_');
  final picked = await FilePicker.saveFile(
    dialogTitle: 'Save the responsibility matrix',
    fileName: '${stem}_responsibility.xlsx',
    type: FileType.custom,
    allowedExtensions: const ['xlsx'],
  );
  if (picked == null) return;
  final target =
      picked.toLowerCase().endsWith('.xlsx') ? picked : '$picked.xlsx';

  try {
    await File(target).writeAsBytes(
      buildXlsx([
        buildStackedReportSheet(
          sheetName: 'Responsibility',
          title: project.name.trim().isEmpty
              ? 'Roles and responsibilities'
              : '${project.name} - roles and responsibilities',
          sections: sections,
        ),
      ]),
    );
    if (context.mounted) {
      showSavedFileSnack(
        context,
        provider,
        'The responsibility matrix',
        target,
      );
    }
  } catch (e) {
    if (context.mounted) {
      showTimedSnackBar(
        ScaffoldMessenger.of(context),
        SnackBar(content: Text('The matrix could not be written: $e')),
      );
    }
  }
}

/// Shows the matrix as it will be PICTURED, and offers to save the picture.
Future<void> showResponsibilityImage(
  BuildContext context,
  BuildingProject project,
  List<({String id, String name})> columns,
) => showDialog<void>(
  context: context,
  builder: (_) =>
      _ResponsibilityImageDialog(project: project, columns: columns),
);

class _ResponsibilityImageDialog extends StatefulWidget {
  final BuildingProject project;
  final List<({String id, String name})> columns;

  const _ResponsibilityImageDialog({
    required this.project,
    required this.columns,
  });

  @override
  State<_ResponsibilityImageDialog> createState() =>
      _ResponsibilityImageDialogState();
}

class _ResponsibilityImageDialogState
    extends State<_ResponsibilityImageDialog> {
  final GlobalKey _boundary = GlobalKey();
  bool _saving = false;

  /// Whether the picture keeps the party colours.
  ///
  /// ON, because the colours are half of how this particular document is read
  /// — whose job the line is, seen down a column rather than looked up cell by
  /// cell — and a picture of it that dropped them would be a worse copy than
  /// the screen it was taken from. The mono treatment every other drawing
  /// leaves this app in is still one press away, for the copy that is going to
  /// be photocopied.
  bool _colour = true;

  /// The matrix as pixels, at the size it will actually be read at.
  ///
  /// Two device pixels per logical one: the picture goes into a submittal and
  /// is read on paper, where a screen-resolution capture of a table of small
  /// type is unreadable. The boundary is the FULL table whatever the preview
  /// happens to be zoomed to, so the file is the document and not the window
  /// over it.
  Future<Uint8List?> _capture() async {
    setState(() => _saving = true);
    try {
      return await captureBoundary(_boundary, pixelRatio: 2.0);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// The matrix straight onto the clipboard, for the mail that is going out
  /// now rather than the file that goes in the folder.
  Future<void> _copy() async {
    final bytes = await _capture();
    if (!mounted) return;
    await copyPictureToClipboard(context, bytes, what: 'The matrix');
  }

  /// The pen and the arrow over the matrix, for the copy that is being sent to
  /// ask a question about one line of it.
  Future<void> _annotate() async {
    final bytes = await _capture();
    if (bytes == null) {
      if (mounted) {
        showTimedSnackBar(
          ScaffoldMessenger.of(context),
          const SnackBar(content: Text('The matrix could not be captured.')),
        );
      }
      return;
    }
    if (!mounted) return;
    final stem = widget.project.name.trim().isEmpty
        ? 'project'
        : widget.project.name.trim().replaceAll(RegExp(r'[^\w\-]+'), '_');
    await showAnnotationEditor(
      context,
      bytes,
      defaultFileName: '${stem}_responsibility.png',
    );
  }

  Future<void> _save() async {
    final provider = context.read<AppStateProvider>();
    final bytes = await _capture();
    if (bytes == null) {
      if (mounted) {
        showTimedSnackBar(
          ScaffoldMessenger.of(context),
          const SnackBar(content: Text('The matrix could not be captured.')),
        );
      }
      return;
    }

    final stem = widget.project.name.trim().isEmpty
        ? 'project'
        : widget.project.name.trim().replaceAll(RegExp(r'[^\w\-]+'), '_');
    final picked = await FilePicker.saveFile(
      dialogTitle: 'Save the responsibility matrix',
      fileName: '${stem}_responsibility.png',
      type: FileType.custom,
      allowedExtensions: const ['png'],
    );
    if (picked == null) return;
    final target =
        picked.toLowerCase().endsWith('.png') ? picked : '$picked.png';
    try {
      await File(target).writeAsBytes(bytes);
      if (mounted) {
        showSavedFileSnack(
          context,
          provider,
          'The responsibility matrix',
          target,
        );
      }
    } catch (e) {
      if (mounted) {
        showTimedSnackBar(
          ScaffoldMessenger.of(context),
          SnackBar(content: Text('The picture could not be written: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final columns = widget.columns;

    return AlertDialog(
      key: const ValueKey('responsibility_image_dialog'),
      title: const Text('The matrix as a picture'),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.7,
        // A matrix is as wide as the project has parties and as long as it has
        // lines, and both of those routinely beat the dialog. Bars down the
        // edges say so, and the zoom is how somebody reads a forty-line table
        // scaled to fit before they commit it to a submittal.
        child: ZoomablePicturePreview(
          keyPrefix: 'responsibility_image',
          backdrop: Theme.of(context).brightness == Brightness.dark
              ? Colors.black45
              : Colors.grey[350],
          child: RepaintBoundary(
            key: _boundary,
            // On white either way. The only question is whether the party
            // colours survive - see [_colour].
            child: printSkin(
              enabled: !_colour,
              child: _MatrixTable(project: project, columns: columns),
            ),
          ),
        ),
      ),
      actions: [
        // A switch rather than two buttons: it changes the preview above, so
        // what is saved is what was looked at.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              key: const ValueKey('responsibility_image_colour'),
              value: _colour,
              onChanged: (v) => setState(() => _colour = v),
            ),
            const SizedBox(width: 4),
            const Text('Party colours'),
          ],
        ),
        const SizedBox(width: 12),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('responsibility_annotate'),
          onPressed: _saving ? null : _annotate,
          icon: const Icon(Icons.draw_outlined, size: 18),
          label: const Text('Annotate'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('responsibility_copy_png'),
          onPressed: _saving ? null : _copy,
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          label: const Text('Copy to clipboard'),
        ),
        FilledButton.icon(
          key: const ValueKey('responsibility_save_png'),
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.download, size: 18),
          label: Text(_saving ? 'Capturing…' : 'Save as PNG'),
        ),
      ],
    );
  }
}

/// The matrix, drawn as the document rather than as an editor.
class _MatrixTable extends StatelessWidget {
  final BuildingProject project;
  final List<({String id, String name})> columns;

  const _MatrixTable({required this.project, required this.columns});

  @override
  Widget build(BuildContext context) {
    final items = project.responsibility;
    const headStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.bold,
      color: Colors.black,
    );
    const cellStyle = TextStyle(fontSize: 11, color: Colors.black);

    Widget cell(String text, {TextStyle style = cellStyle}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Text(text, style: style),
        );

    /// A party's cell: its colour behind its name, on the white the document
    /// is printed on. Greyscaled with the rest of the table when the colours
    /// are switched off, which is why the name is still written in it.
    // The colour this job gave the party, or the one its name derives when
    // nobody has given it one - see [showPartyColorDialog]. The picture is the
    // copy that goes in the submittal, so it has to be the colour that was
    // agreed rather than the colour a name happens to hash to.
    Color partyTint(String party) =>
        resolveTint(assigned: project.partyColor(party), name: party);

    Widget partyCell(String party) {
      final named = party.trim();
      if (named.isEmpty) {
        return cell(
          'NOBODY',
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Color(0xFFB3261E),
          ),
        );
      }
      final tint = partyTint(named);
      return Container(
        color: tintFill(tint, alpha: 0.20),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Text(
          named,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: tintText(tint, Colors.white),
          ),
        ),
      );
    }

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            project.name.trim().isEmpty
                ? 'Roles and responsibilities'
                : '${project.name} - roles and responsibilities',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
          Text(
            'Generated ${reportTimestamp()}',
            style: const TextStyle(fontSize: 10, color: Colors.black54),
          ),
          const SizedBox(height: 8),
          // The key travels with the picture. A submittal reader has not seen
          // the screen these colours were learned on.
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final party in partiesOn(items))
                NameTintChip(
                  name: party,
                  background: Colors.white,
                  // Only what was CHOSEN is passed: a party nobody named a
                  // colour for still has to be able to read as unsettled, and
                  // a resolved colour handed in here would settle it.
                  color: () {
                    final assigned = project.partyColor(party);
                    return assigned == null ? null : Color(assigned);
                  }(),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Table(
            defaultVerticalAlignment: TableCellVerticalAlignment.top,
            // Darker than the hairline it was: this table is photographed
            // for a submittal and photocopied from there, and a 0.6pt grey
            // rule is the first thing a copier loses.
            border: TableBorder.all(color: Colors.black45, width: 0.8),
            columnWidths: {
              0: const FixedColumnWidth(170),
              1: const FixedColumnWidth(95),
              2: const FixedColumnWidth(95),
              3: const FixedColumnWidth(90),
              for (var i = 0; i < columns.length; i++)
                4 + i: const FixedColumnWidth(62),
              4 + columns.length: const FixedColumnWidth(56),
              5 + columns.length: const FixedColumnWidth(260),
              // The cutsheet's NAME, not its path: a printed matrix carrying a
              // full job-folder path is a matrix with a column of noise in it,
              // and the name is what somebody holding the paper searches the
              // folder for.
              6 + columns.length: const FixedColumnWidth(140),
              7 + columns.length: const FixedColumnWidth(200),
            },
            children: [
              TableRow(
                decoration: const BoxDecoration(color: Color(0xFFEDEDED)),
                children: [
                  cell('Scope', style: headStyle),
                  cell('Furnished by', style: headStyle),
                  cell('Installed by', style: headStyle),
                  cell('Needed by', style: headStyle),
                  for (final room in columns) cell(room.name, style: headStyle),
                  cell('Total', style: headStyle),
                  cell('What the work is', style: headStyle),
                  cell('Cutsheet', style: headStyle),
                  cell('Notes', style: headStyle),
                ],
              ),
              for (final item in items)
                TableRow(
                  children: [
                    cell(item.scope),
                    partyCell(item.furnishedBy),
                    partyCell(item.installedBy),
                    cell(item.neededBy),
                    for (final room in columns)
                      cell(
                        formatResponsibilityQty(item.qtyByRoom[room.id] ?? 0),
                      ),
                    cell(formatResponsibilityQty(item.total)),
                    cell(item.work),
                    cell(item.productName),
                    cell(item.notes),
                  ],
                ),
              if (columns.isNotEmpty)
                TableRow(
                  decoration: const BoxDecoration(color: Color(0xFFF6F6F6)),
                  children: [
                    cell('Totals', style: headStyle),
                    cell(''),
                    cell(''),
                    cell(''),
                    for (final room in columns)
                      cell(
                        formatResponsibilityQty(
                          items.fold<double>(
                            0,
                            (sum, i) => sum + (i.qtyByRoom[room.id] ?? 0),
                          ),
                        ),
                        style: headStyle,
                      ),
                    cell(
                      formatResponsibilityQty(
                        items.fold<double>(0, (sum, i) => sum + i.total),
                      ),
                      style: headStyle,
                    ),
                    // Work, cutsheet, notes: nothing to total, but a Table
                    // demands every row be the same width.
                    cell(''),
                    cell(''),
                    cell(''),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}
