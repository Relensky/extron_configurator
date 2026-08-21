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
    // The second kind of equipment row: a line typed on this page, whose name
    // and quantity are BOXES where the drawn device's are printed text. The
    // two have to line up with each other and with the caption over them.
    p.addAvCostExtraEquipment(description: 'Owner display', qty: 2);
    p.addAvCostExtraHardware(description: 'Spare shelf', qty: 1);
    p.addAvCostExtraCable(description: 'Cat6A spool', qty: 1);
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
    // 'Qty' captions the equipment and hardware tables as well; the items one
    // is the last of them, in the order the cards are built.
    final qty = find.text('Qty');
    expect(qty, findsNWidgets(3));
    final itemsQty = rectOf(tester, qty.last);
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
    // The RIGHT edge is the whole of it. A caption cell shrink-wraps its text
    // so that one line and two can share a bottom rule; the figure's cell is
    // stretched to the column. Comparing their left edges compares two boxes
    // rather than two pieces of text, and would fail for a column that is
    // perfectly aligned.
    expect(caption.left, greaterThanOrEqualTo(figure.left - 0.5),
        reason: 'the caption still sits inside its own column');
  });

  testWidgets('a mixed column lines up caption, box and printed text', (
    tester,
  ) async {
    // THE 16-PIXEL PROBLEM. Half these columns are a box on one row and a
    // printed value on the next: a device off the diagram prints its name and
    // "×3" where a line typed here has a field for both. A bare Text paints at
    // the cell's edge and a box paints 16 in from it, so the two rows
    // disagreed with each other and the caption could only sit over one of
    // them.
    final p = room();
    await pump(tester, p);

    for (final pair in const [
      ('Device', 'eqpdesc_', false),
      ('Qty', 'eqpqty_', true),
    ]) {
      final caption = rectOf(tester, find.text(pair.$1).first);
      final box = rectOf(tester, textInside(pair.$2));
      // The printed cell on the DRAWN row of the same column.
      final printed = rectOf(
        tester,
        find.text(pair.$3 ? '×1' : 'Display'),
      );
      double edge(Rect r) => pair.$3 ? r.right : r.left;
      expect(edge(caption), moreOrLessEquals(edge(box), epsilon: 0.5),
          reason: '"${pair.$1}" must sit over the box in its column');
      expect(edge(printed), moreOrLessEquals(edge(box), epsilon: 0.5),
          reason: 'the printed cell must start where the box text does, or '
              'the two kinds of row are ragged against each other');
    }
  });

  testWidgets('the hardware quantity column is square too', (tester) async {
    final p = room();
    await pump(tester, p);

    final caption = find.text('Qty');
    // Equipment, hardware, other items — the hardware one is the second.
    final box = rectOf(tester, textInside('hwqty_'));
    expect(rectOf(tester, caption.at(1)).right,
        moreOrLessEquals(box.right, epsilon: 0.5));
  });

  testWidgets('every caption on a row shares one bottom rule', (tester) async {
    // A narrow column wraps its caption — "Unit price" over 130 pixels is two
    // lines, "Qty" over 60 is one — and a Row centres what it is given, so the
    // tall ones used to ride 8 pixels higher than the short ones and the whole
    // caption row read as crooked. They sit in fixed-height cells now, text
    // against the bottom, which is the rule the divider under them draws.
    final p = room();
    await pump(tester, p);

    for (final table in const [
      ['Device', 'Model', 'Qty', 'Unit price', 'Extended', 'Price from'],
      ['Job type', 'Scope', 'Techs', 'Hours ea.', 'Rate/hr'],
    ]) {
      final bottoms = <double>[
        for (final caption in table) rectOf(tester, find.text(caption).first).bottom,
      ];
      for (final bottom in bottoms) {
        expect(bottom, moreOrLessEquals(bottoms.first, epsilon: 0.5),
            reason: 'the captions of one table sit on one line: $table');
      }
    }
  });

  testWidgets('every table lays its rows out on its caption row', (
    tester,
  ) async {
    // THE INVISIBLE GRID. Each table's caption row and its data rows are built
    // from ONE list of columns, so this is really asking whether that held:
    // every cell boundary on a data row falls where the caption row put it.
    //
    // Per table, because that is where it goes wrong — a column added to one
    // and not the other is exactly the drift this replaced.
    final p = room();
    await pump(tester, p);

    List<double> edgesAt(Finder rowFinder) {
      expect(rowFinder, findsWidgets, reason: 'no row to measure');
      final out = <double>[];
      void visit(Element e) {
        final render = e.renderObject;
        if (render is RenderBox && e.widget is! Row) {
          out.add(render.localToGlobal(Offset.zero).dx);
          return;
        }
        e.visitChildren(visit);
      }

      rowFinder.evaluate().first.visitChildren(visit);
      return out;
    }

    Finder rowsKeyed(String prefix) => find.byWidgetPredicate(
      (w) =>
          w is Row &&
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith(prefix),
    );

    // A caption to find each header row by, and the data rows under it.
    for (final table in const [
      ('Device', 'gridrow_eqp_'),
      ('Item', 'gridrow_hw_'),
      ('Cable type', 'gridrow_cbl_'),
      ('Scope', 'gridrow_labor_'),
      ('Description', 'gridrow_item_'),
    ]) {
      final caption = table.$1;
      final header = edgesAt(
        find.ancestor(of: find.text(caption).first, matching: find.byType(Row))
            .first,
      );
      final data = edgesAt(rowsKeyed(table.$2));
      expect(header, isNotEmpty, reason: 'no caption row for $caption');
      expect(data.length, header.length,
          reason: '$caption: a data row has the columns its captions do');
      for (var i = 0; i < header.length; i++) {
        expect(data[i], moreOrLessEquals(header[i], epsilon: 0.5),
            reason: '$caption: column $i starts in the same place on both '
                'rows');
      }
    }
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
