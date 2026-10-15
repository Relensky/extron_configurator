import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/keyboard_shortcuts.dart';
import 'package:extron_configurator/pinned_grid.dart';
import 'package:extron_configurator/responsive.dart';

/// Pages and grids wider than the window scroll sideways with Shift and the
/// wheel, and with Left and Right when nothing is selected; a grid that fills
/// its frame keeps its sideways bar on the bottom edge.
void main() {
  /// As the app wires it - see RoomConfigApp._helpShortcuts.
  Widget app(Widget body) => MaterialApp(
    builder: (context, child) => Shortcuts(
      shortcuts: textBoxShortcuts(const KeyboardShortcuts()),
      child: Actions(actions: textBoxActions, child: child!),
    ),
    home: Scaffold(body: body),
  );

  Widget page({Widget? top}) => MinWidthScroll(
    minWidth: 1200,
    child: ListView(children: [
      ?top,
      for (var i = 0; i < 40; i++) SizedBox(height: 40, child: Text('row $i')),
    ]),
  );

  Widget grid({double bodyHeight = 2000, bool fill = false}) => PinnedGrid(
    frozenWidth: 100,
    headerHeight: 30,
    bodyWidth: 2000,
    bodyHeight: bodyHeight,
    maxHeight: 500,
    fillHeight: fill,
    corner: const SizedBox(),
    header: const SizedBox(width: 2000, height: 30),
    frozen: SizedBox(height: bodyHeight),
    body: SizedBox(width: 2000, height: bodyHeight),
  );

  double sideways(WidgetTester tester) => tester
      .stateList<ScrollableState>(find.byType(Scrollable))
      .where((s) => s.widget.axisDirection == AxisDirection.right)
      .first
      .position
      .pixels;

  void size(WidgetTester tester) {
    tester.view.physicalSize = const Size(600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> shiftWheel(WidgetTester tester, Offset at) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(at));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }

  testWidgets('Shift and the wheel scroll a page sideways', (tester) async {
    size(tester);
    await tester.pumpWidget(app(page()));
    await shiftWheel(tester, const Offset(200, 200));
    expect(sideways(tester), 120);
  });

  testWidgets('Shift and the wheel scroll a grid sideways', (tester) async {
    size(tester);
    await tester.pumpWidget(app(grid()));
    await shiftWheel(tester, const Offset(400, 300));
    expect(sideways(tester), 120);
  });

  testWidgets('Right and Left scroll a page when nothing is selected',
      (tester) async {
    size(tester);
    await tester.pumpWidget(app(page()));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(sideways(tester), 160);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(sideways(tester), 80);
  });

  testWidgets('Right scrolls the grid under the pointer', (tester) async {
    size(tester);
    await tester.pumpWidget(app(grid()));
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(const Offset(400, 300)));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(sideways(tester), 80);
  });

  testWidgets('in a text box Left and Right move the cursor instead',
      (tester) async {
    size(tester);
    final c = TextEditingController(text: 'hello');
    await tester.pumpWidget(app(page(top: TextField(controller: c))));
    // Focused directly: the box is as wide as the page, so its middle is
    // off the side of the window.
    await tester.showKeyboard(find.byType(TextField));
    await tester.pump();
    c.selection = const TextSelection.collapsed(offset: 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(c.selection.baseOffset, 3);
    expect(sideways(tester), 0);
  });

  testWidgets('a grid that fills its frame keeps its bar on the bottom edge',
      (tester) async {
    size(tester);
    // Three rows: without fill the frame would end under them.
    await tester.pumpWidget(app(Align(
      alignment: Alignment.topLeft,
      child: grid(bodyHeight: 90, fill: true),
    )));
    expect(tester.getSize(find.byType(PinnedGrid)).height, 500);
    await tester.pumpWidget(app(Align(
      alignment: Alignment.topLeft,
      child: grid(bodyHeight: 90),
    )));
    expect(tester.getSize(find.byType(PinnedGrid)).height, lessThan(200));
  });
}
