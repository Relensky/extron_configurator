import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/base_costs.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/campus_lifecycle.dart';
import 'package:extron_configurator/model_standards_view.dart';

/// THE CURRENT MODELS TAB, ON SCREEN.
///
/// The year grid is built entirely out of one number per kind of thing - what a
/// projector costs - and that number had no provenance: somebody typed it onto
/// the base cost card once, and a whole estate was budgeted off it for as long
/// as nobody re-typed it. This is where it gets decided in front of the
/// evidence, and what is held here is that the evidence is actually shown and
/// that accepting it writes the card the reports already price from.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_standards_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A building with three drawn projectors: two of a retired model and one
  /// current.
  String job(String stem) {
    final project = BuildingProject(name: stem, building: stem);
    final file = path.join(dir.path, '${stem}_project.json');

    for (final (i, model) in [
      'PowerLite L610U',
      'PowerLite L610U',
      'PowerLite L775U',
    ].indexed) {
      final config = path.join(dir.path, '${stem}_r${i}_config.json');
      File(config).writeAsStringSync(
        jsonEncode({
          'SYSTEM_SETUP': {'gui_full_room_name': '$stem 10$i'},
        }),
      );
      File(path.join(dir.path, '${stem}_r${i}_config_av_flow.json'))
          .writeAsStringSync(
        jsonEncode({
          'nodes': [
            AvNode(
              id: 'PROJECTORDEVICE_1',
              label: 'Projector',
              model: model,
              pos: Offset.zero,
              ports: const [],
              installedOn: DateTime(2018, 6, 1),
            ).toJson(),
          ],
        }),
      );
      project.rooms.add(
        ProjectRoomRef(id: '$stem-r$i', configPath: config),
      );
    }

    File(file).writeAsStringSync(jsonEncode(project.toJson()));
    return file;
  }

  AppStateProvider withCatalog() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(
          model: 'PowerLite L610U',
          manufacturer: 'Epson',
          category: 'Projector',
          price: 4000,
          retired: true,
          replacedBy: 'PowerLite L775U',
          ports: [],
        ),
      )
      ..upsert(
        const AvDeviceTemplate(
          model: 'PowerLite L775U',
          manufacturer: 'Epson',
          category: 'Projector',
          price: 6100,
          educationPrice: 5200,
          ports: [],
        ),
      );
    p.baseCosts = BaseCostBook(costs: []);
    return p;
  }

  /// Reads an estate and puts the current-models pane on screen.
  Future<AppStateProvider> pumpPane(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final provider = withCatalog();
    late final CampusLifecycle campus;
    await tester.runAsync(() async {
      campus = await readCampus(
        provider: provider,
        projectPaths: [job('SCI')],
        asOf: DateTime(2026, 6, 15),
      );
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CampusModelStandards(
                campus: campus,
                onChanged: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return provider;
  }

  group('what the estate holds', () {
    testWidgets('a card per kind of thing, with what it is budgeted at', (
      tester,
    ) async {
      await pumpPane(tester);
      expect(
        find.byKey(const ValueKey('standard_card_Projector')),
        findsOneWidget,
      );
      expect(find.text('Projector'), findsWidgets);
      // Three positions, all priced at the successor's 6,100 - two of them
      // hold a model nobody can buy.
      expect(find.textContaining('3 positions'), findsOneWidget);
      expect(find.textContaining('2 holding retired gear'), findsOneWidget);
    });

    testWidgets('a category nobody has benchmarked says so', (tester) async {
      await pumpPane(tester);
      expect(
        find.textContaining('The base cost card has no figure for this'),
        findsOneWidget,
      );
    });

    testWidgets('the models in them are one press away', (tester) async {
      await pumpPane(tester);
      // Collapsed by default: on a category with thirty models this is the
      // longest thing on the page and not what the card is read for.
      expect(find.textContaining('PowerLite L610U (2)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('standard_models_Projector')));
      await tester.pumpAndSettle();

      expect(find.textContaining('2 × PowerLite L610U'), findsOneWidget);
      expect(
        find.textContaining('replaced by PowerLite L775U'),
        findsOneWidget,
      );
    });
  });

  group('setting the recommended cost', () {
    testWidgets('there is nothing to accept until a model is picked', (
      tester,
    ) async {
      await pumpPane(tester);
      expect(
        find.byKey(const ValueKey('standard_pick_Projector')),
        findsOneWidget,
      );
      // THE COMPARISON COMES FIRST. Nothing can be committed before the
      // arithmetic is on screen.
      expect(
        find.byKey(const ValueKey('standard_apply_Projector')),
        findsNothing,
      );
    });

    testWidgets('the card is written, with the model and the date on it', (
      tester,
    ) async {
      // Driven through the model rather than the picker dialog: what is being
      // held is that accepting writes the card the reports price from.
      final provider = await pumpPane(tester);
      provider.baseCosts.upsert(
        BaseCost(
          category: 'Projector',
          price: 6100,
          educationPrice: 5200,
          standardModel: 'PowerLite L775U',
          standardSetOn: DateTime(2026, 6, 15),
        ),
      );
      provider.baseCostsChanged();
      await tester.pumpAndSettle();

      final card = provider.baseCosts.byCategory('Projector')!;
      expect(card.price, 6100);
      expect(card.standardModel, 'PowerLite L775U');
      expect(card.standardAgeYears(DateTime(2026, 6, 15)), 0);

      // And the pane says what it is benchmarked on rather than that it has
      // no figure.
      expect(
        find.textContaining('Benchmarked on PowerLite L775U'),
        findsOneWidget,
      );
      expect(
        find.textContaining('The base cost card has no figure'),
        findsNothing,
      );
    });

    testWidgets('the example says what the estate would come to', (
      tester,
    ) async {
      final provider = await pumpPane(tester);
      provider.baseCosts.upsert(
        BaseCost(
          category: 'Projector',
          price: 6100,
          standardModel: 'PowerLite L775U',
          standardSetOn: DateTime(2026, 6, 15),
        ),
      );
      provider.baseCostsChanged();
      await tester.pumpAndSettle();

      // Three of them at 6,100. The gap against what the plan budgets is the
      // whole reading - here it is nil, because the plan already prices the
      // retired ones at their successor.
      expect(find.textContaining('3 × ='), findsOneWidget);
      expect(
        find.textContaining('Exactly what the plan already budgets'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('standard_apply_Projector')),
        findsOneWidget,
      );
    });
  });
}
