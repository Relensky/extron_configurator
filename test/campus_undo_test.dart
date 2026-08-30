import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/campus_file.dart';
import 'package:extron_configurator/campus_lifecycle_view.dart';

/// UNDO ON THE CAMPUS, WHICH IS A LIST SOMEBODY BUILT BY HAND.
///
/// An estate is assembled by picking eleven project files out of four folders,
/// and the only way back from a Remove pressed on the wrong row was to
/// remember which file it had been and go and find it again. That is the kind
/// of small, retrievable-in-principle loss that stops people using a control at
/// all — so Remove was a button somebody hovered over and thought about.
///
/// The document is two things, a name and a list of paths, so the history is
/// the same one every other document in the app uses and sixty deep like all of
/// them. What has to hold is what holds everywhere: a step goes back, it comes
/// forward again, and one estate's history cannot reach into another's.
///
/// EVERYTHING HERE WAITS ON THE REAL CLOCK. Changing the list re-reads every
/// job on it — the sheet holds no figures of its own, so a list that changed
/// has to be read again rather than patched — and that is file I/O with a
/// spinner over it. pumpAndSettle would sit on the spinner until it timed out.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_campus_undo'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A building with money on the plan and no config files to read, so the
  /// sheet can be assembled without any room I/O.
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

  /// Pumps frames on the real clock until [done], or until it gives up.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump();
  }

  Finder removeFor(String file) =>
      find.byKey(ValueKey('campus_remove_${path.basename(file)}'));

  bool shown(Finder f) => f.evaluate().isNotEmpty;

  IconButton bar(WidgetTester tester, String key) =>
      tester.widget<IconButton>(find.byKey(ValueKey(key)));

  /// Puts the campus screen up on [jobs] and waits for its first read.
  Future<void> pumpCampus(WidgetTester tester, List<String> jobs) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final provider = AppStateProvider(autoLoadSettings: false);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCampusLifecycleFile(
                context,
                CampusFile(name: 'Chico', projects: jobs),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await until(tester, () => shown(removeFor(jobs.last)));
  }

  testWidgets('a job removed by mistake comes straight back', (tester) async {
    final a = job('SCI');
    final b = job('BSS');
    await pumpCampus(tester, [a, b]);

    expect(removeFor(b), findsOneWidget, reason: 'both jobs are on the sheet');
    // Nothing to undo before anything has been done.
    expect(bar(tester, 'campus_undo').onPressed, isNull);

    await tester.tap(removeFor(b));
    await until(tester, () => shown(removeFor(a)) && !shown(removeFor(b)));
    expect(removeFor(b), findsNothing, reason: 'it went');

    expect(bar(tester, 'campus_undo').onPressed, isNotNull);
    // The step says WHICH job, because "Undo" alone on an estate of eleven
    // does not answer the only question somebody has.
    expect(bar(tester, 'campus_undo').tooltip, contains('BSS'));

    await tester.tap(find.byKey(const ValueKey('campus_undo')));
    await until(tester, () => shown(removeFor(b)));

    expect(removeFor(b), findsOneWidget, reason: 'and came back');
    expect(removeFor(a), findsOneWidget, reason: 'without disturbing the other');
  });

  testWidgets('and can be removed again with Redo', (tester) async {
    final a = job('SCI');
    final b = job('BSS');
    await pumpCampus(tester, [a, b]);

    await tester.tap(removeFor(b));
    await until(tester, () => shown(removeFor(a)) && !shown(removeFor(b)));
    await tester.tap(find.byKey(const ValueKey('campus_undo')));
    await until(tester, () => shown(removeFor(b)));

    expect(bar(tester, 'campus_redo').onPressed, isNotNull);
    expect(bar(tester, 'campus_redo').tooltip, contains('BSS'));

    await tester.tap(find.byKey(const ValueKey('campus_redo')));
    await until(tester, () => shown(removeFor(a)) && !shown(removeFor(b)));

    expect(removeFor(b), findsNothing);
    expect(removeFor(a), findsOneWidget);
  });

  testWidgets('an estate opened with nothing behind it offers no way back',
      (tester) async {
    await pumpCampus(tester, [job('SCI')]);

    // The hazard on a screen that opens other people's documents: an Undo that
    // pastes the estate somebody had finished with over the one they just
    // opened.
    expect(bar(tester, 'campus_undo').onPressed, isNull);
    expect(bar(tester, 'campus_redo').onPressed, isNull);
  });
}
