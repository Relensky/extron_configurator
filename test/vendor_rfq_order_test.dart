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

/// ============================================================================
///  WHERE THE QUOTE GOT TO, AND WHAT IT BOUGHT
/// ============================================================================
///  This app builds the RFQ per vendor and hands over the file. Everything
///  after that - it went out on the 4th, two came back, one turned into a PO,
///  the third has never replied - lived in somebody's inbox, and on a six-vendor
///  job "which of these are we still waiting on" is the most-asked question on
///  the screen.
///
///  The failure this guards is the one at the end of that chain. Ordering a
///  vendor's package used to be three jobs on two screens: raise the PO, open
///  it, tick nineteen parts. What happened on real jobs is that the first two
///  got done and the third did not - leaving a PO nobody could trace to any
///  equipment, and nineteen parts reading on the timeline as things nobody had
///  bought.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_rfq_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A room with an Epson projector and a Sharp display on the drawing - two
  /// parts from two makers, so a vendor rule has something to sort.
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
          AvNode(
            id: 'DISPLAYDEVICE_1',
            label: 'Display',
            model: 'Aquos 65',
            pos: Offset.zero,
            ports: const [],
          ).toJson(),
        ],
      }),
    );
    return configPath;
  }

  /// The job, and the id of the vendor whose rule claims the Epson line.
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
      );
    p.newProject(name: 'Bessey refresh', building: 'BSS');
    // First in the list, so this rule wins the Epson line over anything the
    // starter split claims - see [BuildingProject.vendorForPart].
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

  String epsonKey(AppStateProvider p) {
    for (final line in p.priceProject().master) {
      if (line.manufacturer.toLowerCase() == 'epson') return line.key;
    }
    throw StateError('no Epson part on the job');
  }

  // -------------------------------------------------------------------------
  //  THE THREE DATES
  // -------------------------------------------------------------------------

  group('the stage is read off the dates, never stored beside them', () {
    test('nothing recorded is nothing sent', () {
      const vendor = ProjectVendor(id: 'vendor1', name: 'Extron');
      expect(vendor.rfqStage, VendorRfqStage.none);
    });

    test('each date moves it along', () {
      const base = ProjectVendor(id: 'vendor1', name: 'Extron');
      expect(
        base.copyWith(rfqSentOn: DateTime(2026, 3, 4)).rfqStage,
        VendorRfqStage.sent,
      );
      expect(
        base
            .copyWith(
              rfqSentOn: DateTime(2026, 3, 4),
              quotedOn: DateTime(2026, 3, 11),
            )
            .rfqStage,
        VendorRfqStage.quoted,
      );
      expect(
        base.copyWith(poNumber: 'PO-1188').rfqStage,
        VendorRfqStage.ordered,
      );
    });

    test('the latest fact wins over the ones nobody recorded', () {
      // A vendor that was ordered is ordered whether or not anybody remembered
      // to note the quote coming back.
      const vendor = ProjectVendor(
        id: 'vendor1',
        name: 'Extron',
        poNumber: 'PO-1188',
      );
      expect(vendor.rfqStage, VendorRfqStage.ordered);
    });

    test('it survives a save and a reload', () {
      final vendor = ProjectVendor(
        id: 'vendor1',
        name: 'Extron',
        rfqSentOn: DateTime(2026, 3, 4),
        quotedOn: DateTime(2026, 3, 11),
        quoteAmount: 18400,
        quoteRef: 'Q-88421',
        orderedOn: DateTime(2026, 3, 14),
        poNumber: 'PO-1188',
      );
      final back = ProjectVendor.fromJson(vendor.toJson());
      expect(back.rfqSentOn, DateTime(2026, 3, 4));
      expect(back.quotedOn, DateTime(2026, 3, 11));
      expect(back.quoteAmount, 18400);
      expect(back.quoteRef, 'Q-88421');
      expect(back.orderedOn, DateTime(2026, 3, 14));
      expect(back.poNumber, 'PO-1188');
      expect(back.rfqStage, VendorRfqStage.ordered);
    });
  });

  group('recording the request and the quote', () {
    test('sent, then quoted, then un-quoted', () {
      final (:p, :vendorId) = job();

      p.setVendorRfqSent(vendorId, DateTime(2026, 3, 4));
      expect(p.project.vendorById(vendorId)!.rfqStage, VendorRfqStage.sent);

      p.setVendorQuote(
        vendorId,
        quotedOn: DateTime(2026, 3, 11),
        amount: 18400,
        reference: 'Q-88421',
      );
      final quoted = p.project.vendorById(vendorId)!;
      expect(quoted.rfqStage, VendorRfqStage.quoted);
      expect(quoted.quoteAmount, 18400);
      expect(quoted.quoteRef, 'Q-88421');

      // Taking the quote off takes the figure with it: a vendor with no quote
      // date and a price still on the row is a number nobody can source.
      p.setVendorQuote(vendorId, quotedOn: null);
      final unquoted = p.project.vendorById(vendorId)!;
      expect(unquoted.rfqStage, VendorRfqStage.sent);
      expect(unquoted.quoteAmount, 0);
      expect(unquoted.quoteRef, isEmpty);
    });

    test('recording a quote changes no price on the job', () {
      final (:p, :vendorId) = job();
      final before = p.priceProject().grandTotal;
      p.setVendorQuote(
        vendorId,
        quotedOn: DateTime(2026, 3, 11),
        amount: 999999,
      );
      expect(p.priceProject().grandTotal, before);
    });

    test('the vendor keeps its place in the list, because the order is a rule', () {
      final (:p, :vendorId) = job();
      final was = p.project.vendors.indexWhere((v) => v.id == vendorId);
      p.setVendorRfqSent(vendorId, DateTime(2026, 3, 4));
      expect(p.project.vendors.indexWhere((v) => v.id == vendorId), was);
    });
  });

  // -------------------------------------------------------------------------
  //  ORDERING, WHICH IS THE ONE THAT DOES SOMETHING
  // -------------------------------------------------------------------------

  group('marking a package ordered', () {
    test('raises the PO, points it at the vendor, and puts the kit on it', () {
      final (:p, :vendorId) = job();
      final estimate = p.priceProject();
      final package = estimate.packageFor(vendorId)!;
      final key = epsonKey(p);

      final onIt = p.markVendorOrdered(
        vendorId,
        poNumber: 'PO-1188',
        orderedOn: DateTime(2026, 3, 14),
        expectedOn: DateTime(2026, 5, 1),
        amount: 18400,
        partKeys: [for (final l in package.lines) l.key],
        partNames: {for (final l in package.lines) l.key: l.description},
      );

      expect(onIt, package.lines.length);

      // 1. The vendor says so.
      final vendor = p.project.vendorById(vendorId)!;
      expect(vendor.rfqStage, VendorRfqStage.ordered);
      expect(vendor.poNumber, 'PO-1188');
      expect(vendor.orderedOn, DateTime(2026, 3, 14));

      // 2. The job has the purchase order, pointed back at the vendor - which
      //    is what lets the Deliveries pane and the timeline find it.
      final po = p.project.poByNumber('PO-1188')!;
      expect(po.vendorId, vendorId);
      expect(po.issuedOn, DateTime(2026, 3, 14));
      expect(po.expectedOn, DateTime(2026, 5, 1));
      expect(po.amount, 18400);

      // 3. THE LINK BACK TO THE EQUIPMENT. This is the whole point: a PO
      //    number that cannot be followed to what it bought is a number, not
      //    a record.
      expect(p.project.partsOnPo('PO-1188'), contains(key));
      final order = p.project.orderForPart(key)!;
      expect(order.isOrdered, isTrue);
      expect(order.orderedOn, DateTime(2026, 3, 14));
      expect(order.expectedOn, DateTime(2026, 5, 1));
    });

    test('the Sharp line is left alone - it is another vendor\'s order', () {
      final (:p, :vendorId) = job();
      final package = p.priceProject().packageFor(vendorId)!;
      p.markVendorOrdered(
        vendorId,
        poNumber: 'PO-1188',
        orderedOn: DateTime(2026, 3, 14),
        partKeys: [for (final l in package.lines) l.key],
      );
      for (final line in p.priceProject().master) {
        if (line.manufacturer.toLowerCase() == 'sharp') {
          expect(p.project.orderForPart(line.key)?.isOrdered ?? false, isFalse);
        }
      }
    });

    test('a number the job already knows is reused, not duplicated', () {
      final (:p, :vendorId) = job();
      p.addProjectPo(number: 'PO-1188');
      p.markVendorOrdered(
        vendorId,
        poNumber: 'PO-1188',
        orderedOn: DateTime(2026, 3, 14),
      );
      expect(
        p.project.purchaseOrders.where((o) => o.number == 'PO-1188').length,
        1,
      );
    });

    test('a blank number orders nothing', () {
      final (:p, :vendorId) = job();
      expect(p.markVendorOrdered(vendorId, poNumber: '   '), 0);
      expect(p.project.purchaseOrders, isEmpty);
      expect(
        p.project.vendorById(vendorId)!.rfqStage,
        isNot(VendorRfqStage.ordered),
      );
    });

    test('un-marking leaves the PO and the parts exactly as they were', () {
      final (:p, :vendorId) = job();
      final package = p.priceProject().packageFor(vendorId)!;
      final key = epsonKey(p);
      p.markVendorOrdered(
        vendorId,
        poNumber: 'PO-1188',
        orderedOn: DateTime(2026, 3, 14),
        partKeys: [for (final l in package.lines) l.key],
      );

      p.clearVendorOrdered(vendorId);

      // The vendor row stops claiming it...
      expect(
        p.project.vendorById(vendorId)!.rfqStage,
        isNot(VendorRfqStage.ordered),
      );
      // ...and the paperwork is untouched, because it records what HAPPENED.
      // A mis-set flag on a vendor row is not a reason to unpick a job.
      expect(p.project.poByNumber('PO-1188'), isNotNull);
      expect(p.project.partsOnPo('PO-1188'), contains(key));
    });

    test('it is in the history, under the vendor and under each part', () {
      final (:p, :vendorId) = job();
      final package = p.priceProject().packageFor(vendorId)!;
      p.markVendorOrdered(
        vendorId,
        poNumber: 'PO-1188',
        orderedOn: DateTime(2026, 3, 14),
        partKeys: [for (final l in package.lines) l.key],
        partNames: {for (final l in package.lines) l.key: l.description},
      );

      final log = p.project.history;
      expect(
        log.where((h) => h.itemKind == 'vendor' && h.summary.contains('PO-1188')),
        isNotEmpty,
      );
      expect(
        log.where((h) => h.itemKind == 'part' && h.summary.contains('PO-1188')),
        isNotEmpty,
        reason: '"this says bought - who said so" is asked of the PART, and a '
            'single line on the vendor cannot answer it',
      );
    });
  });

  // -------------------------------------------------------------------------
  //  THE ORDER AS A DOCUMENT
  // -------------------------------------------------------------------------

  group('the PO carries the order itself', () {
    test('it is stored relative to the job, so the folder can move', () {
      final (:p, :vendorId) = job();
      p.currentProjectPath = path.join(dir.path, 'bessey_project.json');

      final pdf = path.join(dir.path, 'PO-1188 signed.pdf');
      File(pdf).writeAsStringSync('%PDF-1.4');
      final po = p.addProjectPo(number: 'PO-1188');
      p.setPoFile(po.id, pdf);

      final stored = p.project.poById(po.id)!.filePath;
      expect(
        path.isAbsolute(stored),
        isFalse,
        reason: 'a job under one folder travels onto a laptop with its '
            'paperwork still attached',
      );
      expect(stored, 'PO-1188 signed.pdf');
      expect(
        BuildingProject.resolvePath(stored, p.currentProjectPath),
        path.normalize(pdf),
      );
    });

    test('the file type decides which viewer opens it', () {
      final pdf = ProjectPo(id: 'po1', filePath: 'orders/PO-1188.pdf');
      expect(pdf.isPdf, isTrue);
      expect(pdf.isViewable, isTrue);
      // Still worth holding, and handed to the machine's own opener.
      final msg = ProjectPo(id: 'po2', filePath: 'orders/ack.msg');
      expect(msg.isPdf, isFalse);
      expect(msg.isViewable, isFalse);
    });

    test('taking the link off does not touch the file', () {
      final (:p, :vendorId) = job();
      final pdf = path.join(dir.path, 'PO-1188.pdf');
      File(pdf).writeAsStringSync('%PDF-1.4');
      final po = p.addProjectPo(number: 'PO-1188');
      p.setPoFile(po.id, pdf);

      p.setPoFile(po.id, '');

      expect(p.project.poById(po.id)!.filePath, isEmpty);
      expect(
        File(pdf).existsSync(),
        isTrue,
        reason: 'deleting somebody\'s paperwork off their disk is not '
            'something a project file gets to do',
      );
    });

    test('it survives a save and a reload', () {
      final po = ProjectPo(id: 'po1', number: 'PO-1188', filePath: 'po.pdf');
      expect(ProjectPo.fromJson(po.toJson()).filePath, 'po.pdf');
    });
  });

  // -------------------------------------------------------------------------
  //  ON THE SCREENS
  // -------------------------------------------------------------------------

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

  group('the vendor card', () {
    testWidgets('a closed card says where the quote has got to', (
      tester,
    ) async {
      final (:p, :vendorId) = job();
      p.setVendorRfqSent(vendorId, DateTime(2026, 3, 4));
      await openPane(tester, p, 'vendors');

      // A collapsed list of six vendors has to answer "which of these are we
      // waiting on" without any of them being opened.
      expect(
        find.byKey(ValueKey('vendor_rfq_chip_$vendorId')),
        findsOneWidget,
      );
      expect(find.text('RFQ sent'), findsWidgets);
    });

    testWidgets('a vendor nobody has written to carries no chip', (
      tester,
    ) async {
      final (:p, :vendorId) = job();
      await openPane(tester, p, 'vendors');
      expect(find.byKey(ValueKey('vendor_rfq_chip_$vendorId')), findsNothing);
    });

    testWidgets('the ordered card offers the way back to the equipment', (
      tester,
    ) async {
      final (:p, :vendorId) = job();
      final package = p.priceProject().packageFor(vendorId)!;
      p.markVendorOrdered(
        vendorId,
        poNumber: 'PO-1188',
        orderedOn: DateTime(2026, 3, 14),
        partKeys: [for (final l in package.lines) l.key],
      );
      await openPane(tester, p, 'vendors');

      await tester.tap(find.byKey(ValueKey('vendor_toggle_$vendorId')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(ValueKey('vendor_rfq_parts_$vendorId')),
        findsOneWidget,
      );
      // And the order itself can be attached from here.
      final po = p.project.poByNumber('PO-1188')!;
      expect(find.byKey(ValueKey('po_attach_${po.id}')), findsOneWidget);
    });
  });

  group('the timeline', () {
    testWidgets('what has already gone is a block of its own', (tester) async {
      final (:p, :vendorId) = job();
      final package = p.priceProject().packageFor(vendorId)!;
      p.markVendorOrdered(
        vendorId,
        poNumber: 'PO-1188',
        orderedOn: DateTime(2026, 3, 14),
        partKeys: [for (final l in package.lines) l.key],
      );
      await openPane(tester, p, 'timeline');

      final po = p.project.poByNumber('PO-1188')!;
      expect(find.byKey(ValueKey('timeline_order_${po.id}')), findsOneWidget);
      expect(find.text('ORDERED (1)'), findsOneWidget);
      // The link back to the equipment, from the timeline.
      expect(
        find.byKey(ValueKey('timeline_order_parts_${po.id}')),
        findsOneWidget,
      );
    });

    testWidgets('a job with nothing ordered says nothing about orders', (
      tester,
    ) async {
      final (:p, :vendorId) = job();
      await openPane(tester, p, 'timeline');
      // A heading over an empty box is one more thing to read.
      expect(find.textContaining('ORDERED ('), findsNothing);
    });
  });
}
