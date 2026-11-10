import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:extron_configurator/projection_calc.dart';
import 'package:extron_configurator/projection_calculator_dialog.dart';

const _specs = [
  ProjectorSpecs(source: 'PJ', throwMin: 1.5, throwMax: 2.5, lumens: 6000),
  ProjectorSpecs(source: 'Lens B', throwMin: 0.8, throwMax: 1, lumens: 6000),
];

void main() {
  setUp(resetProjectionUnits);

  /// Opens the calculator from a button, keeping what it saves in [saved].
  Future<void> open(
    WidgetTester tester,
    List<Map<String, dynamic>> saved, {
    Map<String, dynamic> kept = const {},
    List<ProjectorSpecs> specs = _specs,
  }) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showProjectionCalculator(
                context,
                specs: specs,
                kept: kept,
                onKeep: (inputs, _) => saved.add(inputs),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('zoom, aspect and the rest lock and are saved locked', (
    tester,
  ) async {
    final saved = <Map<String, dynamic>>[];
    await open(tester, saved);
    for (final n in ['spec', 'zoom', 'aspect', 'sizeBy', 'mode']) {
      await tester.tap(find.byKey(ValueKey('lock_opt_$n')));
      await tester.pump();
    }
    final aspect = tester.widget<DropdownButton<ScreenAspect>>(
      find.descendant(
        of: find.byKey(const ValueKey('projection_aspect')),
        matching: find.byType(DropdownButton<ScreenAspect>),
      ),
    );
    expect(aspect.onChanged, isNull);
    final mode = tester.widget<SegmentedButton<bool>>(
      find.byKey(const ValueKey('projection_mode')),
    );
    expect(mode.onSelectionChanged, isNull);

    await tester.tap(find.byKey(const ValueKey('projection_keep')));
    await tester.pumpAndSettle();
    expect(saved.last['locked'],
        containsAll(['spec', 'zoom', 'aspect', 'sizeBy', 'mode']));
    expect(saved.last['specSource'], 'PJ');
  });

  testWidgets('Lock all locks every box and choice, and unlocks them', (
    tester,
  ) async {
    final saved = <Map<String, dynamic>>[];
    await open(tester, saved);
    await tester.tap(find.byKey(const ValueKey('projection_lock_all')));
    await tester.pump();
    final gain = find.byKey(const ValueKey('projection_gain'));
    expect(tester.widget<TextField>(gain).readOnly, isTrue);
    expect(find.text('Unlock all'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('projection_lock_all')));
    await tester.pump();
    expect(tester.widget<TextField>(gain).readOnly, isFalse);
  });

  testWidgets('opens again with the lens by name, zoom and locks', (
    tester,
  ) async {
    final saved = <Map<String, dynamic>>[];
    // Kept when Lens B was first in the list.
    await open(tester, saved, kept: {
      'spec': 0,
      'specSource': 'Lens B',
      'throwMin': '0.8',
      'throwMax': '1',
      'zoom': 0.25,
      'aspect': '16:9',
      'gain': '1.3',
      'locked': ['zoom', 'aspect', 'gain'],
    });
    final spec = tester.widget<DropdownButton<int>>(
      find.descendant(
        of: find.byKey(const ValueKey('projection_spec')),
        matching: find.byType(DropdownButton<int>),
      ),
    );
    expect(spec.value, 1);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('projection_gain')))
          .readOnly,
      isTrue,
    );
    expect(find.text('0.85:1'), findsWidgets);
    expect(find.byIcon(Icons.lock), findsNWidgets(3));
  });

  testWidgets('Close asks to save changes, and saves them', (tester) async {
    final saved = <Map<String, dynamic>>[];
    await open(tester, saved);
    // Nothing changed: it just closes.
    await tester.tap(find.byKey(const ValueKey('projection_close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('projection_gain')), findsNothing);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('projection_gain')), '1.5');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('projection_close')));
    await tester.pumpAndSettle();
    expect(find.text('Save changes?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('projection_close_save')));
    await tester.pumpAndSettle();
    expect(saved.single['gain'], '1.5');
    expect(find.byKey(const ValueKey('projection_gain')), findsNothing);
  });
}
