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

/// AN RFQ IS A DATE SOMEBODY IS WAITING ON.
///
/// Which makes it the same kind of thing as everything else on the timeline,
/// and it was on none of it: the Vendors pane knew the Extron request went out
/// on the 4th and has never been answered, and the screen somebody opens to ask
/// "what is late" did not. Every vendor whose RFQ has gone anywhere - sent,
/// quoted or ordered - is on the timeline now.
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

  /// A job with two vendors: Epson's maker rule and Sharp's.
  ({AppStateProvider p, String epson, String sharp}) job() {
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
    final epson = p.addProjectVendor(name: 'Epson Direct');
    p.updateProjectVendor(
      ProjectVendor(
        id: epson.id,
        name: 'Epson Direct',
        manufacturers: const ['Epson'],
      ),
    );
    final sharp = p.addProjectVendor(name: 'Sharp Reseller');
    p.updateProjectVendor(
      ProjectVendor(
        id: sharp.id,
        name: 'Sharp Reseller',
        manufacturers: const ['Sharp'],
      ),
    );
    p.addRoomToProject(writeRoom('r0'));
    return (p: p, epson: epson.id, sharp: sharp.id);
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
      final (:p, epson: _, sharp: _) = job();
      await openTimeline(tester, p);
      // A heading over an empty box is one more thing to read.
      expect(find.textContaining('QUOTE REQUESTS'), findsNothing);
    });

    testWidgets('a request that went out is on the timeline', (tester) async {
      final (:p, :epson, sharp: _) = job();
      p.setVendorRfqSent(epson, today().subtract(const Duration(days: 9)));
      await openTimeline(tester, p);

      expect(find.byKey(ValueKey('timeline_rfq_$epson')), findsOneWidget);
      expect(find.text('QUOTE REQUESTS (1) - 1 UNANSWERED'), findsOneWidget);
      // HOW LONG IT HAS BEEN SITTING, which is the whole reason it is on a
      // pane about dates.
      expect(find.textContaining('out 9 days with no answer'), findsOneWidget);
    });

    testWidgets('a quote that came back reads as an answer, not a wait', (
      tester,
    ) async {
      final (:p, :epson, sharp: _) = job();
      p.setVendorRfqSent(epson, DateTime(2026, 3, 4));
      p.setVendorQuote(
        epson,
        quotedOn: today().subtract(const Duration(days: 2)),
        amount: 18400,
        reference: 'Q-88421',
      );
      await openTimeline(tester, p);

      expect(find.byKey(ValueKey('timeline_rfq_$epson')), findsOneWidget);
      // Nothing is unanswered any more, so the heading stops shouting.
      expect(find.text('QUOTE REQUESTS (1)'), findsOneWidget);
      expect(find.textContaining('in 2 days, not ordered'), findsOneWidget);
    });

    testWidgets('an ordered vendor is still the vendor\'s own story', (
      tester,
    ) async {
      final (:p, :epson, sharp: _) = job();
      final package = p.priceProject().packageFor(epson)!;
      p.markVendorOrdered(
        epson,
        poNumber: 'PO-1188',
        orderedOn: DateTime(2026, 3, 14),
        partKeys: [for (final l in package.lines) l.key],
      );
      await openTimeline(tester, p);

      // Both blocks: the vendor's row AND the purchase order's. They answer
      // different questions - a PO raised outside any vendor is in one and not
      // the other.
      expect(find.byKey(ValueKey('timeline_rfq_$epson')), findsOneWidget);
      final po = p.project.poByNumber('PO-1188')!;
      expect(find.byKey(ValueKey('timeline_order_${po.id}')), findsOneWidget);
    });

    testWidgets('the one to chase is at the top', (tester) async {
      // SENT BEFORE QUOTED, and inside each, oldest first: the request that
      // has been out longest and unanswered is the thing to chase.
      final (:p, :epson, :sharp) = job();
      p.setVendorQuote(epson, quotedOn: DateTime(2026, 3, 11));
      p.setVendorRfqSent(sharp, DateTime(2026, 3, 4));
      await openTimeline(tester, p);

      final waiting = tester.getTopLeft(find.byKey(ValueKey('timeline_rfq_$sharp')));
      final answered = tester.getTopLeft(find.byKey(ValueKey('timeline_rfq_$epson')));
      expect(waiting.dy, lessThan(answered.dy));
    });

    testWidgets('the quote document is one press from the timeline', (
      tester,
    ) async {
      final (:p, :epson, sharp: _) = job();
      final pdf = path.join(dir.path, 'Q-88421.pdf');
      File(pdf).writeAsStringSync('%PDF-1.4');
      p.setVendorRfqSent(epson, DateTime(2026, 3, 4));
      p.setVendorQuote(
        epson,
        quotedOn: DateTime(2026, 3, 11),
        filePath: pdf,
      );
      await openTimeline(tester, p);

      expect(
        find.byKey(ValueKey('timeline_rfq_quote_$epson')),
        findsOneWidget,
      );
      expect(find.text('Q-88421.pdf'), findsWidgets);
    });
  });
}
