import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_view.dart';

/// THE BUILDING'S OWN DRAWINGS.
///
/// The failures this guards are the ones that make an attached drawing worse
/// than an email: a plan set that does not survive a save and reload, a
/// project that quietly forgets which sheet was which, a row that opens onto
/// nothing because the file moved, and — the expensive one — a "remove" that
/// deletes somebody's drawing instead of the row pointing at it.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_plans_test'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// A file that exists — the contents are never read by anything under test.
  String writeFile(String name) {
    final file = path.join(dir.path, name);
    File(file).writeAsStringSync('not really a drawing');
    return file;
  }

  AppStateProvider withProject() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey refresh', building: 'BSS');
    p.currentProjectPath = path.join(dir.path, 'bessey_project.json');
    return p;
  }

  group('the model', () {
    test('a plan round-trips through the project file', () {
      final project = BuildingProject(name: 'Bessey');
      project.plans.add(ProjectPlan(
        id: project.nextPlanId(),
        filePath: 'plans/A-101.pdf',
        label: 'Level 1 floor plan',
        notes: 'issued 3 Feb',
      ));

      final back = BuildingProject.fromJson(
        jsonDecode(jsonEncode(project.toJson())) as Map<String, dynamic>,
      );

      expect(back.plans, hasLength(1));
      expect(back.plans.single.id, 'plan1');
      expect(back.plans.single.filePath, 'plans/A-101.pdf');
      expect(back.plans.single.label, 'Level 1 floor plan');
      expect(back.plans.single.notes, 'issued 3 Feb');
      // The counter comes back too, so the next sheet cannot be handed an id
      // that is already in use — two rows on one id is one row that cannot be
      // removed.
      expect(back.nextPlanId(), 'plan2');
    });

    test('the counter is rebuilt from the ids present, not just read', () {
      // A project file is a supported thing to hand edit — see its readme key.
      final back = BuildingProject.fromJson({
        'rooms': <dynamic>[],
        'plans': [
          {'id': 'plan7', 'filePath': 'A-101.pdf'},
        ],
      });
      expect(back.nextPlanId(), 'plan8');
    });

    test('a row with no file on it is dropped', () {
      final back = BuildingProject.fromJson({
        'rooms': <dynamic>[],
        'plans': [
          {'id': 'plan1', 'filePath': '  ', 'label': 'nothing'},
          {'id': 'plan2', 'filePath': 'A-101.pdf'},
        ],
      });
      expect(back.plans, hasLength(1));
      expect(back.plans.single.filePath, 'A-101.pdf');
    });

    test('a project with only plans on it is not empty', () {
      final project = BuildingProject();
      expect(project.isEmpty, isTrue);
      project.plans.add(const ProjectPlan(id: 'plan1', filePath: 'A.pdf'));
      expect(project.isEmpty, isFalse);
    });

    test('a clone carries the plans without sharing the list', () {
      final project = BuildingProject();
      project.plans
          .add(ProjectPlan(id: project.nextPlanId(), filePath: 'A.pdf'));
      final copy = project.clone();
      copy.plans.clear();
      expect(project.plans, hasLength(1), reason: 'the clone is its own list');
      expect(copy.nextPlanId(), 'plan2', reason: 'and its own counter');
    });

    test('the name and the viewer are decided off the file', () {
      const pdf = ProjectPlan(id: 'plan1', filePath: 'plans/A-101.pdf');
      expect(pdf.displayName, 'A-101.pdf', reason: 'no label: the file name');
      expect(pdf.isPdf, isTrue);
      expect(pdf.isViewable, isTrue);

      const labelled =
          ProjectPlan(id: 'plan2', filePath: 'A-102.PDF', label: 'Level 2 RCP');
      expect(labelled.displayName, 'Level 2 RCP');
      expect(labelled.isPdf, isTrue, reason: 'the extension is case blind');

      const image = ProjectPlan(id: 'plan3', filePath: 'scan.PNG');
      expect(image.isPdf, isFalse);
      expect(image.isViewable, isTrue);

      // A drawing the app cannot draw is still a drawing. It is listed and
      // handed to the machine's own opener rather than hidden.
      const cad = ProjectPlan(id: 'plan4', filePath: 'model.dwg');
      expect(cad.isViewable, isFalse);
    });
  });

  group('adding one to the job', () {
    test('a plan under the project folder is stored relative to it', () {
      final p = withProject();
      final file = writeFile('A-101.pdf');

      expect(p.addPlanToProject(file), '');
      expect(p.project.plans.single.filePath, 'A-101.pdf',
          reason: 'relative, so the job travels with its drawings');
      expect(p.resolveProjectPlanPath(p.project.plans.single),
          path.normalize(file));
      expect(p.projectPlanExists(p.project.plans.single), isTrue);
    });

    test('a file that is not there is refused, with the path in the message',
        () {
      final p = withProject();
      final missing = path.join(dir.path, 'nope.pdf');
      expect(p.addPlanToProject(missing), contains('nope.pdf'));
      expect(p.project.plans, isEmpty);
      expect(p.addPlanToProject(''), 'No file chosen.');
    });

    test('the same drawing twice is refused', () {
      final p = withProject();
      final file = writeFile('A-101.pdf');
      expect(p.addPlanToProject(file), '');
      // Two rows onto one drawing is two places to write the note about it,
      // and the second one is the one nobody reads.
      expect(p.addPlanToProject(file), contains('already on this project'));
      expect(p.project.plans, hasLength(1));
    });

    test('adding one is on the job history', () {
      final p = withProject();
      p.addPlanToProject(writeFile('A-101.pdf'));
      expect(
        p.project.history.map((h) => '${h.field} ${h.summary}'),
        contains('Plan added to the job'),
      );
    });
  });

  group('living with them', () {
    test('a label and a note are kept', () {
      final p = withProject();
      p.addPlanToProject(writeFile('A-101.pdf'));
      final id = p.project.plans.single.id;

      p.updateProjectPlan(id, label: 'Level 1', notes: 'supersedes December');

      expect(p.project.plans.single.label, 'Level 1');
      expect(p.project.plans.single.notes, 'supersedes December');
      expect(p.project.plans.single.displayName, 'Level 1');
    });

    test('the order is the order the set reads in', () {
      final p = withProject();
      p.addPlanToProject(writeFile('A-101.pdf'));
      p.addPlanToProject(writeFile('A-102.pdf'));
      expect(p.project.plans.map((e) => e.displayName),
          ['A-101.pdf', 'A-102.pdf']);

      p.moveProjectPlan(p.project.plans.last.id, -1);
      expect(p.project.plans.map((e) => e.displayName),
          ['A-102.pdf', 'A-101.pdf']);

      // Off either end does nothing rather than throwing.
      p.moveProjectPlan(p.project.plans.first.id, -1);
      expect(p.project.plans.map((e) => e.displayName),
          ['A-102.pdf', 'A-101.pdf']);
    });

    test('REMOVING A ROW DOES NOT DELETE THE DRAWING', () {
      final p = withProject();
      final file = writeFile('A-101.pdf');
      p.addPlanToProject(file);

      p.removePlanFromProject(p.project.plans.single.id);

      expect(p.project.plans, isEmpty);
      expect(File(file).existsSync(), isTrue,
          reason: 'this list points at drawings; it does not own them');
    });

    test('a drawing that has moved is reported missing, not lost', () {
      final p = withProject();
      final file = writeFile('A-101.pdf');
      p.addPlanToProject(file);
      File(file).deleteSync();

      final plan = p.project.plans.single;
      expect(p.projectPlanExists(plan), isFalse);
      // Still listed, still named: the row is how somebody finds out WHICH
      // sheet went missing.
      expect(plan.displayName, 'A-101.pdf');
    });
  });

  group('the pane', () {
    Future<void> pump(WidgetTester tester, AppStateProvider p) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: p,
          child: const MaterialApp(home: Scaffold(body: ProjectView())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project_pane_plans')));
      await tester.pumpAndSettle();
    }

    testWidgets('an empty job says what the pane is for', (tester) async {
      await pump(tester, withProject());

      expect(find.byKey(const ValueKey('add_plans')), findsOneWidget);
      expect(find.textContaining('No building plans on this project yet'),
          findsOneWidget);
    });

    testWidgets('a plan is listed, and can be viewed', (tester) async {
      final p = withProject();
      p.addPlanToProject(writeFile('A-101.pdf'));
      p.updateProjectPlan(p.project.plans.single.id, label: 'Level 1 plan');
      await pump(tester, p);

      final id = p.project.plans.single.id;
      // Twice: the row's own title, and the label field it was typed into.
      expect(find.text('Level 1 plan'), findsWidgets);
      expect(find.text('A-101.pdf'), findsWidgets);
      expect(
        tester
            .widget<FilledButton>(find.byKey(ValueKey('plan_view_$id')))
            .onPressed,
        isNotNull,
        reason: 'the drawing is there, so it can be opened',
      );
      expect(find.text('View'), findsOneWidget);
    });

    testWidgets('a drawing the app cannot draw says Open, not View',
        (tester) async {
      final p = withProject();
      p.addPlanToProject(writeFile('riser.dwg'));
      await pump(tester, p);

      expect(find.text('Open'), findsOneWidget);
      expect(find.text('View'), findsNothing);
    });

    testWidgets('a missing drawing is flagged and cannot be opened',
        (tester) async {
      final p = withProject();
      final file = writeFile('A-101.pdf');
      p.addPlanToProject(file);
      File(file).deleteSync();
      await pump(tester, p);

      final id = p.project.plans.single.id;
      expect(find.textContaining('Missing'), findsWidgets);
      expect(
        tester
            .widget<FilledButton>(find.byKey(ValueKey('plan_view_$id')))
            .onPressed,
        isNull,
        reason: 'opening it would only say what the row already says',
      );
    });

    testWidgets('removing a row takes it off the list and leaves the file',
        (tester) async {
      final p = withProject();
      final file = writeFile('A-101.pdf');
      p.addPlanToProject(file);
      await pump(tester, p);

      await tester.tap(
          find.byKey(ValueKey('plan_remove_${p.project.plans.single.id}')));
      await tester.pumpAndSettle();

      expect(p.project.plans, isEmpty);
      expect(File(file).existsSync(), isTrue);
    });
  });
}
