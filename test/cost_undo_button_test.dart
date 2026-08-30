import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/ui_schema.dart';

/// THE UNDO BUTTON ON THE COST TAB, PRESSED THE WAY SOMEBODY PRESSES IT.
///
/// The provider-level tests say the estimate can be taken back. This one says
/// the BUTTON does it, on a price typed into the box, with the box showing the
/// result — which is the whole of what "the undo button is not working" means.
///
/// Two failures live in the gap between those two statements. A price box
/// calls its provider on every keystroke, so `1499` was four undo steps and
/// one press took the room back to `149` — a button that appears to do
/// nothing. And a box that kept showing what was typed after the value behind
/// it had gone back would be the same complaint from the other end.
void main() {
  late UiSchema schema;
  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..uiSchema = schema
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(
          model: 'PowerLite L630U',
          manufacturer: 'Epson',
          category: 'Projector',
          price: 2200,
          ports: [],
        ),
      );
    p.addAvNode(
      const AvNode(
        id: 'PROJECTORDEVICE_1',
        label: 'Projector',
        model: 'PowerLite L630U',
        pos: Offset.zero,
        ports: [],
      ),
    );
    return p;
  }

  Future<void> pump(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Presses [button] and lets the bar it raises run its course.
  ///
  /// Every undo in the app says what it did, and the bar that says it closes
  /// itself on a timer — so a test that stopped at the assertion would leave
  /// that timer pending and fail on the way out.
  Future<void> press(WidgetTester tester, Finder button) async {
    await tester.tap(button);
    await tester.pumpAndSettle(const Duration(seconds: 6));
  }

  /// The estimate's OWN pair, by key. The app has several undo arrows and
  /// they mean different things — finding one by its icon would be the same
  /// mistake this whole file is about.
  Finder undo() => find.byKey(const ValueKey('cost_undo'));
  Finder redo() => find.byKey(const ValueKey('cost_redo'));

  testWidgets('a price typed digit by digit goes back in one press',
      (tester) async {
    final p = room();
    await pump(tester, p);

    final key = p.avCost.priceOverrides.keys.toList();
    expect(key, isEmpty, reason: 'nothing typed yet');

    // Typed the way a person types it: the box calls the provider on every
    // keystroke.
    for (final typed in [1.0, 14.0, 149.0, 1499.0]) {
      p.setAvCostPrice('model:powerlite l630u', typed);
    }
    await tester.pumpAndSettle();
    expect(p.avCost.priceOverrides['model:powerlite l630u'], 1499);

    expect(undo(), findsOneWidget, reason: 'the pair is on the page');
    await press(tester, undo());

    // ONE PRESS, THE WHOLE PRICE. Not '149'.
    expect(p.avCost.priceOverrides['model:powerlite l630u'], isNull);
  });

  testWidgets('and the box on screen goes back with it', (tester) async {
    final p = room();
    await pump(tester, p);

    /// What every input box on the page currently holds.
    ///
    /// Read off the controllers rather than through a text finder: a text
    /// finder also matches a field's HINT, and the hint on a price box is the
    /// figure the row resolves to - which is the same number while an override
    /// is typed over it. That would make the finder agree with itself for the
    /// wrong reason.
    List<String> boxes() => [
          for (final e in find.byType(EditableText).evaluate())
            (e.widget as EditableText).controller.text,
        ];

    p.setAvCostPrice('model:powerlite l630u', 1499);
    await tester.pumpAndSettle();
    expect(boxes(), contains('1499'), reason: 'the typed figure is in the box');

    await press(tester, undo());

    // A box still showing 1499 over a room that no longer holds it is the
    // same complaint read from the other end.
    expect(boxes(), isNot(contains('1499')));
  });

  testWidgets('Redo puts the price back', (tester) async {
    final p = room();
    await pump(tester, p);

    p.setAvCostPrice('model:powerlite l630u', 1499);
    await tester.pumpAndSettle();
    await press(tester, undo());

    await press(tester, redo());

    expect(p.avCost.priceOverrides['model:powerlite l630u'], 1499);
  });

  testWidgets('the pair is dark on a quote nobody has touched', (tester) async {
    final p = room();
    await pump(tester, p);

    // An Undo that is lit and does nothing when pressed is the failure this
    // whole file is about.
    expect(tester.widget<OutlinedButton>(undo()).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(redo()).onPressed, isNull);
  });
}
