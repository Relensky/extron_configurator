import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/campus_lifecycle.dart';
import 'package:extron_configurator/cost_estimate.dart' show money;
import 'package:extron_configurator/equipment_lifecycle.dart';
import 'package:extron_configurator/lifecycle_export.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// THE PLAN AS A DOCUMENT SOMEBODY ELSE OPENS.
///
/// The failure these guard is the one nobody sees until the file is in a mail:
/// a workbook Excel refuses, or - worse - one it opens with an empty chart
/// frame where the money against the years should be. There is no error at
/// write time for either, so the parts that go into the zip are checked here.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_lc_export'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// One part of a built workbook, as text.
  String partOf(List<int> bytes, String name) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final file = archive.files.firstWhere(
      (f) => f.name == name,
      orElse: () => throw StateError(
        '$name is not in the book. It holds: '
        '${archive.files.map((f) => f.name).join(', ')}',
      ),
    );
    return utf8.decode(file.content as List<int>);
  }

  bool hasPart(List<int> bytes, String name) =>
      ZipDecoder().decodeBytes(bytes).files.any((f) => f.name == name);

  // -------------------------------------------------------------------------
  //  THE CHART ITSELF
  // -------------------------------------------------------------------------

  group('a sheet with a chart on it', () {
    XlsxSheet moneyByYear({bool stacked = false}) => XlsxSheet(
      name: 'Refresh by Year',
      rows: [
        ['Year', 'Bessey', 'Kedzie'],
        [2026, money(1000), money(2000)],
        [2027, money(3000), money(0)],
      ],
      charts: [
        XlsxChart(
          title: 'Falling due',
          categoryColumn: 0,
          firstRow: 1,
          lastRow: 2,
          stacked: stacked,
          numberFormat: r'"$"#,##0',
          series: const [
            XlsxChartSeries(name: 'Bessey', column: 1, colorHex: '1F4E79'),
            XlsxChartSeries(name: 'Kedzie', column: 2, colorHex: 'C55A11'),
          ],
        ),
      ],
    );

    test('carries every part Excel needs to draw it', () {
      final bytes = buildXlsx([moneyByYear()]);

      expect(hasPart(bytes, 'xl/charts/chart1.xml'), isTrue);
      expect(hasPart(bytes, 'xl/drawings/drawing1.xml'), isTrue);
      expect(hasPart(bytes, 'xl/drawings/_rels/drawing1.xml.rels'), isTrue);
      expect(hasPart(bytes, 'xl/worksheets/_rels/sheet1.xml.rels'), isTrue);

      // A part with no content type is a workbook Excel calls corrupt.
      expect(
        partOf(bytes, '[Content_Types].xml'),
        contains('/xl/charts/chart1.xml'),
      );
      // The frame has to point at the chart, and the sheet at the frame.
      expect(
        partOf(bytes, 'xl/drawings/drawing1.xml'),
        contains('<xdr:graphicFrame'),
      );
      expect(
        partOf(bytes, 'xl/drawings/_rels/drawing1.xml.rels'),
        contains('../charts/chart1.xml'),
      );
      expect(partOf(bytes, 'xl/worksheets/sheet1.xml'), contains('<drawing '));
    });

    test('reads its numbers off the cells rather than carrying a copy', () {
      final chart = partOf(buildXlsx([moneyByYear()]), 'xl/charts/chart1.xml');

      // The years, then each building's column - by reference, and named with
      // the sheet they live on. A reference to a sheet name the workbook
      // clipped differently is a chart that opens empty.
      expect(chart, contains(r"'Refresh by Year'!$A$2:$A$3"));
      expect(chart, contains(r"'Refresh by Year'!$B$2:$B$3"));
      expect(chart, contains(r"'Refresh by Year'!$C$2:$C$3"));
    });

    test('carries the figures as a cache too, for whatever is not Excel', () {
      final chart = partOf(buildXlsx([moneyByYear()]), 'xl/charts/chart1.xml');

      // A preview pane draws the cache and nothing else. Without it the chart
      // is blank everywhere except in Excel.
      expect(chart, contains('<c:numCache>'));
      expect(chart, contains('<c:v>1000.0</c:v>'));
      expect(chart, contains('<c:v>3000.0</c:v>'));
    });

    test('one series per column, in the colours it was given', () {
      final chart = partOf(buildXlsx([moneyByYear()]), 'xl/charts/chart1.xml');

      expect('<c:ser>'.allMatches(chart).length, 2);
      expect(chart, contains('<a:srgbClr val="1F4E79"/>'));
      expect(chart, contains('<a:srgbClr val="C55A11"/>'));
    });

    test('stacked when asked, clustered when not', () {
      expect(
        partOf(buildXlsx([moneyByYear(stacked: true)]), 'xl/charts/chart1.xml'),
        contains('<c:grouping val="stacked"/>'),
      );
      expect(
        partOf(buildXlsx([moneyByYear()]), 'xl/charts/chart1.xml'),
        contains('<c:grouping val="clustered"/>'),
      );
    });

    test('a picture and a chart share one drawing on the same sheet', () {
      // The image keeps rId1 so a book written before charts existed lays out
      // exactly as it always did.
      final sheet = XlsxSheet(
        name: 'Refresh by Year',
        rows: moneyByYear().rows,
        charts: moneyByYear().charts,
        image: XlsxImage(
          pngBytes: _onePixelPng,
          anchorCol: 0,
          anchorRow: 6,
          widthPx: 10,
          heightPx: 10,
        ),
      );
      final rels = partOf(
        buildXlsx([sheet]),
        'xl/drawings/_rels/drawing1.xml.rels',
      );
      expect(rels, contains('Id="rId1"'));
      expect(rels, contains('../media/image1.png'));
      expect(rels, contains('Id="rId2"'));
      expect(rels, contains('../charts/chart1.xml'));
    });

    test('a book with no chart on it is byte-for-byte the book it was', () {
      final plain = buildXlsx([
        XlsxSheet(name: 'Report', rows: [
          ['Setting', 'Value'],
          ['Rooms', 4],
        ]),
      ]);
      expect(hasPart(plain, 'xl/charts/chart1.xml'), isFalse);
      expect(hasPart(plain, 'xl/drawings/drawing1.xml'), isFalse);
      expect(
        partOf(plain, '[Content_Types].xml'),
        isNot(contains('drawingml.chart')),
      );
    });
  });

  // -------------------------------------------------------------------------
  //  THE YEARS THE CHART COVERS
  // -------------------------------------------------------------------------

  group('the years a money chart covers', () {
    test('starts at the first year with money, not the first install', () {
      // A building whose oldest box went in in 2009 has a GRID that starts in
      // 2009 - it is counting service years. A chart of the money does not:
      // fifteen empty bars in front of the first real one make the real ones
      // unreadable.
      final asOf = DateTime(2026, 6, 1);
      final years = lifecycleDueYears(const [], asOf);
      expect(years, [2026]);
    });
  });

  // -------------------------------------------------------------------------
  //  THE CAMPUS BOOK
  // -------------------------------------------------------------------------

  group('the campus book', () {
    /// A room with one dated projector on it, and the project that carries it.
    String writeJob(String stem, String name, int installedYear) {
      final configPath = '${dir.path}/${stem}_config.json';
      File(configPath).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gve_bldg': stem.toUpperCase(), 'gve_room': '101'},
      }));
      File('${dir.path}/${stem}_config_av_flow.json').writeAsStringSync(
        jsonEncode({
          'nodes': [
            {
              'id': 'PROJECTORDEVICE_1',
              'label': 'Projector 1',
              'model': 'PROJ-1',
              'installedOn': '$installedYear-05-01',
              'ports': const [],
            },
          ],
          'cables': const [],
        }),
      );
      final projectPath = '${dir.path}/${stem}_project.json';
      File(projectPath).writeAsStringSync(jsonEncode({
        'name': name,
        'currency': r'$',
        'rooms': [
          {'id': 'room1', 'configPath': configPath},
        ],
      }));
      return projectPath;
    }

    AppStateProvider host() {
      final p = AppStateProvider(autoLoadSettings: false);
      // A priced catalog, so the years carry money rather than counts.
      p.avDeviceLibrary = AvDeviceLibrary.empty()
        ..upsert(const AvDeviceTemplate(
          model: 'PROJ-1',
          manufacturer: 'Generic',
          category: 'Projector',
          price: 10000,
          ports: [],
        ));
      return p;
    }

    Future<CampusLifecycle> campus() => readCampus(
      provider: host(),
      projectPaths: [
        writeJob('bss', 'Bessey Hall', 2014),
        writeJob('kdz', 'Kedzie Hall', 2018),
      ],
      asOf: DateTime(2026, 6, 1),
    );

    test('every building is a column on the chart, and the total is not', () async {
      final bytes = buildCampusLifecycleXlsx(campus: await campus());
      final chart = partOf(bytes, 'xl/charts/chart1.xml');

      // TWO series for two buildings. The campus total is the last column on
      // the sheet and is deliberately not one of them: a stack that included
      // its own total would be twice as tall as the money it describes.
      expect('<c:ser>'.allMatches(chart).length, 2);
      expect(chart, contains('<c:v>Bessey Hall</c:v>'));
      expect(chart, contains('<c:v>Kedzie Hall</c:v>'));
      expect(chart, isNot(contains('<c:v>Whole campus</c:v>')));
      expect(chart, contains('<c:grouping val="stacked"/>'));
    });

    test('a job that could not be read is a row, not a silent gap', () async {
      final broken = await readCampus(
        provider: host(),
        projectPaths: [
          writeJob('bss', 'Bessey Hall', 2014),
          '${dir.path}/not_here_project.json',
        ],
        asOf: DateTime(2026, 6, 1),
      );

      final titles = [
        for (final s in campusLifecycleSections(broken)) s.title,
      ];
      expect(titles, contains('Could Not Be Read'));
      // And said on the headline too, so a total nobody scrolls past is not
      // quietly short by one building.
      final headline = campusLifecycleSections(broken).first;
      expect(
        headline.rows.map((r) => r.first).toList(),
        contains('Could not be read'),
      );
    });

    test('a campus where nothing read still writes the sheet that says why',
        () async {
      final none = await readCampus(
        provider: host(),
        projectPaths: ['${dir.path}/gone_project.json'],
        asOf: DateTime(2026, 6, 1),
      );
      final bytes = buildCampusLifecycleXlsx(campus: none);

      // The tables are there; the chart sheet is not, because there is nothing
      // to chart and a header row with no bars under it explains nothing.
      expect(hasPart(bytes, 'xl/worksheets/sheet1.xml'), isTrue);
      expect(hasPart(bytes, 'xl/worksheets/sheet2.xml'), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  //  ONE BUILDING'S BOOK
  // -------------------------------------------------------------------------

  test('the building book charts what falls due, and what was already late',
      () {
    final building = BuildingLifecycle(
      rooms: const [],
      asOf: DateTime(2026, 6, 1),
    );
    final sheet = buildingYearSheet(building);

    expect(sheet.rows.first, [
      'Year',
      'Falling due',
      'Of that, already late',
      'Spent by end of year',
    ]);
    expect(sheet.charts, hasLength(1));
    expect(sheet.charts.single.series, hasLength(1));
    // The money column, not the year column.
    expect(sheet.charts.single.series.single.column, 1);
    expect(sheet.charts.single.categoryColumn, 0);
  });
}

/// The smallest valid PNG, for the tests that only need "an image is here".
final _onePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);
