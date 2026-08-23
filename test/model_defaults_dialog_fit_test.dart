import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/config_key_mapper.dart';
import 'package:extron_configurator/model_defaults_audit.dart';
import 'package:extron_configurator/model_defaults_dialog.dart';

/// ============================================================================
///  THE DRIVER-DEFAULTS REVIEW HAS TO FIT THE TEXT SIZE IT IS READ AT
/// ============================================================================
///  The review's connection picker offers "As configured", every connection
///  the drivers in this room describe, and "Original File" — up to seven
///  choices. They used to be a SegmentedButton in a fixed 720-pixel box, and a
///  segmented button does not wrap: at 130% text the row ran off the end and
///  the last connection, usually Network, could not be reached at all. It was
///  inside a horizontal scroll view, which is not an affordance anybody sees —
///  a button cut in half reads as a broken button, not as "scroll me".
///
///  So the choices wrap, and the dialog grows with the text scale up to what
///  the window can show. These tests are at 150%, the largest App Config
///  offers, because that is where it broke.
/// ============================================================================
/// The same legacy room the audit tests use: three devices whose drivers
/// disagree with what the conversion left behind, across several connection
/// styles — which is what puts more than two chips in the picker.
Future<void> _applyLegacyRoom(AppStateProvider provider) async {
  final map = await ConfigKeyMap.load(explicitPath: 'key_map.json');
  provider.roomConfig = map.apply({
    'SYSTEM_SETUP': {
      'dev_wireless': '1',
      'dev_power_controllers': '1',
      'gui_routing_mode': 'Normal',
    },
    'WIRELESSDEVICE_1': {
      'com_type': 'Network',
      'model': 'VIA GO',
      'ip_address': '10.0.0.9',
    },
    'DSPDEVICE_1': {
      'com_type': 'Network',
      'model': 'DMP 64 Plus C AT',
      'ip_address': '10.0.0.5',
      'protocol': 'TCP',
    },
    'POWERDEVICE_1': {
      'com_type': 'Network',
      'model': 'AP7921B',
      'ip_address': '10.0.0.8',
    },
  }).config;
}

void main() {
  late AppStateProvider provider;

  setUp(() {
    provider = AppStateProvider(autoLoadSettings: false)
      ..modulesPath = path.join(Directory.current.path, 'device');
  });

  /// Reads the shipped driver library, schema and key map into [provider].
  ///
  /// Through [WidgetTester.runAsync], and NOT from setUp: a testWidgets body
  /// runs on a fake clock, and real file I/O awaited on that clock never
  /// completes — the whole file simply hangs.
  Future<void> loadRoom(WidgetTester tester) async {
    await tester.runAsync(() async {
      await provider.preloadAllModules();
      await provider.loadUiSchema();
      await _applyLegacyRoom(provider);
    });
  }


  /// Opens the review at [scale] text, in a window of [size].
  Future<void> openReview(
    WidgetTester tester, {
    double scale = 1.5,
    Size size = const Size(1280, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => offerModelDefaults(ctx, provider),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('every connection is reachable at 150% text', (tester) async {
    await loadRoom(tester);
    final styles = comparableComTypes(provider);
    expect(styles, isNotEmpty,
        reason: 'this room has to offer connections for there to be a row');

    await openReview(tester);
    expect(find.byType(AlertDialog), findsOneWidget);

    // Every chip the picker should carry, and none of them clipped: a widget
    // that is present but outside its parent cannot be hit, which is exactly
    // what "the Network button is cut off" was.
    final dialog = tester.getRect(
      find.byKey(const ValueKey('model_defaults_content')),
    );
    for (final value in ['', ...styles]) {
      final chip = find.byKey(ValueKey('compare_$value'));
      expect(chip, findsOneWidget, reason: 'missing the "$value" choice');
      final box = tester.getRect(chip);
      expect(dialog.contains(box.centerLeft), isTrue,
          reason: '"$value" starts outside the dialog');
      expect(dialog.contains(box.centerRight), isTrue,
          reason: '"$value" runs off the end of the dialog - the bug this '
              'test exists for');
    }
  });

  testWidgets('the picker still works when it has wrapped', (tester) async {
    await loadRoom(tester);
    final styles = comparableComTypes(provider);
    await openReview(tester);

    // Tapping the LAST choice — the one that used to be off the end.
    await tester.tap(find.byKey(ValueKey('compare_${styles.last}')));
    await tester.pumpAndSettle();

    final chip = tester.widget<ChoiceChip>(
      find.byKey(ValueKey('compare_${styles.last}')),
    );
    expect(chip.selected, isTrue);
  });

  testWidgets('the dialog never grows past the window', (tester) async {
    await loadRoom(tester);
    // A small window at the largest text size: the box has to stop at what
    // the screen can show rather than at the number it would like to be.
    await openReview(tester, scale: 1.5, size: const Size(900, 600));

    expect(tester.takeException(), isNull,
        reason: 'nothing overflows, however little room there is');
    final dialog = tester.getRect(
      find.byKey(const ValueKey('model_defaults_content')),
    );
    expect(dialog.width, lessThanOrEqualTo(900));
    expect(dialog.height, lessThanOrEqualTo(600));
  });

  testWidgets('a bigger text size gets a bigger dialog', (tester) async {
    await loadRoom(tester);
    await openReview(tester, scale: 1.0, size: const Size(1600, 1000));
    final small = tester
        .getRect(find.byKey(const ValueKey('model_defaults_content')))
        .width;

    await tester.tap(find.text('Keep what the file has'));
    await tester.pumpAndSettle();

    await openReview(tester, scale: 1.5, size: const Size(1600, 1000));
    final large = tester
        .getRect(find.byKey(const ValueKey('model_defaults_content')))
        .width;

    expect(large, greaterThan(small),
        reason: 'the box grows with the text rather than clipping it');
  });
}
