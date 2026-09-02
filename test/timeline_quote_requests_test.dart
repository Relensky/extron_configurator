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

/// A QUOTE ROUND IS A SET OF DATES SOMEBODY IS WAITING ON.
///
/// Which makes it the same kind of thing as everything else on the timeline,
/// and it was on none of it: the Packages pane knew the Extron request went
/// out on the 4th to two vendors and neither has answered, and the screen
/// somebody opens to ask "what is late" did not. Every package whose request
/// has gone anywhere - out, part-quoted, quoted or awarded - is on the timeline
/// now, and the number of people still owing an answer is the point of it.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_tl_rfq_'));
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

  /// A job with two packages, split by maker, and two vendors invited onto
  /// each of them.
  ({AppStateProvider p, String epson, String sharp, String a, String b}) job() {
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
    // The starter split would claim these parts first; this test is about two
    // packages it wrote itself.
    p.project.rfqs.clear();
    final epson = p.addProjectRfq(title: 'Epson package');
    p.updateProjectRfq(epson.copyWith(manufacturers: const ['Epson']));
    final sharp = p.addProjectRfq(title: 'Sharp package');
    p.updateProjectRfq(sharp.copyWith(manufacturers: const ['Sharp']));
    final a = p.addProjectVendor(name: 'Alpha AV');
    final b = p.addProjectVendor(name: 'Beta Supply');
    for (final rfq in [epson.id, sharp.id]) {
      p.inviteVendorToRfq(rfq, a.id);
      p.inviteVendorToRfq(rfq, b.id);
    }
    p.addRoomToProject(writeRoom('r0'));
    return (p: p, epson: epson.id, sharp: sharp.id, a: a.id, b: b.id);
  }

  Future<void> openTimeline(WidgetTester tester, AppStateProvider p) async {
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
    await tester.tap(find.byKey(const ValueKey('project_pane_timeline')));
    await tester.pumpAndSettle();
  }

  group('what is out with the vendors', () {
    testWidgets('a job that has sent nothing says nothing about quotes', (
      tester,
    ) async {
      final (:p, epson: _, sharp: _, a: _, b: _) = job();
      await openTimeline(tester, p);
      // A heading over an empty box is one more thing to read.
      expect(find.textContaining('QUOTE REQUESTS'), findsNothing);
    });

    testWidgets('a request that went out counts everybody still owed', (
      tester,
    ) async {
      final (:p, :epson, sharp: _, a: _, b: _) = job();
      p.markRfqSent(epson, sentOn: today().subtract(const Duration(days: 9)));
      await openTimeline(tester, p);

      expect(find.byKey(ValueKey('timeline_rfq_$epson')), findsOneWidget);
      // TWO unanswered on ONE package. Counting package rows would say 1,
      // which is the number of requests written and not the number of people
      // who owe anybody a reply.
      expect(find.text('QUOTE REQUESTS (1) - 2 UNANSWERED'), findsOneWidget);
      // HOW LONG IT HAS BEEN SITTING, which is the whole reason it is on a
      // pane about dates.
      expect(
        find.textContaining('out 9 days with 2 answers still owed'),
        findsOneWidget,
      );
    });

    testWidgets('one answer in still leaves the other one owed', (
      tester,
    ) async {
      final (:p, :epson, sharp: _, :a, b: _) = job();
      p.markRfqSent(epson, sentOn: today().subtract(const Duration(days: 9)));
      p.setBidQuote(
        epson,
        a,
        quotedOn: today().subtract(const Duration(days: 2)),
        amount: 18400,
        reference: 'Q-88421',
      );
      await openTimeline(tester, p);

      expect(find.text('QUOTE REQUESTS (1) - 1 UNANSWERED'), findsOneWidget);
      expect(
        find.textContaining('out 9 days with 1 answer still owed'),
        findsOneWidget,
      );
      // And the price that IS in shows: a comparison of one is still the
      // comparison somebody is looking at.
      expect(find.textContaining('Alpha AV'), findsWidgets);
    });

    testWidgets('every quote in reads as an answer, not a wait', (
      tester,
    ) async {
      final (:p, :epson, sharp: _, :a, :b) = job();
      p.markRfqSent(epson, sentOn: DateTime(2026, 3, 4));
      p.setBidQuote(epson, a, quotedOn: DateTime(2026, 3, 9), amount: 18400);
      p.setBidQuote(
        epson,
        b,
        quotedOn: today().subtract(const Duration(days: 2)),
        amount: 17900,
      );
      await openTimeline(tester, p);

      // Nothing is unanswered any more, so the heading stops shouting.
      expect(find.text('QUOTE REQUESTS (1)'), findsOneWidget);
      // And the clock now runs from the LAST quote in, because that is the day
      // the decision became possible.
      expect(find.textContaining('all in 2 days, not awarded'), findsOneWidget);
    });

    testWidgets('a declined bid is an answer, not silence', (tester) async {
      final (:p, :epson, sharp: _, :a, :b) = job();
      p.markRfqSent(epson, sentOn: DateTime(2026, 3, 4));
      p.setBidQuote(epson, a, quotedOn: DateTime(2026, 3, 9), amount: 18400);
      p.setBidDeclined(epson, b, true);
      await openTimeline(tester, p);

      // Somebody who wrote back to say no is not somebody to chase.
      expect(find.text('QUOTE REQUESTS (1)'), findsOneWidget);
    });

    testWidgets('the prices are side by side, cheapest first', (tester) async {
      final (:p, :epson, sharp: _, :a, :b) = job();
      p.markRfqSent(epson, sentOn: DateTime(2026, 3, 4));
      p.setBidQuote(epson, a, quotedOn: DateTime(2026, 3, 9), amount: 18400);
      p.setBidQuote(epson, b, quotedOn: DateTime(2026, 3, 10), amount: 17900);
      await openTimeline(tester, p);

      final cheap = tester.getTopLeft(
        find.byKey(ValueKey('timeline_bid_${epson}_$b')),
      );
      final dear = tester.getTopLeft(
        find.byKey(ValueKey('timeline_bid_${epson}_$a')),
      );
      // One row of pills, so it is the x that orders them.
      expect(cheap.dx, lessThan(dear.dx));
    });

    testWidgets('an awarded package names the winner', (tester) async {
      final (:p, :epson, sharp: _, :a, :b) = job();
      p.markRfqSent(epson, sentOn: DateTime(2026, 3, 4));
      p.setBidQuote(epson, a, quotedOn: DateTime(2026, 3, 9), amount: 18400);
      p.setBidQuote(epson, b, quotedOn: DateTime(2026, 3, 10), amount: 17900);
      final package = p.priceProject().packageFor(epson)!;
      p.awardRfq(
        epson,
        vendorId: b,
        poNumber: 'PO-1188',
        awardedOn: DateTime(2026, 3, 14),
        partKeys: [for (final l in package.lines) l.key],
      );
      await openTimeline(tester, p);

      // Both blocks: the package's row AND the purchase order's. They answer
      // different questions - a PO raised outside any package is in one and
      // not the other.
      expect(find.byKey(ValueKey('timeline_rfq_$epson')), findsOneWidget);
      final po = p.project.poByNumber('PO-1188')!;
      expect(find.byKey(ValueKey('timeline_order_${po.id}')), findsOneWidget);
      // The winner leads the card now: after an award, "who is supplying this"
      // is the question being asked of the row.
      expect(
        find.textContaining('Beta Supply - Epson package'),
        findsOneWidget,
      );
    });

    testWidgets('the one to chase is at the top', (tester) async {
      // OUT BEFORE QUOTED, and inside each, oldest first: the request that has
      // been out longest and unanswered is the thing to chase.
      final (:p, :epson, :sharp, :a, :b) = job();
      p.markRfqSent(epson, sentOn: DateTime(2026, 3, 9));
      p.setBidQuote(epson, a, quotedOn: DateTime(2026, 3, 11));
      p.setBidQuote(epson, b, quotedOn: DateTime(2026, 3, 11));
      p.markRfqSent(sharp, sentOn: DateTime(2026, 3, 4));
      await openTimeline(tester, p);

      final waiting = tester.getTopLeft(
        find.byKey(ValueKey('timeline_rfq_$sharp')),
      );
      final answered = tester.getTopLeft(
        find.byKey(ValueKey('timeline_rfq_$epson')),
      );
      expect(waiting.dy, lessThan(answered.dy));
    });

    testWidgets('each quote document is one press from the timeline', (
      tester,
    ) async {
      final (:p, :epson, sharp: _, :a, b: _) = job();
      final pdf = path.join(dir.path, 'Q-88421.pdf');
      File(pdf).writeAsStringSync('%PDF-1.4');
      p.markRfqSent(epson, sentOn: DateTime(2026, 3, 4));
      p.setBidQuote(
        epson,
        a,
        quotedOn: DateTime(2026, 3, 11),
        amount: 18400,
        filePath: pdf,
      );
      await openTimeline(tester, p);

      expect(find.byKey(ValueKey('timeline_bid_${epson}_$a')), findsOneWidget);
      expect(find.textContaining('Alpha AV'), findsWidgets);
    });
  });
}
