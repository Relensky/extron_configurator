import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_estimate.dart';

/// Spares the JOB buys, for a room or for the building.
///
/// A room's own spares live in that room's cost file and travel with the room.
/// A building's spares belong to no room, so there is no room file they could
/// be written into without lying about who is buying them - they live on the
/// project, where they can also be re-pointed at a room, or off one, without
/// rewriting anything on disk.
///
/// The failures this guards, in the order they would cost money:
///
///   * A spare that does not reach the order. It is real money either way.
///   * A spare counted as something a room is installing, which would make
///     both the room count and the coverage wrong.
///   * A coverage figure nobody can act on: "2 spares" without "out of 40".
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_spares'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// A room with [projectors] projectors drawn in it.
  String writeRoom(String stem, String name, {int projectors = 1}) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [
        for (var i = 0; i < projectors; i++)
          AvNode(
            id: 'PROJECTORDEVICE_${i + 1}',
            label: 'Projector ${i + 1}',
            model: 'PowerLite L610U',
            pos: Offset(i * 120, 0),
            ports: const [],
          ).toJson(),
      ],
    }));
    return configPath;
  }

  AppStateProvider withRooms(int count, {int projectorsEach = 1}) {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'PowerLite L610U',
        manufacturer: 'Epson',
        partNumber: 'V11H901020',
        category: 'Projector',
        price: 1000,
        ports: [],
      ))
      ..upsert(const AvDeviceTemplate(
        model: 'DMP 128 PLUS',
        manufacturer: 'Extron',
        partNumber: '60-1494-01',
        category: 'DSP',
        price: 2000,
        ports: [],
      ));
    p.newProject(name: 'Bessey refresh', building: 'BSS');
    for (var i = 0; i < count; i++) {
      p.addRoomToProject(
        writeRoom('r$i', 'Bessey 10$i', projectors: projectorsEach),
      );
    }
    return p;
  }

  /// The master line for the projector every fixture room is having.
  MasterPartLine projectorLine(AppStateProvider p) => p
      .priceProject()
      .master
      .firstWhere((l) => l.model == 'PowerLite L610U');

  group('a spare for the building', () {
    test('is bought, and is not something a room is installing', () {
      final p = withRooms(4);
      final before = projectorLine(p);
      expect(before.qty, 4);
      expect(before.drawnQty, 4);

      p.addProjectSpare(
        partKey: before.key,
        description: before.description,
        model: before.model,
        qty: 2,
      );

      final after = projectorLine(p);
      // Bought: six arrive. Installed: still four - the other two go on a
      // shelf, and counting them as installed would make every figure derived
      // from the drawing wrong.
      expect(after.qty, 6);
      expect(after.drawnQty, 4);
      expect(after.spareQty, 2);
      expect(after.buildingSpareQty, 2);
      // And it is nobody's room's.
      expect(after.spareByRoom, isEmpty);
    });

    test('is in the project total, not only on the order', () {
      // THE FAILURE THIS EXISTS FOR: the project total is the sum of the
      // ROOMS' totals, and a spare the job buys belongs to no room. It reached
      // the parts list, the vendor packages and every quote request, and was
      // in none of the figures on the front of the tab - so the number
      // somebody budgets from was short by the whole spares bill.
      final p = withRooms(4);
      final before = p.priceProject();
      final line = projectorLine(p);

      p.addProjectSpare(
        partKey: line.key,
        description: line.description,
        model: line.model,
        qty: 2,
      );

      final after = p.priceProject();
      expect(after.projectSpareTotal, 2000);
      expect(after.grandTotal, before.grandTotal + 2000);
      // Against the section it lands in, so the sections still add up to the
      // parts figure...
      expect(after.equipmentTotal, before.equipmentTotal + 2000);
      expect(
        after.partsTotal,
        after.equipmentTotal +
            after.hardwareTotal +
            after.cablingTotal +
            after.extrasTotal,
      );
      // ...and the total now agrees with what the packages are being quoted
      // for, which on a job with no labor or tax is the same money twice.
      expect(
        after.packages.fold<double>(0, (sum, v) => sum + v.total),
        after.grandTotal,
      );
    });

    test('a spare of a part no room is having is money too', () {
      final p = withRooms(2);
      final before = p.priceProject();
      p.addProjectSpare(
        partKey: masterPartKey(kind: 'equipment', model: 'DMP 128 PLUS'),
        description: 'DSP for the store',
        model: 'DMP 128 PLUS',
        qty: 1,
      );
      // Priced off the catalog, because no room established a price for it.
      expect(p.priceProject().grandTotal, before.grandTotal + 2000);
    });

    test('says what share of the installed units it covers', () {
      final p = withRooms(40);
      final line = projectorLine(p);
      p.addProjectSpare(
        partKey: line.key,
        description: line.description,
        model: line.model,
        qty: 2,
      );

      final after = projectorLine(p);
      // Two out of forty. The figure the decision is actually made on: nobody
      // can weigh "two spares" without knowing two out of how many.
      expect(after.buildingSpareCoverage, closeTo(0.05, 0.0001));
      expect(after.spareCoverage, closeTo(0.05, 0.0001));
    });

    test('covers nothing measurable when no room is having the part', () {
      final p = withRooms(2);
      p.addProjectSpare(
        partKey: masterPartKey(kind: 'equipment', model: 'DMP 128 PLUS'),
        description: 'DSP for the store',
        model: 'DMP 128 PLUS',
        qty: 1,
      );

      final line = p
          .priceProject()
          .master
          .firstWhere((l) => l.model == 'DMP 128 PLUS');
      // A spare kept for a model every room has since been swapped off. It is
      // still money on the order, so it gets a line - but "infinity per cent
      // covered" and "0% covered" would both be saying something untrue.
      expect(line.qty, 1);
      expect(line.drawnQty, 0);
      expect(line.buildingSpareCoverage, isNull);
      // Priced off the catalog, which is the only thing here that knows.
      expect(line.unitPrice, 2000);
      expect(line.unpriced, isFalse);
    });

    test('the job totals it apart from the rooms own spares', () {
      final p = withRooms(4);
      final line = projectorLine(p);
      p.addProjectSpare(
        partKey: line.key,
        description: line.description,
        model: line.model,
        qty: 2,
      );

      final estimate = p.priceProject();
      expect(estimate.buildingSpareUnits, 2);
      expect(estimate.buildingSparesTotal, 2000);
      // It is still a spare on the job as a whole.
      expect(estimate.spareUnits, 2);
      // And it is not attributed to any room.
      expect(estimate.sparesByRoom, isEmpty);
    });

    test('the shelf list names the rooms it is a spare for', () {
      final p = withRooms(3);
      final line = projectorLine(p);
      p.addProjectSpare(
        partKey: line.key,
        description: line.description,
        model: line.model,
        qty: 2,
      );

      final shelf = p.priceProject().buildingSpares.single;
      expect(shelf.qty, 2);
      expect(shelf.installed, 3);
      expect(shelf.coverage, closeTo(2 / 3, 0.0001));
      // "Two spare projectors" means nothing until the rooms with projectors
      // in them are named beside it.
      expect(shelf.roomIds, hasLength(3));
    });
  });

  group('a spare for one room', () {
    test('lands on that room rather than on the building', () {
      final p = withRooms(2);
      final line = projectorLine(p);
      final roomId = p.project.rooms.first.id;

      p.addProjectSpare(
        partKey: line.key,
        description: line.description,
        model: line.model,
        qty: 1,
        roomId: roomId,
      );

      final after = projectorLine(p);
      expect(after.buildingSpareQty, 0);
      expect(after.spareByRoom[roomId], 1);
      expect(after.spareQty, 1);
      expect(p.priceProject().buildingSpares, isEmpty);
      expect(p.priceProject().sparesByRoom.single.units, 1);
    });

    test('is not bought when its room is off the total', () {
      final p = withRooms(2);
      final line = projectorLine(p);
      final roomId = p.project.rooms.first.id;
      p.addProjectSpare(
        partKey: line.key,
        description: line.description,
        model: line.model,
        qty: 1,
        roomId: roomId,
      );
      expect(projectorLine(p).qty, 3);

      // An alternate taken out of the total takes its spare with it. The spare
      // stays on the PROJECT, because the room may come back.
      p.updateProjectRoom(roomId, included: false);
      expect(projectorLine(p).qty, 1);
      expect(p.project.spares, hasLength(1));
    });

    test('goes with the room when the room leaves the job', () {
      final p = withRooms(2);
      final line = projectorLine(p);
      final roomId = p.project.rooms.first.id;
      p.addProjectSpare(
        partKey: line.key,
        description: line.description,
        model: line.model,
        roomId: roomId,
      );
      p.addProjectSpare(
        partKey: line.key,
        description: line.description,
        model: line.model,
      );

      p.removeRoomFromProject(roomId);
      // The room's spare goes; the building's was never that room's.
      expect(p.project.spares, hasLength(1));
      expect(p.project.spares.single.forBuilding, isTrue);
    });
  });

  group('moving one', () {
    test('off a room makes it the building s', () {
      final p = withRooms(4);
      final line = projectorLine(p);
      final roomId = p.project.rooms.first.id;
      final spare = p.addProjectSpare(
        partKey: line.key,
        description: line.description,
        model: line.model,
        qty: 2,
        roomId: roomId,
      );
      expect(projectorLine(p).spareByRoom[roomId], 2);

      p.moveProjectSpare(spare.id, '');

      final after = projectorLine(p);
      expect(after.spareByRoom, isEmpty);
      expect(after.buildingSpareQty, 2);
      // Nothing else about it moved: same part, same quantity, same money.
      expect(after.qty, 6);
      expect(p.project.spares.single.qty, 2);
    });

    test('onto a room takes it off the building', () {
      final p = withRooms(4);
      final line = projectorLine(p);
      final roomId = p.project.rooms.first.id;
      final spare = p.addProjectSpare(
        partKey: line.key,
        description: line.description,
        model: line.model,
      );

      p.moveProjectSpare(spare.id, roomId);
      expect(projectorLine(p).buildingSpareQty, 0);
      expect(projectorLine(p).spareByRoom[roomId], 1);
    });

    test('is written into the history in words', () {
      final p = withRooms(2);
      final line = projectorLine(p);
      final roomId = p.project.rooms.first.id;
      final spare = p.addProjectSpare(
        partKey: line.key,
        description: line.description,
        model: line.model,
        roomId: roomId,
      );
      p.moveProjectSpare(spare.id, '');

      final moved = p.project.history.last;
      expect(moved.field, 'Spare');
      expect(moved.summary, contains('to the building'));
    });
  });

  group('the quantity', () {
    test('changes without the spare being retyped', () {
      final p = withRooms(4);
      final line = projectorLine(p);
      final spare = p.addProjectSpare(
        partKey: line.key,
        description: line.description,
        model: line.model,
      );

      p.setProjectSpareQty(spare.id, 3);
      expect(projectorLine(p).buildingSpareQty, 3);
      expect(projectorLine(p).qty, 7);
    });

    test('never goes to zero, because a spare of none is not a spare', () {
      final p = withRooms(2);
      final line = projectorLine(p);
      final spare = p.addProjectSpare(
        partKey: line.key,
        description: line.description,
        model: line.model,
      );

      // The box it is typed into can be emptied mid-edit, and a row that
      // vanished while somebody was retyping it would be worse than one that
      // held at one.
      p.setProjectSpareQty(spare.id, 0);
      expect(p.project.spares.single.qty, 1);
    });

    test('taking it off the job takes it off the order', () {
      final p = withRooms(4);
      final line = projectorLine(p);
      final spare = p.addProjectSpare(
        partKey: line.key,
        description: line.description,
        model: line.model,
        qty: 2,
      );
      expect(projectorLine(p).qty, 6);

      p.removeProjectSpare(spare.id);
      expect(projectorLine(p).qty, 4);
      expect(p.priceProject().buildingSpares, isEmpty);
    });
  });

  group('it survives the file', () {
    test('a spare round-trips with its scope and its note', () {
      final project = BuildingProject(name: 'Bessey');
      project.addSpare(
        partKey: 'equipment|model:powerlite l610u',
        description: 'Epson PowerLite L610U',
        model: 'PowerLite L610U',
        qty: 2,
        note: 'for the store',
      );
      project.addSpare(
        partKey: 'equipment|model:dmp 128 plus',
        description: 'Extron DMP 128 PLUS',
        roomId: 'room1',
      );

      final read = BuildingProject.fromJson(
        jsonDecode(jsonEncode(project.toJson())) as Map<String, dynamic>,
      );
      expect(read.spares, hasLength(2));
      expect(read.buildingSpares.single.qty, 2);
      expect(read.buildingSpares.single.note, 'for the store');
      expect(read.sparesFor('room1').single.forBuilding, isFalse);
    });

    test('ids are not handed out twice after a reload', () {
      final project = BuildingProject();
      project.addSpare(partKey: 'k', description: 'A');
      project.addSpare(partKey: 'k', description: 'B');

      final read = BuildingProject.fromJson(
        jsonDecode(jsonEncode(project.toJson())) as Map<String, dynamic>,
      );
      final third = read.addSpare(partKey: 'k', description: 'C');
      // A reused id would make two spares the same spare, and deleting one
      // would delete the other.
      expect(read.spares.map((s) => s.id).toSet(), hasLength(3));
      expect(third.id, isNot('spare1'));
    });

    test('a job with a spare on it is not an empty job', () {
      // Otherwise Close would put away a shelf list somebody just typed.
      expect(BuildingProject().isEmpty, isTrue);
      final project = BuildingProject();
      project.addSpare(partKey: 'k', description: 'A');
      expect(project.isEmpty, isFalse);
    });

    test('a clone carries them and does not share the list', () {
      final project = BuildingProject();
      project.addSpare(partKey: 'k', description: 'A');
      final copy = project.clone();
      copy.addSpare(partKey: 'k', description: 'B');

      expect(project.spares, hasLength(1));
      expect(copy.spares, hasLength(2));
    });
  });
}
