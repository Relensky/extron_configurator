import 'package:extron_configurator/find_in_page.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final key = GlobalKey<FindInPageState>();

  Widget app({Widget? page}) => MaterialApp(
        builder: (context, child) => Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.keyF, control: true):
                ActivateIntent(),
          },
          child: Actions(
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) => key.currentState?.open(),
              ),
            },
            child: FindInPage(key: key, child: child!),
          ),
        ),
        home: Scaffold(
          // Built in full; a lazy list only holds the rows near the screen.
          body: page ??
              SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < 60; i++) Text('Row $i'),
                    const Text('Projector in room ARTS 209'),
                    const Text('Second projector'),
                  ],
                ),
              ),
        ),
      );

  final bar = find.widgetWithText(TextField, 'Find on page');

  Future<void> typeQuery(WidgetTester tester, String q) async {
    await tester.enterText(bar, q);
    await tester.pump(FindInPageState.typingPause);
    await tester.pumpAndSettle();
  }

  testWidgets('Ctrl+F opens the bar and focuses it', (tester) async {
    await tester.pumpWidget(app());
    expect(bar, findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(key.currentState!.isOpen, isTrue);
    final field = tester.widget<TextField>(bar);
    expect(field.focusNode!.hasFocus, isTrue);
  });

  testWidgets('finds matches case-insensitively, not in its own box',
      (tester) async {
    await tester.pumpWidget(app());
    key.currentState!.open();
    await tester.pumpAndSettle();
    await typeQuery(tester, 'PROJECTOR');
    expect(key.currentState!.matches, hasLength(2));
    expect(find.text('1 of 2'), findsOneWidget);
  });

  testWidgets('waits for typing to pause; Enter searches at once',
      (tester) async {
    await tester.pumpWidget(app());
    key.currentState!.open();
    await tester.pumpAndSettle();
    await tester.enterText(bar, 'proj');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.enterText(bar, 'projector');
    await tester.pump(const Duration(milliseconds: 150));
    expect(key.currentState!.matches, isEmpty);
    expect(find.text('...'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();
    expect(find.text('1 of 2'), findsOneWidget);

    await tester.enterText(bar, 'second');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('1 of 1'), findsOneWidget);
  });

  testWidgets('Enter scrolls to the next match and wraps', (tester) async {
    await tester.pumpWidget(app());
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    key.currentState!.open();
    await tester.pumpAndSettle();
    await typeQuery(tester, 'projector');
    // Typing jumped to the first match, far down the list.
    expect(scroll.position.pixels, greaterThan(0));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('1 of 2'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);
  });

  testWidgets('a long list is searched past the rows it has built',
      (tester) async {
    await tester.pumpWidget(app(
      page: ListView.builder(
        itemCount: 500,
        itemBuilder: (_, i) => SizedBox(
          height: 40,
          child: Text(i % 100 == 99 ? 'Projector $i' : 'Row $i'),
        ),
      ),
    ));
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    key.currentState!.open();
    await tester.pumpAndSettle();
    await typeQuery(tester, 'projector');
    expect(key.currentState!.matches, hasLength(5));
    expect(find.text('1 of 5'), findsOneWidget);
    // Typing jumped to the first, which is now built and on screen.
    expect(find.text('Projector 99'), findsOneWidget);
    expect(scroll.position.pixels, greaterThan(0));

    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }
    expect(find.text('5 of 5'), findsOneWidget);
    expect(find.text('Projector 499'), findsOneWidget);
    final current = key.currentState!.matches[key.currentState!.current];
    expect(current.box.attached, isTrue);
  });

  testWidgets('the search icon lines up with the typed text', (tester) async {
    await tester.pumpWidget(app());
    key.currentState!.open();
    await tester.pumpAndSettle();
    await typeQuery(tester, 'row');
    final icon = tester.getCenter(find.byIcon(Icons.search));
    final text = tester.getCenter(find.byType(EditableText));
    expect((icon.dy - text.dy).abs(), lessThan(1));
  });

  testWidgets('a hidden tab is not searched', (tester) async {
    await tester.pumpWidget(app(
      page: const IndexedStack(
        index: 0,
        children: [Text('Shown cable'), Text('Hidden cable')],
      ),
    ));
    key.currentState!.open();
    await tester.pumpAndSettle();
    await typeQuery(tester, 'cable');
    expect(key.currentState!.matches, hasLength(1));
  });

  testWidgets('text boxes are searched, passwords are not', (tester) async {
    await tester.pumpWidget(app(
      page: Column(
        children: [
          TextField(controller: TextEditingController(text: 'DMP 128')),
          TextField(
            obscureText: true,
            controller: TextEditingController(text: 'DMP secret'),
          ),
        ],
      ),
    ));
    key.currentState!.open();
    await tester.pumpAndSettle();
    await typeQuery(tester, 'dmp');
    expect(key.currentState!.matches, hasLength(1));
  });

  testWidgets('Esc closes the bar', (tester) async {
    await tester.pumpWidget(app());
    key.currentState!.open();
    await tester.pumpAndSettle();
    await typeQuery(tester, 'row');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(key.currentState!.isOpen, isFalse);
    expect(bar, findsNothing);
  });
}
