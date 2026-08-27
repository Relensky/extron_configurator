import 'dart:math' as math;

import 'package:flutter/material.dart';

/// ============================================================================
///  A WIDE SHEET THAT STAYS READABLE
/// ============================================================================
///  Two documents in this app are spreadsheets: the building's replacement
///  plan (rooms down, years across) and the responsibility matrix (rooms down,
///  scope items across). Both are wider and taller than the window they are
///  read in, and both were previously laid out at their full size inside the
///  tab's one scroll view — which meant a twenty-year plan for forty rooms
///  pushed everything under it off the bottom, and reading across it took the
///  room names off the left edge with it.
///
///  So they scroll HERE, in their own frame, with the two things that say what
///  a cell means pinned: the first column and the header row. The cells move
///  under them, the frozen halves are dragged along in step, and both bars are
///  on screen whenever there is something off the edge — a sheet that scrolls
///  with no visible bar is a sheet most people read the visible third of.
///
///  EVERY SIZE ON IT IS THE READER'S SIZE. The heights and widths are passed
///  in already scaled through [gridMetric], so a machine at 150% gets a grid
///  with 150% cells rather than the same 22-pixel row with clipped text in it.
/// ============================================================================

/// One fixed dimension, grown the way the text inside it is grown.
///
/// Cells are laid out at a fixed height and width so the frozen half and the
/// scrolling half line up to the pixel, which means a reader on a scaled
/// display gets larger type inside a box that never moved. This is the box
/// moving with it. Clamped: past double size the sheet stops being a sheet.
double gridMetric(BuildContext context, double base) => MediaQuery.textScalerOf(
  context,
).clamp(minScaleFactor: 1, maxScaleFactor: 2).scale(base);

/// The sizes a sheet can be read at, as multiples of its natural one.
///
/// STEPS RATHER THAN A SLIDER. There is one right answer at a time - the plan
/// fits or it does not - and a step gets there in one press without anybody
/// having to aim at a rail with a mouse.
const List<double> kGridZoomSteps = <double>[0.5, 0.75, 1, 1.25, 1.5, 2];

/// The natural size, and what a grid opens at.
const double kGridZoomNormal = 1;

/// The step above [zoom], or [zoom] itself at the top of the range.
double gridZoomIn(double zoom) => kGridZoomSteps.firstWhere(
  (s) => s > zoom + 0.001,
  orElse: () => zoom,
);

/// The step below [zoom], or [zoom] itself at the bottom of the range.
double gridZoomOut(double zoom) => kGridZoomSteps.lastWhere(
  (s) => s < zoom - 0.001,
  orElse: () => zoom,
);

/// How many years of a plan a grid shows at [zoom], given the [natural] window.
///
/// ZOOMING OUT WIDENS THE WINDOW; zooming in never narrows it. Out is the
/// half of this somebody reaches for to see the shape of a plan, and shrinking
/// the cells without letting more years into the frame would just leave a
/// third of the sheet empty. In is for reading a figure, and a grid that threw
/// away the far years to give the near ones more room would be hiding data
/// somebody could otherwise have scrolled to.
int gridYearWindow(int natural, double zoom) =>
    zoom >= 1 ? natural : (natural / zoom).round();

/// [theme]'s type at [zoom].
///
/// The figures have to move with the boxes. A cell taken down to half size
/// with the same 12pt figure in it is a cell with an ellipsis where the money
/// was, and one grown to double with the same figure is a large empty box -
/// either way the zoom would have changed the sheet without changing what can
/// be read off it.
TextTheme zoomedTextTheme(ThemeData theme, double zoom) => zoom == kGridZoomNormal
    ? theme.textTheme
    : theme.textTheme.apply(fontSizeFactor: zoom);

/// The zoom that puts a sheet [natural] wide inside a frame [available] wide.
///
/// Clamped to the ends of [kGridZoomSteps] rather than to 100%: a sheet with
/// four years on it is as wrong at 40% of the window as a thirty-year one is
/// running off the edge, so fitting grows as well as shrinks. A frame with no
/// width yet - the first layout pass of a hidden pane - fits to nothing and
/// leaves the sheet where it was.
double gridFitZoom({required double natural, required double available}) {
  if (natural <= 0 || !available.isFinite || available <= 0) {
    return kGridZoomNormal;
  }
  final fit = available / natural;
  if (fit < kGridZoomSteps.first) return kGridZoomSteps.first;
  if (fit > kGridZoomSteps.last) return kGridZoomSteps.last;
  return fit;
}

/// Zoom out, the level, and zoom in — the control a wide sheet carries.
///
/// The level is a button as well as a readout: once somebody has pushed a
/// sheet down to half size to see the shape of it, the way back to the size
/// the figures are legible at should not be three presses of the other arrow.
class GridZoomControls extends StatelessWidget {
  final double zoom;
  final ValueChanged<double> onChanged;

  /// Names the buttons apart from the other grid's - both live on the campus
  /// screen at once.
  final String keyPrefix;

  /// Whether the sheet is currently being held at whatever size fits the
  /// window, and the way to ask for that. Null leaves the button off.
  final bool fitted;
  final VoidCallback? onFit;

  const GridZoomControls({
    super.key,
    required this.zoom,
    required this.onChanged,
    required this.keyPrefix,
    this.fitted = false,
    this.onFit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final out = gridZoomOut(zoom);
    final into = gridZoomIn(zoom);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: ValueKey('${keyPrefix}_zoom_out'),
          onPressed: out == zoom ? null : () => onChanged(out),
          icon: const Icon(Icons.zoom_out),
          iconSize: 20,
          visualDensity: VisualDensity.compact,
          tooltip: 'Smaller cells, and more years in the frame',
        ),
        SizedBox(
          // A fixed box, so the arrows do not shuffle sideways as the figure
          // goes from 50% to 100% and back.
          width: 46,
          child: TextButton(
            key: ValueKey('${keyPrefix}_zoom_level'),
            onPressed: zoom == kGridZoomNormal && !fitted
                ? null
                : () => onChanged(kGridZoomNormal),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              '${(zoom * 100).round()}%',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        IconButton(
          key: ValueKey('${keyPrefix}_zoom_in'),
          onPressed: into == zoom ? null : () => onChanged(into),
          icon: const Icon(Icons.zoom_in),
          iconSize: 20,
          visualDensity: VisualDensity.compact,
          tooltip: 'Bigger cells',
        ),
        // THE ONE PRESS THAT ANSWERS "how much of this is there". The steps
        // are for reading; this is for seeing the shape of the whole thing,
        // and on a sheet of an unknown width it is the only one of the three
        // that does not have to be pressed twice to find out.
        if (onFit != null)
          IconButton(
            key: ValueKey('${keyPrefix}_zoom_fit'),
            onPressed: onFit,
            isSelected: fitted,
            icon: const Icon(Icons.fit_screen_outlined),
            selectedIcon: const Icon(Icons.fit_screen),
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            tooltip: fitted
                ? 'Fitted to the window - press to leave it at this size'
                : 'Fit the whole sheet in the window',
          ),
      ],
    );
  }
}

/// A grid whose first column and header row stay put while the cells scroll.
///
/// The caller lays out four rectangles at sizes it already knows — it is the
/// one that knows how wide a year column is — and this puts them in the right
/// frames and keeps the four scroll offsets in step.
class PinnedGrid extends StatefulWidget {
  /// The frozen column's width, and the header row's height. The [corner]
  /// occupies the overlap of the two.
  final double frozenWidth;
  final double headerHeight;

  /// The full size of the scrolling half, at its natural size — what the
  /// cells would take if the window were wide and tall enough for all of it.
  final double bodyWidth;
  final double bodyHeight;

  /// How tall the whole frame may grow before the rows start scrolling inside
  /// it.
  ///
  /// GROWS WITH THE SHEET, up to most of the window. A replacement plan is
  /// read for its shape, and a frame fixed at half the window showed eight
  /// rows of a twenty-four room building however much empty screen was under
  /// it - so the reader scrolled a small window inside a large one to see a
  /// picture that would have fitted. The sheet takes the room it needs and
  /// stops just short of the window, which leaves the page it sits on still
  /// recognisably a page.
  final double? maxHeight;

  /// Top-left: what the frozen column is. Never moves.
  final Widget corner;

  /// The header row, [bodyWidth] wide. Moves sideways only.
  final Widget header;

  /// The frozen column's body, [frozenWidth] wide. Moves up and down only.
  ///
  /// Null on a grid built row at a time - see [rowCount].
  final Widget? frozen;

  /// The cells, [bodyWidth] by [bodyHeight]. Moves both ways, and is the one
  /// the reader actually drags. Null on a grid built row at a time.
  final Widget? body;

  // ---------------------------------------------------------------------------
  //  THE LAZY HALF
  // ---------------------------------------------------------------------------
  //  A grid laid out as two finished widgets builds every cell it has, whether
  //  or not any of them are on screen. That is fine for a sheet of a dozen
  //  rows and it is not fine for the replacement plan, where a building of
  //  twenty-four rooms with several replacement dates each is two hundred rows
  //  of fourteen cells - three thousand tooltips and containers built to show
  //  the eight rows that fit in the frame.
  //
  //  So a caller that can produce its rows ONE AT A TIME says so, and gets a
  //  pair of builders instead. Every row is the same height, which is what
  //  lets both halves scroll in step with no measuring.

  /// How many rows the body has, or null to pass [frozen] and [body] whole.
  final int? rowCount;

  /// The height of every row. Required with [rowCount].
  final double rowExtent;

  /// One row of the frozen column, [frozenWidth] wide by [rowExtent] tall.
  final IndexedWidgetBuilder? frozenRowBuilder;

  /// One row of the cells, [bodyWidth] wide by [rowExtent] tall.
  final IndexedWidgetBuilder? bodyRowBuilder;

  /// How wide a frozen column has to be to hold [lines] set in [style].
  ///
  /// A NAME THAT IS ELLIPSISED IS NOT A LABEL. The column was a fixed width
  /// chosen for a room number, and the campus sheet puts BUILDING names down
  /// it - 'Farm Agricultural Education Center' in 126 pixels is 'Farm Agri…',
  /// which names nothing. So the column is measured against what actually goes
  /// in it, between a floor (a short list must not give a stripe of a column)
  /// and a ceiling (one absurd name must not eat the sheet).
  ///
  /// Measured at the sheet's NATURAL size and scaled by the caller's zoom, so
  /// it can be fed into the fit calculation that decides that zoom.
  static double frozenWidthFor(
    BuildContext context,
    Iterable<String> lines,
    TextStyle? style, {
    required double min,
    required double max,
    double padding = 20,
  }) {
    final scaler = MediaQuery.textScalerOf(context);
    var widest = 0.0;
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final painter = TextPainter(
        text: TextSpan(text: line, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      if (painter.width > widest) widest = painter.width;
      painter.dispose();
    }
    return (widest + padding).clamp(min, max);
  }

  const PinnedGrid({
    super.key,
    required this.frozenWidth,
    required this.headerHeight,
    required this.bodyWidth,
    required this.bodyHeight,
    required this.corner,
    required this.header,
    this.frozen,
    this.body,
    this.rowCount,
    this.rowExtent = 0,
    this.frozenRowBuilder,
    this.bodyRowBuilder,
    this.maxHeight,
  }) : assert(
         (frozen != null && body != null) ||
             (rowCount != null &&
                 rowExtent > 0 &&
                 frozenRowBuilder != null &&
                 bodyRowBuilder != null),
         'Give PinnedGrid either finished halves or row builders',
       );

  @override
  State<PinnedGrid> createState() => _PinnedGridState();
}

class _PinnedGridState extends State<PinnedGrid> {
  /// The two the reader drives, and the two that follow them. The followers
  /// take [NeverScrollableScrollPhysics] so there is exactly one way to move
  /// the sheet and no way to knock the halves out of line.
  final _cells = ScrollController();
  final _rows = ScrollController();
  final _header = ScrollController();
  final _frozen = ScrollController();

  /// Guards the mirror against its own jump coming back round.
  bool _mirroring = false;

  @override
  void initState() {
    super.initState();
    _cells.addListener(() => _mirror(_cells, _header));
    _rows.addListener(() => _mirror(_rows, _frozen));
  }

  @override
  void dispose() {
    _cells.dispose();
    _rows.dispose();
    _header.dispose();
    _frozen.dispose();
    super.dispose();
  }

  void _mirror(ScrollController from, ScrollController to) {
    if (_mirroring || !from.hasClients || !to.hasClients) return;
    final target = from.offset.clamp(
      to.position.minScrollExtent,
      to.position.maxScrollExtent,
    );
    if ((to.offset - target).abs() < 0.5) return;
    _mirroring = true;
    to.jumpTo(target);
    _mirroring = false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // THE FROZEN COLUMN GIVES WAY BEFORE THE CELLS DO. On a narrow window
        // a 168-pixel room name column against 200 pixels of grid is a sheet
        // with no sheet on it, so the pinned half is capped at a third of what
        // there is and ellipsises instead.
        final frozenWidth = math.min(
          widget.frozenWidth,
          math.max(72.0, box.maxWidth * 0.34),
        );
        final viewWidth = math.max(0.0, box.maxWidth - frozenWidth);

        // Room under the last row and beside the last column for the bars, so
        // a thumb never sits on top of a figure.
        final scrollsX = widget.bodyWidth > viewWidth + 0.5;
        final contentHeight = widget.bodyHeight + (scrollsX ? _kBar : 0);

        final cap =
            widget.maxHeight ??
            math.max(240.0, MediaQuery.sizeOf(context).height * 0.82);
        final viewHeight = math.max(
          0.0,
          math.min(contentHeight, cap - widget.headerHeight),
        );
        final scrollsY = contentHeight > viewHeight + 0.5;
        final bodyWidth = widget.bodyWidth + (scrollsY ? _kBar : 0);

        // A sheet that fits must not eat the wheel: the tab under it is the
        // thing the reader is still trying to scroll.
        final rowPhysics = scrollsY
            ? const ClampingScrollPhysics()
            : const NeverScrollableScrollPhysics();

        final lazy = widget.rowCount != null;

        // THE FROZEN COLUMN'S BODY. Lazily, a list of fixed-height rows with
        // its own scrolling turned off - it is dragged along by the cells.
        final Widget frozenBody = lazy
            ? ListView.builder(
                controller: _frozen,
                physics: const NeverScrollableScrollPhysics(),
                itemExtent: widget.rowExtent,
                itemCount: widget.rowCount,
                padding: EdgeInsets.only(bottom: scrollsX ? _kBar : 0),
                itemBuilder: widget.frozenRowBuilder!,
              )
            : SingleChildScrollView(
                controller: _frozen,
                physics: const NeverScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    widget.frozen!,
                    if (scrollsX) const SizedBox(height: _kBar),
                  ],
                ),
              );

        // THE CELLS. Both bars are hung outside both scroll views, so each one
        // is drawn against the frame the reader sees rather than against the
        // far edge of a sheet that is mostly off screen. Which of the two
        // scroll views is on the outside differs between the shapes, so the
        // notification depths do too.
        final Widget cells = lazy
            ? Scrollbar(
                controller: _rows,
                thumbVisibility: scrollsY,
                notificationPredicate: (n) => n.depth == 1,
                child: Scrollbar(
                  controller: _cells,
                  thumbVisibility: scrollsX,
                  notificationPredicate: (n) => n.depth == 0,
                  child: SingleChildScrollView(
                    controller: _cells,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: bodyWidth,
                      child: ListView.builder(
                        controller: _rows,
                        physics: rowPhysics,
                        itemExtent: widget.rowExtent,
                        itemCount: widget.rowCount,
                        padding: EdgeInsets.only(bottom: scrollsX ? _kBar : 0),
                        itemBuilder: widget.bodyRowBuilder!,
                      ),
                    ),
                  ),
                ),
              )
            : Scrollbar(
                controller: _rows,
                thumbVisibility: scrollsY,
                notificationPredicate: (n) => n.depth == 0,
                child: Scrollbar(
                  controller: _cells,
                  thumbVisibility: scrollsX,
                  notificationPredicate: (n) => n.depth == 1,
                  child: SingleChildScrollView(
                    controller: _rows,
                    physics: rowPhysics,
                    child: SingleChildScrollView(
                      controller: _cells,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: bodyWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            widget.body!,
                            if (scrollsX) const SizedBox(height: _kBar),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );

        return SizedBox(
          height: widget.headerHeight + viewHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: frozenWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: widget.headerHeight, child: widget.corner),
                    SizedBox(height: viewHeight, child: frozenBody),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: widget.headerHeight,
                      child: SingleChildScrollView(
                        controller: _header,
                        scrollDirection: Axis.horizontal,
                        physics: const NeverScrollableScrollPhysics(),
                        child: SizedBox(
                          width: bodyWidth,
                          child: widget.header,
                        ),
                      ),
                    ),
                    SizedBox(height: viewHeight, child: cells),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// How much room a scrollbar wants beside the content it is scrolling.
const double _kBar = 12;
