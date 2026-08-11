import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/live_text_field.dart';
import 'package:extron_configurator/print_mode.dart';

/// The image of the estimate is a document, not a photograph of a workspace.
/// Three things have to hold: it carries the money and none of the furniture,
/// it is as long as the estimate rather than as tall as the window, and it is
/// whichever way round was asked for.
void main() {
  AvNode device(String id, String label, String model) => AvNode(
    id: id,
    label: label,
    model: model,
    pos: Offset.zero,
    ports: const [],
  );

  AppStateProvider room({int extraLines = 0}) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(model: 'Display X', price: 1000, ports: []),
      );
    p.addAvNode(device('D1', 'Display', 'Display X'));
    p.addAvCostFee(name: 'Freight', percent: 5);
    p.setAvCostTax(percent: 8.25, label: 'State tax');
    for (int i = 0; i < extraLines; i++) {
      p.addAvCostItem(description: 'Sundry $i', qty: 1, unitPrice: 25);
    }
    return p;
  }

  Future<void> pump(
    WidgetTester tester,
    AppStateProvider p, {
    Brightness? capturing,
  }) async {
    tester.view.physicalSize = const Size(1700, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            // Keyed on the mode: without it Flutter reuses the same State
            // across the two pumps and the second one never re-reads the
            // brightness.
            body: CostEstimateView(
              key: ValueKey(capturing),
              debugCaptureBrightness: capturing,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The RepaintBoundary the capture actually targets.
  Finder capturedSheet() => find
      .descendant(
        of: find.byType(OverflowBox),
        matching: find.byType(RepaintBoundary),
      )
      .first;

  group('print mode', () {
    testWidgets('a live field prints its value instead of a box', (
      tester,
    ) async {
      Widget host(bool printing) => MaterialApp(
        home: Scaffold(
          body: PrintMode(
            printing: printing,
            child: LiveTextField(
              fieldId: 'x',
              initial: '',
              // Blank means the row is taking the catalog figure, and the
              // catalog figure is the hint — so the hint is what has to end
              // up on the page.
              hint: '2500',
              prefix: r'$',
              numeric: true,
              onChanged: (_) {},
            ),
          ),
        ),
      );

      await tester.pumpWidget(host(false));
      expect(find.byType(TextField), findsOneWidget);

      await tester.pumpWidget(host(true));
      expect(find.byType(TextField), findsNothing);
      expect(find.text(r'$2500'), findsOneWidget);
    });

    testWidgets('a taxable checkbox prints as a word', (tester) async {
      Widget host(bool printing) => MaterialApp(
        home: Scaffold(
          body: PrintMode(
            printing: printing,
            child: PrintableCheckbox(value: true, onChanged: (_) {}),
          ),
        ),
      );

      await tester.pumpWidget(host(false));
      expect(find.byType(Checkbox), findsOneWidget);

      await tester.pumpWidget(host(true));
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('Yes'), findsOneWidget);
    });
  });

  group('the captured sheet', () {
    testWidgets('drops the workspace and keeps the money', (tester) async {
      final p = room();
      await pump(tester, p);

      // On screen: input boxes and Add buttons. ("Add fee" is not checked
      // here — the fees card is below the fold and the on-screen list is
      // lazy, which is the very reason the capture cannot use it.)
      expect(find.byType(TextField), findsWidgets);
      expect(find.widgetWithText(TextButton, 'Add line'), findsOneWidget);

      await pump(tester, p, capturing: Brightness.light);

      // In the capture frame: no inputs, no buttons, no icons.
      expect(find.byType(TextField), findsNothing);
      expect(find.widgetWithText(TextButton, 'Add line'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Add crew'), findsNothing);
      // Built, because the capture frame is not lazy — and still hidden.
      expect(find.widgetWithText(TextButton, 'Add fee'), findsNothing);
      expect(find.text('Fees'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(SegmentedButton<PricingTier>), findsNothing);

      // But the estimate is all still there.
      expect(find.text('Room Cost Estimate'), findsOneWidget);
      expect(find.text('Display'), findsWidgets);
      expect(find.textContaining('TOTAL'), findsWidgets);
      // The tier and tax settings say themselves in prose instead.
      expect(find.textContaining('Priced at'), findsOneWidget);
    });

    testWidgets('is as long as the estimate, not as tall as the window', (
      tester,
    ) async {
      // Far more rows than a 900px window can hold.
      final p = room(extraLines: 40);
      await pump(tester, p, capturing: Brightness.light);

      final captured = tester.getSize(capturedSheet());
      // The window is 900 tall. A ListView — even a shrinkWrapped one — is a
      // viewport and would have stopped there.
      expect(
        captured.height,
        greaterThan(900),
        reason: 'the capture must run past the bottom of the window',
      );
      expect(find.text('Sundry 39'), findsOneWidget);
    });

    testWidgets('light and dark are the image\'s, not the app\'s', (
      tester,
    ) async {
      final p = room();

      Color paper() => tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(OverflowBox),
              matching: find.byType(Container),
            ),
          )
          .firstWhere((c) => c.color != null)
          .color!;

      await pump(tester, p, capturing: Brightness.light);
      expect(paper(), Colors.white);

      await pump(tester, p, capturing: Brightness.dark);
      expect(paper().computeLuminance(), lessThan(0.2));
    });

    testWidgets('the button offers both ways round', (tester) async {
      await pump(tester, room());
      await tester.tap(find.byType(PopupMenuButton<Brightness>));
      await tester.pumpAndSettle();
      expect(find.text('Light image'), findsOneWidget);
      expect(find.text('Dark image'), findsOneWidget);
    });
  });
}
