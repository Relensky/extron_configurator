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
import 'package:extron_configurator/project_view.dart';

/// THE QUOTE ITSELF, ATTACHED WHERE THE QUOTE IS RECORDED.
///
/// The three fields on a returned quote - when, how much, under what reference
/// - answer "who is cheapest". What was actually quoted, at what lead time,
/// with which accessories, is settled by the PDF, and the PDF lived in the
/// inbox of whoever asked for it. It is attached in the dialog that opens the
/// moment somebody has it in front of them, because attaching it anywhere else
/// is a second trip back to a file they have already closed.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_quote_doc_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String writeRoom(String stem, String name) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(
      jsonEncode({
        'SYSTEM_SETUP': {'gui_full_room_name': name},
      }),
    );
    File(path.join(dir.path, '${stem}_config_av_flow.json')).writeAsStringSync(
      jsonEncode({
        'nodes': [
          AvNode(
            id: 'PROJECTORDEVICE_1',
            label: 'Projector',
            model: 'PowerLite L610U',
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
      );
    p.newProject(name: 'Bessey refresh', building: 'BSS');
    final vendor = p.addProjectVendor(name: 'Epson Direct');
    p.updateProjectVendor(
      ProjectVendor(
        id: vendor.id,
        name: 'Epson Direct',
        manufacturers: const ['Epson'],
      ),
    );
    p.addRoomToProject(writeRoom('r0', 'Bessey 101'));
    return (p: p, vendorId: vendor.id);
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

  // -------------------------------------------------------------------------
  //  WHERE IT IS KEPT
  // -------------------------------------------------------------------------

  group('the quote is a pointer at a file, never a copy of it', () {
    test('stored relative to the job, so the folder can move', () {
      final (:p, :vendorId) = job();
      p.currentProjectPath = path.join(dir.path, 'bessey_project.json');

      final pdf = path.join(dir.path, 'Q-88421.pdf');
      File(pdf).writeAsStringSync('%PDF-1.4');
      p.setVendorQuote(
        vendorId,
        quotedOn: DateTime(2026, 3, 11),
        amount: 18400,
        reference: 'Q-88421',
        filePath: pdf,
      );

      final stored = p.project.vendorById(vendorId)!.quoteFilePath;
      expect(
        path.isAbsolute(stored),
        isFalse,
        reason: 'a job under one folder travels onto a laptop with its '
            'paperwork still attached',
      );
      expect(stored, 'Q-88421.pdf');
      expect(
        BuildingProject.resolvePath(stored, p.currentProjectPath),
        path.normalize(pdf),
      );
      expect(File(pdf).existsSync(), isTrue);
    });

    test('re-saving the row does not re-relativise what is already stored', () {
      // The dialog hands back whatever it was opened with when nobody picked a
      // new file. Storing an already-relative path a second time would resolve
      // it against the working directory and produce a pointer at nothing.
      final (:p, :vendorId) = job();
      p.currentProjectPath = path.join(dir.path, 'bessey_project.json');
      final pdf = path.join(dir.path, 'quotes', 'Q-88421.pdf');
      Directory(path.dirname(pdf)).createSync(recursive: true);
      File(pdf).writeAsStringSync('%PDF-1.4');

      p.setVendorQuote(
        vendorId,
        quotedOn: DateTime(2026, 3, 11),
        filePath: pdf,
      );
      final stored = p.project.vendorById(vendorId)!.quoteFilePath;

      p.setVendorQuote(
        vendorId,
        quotedOn: DateTime(2026, 3, 12),
        amount: 18400,
        filePath: stored,
      );

      expect(p.project.vendorById(vendorId)!.quoteFilePath, stored);
      expect(
        BuildingProject.resolvePath(
          p.project.vendorById(vendorId)!.quoteFilePath,
          p.currentProjectPath,
        ),
        path.normalize(pdf),
      );
    });

    test('taking the quote off the row takes the document with it', () {
      final (:p, :vendorId) = job();
      final pdf = path.join(dir.path, 'Q-88421.pdf');
      File(pdf).writeAsStringSync('%PDF-1.4');
      p.setVendorQuote(
        vendorId,
        quotedOn: DateTime(2026, 3, 11),
        amount: 18400,
        filePath: pdf,
      );

      p.setVendorQuote(vendorId, quotedOn: null);

      final vendor = p.project.vendorById(vendorId)!;
      expect(vendor.quoteFilePath, isEmpty);
      expect(vendor.quoteAmount, 0);
      // The FILE is left where it is. Deleting somebody's paperwork off their
      // disk is not something a project file gets to do.
      expect(File(pdf).existsSync(), isTrue);
    });

    test('it survives a save and a reload', () {
      final vendor = ProjectVendor(
        id: 'vendor1',
        name: 'Extron',
        quotedOn: DateTime(2026, 3, 11),
        quoteFilePath: 'quotes/Q-88421.pdf',
      );
      expect(
        ProjectVendor.fromJson(vendor.toJson()).quoteFilePath,
        'quotes/Q-88421.pdf',
      );
    });

    test('it is in the history under the vendor', () {
      final (:p, :vendorId) = job();
      final pdf = path.join(dir.path, 'Q-88421.pdf');
      File(pdf).writeAsStringSync('%PDF-1.4');
      p.setVendorQuote(
        vendorId,
        quotedOn: DateTime(2026, 3, 11),
        filePath: pdf,
      );
      expect(
        p.project.history.where(
          (h) => h.itemKind == 'vendor' && h.summary.contains('document'),
        ),
        isNotEmpty,
      );
    });
  });

  // -------------------------------------------------------------------------
  //  ON THE SCREEN
  // -------------------------------------------------------------------------

  group('one dialog, not two trips', () {
    testWidgets('the quote dialog attaches the document itself', (
      tester,
    ) async {
      final (:p, :vendorId) = job();
      p.setVendorRfqSent(vendorId, DateTime(2026, 3, 4));
      await openPane(tester, p, 'vendors');
      await tester.tap(find.byKey(ValueKey('vendor_toggle_$vendorId')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ValueKey('vendor_rfq_quoted_$vendorId')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('vendor_quote_dialog')), findsOne);
      // THE PAPER, on the pop-up, at the one moment somebody has it in front
      // of them - and not a second click somewhere else afterwards.
      expect(find.byKey(const ValueKey('vendor_quote_attach')), findsOneWidget);
      expect(find.text('Attach the quote (optional)'), findsOneWidget);
    });

    testWidgets('nothing attached offers nothing to open or unlink', (
      tester,
    ) async {
      final (:p, :vendorId) = job();
      p.setVendorRfqSent(vendorId, DateTime(2026, 3, 4));
      await openPane(tester, p, 'vendors');
      await tester.tap(find.byKey(ValueKey('vendor_toggle_$vendorId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('vendor_rfq_quoted_$vendorId')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('vendor_quote_open')), findsNothing);
      expect(find.byKey(const ValueKey('vendor_quote_detach')), findsNothing);
    });

    testWidgets('an attached quote is named on the dialog and unlinkable', (
      tester,
    ) async {
      final (:p, :vendorId) = job();
      final pdf = path.join(dir.path, 'Q-88421.pdf');
      File(pdf).writeAsStringSync('%PDF-1.4');
      p.setVendorRfqSent(vendorId, DateTime(2026, 3, 4));
      p.setVendorQuote(
        vendorId,
        quotedOn: DateTime(2026, 3, 11),
        amount: 18400,
        filePath: pdf,
      );
      await openPane(tester, p, 'vendors');
      await tester.tap(find.byKey(ValueKey('vendor_toggle_$vendorId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('vendor_rfq_edit_quote_$vendorId')));
      await tester.pumpAndSettle();

      // THE DOCUMENT IS THE BUTTON - named by its own file, because that is
      // what somebody recognises.
      expect(find.text('Q-88421.pdf'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('vendor_quote_detach')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('vendor_quote_save')));
      await tester.pumpAndSettle();

      expect(p.project.vendorById(vendorId)!.quoteFilePath, isEmpty);
      expect(
        File(pdf).existsSync(),
        isTrue,
        reason: 'unlinking is not deleting',
      );
    });

    testWidgets('the vendor card is the way back to it', (tester) async {
      final (:p, :vendorId) = job();
      final pdf = path.join(dir.path, 'Q-88421.pdf');
      File(pdf).writeAsStringSync('%PDF-1.4');
      p.setVendorRfqSent(vendorId, DateTime(2026, 3, 4));
      p.setVendorQuote(
        vendorId,
        quotedOn: DateTime(2026, 3, 11),
        filePath: pdf,
      );
      await openPane(tester, p, 'vendors');
      await tester.tap(find.byKey(ValueKey('vendor_toggle_$vendorId')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(ValueKey('vendor_quote_open_$vendorId')),
        findsOneWidget,
      );
    });
  });
}
