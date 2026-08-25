import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/main.dart';
import 'package:extron_configurator/room_sidecar.dart';

/// Who changed what IN A ROOM.
///
/// The job has kept a log of its own decisions for a while. The room kept
/// none, so "who moved this onto the other switcher" and "when did this stop
/// saying 9600" had no answer at all. Two hooks cover it — the config field
/// writer and the undo stack — and what this guards is that they really do
/// cover it, and that a log does not bury itself in keystrokes.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('room_history_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103'},
        'PROJECTORDEVICE_1': {'baud': '9600', 'ipaddress': ''},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  group('a config field', () {
    test('is logged with what it was and what it became', () {
      final p = room();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'baud', '115200');

      final entry = p.roomHistory.single;
      expect(entry.itemKey, 'device:PROJECTORDEVICE_1');
      expect(entry.field, 'baud');
      // WHAT CHANGED, not just what it says now — the config already answers
      // the second one.
      expect(entry.summary, 'was 9600, now 115200');
    });

    test('a field that was empty reads as set, and back as cleared', () {
      final p = room();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'ipaddress', '10.0.0.4');
      expect(p.roomHistory.last.summary, 'set to 10.0.0.4');

      p.updateDeviceValue('PROJECTORDEVICE_1', 'baud', '');
      expect(p.roomHistory.last.summary, 'cleared (was 9600)');
    });

    test('writing the same value again is not a change', () {
      final p = room();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'baud', '9600');
      expect(p.roomHistory, isEmpty);
    });

    test('typing is one decision, not forty', () {
      final p = room();
      for (final text in ['1', '10', '10.', '10.0', '10.0.0', '10.0.0.4']) {
        p.updateDeviceValue('PROJECTORDEVICE_1', 'ipaddress', text);
      }
      // One entry, carrying where the typing ended up.
      expect(p.roomHistory, hasLength(1));
      expect(p.roomHistory.single.summary, 'set to 10.0.0.4');
    });

    test('a long value is cut rather than pushing the row off the screen', () {
      final p = room();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'ipaddress', 'x' * 200);
      expect(p.roomHistory.single.summary.length, lessThan(60));
      expect(p.roomHistory.single.summary, contains('…'));
    });

    test('nothing is logged with no room open', () {
      final p = AppStateProvider(autoLoadSettings: false);
      p.updateDeviceValue('PROJECTORDEVICE_1', 'baud', '115200');
      expect(p.roomHistory, isEmpty);
    });
  });

  group('an edit to the drawing', () {
    test('rides on the undo stack, naming the tab it happened on', () {
      final p = room();
      p.addAvNode(
        const AvNode(
          id: 'SWITCHERDEVICE_1',
          label: 'Switcher',
          model: 'SW1',
          pos: Offset.zero,
          ports: [],
        ),
      );
      // Adding a node takes its own snapshot; editing one pushes an undo entry
      // with a sentence on it.
      p.updateAvNode(
        p.avNodeById('SWITCHERDEVICE_1')!.copyWith(label: 'Rack switcher'),
      );

      final entry = p.roomHistory.last;
      expect(entry.field, 'Drawing');
      expect(entry.itemName, contains('AV Flow'));
      expect(entry.summary, contains('Rack switcher'));
    });

    test('an install date says which box it was set on', () {
      final p = room();
      p.addAvNode(
        const AvNode(
          id: 'PROJECTORDEVICE_1',
          label: 'Projector 1',
          model: 'PROJ-1',
          pos: Offset.zero,
          ports: [],
        ),
      );
      p.setAvNodeInstalledOn('PROJECTORDEVICE_1', DateTime(2018, 4, 1));
      expect(p.roomHistory.last.summary, contains('Projector 1'));
    });
  });

  group('the file', () {
    test('the log is written beside the room and read back', () async {
      final configPath = '${dir.path}/BSS103_config.json';
      File(configPath).writeAsStringSync('{"SYSTEM_SETUP":{}}');

      final p = room()..currentConfigPath = configPath;
      p.updateDeviceValue('PROJECTORDEVICE_1', 'baud', '115200');
      await p.saveAvFlow();

      final file = File(roomSidecarPath(configPath, RoomSidecarPart.history));
      expect(file.existsSync(), isTrue,
          reason: 'the log gets a file of its own beside the room');
      final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(doc['roomHistory'], hasLength(1));

      // ...and comes back on the next open.
      final reopened = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {'SYSTEM_SETUP': {}}
        ..currentConfigPath = configPath;
      reopened.loadAvFlowForCurrentConfig();
      expect(reopened.roomHistory, hasLength(1));
      expect(reopened.roomHistory.single.summary, 'was 9600, now 115200');
    });

    test('a room whose only change is a field still has something to save',
        () {
      final p = room();
      expect(p.hasAvFlow, isFalse, reason: 'nothing drawn, nothing estimated');
      p.updateDeviceValue('PROJECTORDEVICE_1', 'baud', '115200');
      expect(
        p.hasAvFlow,
        isTrue,
        reason: 'a control-only room must not lose its log on save',
      );
    });

    test('a room with no log writes no key for one', () {
      expect(room().avFlowAsJson().containsKey('roomHistory'), isFalse);
    });

    test('opening a different room does not inherit the last log', () {
      final p = room();
      p.updateDeviceValue('PROJECTORDEVICE_1', 'baud', '115200');
      expect(p.roomHistory, isNotEmpty);
      p.loadAvFlowForCurrentConfig();
      expect(p.roomHistory, isEmpty);
    });
  });

  group('the History screen', () {
    testWidgets('is on the toolbar, and carries both logs', (tester) async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..settingsLoaded = true
        ..firstRunSetupNeeded = false
        ..roomConfig = {
          'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103'},
          'PROJECTORDEVICE_1': {'baud': '9600'},
        };
      p.loadAvFlowForCurrentConfig();
      p.newProject(name: 'Bessey Hall');
      p.setProjectDeadline(DateTime(2026, 9, 14));
      p.updateDeviceValue('PROJECTORDEVICE_1', 'baud', '115200');

      tester.view.physicalSize = const Size(1800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const RoomConfigApp(),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('show_history')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('history_dialog')), findsOneWidget);
      // One line from each log, on one screen, each saying where it came from.
      expect(find.textContaining('was 9600, now 115200', findRichText: true), findsOneWidget);
      expect(find.textContaining('Delivery deadline', findRichText: true), findsOneWidget);
      expect(find.text('ROOM'), findsOneWidget);
      expect(find.text('JOB'), findsOneWidget);
    });

    testWidgets('can be narrowed to one log or the other', (tester) async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..settingsLoaded = true
        ..firstRunSetupNeeded = false
        ..roomConfig = {
          'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103'},
          'PROJECTORDEVICE_1': {'baud': '9600'},
        };
      p.loadAvFlowForCurrentConfig();
      p.newProject(name: 'Bessey Hall');
      p.setProjectDeadline(DateTime(2026, 9, 14));
      p.updateDeviceValue('PROJECTORDEVICE_1', 'baud', '115200');

      tester.view.physicalSize = const Size(1800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const RoomConfigApp(),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('show_history')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('history_scope_room')));
      await tester.pumpAndSettle();
      expect(find.textContaining('was 9600, now 115200', findRichText: true), findsOneWidget);
      expect(find.textContaining('Delivery deadline', findRichText: true), findsNothing);

      await tester.tap(find.byKey(const ValueKey('history_scope_project')));
      await tester.pumpAndSettle();
      expect(find.textContaining('was 9600, now 115200', findRichText: true), findsNothing);
      expect(find.textContaining('Delivery deadline', findRichText: true), findsOneWidget);
    });
  });
}
