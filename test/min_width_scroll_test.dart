import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/responsive.dart';

/// The sideways scrollbar of a page narrower than its tables sits on the
/// bottom edge, not lifted by the chat button's clearance.
void main() {
  testWidgets('the bar ignores the bottom padding; the page keeps it',
      (tester) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late EdgeInsets inside;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(500, 800),
          padding: EdgeInsets.only(bottom: 88),
        ),
        child: MinWidthScroll(
          minWidth: 900,
          child: Builder(builder: (context) {
            inside = MediaQuery.paddingOf(context);
            return const SizedBox.expand();
          }),
        ),
      ),
    ));
    final bar = tester.element(find.byType(Scrollbar));
    expect(MediaQuery.paddingOf(bar).bottom, 0);
    expect(inside.bottom, 88);
    // And it spans the whole height, so its bottom is the window's.
    expect(tester.getRect(find.byType(Scrollbar)).bottom, 800);
  });
}
