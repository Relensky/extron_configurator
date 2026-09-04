import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/campus_file.dart';
import 'package:extron_configurator/campus_lifecycle_view.dart';
import 'package:extron_configurator/main.dart';
import 'package:extron_configurator/project_view.dart';

/// ============================================================================
///  IT HAS TO FIT THE WINDOW SOMEBODY ACTUALLY HAS
/// ============================================================================
///  Two things break a layout in this app and neither of them is the developer
///  machine: a HALF-WIDTH WINDOW, because these screens are read beside a
///  drawing or a spreadsheet, and a DISPLAY AT 150%, because the people who
///  read replacement plans in meeting rooms have their text turned up.
///
///  Both are the same failure — a Row that will not give — and it shows up as
///  the black-and-yellow stripes over a control that can no longer be pressed
///  on a screen that had room for it. The individual tabs each guard their own
///  worst case; this sweeps the whole application at both of them at once, so
///  a control added to a header row that already had three cannot quietly cost
///  somebody the button beside it.
///
///  EVERY PANE, EVERY WIDTH, EVERY SCALE. Slow, and worth it: an overflow is
///  invisible to the person who wrote it and obvious to everybody else.
/// ============================================================================
/// EVERY BUTTON LABEL ON SCREEN THAT IS BEING CUT.
///
/// A hard overflow throws and is caught by the checks below. A label that is
/// merely SQUEEZED does not: Flutter quietly wraps or ellipsizes it, the test
/// suite stays green, and the reader gets 'Create a New Fi...' on a control
/// they have never used before. That failure is invisible to whoever wrote it
/// and obvious to everybody else, which is exactly the kind this app cannot
/// find by looking.
///
/// A BUTTON, SPECIFICALLY. Prose is allowed to ellipsize - a room name, a file
/// path, a sentence with a tooltip behind it - and demanding that every string
/// in the application fit would be a rule nobody could keep. A CONTROL is
/// different: a label that is cut is a control somebody cannot identify, and
/// there is no tooltip on most of them.
///
/// Compares what each label was given against what it asked for, so it catches
/// the wrap as well as the ellipsis.
Set<String> squeezedButtonLabels(WidgetTester tester) {
  final out = <String>{};
  for (final button
      in find.byWidgetPredicate((w) => w is ButtonStyleButton).evaluate()) {
    final labels = find.descendant(
      of: find.byWidget(button.widget),
      matching: find.byType(Text),
    );
    for (final label in labels.evaluate()) {
      final render = label.findRenderObject();
      if (render is! RenderParagraph) continue;
      final wants = render.getMaxIntrinsicWidth(double.infinity);
      if (wants > render.size.width + 0.5) {
        out.add(
          '"${(label.widget as Text).data}" had '
          '${render.size.width.toStringAsFixed(0)} px and wanted '
          '${wants.toStringAsFixed(0)}',
        );
      }
    }
  }
  return out;
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_layout_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AvNode device(String id, String label, String model, {DateTime? installed}) =>
      AvNode(
        id: id,
        label: label,
        model: model,
        pos: Offset.zero,
        ports: const [],
        installedOn: installed,
      );

  String writeRoom(String stem, String name, List<AvNode> nodes) {
    final configPath = path.join(dir.path, '${stem}_config.json');
    File(configPath).writeAsStringSync(
      jsonEncode({
        'SYSTEM_SETUP': {'gui_full_room_name': name},
      }),
    );
    File(path.join(dir.path, '${stem}_config_av_flow.json')).writeAsStringSync(
      jsonEncode({'nodes': [for (final n in nodes) n.toJson()]}),
    );
    return configPath;
  }

  /// A job with enough on it that every pane has something to draw: two rooms,
  /// priced equipment, install dates so the plan has years, and a deadline so
  /// the timeline has a rail.
  AppStateProvider withProject() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(
          model: 'DTP2 T 211',
          manufacturer: 'Extron',
          partNumber: '60-1439-13',
          category: 'Transmitter',
          price: 500,
          ports: [],
        ),
      )
      ..upsert(
        const AvDeviceTemplate(
          model: 'RoboSHOT 12E',
          manufacturer: 'Vaddio',
          category: 'Camera',
          price: 2000,
          ports: [],
        ),
      );

    p.newProject(name: 'Bessey refresh', building: 'BSS');
    p.addRoomToProject(
      writeRoom('a', 'Bessey 101', [
        device('d1', 'Lectern TX', 'DTP2 T 211', installed: DateTime(2016, 5)),
        device('d2', 'Room camera', 'RoboSHOT 12E',
            installed: DateTime(2019, 5)),
      ]),
    );
    p.addRoomToProject(
      writeRoom('b', 'Bessey 103', [
        device('d1', 'Lectern TX', 'DTP2 T 211', installed: DateTime(2014, 5)),
      ]),
    );
    p.setProjectDeadline(DateTime.now().add(const Duration(days: 400)));
    return p;
  }

  /// The panes on the Project tab, and the icon each falls back to when the
  /// window is too narrow to carry its label.
  const panes = <({String key, IconData icon})>[
    (key: 'rooms', icon: Icons.meeting_room),
    (key: 'parts', icon: Icons.inventory_2),
    (key: 'plans', icon: Icons.architecture),
    (key: 'timeline', icon: Icons.event_available),
    (key: 'lifecycle', icon: Icons.history_toggle_off),
    (key: 'responsibility', icon: Icons.handshake_outlined),
    (key: 'vendors', icon: Icons.local_shipping),
    (key: 'todo', icon: Icons.checklist),
    (key: 'notes', icon: Icons.sticky_note_2_outlined),
  ];

  Future<void> pumpProject(
    WidgetTester tester,
    AppStateProvider p, {
    required double width,
    required double textScale,
  }) async {
    final size = Size(width, 1000);
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
              textScaler: TextScaler.linear(textScale),
            ),
            child: const Scaffold(body: ProjectView()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // -------------------------------------------------------------------------
  //  THE JOB, ON EVERY WINDOW IT IS READ ON
  // -------------------------------------------------------------------------

  // 900 is a half-width window on a 1080p laptop, 1400 a maximised one, and
  // 1900 a desktop. 150% is the display scale a meeting room runs at.
  for (final width in [900.0, 1400.0, 1900.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets(
        'every project pane fits ${width.round()} px at '
        '${(scale * 100).round()}%',
        (tester) async {
          final p = withProject();
          for (final pane in panes) {
            await pumpProject(tester, p, width: width, textScale: scale);
            final labeled = find.byKey(ValueKey('project_pane_${pane.key}'));
            await tester.tap(
              labeled.evaluate().isEmpty
                  ? find.byIcon(pane.icon).first
                  : labeled.first,
            );
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '${pane.key} at $width px, ${scale * 100}%',
            );
            expect(
              squeezedButtonLabels(tester),
              isEmpty,
              reason: '${pane.key} at $width px, ${scale * 100}%',
            );
          }
        },
      );
    }
  }

  // -------------------------------------------------------------------------
  //  THE WHAT-IF CONTROL, WHICH SITS ON A HEADER ROW THAT WAS ALREADY FULL
  // -------------------------------------------------------------------------

  for (final width in [900.0, 1400.0]) {
    testWidgets(
      'the plan fits ${width.round()} px with a cycle assumed',
      (tester) async {
        final p = withProject();
        // The state the control's own line only exists in - see
        // [AssumedCycleNote]. A restated plan carries a sentence and three
        // figures the plan as recorded does not.
        p.setAssumedLifeCycle(12);
        await pumpProject(tester, p, width: width, textScale: 1.5);
        await tester.tap(find.byIcon(Icons.history_toggle_off).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  // -------------------------------------------------------------------------
  //  THE ESTATE
  // -------------------------------------------------------------------------
  //  Never swept before, and it carries the widest header in the app: a mode
  //  strip, five controls, a calendar with its own zoom, and now a what-if
  //  picker beside it.

  String job(String stem) {
    final project = BuildingProject(name: stem, building: stem);
    project.addManualRoom(
      name: '$stem 101',
      installedOn: DateTime(2018, 7),
      lifeYears: 8,
      replacementCost: 24000,
    );
    final file = path.join(dir.path, '${stem}_project.json');
    File(file).writeAsStringSync(jsonEncode(project.toJson()));
    return file;
  }

  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump();
  }

  for (final width in [1100.0, 1400.0, 1900.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets(
        'the campus fits ${width.round()} px at ${(scale * 100).round()}%',
        (tester) async {
          final size = Size(width, 1000);
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final provider = AppStateProvider(autoLoadSettings: false);
          await tester.pumpWidget(
            ChangeNotifierProvider<AppStateProvider>.value(
              value: provider,
              child: MaterialApp(
                home: MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: Builder(
                    builder: (context) => Scaffold(
                      body: Center(
                        child: TextButton(
                          onPressed: () => showCampusLifecycleFile(
                            context,
                            CampusFile(
                              name: 'Chico',
                              projects: [job('SCI'), job('BSS')],
                            ),
                          ),
                          child: const Text('open'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('open'));
          await settle(
            tester,
            () => find.byType(CampusYearGrid).evaluate().isNotEmpty,
          );
          expect(
            tester.takeException(),
            isNull,
            reason: 'the campus at $width px, ${scale * 100}%',
          );
          expect(
            squeezedButtonLabels(tester),
            isEmpty,
            reason: 'the campus at $width px, ${scale * 100}%',
          );
        },
      );
    }
  }

  // -------------------------------------------------------------------------
  //  APP CONFIG
  // -------------------------------------------------------------------------
  //  A column of path rows, each a field and a fixed-width button - see
  //  settings_path_rows_test.dart. The button cannot shrink, so a narrow
  //  window at 150% is where it would run the field into it.

  for (final width in [900.0, 1400.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets(
        'app config fits ${width.round()} px at ${(scale * 100).round()}%',
        (tester) async {
          final size = Size(width, 2400);
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final provider = AppStateProvider(autoLoadSettings: false);
          await tester.pumpWidget(
            ChangeNotifierProvider<AppStateProvider>.value(
              value: provider,
              child: MaterialApp(
                home: MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: const Scaffold(body: AppSettingsView()),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'app config at $width px, ${scale * 100}%',
          );
          expect(
            squeezedButtonLabels(tester),
            isEmpty,
            reason: 'app config at $width px, ${scale * 100}%',
          );
        },
      );
    }
  }

  // -------------------------------------------------------------------------
  //  EVERY TAB IN THE RAIL, WITH NO ROOM OPEN
  // -------------------------------------------------------------------------
  //  The state the application starts in, and the one nobody re-checks: the
  //  "no configuration loaded" screen stands in front of eleven of the fifteen
  //  tabs, and the one control on it is the first control a new user ever
  //  meets. It read 'Create a New Fi...' at every size there is.

  for (final width in [1100.0, 1500.0]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets(
        'every tab in the rail fits ${width.round()} px at '
        '${(scale * 100).round()}%',
        (tester) async {
          final size = Size(width, 900);
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          // The whole application rather than one pane: the rail, the banner
          // and the page are laid out against each other, and a tab checked on
          // its own is a tab checked with the rail's width given back to it.
          final p = withProject()
            ..settingsLoaded = true
            ..firstRunSetupNeeded = false
            ..textScale = scale;
          await tester.pumpWidget(
            ChangeNotifierProvider<AppStateProvider>.value(
              value: p,
              child: const RoomConfigApp(),
            ),
          );
          await tester.pumpAndSettle();

          for (final tab in AppTab.values) {
            p.selectTab(tab.index);
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '${tab.name} at $width px, ${scale * 100}%',
            );
            expect(
              squeezedButtonLabels(tester),
              isEmpty,
              reason: '${tab.name} at $width px, ${scale * 100}%',
            );
          }
        },
      );
    }
  }
}
