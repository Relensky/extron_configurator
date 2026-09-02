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

/// THE COUNT IS THE WAY TO THE ROWS IT COUNTS.
///
/// "19 lines - $18,400" on a vendor card is a sentence about nineteen specific
/// parts, and following it used to mean leaving for the Equipment list and
/// finding this vendor's chip by hand among a dozen. A jump that does not
/// carry what it was a jump ABOUT leaves the reader to re-ask the question
/// they had just asked.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_pkg_parts_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

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

  ({AppStateProvider p, String epson}) job() {
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
      );
    p.newProject(name: 'Bessey refresh', building: 'BSS');
    final epson = p.addProjectRfq(title: 'Epson Direct');
    p.updateProjectRfq(
      epson.copyWith(manufacturers: const ['Epson']),
    );
    p.addRoomToProject(writeRoom('r0'));
    return (p: p, epson: epson.id);
  }

  Future<void> openPane(
    WidgetTester tester,
    AppStateProvider p,
    String pane,
  ) async {
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
    await tester.tap(find.byKey(ValueKey('project_pane_$pane')));
    await tester.pumpAndSettle();
  }

  group('following the package count', () {
    testWidgets('the chip is on the package card, closed or open', (
      tester,
    ) async {
      final (:p, :epson) = job();
      await openPane(tester, p, 'vendors');
      expect(
        find.byKey(ValueKey('rfq_package_parts_$epson')),
        findsOneWidget,
      );
    });

    testWidgets('pressing it lands on the Equipment list, already narrowed', (
      tester,
    ) async {
      final (:p, :epson) = job();
      await openPane(tester, p, 'vendors');

      await tester.tap(find.byKey(ValueKey('rfq_package_parts_$epson')));
      await tester.pumpAndSettle();

      // The Epson line is there and the Sharp one is not - which is the whole
      // claim the chip was making.
      expect(find.textContaining('PowerLite L610U'), findsWidgets);
      expect(find.textContaining('Aquos 65'), findsNothing);
    });

    testWidgets('the same press twice still moves the tab', (tester) async {
      // A reader who followed the chip, wandered back to Vendors and pressed
      // it again must be taken there again - the request has not changed, and
      // the tab honors changes. See [AppStateProvider.projectPaneRequestId].
      final (:p, :epson) = job();
      await openPane(tester, p, 'vendors');
      await tester.tap(find.byKey(ValueKey('rfq_package_parts_$epson')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('project_pane_vendors')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('rfq_package_parts_$epson')));
      await tester.pumpAndSettle();

      expect(find.textContaining('PowerLite L610U'), findsWidgets);
      expect(find.textContaining('Aquos 65'), findsNothing);
    });
  });

  group('the request carries the filter, or leaves it alone', () {
    test('a plain pane request says nothing about the master list', () {
      final (:p, epson: _) = job();
      p.requestProjectPane('lifecycle');
      expect(
        p.requestedPartsVendorFilter,
        isEmpty,
        reason: 'a jump to Lifecycle has nothing to say about the parts list',
      );
    });

    test('a package request names the vendor it was made from', () {
      final (:p, :epson) = job();
      p.requestProjectPane('parts', partsVendorFilter: epson);
      expect(p.requestedProjectPane, 'parts');
      expect(p.requestedPartsVendorFilter, epson);
    });

    test('the next plain request clears the one before it', () {
      final (:p, :epson) = job();
      p.requestProjectPane('parts', partsVendorFilter: epson);
      p.requestProjectPane('parts');
      expect(
        p.requestedPartsVendorFilter,
        isEmpty,
        reason: 'a filter left set behind an unrelated jump is a list quietly '
            'missing rows with nothing on screen saying why',
      );
    });
  });
}
