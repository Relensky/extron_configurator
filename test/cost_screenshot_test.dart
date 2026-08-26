import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/contrast.dart';
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
              // up on the page. Marked as such: a hint is only printed when
              // it is a VALUE, never when it is an example.
              hint: '2500',
              hintIsValue: true,
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

    // WHAT A PHOTOGRAPHED QUOTE MUST NOT CARRY. Half the boxes on the cost
    // sheet hint with an example of what could be typed in them - 'e.g.
    // Freight' - and printed, an example reads as a line somebody quoted.
    testWidgets('an example hint prints as nothing at all', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PrintMode(
              printing: true,
              child: LiveTextField(
                fieldId: 'x',
                initial: '',
                hint: 'e.g. Rack build and termination',
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      expect(find.textContaining('e.g.'), findsNothing);
    });

    testWidgets('what the user typed always prints', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PrintMode(
              printing: true,
              child: LiveTextField(
                fieldId: 'x',
                initial: 'Rack build, second floor',
                hint: 'e.g. Rack build and termination',
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );

      expect(find.text('Rack build, second floor'), findsOneWidget);
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
      // The tier and the tax rate used to print as a line of prose above the
      // sections. They do not any more - see "the capture carries the figures
      // and none of the prose": the image goes out to people, and the tax
      // still says itself where it belongs, on its own line in the totals.
      expect(find.textContaining('Priced at'), findsNothing);
      expect(find.textContaining('State tax (8.25%)'), findsOneWidget);
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
  // ---------------------------------------------------------------------------
  //  THE IMAGE IS A QUOTE, NOT A PAGE OF THE APP
  // ---------------------------------------------------------------------------

  testWidgets('the capture carries the figures and none of the prose', (
    tester,
  ) async {
    final p = room(extraLines: 1);
    await pump(tester, p, capturing: Brightness.light);

    // What a quote is made of: the headings, what is being bought, and what
    // it costs.
    expect(find.text('Room Cost Estimate'), findsOneWidget);
    expect(find.textContaining('Equipment ('), findsOneWidget);
    expect(find.text('Display X'), findsWidgets);
    expect(find.text('TOTAL'), findsOneWidget);
    expect(find.textContaining(r'$1,000.00'), findsWidgets);

    // And what it is not made of: the paragraph that explains the page to
    // whoever is filling it in, the line describing how the picture was
    // priced, and the note under every heading saying what that section is
    // for. This one goes out to people.
    for (final prose in [
      'Quantities are the devices',
      'Priced at',
      'counted off the signal flow diagram',
      'placed on the Racks tab',
      'one lead per run',
      'anything not a device on the canvas',
      'each a percentage of the subtotal',
      'No cables drawn yet',
      'None yet.',
      'No job type has an hourly rate',
    ]) {
      expect(
        find.textContaining(prose),
        findsNothing,
        reason: '"$prose" has no business on an emailed quote',
      );
    }
  });

  testWidgets('the same notes are still there on screen', (tester) async {
    // The other half of it: these are useful to the person working, and
    // hiding them from the app as well would be fixing the wrong thing.
    final p = room();
    await pump(tester, p);
    expect(
      find.textContaining('counted off the signal flow diagram'),
      findsOneWidget,
    );
    expect(find.textContaining('Quantities are the devices'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  //  A DARK IMAGE OFF A LIGHT APP
  // ---------------------------------------------------------------------------

  /// Every text in the captured sheet that does not read on what is painted
  /// behind it, as "ratio - the words".
  List<String> unreadable(WidgetTester tester) {
    final out = <String>[];
    void walk(RenderObject node, List<Color> grounds) {
      var stack = grounds;
      if (node is RenderPhysicalShape && node.color.a == 1.0) {
        stack = [...grounds, node.color];
      } else if (node is RenderPhysicalModel && node.color.a == 1.0) {
        stack = [...grounds, node.color];
      } else if (node is RenderDecoratedBox) {
        final d = node.decoration;
        if (d is BoxDecoration && d.color != null && d.color!.a == 1.0) {
          stack = [...grounds, d.color!];
        }
      }
      if (node is RenderParagraph && stack.isNotEmpty) {
        final span = node.text;
        final text = span.toPlainText(includeSemanticsLabels: false).trim();
        final ink = span.style?.color;
        // An Icon is a glyph in a RichText with no plain text of its own, and
        // a disabled one is meant to be faint.
        if (text.isNotEmpty && ink != null) {
          final ground = stack.last;
          final ratio = contrastRatio(Color.alphaBlend(ink, ground), ground);
          if (ratio < kContrastBody) {
            out.add('${ratio.toStringAsFixed(2)}:1  "$text"');
          }
        }
      }
      node.visitChildren((c) => walk(c, stack));
    }

    walk(
      capturedSheet().evaluate().single.renderObject!,
      [const Color(0xFF16191D)],
    );
    return out;
  }

  testWidgets('a dark image off a light app is dark all the way down', (
    tester,
  ) async {
    // THE FAILURE: the cards were built against the APP's theme and only
    // wrapped in the image's afterwards, so a dark image taken from a light
    // app came out with the totals in a white box, black section headings and
    // the top of the sheet unreadable. The paper was the only thing that had
    // heard about the brightness.
    await pump(tester, room(extraLines: 1), capturing: Brightness.dark);

    final bad = unreadable(tester);
    expect(
      bad,
      isEmpty,
      reason: 'unreadable on the dark image:\n${bad.join('\n')}',
    );
  });

  testWidgets('and a light image off a light app still reads', (tester) async {
    await pump(tester, room(extraLines: 1), capturing: Brightness.light);
    final bad = unreadable(tester);
    expect(
      bad,
      isEmpty,
      reason: 'unreadable on the light image:\n${bad.join('\n')}',
    );
  });

  // ---------------------------------------------------------------------------
  //  READING A CELL THAT DID NOT FIT
  // ---------------------------------------------------------------------------

  testWidgets('a cut-off device hovers to its name and model', (tester) async {
    final p = room();
    // A name far longer than the Device column, on a narrow window.
    p.addAvNode(
      device('D2', 'Lectern rack frame with the cable cubby under it',
          'Display X'),
    );
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();

    final long = find.textContaining('Lectern rack frame');
    expect(long, findsWidgets);
    final tip = find.ancestor(of: long.first, matching: find.byType(Tooltip));
    expect(
      tip,
      findsWidgets,
      reason: 'a name the column cannot show has to be readable somehow',
    );
    expect(
      tester.widget<Tooltip>(tip.first).message,
      contains('Display X'),
      reason: 'the model is half of what the row is',
    );
  });

  testWidgets('a name that fits is left alone', (tester) async {
    // The other half: a tooltip over every cell in a table of ninety is a
    // page that flickers a black box wherever the pointer rests.
    final p = room();
    tester.view.physicalSize = const Size(1900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();

    final short = find.text('Display');
    expect(short, findsWidgets);
    expect(
      find.ancestor(of: short.first, matching: find.byType(Tooltip)),
      findsNothing,
    );
  });

}
