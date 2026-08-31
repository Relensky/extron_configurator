import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/project_view.dart';

/// THE MAKERS GET THE SAME TICK-LIST THE CATEGORIES HAVE.
///
/// A manufacturer rule is matched EXACTLY, which makes typing one the worst
/// possible way to write it: 'Extron Electronics' against a catalog that says
/// 'Extron' claims nothing, and there is nothing anywhere on the screen to say
/// so. The list is built from THE JOB's own makers, because a rule about a
/// manufacturer this job buys nothing from claims nothing and says nothing.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_vendor_makers_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// One Epson projector and two Sharp displays: three parts from two makers,
  /// so the counts on the list are worth reading.
  String writeRoom(String stem) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(
      jsonEncode({
        'SYSTEM_SETUP': {'gui_full_room_name': 'Bessey 101'},
      }),
    );
    File(path.join(dir.path, '${stem}_config_av_flow.json')).writeAsStringSync(
      jsonEncode({
        'nodes': [
          for (final (id, model) in [
            ('PROJECTORDEVICE_1', 'PowerLite L610U'),
            ('DISPLAYDEVICE_1', 'Aquos 65'),
            ('DISPLAYDEVICE_2', 'Aquos 55'),
          ])
            AvNode(
              id: id,
              label: id,
              model: model,
              pos: Offset.zero,
              ports: const [],
            ).toJson(),
        ],
      }),
    );
    return configPath;
  }

  ({AppStateProvider p, String vendorId}) job() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(
          model: 'PowerLite L610U',
          manufacturer: 'Epson',
          category: 'Projector',
          price: 1000,
          ports: [],
        ),
      )
      ..upsert(
        const AvDeviceTemplate(
          model: 'Aquos 65',
          manufacturer: 'Sharp',
          category: 'Display',
          price: 400,
          ports: [],
        ),
      )
      ..upsert(
        const AvDeviceTemplate(
          model: 'Aquos 55',
          manufacturer: 'Sharp',
          category: 'Display',
          price: 300,
          ports: [],
        ),
      );
    p.newProject(name: 'Bessey refresh', building: 'BSS');
    final vendor = p.addProjectVendor(name: 'AV Reseller');
    p.addRoomToProject(writeRoom('r0'));
    return (p: p, vendorId: vendor.id);
  }

  Future<void> openVendors(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1700, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: ProjectView())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project_pane_vendors')));
    await tester.pumpAndSettle();
  }

  Future<void> openPicker(
    WidgetTester tester,
    AppStateProvider p,
    String vendorId,
  ) async {
    await openVendors(tester, p);
    await tester.tap(find.byKey(ValueKey('vendor_toggle_$vendorId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rule_pick_Manufacturers')));
    await tester.pumpAndSettle();
  }

  group('the list is what the job actually buys', () {
    test('counted, most-used first', () {
      final (:p, vendorId: _) = job();
      final choices = projectManufacturerChoices(p.priceProject());

      expect(choices.first.name, 'Sharp');
      expect(choices.first.count, 2);
      expect(choices.map((c) => c.name), contains('Epson'));
      // The CATALOG knows more makers than this. They are not on the list,
      // because a rule about one of them claims nothing.
      expect(choices.map((c) => c.name), isNot(contains('Extron')));
    });
  });

  group('picking from the job', () {
    testWidgets('the button is on the manufacturers editor', (tester) async {
      final (:p, :vendorId) = job();
      await openVendors(tester, p);
      await tester.tap(find.byKey(ValueKey('vendor_toggle_$vendorId')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('rule_pick_Manufacturers')),
        findsOneWidget,
      );
    });

    testWidgets('ticking two writes two rules, spelled the catalog\'s way', (
      tester,
    ) async {
      final (:p, :vendorId) = job();
      await openPicker(tester, p, vendorId);

      expect(find.byKey(const ValueKey('vendor_manufacturer_picker')), findsOne);
      expect(find.text('2 parts on the job'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('vendor_manufacturer_Sharp')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('vendor_manufacturer_Epson')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('vendor_manufacturer_picker_save')),
      );
      await tester.pumpAndSettle();

      final vendor = p.project.vendorById(vendorId)!;
      expect(vendor.manufacturers, containsAll(['Sharp', 'Epson']));
      // And the rules actually claim the parts, which is the whole point of
      // ticking rather than typing.
      expect(vendor.quotesManufacturer('Sharp'), isTrue);
      expect(vendor.quotesManufacturer('Epson'), isTrue);
    });

    testWidgets('unticking is how a rule goes', (tester) async {
      final (:p, :vendorId) = job();
      p.updateProjectVendor(
        p.project.vendorById(vendorId)!.copyWith(
          manufacturers: const ['Sharp', 'Epson'],
        ),
      );
      await openPicker(tester, p, vendorId);

      await tester.tap(find.byKey(const ValueKey('vendor_manufacturer_Sharp')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('vendor_manufacturer_picker_save')),
      );
      await tester.pumpAndSettle();

      expect(p.project.vendorById(vendorId)!.manufacturers, ['Epson']);
    });

    testWidgets('backing out changes nothing', (tester) async {
      final (:p, :vendorId) = job();
      await openPicker(tester, p, vendorId);

      await tester.tap(find.byKey(const ValueKey('vendor_manufacturer_Sharp')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(p.project.vendorById(vendorId)!.manufacturers, isEmpty);
    });

    testWidgets('a maker the job buys nothing from is carried, not dropped', (
      tester,
    ) async {
      // THE TYPED ROUTE SURVIVES. A vendor is often set up before the rooms
      // are drawn, so a rule for a maker nothing on the job is by yet is a
      // real thing to want - and a picker that silently deleted it would be
      // worse than no picker.
      final (:p, :vendorId) = job();
      p.updateProjectVendor(
        p.project.vendorById(vendorId)!.copyWith(
          manufacturers: const ['Crestron'],
        ),
      );
      await openPicker(tester, p, vendorId);

      expect(
        find.byKey(const ValueKey('vendor_manufacturer_off_Crestron')),
        findsOneWidget,
      );
      expect(find.text('no part on this job is by them'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('vendor_manufacturer_picker_save')),
      );
      await tester.pumpAndSettle();
      expect(p.project.vendorById(vendorId)!.manufacturers, ['Crestron']);
    });

    testWidgets('the box beside it still takes anything typed', (tester) async {
      final (:p, :vendorId) = job();
      await openVendors(tester, p);
      await tester.tap(find.byKey(ValueKey('vendor_toggle_$vendorId')));
      await tester.pumpAndSettle();

      final field = find.descendant(
        of: find.byKey(const ValueKey('rule_add_Manufacturers')),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'Biamp');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(
        p.project.vendorById(vendorId)!.manufacturers,
        contains('Biamp'),
      );
    });

    testWidgets('the two pickers are separate lists', (tester) async {
      // Both editors carry a button now, and each has to open its OWN list -
      // a manufacturer picker showing categories would write rules that claim
      // nothing.
      final (:p, :vendorId) = job();
      await openPicker(tester, p, vendorId);

      expect(find.byKey(const ValueKey('vendor_manufacturer_Sharp')), findsOne);
      expect(find.byKey(const ValueKey('vendor_category_Display')), findsNothing);
    });
  });
}
