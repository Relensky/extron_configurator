import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// Settings in folding sections, and your profile in the corner.
void main() {
  setUp(SettingsSection.forgetOpenForTest);

  Future<void> pump(WidgetTester tester, AppStateProvider p, Widget body) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(home: body),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('settings fold into sections, logging in one of its own',
      (tester) async {
    final p = AppStateProvider(autoLoadSettings: false);
    await pump(tester, p, const Scaffold(body: AppSettingsView()));

    // Folded, and without what moved to the File menu and the profile.
    for (final id in ['deployment', 'appearance', 'estimate_pdf']) {
      expect(find.byKey(ValueKey('settings_section_$id')), findsNothing);
    }
    expect(find.text('Logging'), findsOneWidget);
    expect(find.byKey(const ValueKey('open_log_folder')), findsNothing);

    await tester.tap(find.text('Logging'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('open_log_folder')), findsOneWidget);
    // The recovery copies are a different section.
    expect(find.text('Open recovery folder'), findsNothing);
  });

  testWidgets('a section opened, shut and opened again can still be typed in',
      (tester) async {
    // The crash in the 1 October log: a section remembered open-or-shut under
    // the same page-storage key its text boxes kept their scroll in, so after
    // one toggle every box in it failed to build.
    final p = AppStateProvider(autoLoadSettings: false);
    await pump(tester, p, const Scaffold(body: AppSettingsView()));
    // A short window and a long open section, so scrolling really takes the
    // sections off screen and builds them again.
    tester.view.physicalSize = const Size(1600, 500);
    await tester.pumpAndSettle();
    final scroll = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;

    /// Scrolls from the top until [text] is built, then onto the screen.
    Future<void> reveal(String text) async {
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      while (find.text(text).evaluate().isEmpty &&
          scroll.pixels < scroll.maxScrollExtent) {
        scroll.jumpTo(scroll.pixels + 200);
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(find.text(text));
      await tester.pumpAndSettle();
    }

    await reveal('Files and folders');
    await tester.tap(find.text('Files and folders'));
    await tester.pumpAndSettle();

    for (var i = 0; i < 3; i++) {
      await reveal('Logging');
      await tester.tap(find.text('Logging'));
      await tester.pumpAndSettle();
    }
    // Scrolled away and back, so the sections are built afresh - which is
    // when their text boxes read their scroll position back.
    scroll.jumpTo(scroll.maxScrollExtent);
    await tester.pumpAndSettle();
    await reveal('Logging');
    await reveal('Files and folders');
    expect(tester.takeException(), isNull);
    await reveal('Logging');
    final field = find.byKey(
      ValueKey('logFolderPath_${p.logFolderPath}'),
    );
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    expect(field, findsOneWidget);
    await tester.tap(field);
    await tester.enterText(field, r'C:\logs');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the profile shows who you are and opens your settings',
      (tester) async {
    final p = AppStateProvider(autoLoadSettings: false)
      ..userDisplayName = 'Derek Stanley'
      ..userEmail = 'dstanley@example.edu';
    await pump(
      tester,
      p,
      Scaffold(appBar: AppBar(actions: const [ProfileButton()])),
    );

    await tester.tap(find.byKey(const ValueKey('profile_button')));
    await tester.pumpAndSettle();
    expect(find.text('Derek Stanley'), findsOneWidget);
    expect(find.text('dstanley@example.edu'), findsOneWidget);
    expect(find.byKey(const ValueKey('profile_menu_settings')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('profile_menu_profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile_dialog')), findsOneWidget);
    // Who you are and your avatar, then how the app and your PDFs look.
    expect(find.byKey(const ValueKey('profile_email')), findsOneWidget);
    expect(find.byKey(const ValueKey('avatar_settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings_section_appearance')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('settings_section_estimate_pdf')),
        findsOneWidget);

    await tester.ensureVisible(find.text('Appearance'));
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    expect(find.text('Theme Style'), findsOneWidget);
    expect(find.text('Text Size'), findsOneWidget);
    await tester.ensureVisible(find.text('Estimate PDF'));
    await tester.tap(find.text('Estimate PDF'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('estimate_prepared_by')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('profile_email')));

    await tester.enterText(
      find.byKey(const ValueKey('profile_email')),
      'derek@example.edu',
    );
    expect(p.userEmail, 'derek@example.edu');
  });
}
