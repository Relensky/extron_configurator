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

/// SIX BOXES, NOT SIX EXACT STRINGS.
///
/// A vendor's category rule is matched exactly (or by prefix), which makes
/// typing one the worst possible way to write it: "Cameras" against a catalog
/// that says "Camera" claims nothing, and there is nothing anywhere on the
/// screen to say so. The autocomplete helped, and only after you had typed
/// enough of the word for it to appear.
///
/// What people actually do is read down what is being bought and say "that lot
/// is Extron's". That is a tick-list, so this is one - built from THE JOB's
/// own categories, because a rule about a category the job has no part in
/// claims nothing and says nothing.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_vendor_cats_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A room with a projector and two displays: three parts in two categories,
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
    final vendor = p.addProjectRfq(title: 'AV Reseller');
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
    await tester.tap(find.byKey(ValueKey('rfq_toggle_$vendorId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rule_pick_Categories')));
    await tester.pumpAndSettle();
  }

  group('the list is what the job actually has', () {
    test('counted, most-used first', () {
      final (:p, vendorId: _) = job();
      final choices = projectCategoryChoices(p.priceProject());

      // Two display lines and one projector line. The count is what makes the
      // list readable as a decision: "Display (2)" against "Projector (1)".
      expect(choices.first.name, 'Display');
      expect(choices.first.count, 2);
      expect(choices.map((c) => c.name), contains('Projector'));
      // The CATALOG knows more categories than this. They are not on the list,
      // because a rule about one of them claims nothing.
      expect(choices.map((c) => c.name), isNot(contains('Camera')));
    });
  });

  group('picking from the job', () {
    testWidgets('the button is on the categories editor', (tester) async {
      final (:p, :vendorId) = job();
      await openVendors(tester, p);
      await tester.tap(find.byKey(ValueKey('rfq_toggle_$vendorId')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('rule_pick_Categories')),
        findsOneWidget,
      );
    });

    testWidgets('ticking two writes two rules, spelled the catalog\'s way', (
      tester,
    ) async {
      final (:p, :vendorId) = job();
      await openPicker(tester, p, vendorId);

      expect(find.byKey(const ValueKey('vendor_category_picker')), findsOne);
      // The count is on the row, which is how a decision gets made off it.
      expect(find.text('2 parts on the job'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('vendor_category_Display')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('vendor_category_Projector')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('vendor_category_picker_save')),
      );
      await tester.pumpAndSettle();

      final vendor = p.project.rfqById(vendorId)!;
      expect(vendor.categories, containsAll(['Display', 'Projector']));
      // And the rules actually claim the parts, which is the whole point of
      // ticking rather than typing.
      expect(vendor.quotesCategory('Display'), isTrue);
      expect(vendor.quotesCategory('Projector'), isTrue);
    });

    testWidgets('unticking is how a rule goes', (tester) async {
      final (:p, :vendorId) = job();
      p.updateProjectRfq(
        p.project.rfqById(vendorId)!.copyWith(
          categories: const ['Display', 'Projector'],
        ),
      );
      await openPicker(tester, p, vendorId);

      await tester.tap(find.byKey(const ValueKey('vendor_category_Display')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('vendor_category_picker_save')),
      );
      await tester.pumpAndSettle();

      expect(p.project.rfqById(vendorId)!.categories, ['Projector']);
    });

    testWidgets('backing out changes nothing', (tester) async {
      final (:p, :vendorId) = job();
      await openPicker(tester, p, vendorId);

      await tester.tap(find.byKey(const ValueKey('vendor_category_Display')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(p.project.rfqById(vendorId)!.categories, isEmpty);
    });

    testWidgets('a rule the job has no parts for is carried, not dropped', (
      tester,
    ) async {
      // THE TYPED ROUTE SURVIVES. A vendor is often set up before the rooms
      // are drawn, so a rule for a category nothing on the job is in yet is a
      // real thing to want - and a picker that silently deleted it would be
      // worse than no picker.
      final (:p, :vendorId) = job();
      p.updateProjectRfq(
        p.project.rfqById(vendorId)!.copyWith(
          categories: const ['Camera'],
        ),
      );
      await openPicker(tester, p, vendorId);

      expect(
        find.byKey(const ValueKey('vendor_category_off_Camera')),
        findsOneWidget,
      );
      expect(find.text('no part on this job is in it'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('vendor_category_picker_save')),
      );
      await tester.pumpAndSettle();
      expect(p.project.rfqById(vendorId)!.categories, ['Camera']);
    });

    testWidgets('the box beside it still takes anything typed', (tester) async {
      final (:p, :vendorId) = job();
      await openVendors(tester, p);
      await tester.tap(find.byKey(ValueKey('rfq_toggle_$vendorId')));
      await tester.pumpAndSettle();

      // The tick-list is a way in, not the only one. A category this job has
      // never seen must still be writable.
      final field = find.descendant(
        of: find.byKey(const ValueKey('rule_add_Categories')),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'Videowall');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(p.project.rfqById(vendorId)!.categories, contains('Videowall'));
    });
  });
}
