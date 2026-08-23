import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/project_view.dart';

/// The spares section on Core Components.
///
/// Where a spare is added, scoped to a room or to the building, and moved
/// between the two. The failure it exists to stop is a shelf list nobody can
/// approve: two spare projectors with no idea whether that covers a building
/// of four rooms or forty.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_spare_ui'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String writeRoom(
    String stem,
    String name, {
    Map<String, double> ownSpares = const {},
  }) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [
        AvNode(
          id: 'PROJECTORDEVICE_1',
          label: 'Projector',
          model: 'PowerLite L610U',
          pos: Offset.zero,
          ports: const [],
        ).toJson(),
      ],
    }));
    if (ownSpares.isNotEmpty) {
      File(path.join(dir.path, '${stem}_config_cost.json'))
          .writeAsStringSync(jsonEncode({
        'cost': {
          'extraEquipment': [
            for (final e in ownSpares.entries)
              {
                'id': '$stem-${e.key}',
                'description': e.key,
                'qty': e.value,
                'unitPrice': 300,
                'spare': true,
              },
          ],
        },
      }));
    }
    return configPath;
  }

  AppStateProvider withRooms(int count, {Map<String, double> ownSpares = const {}}) {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'PowerLite L610U',
        manufacturer: 'Epson',
        partNumber: 'V11H901020',
        category: 'Projector',
        price: 1000,
        ports: [],
      ));
    p.newProject(name: 'Bessey refresh', building: 'BSS');
    for (var i = 0; i < count; i++) {
      p.addRoomToProject(
        writeRoom('r$i', 'Bessey 10$i', ownSpares: i == 0 ? ownSpares : const {}),
      );
    }
    return p;
  }

  Future<void> openSpares(WidgetTester tester, AppStateProvider p) async {
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
    await tester.tap(find.text('Core Components'));
    await tester.pumpAndSettle();
    // 'Spares' with nothing spared yet, 'Spares (2)' once there is.
    await tester.tap(find.textContaining('Spares').first);
    await tester.pumpAndSettle();
  }

  testWidgets('a building spare says what share of the rooms it covers',
      (tester) async {
    final p = withRooms(4);
    final line = p.priceProject().master.first;
    p.addProjectSpare(
      partKey: line.key,
      description: line.description,
      model: line.model,
      qty: 1,
    );
    await openSpares(tester, p);

    expect(find.text('FOR THE BUILDING  (1)'), findsOneWidget);
    // One on a shelf against four installed. The figure the decision is
    // actually made on, and the one nothing else in the app would work out.
    expect(find.textContaining('1 on the shelf for 4 installed'),
        findsOneWidget);
    expect(find.textContaining('25% coverage'), findsOneWidget);
  });

  testWidgets('a building spare names the rooms it is a spare for',
      (tester) async {
    final p = withRooms(3);
    final line = p.priceProject().master.first;
    p.addProjectSpare(
      partKey: line.key,
      description: line.description,
      model: line.model,
    );
    await openSpares(tester, p);

    // "1 spare projector" is a row somebody has to go and research; the rooms
    // that have projectors in them is a row somebody can approve or cut.
    final covers = find.textContaining('Spare for Bessey 100');
    expect(covers, findsOneWidget);
    expect(
      tester.widget<Text>(covers).data,
      contains('Bessey 102'),
    );
  });

  testWidgets('a thin coverage reads as the small number it is',
      (tester) async {
    final p = withRooms(40);
    final line = p.priceProject().master.first;
    p.addProjectSpare(
      partKey: line.key,
      description: line.description,
      model: line.model,
      qty: 2,
    );
    await openSpares(tester, p);

    // 5%, not "0%": rounding a thin coverage to nothing would be saying the
    // job has no cover when it has some.
    expect(find.textContaining('5.0% coverage'), findsOneWidget);
  });

  testWidgets('a spare is added from the job, for the building',
      (tester) async {
    final p = withRooms(2);
    await openSpares(tester, p);

    await tester.tap(find.byKey(const ValueKey('project_add_spare')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add_spare_dialog')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('add_spare_qty')), '3');
    await tester.tap(find.byKey(const ValueKey('add_spare_confirm')));
    await tester.pumpAndSettle();

    expect(p.project.spares, hasLength(1));
    expect(p.project.spares.single.qty, 3);
    expect(p.project.spares.single.forBuilding, isTrue);
    // And it is on the order: three more arrive than the rooms are having.
    expect(p.priceProject().master.first.qty, 5);
  });

  testWidgets('a spare moves off a room onto the building', (tester) async {
    final p = withRooms(4);
    final line = p.priceProject().master.first;
    final roomId = p.project.rooms.first.id;
    final spare = p.addProjectSpare(
      partKey: line.key,
      description: line.description,
      model: line.model,
      roomId: roomId,
    );
    await openSpares(tester, p);
    expect(find.text('FOR THE BUILDING  (1)'), findsNothing);

    await tester.tap(find.byKey(ValueKey('spare_scope_${spare.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('spare_scope_building')).last);
    await tester.pumpAndSettle();

    // Nothing about it changed but who it is for, which is the whole reason
    // its room is a field rather than a fact about where it is stored.
    expect(p.project.spares.single.forBuilding, isTrue);
    expect(find.text('FOR THE BUILDING  (1)'), findsOneWidget);
    expect(find.textContaining('25% coverage'), findsOneWidget);
  });

  testWidgets('a spare comes back off the job', (tester) async {
    final p = withRooms(2);
    final line = p.priceProject().master.first;
    final spare = p.addProjectSpare(
      partKey: line.key,
      description: line.description,
      model: line.model,
    );
    await openSpares(tester, p);

    await tester.tap(find.byKey(ValueKey('spare_remove_${spare.id}')));
    await tester.pumpAndSettle();

    expect(p.project.spares, isEmpty);
    expect(p.priceProject().master.first.qty, 2);
  });

  testWidgets('a room s own spare is shown, and is the room s to change',
      (tester) async {
    final p = withRooms(2, ownSpares: {'Spare lamp': 2});
    await openSpares(tester, p);

    // It lives in that room's cost file and travels with the room, so the job
    // reports it rather than offering to edit it.
    expect(
      find.textContaining('2 asked for on this room\'s own Cost page'),
      findsOneWidget,
    );
    expect(find.text('BESSEY 100  (1)'), findsOneWidget);
  });

  testWidgets('the section totals the job s spares', (tester) async {
    final p = withRooms(4, ownSpares: {'Spare lamp': 2});
    final line = p
        .priceProject()
        .master
        .firstWhere((l) => l.model == 'PowerLite L610U');
    p.addProjectSpare(
      partKey: line.key,
      description: line.description,
      model: line.model,
    );
    await openSpares(tester, p);

    // Two lamps at 300 plus one projector at 1000. The header carries the
    // whole job's figure; the panel under it repeats it for the "every room"
    // selection, which is the same number said twice on purpose.
    expect(find.textContaining('3 units'), findsWidgets);
    expect(find.textContaining('1 for the building'), findsOneWidget);
  });
}
