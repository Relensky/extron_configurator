import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// ============================================================================
///  THE START SCREEN, ON ONE LINE
/// ============================================================================
///  Two cards, each offering the one thing there is to MAKE of its kind. They
///  were in a Wrap, which gives every child its natural height - and the two
///  blurbs are not the same length, so the Project button sat a line lower than
///  the Room one. Two buttons that do the same kind of thing, at two different
///  heights, read as a mistake before they read as anything else.
///
///  What is held here: that the two buttons share a line whenever the cards
///  share one, at any text scale, and that a window too narrow for both stacks
///  them instead of clipping or overflowing.
/// ============================================================================
void main() {
  Future<void> pump(
    WidgetTester tester,
    AppStateProvider provider, {
    required Size size,
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: const RoomConfigApp(),
        ),
      ),
    );
    await tester.pump();
  }

  AppStateProvider fresh() => AppStateProvider(autoLoadSettings: false)
    ..settingsLoaded = true
    ..firstRunSetupNeeded = false;

  // Functions rather than shared values: a Finder caches what it matched, and
  // one reused across pumps would answer for the screen before last.
  Finder project() =>
      find.widgetWithText(FilledButton, 'Start a New Project');
  Finder room() => find.widgetWithText(FilledButton, 'Create a New File');

  for (final scale in [1.0, 1.3, 1.5]) {
    testWidgets('the two buttons are level at ${scale}x text', (tester) async {
      await pump(
        tester,
        fresh(),
        size: const Size(1600, 1200),
        textScale: scale,
      );

      expect(project(), findsOneWidget);
      expect(room(), findsOneWidget);
      final a = tester.getRect(project());
      final b = tester.getRect(room());

      // Level, not merely close: the slack goes above the button on whichever
      // card is shorter, so the two tops land on the same pixel.
      expect(
        a.top,
        moreOrLessEquals(b.top, epsilon: 0.5),
        reason: 'the buttons sit on different lines',
      );
      expect(a.height, moreOrLessEquals(b.height, epsilon: 0.5));
      // And they are genuinely side by side rather than accidentally level
      // because one wrapped underneath the other.
      expect(a.left, lessThan(b.left));
    });
  }

  testWidgets('a window too narrow for both stacks them instead', (
    tester,
  ) async {
    await pump(tester, fresh(), size: const Size(600, 1200));

    expect(project(), findsOneWidget);
    expect(room(), findsOneWidget);
    // Stacked: there is no line to share, so nothing is stretched to match a
    // card that is no longer beside it.
    expect(tester.getRect(project()).top, lessThan(tester.getRect(room()).top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a lone card reserves room for its own words only', (
    tester,
  ) async {
    final p = fresh()..newProject(name: 'Bessey Hall');
    await pump(tester, p, size: const Size(1600, 1200));

    expect(project(), findsNothing);
    expect(room(), findsOneWidget);
    // Room reserved for a blurb nobody can see would leave a hole in the one
    // card that is left, and push the Open button down the page after it.
    final card = tester.getRect(room());
    final open = tester.getRect(find.byKey(const ValueKey('start_open_any')));
    expect(open.top - card.bottom, lessThan(160));
    expect(tester.takeException(), isNull);
  });
}
