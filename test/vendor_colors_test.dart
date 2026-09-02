import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/name_colors.dart';
import 'package:extron_configurator/project_view.dart';

/// A COLOR PER ORDER, on the project's Equipment list.
///
/// A vendor is an order: everything tagged to it goes to one company on one
/// purchase order. The failure this guards is a master list of two hundred
/// parts that can only be read one row at a time to answer "which of these am
/// I buying from whom" — and a color somebody chose for that order quietly
/// reverting to a derived one.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_vendor_colors'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String writeRoom(String stem, String name) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gui_full_room_name': name},
    }));
    File(path.join(dir.path, '${stem}_config_av_flow.json'))
        .writeAsStringSync(jsonEncode({
      'nodes': [
        AvNode(
          id: 'PROJECTORDEVICE_1',
          label: 'Projector',
          model: 'PowerLite L610U',
          pos: Offset.zero,
          ports: const [],
        ).toJson(),
      ],
    }));
    return configPath;
  }

  AppStateProvider withJob() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(const AvDeviceTemplate(
        model: 'PowerLite L610U',
        manufacturer: 'Epson',
        category: 'Projector',
        price: 1000,
        ports: [],
      ));
    p.newProject(name: 'Bessey refresh', building: 'BSS');
    p.addRoomToProject(writeRoom('r1', 'Bessey 101'));
    return p;
  }

  Future<void> openPane(
    WidgetTester tester,
    AppStateProvider p,
    String pane,
  ) async {
    tester.view.physicalSize = const Size(1700, 1400);
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

  group('what color an order is', () {
    test('a package nobody has colored still has one', () {
      // Derived from the name, so a list is legible before anybody has set
      // anything up — and the same package is the same color every time.
      const vendor = ProjectRfq(id: 'v1', title: 'Extron Direct');
      expect(projectRfqColor(vendor), tintForName('Extron Direct'));
      expect(projectRfqColor(vendor), isNot(kNameTintUnsettled));
    });

    test('an assigned color beats the derived one', () {
      const vendor = ProjectRfq(
        id: 'v1',
        title: 'Extron Direct',
        color: 0xFF43A047,
      );
      expect(projectRfqColor(vendor), const Color(0xFF43A047));
    });

    test('an untagged part is not an order, and reads as one that is not', () {
      // Gray rather than a color of its own: an untagged part is the thing
      // the list is meant to catch, and a cheerful color would file it with
      // the decided ones.
      expect(projectRfqColor(null), kNameTintUnsettled);
    });
  });

  group('assigning one', () {
    testWidgets('the swatch on a package sets the color, and Automatic takes '
        'it back', (tester) async {
      final p = withJob();
      final vendor = p.addProjectRfq(title: 'Extron Direct');
      await openPane(tester, p, 'vendors');

      await tester.tap(find.byKey(ValueKey('rfq_color_${vendor.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rfq_color_dialog')), findsOneWidget);

      const chosen = Color(0xFFD81B60);
      await tester.tap(
        find.byKey(
          ValueKey(
            'rfq_color_${vendor.id}_'
            '${(chosen.toARGB32() & 0xFFFFFF).toRadixString(16)}',
          ),
        ),
      );
      await tester.pumpAndSettle();
      ProjectRfq mine() =>
          p.project.rfqs.firstWhere((v) => v.id == vendor.id);
      expect(mine().color, chosen.toARGB32());

      // Back to the derived color, which is a different answer from "no
      // color at all".
      await tester.tap(find.byKey(const ValueKey('rfq_color_auto')));
      await tester.pumpAndSettle();
      expect(mine().color, isNull);
      expect(projectRfqColor(mine()), tintForName('Extron Direct'));

      await tester.tap(find.byKey(const ValueKey('rfq_color_done')));
      await tester.pumpAndSettle();
    });

    testWidgets('a renamed package keeps the color somebody chose', (
      tester,
    ) async {
      final p = withJob();
      final vendor = p.addProjectRfq(title: 'Extron Direct');
      ProjectRfq mine() =>
          p.project.rfqs.firstWhere((v) => v.id == vendor.id);
      p.updateProjectRfq(vendor.copyWith(color: 0xFF1E88E5));
      p.updateProjectRfq(mine().copyWith(title: 'Extron, direct'));
      // The order did not change color because somebody fixed a comma.
      expect(mine().color, 0xFF1E88E5);
      expect(mine().name, 'Extron, direct');
      await openPane(tester, p, 'parts');
      expect(find.byKey(const ValueKey('project_pane_parts')), findsWidgets);
    });
  });
}
