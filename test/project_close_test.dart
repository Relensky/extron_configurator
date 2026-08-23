import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_view.dart';

/// Putting a job away.
///
/// The failure this guards is a Close that does not close: a room list left
/// behind, a dirty flag still set, or — the expensive one — a job discarded
/// without anybody being asked about the ten minutes of tagging that was only
/// ever in memory.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('close_test_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppStateProvider withProject() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    final file = '${dir.path}/bss101_config.json';
    File(file).writeAsStringSync('{"SYSTEM_SETUP":{}}');
    p.addRoomToProject(file);
    return p;
  }

  Future<void> pump(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: ProjectView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  final closeButton = find.byKey(const ValueKey('project_close'));

  /// Lets the "Closed ..." bar run out.
  ///
  /// showTimedSnackBar arms a Timer a little past the bar's own duration, and
  /// a test that ends while it is still armed fails on a pending timer rather
  /// than on anything it was checking.
  Future<void> letTheSnackBarGo(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  }

  group('the provider side', () {
    test('closing leaves an EMPTY job, not a new one', () {
      final p = withProject();
      expect(p.project.rooms, isNotEmpty);
      expect(p.project.vendors, isNotEmpty, reason: 'New seeds the split');

      p.closeProject();

      expect(p.project.rooms, isEmpty);
      expect(p.project.name, isEmpty);
      expect(p.currentProjectPath, isEmpty);
      expect(p.projectDirty, isFalse);
      // Not "a new project": Close that left the starter vendors behind would
      // be a Close that did not close anything.
      expect(p.project.vendors, isEmpty);
      expect(p.project.isEmpty, isTrue);
    });

    test('the open room is left exactly where it was', () {
      final p = withProject();
      p.roomConfig = {'SYSTEM_SETUP': {}};
      p.currentConfigPath = '${dir.path}/bss101_config.json';

      p.closeProject();

      // A room is its own document. Closing the job it belongs to is not a
      // reason to shut it.
      expect(p.roomConfig, isNotEmpty);
      expect(p.currentConfigPath, isNotEmpty);
      // ...but it is no longer one of the project's rooms, because there is
      // no project.
      expect(p.openProjectRoom, isNull);
    });

    test('a closed job can be started again cleanly', () {
      final p = withProject();
      p.closeProject();
      p.newProject(name: 'Second job');

      expect(p.project.name, 'Second job');
      expect(p.project.rooms, isEmpty);
      expect(p.project.vendors, isNotEmpty, reason: 'New seeds them again');
    });
  });

  group('the button', () {
    testWidgets('closes a saved job without asking', (tester) async {
      final p = withProject();
      // Saved: nothing at stake, so no prompt.
      p.projectDirty = false;
      await pump(tester, p);

      await tester.tap(closeButton);
      await tester.pumpAndSettle();

      expect(p.project.rooms, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      await letTheSnackBarGo(tester);
    });

    testWidgets('asks first when there is unsaved work, and Cancel stops it', (
      tester,
    ) async {
      final p = withProject();
      expect(p.projectDirty, isTrue, reason: 'adding a room is an edit');
      await pump(tester, p);

      await tester.tap(closeButton);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Backing out of the prompt keeps the job.
      expect(p.project.rooms, isNotEmpty);
      expect(p.projectDirty, isTrue);
    });

    testWidgets('Discard closes it and loses only the list', (tester) async {
      final p = withProject();
      await pump(tester, p);

      await tester.tap(closeButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(p.project.rooms, isEmpty);
      // The room file is untouched either way — only the room list, the
      // vendors and the tags were ever at stake.
      expect(File('${dir.path}/bss101_config.json').existsSync(), isTrue);
      await letTheSnackBarGo(tester);
    });

    testWidgets('is dead when there is no job to put away', (tester) async {
      final p = AppStateProvider(autoLoadSettings: false);
      await pump(tester, p);

      expect(
        tester.widget<TextButton>(closeButton).onPressed,
        isNull,
        reason: 'Close on nothing must not clear a job somebody just started',
      );
    });
  });

  group('the job is FOR somebody', () {
    // Renamed from 'client': this shop's work is for the university, and
    // nobody on the other side of one of these quotes is buying anything.
    test('it round-trips under its own name', () {
      final project = BuildingProject(stakeholder: 'Facilities');
      expect(project.toJson()['stakeholder'], 'Facilities');
      expect(project.toJson().containsKey('client'), isFalse);
      expect(
        BuildingProject.fromJson(project.toJson()).stakeholder,
        'Facilities',
      );
    });

    test('a project file written before the rename still reads', () {
      // The old key is what is in every project file already saved, and one
      // of them is what somebody opens this afternoon.
      final old = BuildingProject.fromJson({
        'name': 'Bessey refresh',
        'client': 'Physics department',
      });
      expect(old.stakeholder, 'Physics department');
      // Written back under the new name, so the old key retires as each
      // project is saved rather than on a migration nobody asked for.
      expect(old.toJson()['stakeholder'], 'Physics department');
      expect(old.toJson().containsKey('client'), isFalse);
    });

    test('the new name wins when a file somehow carries both', () {
      final both = BuildingProject.fromJson({
        'client': 'the old answer',
        'stakeholder': 'the current one',
      });
      expect(both.stakeholder, 'the current one');
    });

    test('it counts toward a project having anything in it at all', () {
      // Otherwise Close would treat a job with a stakeholder typed on it as
      // an empty one and put it away without asking.
      expect(BuildingProject().isEmpty, isTrue);
      expect(BuildingProject(stakeholder: 'Facilities').isEmpty, isFalse);
    });

    test('a clone carries it', () {
      final project = BuildingProject(stakeholder: 'Facilities');
      expect(project.clone().stakeholder, 'Facilities');
    });
  });
}
