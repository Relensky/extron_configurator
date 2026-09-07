import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/assumed_cycle_bar.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/base_costs.dart';
import 'package:extron_configurator/equipment_lifecycle.dart';
import 'package:extron_configurator/model_standards_view.dart';
import 'package:extron_configurator/lifecycle_view.dart';
import 'package:extron_configurator/project_view.dart';

/// ============================================================================
///  CURRENT MODELS, AT EVERY LEVEL
/// ============================================================================
///  "What would we buy this year" was a question only the estate could be
///  asked. That is the level furthest from the person who can answer it: the
///  one who knows what the projector in room 101 actually is is standing in
///  room 101, or looking at the single job they were handed - not assembling
///  twelve buildings off a shared drive.
///
///  So the same pane now hangs off all three plans, over the same arithmetic.
///  What is held here is that it reads the right positions at each level - one
///  room's, one building's - that it says which level it is describing, and
///  that switching to it puts the year grid away rather than stacking two
///  documents on one screen.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_models_level_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A catalog with this year's projector in it, and the one it replaced.
  AvDeviceLibrary catalog() => AvDeviceLibrary.empty()
    ..upsert(
      const AvDeviceTemplate(
        model: 'PROJ-1',
        manufacturer: 'Epson',
        category: 'Projector',
        price: 4000,
        retired: true,
        replacedBy: 'PROJ-2',
        ports: [],
      ),
    )
    ..upsert(
      const AvDeviceTemplate(
        model: 'PROJ-2',
        manufacturer: 'Epson',
        category: 'Projector',
        price: 6100,
        educationPrice: 5200,
        ports: [],
      ),
    );

  AvNode box(String id, String model) => AvNode(
    id: id,
    label: id,
    model: model,
    pos: Offset.zero,
    ports: const [],
    installedOn: DateTime(2016, 6, 1),
  );

  void sized(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  // -------------------------------------------------------------------------
  //  ONE ROOM
  // -------------------------------------------------------------------------

  group('a room', () {
    AppStateProvider room({BaseCostBook? cards}) {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {
            'gui_full_room_name': 'Bessey 101',
            'gve_bldg': 'BSS',
            'gve_room': '101',
          },
        };
      p.avDeviceLibrary = catalog();
      p.baseCosts = cards ?? BaseCostBook(costs: []);
      p.loadAvFlowForCurrentConfig();
      p.addAvNode(box('PROJECTORDEVICE_1', 'PROJ-1'));
      p.addAvNode(box('DISPLAYDEVICE_1', 'DISP-1'));
      return p;
    }

    Future<void> pump(WidgetTester tester, AppStateProvider p) async {
      sized(tester);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: LifecycleView())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Current models'));
      await tester.pumpAndSettle();
    }

    testWidgets('reads its own positions, not an estate of them', (
      tester,
    ) async {
      await pump(tester, room());

      expect(
        find.byKey(const ValueKey('room_lifecycle_standards')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('standard_card_Projector')),
        findsOneWidget,
      );
      // ONE of them, and it is the room being talked about. A pane that said
      // "estate" while standing in one room would be describing something the
      // reader cannot see.
      expect(find.textContaining('1 position'), findsWidgets);
      expect(
        find.textContaining('Every kind of thing this room holds'),
        findsOneWidget,
      );
    });

    testWidgets('says which of what is in here the catalog has retired', (
      tester,
    ) async {
      await pump(tester, room());
      expect(find.textContaining('1 holding retired gear'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('standard_models_Projector')));
      await tester.pumpAndSettle();
      expect(find.textContaining('replaced by PROJ-2'), findsOneWidget);
    });

    testWidgets('the arithmetic is this room, at this year model', (
      tester,
    ) async {
      // A card already benchmarked, so the comparison is on screen without the
      // picker: one projector at this year's model, against what the plan
      // budgets for the one that is in there.
      await pump(
        tester,
        room(
          cards: BaseCostBook(
            costs: [
              BaseCost(
                category: 'Projector',
                price: 6100,
                standardModel: 'PROJ-2',
                standardSetOn: DateTime.now(),
              ),
            ],
          ),
        ),
      );

      expect(find.textContaining('Benchmarked on PROJ-2'), findsOneWidget);
      expect(find.textContaining('across this room'), findsOneWidget);
    });

    testWidgets('the cycle picker is on the pane, and it moves the year figure',
        (tester) async {
      // One projector at 6,100, dated 2016. On the recorded eight-year cycle
      // that is 762.50 a year to keep; restated onto twenty it is 305.
      final p = room(
        cards: BaseCostBook(
          costs: [
            BaseCost(
              category: 'Projector',
              price: 6100,
              standardModel: 'PROJ-2',
              standardSetOn: DateTime.now(),
            ),
          ],
        ),
      );
      await pump(tester, p);

      expect(
        find.byKey(const ValueKey('room_standards_assumed_cycle')),
        findsOneWidget,
      );
      // THE LUMP SUM IS NOT WHAT MOVES. The same projector costs the same to
      // buy whatever life anybody assumes; what it costs A YEAR is the half
      // the cycle decides, which is why the picker is on this pane.
      expect(
        find.textContaining(r'1 a year on the cycle in force = $763 a year'),
        findsOneWidget,
        reason: '6,100 over the recorded eight-year life',
      );
      expect(find.textContaining(r'= $6,100 across this room'), findsWidgets);

      p.setAssumedLifeCycle(20);
      await tester.pumpAndSettle();

      // Twenty years: the lump sum is the same projector at the same price,
      // and the annual ask has dropped to 6,100 over twenty.
      expect(
        find.textContaining(r'0.1 a year on the cycle in force = $305 a year'),
        findsOneWidget,
        reason: 'the cycle restated the annual figure and nothing else',
      );
      expect(find.textContaining(r'= $6,100 across this room'), findsWidgets);
    });

    testWidgets('the heading and its cycle picker fit a narrow window at 150%',
        (tester) async {
      // The picker rides on the pane's own heading row, and its label is a
      // whole sentence - so this is the case that would overflow it: the
      // reader's type at 150% on a half-width window. An overflow throws and
      // fails this test on its own.
      //
      // THE PANE ON ITS OWN, not the whole tab. The room's plan pane has an
      // overflow of its own at this size that has nothing to do with this
      // work, and a test that pumped the tab would fail on that instead of
      // holding anything about this heading.
      const size = Size(720, 1200);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: room(),
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(1.5),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ModelStandardsPane(
                      items: buildRoomLifecycle(
                        model: buildAvFlowModel(room()),
                        roomName: 'BSS 101',
                      ).items,
                      asOf: DateTime(2026, 6, 15),
                      currency: r'$',
                      scope: 'room',
                      headerAction: AssumedCycleControl(
                        keyPrefix: 'room_standards',
                        assumed: 20,
                        onChanged: (_) {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('room_standards_assumed_cycle')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('standard_card_Projector')),
        findsOneWidget,
      );
    });

    testWidgets('switching panes puts the plan away, and brings it back', (
      tester,
    ) async {
      await pump(tester, room());
      // The survey controls belong to the plan. Left under a pane about
      // prices they would be a second document on one screen.
      expect(find.byKey(const ValueKey('lifecycle_date_room')), findsNothing);

      await tester.tap(find.text('The plan'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('lifecycle_date_room')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('room_lifecycle_standards')),
        findsNothing,
      );
    });
  });

  // -------------------------------------------------------------------------
  //  ONE BUILDING
  // -------------------------------------------------------------------------

  group('a building', () {
    AppStateProvider job() {
      final p = AppStateProvider(autoLoadSettings: false);
      p.avDeviceLibrary = catalog();
      p.baseCosts = BaseCostBook(costs: []);
      p.newProject(name: 'Bessey Hall');
      for (final stem in ['bss101', 'bss103']) {
        final file = '${dir.path}/${stem}_config.json';
        File(file).writeAsStringSync('{"SYSTEM_SETUP":{"gve_room":"$stem"}}');
        File('${dir.path}/${stem}_config_av_flow.json').writeAsStringSync(
          '{"nodes":[{"id":"PROJECTORDEVICE_1","label":"Projector 1",'
          '"model":"PROJ-1","installedOn":"2016-06-01","ports":[]}],'
          '"cables":[]}',
        );
        p.addRoomToProject(file);
      }
      return p;
    }

    Future<void> pump(WidgetTester tester, AppStateProvider p) async {
      sized(tester);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: ProjectView())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project_pane_lifecycle')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Current models'));
      await tester.pumpAndSettle();
    }

    testWidgets('reads the whole job, its rooms rolled up', (tester) async {
      await pump(tester, job());

      expect(find.byKey(const ValueKey('lifecycle_standards')), findsOneWidget);
      // Two rooms, one projector each - and the pane names the building it is
      // a tab of rather than an estate this job may not be on.
      expect(find.textContaining('2 positions'), findsOneWidget);
      expect(find.textContaining('2 holding retired gear'), findsOneWidget);
      expect(
        find.textContaining('Every kind of thing this building holds'),
        findsOneWidget,
      );
    });

    testWidgets('carries the cycle picker, restating the annual ask', (
      tester,
    ) async {
      final p = job();
      p.baseCosts.upsert(
        BaseCost(
          category: 'Projector',
          price: 6100,
          standardModel: 'PROJ-2',
          standardSetOn: DateTime.now(),
        ),
      );
      await pump(tester, p);

      expect(
        find.byKey(const ValueKey('lifecycle_standards_assumed_cycle')),
        findsOneWidget,
      );
      // Two projectors at 6,100 over the recorded eight-year life.
      expect(
        find.textContaining(r'= $1,525 a year to keep'),
        findsOneWidget,
      );

      p.setAssumedLifeCycle(20);
      await tester.pumpAndSettle();

      // The job still costs 12,200 to re-equip; on twenty years it asks for
      // 610 a year instead of 1,525. That gap is the argument a refresh
      // cycle is actually about.
      expect(find.textContaining(r'= $610 a year to keep'), findsOneWidget);
      expect(
        find.textContaining(r'= $12,200 across this building'),
        findsWidgets,
      );
    });

    testWidgets('the year grid is put away while the prices are read', (
      tester,
    ) async {
      await pump(tester, job());
      expect(find.byKey(const ValueKey('lifecycle_spend_chart')), findsNothing);

      await tester.tap(find.text('The plan'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('lifecycle_spend_chart')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('lifecycle_standards')), findsNothing);
    });
  });
}
