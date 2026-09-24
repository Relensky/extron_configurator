import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/collab/collab_controller.dart';
import 'package:extron_configurator/project_budget.dart';
import 'package:extron_configurator/spec_sheets.dart';

/// ============================================================================
///  EDITING TOGETHER, THROUGH THE REAL DOCUMENTS
/// ============================================================================
///  A room and a job opened the ordinary way, a colleague's save landing on
///  disk underneath, and the merge bringing it in without losing what was
///  typed here. Plus the budget and the spec sheet folder.
/// ============================================================================
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('collab_state_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> later() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('a colleague\'s save to the room is merged with unsaved edits here',
      () async {
    final file = path.join(dir.path, 'bss103_config.json');
    File(file).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103', 'notes': 'a'},
    }));
    final p = AppStateProvider(autoLoadSettings: false);
    p.collab.enabled = true;
    await p.openConfigAtPath(file);
    await p.collab.tick();

    // Mine: a field typed here and not saved.
    p.updateDeviceValue('SYSTEM_SETUP', 'gve_room', '104');
    expect(p.roomHasUnsavedChanges, isTrue);

    // Theirs: a different field, saved from another machine.
    await later();
    final disk = jsonDecode(File(file).readAsStringSync()) as Map;
    (disk['SYSTEM_SETUP'] as Map)['notes'] = 'from jsmith';
    File(file).writeAsStringSync(jsonEncode(disk));

    await p.collab.tick();
    expect(p.collab.incomingOn(CollabDocKind.room), isNotNull);

    final outcome = await p.collab.mergeIncoming(CollabDocKind.room);
    expect(outcome.conflicts, isEmpty);
    final merged = p.roomConfig['SYSTEM_SETUP'] as Map;
    expect(merged['gve_room'], '104', reason: 'my edit is kept');
    expect(merged['notes'], 'from jsmith', reason: 'their edit comes in');
    expect(p.roomHasUnsavedChanges, isTrue);
    p.dispose();
  });

  test('a colleague\'s budget lines are merged into the job', () async {
    final p = AppStateProvider(autoLoadSettings: false);
    p.collab.enabled = true;
    p.newProject(name: 'Bessey Hall');
    final file = path.join(dir.path, 'bessey_project.json');
    await p.saveProject(to: file);
    await p.collab.tick();

    p.setProjectBudget(100000);
    p.addBudgetLine(BudgetLine.create(item: 'Mine', amount: 10));

    // Another copy of the job, saved with a line of its own.
    await later();
    final theirs = jsonDecode(File(file).readAsStringSync()) as Map;
    theirs['budgetLines'] = [
      BudgetLine.create(item: 'Theirs', amount: 20).toJson(),
    ];
    File(file).writeAsStringSync(jsonEncode(theirs));

    await p.collab.tick();
    expect(p.collab.incomingOn(CollabDocKind.project), isNotNull);
    await p.collab.mergeIncoming(CollabDocKind.project);

    expect(p.project.budget, 100000);
    expect(
      p.project.budgetLines.map((l) => l.item).toSet(),
      {'Mine', 'Theirs'},
    );
    expect(p.projectDirty, isTrue);
    p.dispose();
  });

  group('budget', () {
    test('survives a save and a reopen', () async {
      final p = AppStateProvider(autoLoadSettings: false);
      p.newProject(name: 'Job');
      p.setProjectBudget(5000);
      final id = p.addBudgetLine(BudgetLine.create(item: 'Projector'));
      p.updateBudgetLine(p.project.budgetLines
          .firstWhere((l) => l.id == id)
          .copyWith(amount: 1200, status: BudgetStatus.committed));
      final file = path.join(dir.path, 'job_project.json');
      expect(await p.saveProject(to: file), '');

      final q = AppStateProvider(autoLoadSettings: false);
      expect(await q.openProject(file), '');
      expect(q.project.budget, 5000);
      expect(q.project.budgetLines.single.item, 'Projector');
      expect(q.project.budgetLines.single.status, BudgetStatus.committed);
      p.dispose();
      q.dispose();
    });

    test('remaining is the budget less committed and spent', () {
      final s = BudgetSummary.of(1000, [
        BudgetLine.create(amount: 100, status: BudgetStatus.planned),
        BudgetLine.create(amount: 200, status: BudgetStatus.committed),
        BudgetLine.create(amount: 300, status: BudgetStatus.spent),
      ], estimate: 1200);
      expect(s.used, 500);
      expect(s.remaining, 500);
      expect(s.forecastRemaining, 400);
      expect(s.estimateHeadroom, -200);
    });

    test('two copies never issue the same line id', () {
      final ids = {for (var i = 0; i < 200; i++) newBudgetLineId()};
      expect(ids, hasLength(200));
    });
  });

  group('spec sheets', () {
    test('attaching copies into the shared folder, stored relative', () async {
      final folder = path.join(dir.path, 'share', 'spec_sheets');
      final source = path.join(dir.path, 'download.pdf');
      File(source).writeAsStringSync('%PDF-1.4 fake');
      const entry = AvDeviceTemplate(
        model: 'DTP CrossPoint 84',
        manufacturer: 'Extron',
        ports: [],
      );
      final ref = await attachSpecSheet(
        entry: entry,
        source: source,
        folder: folder,
      );
      expect(ref, 'Extron/DTP_CrossPoint_84.pdf');
      expect(
        File(path.join(folder, 'Extron', 'DTP_CrossPoint_84.pdf')).existsSync(),
        isTrue,
      );
      final withSheet = entry.copyWith(specSheet: ref);
      expect(
        resolveSpecSheet(withSheet, folder),
        path.join(folder, 'Extron/DTP_CrossPoint_84.pdf'),
      );
      // ...and it survives the catalog's own JSON.
      expect(
        AvDeviceTemplate.fromJson(withSheet.toJson()).specSheet,
        ref,
      );
    });

    test('a sheet named for the model is found without being attached', () {
      final folder = path.join(dir.path, 'sheets');
      Directory(path.join(folder, 'Extron')).createSync(recursive: true);
      File(path.join(folder, 'Extron', 'DMP_64.pdf')).writeAsStringSync('x');
      const entry = AvDeviceTemplate(
        model: 'DMP 64',
        manufacturer: 'Extron',
        ports: [],
      );
      expect(
        resolveSpecSheet(entry, folder),
        path.join(folder, 'Extron', 'DMP_64.pdf'),
      );
      expect(countSpecSheets([entry], folder), 1);
    });

    test('a web address is kept as it is', () {
      const entry = AvDeviceTemplate(
        model: 'X',
        specSheet: 'https://example.com/x.pdf',
        ports: [],
      );
      expect(resolveSpecSheet(entry, '/nowhere'), 'https://example.com/x.pdf');
    });
  });
}
