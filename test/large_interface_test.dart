import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/collapsible_bar.dart';
import 'package:extron_configurator/nav_rail.dart';

/// At a large Interface Size the bars over a drawing fold away, the header
/// scrolls instead of squeezing the page, and the rail keeps its full-size
/// buttons and scrolls.
void main() {
  Widget host(Widget child, {Size size = const Size(600, 400)}) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(size: size, child: child),
          ),
        ),
      );

  testWidgets('a bar folds to its name and back', (tester) async {
    BarFolds.setFolded('test_bar', false);
    await tester.pumpWidget(host(const CollapsibleBar(
      id: 'test_bar',
      title: 'Cable runs',
      child: Text('the chips'),
    )));
    expect(find.text('the chips'), findsOneWidget);
    expect(find.text('Cable runs'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('collapse_test_bar')));
    await tester.pump();
    expect(find.text('the chips'), findsNothing);
    expect(find.text('Cable runs'), findsOneWidget);
    expect(BarFolds.isFolded('test_bar'), isTrue);

    await tester.tap(find.byKey(const ValueKey('collapse_test_bar')));
    await tester.pump();
    expect(find.text('the chips'), findsOneWidget);
  });

  testWidgets('a tall header is held to half the page and scrolls',
      (tester) async {
    await tester.pumpWidget(host(
      const ScrollingHeader(
        id: 'test',
        header: SizedBox(height: 900, child: Text('tools')),
        body: ColoredBox(key: ValueKey('body'), color: Colors.green),
      ),
    ));
    // Half of 400 for the header, the 7 px grip, the rest for the body.
    expect(tester.getSize(find.byKey(const ValueKey('body'))).height, 193);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scroll.position.maxScrollExtent, greaterThan(0));
  });

  testWidgets('a short header takes only its own height', (tester) async {
    await tester.pumpWidget(host(
      const ScrollingHeader(
        id: 'test_short',
        header: SizedBox(height: 50),
        body: ColoredBox(key: ValueKey('body'), color: Colors.green),
      ),
    ));
    expect(tester.getSize(find.byKey(const ValueKey('body'))).height, 343);
  });

  testWidgets('the grip drags the header shorter and taller, and a '
      'double-click puts it back', (tester) async {
    await tester.pumpWidget(host(
      const ScrollingHeader(
        id: 'test_drag',
        header: SizedBox(height: 900, child: Text('tools')),
        body: ColoredBox(key: ValueKey('body'), color: Colors.green),
      ),
    ));
    double body() => tester.getSize(find.byKey(const ValueKey('body'))).height;
    final grip = find.byKey(const ValueKey('header_grip_test_drag'));
    expect(body(), 193);

    await tester.drag(grip, const Offset(0, -100));
    await tester.pump();
    expect(body(), closeTo(293, 1));

    // Taller, but never past leaving the page its least.
    await tester.drag(grip, const Offset(0, 500));
    await tester.pump();
    expect(body(), closeTo(ScrollingHeader.minBody, 1));

    await tester.tap(grip);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(grip);
    await tester.pumpAndSettle();
    expect(body(), 193);
  });

  testWidgets('the full-size rail keeps its labels and scrolls',
      (tester) async {
    Widget rail(bool full) => host(
          AppNavRail(
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            keepFullSize: full,
          ),
          size: const Size(108, 300),
        );

    await tester.pumpWidget(rail(false));
    final shrunk = tester.widget<NavRailRow>(find.byType(NavRailRow).first);

    await tester.pumpWidget(rail(true));
    await tester.pump();
    final full = tester.widget<NavRailRow>(find.byType(NavRailRow).first);
    expect(full.fit.labels, isTrue);
    expect(full.fit.rowHeight, greaterThan(shrunk.fit.rowHeight));
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scroll.position.maxScrollExtent, greaterThan(0));
  });
}
