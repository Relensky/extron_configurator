import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/name_colors.dart';
import 'package:extron_configurator/project_view.dart';
import 'package:extron_configurator/responsibility_matrix.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// The colour each party on the matrix reads in, when somebody chooses it.
///
/// The failure this guards is a colour that only exists on screen. This
/// document is issued - as a picture into a submittal and as a spreadsheet the
/// contractor prices from - and a party that is blue on the pane it was agreed
/// on and orange in the file that was sent is two parties as far as the person
/// reading it is concerned.
void main() {
  BuildingProject job() {
    final project = BuildingProject(name: 'Bessey refresh', building: 'BSS');
    project.rooms.add(
      ProjectRoomRef(
        id: project.nextRoomId(),
        configPath: 'C:/rooms/BSS_101_config.json',
        label: 'BSS 101',
      ),
    );
    project.addResponsibilityItem(
      'Screens',
      furnishedBy: 'Owner',
      installedBy: 'Contractor',
    );
    return project;
  }

  ReportRow gridRow(BuildingProject project) => responsibilityMatrixSections(
    project.responsibility,
    roomNames: project.responsibilityRoomColumns(),
    partyColors: project.partyColors,
  ).firstWhere((s) => s.title == 'Roles and Responsibilities').rows.first;

  group('a party keeps the colour it was given', () {
    test('into the spreadsheet', () {
      final project = job();
      // Not the hue 'Owner' derives: the point of choosing one is that the
      // derived answer was the wrong answer.
      const chosen = Color(0xFFD81B60);
      project.setPartyColor('Owner', chosen.toARGB32());

      final furnished = gridRow(project)[1] as XlsxTint;
      expect(furnished.fillHex, sheetTintOf(chosen).fill);
      expect(furnished.inkHex, sheetTintOf(chosen).ink);
      // The party nobody re-coloured is untouched.
      final installed = gridRow(project)[2] as XlsxTint;
      expect(installed.fillHex, nameSheetTint('Contractor').fill);
    });

    test('through a save and a reopen', () {
      final project = job();
      project.setPartyColor('Owner', const Color(0xFF43A047).toARGB32());

      final reopened = BuildingProject.fromJson(
        jsonDecode(jsonEncode(project.toJson())) as Map<String, dynamic>,
      );
      expect(reopened.partyColor('Owner'), const Color(0xFF43A047).toARGB32());
    });

    // Case and spacing are not two parties anywhere else on this sheet, and a
    // colour filed under a second spelling is a colour that goes missing the
    // next time somebody types the name with two spaces in it.
    test('however the name is typed', () {
      final project = job();
      project.setPartyColor('CTS  Chico', const Color(0xFF1E88E5).toARGB32());
      expect(
        project.partyColor('cts chico'),
        const Color(0xFF1E88E5).toARGB32(),
      );
    });

    test('and goes back to automatic when it is taken off', () {
      final project = job();
      project.setPartyColor('Owner', const Color(0xFF43A047).toARGB32());
      project.setPartyColor('Owner', null);

      expect(project.partyColor('Owner'), isNull);
      expect(
        (gridRow(project)[1] as XlsxTint).fillHex,
        nameSheetTint('Owner').fill,
      );
    });

    // A blank party is the thing this document exists to catch. Painting it a
    // settled colour would hide the one line somebody has to chase.
    test('but a party nobody has named cannot be given one', () {
      final project = job();
      project.setPartyColor('   ', const Color(0xFF43A047).toARGB32());
      expect(project.partyColors, isEmpty);
    });
  });

  group('the pane', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('party_colors_'));
    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<AppStateProvider> pumpPane(WidgetTester tester) async {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Bessey Hall');
      final file = '${dir.path}/bss101_config.json';
      File(file).writeAsStringSync(
        '{"SYSTEM_SETUP":{"gve_bldg":"BSS","gve_room":"101"}}',
      );
      p.addRoomToProject(file);
      final item = p.addResponsibilityItem('Screens');
      p.updateResponsibilityItem(
        item.copyWith(furnishedBy: 'Owner', installedBy: 'Contractor'),
      );

      tester.view.physicalSize = const Size(1600, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: ProjectView())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('project_pane_responsibility')),
      );
      await tester.pumpAndSettle();
      return p;
    }

    testWidgets('sets a party colour from the key above the grid', (
      tester,
    ) async {
      final p = await pumpPane(tester);

      // The chip in the key IS the control: a colour is changed by pressing
      // the colour.
      await tester.tap(find.byKey(const ValueKey('responsibility_party_owner')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('responsibility_party_color_dialog')),
        findsOneWidget,
      );

      const chosen = Color(0xFFD81B60);
      await tester.tap(
        find.byKey(
          ValueKey(
            'party_color_owner_'
            '${(chosen.toARGB32() & 0xFFFFFF).toRadixString(16)}',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(p.project.partyColor('Owner'), chosen.toARGB32());

      // ...and hands it back when Automatic is pressed.
      await tester.tap(find.byKey(const ValueKey('party_color_auto')));
      await tester.pumpAndSettle();
      expect(p.project.partyColor('Owner'), isNull);

      await tester.tap(find.byKey(const ValueKey('party_color_done')));
      await tester.pumpAndSettle();
    });
  });
}

/// One row of a rendered section — cells of whatever the sheet writes.
typedef ReportRow = List<dynamic>;
