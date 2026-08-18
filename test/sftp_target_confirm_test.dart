import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// The SFTP dialog must never sit showing one room's IP while a different room
/// is being picked — that stale pairing is how a transfer lands on the wrong
/// processor. Touching the search drops the connection details; choosing a room
/// puts the new ones in.
///
/// Also covers the App Config default password being pre-filled.
void main() {
  List<Map<String, dynamic>> processors() => [
        {'roomId': '1', 'roomName': 'BSS 103', 'ip': '10.248.103.8'},
        {'roomId': '2', 'roomName': 'AJH 125B', 'ip': '10.248.125.8'},
      ];

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

  Future<AppStateProvider> pumpDialog(
    WidgetTester tester, {
    bool isUpload = true,
    String savedPassword = '',
    bool usePassword = false,
  }) async {
    final provider = AppStateProvider(autoLoadSettings: false)
      ..processors = processors()
      ..defaultProcessorPassword = savedPassword
      ..useDefaultProcessorPassword = usePassword
      // Open with BSS 103 already the active target, as the dialog does when a
      // deployment target is set.
      ..selectProcessor(processors().first);

    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: Scaffold(body: ProcessorSftpDialog(isUpload: isUpload)),
      ),
    ));
    await tester.pumpAndSettle();
    return provider;
  }

  String fieldText(WidgetTester tester, String label) {
    final field = tester.widget<TextField>(
      find.ancestor(of: find.text(label), matching: find.byType(TextField)).first,
    );
    return field.controller?.text ?? '';
  }

  Finder search() => find.widgetWithText(TextField, 'Search Room / Building');

  testWidgets('touching the search clears the outgoing room\'s IP',
      (tester) async {
    final provider = await pumpDialog(tester);
    expect(fieldText(tester, 'Processor IP / Hostname'), '10.248.103.8');

    // Just focusing the search is enough — no keystroke needed
    await tester.tap(search());
    await tester.pumpAndSettle();

    expect(fieldText(tester, 'Processor IP / Hostname'), '',
        reason: 'the previous room\'s IP must not linger during a re-pick');
    expect(provider.selectedProcessor, isNull);
    // ...and nothing is in the way: the dialog itself IS an AlertDialog, so
    // the check is for the confirmation's own button, which should be gone.
    expect(find.text('Use This Room'), findsNothing);
  });

  testWidgets('picking a room fills its IP straight in, no confirmation',
      (tester) async {
    final provider = await pumpDialog(tester);

    await tester.tap(search());
    await tester.pumpAndSettle();
    // Separator-insensitive search: "ajh125b" finds "AJH 125B"
    await tester.enterText(search(), 'ajh125b');
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('AJH 125B').last);
    await tester.pumpAndSettle();

    expect(fieldText(tester, 'Processor IP / Hostname'), '10.248.125.8');
    expect(provider.selectedProcessor?['roomName'], 'AJH 125B');
    expect(find.text('Use This Room'), findsNothing,
        reason: 'the confirmation step was removed');
  });

  testWidgets('Enter picks the highlighted room and fills its details',
      (tester) async {
    // Typing the room and reaching for the mouse to click the one entry the
    // list is now showing is the slow way round. Enter takes the highlighted
    // option — the top match, until the arrow keys move it — and that has to
    // fill the IP exactly as a click does.
    final provider = await pumpDialog(tester);

    await tester.tap(search());
    await tester.pumpAndSettle();
    await tester.enterText(search(), 'ajh125b');
    await tester.pumpAndSettle();

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(provider.selectedProcessor?['roomName'], 'AJH 125B');
    expect(fieldText(tester, 'Processor IP / Hostname'), '10.248.125.8');
  });

  testWidgets('the arrow keys move which room Enter takes', (tester) async {
    final provider = await pumpDialog(tester);

    await tester.tap(search());
    await tester.pumpAndSettle();
    // Both rooms match, so the highlight starts on the first and Down moves
    // it to the second.
    await tester.enterText(search(), '10.248.1');
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(provider.selectedProcessor?['roomName'], 'AJH 125B');
  });

  testWidgets('typing in the search also clears, before any pick',
      (tester) async {
    await pumpDialog(tester);
    await tester.enterText(search(), 'aj');
    await tester.pumpAndSettle();

    expect(fieldText(tester, 'Processor IP / Hostname'), '');
  });

  group('default password', () {
    testWidgets('is pre-filled when the toggle is on', (tester) async {
      await pumpDialog(tester, savedPassword: 'ATEC2007', usePassword: true);
      expect(fieldText(tester, 'Admin Password'), 'ATEC2007');
    });

    testWidgets('survives a room change (same credential room to room)',
        (tester) async {
      await pumpDialog(tester, savedPassword: 'ATEC2007', usePassword: true);

      await tester.tap(search());
      await tester.pumpAndSettle();
      await tester.enterText(search(), 'ajh125b');
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('AJH 125B').last);
      await tester.pumpAndSettle();

      expect(fieldText(tester, 'Admin Password'), 'ATEC2007');
    });

    testWidgets('stays blank when the toggle is off, even with one saved',
        (tester) async {
      await pumpDialog(tester, savedPassword: 'ATEC2007', usePassword: false);
      expect(fieldText(tester, 'Admin Password'), '');
    });
  });

  group('turning the toggle off', () {
    test('forgets the saved password', () async {
      final provider = AppStateProvider(autoLoadSettings: false)
        ..defaultProcessorPassword = 'ATEC2007'
        ..useDefaultProcessorPassword = true;
      expect(provider.autofillProcessorPassword, 'ATEC2007');

      await provider.setUseDefaultProcessorPassword(false);

      expect(provider.useDefaultProcessorPassword, isFalse);
      expect(provider.defaultProcessorPassword, '',
          reason: 'switching it off must get the value out of the settings file');
      expect(provider.autofillProcessorPassword, '');
    });
  });
}
