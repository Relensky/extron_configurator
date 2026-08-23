import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// A successful upload leaves its message up for two seconds and then closes
/// the dialog. That delay races the Cancel button, which is live again the
/// moment the transfer finishes.
///
/// Cancel pops the dialog, but the State stays mounted until the route's exit
/// animation completes — so a late Cancel used to leave the auto-close timer
/// firing against a live State and popping a SECOND route: the page underneath.
/// The navigator was left empty and the window went black.
void main() {
  // The default 800x600 test surface is smaller than any desktop this ships
  // to, and the dialog's field stack overflows it. Give it a real window.
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1400, 1200);
    view.devicePixelRatio = 1.0;
  });

  tearDown(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  /// The app as the dialog sees it: a home page, with the SFTP dialog pushed
  /// on top. If a stray pop reaches the home route, "Home" disappears — which
  /// is exactly the black screen, observable in a test.
  Future<void> pumpAppWithDialog(WidgetTester tester) async {
    // The provider sits ABOVE MaterialApp, as it does in the real app — the
    // dialog is pushed on the root navigator and has to see it from there.
    await tester.pumpWidget(ChangeNotifierProvider<AppStateProvider>.value(
      value: AppStateProvider(autoLoadSettings: false),
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const ProcessorSftpDialog(isUpload: true),
                ),
                child: const Text('Home'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.byType(ProcessorSftpDialog), findsOneWidget);
  }

  testWidgets('a late Cancel does not take the page down with it',
      (tester) async {
    await pumpAppWithDialog(tester);

    // Drive a successful upload the way the UI does. The real transfer needs a
    // processor, so this exercises the close path directly: the dialog's own
    // Cancel, then the auto-close timer's window elapsing on top of it.
    final state = tester.state<State<ProcessorSftpDialog>>(
        find.byType(ProcessorSftpDialog));
    // ignore: invalid_use_of_protected_member, avoid_dynamic_calls
    (state as dynamic).scheduleUploadAutoClose();
    await tester.pump();

    // User cancels 1.9s in — just before the auto-close would fire.
    await tester.pump(const Duration(milliseconds: 1900));
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump(); // starts the route's exit animation, State still alive

    // The timer's moment arrives while that animation is still running.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(find.byType(ProcessorSftpDialog), findsNothing,
        reason: 'the dialog should be closed');
    expect(find.text('Home'), findsOneWidget,
        reason: 'the page underneath must survive - its loss is the black screen');
  });

  testWidgets('left alone, the upload dialog still closes itself',
      (tester) async {
    await pumpAppWithDialog(tester);

    final state = tester.state<State<ProcessorSftpDialog>>(
        find.byType(ProcessorSftpDialog));
    // ignore: invalid_use_of_protected_member, avoid_dynamic_calls
    (state as dynamic).scheduleUploadAutoClose();
    await tester.pump();

    expect(find.byType(ProcessorSftpDialog), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.byType(ProcessorSftpDialog), findsNothing);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('closing the dialog leaves no timer to fire', (tester) async {
    await pumpAppWithDialog(tester);

    final state = tester.state<State<ProcessorSftpDialog>>(
        find.byType(ProcessorSftpDialog));
    // ignore: invalid_use_of_protected_member, avoid_dynamic_calls
    (state as dynamic).scheduleUploadAutoClose();
    await tester.pump();

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle(); // fully disposed well before the 2s mark

    // If dispose didn't cancel the timer, the test framework fails the test
    // here with a pending-timer error.
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Home'), findsOneWidget);
  });
}
