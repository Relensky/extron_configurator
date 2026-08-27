import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/main.dart';

/// ============================================================================
///  THE DEVICES NOTHING WILL DRIVE, FROM THE PROJECT TAB
/// ============================================================================
///  A box quoted with no control module arrives, gets racked, and does not
///  commission. The project tab has always counted them — and the count was
///  the end of the road: the warning chip linked the price and vendor faults
///  to the rows they were about and left this one unpressable, so the one
///  fault whose fix lives in ANOTHER ROOM was the one nothing would take you
///  to.
///
///  Two things are checked here: that the count is a way in, and that what it
///  opens answers the question that follows it — which rooms do I have to go
///  and fix.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_gaps'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  AvNode device(String id, String label, String model) => AvNode(
    id: id,
    label: label,
    model: model,
    pos: Offset.zero,
    ports: const [],
  );

  String writeRoom(String stem, String name, List<AvNode> nodes) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(
      jsonEncode({
        'SYSTEM_SETUP': {'gui_full_room_name': name},
      }),
    );
    File(path.join(dir.path, '${stem}_config_av_flow.json')).writeAsStringSync(
      jsonEncode({'nodes': [for (final n in nodes) n.toJson()]}),
    );
    return configPath;
  }

  /// Three rooms, two of them carrying products no module claims. The catalog
  /// knows the products — they are real things somebody buys — and the module
  /// library has never heard of them, which is exactly how a device reaches
  /// the undriven list.
  AppStateProvider withProject() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = dir.path
      ..avDevicesFilePath = path.join(dir.path, 'av_devices.json')
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false;
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(
          model: 'Display X',
          manufacturer: 'Generic',
          category: 'Display',
          price: 1000,
          ports: [],
        ),
      )
      ..upsert(
        const AvDeviceTemplate(
          model: 'Camera Y',
          manufacturer: 'Generic',
          category: 'Camera',
          price: 900,
          ports: [],
        ),
      );
    p.newProject(name: 'Driver gaps');
    p.addRoomToProject(
      writeRoom('a', 'Room A', [
        device('n1', 'Display', 'Display X'),
        device('n2', 'Camera', 'Camera Y'),
      ]),
    );
    p.addRoomToProject(
      writeRoom('b', 'Room B', [device('n1', 'Display', 'Display X')]),
    );
    // Nothing undriven in here: it must not turn up on the list of rooms to
    // go and fix.
    p.addRoomToProject(writeRoom('c', 'Room C', []));
    p.selectTab(AppTab.project.index);
    return p;
  }

  Future<void> pumpProject(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('the rooms with undriven devices are on the estimate', () {
    final p = withProject();
    final estimate = p.priceProject();

    expect(estimate.undrivenDevices, greaterThan(0));
    // Room A and Room B, and not Room C.
    final rooms = {
      for (final entry in estimate.controlGaps) entry.room.name,
    };
    expect(rooms, {'Room A', 'Room B'});
  });

  testWidgets('the warning opens the undriven list, and names the rooms',
      (tester) async {
    final p = withProject();
    await pumpProject(tester, p);

    final warning = find.byKey(const ValueKey('project_warnings'));
    expect(warning, findsOneWidget);
    // It is a button, not a label: an unpressable count leaves somebody
    // hunting a parts list for the rows it means.
    await tester.tap(warning);
    await tester.pumpAndSettle();

    // The parts pane, filtered to the parts nothing drives.
    expect(find.textContaining('No control module'), findsWidgets);

    // AND THE ROOMS, which is the question that follows: the fix is picking a
    // module on a device, and that happens one room at a time.
    expect(find.textContaining('Rooms affected'), findsOneWidget);
    expect(find.textContaining('Room A'), findsWidgets);
    expect(find.textContaining('Room B'), findsWidgets);

    // Each with the way in.
    final opens = find.byWidgetPredicate((w) {
      final key = w.key;
      return key is ValueKey<String> &&
          key.value.startsWith('gap_room_open_');
    });
    expect(opens, findsNWidgets(2), reason: 'one per affected room');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a job with nothing undriven has no rooms list to show',
      (tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = dir.path
      ..avDevicesFilePath = path.join(dir.path, 'av_devices.json')
      ..settingsLoaded = true
      ..firstRunSetupNeeded = false;
    p.newProject(name: 'Clean job');
    p.addRoomToProject(writeRoom('d', 'Room D', []));
    p.selectTab(AppTab.project.index);
    await pumpProject(tester, p);

    expect(find.textContaining('Rooms affected'), findsNothing);
  });
}
