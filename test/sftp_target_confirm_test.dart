import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';

/// Changing the room in the SFTP dialog used to be silent and immediate: the IP
/// was swapped under a password that was already typed, so the next click on
/// Upload pushed the config at whatever room a stray tap had landed on.
///
/// The guard: clear both fields, confirm the new room by name and IP, and only
/// then fill the IP in — leaving the password blank so a transfer can never
/// ride on credentials entered for the previous target.
void main() {
  /// Two rooms to switch between.
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

  Future<AppStateProvider> pumpDialog(WidgetTester tester,
      {required bool isUpload}) async {
    final provider = AppStateProvider(autoLoadSettings: false)
      ..processors = processors()
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

  /// The text currently in the field labelled [label].
  String fieldText(WidgetTester tester, String label) {
    final field = tester.widget<TextField>(
      find.ancestor(
        of: find.text(label),
        matching: find.byType(TextField),
      ).first,
    );
    return field.controller?.text ?? '';
  }

  /// Types a password, then picks the OTHER room from the search list.
  Future<void> pickOtherRoom(WidgetTester tester) async {
    await tester.enterText(
        find.widgetWithText(TextField, 'Admin Password'), 'secret');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextField, 'Search Room / Building'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Search Room / Building'), 'ajh125b');
    await tester.pumpAndSettle();
    // The separator-insensitive search finds "AJH 125B" from "ajh125b"
    await tester.tap(find.textContaining('AJH 125B').last);
    await tester.pumpAndSettle();
  }

  testWidgets('picking another room asks before touching the fields',
      (tester) async {
    await pumpDialog(tester, isUpload: true);
    expect(fieldText(tester, 'Processor IP / Hostname'), '10.248.103.8');

    await pickOtherRoom(tester);

    // A confirmation naming the room and its IP, not a silent swap
    expect(find.text('Upload to this room?'), findsOneWidget);
    expect(find.text('AJH 125B'), findsWidgets);
    expect(find.text('10.248.125.8'), findsOneWidget);
  });

  testWidgets('confirming fills the new IP and leaves the password blank',
      (tester) async {
    final provider = await pumpDialog(tester, isUpload: true);

    await pickOtherRoom(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Use This Room'));
    await tester.pumpAndSettle();

    expect(fieldText(tester, 'Processor IP / Hostname'), '10.248.125.8');
    expect(fieldText(tester, 'Admin Password'), '',
        reason: 'an upload must not ride on the previous room\'s password');
    expect(provider.selectedProcessor?['roomName'], 'AJH 125B');
  });

  testWidgets('cancelling keeps the old target and still clears the password',
      (tester) async {
    final provider = await pumpDialog(tester, isUpload: true);

    await pickOtherRoom(tester);
    // The SFTP dialog has its own Cancel — target the confirmation's, by
    // scoping to the dialog that carries the Use This Room button.
    final confirmDialog = find.ancestor(
        of: find.text('Use This Room'), matching: find.byType(AlertDialog));
    await tester.tap(find.descendant(
        of: confirmDialog, matching: find.widgetWithText(TextButton, 'Cancel')));
    await tester.pumpAndSettle();

    // Previous target intact, everywhere it's shown
    expect(fieldText(tester, 'Processor IP / Hostname'), '10.248.103.8');
    expect(provider.selectedProcessor?['roomName'], 'BSS 103');
    // The password stays cleared — the safe side of the trade
    expect(fieldText(tester, 'Admin Password'), '');
    // ...and the search box snaps back off the room that was rejected
    expect(fieldText(tester, 'Search Room / Building'), contains('BSS 103'));
  });

  testWidgets('the download dialog asks in its own words', (tester) async {
    await pumpDialog(tester, isUpload: false);
    await pickOtherRoom(tester);
    expect(find.text('Download from this room?'), findsOneWidget);
  });
}
