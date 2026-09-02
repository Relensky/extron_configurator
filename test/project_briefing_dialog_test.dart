import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/project_briefing_dialog.dart';

/// The briefing on screen, and the one thing somebody does with it besides
/// read it.
///
/// "Where does this job stand" is asked on email and on calls far more often
/// than it is asked by the person in front of the app, and an answer that has
/// to be retyped out of a dialog is an answer that arrives stale and without
/// its dates.
void main() {
  /// What the app actually put on the clipboard, or null when nothing did.
  String? copied;

  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// Lets the confirmation bar finish. It is on a timer, and a test that walks
  /// away mid-countdown fails on a pending timer rather than on anything real.
  Future<void> drainSnack(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  Future<void> openBriefing(WidgetTester tester) async {
    final provider = AppStateProvider(autoLoadSettings: false)
      ..newProject(name: 'Bessey refresh', building: 'BSS');

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showProjectBriefing(
                  context,
                  provider,
                  // A brand new job has nothing time-critical on it, and the
                  // briefing is deliberately silent on those unless asked.
                  force: true,
                  asOf: DateTime(2026, 3, 4),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The calendar only draws when there is more than one date to draw.
  Future<void> openDatedBriefing(WidgetTester tester) async {
    final provider = AppStateProvider(autoLoadSettings: false)
      ..newProject(name: 'Bessey refresh', building: 'BSS');
    provider.setProjectDeadline(DateTime(2026, 12, 1));

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showProjectBriefing(
                  context,
                  provider,
                  force: true,
                  asOf: DateTime(2026, 3, 4),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the dates are drawn on a calendar, not only listed',
      (tester) async {
    await openDatedBriefing(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(BriefingCalendar), findsOneWidget);
    // Today and the delivery date, each with its own marker on the line.
    expect(
      find.byKey(const ValueKey('briefing_marker_today_2026-03-04')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('briefing_marker_delivery_2026-12-01')),
      findsOneWidget,
    );
    // Read against a real calendar rather than against its neighbors.
    expect(find.text('Delivery'), findsWidgets);
  });

  testWidgets('a job with one date and nothing else draws no calendar',
      (tester) async {
    // The plain fixture: a new job with no deadline, so today is the only
    // date there is. One marker on a line says nothing a row does not.
    await openBriefing(tester);
    expect(find.byType(BriefingCalendar), findsOneWidget);
    expect(
      find.byKey(const ValueKey('briefing_marker_today_2026-03-04')),
      findsNothing,
    );
  });

  testWidgets('the briefing offers a copy beside its dismissal',
      (tester) async {
    await openBriefing(tester);
    expect(find.byKey(const ValueKey('project_briefing')), findsOneWidget);
    expect(find.byKey(const ValueKey('briefing_copy')), findsOneWidget);
  });

  testWidgets('copying puts the whole briefing on the clipboard',
      (tester) async {
    await openBriefing(tester);
    await tester.tap(find.byKey(const ValueKey('briefing_copy')));
    await tester.pumpAndSettle();

    expect(copied, isNotNull);
    expect(copied, contains('Bessey refresh'));
    expect(copied, contains('Where it stands on 4 Mar 2026'));
    expect(copied, contains('Project total'));
    await drainSnack(tester);
  });

  testWidgets('the dialog stays open, and says the copy happened',
      (tester) async {
    await openBriefing(tester);
    await tester.tap(find.byKey(const ValueKey('briefing_copy')));
    await tester.pump();

    // Copying is done on the way to pasting: closing the dialog would take the
    // job name off screen at the moment somebody wants to check it.
    expect(find.byKey(const ValueKey('project_briefing')), findsOneWidget);
    expect(find.textContaining('copied to the clipboard'), findsOneWidget);
    await drainSnack(tester);
  });
}
