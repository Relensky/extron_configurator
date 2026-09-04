import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/device_info_editor.dart';
import 'package:extron_configurator/device_info_source.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  WRITING A DRIVER'S DEVICE_INFO INSTEAD OF TYPING IT
/// ============================================================================
///  A driver with no DEVICE_INFO is invisible: it parses, its models never
///  reach the Model dropdown, nothing can review a room against its connection
///  settings, and there is no message anywhere saying so. The block used to be
///  hand-written, or written once by a script nobody runs again.
///
///  Held here: that a scan reads what the file really does say (the models,
///  the wrapper classes, the baud rate and protocol they default to), that it
///  does NOT invent what a driver never declares (the TCP port), that what it
///  formats parses straight back through the app's own reader, and that
///  writing it into a file replaces the block rather than growing a second one.
/// ============================================================================
void main() {
  /// A driver shaped like the ones in device/: models, an Update method to
  /// poll on, and the three wrapper classes at the bottom.
  const driver = '''
from extronlib.interface import SerialInterface, EthernetClientInterface
import re


class DeviceClass:

    def __init__(self):
        self.Models = {
            'BrightLink 696Ui': self.epsn_1_2422_HDMI3,
            'EB-1440Ui': self.epsn_1_2422_Default,
            }

    def UpdatePower(self, value, qualifier):
        pass

    def UpdateLampUsage(self, value, qualifier):
        pass


class SerialClass(SerialInterface, DeviceClass):

    def __init__(self, Host, Port, Baud=38400, Data=8, Parity='None', Stop=1, FlowControl='Off', CharDelay=0, Mode='RS232', Model=None):
        pass


class SerialOverEthernetClass(EthernetClientInterface, DeviceClass):

    def __init__(self, Hostname, IPPort, Protocol='TCP', ServicePort=0, Model=None):
        pass


class EthernetClass(EthernetClientInterface, DeviceClass):

    def __init__(self, Hostname, IPPort, Protocol='TCP', ServicePort=0, Model=None):
        pass
''';

  group('scanning a driver', () {
    test('reads the models out of self.Models', () {
      final scan = scanModuleSource(driver, fileName: 'epsn_vp_BrightLink.py');
      expect(scan.draft.models, ['BrightLink 696Ui', 'EB-1440Ui']);
    });

    test('reads the device family off the file name', () {
      expect(
        scanModuleSource(driver, fileName: 'epsn_vp_BrightLink.py')
            .draft
            .deviceTypes,
        ['projector'],
      );
      expect(
        scanModuleSource(driver, fileName: 'extr_dsp_DMP_64.py')
            .draft
            .deviceTypes,
        ['dsp'],
      );
      // AMBIGUOUS IS LEFT BLANK. 'sm' is the SMP recorder in one file and the
      // NAVigator switcher in the next; a family filled in wrong puts the
      // models on a tab nobody looking for them will check.
      expect(
        scanModuleSource(driver, fileName: 'extr_sm_NAVigator.py')
            .draft
            .deviceTypes,
        isEmpty,
      );
    });

    test('reads baud, protocol and service port off the wrapper classes', () {
      final draft = scanModuleSource(driver, fileName: 'epsn_vp_X.py').draft;
      expect(draft.comTypes['serial']?['baud'], 38400);
      expect(draft.comTypes['network']?['protocol'], 'TCP');
      expect(draft.comTypes['network']?['service_port'], 0);
      // The gateway a SerialOverEthernet device is really reached through.
      expect(draft.comTypes['serialoverethernet']?['net_port'],
          kSerialOverEthernetPort);
    });

    test('does not invent the network port, and says why', () {
      final scan = scanModuleSource(driver, fileName: 'epsn_vp_X.py');
      // IPPort is passed IN to every wrapper in the folder - the driver is
      // told which port to use and has no opinion - so a scan that produced
      // one would be producing a number off nothing.
      expect(scan.draft.connection.containsKey('net_port'), isFalse);
      expect(
        scan.notes.any((n) => n.contains('communication sheet')),
        isTrue,
        reason: 'the missing port has to be said out loud',
      );
    });

    test('seeds the house style for the family, keep-alive checked against '
        'the driver', () {
      final draft = scanModuleSource(driver, fileName: 'epsn_vp_X.py').draft;
      expect(draft.defaults['btn_name'], 'Btn_Con_Projector1');
      expect(draft.defaults['gve_id'], 'Proj1');
      // Every projector in the folder polls Power at ten seconds, and this
      // driver really has UpdatePower.
      expect(draft.defaults['keep_alive_command'], 'Power');
      expect(draft.defaults['keep_alive_interval'], 10);
      expect(draft.defaults['name'], 'Projector - Epson BrightLink 696Ui');
    });

    test('a keep-alive the driver does not have is not left in the block', () {
      // The house style for a DSP is PartNumber; this file has no such
      // command, so writing it would put a poll in the config that the
      // processor cannot send.
      final scan = scanModuleSource(driver, fileName: 'extr_dsp_Thing.py');
      expect(scan.draft.defaults['keep_alive_command'], 'Power');
      expect(scan.notes.any((n) => n.contains('no "PartNumber" command')),
          isTrue);
    });
  });

  group('formatting the block', () {
    test('what it writes is what the app reads back', () {
      // The round trip is the whole contract: a block this formats that the
      // app's own parser cannot read is a driver that has quietly gone silent.
      final draft = scanModuleSource(driver, fileName: 'epsn_vp_X.py').draft;
      final info = AppStateProvider.parseDeviceInfo(
          'x.py', formatDeviceInfo(draft));

      expect(info, isNotNull);
      expect(info!['device_type'], 'projector');
      expect(info['models'], ['BrightLink 696Ui', 'EB-1440Ui']);
      expect((info['connection'] as Map)['com_type'], 'Network');
      expect((info['defaults'] as Map)['keep_alive_interval'], 10);
      expect((info['serial'] as Map)['baud'], 38400);
    });

    test('a port is written as a number, not a string', () {
      // A port spelled "22023" is a string the processor cannot open a socket
      // on. The editor takes every value as text; this is where that is
      // turned back into what the value MEANS.
      final draft = DeviceInfoDraft(connection: {
        'net_port': pythonScalarOf('22023'),
        'manual_disconnect': pythonScalarOf('False'),
        'keep_alive_trigger': pythonScalarOf('None'),
        'serial_port': pythonScalarOf('COM3'),
      });
      final text = formatDeviceInfo(draft);
      expect(text, contains('"net_port": 22023,'));
      expect(text, contains('"manual_disconnect": False,'));
      expect(text, contains('"keep_alive_trigger": None,'));
      expect(text, contains('"serial_port": "COM3",'));
    });

    test('an editor round trip never loses a key the driver had', () {
      const py = '''
DEVICE_INFO = {
    "device_type": "dsp",
    "models": ["DMP 64 Plus C"],
    "connection": {"com_type": "Network", "net_port": 22023},
    "defaults": {"keep_alive_command": "PartNumber"},
    "network": {"protocol": "SSH"},
    "omit": ["group_*"],
    "tags": ["extron"],
}
''';
      final info = AppStateProvider.parseDeviceInfo('x.py', py)!;
      final again = AppStateProvider.parseDeviceInfo(
          'x.py', formatDeviceInfo(DeviceInfoDraft.fromInfo(info)))!;

      expect(again['device_type'], 'dsp');
      expect(again['models'], ['DMP 64 Plus C']);
      expect((again['network'] as Map)['protocol'], 'SSH');
      expect(again['omit'], ['group_*']);
      // A key this editor has never heard of is still the driver author's,
      // and comes back out the other side.
      expect(again['tags'], ['extron']);
    });
  });

  group('writing it into the file', () {
    test('a driver with none gets one under its imports', () {
      final written = applyDeviceInfoBlock(
          driver, formatDeviceInfo(DeviceInfoDraft(models: const ['X'])));
      expect(AppStateProvider.parseDeviceInfo('x.py', written)?['models'],
          ['X']);
      // Above the code, below the imports - and the code is all still there.
      expect(written.indexOf('DEVICE_INFO'),
          lessThan(written.indexOf('class DeviceClass')));
      expect(written, contains('def UpdateLampUsage'));
      expect(written, contains('from extronlib.interface import'));
    });

    test('a driver that has one gets it replaced, not doubled', () {
      var written = applyDeviceInfoBlock(
          driver, formatDeviceInfo(DeviceInfoDraft(models: const ['X'])));
      written = applyDeviceInfoBlock(
          written, formatDeviceInfo(DeviceInfoDraft(models: const ['Y'])));

      expect('DEVICE_INFO'.allMatches(written).length, 1);
      expect(AppStateProvider.parseDeviceInfo('x.py', written)?['models'],
          ['Y']);
    });

    test('every driver in the folder still reads after a round trip', () {
      // The blocks in device/ are hand-written, with comments and a layout
      // this formatter does not reproduce. What has to survive is the
      // CONTENT: re-formatting one must not change what the app believes
      // about the driver.
      final dir = Directory('device');
      if (!dir.existsSync()) return;
      for (final file in dir.listSync().whereType<File>()) {
        if (!file.path.toLowerCase().endsWith('.py')) continue;
        final before =
            AppStateProvider.parseDeviceInfo(file.path, file.readAsStringSync());
        if (before == null) continue;
        final after = AppStateProvider.parseDeviceInfo(
            file.path, formatDeviceInfo(DeviceInfoDraft.fromInfo(before)));
        expect(after, isNotNull, reason: '${file.path} did not survive');
        expect(after!['models'], before['models'],
            reason: '${file.path} lost its models');
        expect(after['connection'], before['connection'],
            reason: '${file.path} changed its connection');
        expect(after['defaults'], before['defaults'],
            reason: '${file.path} changed its defaults');
      }
    });
  });

  group('the editor, end to end', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('rcb_devinfo_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// Pumps until [done], letting REAL file I/O run in between.
    ///
    /// The editor reads and writes the driver off the disk, and a widget test
    /// runs in a fake-async zone where a real Future never completes on its
    /// own - so a plain pumpAndSettle here waits for something that cannot
    /// happen. [WidgetTester.runAsync] is the door out of that zone.
    Future<void> until(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 80 && !done(); i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pump();
    }

    testWidgets('every key sits level with its own value', (tester) async {
      // THE FAULT THIS HOLDS THE LINE ON. The key's description used to be
      // the decoration's helperText, which makes that field taller than the
      // one beside it - so the Row centred the two boxes against each other
      // and the key sat above its value. Worse, it only happened on keys the
      // dictionary describes, so no two rows down a block lined up either.
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final devices = Directory(path.join(dir.path, 'devices'))
        ..createSync(recursive: true);
      // A block whose first key IS described in the dictionary (com_type) and
      // whose second is not (a group number a driver made up), so the row
      // that used to break and the row that never did are both measured.
      File(path.join(devices.path, 'extr_dsp_Thing.py')).writeAsStringSync('''
DEVICE_INFO = {
    "device_type": "dsp",
    "models": ["DMP 64 Plus C"],
    "connection": {
        "com_type": "Network",
        "group_prog_gain": "1",
        "net_port": 22023,
    },
}


$driver
''');

      late AppStateProvider provider;
      await tester.runAsync(() async {
        provider = AppStateProvider(autoLoadSettings: false)
          ..uiSchema = await UiSchema.load(explicitPath: 'ui_schema.json')
          ..modulesPath = devices.path;
        await provider.preloadAllModules();
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDeviceInfoEditor(context,
                      module: 'extr_dsp_Thing'),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await until(
        tester,
        () => find
            .byKey(const ValueKey('device_info_row_connection_0'))
            .evaluate()
            .isNotEmpty,
      );

      // Every row of the connection block: the key box and the value box on
      // one line, and the same height as each other.
      Rect? firstTop;
      for (var i = 0; i < 3; i++) {
        final row = find.byKey(ValueKey('device_info_row_connection_$i'));
        expect(row, findsOneWidget, reason: 'row $i should be on screen');
        final fields =
            find.descendant(of: row, matching: find.byType(TextField));
        expect(fields, findsNWidgets(2));

        final key = tester.getRect(fields.at(0));
        final value = tester.getRect(fields.at(1));
        expect(key.top, moreOrLessEquals(value.top, epsilon: 0.5),
            reason: 'row $i: the key box starts where its value box starts');
        expect(key.bottom, moreOrLessEquals(value.bottom, epsilon: 0.5),
            reason: 'row $i: and ends where it ends');

        // And one row is the same height as the next, described or not.
        firstTop ??= key;
        expect(key.height, moreOrLessEquals(firstTop.height, epsilon: 0.5),
            reason: 'row $i is the same box as every other row');
      }

      // The description is still there - moved under the row, not dropped.
      expect(find.textContaining('Type of connection'), findsOneWidget);
    });

    testWidgets('a silent driver is given a block, and its models arrive', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final devices = Directory(path.join(dir.path, 'devices'))
        ..createSync(recursive: true);
      final file = File(path.join(devices.path, 'epsn_vp_BrightLink.py'))
        ..writeAsStringSync(driver);

      // Real disk work, so it has to run outside the fake-async zone the
      // test body is in - see [until].
      late AppStateProvider provider;
      await tester.runAsync(() async {
        provider = AppStateProvider(autoLoadSettings: false)
          ..uiSchema = await UiSchema.load(explicitPath: 'ui_schema.json')
          ..modulesPath = devices.path;
        await provider.preloadAllModules();
      });

      // Before: the driver declares nothing, so nothing it drives is on the
      // Model dropdown as a projector.
      expect(provider.moduleDefaults, isEmpty);

      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: MaterialApp(
            // A Scaffold because the editor reports what it wrote on a snack
            // bar, and one has nowhere to land without it.
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDeviceInfoEditor(context,
                      module: 'modules.device.epsn_vp_BrightLink'),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await until(
        tester,
        () => find
            .byKey(const ValueKey('device_info_models'))
            .evaluate()
            .isNotEmpty,
      );

      expect(find.byKey(const ValueKey('device_info_editor')), findsOneWidget);
      // It says so rather than looking like an empty form.
      expect(find.textContaining('no DEVICE_INFO block'), findsOneWidget);
      // AND THE LIST SAYS IT TOO. This driver has a self.Models dict, so the
      // model registry knows its models and a list that asked the registry
      // would have marked it done - which is the driver this screen is for.
      await until(tester, () => find.text('no block').evaluate().isNotEmpty);
      expect(find.text('no block'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('device_info_scan')));
      await until(
        tester,
        () => find.textContaining('communication sheet').evaluate().isNotEmpty,
      );

      // The models it read, in the box, and the port it could not read, said.
      final models = tester.widget<TextField>(
          find.byKey(const ValueKey('device_info_models')));
      expect(models.controller?.text, contains('BrightLink 696Ui'));

      await tester.tap(find.byKey(const ValueKey('device_info_save')));
      await tester.pumpAndSettle();
      // The exact python, before anything is written.
      expect(find.byKey(const ValueKey('device_info_preview')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('device_info_write')));
      // Waiting on EXPLICIT, not on the model being known: the self.Models
      // fallback already put it in the registry, so "is it there" was true
      // before the write and the wait ended before it happened.
      await until(
        tester,
        () => provider.modelRegistry['BrightLink 696Ui']?.explicit == true,
      );

      // On disk, and the rest of the driver still there.
      final written = file.readAsStringSync();
      expect(written, contains('DEVICE_INFO = {'));
      expect(written, contains('class SerialClass'));
      expect(AppStateProvider.parseDeviceInfo(file.path, written)?['models'],
          contains('BrightLink 696Ui'));

      // And the app is looking at the file as it is NOW: the folder is
      // re-read on the way out, or the save would leave it believing the
      // silent copy it started with.
      expect(provider.modelRegistry['BrightLink 696Ui']?.explicit, isTrue);
      expect(
        provider.moduleDefaultsFor('epsn_vp_BrightLink')?['com_type'],
        'Network',
      );
    });

    testWidgets('the drivers folder is changed from inside the dialog', (
      tester,
    ) async {
      // WHY THE PATH IS ON THIS SCREEN AT ALL. The list is only ever as
      // right as the folder it was read from, and the person finding out it
      // is the wrong folder is the person standing here - the driver they
      // opened the editor to fix is not in the list.
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final first = Directory(path.join(dir.path, 'devices'))
        ..createSync(recursive: true);
      File(path.join(first.path, 'extr_dsp_Thing.py')).writeAsStringSync(driver);
      final second = Directory(path.join(dir.path, 'other_devices'))
        ..createSync(recursive: true);
      File(path.join(second.path, 'epsn_vp_BrightLink.py'))
          .writeAsStringSync(driver);

      late AppStateProvider provider;
      await tester.runAsync(() async {
        provider = AppStateProvider(autoLoadSettings: false)
          ..uiSchema = await UiSchema.load(explicitPath: 'ui_schema.json')
          ..modulesPath = first.path;
        await provider.preloadAllModules();
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDeviceInfoEditor(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await until(
        tester,
        () => find
            .byKey(const ValueKey('device_info_modules_path'))
            .evaluate()
            .isNotEmpty,
      );

      // The folder being read, in the box, and its driver in the list.
      final box = tester.widget<TextField>(
          find.byKey(const ValueKey('device_info_modules_path')));
      expect(box.controller?.text, first.path);
      await until(tester, () => find.text('extr_dsp_Thing').evaluate().isNotEmpty);

      // Point it somewhere else.
      await tester.enterText(
          find.byKey(const ValueKey('device_info_modules_path')), second.path);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await until(
        tester,
        () => find.text('epsn_vp_BrightLink').evaluate().isNotEmpty,
      );

      // THE WHOLE APP FOLLOWED, not just the list: this is the App Config
      // setting, and the drivers behind the Model dropdown are the new
      // folder's now.
      expect(provider.modulesPath, second.path);
      expect(provider.availableModules, ['epsn_vp_BrightLink']);
      expect(find.text('extr_dsp_Thing'), findsNothing);
    });
  });
}
