import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/base_costs.dart';
import 'package:extron_configurator/lifecycle_view.dart';
import 'package:extron_configurator/project_view.dart';

/// ============================================================================
///  THE REPLACEMENT PLAN, ON THE WINDOW IT IS ACTUALLY READ ON
/// ============================================================================
///  Both of these screens are strips of figures over a sheet, and every strip
///  on them is a Wrap of little Rows. That shape has one failure and it has it
///  everywhere: a WRAP CAN ONLY MOVE A WHOLE CHILD ONTO THE NEXT LINE. It
///  cannot narrow one. So a Row inside it that is too wide by itself does not
///  wrap - it runs off the right-hand edge behind the overflow stripes, taking
///  a figure or a control with it.
///
///  That is not a hypothetical. It was live in five places at once: the sheet's
///  own zoom stepper, the building's condition bands, the room's condition
///  headline, the year chips on a room row, the whole-building figure, and the
///  refresh-cycle picker. All of them appeared at the SAME kind of setting -
///  a window at half a laptop's width with the reader's type turned up - which
///  is a real desk, not an edge case, and is exactly where somebody reads a
///  budget sheet beside the spreadsheet they are typing it into.
///
///  A GRID OF SIZES RATHER THAN ONE CASE, because every one of those was found
///  by a different combination and fixing one told you nothing about the next.
///  Flutter reports an overflow as a test error, so each of these holds simply
///  by being pumped: there is nothing to assert beyond "it laid out".
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_lc_layout_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A room with one dated projector on it - enough for every band, chip and
  /// figure on both strips to be drawn.
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {
          'gui_full_room_name': 'Bessey 101',
          'gve_bldg': 'BSS',
          'gve_room': '101',
        },
      };
    p.avDeviceLibrary = AvDeviceLibrary.empty();
    p.baseCosts = BaseCostBook(
      costs: [BaseCost(category: 'Projector', price: 6100)],
    );
    p.loadAvFlowForCurrentConfig();
    p.addAvNode(
      AvNode(
        id: 'PROJECTORDEVICE_1',
        label: 'Projector 1',
        model: 'PROJ-1',
        pos: Offset.zero,
        ports: const [],
        installedOn: DateTime(2016, 6, 1),
      ),
    );
    return p;
  }

  /// The same room as a job, so the building's own strip and its year chips
  /// are on screen too.
  AppStateProvider job() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty();
    p.baseCosts = BaseCostBook(
      costs: [BaseCost(category: 'Projector', price: 6100)],
    );
    p.newProject(name: 'Bessey Hall');
    final file = '${dir.path}/bss101_config.json';
    File(file).writeAsStringSync(
      '{"SYSTEM_SETUP":{"gve_bldg":"BSS","gve_room":"101"}}',
    );
    File('${dir.path}/bss101_config_av_flow.json').writeAsStringSync(
      '{"nodes":[{"id":"PROJECTORDEVICE_1","label":"Projector 1",'
      '"model":"PROJ-1","installedOn":"2016-06-01","ports":[]}],"cables":[]}',
    );
    p.addRoomToProject(file);
    return p;
  }

  Future<void> pump(
    WidgetTester tester,
    AppStateProvider p,
    Widget screen,
    double width,
    double scale,
  ) async {
    // TALL, so nothing is left unbuilt below the fold and out of the test's
    // reach. The width and the type are what this is about.
    final size = Size(width, 1400);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(body: screen),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // 560 is narrower than this app is meant to be used at and 200% is the top
  // of the range Windows offers; between them they are the corner every one of
  // these overflows was hiding in.
  const widths = [560.0, 720.0, 900.0, 1280.0, 1600.0];
  const scales = [1.0, 1.3, 1.5, 2.0];

  group('the room lifecycle tab lays out', () {
    for (final width in widths) {
      for (final scale in scales) {
        testWidgets('at ${width.toInt()}px, ${(scale * 100).toInt()}% type', (
          tester,
        ) async {
          await pump(tester, room(), const LifecycleView(), width, scale);
          expect(find.byType(LifecycleView), findsOneWidget);
        });
      }
    }
  });

  group('the building replacement plan lays out', () {
    for (final width in widths) {
      for (final scale in scales) {
        testWidgets('at ${width.toInt()}px, ${(scale * 100).toInt()}% type', (
          tester,
        ) async {
          await pump(tester, job(), const ProjectView(), width, scale);
          // By icon, not by label: the pane rail drops its labels on a window
          // this narrow and the key rides on the label.
          await tester.tap(find.byIcon(Icons.history_toggle_off));
          await tester.pumpAndSettle();
          expect(find.byType(ProjectView), findsOneWidget);
        });
      }
    }
  });

  // The pane the cycle picker was added to. It carries a second copy of that
  // control, so it is the one place a fix to the sheet's header would not have
  // covered.
  group('the Current models pane lays out', () {
    for (final width in widths) {
      for (final scale in scales) {
        testWidgets('at ${width.toInt()}px, ${(scale * 100).toInt()}% type', (
          tester,
        ) async {
          await pump(tester, room(), const LifecycleView(), width, scale);
          await tester.tap(find.text('Current models'));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('room_lifecycle_standards')),
            findsOneWidget,
          );
        });
      }
    }
  });
}
