import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// The red count on the toolbar's Convert button.
///
/// It answers "is there something here to deal with", not "was this file ever
/// converted" — a count that stays up after the work is done stops meaning
/// anything, and the next file that really does need converting gets ignored
/// along with it.
void main() {
  group('the convert button badge', () {
    test('is up while a converted file has not been dealt with', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..lastLoadHadChanges = true;
      expect(p.conversionNeedsAttention, isTrue);
    });

    test('comes down when the conversion is acknowledged, and repaints', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..lastLoadHadChanges = true;

      var repaints = 0;
      p.addListener(() => repaints++);

      p.acknowledgeConversion();

      expect(p.conversionNeedsAttention, isFalse);
      expect(repaints, 1, reason: 'the toolbar has to be told to repaint');

      // Acknowledging twice is not two repaints.
      p.acknowledgeConversion();
      expect(repaints, 1);
    });

    test('leaves the log reachable after it is acknowledged', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..lastLoadHadChanges = true;
      p.acknowledgeConversion();

      // The button stays enabled off lastLoadHadChanges; only the count goes.
      expect(p.lastLoadHadChanges, isTrue);
      expect(p.conversionAcknowledged, isTrue);
      expect(p.conversionNeedsAttention, isFalse);
    });

    test('never shows for a file that needed nothing', () {
      final p = AppStateProvider(autoLoadSettings: false);
      expect(p.lastLoadHadChanges, isFalse);
      expect(p.conversionNeedsAttention, isFalse);
      // And acknowledging a conversion that never happened cannot light it.
      p.acknowledgeConversion();
      expect(p.conversionNeedsAttention, isFalse);
    });

    test('discarding the changes clears both flags', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..lastLoadHadChanges = true;
      p.acknowledgeConversion();

      // What revertToOriginalLoad leaves behind: nothing was converted, so
      // there is nothing to flag and nothing to have acknowledged.
      p
        ..lastLoadHadChanges = false
        ..conversionAcknowledged = false;
      expect(p.conversionNeedsAttention, isFalse);
    });

    test('the next load that needs converting lights it again', () {
      final p = AppStateProvider(autoLoadSettings: false)
        ..lastLoadHadChanges = true;
      p.acknowledgeConversion();
      expect(p.conversionNeedsAttention, isFalse);

      // What a load does: sets the flag from what it found and clears the
      // acknowledgement, so reopening a file that still needs work says so.
      p
        ..lastLoadHadChanges = true
        ..conversionAcknowledged = false;
      expect(p.conversionNeedsAttention, isTrue);
    });
  });

  /// The wiring the unit tests above cannot see: that the toolbar actually
  /// draws the count, that Acknowledge is actually connected, and that the
  /// button repaints without the file being reopened.
  group('driven through the real toolbar', () {
    Future<AppStateProvider> pumpShell(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final provider = AppStateProvider(autoLoadSettings: false)
        ..processors =
            jsonDecode(File('processors.json').readAsStringSync()) as List
        ..buildings =
            jsonDecode(File('buildings.json').readAsStringSync())
                as Map<String, dynamic>
        ..settingsLoaded = true
        ..firstRunSetupNeeded = false;

      // A legacy file that came in needing three changes.
      provider.lastLoadHadChanges = true;
      provider.systemLogs.addAll([
        'LEGACY CONFIG UPDATED',
        'DEFAULTS injected for SYSTEM_SETUP',
        'WARNING one field could not be mapped',
      ]);

      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: const RoomConfigApp(),
        ),
      );
      await tester.pumpAndSettle();
      return provider;
    }

    testWidgets('acknowledging takes the count down without a reload', (
      tester,
    ) async {
      final provider = await pumpShell(tester);

      final badge = find.byType(Badge);
      expect(badge, findsOneWidget);
      expect(tester.widget<Badge>(badge).isLabelVisible, isTrue);

      await tester.tap(
        find.byTooltip('Convert — review the changes this file needs'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Legacy Config Updated'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Acknowledge'));
      await tester.pumpAndSettle();

      // Repainted on the spot — no reopening the file.
      expect(tester.widget<Badge>(find.byType(Badge)).isLabelVisible, isFalse);
      expect(provider.conversionNeedsAttention, isFalse);

      // And the log is still one click away.
      expect(
        find.byTooltip('Conversion reviewed — open the log again'),
        findsOneWidget,
      );
      await tester.tap(
        find.byTooltip('Conversion reviewed — open the log again'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Legacy Config Updated'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
