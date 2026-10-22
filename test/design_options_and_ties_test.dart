import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/project_estimate.dart';
import 'package:extron_configurator/room_design_options.dart';
import 'package:extron_configurator/room_sidecar.dart';
import 'package:extron_configurator/ui_schema.dart';

/// Tied lines on the Cost tab, and design options: other builds of the same
/// room, each a whole copy of its files.
void main() {
  group('tied lines', () {
    test('tied both ways, untied, moved and saved', () {
      final s = RoomCostSettings();
      expect(s.tie('mount', 'display'), isTrue);
      expect(s.tie('display', 'mount'), isFalse, reason: 'already tied');
      expect(s.tie('mount', 'mount'), isFalse);
      s.tie('mount', 'cable');
      expect(s.tiesOf('mount'), ['cable', 'display']);
      expect(s.tiesOf('display'), ['mount']);

      final back = RoomCostSettings()..readJson(s.toJson());
      expect(back.tiesOf('mount'), ['cable', 'display']);
      expect(back.tiesOf('cable'), ['mount']);

      s.moveTies('mount', 'mount2');
      expect(s.tiesOf('mount'), isEmpty);
      expect(s.tiesOf('display'), ['mount2']);

      expect(s.untie('display', 'mount2'), isTrue);
      expect(s.tiesOf('display'), isEmpty);
      expect(s.lineTies.containsKey('display'), isFalse);
      expect(RoomCostSettings().toJson().containsKey('lineTies'), isFalse);
    });

    test('a file with one side of a tie reads back both ways', () {
      final s = RoomCostSettings()
        ..readJson({
          'lineTies': {
            'mic': ['base'],
          },
        });
      expect(s.tiesOf('base'), ['mic']);
    });

    test('changing the count of a tied line is noticed', () {
      final p = AppStateProvider(autoLoadSettings: false);
      final mic = p.addAvCostExtraEquipment(description: 'Mic', unitPrice: 1);
      final base = p.addAvCostExtraEquipment(description: 'Base');
      final other = p.addAvCostExtraEquipment(description: 'Other');
      p.tieAvCostLines(mic.id, base.id);
      expect(p.avCostTiesOf(base.id), [mic.id]);

      final seen = <String>[];
      p.avCostTiedEdit.addListener(() {
        if (p.avCostTiedEdit.value.isNotEmpty) {
          seen.add(p.avCostTiedEdit.value);
        }
      });
      p.updateAvCostExtraEquipment(mic.copyWith(qty: 2));
      p.updateAvCostExtraEquipment(mic.copyWith(qty: 2, unitPrice: 5));
      p.updateAvCostExtraEquipment(other.copyWith(qty: 3));
      expect(seen, [mic.id], reason: 'only a count change on a tied line');

      p.untieAvCostLines(base.id, mic.id);
      expect(p.avCostTiesOf(mic.id), isEmpty);
    });

    testWidgets('tied from the tag menu; removing one warns',
        (tester) async {
      tester.view.physicalSize = const Size(1700, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      p.loadAvFlowForCurrentConfig();
      final mic = p.addAvCostItem(description: 'Ceiling mic', unitPrice: 900);
      final base = p.addAvCostItem(description: 'Mic base', unitPrice: 50);
      await tester.pumpWidget(ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(ValueKey('furnished_${mic.id}')));
      await tester.tap(find.byKey(ValueKey('furnished_${mic.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('cost_tie_${mic.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cost_tie_picker')), findsOneWidget);
      expect(find.byKey(ValueKey('cost_tie_pick_${mic.id}')), findsNothing,
          reason: 'not tied to itself');
      await tester.tap(find.byKey(ValueKey('cost_tie_pick_${base.id}')));
      await tester.pumpAndSettle();
      expect(p.avCostTiesOf(mic.id), [base.id]);
      expect(p.avCostTiesOf(base.id), [mic.id]);

      // Removing the base asks first, naming the mic.
      await tester.ensureVisible(
          find.byKey(ValueKey('item_delete_${base.id}')));
      await tester.tap(find.byKey(ValueKey('item_delete_${base.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cost_tie_confirm')), findsOneWidget);
      expect(find.textContaining('Tied to Ceiling mic'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(p.avCost.items.map((i) => i.id), contains(base.id));

      await tester.tap(find.byKey(ValueKey('item_delete_${base.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cost_tie_confirm_go')));
      await tester.pumpAndSettle();
      expect(p.avCost.items.map((i) => i.id), isNot(contains(base.id)));

      // The mic still names it, until untied.
      // The page shrank by a row, so let it settle before looking for it.
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(ValueKey('furnished_${mic.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('furnished_${mic.id}')));
      await tester.pumpAndSettle();
      expect(find.text('An item no longer on the quote'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('cost_untie_${mic.id}_${base.id}')));
      await tester.pumpAndSettle();
      expect(p.avCostTiesOf(mic.id), isEmpty);
    });
  });

  group('design options on disk', () {
    late Directory dir;
    late String config;

    String costFile(String configPath) =>
        roomFilePath(configPath, 'cost.json');
    String racksFile(String configPath) =>
        roomFilePath(configPath, 'racks.json');

    setUp(() {
      dir = Directory.systemTemp.createTempSync('rcb_design_options');
      config = path.join(dir.path, 'R1', 'config.json');
      Directory(path.dirname(config)).createSync(recursive: true);
      File(config).writeAsStringSync(jsonEncode({
        'SYSTEM_SETUP': {'gui_full_room_name': 'Room 1'},
      }));
      ensureRoomFolder(config);
      File(costFile(config)).writeAsStringSync('{"cost": {"notes": "A"}}');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('a new option files the room away and becomes the room', () {
      expect(readDesignOptions(config).options, isEmpty);
      final options = createDesignOption(
        config,
        name: 'Camera package',
        firstName: 'Base',
        total: 100,
      );
      expect(options.options.map((o) => o.name), ['Base', 'Camera package']);
      expect(options.activeOption?.name, 'Camera package');
      expect(readDesignOptions(config).active, options.active);
      // Both copies are the room as it was, laid out as rooms of their own.
      for (final o in options.options) {
        final kept = designOptionConfigPath(config, o.id);
        expect(File(kept).existsSync(), isTrue);
        expect(File(costFile(kept)).readAsStringSync(), contains('"A"'));
        expect(readRoomFromDisk(kept).ok, isTrue);
      }
    });

    test('choosing swaps the files both ways, parts and all', () {
      final options = createDesignOption(config, name: 'B');
      final base = options.options.first.id;
      final b = options.active;
      // Worked on as B: a different quote, and racks the base never had.
      File(costFile(config)).writeAsStringSync('{"cost": {"notes": "B"}}');
      File(racksFile(config)).writeAsStringSync('{"racks": []}');

      final back = chooseDesignOption(config, base, total: 250)!;
      expect(back.active, base);
      expect(back.byId(b)!.total, 250, reason: 'B kept with its total');
      expect(File(costFile(config)).readAsStringSync(), contains('"A"'));
      expect(File(racksFile(config)).existsSync(), isFalse);
      expect(
        File(costFile(designOptionConfigPath(config, b))).readAsStringSync(),
        contains('"B"'),
      );
      // Backed up before it was written over.
      expect(
        Directory(path.join(roomFolderPath(config), 'backups')).existsSync(),
        isTrue,
      );

      chooseDesignOption(config, b);
      expect(File(costFile(config)).readAsStringSync(), contains('"B"'));
      expect(File(racksFile(config)).existsSync(), isTrue);
      expect(chooseDesignOption(config, 'nope'), isNull);
    });

    test('renamed, and removed into a folder of its own', () {
      final options = createDesignOption(config, name: 'B');
      final base = options.options.first.id;
      renameDesignOption(config, base, 'As built');
      expect(readDesignOptions(config).byId(base)!.name, 'As built');

      // The chosen one is the room and stays.
      expect(
        removeDesignOption(config, options.active).options.length,
        2,
      );
      final left = removeDesignOption(config, base);
      expect(left.options.map((o) => o.id), [options.active]);
      expect(Directory(designOptionFolder(config, base)).existsSync(), isFalse);
      final removed = Directory(path.join(
          roomFolderPath(config), kDesignOptionsFolder, 'removed'));
      expect(removed.listSync(), hasLength(1));
    });
  });

  group('design options in the app', () {
    late UiSchema schema;
    late AvDeviceLibrary library;

    setUpAll(() async {
      schema = await UiSchema.load(explicitPath: 'ui_schema.json');
      library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
    });

    test('the open room switches between options and prices the other',
        () async {
      final dir = Directory.systemTemp.createTempSync('rcb_design_app');
      addTearDown(() => dir.deleteSync(recursive: true));
      final p = AppStateProvider(autoLoadSettings: false)
        ..uiSchema = schema
        ..avDeviceLibrary = library
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Room 1'},
        }
        ..currentConfigPath = path.join(dir.path, 'R1', 'config.json');
      Directory(path.join(dir.path, 'R1')).createSync(recursive: true);
      p.loadAvFlowForCurrentConfig();
      p.addAvCostExtraEquipment(description: 'Projector', unitPrice: 1000);
      await p.saveCurrentConfigToFile();
      p.markRoomSaved();

      expect(await p.createRoomDesignOption('Camera', firstName: 'Base'), '');
      expect(p.roomDesignOptions.activeOption?.name, 'Camera');
      p.addAvCostExtraEquipment(description: 'Camera', unitPrice: 500);
      expect(p.roomCost.grandTotal, 1500);

      // Unsaved work is saved into Camera before Base comes in.
      final base = p.roomDesignOptions.options.first.id;
      expect(await p.chooseRoomDesignOption(base), '');
      expect(p.roomDesignOptions.active, base);
      expect(p.avCost.extraEquipment.map((i) => i.description), ['Projector']);
      expect(p.roomCost.grandTotal, 1000);

      final camera = p.roomDesignOptions.options.last.id;
      expect(p.roomDesignOptions.byId(camera)!.total, 1500);
      p.designOptionTotal(p.currentConfigPath, camera);
      await pumpEventQueue();
      for (var i = 0;
          i < 50 && p.designOptionTotal(p.currentConfigPath, camera) == null;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(p.designOptionTotal(p.currentConfigPath, camera), 1500);

      expect(await p.chooseRoomDesignOption(camera), '');
      expect(p.avCost.extraEquipment.map((i) => i.description),
          ['Projector', 'Camera']);
    });
  });
}
