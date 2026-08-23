import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/project_estimate.dart';

/// A building quoted as one job: rooms read off disk without being opened,
/// their totals rolled up, their parts merged onto one order, and that order
/// split between the companies that will quote it.
///
/// The figures here are the ones that go on a quote and the ones that go out
/// to a supplier, so every rule that decides a number or a vendor gets its own
/// check.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_project_test'));
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

  /// Writes a room to disk the way the app writes one: a config, plus the
  /// sidecar parts that hold the diagram and the estimate.
  String writeRoom(
    String stem, {
    required String name,
    required List<AvNode> nodes,
    double taxPercent = 0,
    Map<String, double> priceOverrides = const {},
    List<CostLineItem> items = const [],
  }) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));

    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [for (final n in nodes) n.toJson()],
      'cables': <dynamic>[],
    }));

    final settings = RoomCostSettings(
      taxPercent: taxPercent,
      priceOverrides: Map<String, double>.from(priceOverrides),
      items: List<CostLineItem>.from(items),
    );
    File(path.join(dir.path, '${stem}_config_cost.json'))
        .writeAsStringSync(jsonEncode({'cost': settings.toJson()}));

    return configPath;
  }

  /// Two makers and three categories, so both kinds of vendor rule have
  /// something real to bite on.
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
    library.upsert(const AvDeviceTemplate(
      model: 'Big Panel 86',
      manufacturer: 'Samsung',
      partNumber: 'QM86R',
      category: 'Display',
      price: 3000,
      ports: [],
    ));
    return library;
  }

  ProjectEstimate price(BuildingProject project, {String projectPath = ''}) =>
      computeProjectEstimate(
        project: project,
        projectPath: projectPath.isEmpty
            ? path.join(dir.path, 'job_project.json')
            : projectPath,
        library: catalog(),
      );

  /// A project over [configs], each added as its own room.
  BuildingProject projectOver(List<String> configs) {
    final project = BuildingProject(name: 'Test Building');
    final projectPath = path.join(dir.path, 'job_project.json');
    for (final c in configs) {
      project.rooms.add(ProjectRoomRef(
        id: project.nextRoomId(),
        configPath: BuildingProject.storePath(c, projectPath),
      ));
    }
    return project;
  }

  MasterPartLine partNamed(ProjectEstimate estimate, String needle) =>
      estimate.master.firstWhere(
        (l) => l.description.toLowerCase().contains(needle.toLowerCase()),
        orElse: () => throw StateError(
          'No core component matching "$needle". Have: '
          '${estimate.master.map((l) => l.description).join(', ')}',
        ),
      );

  // -------------------------------------------------------------------------
  //  READING A ROOM WITHOUT OPENING IT
  // -------------------------------------------------------------------------

  group('reading rooms off disk', () {
    test('reads the config name, the diagram and the estimate settings', () {
      final config = writeRoom(
        'r1',
        name: 'Bessey 101',
        nodes: [device('d1', 'Camera', 'RoboSHOT 12E')],
        taxPercent: 8.25,
      );

      final room = readRoomFromDisk(config);

      expect(room.ok, isTrue);
      expect(room.title, 'Bessey 101');
      expect(room.model.nodes, hasLength(1));
      expect(room.model.nodes.single.model, 'RoboSHOT 12E');
      expect(room.settings.taxPercent, 8.25);
    });

    test('a missing config is an error on that room, not an exception', () {
      final room = readRoomFromDisk(path.join(dir.path, 'nope_config.json'));

      expect(room.ok, isFalse);
      expect(room.error, contains('not at'));
      // Still a usable object: the rollup renders a row for it.
      expect(room.model.nodes, isEmpty);
    });

    test('unparseable json is an error rather than a crash', () {
      final config = path.join(dir.path, 'bad_config.json');
      File(config).writeAsStringSync('{ this is not json');

      final room = readRoomFromDisk(config);

      expect(room.ok, isFalse);
      expect(room.error, contains('could not be read'));
    });

    test('a config with no sidecars reads as empty, not as broken', () {
      final config = path.join(dir.path, 'bare_config.json');
      File(config).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gui_full_room_name': 'Not drawn yet'},
      }));

      final room = readRoomFromDisk(config);

      expect(room.ok, isTrue);
      expect(room.isEmpty, isTrue);
      expect(room.title, 'Not drawn yet');
    });

    test('a room saved as one combined file still reads', () {
      // The pre-split document: every key in the flow file, no companions.
      final config = path.join(dir.path, 'old_config.json');
      File(config).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gui_full_room_name': 'Legacy room'},
      }));
      File(path.join(dir.path, 'old_config_av_flow.json'))
          .writeAsStringSync(jsonEncode({
        'nodes': [device('d1', 'TX', 'DTP2 T 211').toJson()],
        'cost': RoomCostSettings(taxPercent: 7).toJson(),
      }));

      final room = readRoomFromDisk(config);

      expect(room.model.nodes, hasLength(1));
      expect(room.settings.taxPercent, 7);
    });
  });

  // -------------------------------------------------------------------------
  //  THE ROLLUP
  // -------------------------------------------------------------------------

  group('the building total', () {
    test('breaks out per room and adds to the project total', () {
      final a = writeRoom('a', name: 'Room A', nodes: [
        device('d1', 'TX', 'DTP2 T 211'),
      ]);
      final b = writeRoom('b', name: 'Room B', nodes: [
        device('d1', 'Camera', 'RoboSHOT 12E'),
        device('d2', 'Panel', 'Big Panel 86'),
      ]);

      final estimate = price(projectOver([a, b]));

      expect(estimate.rooms, hasLength(2));
      expect(estimate.rooms[0].name, 'Room A');
      expect(estimate.rooms[0].total, 500);
      expect(estimate.rooms[1].name, 'Room B');
      expect(estimate.rooms[1].total, 5000);
      expect(estimate.grandTotal, 5500);
      expect(estimate.equipmentTotal, 5500);
    });

    test('tax is each room\'s own, applied per room and then added', () {
      // 10% on one room and nothing on the other. A project-wide percentage
      // would give a different — and wrong — answer, so this is the check
      // that the rollup is a sum of room totals rather than a re-derivation.
      final a = writeRoom('a', name: 'Taxed', taxPercent: 10, nodes: [
        device('d1', 'Panel', 'Big Panel 86'),
      ]);
      final b = writeRoom('b', name: 'Untaxed', nodes: [
        device('d1', 'Panel', 'Big Panel 86'),
      ]);

      final estimate = price(projectOver([a, b]));

      expect(estimate.equipmentTotal, 6000);
      expect(estimate.taxTotal, 300);
      expect(estimate.grandTotal, 6300);
    });

    test('an excluded room stays listed but leaves the total', () {
      final a = writeRoom('a', name: 'In', nodes: [
        device('d1', 'Panel', 'Big Panel 86'),
      ]);
      final b = writeRoom('b', name: 'Alternate', nodes: [
        device('d1', 'Camera', 'RoboSHOT 12E'),
      ]);

      final project = projectOver([a, b]);
      project.rooms[1] = project.rooms[1].copyWith(included: false);
      final estimate = price(project);

      expect(estimate.rooms, hasLength(2), reason: 'still on the job');
      expect(estimate.costedRooms, hasLength(1));
      expect(estimate.grandTotal, 3000);
      // And its parts are off the order too — an alternate nobody chose must
      // not be bought.
      expect(
        estimate.master.map((l) => l.description),
        isNot(contains(contains('Camera'))),
      );
    });

    test('one unreadable room does not stop the others pricing', () {
      final good = writeRoom('a', name: 'Fine', nodes: [
        device('d1', 'Panel', 'Big Panel 86'),
      ]);

      final project = projectOver([good]);
      project.rooms.add(ProjectRoomRef(
        id: project.nextRoomId(),
        configPath: 'gone_config.json',
      ));
      final estimate = price(project);

      expect(estimate.failedRooms, 1);
      expect(estimate.costedRooms, hasLength(1));
      expect(estimate.grandTotal, 3000);
      expect(estimate.isComplete, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  //  THE CORE COMPONENTS LIST
  // -------------------------------------------------------------------------

  group('the core components list', () {
    test('merges the same model across rooms onto one line', () {
      final a = writeRoom('a', name: 'Room A', nodes: [
        device('d1', 'TX 1', 'DTP2 T 211'),
        device('d2', 'TX 2', 'DTP2 T 211'),
      ]);
      final b = writeRoom('b', name: 'Room B', nodes: [
        device('d1', 'TX', 'DTP2 T 211'),
      ]);

      final estimate = price(projectOver([a, b]));

      expect(estimate.master, hasLength(1));
      final line = estimate.master.single;
      expect(line.qty, 3);
      expect(line.total, 1500);
      expect(line.partNumber, '60-1439-13');
    });

    test('records which rooms the units are for', () {
      final a = writeRoom('a', name: 'Room A', nodes: [
        device('d1', 'TX 1', 'DTP2 T 211'),
        device('d2', 'TX 2', 'DTP2 T 211'),
      ]);
      final b = writeRoom('b', name: 'Room B', nodes: [
        device('d1', 'TX', 'DTP2 T 211'),
      ]);

      final project = projectOver([a, b]);
      final estimate = price(project);
      final line = estimate.master.single;

      expect(line.qtyByRoom[project.rooms[0].id], 2);
      expect(line.qtyByRoom[project.rooms[1].id], 1);
      // Most-first, so the breakdown column reads usefully.
      expect(line.roomIdsByQty().first, project.rooms[0].id);
    });

    test('a negotiated price in one room shows as a range, and the extended '
        'total is the sum of what the rooms actually pay', () {
      final a = writeRoom(
        'a',
        name: 'Room A',
        nodes: [device('d1', 'Panel', 'Big Panel 86')],
        priceOverrides: {'model:big panel 86': 2500},
      );
      final b = writeRoom('b', name: 'Room B', nodes: [
        device('d1', 'Panel', 'Big Panel 86'),
      ]);

      final estimate = price(projectOver([a, b]));
      final line = estimate.master.single;

      expect(line.qty, 2);
      expect(line.priceVaries, isTrue);
      expect(line.unitPrice, 2500);
      expect(line.maxUnitPrice, 3000);
      // 2500 + 3000 — NOT qty x either price.
      expect(line.total, 5500);
      expect(line.total, estimate.equipmentTotal);
    });

    test('parts merge on part number even when the rooms name them '
        'differently', () {
      // The same catalog entry reached through two different device labels:
      // a pack list keyed on the label would call these two products.
      final a = writeRoom('a', name: 'Room A', nodes: [
        device('d1', 'Wall plate TX', 'DTP2 T 211'),
      ]);
      final b = writeRoom('b', name: 'Room B', nodes: [
        device('d1', 'Lectern transmitter', 'DTP2 T 211'),
      ]);

      final estimate = price(projectOver([a, b]));

      expect(estimate.master, hasLength(1));
      expect(estimate.master.single.qty, 2);
    });

    test('sections never merge into each other', () {
      // An "other item" typed with the same name as a device must stay its
      // own line — the two are read in different parts of a quote.
      final a = writeRoom(
        'a',
        name: 'Room A',
        nodes: [device('d1', 'Big Panel 86', 'Big Panel 86')],
        items: [
          const CostLineItem(
            id: 'i1',
            description: 'Big Panel 86',
            qty: 1,
            unitPrice: 25,
          ),
        ],
      );

      final estimate = price(projectOver([a]));

      expect(estimate.master, hasLength(2));
      expect(
        estimate.master.map((l) => l.kind),
        containsAll([MasterPartKind.equipment, MasterPartKind.other]),
      );
    });
  });

  // -------------------------------------------------------------------------
  //  VENDOR TAGGING
  // -------------------------------------------------------------------------

  group('vendor tagging', () {
    /// One room with one of everything, so each rule has a part to claim.
    BuildingProject oneOfEach() {
      final config = writeRoom('a', name: 'Room A', nodes: [
        device('d1', 'TX', 'DTP2 T 211'),
        device('d2', 'Camera', 'RoboSHOT 12E'),
        device('d3', 'Panel', 'Big Panel 86'),
      ]);
      return projectOver([config]);
    }

    test('a manufacturer rule claims every part by that maker', () {
      final project = oneOfEach();
      project.vendors.add(const ProjectVendor(
        id: 'v1',
        name: 'Extron Direct',
        manufacturers: ['Extron'],
      ));

      final estimate = price(project);

      expect(partNamed(estimate, 'TX').vendor?.name, 'Extron Direct');
      expect(
        partNamed(estimate, 'TX').tagSource,
        VendorTagSource.manufacturerRule,
      );
      expect(partNamed(estimate, 'Camera').vendor, isNull);
      expect(estimate.untaggedParts, 2);
    });

    test('a category rule claims parts across makers', () {
      // The split the feature was asked for: cameras and screens together,
      // from two different manufacturers, without naming either.
      final project = oneOfEach();
      project.vendors.add(const ProjectVendor(
        id: 'v1',
        name: 'AV Reseller',
        categories: ['Camera', 'Display'],
      ));

      final estimate = price(project);

      expect(partNamed(estimate, 'Camera').vendor?.name, 'AV Reseller');
      expect(partNamed(estimate, 'Panel').vendor?.name, 'AV Reseller');
      expect(
        partNamed(estimate, 'Camera').tagSource,
        VendorTagSource.categoryRule,
      );
      expect(partNamed(estimate, 'TX').vendor, isNull);
    });

    test('a category rule matches a finer category on a word boundary', () {
      const vendor = ProjectVendor(
        id: 'v1',
        name: 'Reseller',
        categories: ['Camera'],
      );

      expect(vendor.quotesCategory('Camera'), isTrue);
      expect(vendor.quotesCategory('Camera - PTZ'), isTrue);
      expect(vendor.quotesCategory('camera/ptz'), isTrue);
      // Not a finer camera — a different word that happens to start the same.
      expect(vendor.quotesCategory('Cameraman kit'), isFalse);
    });

    test('a manufacturer rule beats a category rule for the same part', () {
      // An Extron display is bought direct, not from the reseller who does
      // screens — whichever vendor happens to be listed first.
      final config = writeRoom('a', name: 'Room A', nodes: [
        device('d1', 'TX', 'DTP2 T 211'),
      ]);
      final project = projectOver([config]);
      project.vendors.addAll(const [
        // Deliberately listed FIRST, so an order-only rule would pick it.
        ProjectVendor(
          id: 'v2',
          name: 'AV Reseller',
          categories: ['Transmitter'],
        ),
        ProjectVendor(
          id: 'v1',
          name: 'Extron Direct',
          manufacturers: ['Extron'],
        ),
      ]);

      final estimate = price(project);

      expect(partNamed(estimate, 'TX').vendor?.name, 'Extron Direct');
    });

    test('a pin beats every rule', () {
      final project = oneOfEach();
      project.vendors.addAll(const [
        ProjectVendor(
          id: 'v1',
          name: 'Extron Direct',
          manufacturers: ['Extron'],
        ),
        ProjectVendor(id: 'v2', name: 'Integrator'),
      ]);

      final key = partNamed(price(project), 'TX').key;
      project.pinPart(key, 'v2');
      final estimate = price(project);

      expect(partNamed(estimate, 'TX').vendor?.name, 'Integrator');
      expect(partNamed(estimate, 'TX').tagSource, VendorTagSource.pinned);
    });

    test('a pin survives the part moving to another room', () {
      // The pin is filed under the PART, so re-drawing the job does not undo
      // a purchasing decision.
      final a = writeRoom('a', name: 'Room A', nodes: [
        device('d1', 'TX', 'DTP2 T 211'),
      ]);
      final project = projectOver([a]);
      project.vendors.add(const ProjectVendor(id: 'v2', name: 'Integrator'));
      project.pinPart(partNamed(price(project), 'TX').key, 'v2');

      // Same part, different room, different node id.
      final b = writeRoom('b', name: 'Room B', nodes: [
        device('zzz', 'TX', 'DTP2 T 211'),
      ]);
      project.rooms.clear();
      project.rooms.add(ProjectRoomRef(
        id: project.nextRoomId(),
        configPath: BuildingProject.storePath(
          b,
          path.join(dir.path, 'job_project.json'),
        ),
      ));

      expect(partNamed(price(project), 'TX').vendor?.name, 'Integrator');
    });

    test('a pin to a deleted vendor falls back to the rules', () {
      final project = oneOfEach();
      project.vendors.addAll(const [
        ProjectVendor(
          id: 'v1',
          name: 'Extron Direct',
          manufacturers: ['Extron'],
        ),
        ProjectVendor(id: 'v2', name: 'Integrator'),
      ]);
      project.pinPart(partNamed(price(project), 'TX').key, 'v2');

      project.removeVendor('v2');
      final estimate = price(project);

      expect(partNamed(estimate, 'TX').vendor?.name, 'Extron Direct');
      // And the dead pin is gone rather than lurking.
      expect(project.partVendors.values, isNot(contains('v2')));
    });

    test('overlapping rules of the same kind are reported', () {
      final project = oneOfEach();
      project.vendors.addAll(const [
        ProjectVendor(id: 'v1', name: 'One', manufacturers: ['Extron']),
        ProjectVendor(id: 'v2', name: 'Two', manufacturers: ['extron']),
        // A manufacturer rule and a category rule that both cover a part are
        // the normal case, not a conflict — the tiers resolve it.
        ProjectVendor(id: 'v3', name: 'Three', categories: ['Transmitter']),
      ]);

      final conflicts = project.vendorConflicts;

      expect(conflicts, hasLength(1));
      expect(conflicts.single.kind, 'Manufacturer');
      expect(
        conflicts.single.vendors.map((v) => v.name),
        containsAll(['One', 'Two']),
      );
    });
  });

  // -------------------------------------------------------------------------
  //  VENDOR PACKAGES
  // -------------------------------------------------------------------------

  group('vendor packages', () {
    test('split the master list, and the splits add back to it', () {
      final a = writeRoom('a', name: 'Room A', nodes: [
        device('d1', 'TX', 'DTP2 T 211'),
        device('d2', 'Camera', 'RoboSHOT 12E'),
      ]);
      final b = writeRoom('b', name: 'Room B', nodes: [
        device('d1', 'TX', 'DTP2 T 211'),
        device('d2', 'Panel', 'Big Panel 86'),
      ]);

      final project = projectOver([a, b]);
      project.vendors.addAll(const [
        ProjectVendor(
          id: 'v1',
          name: 'Extron Direct',
          manufacturers: ['Extron'],
        ),
        ProjectVendor(
          id: 'v2',
          name: 'AV Reseller',
          categories: ['Camera', 'Display'],
        ),
      ]);

      final estimate = price(project);

      expect(estimate.untaggedParts, 0);
      expect(estimate.vendors, hasLength(2));

      final extron = estimate.packageFor('v1')!;
      expect(extron.lines, hasLength(1));
      expect(extron.qty, 2, reason: 'one transmitter in each room');
      expect(extron.total, 1000);

      final reseller = estimate.packageFor('v2')!;
      expect(reseller.total, 5000);

      expect(
        extron.total + reseller.total,
        closeTo(estimate.partsTotal, 0.001),
      );
    });

    test('untagged parts get their own package, listed last', () {
      final a = writeRoom('a', name: 'Room A', nodes: [
        device('d1', 'TX', 'DTP2 T 211'),
        device('d2', 'Camera', 'RoboSHOT 12E'),
      ]);
      final project = projectOver([a]);
      project.vendors.add(const ProjectVendor(
        id: 'v1',
        name: 'Extron Direct',
        manufacturers: ['Extron'],
      ));

      final estimate = price(project);

      expect(estimate.vendors.last.isUntagged, isTrue);
      expect(estimate.vendors.last.lines, hasLength(1));
      expect(estimate.untaggedParts, 1);
    });

    test('packages follow the vendor list order', () {
      final a = writeRoom('a', name: 'Room A', nodes: [
        device('d1', 'TX', 'DTP2 T 211'),
        device('d2', 'Camera', 'RoboSHOT 12E'),
      ]);
      final project = projectOver([a]);
      project.vendors.addAll(const [
        ProjectVendor(id: 'v2', name: 'Reseller', categories: ['Camera']),
        ProjectVendor(id: 'v1', name: 'Extron', manufacturers: ['Extron']),
      ]);

      final estimate = price(project);

      expect(
        estimate.vendors.map((p) => p.name).toList(),
        ['Reseller', 'Extron'],
      );
    });
  });

  // -------------------------------------------------------------------------
  //  THE PROJECT FILE
  // -------------------------------------------------------------------------

  group('the project file', () {
    test('round-trips through json', () async {
      final project = BuildingProject(
        name: 'Bessey refresh',
        building: 'BSS',
        jobNumber: 'J-1001',
        client: 'Facilities',
        currency: r'$',
      );
      project.rooms.add(ProjectRoomRef(
        id: project.nextRoomId(),
        configPath: 'bss101_config.json',
        label: 'BSS 101',
        notes: 'phase 2',
        included: false,
      ));
      project.vendors.add(ProjectVendor(
        id: project.nextVendorId(),
        name: 'Extron Direct',
        contact: 'orders@example.com',
        manufacturers: const ['Extron'],
        categories: const ['Transmitter'],
      ));
      project.pinPart('equipment|pn:QM86R', project.vendors.single.id);

      final file = path.join(dir.path, 'bss_project.json');
      await project.save(file);
      final back = await BuildingProject.load(file);

      expect(back.name, 'Bessey refresh');
      expect(back.jobNumber, 'J-1001');
      expect(back.rooms.single.label, 'BSS 101');
      expect(back.rooms.single.included, isFalse);
      expect(back.rooms.single.notes, 'phase 2');
      expect(back.vendors.single.contact, 'orders@example.com');
      expect(back.vendors.single.categories, ['Transmitter']);
      expect(back.partVendors['equipment|pn:QM86R'], 'vendor1');
      // Counters carry over, so the next id cannot collide with a stored one.
      expect(back.nextRoomId(), 'room2');
      expect(back.nextVendorId(), 'vendor2');
    });

    test('ids added by hand cannot be handed out again', () async {
      // The file says it has issued nothing; the rooms say otherwise. A room
      // added by hand-editing must not have its id reused.
      final file = path.join(dir.path, 'hand_project.json');
      File(file).writeAsStringSync(jsonEncode({
        'rooms': [
          {'id': 'room7', 'configPath': 'a_config.json'},
        ],
        'vendors': <dynamic>[],
        'roomCounter': 0,
      }));

      final project = await BuildingProject.load(file);

      expect(project.nextRoomId(), 'room8');
    });

    test('opening something that is not a project says so', () async {
      final file = path.join(dir.path, 'a_config.json');
      File(file).writeAsStringSync(jsonEncode({'SYSTEM_SETUP': {}}));

      expect(
        () => BuildingProject.load(file),
        throwsA(isA<FormatException>()),
      );
    });

    test('room paths are stored relative when they sit under the project', () {
      final projectFile = path.join(dir.path, 'job_project.json');
      final room = path.join(dir.path, 'rooms', 'a_config.json');

      final stored = BuildingProject.storePath(room, projectFile);

      expect(path.isAbsolute(stored), isFalse);
      expect(stored, path.join('rooms', 'a_config.json'));
      expect(
        BuildingProject.resolvePath(stored, projectFile),
        path.normalize(room),
      );
    });

    test('a room outside the project folder is stored absolute', () {
      // Relativising it would produce a chain of "..", which breaks the moment
      // the project file moves — the very thing relative paths are for.
      final projectFile = path.join(dir.path, 'here', 'job_project.json');
      final room = path.join(dir.path, 'elsewhere', 'a_config.json');

      final stored = BuildingProject.storePath(room, projectFile);

      expect(path.isAbsolute(stored), isTrue);
      expect(
        BuildingProject.resolvePath(stored, projectFile),
        path.normalize(room),
      );
    });
  });
}
