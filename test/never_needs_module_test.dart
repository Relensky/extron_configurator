import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/control_gaps.dart';
import 'package:extron_configurator/project_view.dart';

/// Marking a product as one nothing can ever drive, from the Cost tab and from
/// the Project tab, and having that stick in the catalog.
///
/// The point of the flag is the list it shortens: a passive splitter reported
/// forever as "waiting for a control module" is a warning that can never be
/// acted on, and a list full of those is one nobody reads — which is how the
/// real ones get missed.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_never_ctrl'));
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

  /// A provider whose catalog is written into the temp folder, so the save
  /// path is a real one and the file can be read back.
  AppStateProvider app() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..rootFolderPath = dir.path;
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'Passive splitter',
        manufacturer: 'Generic',
        partNumber: 'SPL-2',
        category: 'Splitter',
        price: 40,
        ports: [],
      ))
      ..upsert(const AvDeviceTemplate(
        model: 'DTP2 T 211',
        manufacturer: 'Extron',
        partNumber: '60-1439-13',
        category: 'Transmitter',
        price: 500,
        ports: [],
      ));
    return p;
  }

  // -------------------------------------------------------------------------
  //  THE CATALOG ACTION
  // -------------------------------------------------------------------------

  group('marking a product', () {
    test('sets the flag and writes the catalog file', () async {
      final p = app();

      final result = await p.setModelNeverControlled('Passive splitter', true);

      expect(result.ok, isTrue);
      expect(result.message, contains('never needs a control module'));
      expect(
        p.avDeviceLibrary.templateForModel('Passive splitter')!.neverControlled,
        isTrue,
      );

      // On disk, not just in memory — there is no catalog Save button on
      // either of the tabs this is reached from.
      final file = File(path.join(dir.path, 'av_devices.json'));
      expect(file.existsSync(), isTrue);
      final written = jsonEncode(jsonDecode(file.readAsStringSync()));
      expect(written, contains('neverControlled'));
    });

    test('unmarks again', () async {
      final p = app();
      await p.setModelNeverControlled('Passive splitter', true);

      final result = await p.setModelNeverControlled('Passive splitter', false);

      expect(result.ok, isTrue);
      expect(
        p.avDeviceLibrary.templateForModel('Passive splitter')!.neverControlled,
        isFalse,
      );
    });

    test('keeps everything else on the entry', () async {
      // The flag is one field; an action that quietly rewrote the price or
      // dropped the part number would be a far worse bug than the one it
      // fixes, because nobody would look for it here.
      final p = app();
      await p.setModelNeverControlled('DTP2 T 211', true);

      final entry = p.avDeviceLibrary.templateForModel('DTP2 T 211')!;
      expect(entry.manufacturer, 'Extron');
      expect(entry.partNumber, '60-1439-13');
      expect(entry.category, 'Transmitter');
      expect(entry.price, 500);
    });

    test('a model the catalog does not have is refused, not invented',
        () async {
      // An entry conjured from a quote line would carry a model and nothing
      // else, and would then shadow the real one on the next import.
      final p = app();

      final result = await p.setModelNeverControlled('Mystery box', true);

      expect(result.ok, isFalse);
      expect(result.message, contains('not in the catalog yet'));
      expect(p.avDeviceLibrary.templateForModel('Mystery box'), isNull);
    });

    test('a line with no model says so', () async {
      final result = await app().setModelNeverControlled('', true);

      expect(result.ok, isFalse);
      expect(result.message, contains('no model'));
    });

    test('marking it twice is not an error', () async {
      final p = app();
      await p.setModelNeverControlled('Passive splitter', true);

      final again = await p.setModelNeverControlled('Passive splitter', true);

      expect(again.ok, isTrue);
      expect(again.message, contains('already'));
    });
  });

  // -------------------------------------------------------------------------
  //  WHAT IT ACTUALLY CHANGES
  // -------------------------------------------------------------------------

  group('the effect on the control-gap list', () {
    AvFlowModel diagram() => AvFlowModel(
      nodes: [
        device('n1', 'Splitter', 'Passive splitter'),
        device('n2', 'Lectern TX', 'DTP2 T 211'),
      ],
      cables: const [],
      racks: const [],
      rackSlots: const {},
      canvasSize: const Size(0, 0),
      roomTitle: 'Room A',
      unplaced: const [],
    );

    test('takes the product off the list, and leaves the others on it',
        () async {
      final p = app();

      List<ControlGap> gaps() => controlGapsForRoom(
        config: const {},
        model: diagram(),
        deviceCountMap: const {},
        library: p.avDeviceLibrary,
        moduleForModel: (_) => '',
      );

      expect(gaps().map((g) => g.model), ['Passive splitter', 'DTP2 T 211']);

      await p.setModelNeverControlled('Passive splitter', true);

      expect(
        gaps().map((g) => g.model),
        ['DTP2 T 211'],
        reason: 'the transmitter still needs a driver and still says so',
      );
    });

    test('the room stops flagging it too', () async {
      final p = app();
      final splitter = device('n1', 'Splitter', 'Passive splitter');
      expect(p.avNodeIsUncontrolled(splitter), isFalse);

      await p.setModelNeverControlled('Passive splitter', true);

      expect(p.avNodeIsUncontrolled(splitter), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  //  THE PROJECT TAB
  // -------------------------------------------------------------------------

  group('from the Project tab', () {
    String writeRoom(String stem, String name, List<AvNode> nodes) {
      final configPath = path.join(dir.path, '${stem}_config.json');
      File(configPath).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gui_full_room_name': name},
      }));
      File(path.join(dir.path, '${stem}_config_av_flow.json'))
          .writeAsStringSync(jsonEncode({
        'nodes': [for (final n in nodes) n.toJson()],
      }));
      return configPath;
    }

    AppStateProvider withProject() {
      final p = app();
      p.newProject(name: 'Never test');
      p.addRoomToProject(writeRoom('a', 'Room A', [
        device('n1', 'Splitter', 'Passive splitter'),
        device('n2', 'Lectern TX', 'DTP2 T 211'),
      ]));
      return p;
    }

    Future<void> pump(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: ProjectView())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('offers the action on the row that reports the gap',
        (tester) async {
      final p = withProject();
      await pump(tester, p);
      await tester.tap(find.text('Core Components'));
      await tester.pumpAndSettle();

      // Both products are undriven, so both rows carry it.
      expect(find.text('Never needs one'), findsNWidgets(2));
    });

    testWidgets('confirms before writing, and cancelling writes nothing',
        (tester) async {
      final p = withProject();
      await pump(tester, p);
      await tester.tap(find.text('Core Components'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('never_needs_module_Passive splitter')),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('never needs a module?'), findsOneWidget);
      // Says plainly that this is not a project-scoped edit.
      expect(find.textContaining('saved to the CATALOG'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(
        p.avDeviceLibrary
            .templateForModel('Passive splitter')!
            .neverControlled,
        isFalse,
      );
    });

    testWidgets('confirming retires the row', (tester) async {
      final p = withProject();
      await pump(tester, p);
      await tester.tap(find.text('Core Components'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('never_needs_module_Passive splitter')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('never_needs_module_confirm')),
      );
      await tester.pumpAndSettle();

      expect(
        p.avDeviceLibrary
            .templateForModel('Passive splitter')!
            .neverControlled,
        isTrue,
      );

      // The row it was pressed on stops complaining; the other one does not.
      p.refreshProjectRooms();
      final estimate = p.priceProject();
      expect(
        estimate.master
            .firstWhere((l) => l.model == 'Passive splitter')
            .hasControlGap,
        isFalse,
      );
      expect(
        estimate.master
            .firstWhere((l) => l.model == 'DTP2 T 211')
            .hasControlGap,
        isTrue,
      );
      expect(estimate.undrivenDevices, 1);
    });

    testWidgets('the action is gone once there is nothing to fix',
        (tester) async {
      final p = withProject();
      // runAsync, because this writes av_devices.json for real and a widget
      // test's fake clock never lets that Future complete — awaiting it
      // directly hangs the test rather than failing it.
      await tester.runAsync(() async {
        await p.setModelNeverControlled('Passive splitter', true);
        await p.setModelNeverControlled('DTP2 T 211', true);
      });
      p.refreshProjectRooms();

      await pump(tester, p);
      await tester.tap(find.text('Core Components'));
      await tester.pumpAndSettle();

      expect(find.text('Never needs one'), findsNothing);
      expect(p.priceProject().undrivenDevices, 0);
    });
  });
}
