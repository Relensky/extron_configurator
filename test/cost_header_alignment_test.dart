import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/live_text_field.dart';

/// The estimate's tables are Rows of SizedBoxes rather than a Table, so every
/// caption is lined up with its column BY HAND. Nothing in the framework holds
/// the two together, which is exactly why this measures them.
///
/// Two ways they came apart. The cells themselves are settled — each caption
/// sits over the same span as the cell under it. What was still wrong is what
/// sits INSIDE a cell: half of these columns are input boxes, and a box
/// right-aligns its figure and holds it 16 pixels off its own border. "Unit
/// price" was drawn hard against the left edge of a cell whose number is hard
/// against the right, and "Techs", "Hours ea." and "Rate/hr" the same — the
/// caption reading as though it belonged to the column beside it.
void main() {
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
    p.addAvNode(
      const AvNode(
        id: 'D1',
        label: 'Display',
        model: 'Display X',
        pos: Offset.zero,
        ports: [],
      ),
    );
    p.addAvCostItem();
    p.addAvCostLabor(rateId: 'cts3', techs: 1);
    return p;
  }

  Future<void> pump(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1900, 3000);
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

  Rect rectOf(WidgetTester tester, Finder f) {
    expect(f, findsWidgets, reason: 'nothing found to measure');
    final box = f.evaluate().first.renderObject! as RenderBox;
    final at = box.localToGlobal(Offset.zero);
    return at & box.size;
  }

  /// The text a [LiveTextField] actually draws, not the box around it.
  Finder textInside(String fieldIdPrefix) => find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is LiveTextField && w.fieldId.startsWith(fieldIdPrefix),
    ),
    matching: find.byType(EditableText),
  );

  testWidgets('a caption over a figure sits over the figure', (tester) async {
    final p = room();
    await pump(tester, p);

    // The equipment row's price box. Its figure is right-aligned inside the
    // box, so the caption's right edge belongs on the figure's right edge —
    // not 16 pixels past it, on the border.
    final caption = rectOf(tester, find.text('Unit price').first);
    final figure = rectOf(tester, textInside('price_'));
    expect(
      caption.right,
      moreOrLessEquals(figure.right, epsilon: 0.5),
      reason: '"Unit price" must line up with the number in the box',
    );

    // And it is right-aligned at all, which is what puts it there.
    final text = tester.widget<Text>(find.text('Unit price').first);
    expect(text.textAlign, TextAlign.right);
  });

  testWidgets('the labor captions line up with their boxes', (tester) async {
    final p = room();
    await pump(tester, p);

    for (final pair in const [
      ('Techs', 'labor_techs_'),
      ('Hours ea.', 'labor_hours_'),
      ('Rate/hr', 'labor_rate_'),
    ]) {
      final caption = rectOf(tester, find.text(pair.$1));
      final figure = rectOf(tester, textInside(pair.$2));
      expect(
        caption.right,
        moreOrLessEquals(figure.right, epsilon: 0.5),
        reason: '"${pair.$1}" must line up with the figure under it',
      );
    }

    // Scope is prose, not a figure: it reads from the left, and so does its
    // caption — 16 pixels in, where the box starts its text.
    final scope = rectOf(tester, find.text('Scope'));
    final typed = rectOf(tester, textInside('labor_desc_'));
    expect(scope.left, moreOrLessEquals(typed.left, epsilon: 0.5));
  });

  testWidgets('the other-items captions line up too', (tester) async {
    final p = room();
    await pump(tester, p);

    final desc = rectOf(tester, find.text('Description'));
    expect(
      desc.left,
      moreOrLessEquals(rectOf(tester, textInside('desc_')).left, epsilon: 0.5),
    );
    // 'Qty' appears on the equipment table as well; the items one is the box.
    final qty = find.text('Qty');
    expect(qty, findsNWidgets(2));
    final itemsQty = rectOf(tester, qty.at(1));
    expect(
      itemsQty.right,
      moreOrLessEquals(rectOf(tester, textInside('qty_')).right, epsilon: 0.5),
    );
  });

  testWidgets('a caption over a plain figure still sits on the cell edge', (
    tester,
  ) async {
    // Nothing was wrong with these and nothing may become wrong with them:
    // "Extended" is a Text painted at the cell's own edge, so its caption
    // belongs there rather than inset like a box's.
    final p = room();
    await pump(tester, p);

    final caption = rectOf(tester, find.text('Extended').first);
    final figure = rectOf(tester, find.text(r'$1,000.00').first);
    expect(caption.right, moreOrLessEquals(figure.right, epsilon: 0.5));
    expect(caption.left, moreOrLessEquals(figure.left, epsilon: 0.5));
  });

  testWidgets('the inset the captions use is the one a field really has', (
    tester,
  ) async {
    // [kFieldTextInset] is measured, not derived — if Flutter's dense outlined
    // field ever changes its content padding, this is what says so rather than
    // every caption quietly drifting.
    final p = room();
    await pump(tester, p);

    final box = rectOf(
      tester,
      find.byWidgetPredicate(
        (w) => w is LiveTextField && w.fieldId.startsWith('labor_techs_'),
      ),
    );
    final text = rectOf(tester, textInside('labor_techs_'));
    expect(box.right - text.right, moreOrLessEquals(kFieldTextInset, epsilon: 0.5));
    expect(text.left - box.left, moreOrLessEquals(kFieldTextInset, epsilon: 0.5));
  });
}
