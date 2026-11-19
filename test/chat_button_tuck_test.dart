import 'package:extron_configurator/hover_fade.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// The hovering chat button steps aside while a page scrolls down and at its
/// end, so nothing in the bottom-right corner is stuck under it - whatever
/// padding the page's own list sets.
void main() {
  Future<void> pumpList(WidgetTester tester, {int rows = 60}) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatButtonScrollWatch(
            child: ListView(
              // Its own padding, the case the MediaQuery clearance misses.
              padding: const EdgeInsets.all(16),
              children: [
                for (int i = 0; i < rows; i++)
                  SizedBox(height: 40, child: Text('Row $i')),
              ],
            ),
          ),
        ),
      ));

  testWidgets('a new page starts with the button showing', (tester) async {
    chatButtonTucked.value = true;
    await pumpList(tester);
    expect(chatButtonTucked.value, isFalse);
  });

  testWidgets('scrolling down tucks it; back up brings it back',
      (tester) async {
    await pumpList(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();
    expect(chatButtonTucked.value, isTrue);

    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(chatButtonTucked.value, isFalse);
  });

  testWidgets('at the end of the page it stays out of the way',
      (tester) async {
    await pumpList(tester);
    await tester.dragUntilVisible(
        find.text('Row 59'), find.byType(ListView), const Offset(0, -500));
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(chatButtonTucked.value, isTrue);
  });

  testWidgets('a page only a little taller than the screen keeps it',
      (tester) async {
    // 600 high; 16 + 16 rows of 40 = 656 - just past the bottom, the way
    // the start page sits on a phone.
    await pumpList(tester, rows: 16);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(chatButtonTucked.value, isFalse);
  });

  testWidgets('a page too short to scroll never tucks it', (tester) async {
    await pumpList(tester, rows: 3);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(chatButtonTucked.value, isFalse);
  });
}
