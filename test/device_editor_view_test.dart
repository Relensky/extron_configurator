import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/device_editor_view.dart';

/// The two new screens, driven the way a user drives them: the catalog editor
/// where a model's connectors, rack height, power and price are filled in, and
/// the cost page where those prices turn into a room total.
void main() {
  AppStateProvider withCatalog() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(
          model: 'Switcher Y',
          manufacturer: 'Extron',
          rackUnits: 2,
          powerWatts: 90,
          price: 2500,
          ports: [
            AvPort(
              id: 'in_hdmi_1',
              label: 'HDMI IN 1',
              signal: SignalType.hdmi,
              direction: PortDirection.input,
              side: PortSide.left,
            ),
          ],
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

  group('the device editor', () {
    testWidgets('lists the catalog and opens a model for editing', (
      tester,
    ) async {
      final provider = withCatalog();
      await pump(tester, provider, const DeviceEditorView());

      expect(tester.takeException(), isNull);
      expect(find.text('Switcher Y'), findsOneWidget);
      // Rack height, connector counts and price are all on the list row: the
      // four facts the catalog exists to carry.
      expect(find.textContaining('2U'), findsOneWidget);
      expect(find.textContaining('1 in / 0 out'), findsOneWidget);
      expect(find.text(r'$2,500.00'), findsOneWidget);

      await tester.tap(find.text('Switcher Y'));
      await tester.pumpAndSettle();
      expect(find.text('Connectors — 1 in / 0 out'), findsOneWidget);
    });

    testWidgets('edits power and price straight into the catalog', (
      tester,
    ) async {
      final provider = withCatalog();
      await pump(tester, provider, const DeviceEditorView());
      await tester.tap(find.text('Switcher Y'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Power'), '120');
      await tester.pumpAndSettle();
      // Two published prices per entry now, so the box is named for the tier
      // it holds rather than the generic "Unit price".
      await tester.enterText(
        find.widgetWithText(TextField, 'MSRP'),
        '2799.5',
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Education price'),
        '2100',
      );
      await tester.pumpAndSettle();

      final entry = provider.avDeviceLibrary.templateForModel('Switcher Y')!;
      expect(entry.powerWatts, 120);
      expect(entry.price, 2799.5);
      expect(entry.educationPrice, 2100);
      expect(tester.takeException(), isNull);
      // Nothing has been written to disk, so the unsaved marker is up.
      expect(find.text('Unsaved changes'), findsOneWidget);
    });

    testWidgets('adds an output connector', (tester) async {
      final provider = withCatalog();
      await pump(tester, provider, const DeviceEditorView());
      await tester.tap(find.text('Switcher Y'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Add output'));
      await tester.pumpAndSettle();

      final entry = provider.avDeviceLibrary.templateForModel('Switcher Y')!;
      expect(entry.outputCount, 1);
      expect(entry.ports.last.direction, PortDirection.output);
      expect(entry.ports.last.side, PortSide.right);
    });

    testWidgets('a new model joins the catalog', (tester) async {
      final provider = withCatalog();
      await pump(tester, provider, const DeviceEditorView());

      await tester.tap(find.widgetWithText(OutlinedButton, 'New device'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Model name'),
        'Ceiling Mic Array',
      );
      await tester.tap(find.widgetWithText(ElevatedButton, 'Create'));
      await tester.pumpAndSettle();

      expect(
        provider.avDeviceLibrary.templateForModel('Ceiling Mic Array'),
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('the cost page', () {
    AppStateProvider pricedRoom() {
      final p = withCatalog()
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      p.loadAvFlowForCurrentConfig();
      p.addAvNode(
        const AvNode(
          id: 'SWITCHERDEVICE_1',
          label: 'Main Switcher',
          model: 'Switcher Y',
          pos: Offset(40, 60),
          ports: [],
        ),
      );
      return p;
    }

    testWidgets('prices the diagram from the catalog', (tester) async {
      final provider = pricedRoom();
      await pump(
        tester,
        provider,
        CostEstimateView(model: buildAvFlowModel(provider)),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Main Switcher'), findsOneWidget);
      expect(find.text('Catalog'), findsOneWidget);
      expect(find.text(r'$2,500.00'), findsWidgets);
    });

    testWidgets('a fee and a tax rate reach the total', (tester) async {
      final provider = pricedRoom();
      await pump(
        tester,
        provider,
        CostEstimateView(model: buildAvFlowModel(provider)),
      );

      await tester.tap(find.widgetWithText(TextButton, 'Add fee'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'e.g. Freight'), 'Freight');
      await tester.pumpAndSettle();

      // The fee's percent box is the one numeric field with a % suffix that
      // isn't the tax rate (which carries a label).
      await tester.enterText(
        find.widgetWithText(TextField, 'Tax rate'),
        '10',
      );
      await tester.pumpAndSettle();

      expect(provider.avCost.fees.single.name, 'Freight');
      expect(provider.avCost.taxPercent, 10);
      // 2500 + 10% tax, no fee percentage typed yet.
      expect(find.text(r'$2,750.00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a typed price overrides the catalog for this room only', (
      tester,
    ) async {
      final provider = pricedRoom();
      await pump(
        tester,
        provider,
        CostEstimateView(model: buildAvFlowModel(provider)),
      );

      await tester.enterText(
        find.widgetWithText(TextField, '2500'),
        '1900',
      );
      await tester.pumpAndSettle();

      expect(provider.avCost.priceOverrides['model:switcher y'], 1900);
      // The catalog itself is untouched — a quoted price is a fact about the
      // job, not about the model.
      expect(
        provider.avDeviceLibrary.templateForModel('Switcher Y')!.price,
        2500,
      );
      expect(find.text('Room price'), findsOneWidget);
    });
  });
}
