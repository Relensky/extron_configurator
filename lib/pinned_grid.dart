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
  /// it. Defaults to about half the window, which leaves the sheet as the
  /// biggest thing on the tab without letting it become the only thing.
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
            math.max(240.0, MediaQuery.sizeOf(context).height * 0.5);
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
