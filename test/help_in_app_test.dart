import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// HELP HAS TO BE REACHABLE FROM THE APP, not just exist inside it.
///
/// Two ways in, both of them where somebody would already be looking: a button
/// on the title bar beside the gear - help is a property of the app rather than
/// of whichever tab is open, so it does not move - and F1, which every Windows
/// tool has meant help on for thirty years.
void main() {
  AppStateProvider ready() => AppStateProvider(autoLoadSettings: false)
    ..settingsLoaded = true
    ..firstRunSetupNeeded = false;

  Future<void> pumpApp(WidgetTester tester, AppStateProvider provider) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pump();
  }

  testWidgets('the title bar carries a help button', (tester) async {
    await pumpApp(tester, ready());
    expect(find.byKey(const ValueKey('open_help')), findsOneWidget);
  });

  testWidgets('pressing it opens the book on its search box', (tester) async {
    await pumpApp(tester, ready());
    await tester.tap(find.byKey(const ValueKey('open_help')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('help_book')), findsOneWidget);
    expect(find.byKey(const ValueKey('help_search')), findsOneWidget);
  });

  testWidgets('F1 opens it too, without touching the mouse', (tester) async {
    await pumpApp(tester, ready());
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('help_book')), findsOneWidget);
  });

  testWidgets('closing it puts back what was underneath', (tester) async {
    final provider = ready();
    await pumpApp(tester, provider);
    final tabBefore = provider.selectedTabIndex;

    await tester.tap(find.byKey(const ValueKey('open_help')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('help_close')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('help_book')), findsNothing);
    expect(
      provider.selectedTabIndex,
      tabBefore,
      reason: 'the answer arrives beside the question, not instead of it',
    );
  });
}
