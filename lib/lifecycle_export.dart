import 'dart:typed_data';

import 'av_flow_model.dart' show formatEquipmentDate;
import 'campus_lifecycle.dart';
import 'cost_estimate.dart' show money;
import 'equipment_lifecycle.dart';
import 'report_tools.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  THE REPLACEMENT PLAN, AS A DOCUMENT
/// ============================================================================
///  The plan is read on screen and argued about somewhere else. It goes into a
///  budget request, onto a slide, into a mail to a dean - and until now the
///  only way to get it out of the app was to describe it.
///
///  So it leaves in two shapes, and both of them come off the SAME
///  [BuildingLifecycle] / [CampusLifecycle] the screen is drawn from:
///
///    * A PICTURE, which is the sheet exactly as it is read, colours and all.
///    * A SPREADSHEET, which is the sheet as a thing that can be totalled,
///      filtered and re-sorted, with a REAL Excel chart of the money against
///      the years bound to the cells beside it.
///
///  WHY THE CHART IS A CHART AND NOT A PICTURE OF ONE. What gets asked of this
///  document is "what if we push the science block a year" - and the whole
///  value of handing over a spreadsheet rather than a PDF is that somebody can
///  answer that by editing a cell and watching the spike move. A pasted image
///  cannot move, so it gets ignored, and the sheet goes back to being a PDF
///  with extra steps.
///
///  THE YEARS ON THE CHART ARE THE YEARS WITH MONEY IN THEM. A building whose
///  oldest projector went in in 2009 has a GRID that starts in 2009, because
///  the grid is counting service years. A chart of the money does not: fifteen
///  empty bars in front of the first real one make the real ones unreadable.
/// ============================================================================

/// The sheet the tables land on, per document.
const String kLifecyclePlanSheet = 'Replacement Plan';
const String kCampusPlanSheet = 'Campus Plan';

/// The sheet the chart lives on, in both books.
///
/// ITS OWN SHEET, not a chart floating over the tables. The tables are read
/// down and the chart is read across, and a chart anchored beside a stacked
/// report moves every time a section above it grows a row.
const String kLifecycleYearSheet = 'Refresh by Year';

/// One bar's colour, per building on a campus chart. Chosen to stay apart from
/// each other in print and when one of them is behind a projector.
const List<String> kLifecycleSeriesColors = [
  '1F4E79',
  'C55A11',
  '548235',
  '7030A0',
  '2E75B6',
  'BF8F00',
  '9E480E',
  '636363',
  '997300',
  '264478',
];

/// The Excel number format the chart's value axis carries.
String lifecycleNumberFormat(String currency) => '"$currency"#,##0';

/// The years a MONEY chart covers: every year something falls due, always
/// including today so a plan with nothing due still has a column to say so in.
///
/// NOT CAPPED. The years with no money in them are already left off - that is
/// what this function is for - so what is left is the years that carry a
/// figure, and dropping one of those would mean the bars on the chart added up
/// to less than the table beside them. A wide chart is a nuisance; a chart
/// whose total disagrees with the sheet is a document nobody can use.
List<int> lifecycleDueYears(List<EquipmentLife> items, DateTime asOf) {
  var first = asOf.year;
  var last = asOf.year;
  for (final item in items) {
    final due = item.dueYear;
    if (due == null) continue;
    if (due < first) first = due;
    if (due > last) last = due;
  }
  return [for (var y = first; y <= last; y++) y];
}

// ---------------------------------------------------------------------------
//  ONE BUILDING
// ---------------------------------------------------------------------------

/// The money against the years for one building, with the chart over it.
///
/// Three figures per year rather than one: what lands in it, how much of that
/// was already late, and what has been spent by the end of it. The second is
/// the one a request is argued from - "this is not a wish list, half of it was
/// due before we asked" - and the third is what a phased plan is checked
/// against.
XlsxSheet buildingYearSheet(
  BuildingLifecycle building, {
  String sheetName = kLifecycleYearSheet,
}) {
  final currency = building.currency;
  final years = lifecycleDueYears(building.items, building.asOf);
  final thisYear = building.asOf.year;

  final rows = <List<dynamic>>[
    ['Year', 'Falling due', 'Of that, already late', 'Spent by end of year'],
  ];
  var running = 0.0;
  for (final year in years) {
    final due = building.costDueIn(year);
    running += due;
    rows.add([
      year,
      money(due, currency),
      // A year already gone is a year the money should already have been spent
      // in. That is what "late" means on this sheet.
      money(year < thisYear ? due : 0, currency),
      money(running, currency),
    ]);
  }

  return XlsxSheet(
    name: sheetName,
    rows: rows,
    rowStyles: const {0: XlsxRowStyle.header},
    columnWidths: const {0: 10},
    charts: [
      XlsxChart(
        title: 'Replacement cost falling due, by year',
        categoryColumn: 0,
        firstRow: 1,
        lastRow: rows.length - 1,
        numberFormat: lifecycleNumberFormat(currency),
        valueAxisTitle: 'Replacement cost',
        categoryAxisTitle: 'Year',
        series: [
          XlsxChartSeries(
            name: 'Falling due',
            column: 1,
            colorHex: kLifecycleSeriesColors.first,
          ),
        ],
        // Clear of the table to its left, and starting a row down so the
        // header row stays readable beside it.
        anchorCol: 5,
        anchorRow: 1,
      ),
    ],
  );
}

/// One building's replacement plan as a book: the tables, then the chart.
///
/// [picture] is the sheet as it looks on screen, when the caller managed to
/// capture it. Dropped in under the tables rather than made a sheet of its own
/// - it is an illustration of what is above it, not a second document.
Uint8List buildBuildingLifecycleXlsx({
  required BuildingLifecycle building,
  required String title,
  Uint8List? picture,
  DateTime? generated,
}) {
  final at = generated ?? DateTime.now();
  return buildXlsx([
    buildStackedReportSheet(
      sheetName: kLifecyclePlanSheet,
      title: title,
      // EVERY year, not a window on them. This book is read on its own, and
      // a year grid that stopped at the twentieth column would be a plan
      // missing whatever falls due in the twenty-first.
      sections: buildingLifecycleSections(building, maxColumns: null),
      generated: at,
      imageBuilder: picture == null
          ? null
          : (anchorRow) => scaledSheetImage(picture, anchorRow),
    ),
    buildingYearSheet(building),
  ]);
}

// ---------------------------------------------------------------------------
//  THE CAMPUS
// ---------------------------------------------------------------------------

/// The first year anything in [building] falls due, or null when nothing does.
int? firstDueYearOf(BuildingLifecycle building) {
  int? first;
  for (final room in building.rooms) {
    final year = room.firstDueYear;
    if (year != null && (first == null || year < first)) first = year;
  }
  return first;
}

/// The campus as tables: what it needs, which building, which year.
///
/// The same questions the building sheet answers, asked one level up - and in
/// the order the meeting asks them: what is the total, who is it made of, and
/// when does it land.
List<ReportSection> campusLifecycleSections(CampusLifecycle campus) {
  if (campus.jobs.isEmpty) return const [];
  final currency = campus.currency;
  // The GRID is the timeline and carries every year the estate touches; the
  // chart below is about the money and carries only the years that have any.
  final years = campus.allYears;

  return [
    (
      title: 'The Campus As It Stands',
      header: const ['Item', 'Value'],
      rows: [
        ['As of', formatEquipmentDate(campus.asOf)],
        ['Buildings', campus.ok.length],
        ['Rooms', campus.rooms],
        ['Items tracked', campus.items.length],
        [
          'Recommended now',
          formatEquipmentBand(
            campus.toReplaceCount,
            campus.toReplaceCost,
            currency,
          ),
        ],
        [
          'Past its life today',
          formatLifecycleMoney(campus.overdueCost, currency),
        ],
        ['Worst single year', formatLifecycleMoney(campus.peakYear, currency)],
        [
          'Everything, whatever its age',
          formatEquipmentBand(
            campus.items.length,
            campus.refreshCost,
            currency,
          ),
        ],
        // SAID ON THE DOCUMENT, not just on the screen. A campus plan built on
        // an estate that is half surveyed reads far better than the estate is,
        // and the figure that says so has to travel with the totals.
        if (campus.undated > 0)
          [
            'Not yet surveyed',
            '${campus.undated} item${campus.undated == 1 ? '' : 's'} carry no '
                'install date, so they fall due in no year here and are in '
                'none of the figures above',
          ],
        if (campus.failed.isNotEmpty)
          [
            'Could not be read',
            '${campus.failed.length} job'
                '${campus.failed.length == 1 ? '' : 's'} - see the last table. '
                'These are in none of the figures above.',
          ],
      ],
    ),
    (
      title: 'Buildings',
      header: const [
        'Building',
        'Rooms',
        'First due',
        'Past its life',
        'Recommended now',
        'Full refresh',
        'Undated items',
        'File',
      ],
      rows: [
        for (final job in campus.ok)
          [
            job.name,
            job.rooms,
            firstDueYearOf(job.lifecycle!) ?? '',
            formatLifecycleMoney(job.lifecycle!.overdueCost, currency),
            formatEquipmentBand(
              job.lifecycle!.toReplaceCount,
              job.lifecycle!.toReplaceCost,
              currency,
            ),
            formatLifecycleMoney(job.lifecycle!.refreshCost, currency),
            job.lifecycle!.countOf(EquipmentCondition.unknown) == 0
                ? ''
                : job.lifecycle!.countOf(EquipmentCondition.unknown),
            job.path,
          ],
      ],
    ),
    (
      title: 'Replacement Year Grid',
      header: ['Building', for (final y in years) '$y'],
      rows: [
        for (final job in campus.ok)
          [
            job.name,
            for (final y in years)
              campus.costIn(job, y) > 0
                  ? formatLifecycleMoney(campus.costIn(job, y), currency)
                  : '',
          ],
        [
          'Whole campus',
          for (final y in years)
            campus.totalIn(y) > 0
                ? formatLifecycleMoney(campus.totalIn(y), currency)
                : '',
        ],
      ],
    ),
    // A JOB THAT COULD NOT BE READ IS STILL A ROW. The whole value of this
    // sheet is that the total is complete; a campus of eleven that quietly
    // totals ten is worse than no total at all.
    if (campus.failed.isNotEmpty)
      (
        title: 'Could Not Be Read',
        header: const ['Building', 'File', 'Why'],
        rows: [
          for (final job in campus.failed) [job.name, job.path, job.error],
        ],
      ),
  ];
}

/// The campus money against the years, with the stacked chart over it.
///
/// A COLUMN PER BUILDING, not just a total. "Which year is the spike" is the
/// first question and "which building is making it" is always the second, and
/// a stacked bar answers both in one picture - which is the whole reason to
/// put several jobs on one calendar in the first place.
XlsxSheet campusYearSheet(
  CampusLifecycle campus, {
  String sheetName = kLifecycleYearSheet,
}) {
  final currency = campus.currency;
  final years = lifecycleDueYears(campus.items, campus.asOf);
  final jobs = campus.ok;

  final rows = <List<dynamic>>[
    ['Year', for (final j in jobs) j.name, 'Whole campus'],
  ];
  for (final year in years) {
    rows.add([
      year,
      for (final j in jobs) money(campus.costIn(j, year), currency),
      money(campus.totalIn(year), currency),
    ]);
  }

  return XlsxSheet(
    name: sheetName,
    rows: rows,
    rowStyles: const {0: XlsxRowStyle.header},
    columnWidths: const {0: 10},
    charts: [
      XlsxChart(
        title: 'Replacement cost falling due, by year and building',
        categoryColumn: 0,
        firstRow: 1,
        lastRow: rows.length - 1,
        stacked: true,
        numberFormat: lifecycleNumberFormat(currency),
        valueAxisTitle: 'Replacement cost',
        categoryAxisTitle: 'Year',
        series: [
          for (var i = 0; i < jobs.length; i++)
            XlsxChartSeries(
              name: jobs[i].name,
              // Column 0 is the year, so a building's column is its index + 1.
              // The campus total is the last column and is deliberately NOT a
              // series: a stack that included its own total would be twice as
              // tall as the money it describes.
              column: i + 1,
              colorHex:
                  kLifecycleSeriesColors[i % kLifecycleSeriesColors.length],
            ),
        ],
        anchorCol: jobs.length + 3,
        anchorRow: 1,
      ),
    ],
  );
}

/// The campus plan as a book: the tables, then the chart.
Uint8List buildCampusLifecycleXlsx({
  required CampusLifecycle campus,
  Uint8List? picture,
  DateTime? generated,
}) {
  final at = generated ?? DateTime.now();
  return buildXlsx([
    buildStackedReportSheet(
      sheetName: kCampusPlanSheet,
      title: 'Campus refresh plan',
      sections: campusLifecycleSections(campus),
      generated: at,
      imageBuilder: picture == null
          ? null
          : (anchorRow) => scaledSheetImage(picture, anchorRow),
    ),
    // Nothing read, nothing to chart - and a chart sheet with a header row and
    // no bars under it is a page somebody has to work out the meaning of.
    if (campus.ok.isNotEmpty) campusYearSheet(campus),
  ]);
}
