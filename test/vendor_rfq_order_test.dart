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
///  WHERE THE QUOTES GOT TO, AND WHAT THE WINNER BOUGHT
/// ============================================================================
///  A job writes a PACKAGE and sends the same one to several vendors, who come
///  back with several prices. One wins and turns into a purchase order; the
///  others are why anybody can defend the choice six months later.
///
///  Two failures are guarded here. The first is the one that made this shape
///  necessary: a vendor used to BE the package, so it could only ever hold one
///  price, and a job that competed forty lines between three companies had
///  nowhere to put two of the answers.
///
///  The second is at the end of the chain. Ordering a package used to be three
///  jobs on two screens: raise the PO, open it, tick nineteen parts. What
///  happened on real jobs is that the first two got done and the third did not
///  - leaving a PO nobody could trace to any equipment, and nineteen parts
///  reading on the timeline as things nobody had bought.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_rfq_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A room with an Epson projector and a Sharp display on the drawing - two
  /// parts from two makers, so a package rule has something to sort.
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

  /// The job: one package claiming the Epson line, and two vendors invited to
  /// bid it.
  ({AppStateProvider p, String rfqId, String alpha, String beta}) job() {
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
    // starter split claims - see [BuildingProject.rfqForPart].
    final rfq = p.addProjectRfq(title: 'Epson package');
    p.updateProjectRfq(rfq.copyWith(manufacturers: const ['Epson']));
    final alpha = p.addProjectVendor(name: 'Alpha AV');
    final beta = p.addProjectVendor(name: 'Beta Supply');
    p.inviteVendorToRfq(rfq.id, alpha.id);
    p.inviteVendorToRfq(rfq.id, beta.id);
    p.addRoomToProject(writeRoom('r0', 'Bessey 101'));
    return (p: p, rfqId: rfq.id, alpha: alpha.id, beta: beta.id);
  }

  String epsonKey(AppStateProvider p) {
    for (final line in p.priceProject().master) {
      if (line.manufacturer.toLowerCase() == 'epson') return line.key;
    }
    throw StateError('no Epson part on the job');
  }

  // -------------------------------------------------------------------------
  //  THE STAGE
  // -------------------------------------------------------------------------

  group('the stage is read off the bids, never stored beside them', () {
    test('nothing asked is a draft', () {
      const rfq = ProjectRfq(id: 'rfq1', title: 'Extron');
      expect(rfq.stage, RfqStage.draft);
      // Inviting somebody is not sending to them.
      expect(
        rfq.withBid(const RfqBid(vendorId: 'v1')).stage,
        RfqStage.draft,
      );
    });

    test('a round moves along as the answers come in', () {
      final out = const ProjectRfq(id: 'rfq1', title: 'Extron')
          .withBid(RfqBid(vendorId: 'v1', sentOn: DateTime(2026, 3, 4)))
          .withBid(RfqBid(vendorId: 'v2', sentOn: DateTime(2026, 3, 4)));
      expect(out.stage, RfqStage.out);

      // ONE BACK OF TWO is its own state. It is the one that names the
      // chasing, and a two-state model had to call it either "waiting" - which
      // hides the price that did arrive - or "quoted", which hides the vendor
      // who still owes an answer.
      final partial = out.withBid(
        out.bidFor('v1')!.copyWith(
          quotedOn: DateTime(2026, 3, 9),
          amount: 18400,
        ),
      );
      expect(partial.stage, RfqStage.partial);
      expect(partial.outstanding.single.vendorId, 'v2');

      final quoted = partial.withBid(
        partial.bidFor('v2')!.copyWith(
          quotedOn: DateTime(2026, 3, 11),
          amount: 17900,
        ),
      );
      expect(quoted.stage, RfqStage.quoted);
      expect(quoted.lowestBid!.vendorId, 'v2');
    });

    test('a decline is an answer, so it completes the round', () {
      final rfq = const ProjectRfq(id: 'rfq1', title: 'Extron')
          .withBid(
            RfqBid(
              vendorId: 'v1',
              sentOn: DateTime(2026, 3, 4),
              quotedOn: DateTime(2026, 3, 9),
              amount: 18400,
            ),
          )
          .withBid(
            RfqBid(
              vendorId: 'v2',
              sentOn: DateTime(2026, 3, 4),
              declined: true,
            ),
          );
      expect(rfq.stage, RfqStage.quoted);
      expect(rfq.outstanding, isEmpty);
      // And a no-bid is never the cheapest quote.
      expect(rfq.lowestBid!.vendorId, 'v1');
    });

    test('the latest fact wins over the ones nobody recorded', () {
      // A package that was awarded is awarded whether or not anybody
      // remembered to note the quotes coming back.
      const rfq = ProjectRfq(
        id: 'rfq1',
        title: 'Extron',
        poNumber: 'PO-1188',
      );
      expect(rfq.stage, RfqStage.awarded);
    });

    test('it survives a save and a reload', () {
      final rfq = ProjectRfq(
        id: 'rfq1',
        title: 'Extron',
        scope: 'Net 30',
        dueBy: DateTime(2026, 3, 10),
        bids: [
          RfqBid(
            vendorId: 'v1',
            sentOn: DateTime(2026, 3, 4),
            quotedOn: DateTime(2026, 3, 11),
            amount: 18400,
            reference: 'Q-88421',
            expectedOn: DateTime(2026, 5, 1),
            notes: 'excludes freight',
          ),
          const RfqBid(vendorId: 'v2', declined: true),
        ],
        awardedVendorId: 'v1',
        awardedOn: DateTime(2026, 3, 14),
        poNumber: 'PO-1188',
      );
      final back = ProjectRfq.fromJson(rfq.toJson());

      expect(back.scope, 'Net 30');
      expect(back.dueBy, DateTime(2026, 3, 10));
      // THE LOSING BID COMES BACK TOO. It is the record of the competition,
      // and a file that dropped it would leave an award nobody could explain.
      expect(back.bids, hasLength(2));
      expect(back.bidFor('v2')!.declined, isTrue);
      final won = back.winningBid!;
      expect(won.amount, 18400);
      expect(won.reference, 'Q-88421');
      expect(won.expectedOn, DateTime(2026, 5, 1));
      expect(won.notes, 'excludes freight');
      expect(back.poNumber, 'PO-1188');
      expect(back.stage, RfqStage.awarded);
    });
  });

  // -------------------------------------------------------------------------
  //  THE FILE WRITTEN BEFORE PACKAGES EXISTED
  // -------------------------------------------------------------------------

  group('a project saved when a vendor was the package', () {
    test('becomes one package per vendor, with that vendor as its one bid',
        () async {
      final file = path.join(dir.path, 'old_project.json');
      File(file).writeAsStringSync(
        jsonEncode({
          'name': 'Bessey refresh',
          'rooms': [],
          'vendorCounter': 2,
          'vendors': [
            {
              'id': 'vendor1',
              'name': 'Epson Direct',
              'notes': 'Net 30, delivered to the dock.',
              'manufacturers': ['Epson'],
              'color': 0xFF1E88E5,
              'rfqSentOn': '2026-03-04',
              'quotedOn': '2026-03-11',
              'quoteAmount': 18400,
              'quoteRef': 'Q-88421',
              'orderedOn': '2026-03-14',
              'poNumber': 'PO-1188',
            },
            // Never given a rule and never asked anything: only ever a
            // contact, and it stays one.
            {'id': 'vendor2', 'name': 'Somebody we know'},
          ],
          'partVendors': {'equipment|pn:QM86R': 'vendor1'},
        }),
      );

      final back = await BuildingProject.load(file);

      // Both companies survive as companies.
      expect(back.vendors.map((v) => v.name), [
        'Epson Direct',
        'Somebody we know',
      ]);
      // One package, from the vendor that owned parts.
      expect(back.rfqs, hasLength(1));
      final rfq = back.rfqs.single;
      expect(rfq.title, 'Epson Direct');
      expect(rfq.manufacturers, ['Epson']);
      expect(rfq.color, 0xFF1E88E5);
      // The terms MOVED rather than copied - the same paragraph in two places
      // would now mean two different things.
      expect(rfq.scope, 'Net 30, delivered to the dock.');
      expect(back.vendors.first.notes, isEmpty);
      // The quote it held becomes its one bid, and the order becomes an award.
      final bid = rfq.bids.single;
      expect(bid.vendorId, 'vendor1');
      expect(bid.sentOn, DateTime(2026, 3, 4));
      expect(bid.quotedOn, DateTime(2026, 3, 11));
      expect(bid.amount, 18400);
      expect(bid.reference, 'Q-88421');
      expect(rfq.awardedVendorId, 'vendor1');
      expect(rfq.poNumber, 'PO-1188');
      expect(rfq.stage, RfqStage.awarded);
      // And the pin follows the parts onto the package that replaced it.
      expect(back.partRfqs['equipment|pn:QM86R'], rfq.id);
    });
  });

  // -------------------------------------------------------------------------
  //  ASKING, AND WHAT COMES BACK
  // -------------------------------------------------------------------------

  group('recording the request and the quotes', () {
    test('invited, sent, quoted, then un-quoted', () {
      final (:p, :rfqId, :alpha, :beta) = job();
      expect(p.project.rfqById(rfqId)!.bids, hasLength(2));

      // ONE ACTION FOR THE WHOLE PACKAGE: the file is written once and emailed
      // to both in one sitting.
      expect(p.markRfqSent(rfqId, sentOn: DateTime(2026, 3, 4)), 2);
      expect(p.project.rfqById(rfqId)!.stage, RfqStage.out);

      p.setBidQuote(
        rfqId,
        alpha,
        quotedOn: DateTime(2026, 3, 11),
        amount: 18400,
        reference: 'Q-88421',
      );
      final partial = p.project.rfqById(rfqId)!;
      expect(partial.stage, RfqStage.partial);
      expect(partial.bidFor(alpha)!.amount, 18400);
      expect(partial.bidFor(alpha)!.reference, 'Q-88421');

      // Taking the quote off takes the figure with it: a bid with no quote
      // date and a price still on it is a number nobody can source.
      p.setBidQuote(rfqId, alpha, quotedOn: null);
      final unquoted = p.project.rfqById(rfqId)!;
      expect(unquoted.stage, RfqStage.out);
      expect(unquoted.bidFor(alpha)!.amount, 0);
      expect(unquoted.bidFor(alpha)!.reference, isEmpty);
    });

    test('a vendor invited late gets a send date of their own', () {
      final (:p, :rfqId, :alpha, :beta) = job();
      p.markRfqSent(rfqId, sentOn: DateTime(2026, 3, 4));
      final late = p.addProjectVendor(name: 'Gamma Ltd');
      p.inviteVendorToRfq(rfqId, late.id);

      // Only the new one is marked, and the two originals keep their date.
      expect(p.markRfqSent(rfqId, sentOn: DateTime(2026, 3, 11)), 1);
      final rfq = p.project.rfqById(rfqId)!;
      expect(rfq.bidFor(alpha)!.sentOn, DateTime(2026, 3, 4));
      expect(rfq.bidFor(late.id)!.sentOn, DateTime(2026, 3, 11));
    });

    test('a vendor cannot be invited to the same package twice', () {
      final (:p, :rfqId, :alpha, beta: _) = job();
      p.inviteVendorToRfq(rfqId, alpha);
      expect(p.project.rfqById(rfqId)!.bids, hasLength(2));
    });

    test('declining clears any price, because they are one answer', () {
      final (:p, :rfqId, :alpha, beta: _) = job();
      p.setBidQuote(rfqId, alpha, quotedOn: DateTime(2026, 3, 11), amount: 18400);
      p.setBidDeclined(rfqId, alpha, true);

      final bid = p.project.rfqById(rfqId)!.bidFor(alpha)!;
      expect(bid.declined, isTrue);
      expect(bid.quotedOn, isNull);
      expect(bid.amount, 0);

      // And typing a price back in takes the decline off.
      p.setBidQuote(rfqId, alpha, quotedOn: DateTime(2026, 3, 12), amount: 17000);
      expect(p.project.rfqById(rfqId)!.bidFor(alpha)!.declined, isFalse);
    });

    test('recording a quote changes no price on the job', () {
      final (:p, :rfqId, :alpha, beta: _) = job();
      final before = p.priceProject().grandTotal;
      p.setBidQuote(
        rfqId,
        alpha,
        quotedOn: DateTime(2026, 3, 11),
        amount: 999999,
      );
      expect(p.priceProject().grandTotal, before);
    });

    test('the package keeps its place in the list, because order is a rule', () {
      final (:p, :rfqId, :alpha, beta: _) = job();
      final was = p.project.rfqs.indexWhere((r) => r.id == rfqId);
      p.markRfqSent(rfqId, sentOn: DateTime(2026, 3, 4));
      expect(p.project.rfqs.indexWhere((r) => r.id == rfqId), was);
    });
  });

  // -------------------------------------------------------------------------
  //  UNTIL IT IS AWARDED, NOBODY IS SUPPLYING ANYTHING
  // -------------------------------------------------------------------------

  group('the supplier on a part', () {
    test('is blank while the package is out to quote', () {
      final (:p, :rfqId, :alpha, beta: _) = job();
      p.markRfqSent(rfqId, sentOn: DateTime(2026, 3, 4));
      p.setBidQuote(rfqId, alpha, quotedOn: DateTime(2026, 3, 11), amount: 18400);

      final line = p.priceProject().master.firstWhere(
        (l) => l.manufacturer.toLowerCase() == 'epson',
      );
      // The part is in a package - that much is decided...
      expect(line.rfq?.id, rfqId);
      // ...but naming a supplier before an award would be reading a
      // purchasing assumption as a fact.
      expect(line.vendor, isNull);
    });

    test('is the winner once one is awarded', () {
      final (:p, :rfqId, :alpha, :beta) = job();
      final package = p.priceProject().packageFor(rfqId)!;
      p.awardRfq(
        rfqId,
        vendorId: beta,
        poNumber: 'PO-1188',
        partKeys: [for (final l in package.lines) l.key],
      );

      final line = p.priceProject().master.firstWhere(
        (l) => l.manufacturer.toLowerCase() == 'epson',
      );
      expect(line.vendor?.name, 'Beta Supply');
      // And the package now reads as the company, which is what "once chosen
      // we only need the chosen vendor listed" means.
      expect(p.priceProject().packageFor(rfqId)!.name, 'Beta Supply');
    });
  });

  // -------------------------------------------------------------------------
  //  AWARDING, WHICH IS THE ONE THAT DOES SOMETHING
  // -------------------------------------------------------------------------

  group('awarding a package', () {
    test('raises the PO, points it at the winner, and puts the kit on it', () {
      final (:p, :rfqId, :alpha, :beta) = job();
      final package = p.priceProject().packageFor(rfqId)!;
      final key = epsonKey(p);
      p.markRfqSent(rfqId, sentOn: DateTime(2026, 3, 4));
      p.setBidQuote(rfqId, alpha, quotedOn: DateTime(2026, 3, 9), amount: 18400);
      p.setBidQuote(rfqId, beta, quotedOn: DateTime(2026, 3, 10), amount: 17900);

      final onIt = p.awardRfq(
        rfqId,
        vendorId: beta,
        poNumber: 'PO-1188',
        awardedOn: DateTime(2026, 3, 14),
        expectedOn: DateTime(2026, 5, 1),
        amount: 17900,
        partKeys: [for (final l in package.lines) l.key],
        partNames: {for (final l in package.lines) l.key: l.description},
      );

      expect(onIt, package.lines.length);

      // 1. The package says so - and keeps the losing quote, which is what
      //    makes the choice explainable later.
      final rfq = p.project.rfqById(rfqId)!;
      expect(rfq.stage, RfqStage.awarded);
      expect(rfq.awardedVendorId, beta);
      expect(rfq.poNumber, 'PO-1188');
      expect(rfq.awardedOn, DateTime(2026, 3, 14));
      expect(rfq.bidFor(alpha)!.amount, 18400);

      // 2. The job has the purchase order, pointed at the winner - which is
      //    what lets the Deliveries pane and the timeline find it.
      final po = p.project.poByNumber('PO-1188')!;
      expect(po.vendorId, beta);
      expect(po.issuedOn, DateTime(2026, 3, 14));
      expect(po.expectedOn, DateTime(2026, 5, 1));
      expect(po.amount, 17900);

      // 3. THE LINK BACK TO THE EQUIPMENT. This is the whole point: a PO
      //    number that cannot be followed to what it bought is a number, not
      //    a record.
      expect(p.project.partsOnPo('PO-1188'), contains(key));
      final order = p.project.orderForPart(key)!;
      expect(order.isOrdered, isTrue);
      expect(order.orderedOn, DateTime(2026, 3, 14));
      expect(order.expectedOn, DateTime(2026, 5, 1));
    });

    test('the Sharp line is left alone - it is another package', () {
      final (:p, :rfqId, alpha: _, :beta) = job();
      final package = p.priceProject().packageFor(rfqId)!;
      p.awardRfq(
        rfqId,
        vendorId: beta,
        poNumber: 'PO-1188',
        awardedOn: DateTime(2026, 3, 14),
        partKeys: [for (final l in package.lines) l.key],
      );
      for (final line in p.priceProject().master) {
        if (line.manufacturer.toLowerCase() == 'sharp') {
          expect(p.project.orderForPart(line.key)?.isOrdered ?? false, isFalse);
        }
      }
    });

    test('a number the job already knows is reused, not duplicated', () {
      final (:p, :rfqId, alpha: _, :beta) = job();
      p.addProjectPo(number: 'PO-1188');
      p.awardRfq(
        rfqId,
        vendorId: beta,
        poNumber: 'PO-1188',
        awardedOn: DateTime(2026, 3, 14),
      );
      expect(
        p.project.purchaseOrders.where((o) => o.number == 'PO-1188').length,
        1,
      );
    });

    test('a blank number, or nobody named, awards nothing', () {
      final (:p, :rfqId, alpha: _, :beta) = job();
      expect(p.awardRfq(rfqId, vendorId: beta, poNumber: '   '), 0);
      expect(p.awardRfq(rfqId, vendorId: '', poNumber: 'PO-1188'), 0);
      expect(p.project.purchaseOrders, isEmpty);
      expect(p.project.rfqById(rfqId)!.stage, isNot(RfqStage.awarded));
    });

    test('un-awarding leaves the PO, the parts and every bid as they were', () {
      final (:p, :rfqId, :alpha, :beta) = job();
      final package = p.priceProject().packageFor(rfqId)!;
      final key = epsonKey(p);
      p.setBidQuote(rfqId, alpha, quotedOn: DateTime(2026, 3, 9), amount: 18400);
      p.awardRfq(
        rfqId,
        vendorId: beta,
        poNumber: 'PO-1188',
        awardedOn: DateTime(2026, 3, 14),
        partKeys: [for (final l in package.lines) l.key],
      );

      p.clearRfqAward(rfqId);

      // The package stops claiming it...
      final rfq = p.project.rfqById(rfqId)!;
      expect(rfq.stage, isNot(RfqStage.awarded));
      expect(rfq.awardedVendorId, isEmpty);
      // ...the quotes are still there to decide again...
      expect(rfq.bidFor(alpha)!.amount, 18400);
      // ...and the paperwork is untouched, because it records what HAPPENED.
      // A mis-set award is not a reason to unpick a job.
      expect(p.project.poByNumber('PO-1188'), isNotNull);
      expect(p.project.partsOnPo('PO-1188'), contains(key));
    });

    test('the winner cannot be un-invited out from under the award', () {
      final (:p, :rfqId, alpha: _, :beta) = job();
      p.awardRfq(rfqId, vendorId: beta, poNumber: 'PO-1188');
      p.removeVendorFromRfq(rfqId, beta);
      expect(p.project.rfqById(rfqId)!.bidFor(beta), isNotNull);
    });

    test('deleting the winning company takes the award back, not the PO', () {
      final (:p, :rfqId, alpha: _, :beta) = job();
      final package = p.priceProject().packageFor(rfqId)!;
      p.awardRfq(
        rfqId,
        vendorId: beta,
        poNumber: 'PO-1188',
        partKeys: [for (final l in package.lines) l.key],
      );

      p.removeProjectVendor(beta);

      final rfq = p.project.rfqById(rfqId)!;
      expect(rfq.awardedVendorId, isEmpty);
      expect(rfq.bidFor(beta), isNull);
      // The order still happened.
      expect(p.project.poByNumber('PO-1188'), isNotNull);
      expect(p.project.partsOnPo('PO-1188'), isNotEmpty);
    });

    test('it is in the history, under the package and under each part', () {
      final (:p, :rfqId, :alpha, :beta) = job();
      final package = p.priceProject().packageFor(rfqId)!;
      p.setBidQuote(rfqId, alpha, quotedOn: DateTime(2026, 3, 9), amount: 17000);
      p.setBidQuote(rfqId, beta, quotedOn: DateTime(2026, 3, 10), amount: 17900);
      p.awardRfq(
        rfqId,
        vendorId: beta,
        poNumber: 'PO-1188',
        awardedOn: DateTime(2026, 3, 14),
        partKeys: [for (final l in package.lines) l.key],
        partNames: {for (final l in package.lines) l.key: l.description},
      );

      final log = p.project.history;
      final onRfq = log.where(
        (h) => h.itemKind == 'rfq' && h.summary.contains('PO-1188'),
      );
      expect(onRfq, isNotEmpty);
      // "We did not take the lowest" is the decision that gets asked about, so
      // it is written down at the moment it is taken rather than left to be
      // reconstructed from the bids.
      expect(
        onRfq.any((h) => h.summary.contains('not the lowest')),
        isTrue,
      );
      expect(
        log.where((h) => h.itemKind == 'part' && h.summary.contains('PO-1188')),
        isNotEmpty,
        reason: '"this says bought - who said so" is asked of the PART, and a '
            'single line on the package cannot answer it',
      );
    });
  });

  // -------------------------------------------------------------------------
  //  SPLIT AWARDS
  // -------------------------------------------------------------------------

  group('half a package going to somebody else', () {
    test('is said by splitting the package, not by two vendors on one part',
        () {
      final (:p, :rfqId, alpha: _, beta: _) = job();
      final key = epsonKey(p);
      final other = p.addProjectRfq(title: 'Long-lead items');

      expect(p.movePartsToRfq([key], toRfqId: other.id), 1);

      // The part is in exactly one package - the invariant every PO, delivery
      // and color downstream rests on.
      expect(p.project.partRfqs[key], other.id);
      final line = p.priceProject().master.firstWhere((l) => l.key == key);
      expect(line.rfq?.id, other.id);
    });
  });

  // -------------------------------------------------------------------------
  //  THE ORDER AS A DOCUMENT
  // -------------------------------------------------------------------------

  group('the PO carries the order itself', () {
    test('it is stored relative to the job, so the folder can move', () {
      final (:p, rfqId: _, alpha: _, beta: _) = job();
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
      final (:p, rfqId: _, alpha: _, beta: _) = job();
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

  group('the package card', () {
    testWidgets('a closed card says where the quotes have got to', (
      tester,
    ) async {
      final (:p, :rfqId, alpha: _, beta: _) = job();
      p.markRfqSent(rfqId, sentOn: DateTime(2026, 3, 4));
      await openPane(tester, p, 'vendors');

      // A collapsed list of six packages has to answer "which of these are we
      // waiting on" without any of them being opened.
      expect(find.byKey(ValueKey('rfq_chip_$rfqId')), findsOneWidget);
      expect(find.text('Out'), findsWidgets);
    });

    testWidgets('a package nobody has written to carries no chip', (
      tester,
    ) async {
      final (:p, :rfqId, alpha: _, beta: _) = job();
      await openPane(tester, p, 'vendors');
      expect(find.byKey(ValueKey('rfq_chip_$rfqId')), findsNothing);
    });

    testWidgets('the comparison lists every bidder, cheapest first', (
      tester,
    ) async {
      final (:p, :rfqId, :alpha, :beta) = job();
      p.markRfqSent(rfqId, sentOn: DateTime(2026, 3, 4));
      p.setBidQuote(rfqId, alpha, quotedOn: DateTime(2026, 3, 9), amount: 18400);
      p.setBidQuote(rfqId, beta, quotedOn: DateTime(2026, 3, 10), amount: 17900);
      await openPane(tester, p, 'vendors');
      await tester.tap(find.byKey(ValueKey('rfq_toggle_$rfqId')));
      await tester.pumpAndSettle();

      final cheap = tester.getTopLeft(
        find.byKey(ValueKey('rfq_bid_${rfqId}_$beta')),
      );
      final dear = tester.getTopLeft(
        find.byKey(ValueKey('rfq_bid_${rfqId}_$alpha')),
      );
      expect(cheap.dy, lessThan(dear.dy));
      // The lowest is marked even before anybody awards anything.
      expect(find.text('lowest'), findsOneWidget);
      // And there is something to press once a price is in.
      expect(find.byKey(ValueKey('rfq_award_$rfqId')), findsOneWidget);
    });

    testWidgets('a vendor still owed an answer is on the table too', (
      tester,
    ) async {
      final (:p, :rfqId, :alpha, beta: _) = job();
      p.markRfqSent(rfqId, sentOn: DateTime(2026, 3, 4));
      p.setBidQuote(rfqId, alpha, quotedOn: DateTime(2026, 3, 9), amount: 18400);
      await openPane(tester, p, 'vendors');
      await tester.tap(find.byKey(ValueKey('rfq_toggle_$rfqId')));
      await tester.pumpAndSettle();

      // Leaving them off would make a comparison of one look complete when a
      // second was asked and never answered - the state most worth seeing
      // before awarding, because a phone call can still fix it.
      expect(find.textContaining('no reply'), findsOneWidget);
    });

    testWidgets('the awarded card offers the way back to the equipment', (
      tester,
    ) async {
      final (:p, :rfqId, alpha: _, :beta) = job();
      final package = p.priceProject().packageFor(rfqId)!;
      p.awardRfq(
        rfqId,
        vendorId: beta,
        poNumber: 'PO-1188',
        awardedOn: DateTime(2026, 3, 14),
        partKeys: [for (final l in package.lines) l.key],
      );
      await openPane(tester, p, 'vendors');

      await tester.tap(find.byKey(ValueKey('rfq_toggle_$rfqId')));
      await tester.pumpAndSettle();

      expect(find.byKey(ValueKey('rfq_parts_$rfqId')), findsOneWidget);
      // And the order itself can be attached from here.
      final po = p.project.poByNumber('PO-1188')!;
      expect(find.byKey(ValueKey('po_attach_${po.id}')), findsOneWidget);
    });
  });

  group('the timeline', () {
    testWidgets('what has already gone is a block of its own', (tester) async {
      final (:p, :rfqId, alpha: _, :beta) = job();
      final package = p.priceProject().packageFor(rfqId)!;
      p.awardRfq(
        rfqId,
        vendorId: beta,
        poNumber: 'PO-1188',
        awardedOn: DateTime(2026, 3, 14),
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
      final (:p, rfqId: _, alpha: _, beta: _) = job();
      await openPane(tester, p, 'timeline');
      // A heading over an empty box is one more thing to read.
      expect(find.textContaining('ORDERED ('), findsNothing);
    });
  });
}
