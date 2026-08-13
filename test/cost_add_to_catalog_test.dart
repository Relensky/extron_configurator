import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cost_estimate_view.dart';

/// A part enters the building as a line on a quote — somebody is given a figure
/// over the phone and types it on the job in front of them. Promoting that line
/// into the catalog used to be possible only for lines TYPED on this page,
/// which left the commonest case out: the box on the drawing that nobody has
/// ever priced.
///
/// Anything on the estimate can be written to the catalog now. A row already
/// priced FROM the catalog is the one case with nothing to write.
void main() {
  AvNode device(String id, String label, String model) => AvNode(
    id: id,
    label: label,
    model: model,
    pos: Offset.zero,
    ports: const [],
  );

  /// A room with one PRICED display and one unknown box nobody has entered.
  AppStateProvider room() {
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
    p.addAvNode(device('D2', 'Owner switch', 'CAT-9300'));
    return p;
  }

  Future<void> pump(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1900, 1400);
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

  /// The add-to-catalog buttons on the page, in row order.
  Finder addButtons() => find.byWidgetPredicate(
    (w) => w is IconButton && w.icon is Icon &&
        (w.icon as Icon).icon == Icons.library_add_outlined,
  );

  testWidgets('a device on the drawing with no catalog entry can be added',
      (tester) async {
    final p = room();
    await pump(tester, p);

    // Two equipment rows: the priced Display and the unknown switch. The
    // unknown one is the row with a live button.
    final live = tester
        .widgetList<IconButton>(addButtons())
        .where((b) => b.onPressed != null)
        .length;
    expect(live, greaterThan(0),
        reason: 'the unpriced box on the drawing must be addable');

    // The priced one has nothing to promote.
    final dead = tester
        .widgetList<IconButton>(addButtons())
        .where((b) => b.onPressed == null)
        .length;
    expect(dead, greaterThan(0),
        reason: 'a row already priced from the catalog is not offered');
  });

  testWidgets('the dialog opens with the model already filled in',
      (tester) async {
    final p = room();
    await pump(tester, p);

    final button = addButtons().at(
      tester
          .widgetList<IconButton>(addButtons())
          .toList()
          .indexWhere((b) => b.onPressed != null),
    );
    await tester.tap(button, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('Add this line to the catalog'), findsOneWidget);
    // The model off the drawing, not the device's label: the estimate prices
    // by MODEL, so that is the name the entry has to carry to be picked up.
    expect(find.widgetWithText(TextField, 'CAT-9300'), findsOneWidget);
  });

  testWidgets('adding it prices the row off the catalog from then on',
      (tester) async {
    final p = room();
    await pump(tester, p);

    final button = addButtons().at(
      tester
          .widgetList<IconButton>(addButtons())
          .toList()
          .indexWhere((b) => b.onPressed != null),
    );
    await tester.tap(button, warnIfMissed: false);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'CAT-9300'),
      'CAT-9300',
    );
    // The list price, in the box labelled for the room's currency.
    await tester.enterText(
      find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            (w.decoration?.labelText ?? '').startsWith('List price'),
      ),
      '4200',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to catalog'));
    await tester.pumpAndSettle();

    final entry = p.avDeviceLibrary.templateForModel('CAT-9300');
    expect(entry, isNotNull);
    expect(entry!.price, 4200);
    // And the row on the estimate now resolves through it.
    expect(p.avCost.priceOverrides['D2'], isNull);
  });
}
