import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/campus_lifecycle.dart';

/// SEVERAL BUILDINGS ON ONE CALENDAR.
///
/// The question a refresh budget is set from is not "what does this building
/// need" but "what does the estate need, in which year, and can we afford that
/// year". The failure this guards is a campus total that quietly leaves a
/// building out - because the whole value of the sheet is that the total is
/// complete, and a figure that is short by one building is worse than no figure
/// at all.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_campus'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// A room with one dated projector on it, and the project file that carries
  /// it. Returns the project's path.
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

  test('two buildings land on one calendar, and the totals are the sum', () async {
    // Eight-year life: 2014 falls due in 2022, 2019 in 2027.
    final a = writeJob('bss', 'Bessey Hall', 2014);
    final b = writeJob('phy', 'Physical Sciences', 2019);

    final campus = await readCampus(
      provider: host(),
      projectPaths: [a, b],
      asOf: DateTime(2025, 6, 1),
    );

    expect(campus.ok, hasLength(2));
    expect(campus.failed, isEmpty);
    expect([for (final j in campus.ok) j.name],
        ['Bessey Hall', 'Physical Sciences']);

    // Each building's money lands in ITS year, and the campus line is the sum.
    expect(campus.totalIn(2022), 10000);
    expect(campus.totalIn(2027), 10000);
    expect(campus.totalIn(2024), 0);
    // Nothing is double-counted: two projectors, twenty thousand, whatever
    // year they fall in.
    expect(campus.refreshCost, 20000);
    expect(campus.items, hasLength(2));
    expect(campus.rooms, 2);

    // The calendar covers the oldest install to the last due date.
    expect(campus.years.first, 2014);
    expect(campus.years.last, 2027);

    // The worst single year is what a phased plan exists to flatten.
    expect(campus.peakYear, 10000);
  });

  test('the whole campus falling due at once shows as one spike', () async {
    // THE CASE THE SHEET EXISTS FOR: three buildings done in the same summer
    // come due in the same summer, and no single building's own page can say
    // so.
    final paths = [
      writeJob('bss', 'Bessey Hall', 2014),
      writeJob('phy', 'Physical Sciences', 2014),
      writeJob('art', 'Arts', 2014),
    ];

    final campus = await readCampus(
      provider: host(),
      projectPaths: paths,
      asOf: DateTime(2025, 6, 1),
    );

    expect(campus.totalIn(2022), 30000);
    expect(campus.peakYear, 30000);
    // All of it is already late in 2025, so it is all being recommended now.
    expect(campus.toReplaceCount, 3);
    expect(campus.toReplaceCost, 30000);
    expect(campus.overdueCost, 30000);
  });

  test('a job that cannot be read is a row, not a silent gap', () async {
    final good = writeJob('bss', 'Bessey Hall', 2014);
    final missing = '${dir.path}/gone_project.json';

    final campus = await readCampus(
      provider: host(),
      projectPaths: [good, missing],
      asOf: DateTime(2025, 6, 1),
    );

    expect(campus.ok, hasLength(1));
    expect(campus.failed, hasLength(1));
    expect(campus.failed.single.name, 'gone_project');
    expect(campus.failed.single.error, isNotEmpty);
    // The total is the buildings that read, and the sheet says which one did
    // not - a total short by one building with nothing saying so is the one
    // failure this view cannot survive.
    expect(campus.refreshCost, 10000);
  });

  test('a folder is scanned for the jobs in it', () {
    writeJob('bss', 'Bessey Hall', 2014);
    writeJob('phy', 'Physical Sciences', 2019);
    // A room config beside them is not a project and must not be picked up.
    File('${dir.path}/stray_config.json').writeAsStringSync('{}');

    final found = projectFilesUnder(dir.path);
    expect(found, hasLength(2));
    expect(
      found.every((f) => f.endsWith('_project.json')),
      isTrue,
      reason: 'only projects, and a room config is not one',
    );
  });
}
