import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/labor_rates.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/project_workbook.dart';

/// The two documents a project produces: the workbook that holds everything,
/// and the per-vendor quote request that holds exactly one vendor's parts and
/// nothing else.
///
/// The second one is the one with teeth. It gets emailed to a supplier, so a
/// figure that leaks into it — another vendor's pricing, the stakeholder's labor
/// rate, the project total — is a real disclosure rather than an untidy sheet.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_project_wb'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  // -------------------------------------------------------------------------
  //  FIXTURES
  // -------------------------------------------------------------------------

  AvNode device(String id, String label, String model) => AvNode(
    id: id,
    label: label,
    model: model,
    pos: Offset.zero,
    ports: const [],
  );

  String writeRoom(
    String stem, {
    required String name,
    required List<AvNode> nodes,
    List<LaborLine> labor = const [],
  }) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [for (final n in nodes) n.toJson()],
    }));
    File(path.join(dir.path, '${stem}_config_cost.json'))
        .writeAsStringSync(jsonEncode({
      'cost': RoomCostSettings(labor: List<LaborLine>.from(labor)).toJson(),
    }));
    return configPath;
  }

  AvDeviceLibrary catalog() {
    final library = AvDeviceLibrary.empty();
    library.upsert(const AvDeviceTemplate(
      model: 'DTP2 T 211',
      manufacturer: 'Extron',
      partNumber: '60-1439-13',
      category: 'Transmitter',
      price: 500,
      ports: [],
    ));
    library.upsert(const AvDeviceTemplate(
      model: 'RoboSHOT 12E',
      manufacturer: 'Vaddio',
      partNumber: '999-9950-000',
      category: 'Camera',
      price: 2000,
      ports: [],
    ));
    return library;
  }

  /// A two-room job with both vendors set up and every part tagged.
  ProjectEstimate job({List<LaborLine> labor = const []}) {
    final a = writeRoom(
      'a',
      name: 'Bessey 101',
      nodes: [
        device('d1', 'Lectern TX', 'DTP2 T 211'),
        device('d2', 'Room camera', 'RoboSHOT 12E'),
      ],
      labor: labor,
    );
    final b = writeRoom('b', name: 'Bessey 103', nodes: [
      device('d1', 'Lectern TX', 'DTP2 T 211'),
    ]);

    final projectPath = path.join(dir.path, 'bss_project.json');
    final project = BuildingProject(name: 'Bessey refresh', building: 'BSS');
    for (final c in [a, b]) {
      project.rooms.add(ProjectRoomRef(
        id: project.nextRoomId(),
        configPath: BuildingProject.storePath(c, projectPath),
      ));
    }
    project.vendors.addAll(const [
      ProjectVendor(
        id: 'v1',
        name: 'Extron Direct',
        contact: 'orders@extron.example',
        manufacturers: ['Extron'],
      ),
      ProjectVendor(id: 'v2', name: 'AV Reseller', categories: ['Camera']),
    ]);

    return computeProjectEstimate(
      project: project,
      projectPath: projectPath,
      library: catalog(),
    );
  }

  // --- reading the book back -----------------------------------------------

  List<String> tabNames(Archive archive) {
    final workbook = utf8.decode(
      archive.files.firstWhere((f) => f.name == 'xl/workbook.xml').content
          as List<int>,
    );
    return RegExp(r'<sheet name="([^"]+)"')
        .allMatches(workbook)
        .map((m) => m.group(1)!)
        .toList();
  }

  String sheetText(Archive archive, int oneBased) => utf8.decode(
    archive.files
            .firstWhere((f) => f.name == 'xl/worksheets/sheet$oneBased.xml')
            .content
        as List<int>,
  );

  String sheetNamed(Archive archive, String name) =>
      sheetText(archive, tabNames(archive).indexOf(name) + 1);

  String wholeBook(Archive archive) => [
    for (var i = 1; i <= tabNames(archive).length; i++) sheetText(archive, i),
  ].join();

  // -------------------------------------------------------------------------
  //  THE PROJECT WORKBOOK
  // -------------------------------------------------------------------------

  group('the project workbook', () {
    test('has a summary, a master list, a tab per vendor and one per room',
        () {
      final archive = ZipDecoder()
          .decodeBytes(buildProjectWorkbookBytes(estimate: job()));

      expect(tabNames(archive), [
        'Summary',
        'Core Components',
        // When to buy it and what is spared: two questions the parts list
        // cannot answer in a column, read by different people.
        'Order Timeline',
        'Spares',
        'Extron Direct',
        'AV Reseller',
        'Bessey 101',
        'Bessey 103',
      ]);
    });

    test('the summary carries every room and the project total', () {
      final estimate = job();
      final archive = ZipDecoder()
          .decodeBytes(buildProjectWorkbookBytes(estimate: estimate));
      final summary = sheetNamed(archive, 'Summary');

      expect(summary, contains('Bessey 101'));
      expect(summary, contains('Bessey 103'));
      expect(summary, contains('PROJECT TOTAL'));
      // 500 + 2000 + 500
      expect(estimate.grandTotal, 3000);
      expect(summary, contains('3000'));
    });

    test('the master list merges the transmitter and says which rooms', () {
      final archive = ZipDecoder()
          .decodeBytes(buildProjectWorkbookBytes(estimate: job()));
      final master = sheetNamed(archive, 'Core Components');

      expect(master, contains('60-1439-13'));
      // Two rooms, one line, and the breakdown that makes it checkable.
      expect(master, contains('Bessey 101 ×1, Bessey 103 ×1'));
      expect(master, contains('Extron Direct'));
    });

    test('rooms that would clip to the same tab name are numbered', () {
      // Excel refuses a book with two sheets of one name, so a building of
      // long, similar room names must not produce an unopenable file.
      const long = 'Behavioral and Social Science Building room';
      final a = writeRoom('a', name: '$long 101', nodes: [
        device('d1', 'TX', 'DTP2 T 211'),
      ]);
      final b = writeRoom('b', name: '$long 102', nodes: [
        device('d1', 'TX', 'DTP2 T 211'),
      ]);

      final projectPath = path.join(dir.path, 'p_project.json');
      final project = BuildingProject(name: 'Long names');
      for (final c in [a, b]) {
        project.rooms.add(ProjectRoomRef(
          id: project.nextRoomId(),
          configPath: BuildingProject.storePath(c, projectPath),
        ));
      }

      final archive = ZipDecoder().decodeBytes(buildProjectWorkbookBytes(
        estimate: computeProjectEstimate(
          project: project,
          projectPath: projectPath,
          library: catalog(),
        ),
      ));

      final names = tabNames(archive);
      expect(names.toSet(), hasLength(names.length), reason: 'no duplicates');
      expect(names.every((n) => n.length <= 31), isTrue);
      expect(names.last, endsWith(' (2)'));
    });

    test('the drawing set the job was quoted against is on the summary', () {
      // "Which set was this priced from" is asked every time a plan is
      // reissued and a number stops matching.
      final estimate = job();
      final drawing = path.join(dir.path, 'A-101.pdf');
      File(drawing).writeAsStringSync('%PDF-1.4');
      estimate.project.plans.add(ProjectPlan(
        id: estimate.project.nextPlanId(),
        filePath: BuildingProject.storePath(drawing, estimate.projectPath),
        label: 'Level 1 floor plan',
        notes: 'issued 3 Feb',
      ));

      final archive = ZipDecoder()
          .decodeBytes(buildProjectWorkbookBytes(estimate: estimate));
      final summary = sheetNamed(archive, 'Summary');

      expect(summary, contains('Plans this job is quoted against (1)'));
      expect(summary, contains('Level 1 floor plan'));
      expect(summary, contains('issued 3 Feb'));
      // The path AS STORED - what the project file says, so a reader with the
      // folder in front of them can follow it.
      expect(summary, contains('A-101.pdf'));
      expect(summary, isNot(contains('NOT FOUND')));
    });

    test('a drawing that has moved is flagged, not quietly listed', () {
      final estimate = job();
      estimate.project.plans.add(ProjectPlan(
        id: estimate.project.nextPlanId(),
        filePath: 'A-999.pdf',
        label: 'Riser diagram',
      ));

      final archive = ZipDecoder()
          .decodeBytes(buildProjectWorkbookBytes(estimate: estimate));
      final summary = sheetNamed(archive, 'Summary');

      expect(summary, contains('Riser diagram'));
      expect(summary, contains('NOT FOUND'));
      // ...and again in the block somebody reads before the book goes out.
      expect(summary, contains('Check before this goes out'));
      expect(summary, contains('1 building plan is not where the project'));
    });

    test('a job with no plans says nothing about them', () {
      final archive = ZipDecoder()
          .decodeBytes(buildProjectWorkbookBytes(estimate: job()));
      expect(sheetNamed(archive, 'Summary'),
          isNot(contains('Plans this job is quoted against')));
    });

    test('an unreadable room is named in the summary rather than dropped', () {
      final estimate = job();
      estimate.project.rooms.add(ProjectRoomRef(
        id: estimate.project.nextRoomId(),
        configPath: 'missing_config.json',
        label: 'Bessey 105',
      ));
      final rebuilt = computeProjectEstimate(
        project: estimate.project,
        projectPath: path.join(dir.path, 'bss_project.json'),
        library: catalog(),
      );

      final archive = ZipDecoder()
          .decodeBytes(buildProjectWorkbookBytes(estimate: rebuilt));
      final summary = sheetNamed(archive, 'Summary');

      expect(summary, contains('Bessey 105'));
      expect(summary, contains('NOT COUNTED'));
      expect(summary, contains('Check before this goes out'));
    });

    test('untagged parts are called out on the summary', () {
      final estimate = job();
      estimate.project.vendors.clear();
      final rebuilt = computeProjectEstimate(
        project: estimate.project,
        projectPath: path.join(dir.path, 'bss_project.json'),
        library: catalog(),
      );

      final archive = ZipDecoder()
          .decodeBytes(buildProjectWorkbookBytes(estimate: rebuilt));

      expect(tabNames(archive), contains('Untagged'));
      expect(
        sheetNamed(archive, 'Summary'),
        contains('not tagged to any vendor'),
      );
    });
  });

  group('the control-gap sheet', () {
    /// The fixture rooms have no config device blocks behind their boxes, so
    /// every drawn device is a hand-added box with no driver — which is
    /// exactly the case the sheet exists for.
    ProjectEstimate withGaps() {
      final estimate = job();
      return computeProjectEstimate(
        project: estimate.project,
        projectPath: path.join(dir.path, 'bss_project.json'),
        library: catalog(),
        deviceCountMap: const {},
        moduleForModel: (_) => '',
      );
    }

    test('appears only when there is something on it', () {
      // No module lookup: the rule does not run, so no sheet.
      expect(
        tabNames(ZipDecoder()
            .decodeBytes(buildProjectWorkbookBytes(estimate: job()))),
        isNot(contains(kProjectControlSheet)),
      );

      expect(
        tabNames(ZipDecoder()
            .decodeBytes(buildProjectWorkbookBytes(estimate: withGaps()))),
        contains(kProjectControlSheet),
      );
    });

    test('names the room, the device and what to do about it', () {
      final archive = ZipDecoder()
          .decodeBytes(buildProjectWorkbookBytes(estimate: withGaps()));
      final sheet = sheetNamed(archive, kProjectControlSheet);

      expect(sheet, contains('Devices Without a Control Module'));
      expect(sheet, contains('Bessey 101'));
      expect(sheet, contains('Lectern TX'));
      expect(sheet, contains('No Python module claims this model'));
      expect(sheet, contains('What needs doing'));
    });

    test('the summary warns about it and the master list says which rooms',
        () {
      final archive = ZipDecoder()
          .decodeBytes(buildProjectWorkbookBytes(estimate: withGaps()));

      expect(
        sheetNamed(archive, 'Summary'),
        contains('have no control module'),
      );
      expect(
        sheetNamed(archive, 'Core Components'),
        contains('no module: '),
      );
    });

    test('the quote requests carry none of it', () {
      // A supplier being asked to price three transmitters has no business
      // knowing which of our rooms cannot commission them.
      final estimate = withGaps();
      final rfq = ZipDecoder().decodeBytes(buildVendorRfqBytes(
        estimate: estimate,
        package: estimate.packageFor('v1')!,
      ));

      expect(sheetText(rfq, 1), isNot(contains('no module')));
      expect(sheetText(rfq, 1), isNot(contains('Control')));
    });
  });

  // -------------------------------------------------------------------------
  //  THE QUOTE REQUESTS
  // -------------------------------------------------------------------------

  group('a vendor quote request', () {
    test('holds that vendor\'s parts and the rooms they are for', () {
      final estimate = job();
      final archive = ZipDecoder().decodeBytes(buildVendorRfqBytes(
        estimate: estimate,
        package: estimate.packageFor('v1')!,
      ));

      final sheet = sheetText(archive, 1);
      expect(tabNames(archive), ['Extron Direct']);
      expect(sheet, contains('60-1439-13'));
      expect(sheet, contains('orders@extron.example'));
      expect(sheet, contains('Bessey 101 ×1, Bessey 103 ×1'));
      // Somewhere for the supplier to write, which is the point of the sheet.
      expect(sheet, contains('Your unit price'));
      expect(sheet, contains('Lead time'));
    });

    test('carries nothing belonging to another vendor', () {
      final estimate = job();
      final archive = ZipDecoder().decodeBytes(buildVendorRfqBytes(
        estimate: estimate,
        package: estimate.packageFor('v1')!,
      ));
      final sheet = sheetText(archive, 1);

      expect(sheet, isNot(contains('RoboSHOT')));
      expect(sheet, isNot(contains('999-9950-000')));
      expect(sheet, isNot(contains('AV Reseller')));
    });

    test('carries no labor, no fees, no tax and no project total', () {
      // The stakeholder's numbers. A supplier quoting three transmitters has no
      // business seeing what the install is being billed at.
      final estimate = job(labor: [
        const LaborLine(
          id: 'l1',
          description: 'Technician',
          customRate: 95,
          techs: 2,
          hours: 8,
        ),
      ]);
      final archive = ZipDecoder().decodeBytes(buildVendorRfqBytes(
        estimate: estimate,
        package: estimate.packageFor('v1')!,
      ));
      final sheet = sheetText(archive, 1);

      expect(sheet, isNot(contains('Labor')));
      expect(sheet, isNot(contains('Technician')));
      expect(sheet, isNot(contains('PROJECT TOTAL')));
      expect(sheet, isNot(contains('Sales tax')));
    });

    test('the file name says the job and the vendor', () {
      final estimate = job();
      final stem = vendorRfqFileStem(
        estimate.project,
        estimate.packageFor('v1')!,
      );

      expect(stem, 'Bessey_refresh_Extron_Direct_RFQ');
      // Nothing a file system will refuse.
      expect(RegExp(r'[\\/:*?"<>|]').hasMatch(stem), isFalse);
    });

    test('the vendor tabs inside the workbook say the same thing', () {
      // The book's per-vendor tab and the standalone RFQ are the same
      // sections, so a supplier and the person who sent it are reading one
      // document.
      final estimate = job();
      final book = ZipDecoder()
          .decodeBytes(buildProjectWorkbookBytes(estimate: estimate));
      final rfq = ZipDecoder().decodeBytes(buildVendorRfqBytes(
        estimate: estimate,
        package: estimate.packageFor('v1')!,
      ));

      for (final needle in const [
        '60-1439-13',
        'orders@extron.example',
        'Your unit price',
      ]) {
        expect(sheetNamed(book, 'Extron Direct'), contains(needle));
        expect(sheetText(rfq, 1), contains(needle));
      }
    });
  });

  // -------------------------------------------------------------------------
  //  THE BOOK AGREES WITH ITSELF
  // -------------------------------------------------------------------------

  test('the room tabs are the same figures the rooms\' own estimates give',
      () {
    final estimate = job();
    final archive = ZipDecoder()
        .decodeBytes(buildProjectWorkbookBytes(estimate: estimate));

    // Bessey 101 is a 500 transmitter and a 2000 camera.
    expect(estimate.rooms.first.total, 2500);
    expect(sheetNamed(archive, 'Bessey 101'), contains('2500'));
    // And the same figure appears on the summary's room row.
    expect(sheetNamed(archive, 'Summary'), contains('2500'));
  });

  test('the vendor packages add up to the parts total on the summary', () {
    final estimate = job();
    final split = estimate.vendors.fold(0.0, (s, p) => s + p.total);

    expect(split, closeTo(estimate.partsTotal, 0.001));
    // And the book is written, so a rounding fault would show as a bad file
    // rather than silently.
    expect(
      wholeBook(ZipDecoder()
          .decodeBytes(buildProjectWorkbookBytes(estimate: estimate))),
      isNotEmpty,
    );
  });

  // -------------------------------------------------------------------------
  //  THE HISTORY SHEET
  // -------------------------------------------------------------------------

  group('the history sheet', () {
    /// The same job, with a few recorded changes on it.
    ProjectEstimate jobWithHistory() {
      final estimate = job();
      estimate.project
        ..logEdit(
          itemKey: 'part:x',
          itemName: 'DTP2 T 211',
          field: 'Lead time',
          summary: 'set to 42 days',
          user: 'alice',
          at: DateTime(2026, 3, 4, 9, 5),
        )
        ..logEdit(
          itemKey: 'part:x',
          itemName: 'DTP2 T 211',
          field: 'Order',
          summary: 'ordered on 2026-03-05, PO PO-1234',
          user: 'bob',
          at: DateTime(2026, 3, 5, 14, 32),
        )
        ..logEdit(
          itemKey: 'project',
          itemName: 'Bessey refresh',
          field: 'Delivery deadline',
          summary: 'set to 2026-06-01',
          // No login: what an environment that says nothing produces. Left
          // blank rather than dressed up as a name — see currentUserName.
          user: '',
          at: DateTime(2026, 3, 6, 11, 0),
        );
      return estimate;
    }

    test('it is there, after the job sheets and before the vendors', () {
      final archive = ZipDecoder()
          .decodeBytes(buildProjectWorkbookBytes(estimate: jobWithHistory()));

      expect(tabNames(archive), [
        'Summary',
        'Core Components',
        'Order Timeline',
        'Spares',
        // A record about the JOB, so it sits with the job's own sheets rather
        // than pushing the tabs somebody actually sends further along.
        'History',
        'Extron Direct',
        'AV Reseller',
        'Bessey 101',
        'Bessey 103',
      ]);
    });

    test('it carries the change, the item, the time and the login', () {
      final archive = ZipDecoder()
          .decodeBytes(buildProjectWorkbookBytes(estimate: jobWithHistory()));
      final sheet = sheetNamed(archive, 'History');

      expect(sheet, contains('DTP2 T 211'));
      expect(sheet, contains('set to 42 days'));
      expect(sheet, contains('ordered on 2026-03-05, PO PO-1234'));
      expect(sheet, contains('alice'));
      expect(sheet, contains('bob'));
      // 24 hour, zero padded, so the column sorts and reads the same
      // everywhere.
      expect(sheet, contains('14:32'));
      expect(sheet, contains('09:05'));
      expect(sheet, contains('2026-03-04'));
    });

    test('it reads newest first and counts who did what', () {
      final archive = ZipDecoder()
          .decodeBytes(buildProjectWorkbookBytes(estimate: jobWithHistory()));
      final sheet = sheetNamed(archive, 'History');

      // The most recent change comes before the oldest one on the sheet.
      expect(
        sheet.indexOf('Delivery deadline'),
        lessThan(sheet.indexOf('set to 42 days')),
      );
      expect(sheet, contains('Who has worked on this job'));
      // The entry nobody was recorded against is counted rather than dropped.
      expect(sheet, contains('(not recorded)'));
    });

    test('a job with no recorded changes has no sheet at all', () {
      final archive =
          ZipDecoder().decodeBytes(buildProjectWorkbookBytes(estimate: job()));
      expect(tabNames(archive), isNot(contains('History')));
    });

    test('a QUOTE REQUEST never carries it', () {
      final estimate = jobWithHistory();
      final archive = ZipDecoder().decodeBytes(
        buildVendorRfqBytes(
          estimate: estimate,
          package: estimate.vendors.first,
        ),
      );

      // This is the file that gets emailed to a supplier. An audit trail of
      // who changed what internally is exactly the kind of thing that must not
      // leave the building on it.
      expect(tabNames(archive), isNot(contains('History')));
      expect(wholeBook(archive), isNot(contains('alice')));
      expect(wholeBook(archive), isNot(contains('PO-1234')));
    });
  });
}
