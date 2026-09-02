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
import 'package:extron_configurator/pinned_grid.dart';
import 'package:extron_configurator/project_view.dart';

/// THE RAIL, ON A JOB THAT RUNS FOR YEARS.
///
/// Two things it could not do. It could not show where the vendors had got to
/// - the quote requests were a list underneath, and a list has no distance in
/// it, so "did Extron quote before or after the walls close" was unanswerable
/// on the one drawing that exists to answer exactly that. And it always fitted
/// the whole job into the width of the card, which on a three-year refresh is
/// four days per pixel: every date in a fortnight is one dot.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_tl_graph_'));
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

  /// A job with a deadline far enough out that the rail has a real span, and
  /// two vendors to put on it.
  ({AppStateProvider p, String epson, String sharp, String bidder}) job() {
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
    p.project.rfqs.clear();
    final bidder = p.addProjectVendor(name: 'Alpha AV').id;
    final epson = p.addProjectRfq(title: 'Epson Direct');
    p.updateProjectRfq(
      epson.copyWith(manufacturers: const ['Epson']),
    );
    p.inviteVendorToRfq(epson.id, bidder);
    final sharp = p.addProjectRfq(title: 'Sharp Reseller');
    p.updateProjectRfq(
      sharp.copyWith(manufacturers: const ['Sharp']),
    );
    p.inviteVendorToRfq(sharp.id, bidder);
    p.addRoomToProject(writeRoom('r0'));
    // A MULTI-YEAR JOB. Three years of rail is the case the zoom exists for.
    p.setProjectDeadline(today().add(const Duration(days: 1100)));
    return (p: p, epson: epson.id, sharp: sharp.id, bidder: bidder);
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

  group('the packages are on the rail', () {
    testWidgets('a request that went out gets a mark of its own', (
      tester,
    ) async {
      final (:p, :epson, sharp: _, :bidder) = job();
      p.markRfqSent(epson, sentOn: today().add(const Duration(days: 20)));
      await openTimeline(tester, p);

      expect(find.byKey(const ValueKey('timeline_date_graph')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('timeline_date_mark_Epson Direct out to 1')),
        findsOneWidget,
      );
    });

    testWidgets('the mark says where the vendor has got to, not its history', (
      tester,
    ) async {
      // ONE MARK PER VENDOR, on its latest date. Three cards per vendor saying
      // what one card says is a rail nobody can read.
      final (:p, :epson, sharp: _, :bidder) = job();
      p.markRfqSent(epson, sentOn: today().add(const Duration(days: 20)));
      p.setBidQuote(epson, bidder, quotedOn: today().add(const Duration(days: 40)));
      await openTimeline(tester, p);

      expect(
        find.byKey(const ValueKey('timeline_date_mark_Epson Direct quoted')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('timeline_date_mark_Epson Direct out to 1')),
        findsNothing,
      );
    });

    testWidgets('two vendors are two marks', (tester) async {
      final (:p, :epson, :sharp, :bidder) = job();
      p.markRfqSent(epson, sentOn: today().add(const Duration(days: 20)));
      p.markRfqSent(sharp, sentOn: today().add(const Duration(days: 60)));
      await openTimeline(tester, p);

      expect(
        find.byKey(const ValueKey('timeline_date_mark_Epson Direct out to 1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('timeline_date_mark_Sharp Reseller out to 1')),
        findsOneWidget,
      );
    });

    testWidgets('a vendor nobody has written to is not on it', (tester) async {
      final (:p, :epson, :sharp, :bidder) = job();
      p.markRfqSent(epson, sentOn: today().add(const Duration(days: 20)));
      await openTimeline(tester, p);

      expect(
        find.byKey(const ValueKey('timeline_date_mark_Sharp Reseller out to 1')),
        findsNothing,
      );
    });
  });

  group('the rail zooms', () {
    testWidgets('it opens fitted, with nothing to scroll to', (tester) async {
      final (:p, :epson, sharp: _, :bidder) = job();
      p.markRfqSent(epson, sentOn: today().add(const Duration(days: 20)));
      await openTimeline(tester, p);

      expect(
        find.byKey(const ValueKey('timeline_graph_zoom_out')),
        findsOneWidget,
      );
      // Fitted is the whole job, and there is nothing further out than all of
      // it - so the out arrow is dead until somebody has zoomed in.
      final out = tester.widget<IconButton>(
        find.byKey(const ValueKey('timeline_graph_zoom_out')),
      );
      expect(out.onPressed, isNull);
    });

    testWidgets('the readout is a stretch of time, not a multiplier', (
      tester,
    ) async {
      final (:p, :epson, sharp: _, :bidder) = job();
      p.markRfqSent(epson, sentOn: today().add(const Duration(days: 20)));
      await openTimeline(tester, p);

      // Three years fitted. The number somebody wants off a calendar is how
      // much of the job is in front of them.
      expect(find.textContaining(' yr'), findsWidgets);
    });

    testWidgets('zooming in shortens the stretch in the frame', (tester) async {
      final (:p, :epson, sharp: _, :bidder) = job();
      p.markRfqSent(epson, sentOn: today().add(const Duration(days: 20)));
      await openTimeline(tester, p);

      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byKey(const ValueKey('timeline_graph_zoom_in')));
        await tester.pumpAndSettle();
      }

      // Four steps up kTimelineZoomSteps from 1 is 4x: three years becomes
      // about nine months.
      expect(find.textContaining(' mo'), findsWidgets);
      // And the rail is now longer than the card, so it scrolls.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('timeline_date_graph')),
          matching: find.byType(Scrollbar),
        ),
        findsWidgets,
      );
    });

    testWidgets('fit puts the whole job back in the frame', (tester) async {
      final (:p, :epson, sharp: _, :bidder) = job();
      p.markRfqSent(epson, sentOn: today().add(const Duration(days: 20)));
      await openTimeline(tester, p);

      await tester.tap(find.byKey(const ValueKey('timeline_graph_zoom_in')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('timeline_graph_zoom_in')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('timeline_graph_zoom_fit')));
      await tester.pumpAndSettle();

      final out = tester.widget<IconButton>(
        find.byKey(const ValueKey('timeline_graph_zoom_out')),
      );
      expect(out.onPressed, isNull, reason: 'back at the whole job');
    });

    test('the ladder starts at the whole job and climbs a long way', () {
      // A grid is unreadable past twice size; a time axis has to get from six
      // years down to one week.
      expect(kTimelineZoomSteps.first, kGridZoomNormal);
      expect(kTimelineZoomSteps.last, greaterThan(kGridZoomSteps.last));
      expect(gridZoomOut(kGridZoomNormal, kTimelineZoomSteps), kGridZoomNormal);
      expect(
        gridZoomIn(kGridZoomNormal, kTimelineZoomSteps),
        greaterThan(kGridZoomNormal),
      );
    });
  });
}
