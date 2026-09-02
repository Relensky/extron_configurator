import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_view.dart';

/// ============================================================================
///  WHERE THE KIT IS, ON THE LIST THAT SAYS WHAT WAS BOUGHT
/// ============================================================================
///  The delivery log records ARRIVALS - six on the 3rd, four on the 11th - and
///  the question somebody has in June is a different one: where is it. What is
///  guarded here:
///
///    * arrivals in the same place merge into one answer, however many
///      packing slips they came on
///    * a returned lot is not counted as being anywhere
///    * an installed lot names the room, not the shelf it passed through
///    * the equipment list actually shows it, and shows nothing when the job
///      logs no deliveries
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_whereabouts'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String writeRoom(String stem, String name) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(
      jsonEncode({
        'SYSTEM_SETUP': {'gui_full_room_name': name},
      }),
    );
    File(path.join(dir.path, '${stem}_config_av_flow.json')).writeAsStringSync(
      jsonEncode({
        'nodes': [
          AvNode(
            id: 'PROJECTORDEVICE_1',
            label: 'Projector',
            model: 'PowerLite L610U',
            pos: Offset.zero,
            ports: const [],
          ).toJson(),
        ],
      }),
    );
    return configPath;
  }

  AppStateProvider job() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(
          model: 'PowerLite L610U',
          manufacturer: 'Epson',
          category: 'Projector',
          price: 1000,
          ports: [],
        ),
      );
    p.newProject(name: 'Bessey refresh', building: 'BSS');
    p.addRoomToProject(writeRoom('r0', 'Bessey 101'));
    return p;
  }

  group('the grouping', () {
    test('three arrivals at the same place are one answer', () {
      final p = job();
      final key = p.priceProject().master.first.key;
      for (var i = 0; i < 3; i++) {
        p.addProjectDelivery(
          partKey: key,
          qty: 2,
          state: DeliveryState.stored,
          // The same shelf, typed three ways - which is what happens.
          location: i == 1 ? 'central stores' : 'Central Stores',
        );
      }

      final where = p.project.partLocationsFor(key);
      expect(where.length, 1);
      expect(where.single.qty, 6);
      // The FIRST spelling is the one kept: it is the one the shared list
      // wrote, and the row should not start reading in lower case because
      // somebody was in a hurry on the Tuesday.
      expect(where.single.label(), 'In storage at Central Stores');
    });

    test('a returned lot is nowhere', () {
      final p = job();
      final key = p.priceProject().master.first.key;
      p.addProjectDelivery(partKey: key, qty: 4, location: 'MLIB dock');
      p.addProjectDelivery(
        partKey: key,
        qty: 1,
        state: DeliveryState.returned,
        location: 'MLIB dock',
      );

      final where = p.project.partLocationsFor(key);
      expect(where.length, 1, reason: 'the returned lot went back');
      expect(where.single.qty, 4);
    });

    test('an installed lot is in the room, whatever place was on the row', () {
      final p = job();
      final roomId = p.project.rooms.single.id;
      final key = p.priceProject().master.first.key;
      p.addProjectDelivery(
        partKey: key,
        qty: 2,
        state: DeliveryState.installed,
        roomId: roomId,
        location: 'MLIB dock',
      );

      final at = p.project.partLocationsFor(key).single;
      expect(at.isInstalled, isTrue);
      expect(at.roomId, roomId);
      expect(at.label(roomName: 'BSS 101'), 'Installed in BSS 101');
      // Without a name it still answers the question that was asked, rather
      // than printing a room id at somebody.
      expect(at.label(), 'Installed');
    });

    test('the biggest lot leads, and the whole log is read in one pass', () {
      final p = job();
      final roomId = p.project.rooms.single.id;
      final key = p.priceProject().master.first.key;
      p.addProjectDelivery(partKey: key, qty: 1, location: 'MLIB dock');
      p.addProjectDelivery(
        partKey: key,
        qty: 5,
        state: DeliveryState.installed,
        roomId: roomId,
      );
      p.addProjectDelivery(
        partKey: key,
        qty: 3,
        state: DeliveryState.stored,
        location: 'Central Stores',
      );
      // Something that is not on the master list at all - a loaner, a box of
      // connectors - has no part key and belongs to no row.
      p.addProjectDelivery(itemName: 'Loaner switcher', qty: 1);

      final byKey = p.project.partLocationsByKey();
      expect(byKey.keys, [key]);
      expect([for (final at in byKey[key]!) at.qty], [5, 3, 1]);
    });
  });

  group('the equipment list', () {
    Future<void> openParts(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1700, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: ProjectView())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project_pane_parts')));
      await tester.pumpAndSettle();
    }

    testWidgets('a part says where it is', (tester) async {
      final p = job();
      final roomId = p.project.rooms.single.id;
      final key = p.priceProject().master.first.key;
      p.addProjectDelivery(
        partKey: key,
        qty: 1,
        state: DeliveryState.installed,
        roomId: roomId,
      );
      p.addProjectDelivery(
        partKey: key,
        qty: 2,
        state: DeliveryState.stored,
        location: 'Central Stores',
      );

      await openParts(tester, p);

      final row = find.byKey(ValueKey('part_where_$key'));
      expect(row, findsOneWidget);
      final text = tester.widget<Text>(row).data!;
      expect(text, contains('In storage at Central Stores'));
      expect(text, contains('Installed in'));
    });

    testWidgets('a job that logs nothing grows no line', (tester) async {
      final p = job();
      final key = p.priceProject().master.first.key;
      await openParts(tester, p);
      expect(find.byKey(ValueKey('part_where_$key')), findsNothing);
    });
  });
}
