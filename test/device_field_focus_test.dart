import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/dynamic_devices_view.dart';

/// A converted room arrives without half the keys the schema offers — the
/// serial device with no baud rate in the file is the everyday case. Those are
/// rendered as PLACEHOLDER fields, and the first keystroke in one writes the
/// key into the config.
///
/// Which used to move the field. Placeholders were listed after the real
/// fields, so the moment "9" was typed, baud became a real key, sorted into its
/// alphabetical place near the top of the form, and left the visible part of a
/// lazy ListView — taking the caret with it, so the "600" went nowhere. One
/// sorted list of real and offered keys is what stops it.
void main() {
  late AppStateProvider provider;

  // The schema is loaded OUTSIDE testWidgets: real file I/O awaited inside one
  // never completes, because the test body runs in fake async.
  setUp(() async {
    provider = AppStateProvider(autoLoadSettings: false);
    await provider.loadUiSchema();
    provider.roomConfig = {
      'SYSTEM_SETUP': {'dev_projectors': '1'},
      // A serial device as a conversion leaves it: no baud, no keep-alive.
      'PROJECTORDEVICE_1': {
        'name': 'Projector',
        'model': 'PT-FW430U',
        'com_type': 'Serial',
        'serial_port': 'COM2',
      },
    };
  });

  Future<void> pumpForm(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const MaterialApp(
          home: Scaffold(
            body: DeviceConfigurationForm(deviceKey: 'PROJECTORDEVICE_1'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The baud field, found by the key its builder stamps on it.
  final baud = find.byKey(const ValueKey('PROJECTORDEVICE_1.baud'));

  /// The text inside a keyed field.
  Finder editableIn(Finder field) =>
      find.descendant(of: field, matching: find.byType(EditableText));

  double topOf(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

  testWidgets('a key the file never had is offered in its sorted position',
      (tester) async {
    await pumpForm(tester);
    expect(baud, findsOneWidget);

    // Sorted in with the real keys rather than parked in a group after them:
    // 'baud' comes before 'keep_alive_qualifier', which is offered the same
    // way and would otherwise be its neighbour at the bottom of the form.
    expect(
      topOf(tester, baud),
      lessThan(
        topOf(
          tester,
          find.byKey(const ValueKey('PROJECTORDEVICE_1.keep_alive_qualifier')),
        ),
      ),
    );
  });

  testWidgets('typing a baud rate keeps the caret and the field where it was',
      (tester) async {
    await pumpForm(tester);
    final before = topOf(tester, baud);

    // The first keystroke is the one that used to lose the field: it writes
    // 'baud' into the config for the first time.
    await tester.enterText(editableIn(baud), '9');
    await tester.pump();
    expect((provider.roomConfig['PROJECTORDEVICE_1'] as Map)['baud'], 9);
    expect(topOf(tester, baud), before, reason: 'the field must not move');
    expect(
      tester.widget<EditableText>(editableIn(baud)).focusNode.hasFocus,
      isTrue,
      reason: 'and it must keep the caret',
    );

    // ...so the rest of the number goes into the same box, which is the whole
    // point: a field that loses focus after one digit cannot be typed into.
    await tester.enterText(editableIn(baud), '9600');
    await tester.pump();
    expect((provider.roomConfig['PROJECTORDEVICE_1'] as Map)['baud'], 9600);
    expect(topOf(tester, baud), before);
  });

  testWidgets('a block whose values are all strings still takes a number',
      (tester) async {
    // The other half of the same bug, and the one with no symptom at all: a
    // device block typed as Map<String, String> — by a preset, a wizard, or
    // anything building it from a Dart literal — threw
    // "type 'int' is not a subtype of type 'String'" from inside onChanged,
    // where nothing surfaces it. The digit simply never landed.
    provider.roomConfig = {
      'SYSTEM_SETUP': <String, String>{'dev_projectors': '1'},
      'PROJECTORDEVICE_1': <String, String>{
        'name': 'Projector',
        'com_type': 'Serial',
        'serial_port': 'COM2',
      },
    };
    await pumpForm(tester);

    await tester.enterText(editableIn(baud), '38400');
    await tester.pump();
    expect((provider.roomConfig['PROJECTORDEVICE_1'] as Map)['baud'], 38400);
  });

  testWidgets('the offered key still disappears when the schema hides it',
      (tester) async {
    // baud is Serial-only. A network device must not be offered one, sorted
    // into place or otherwise.
    (provider.roomConfig['PROJECTORDEVICE_1'] as Map)['com_type'] = 'Network';
    await pumpForm(tester);
    expect(baud, findsNothing);
  });
}
