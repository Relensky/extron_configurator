import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/device_recheck_dialog.dart';
import 'package:extron_configurator/labor_rates.dart';

/// The two screens added for "the device isn't in the rack builder" and "let
/// me find a rate by its letters", driven the way a user drives them.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(
          model: 'Switcher Y',
          category: 'Switcher',
          rackUnits: 2,
          powerWatts: 90,
          price: 2500,
          ports: [],
        ),
      );
    return p;
  }

  Future<void> pump(
    WidgetTester tester,
    AppStateProvider provider,
    Widget child,
  ) async {
    tester.view.physicalSize = const Size(1800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A page whose only job is to carry the button under test.
  Widget host() => Builder(
    builder: (context) => Center(child: deviceRecheckButton(context)),
  );

  group('the recheck dialog', () {
    testWidgets('finds a device whose rack height is still the old copy and '
        'updates it', (tester) async {
      final p = room();
      // The order that causes this: the box goes on the diagram, and the rack
      // height is filled in on the catalog afterwards.
      p.addAvNode(
        const AvNode(
          id: 'S1',
          label: 'Main switcher',
          model: 'Switcher Y',
          pos: Offset.zero,
          ports: [],
        ),
      );
      await pump(tester, p, host());

      await tester.tap(find.text('Recheck devices'));
      await tester.pumpAndSettle();

      expect(find.text('Rack height 0U → 2U · Power 0 W → 90 W'), findsOneWidget);
      expect(find.text('1 to look at'), findsOneWidget);

      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();

      expect(p.avNodeById('S1')!.rackUnits, 2);
      // Which is what puts it in the rack builder's list.
      expect(p.avNodes.where((n) => n.rackUnits > 0).length, 1);
      expect(find.text('Updated'), findsOneWidget);
    });

    testWidgets('moves a quoted-but-undrawn line onto the room', (
      tester,
    ) async {
      final p = room();
      p.addAvCostExtraEquipment(
        catalogModel: 'Switcher Y',
        description: 'Spare switcher',
      );
      await pump(tester, p, host());

      await tester.tap(find.text('Recheck devices'));
      await tester.pumpAndSettle();
      expect(find.text('Quoted on the Cost tab, never drawn'), findsOneWidget);

      await tester.tap(find.text('Put on room'));
      await tester.pumpAndSettle();

      expect(p.avNodes.single.model, 'Switcher Y');
      expect(p.avNodes.single.rackUnits, 2);
      // Counted once: the cost line goes when the device arrives.
      expect(p.avCost.extraEquipment, isEmpty);
    });

    testWidgets('un-racks a device whose frame has been deleted', (
      tester,
    ) async {
      final p = room();
      p.addAvNode(
        const AvNode(
          id: 'S1',
          label: 'Main switcher',
          model: 'Switcher Y',
          pos: Offset.zero,
          rackUnits: 2,
          powerWatts: 90,
          ports: [],
        ),
      );
      // Invisible twice over: no elevation can draw it, and the "to place"
      // list skips it because the room thinks it is already racked.
      p.avRackSlots['S1'] = const RackSlot(rackId: 'GONE', startU: 3);

      await pump(tester, p, host());
      await tester.tap(find.text('Recheck devices'));
      await tester.pumpAndSettle();

      expect(find.text('Racked into nothing'), findsOneWidget);
      await tester.tap(find.text('Un-rack'));
      await tester.pumpAndSettle();

      expect(p.avRackSlots, isEmpty);
    });

    testWidgets('says so plainly when there is nothing to fix', (tester) async {
      final p = room();
      p.addAvNode(
        const AvNode(
          id: 'S1',
          label: 'Main switcher',
          model: 'Switcher Y',
          pos: Offset.zero,
          rackUnits: 2,
          powerWatts: 90,
          ports: [],
        ),
      );
      await pump(tester, p, host());

      await tester.tap(find.text('Recheck devices'));
      await tester.pumpAndSettle();

      expect(find.text('Everything checks out.'), findsOneWidget);
      expect(find.text('Update'), findsNothing);
    });
  });

  group('the job type picker', () {
    AppStateProvider withRates() {
      final p = room();
      p.laborRates = LaborRateBook(
        rates: const [
          LaborRate(
            id: 'tss3ns',
            name: '0482 Technology Support Specialist III — Non-state',
            hourlyRate: 83.76,
          ),
          LaborRate(
            id: 'tss4ns',
            name: '0483 Technology Support Specialist IV — Non-state',
            hourlyRate: 93.97,
          ),
          LaborRate(
            id: 'elec',
            name: '6533 Electrician — Non-state',
            hourlyRate: 84.41,
          ),
        ],
      );
      return p;
    }

    testWidgets('shows each role\'s shorthand and filters on it', (
      tester,
    ) async {
      final p = withRates();
      p.addAvCostLabor();
      await pump(tester, p, const CostEstimateView());

      // The closed cell is one ellipsized line — the clipped second line was
      // the original complaint.
      final cell = tester.widget<Text>(
        find.text('0482 Technology Support Specialist III — Non-state').first,
      );
      expect(cell.maxLines, 1);
      expect(cell.overflow, TextOverflow.ellipsis);

      await tester.tap(find.text('0482 Technology Support Specialist III — '
          'Non-state'));
      await tester.pumpAndSettle();

      // Shown, not just matched.
      expect(find.text('TSSIII'), findsOneWidget);
      expect(find.text('TSSIV'), findsOneWidget);
      expect(find.text('E'), findsOneWidget);

      // The page underneath is full of text fields; the search box is the
      // dialog's own.
      final search = find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          )
          .first;

      await tester.enterText(search, 'tss');
      await tester.pumpAndSettle();
      expect(find.text('TSSIII'), findsOneWidget);
      expect(find.text('TSSIV'), findsOneWidget);
      expect(find.text('E'), findsNothing);

      // And the level narrows it to one.
      await tester.enterText(search, 'tssIII');
      await tester.pumpAndSettle();
      expect(find.text('TSSIII'), findsOneWidget);
      expect(find.text('TSSIV'), findsNothing);

      await tester.tap(find.text('TSSIII'));
      await tester.pumpAndSettle();
      expect(p.avCost.labor.single.rateId, 'tss3ns');
    });
  });
}
