import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/dynamic_devices_view.dart';
import 'package:extron_configurator/ui_schema.dart';

/// A processor's serial port is COM1, COM2, COM3 - the word never varies, and
/// typing it on every device was three characters of nothing. So the field
/// asks for the NUMBER and writes the port: 3 on the tab, "COM3" in the file,
/// which is still exactly what the processor reads.
///
/// The value in config.json is unchanged by all this. What a device carries is
/// still "COM3", so a converted room, a driver's DEVICE_INFO and the schematic
/// all keep reading the same key the same way - the only thing that moved is
/// how much of it somebody has to type.
void main() {
  group('normalizeComPort', () {
    test('makes a port out of the number alone', () {
      expect(normalizeComPort('3'), 'COM3');
      expect(normalizeComPort(' 12 '), 'COM12');
    });

    test('accepts a port that already carries its prefix', () {
      // Pasted off a survey sheet, or typed out of habit.
      for (final typed in ['COM3', 'com3', 'Com 3', 'COM 3']) {
        expect(normalizeComPort(typed), 'COM3', reason: typed);
      }
    });

    test('reads a leading zero as the typing artifact it is', () {
      expect(normalizeComPort('01'), 'COM1');
      expect(normalizeComPort('0'), 'COM0');
    });

    test('leaves anything that is not a port number alone', () {
      // Not understood is not the same as wrong: a value nobody can explain
      // belongs on the tab where it can be seen, not silently rewritten.
      expect(normalizeComPort('/dev/ttyS1'), '/dev/ttyS1');
      expect(normalizeComPort('COM3A'), 'COM3A');
      expect(normalizeComPort('  '), '');
    });
  });

  group('comPortNumber', () {
    test('takes off the COM the field prints for itself', () {
      expect(comPortNumber('COM3'), '3');
      expect(comPortNumber('com 12'), '12');
      expect(comPortNumber(''), '');
      expect(comPortNumber(null), '');
    });

    test('shows a value it does not understand whole', () {
      expect(comPortNumber('/dev/ttyS1'), '/dev/ttyS1');
    });
  });

  group('the device tab', () {
    late AppStateProvider provider;

    // The schema is loaded OUTSIDE testWidgets: real file I/O awaited inside
    // one never completes, because the test body runs in fake async.
    setUp(() async {
      provider = AppStateProvider(autoLoadSettings: false);
      await provider.loadUiSchema();
      provider.roomConfig = {
        'SYSTEM_SETUP': {'dev_projectors': '1'},
        'PROJECTORDEVICE_1': {
          'name': 'Projector',
          'com_type': 'Serial',
        },
      };
    });

    Future<void> pumpForm(WidgetTester tester) async {
      // Tall enough to build the whole form: the device form is a lazy
      // ListView, so a field below the fold does not exist to find.
      tester.view.physicalSize = const Size(1200, 1400);
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

    final port = find.byKey(const ValueKey('PROJECTORDEVICE_1.serial_port'));
    Finder editableIn(Finder field) =>
        find.descendant(of: field, matching: find.byType(EditableText));

    String? stored() =>
        (provider.roomConfig['PROJECTORDEVICE_1'] as Map)['serial_port']
            as String?;

    test('is the schema entry that drives the field', () {
      expect(provider.uiSchema.specFor('serial_port')?.type, 'com_port');
    });

    testWidgets('writes COM3 when 3 is typed', (tester) async {
      await pumpForm(tester);
      expect(port, findsOneWidget);

      await tester.enterText(editableIn(port), '3');
      await tester.pump();
      expect(stored(), 'COM3');
    });

    testWidgets('shows a stored port as its number', (tester) async {
      (provider.roomConfig['PROJECTORDEVICE_1'] as Map)['serial_port'] = 'COM2';
      await pumpForm(tester);
      expect(tester.widget<EditableText>(editableIn(port)).controller.text, '2');
    });

    testWidgets('prints the COM beside the number', (tester) async {
      (provider.roomConfig['PROJECTORDEVICE_1'] as Map)['serial_port'] = 'COM2';
      await pumpForm(tester);
      expect(
        tester
            .widget<TextField>(
                find.descendant(of: port, matching: find.byType(TextField)))
            .decoration
            ?.prefixText,
        'COM',
      );
    });

    testWidgets('still takes a whole port typed out', (tester) async {
      await pumpForm(tester);
      await tester.enterText(editableIn(port), 'COM6');
      await tester.pump();
      expect(stored(), 'COM6');
    });

    testWidgets('keeps a value that is not a port number', (tester) async {
      await pumpForm(tester);
      await tester.enterText(editableIn(port), '/dev/ttyS1');
      await tester.pump();
      expect(stored(), '/dev/ttyS1');
      // ...and stops printing a COM in front of it.
      expect(
        tester
            .widget<TextField>(
                find.descendant(of: port, matching: find.byType(TextField)))
            .decoration
            ?.prefixText,
        isNull,
      );
    });
  });
}
