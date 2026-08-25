import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/project_view.dart';
import 'package:extron_configurator/responsibility_matrix.dart';

/// Editing and issuing the roles and responsibilities matrix.
///
/// The failure this guards is a matrix that goes out with blanks on it: a line
/// nobody has claimed reads exactly like a line somebody has, and the day that
/// is discovered is the day the trades are on site.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('responsibility_view_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppStateProvider withProject() {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Bessey Hall');
    for (final stem in ['bss101', 'bss103']) {
      final file = '${dir.path}/${stem}_config.json';
      File(file).writeAsStringSync('{"SYSTEM_SETUP":{}}');
      p.addRoomToProject(file);
    }
    return p;
  }

  Future<void> pumpPane(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: ProjectView())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('project_pane_responsibility')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an empty matrix says what it is for', (tester) async {
    await pumpPane(tester, withProject());
    expect(find.textContaining('Nothing agreed yet'), findsOneWidget);
  });

  testWidgets('the usual lines go on in one press', (tester) async {
    final p = withProject();
    await pumpPane(tester, p);

    await tester.tap(find.byKey(const ValueKey('responsibility_starters')));
    await tester.pumpAndSettle();

    expect(
      p.project.responsibility,
      hasLength(kStarterResponsibilityItems.length),
    );
    expect(find.text('Ceiling speakers'), findsOneWidget);

    // The snack bar that says what happened keeps its timer outside the widget
    // tree (see showTimedSnackBar), so it has to be allowed to expire before
    // the tree goes away.
    await tester.pumpAndSettle(const Duration(seconds: 8));
  });

  testWidgets('a line is edited in one dialog and lands on the job', (
    tester,
  ) async {
    final p = withProject();
    final rooms = p.project.rooms.map((r) => r.id).toList();
    p.addResponsibilityItem();
    await pumpPane(tester, p);

    await tester.tap(find.byKey(const ValueKey('responsibility_edit_resp1')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('responsibility_scope')),
      'Ceiling speakers',
    );
    await tester.enterText(
      find.byKey(const ValueKey('responsibility_furnished')),
      'Owner',
    );
    await tester.enterText(
      find.byKey(const ValueKey('responsibility_installed')),
      'Contractor',
    );
    await tester.enterText(
      find.byKey(ValueKey('responsibility_qty_${rooms.first}')),
      '12',
    );
    await tester.enterText(
      find.byKey(const ValueKey('responsibility_work')),
      'Install with slack wire and a cross tee.',
    );
    await tester.tap(find.byKey(const ValueKey('responsibility_save')));
    await tester.pumpAndSettle();

    final item = p.project.responsibility.single;
    expect(item.scope, 'Ceiling speakers');
    expect(item.furnishedBy, 'Owner');
    expect(item.installedBy, 'Contractor');
    expect(item.qtyByRoom[rooms.first], 12);
    expect(item.total, 12);
    expect(item.work, contains('cross tee'));
    expect(item.unassigned, isFalse);
  });

  testWidgets('backing out of the editor changes nothing', (tester) async {
    final p = withProject();
    p.addResponsibilityItem('Screens');
    await pumpPane(tester, p);

    await tester.tap(find.byKey(const ValueKey('responsibility_edit_resp1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('responsibility_scope')),
      'Something else',
    );
    await tester.tap(find.byKey(const ValueKey('responsibility_cancel')));
    await tester.pumpAndSettle();

    expect(p.project.responsibility.single.scope, 'Screens');
  });

  testWidgets('a line with nobody named is called out on the pane', (
    tester,
  ) async {
    final p = withProject();
    p.addResponsibilityItem('Screens');
    await pumpPane(tester, p);

    expect(find.textContaining('with nobody named'), findsOneWidget);
    expect(find.textContaining('NOBODY YET'), findsOneWidget);
  });

  testWidgets('a line can be taken off the matrix', (tester) async {
    final p = withProject();
    p.addResponsibilityItem('Screens');
    await pumpPane(tester, p);

    await tester.tap(find.byKey(const ValueKey('responsibility_delete_resp1')));
    await tester.pumpAndSettle();
    expect(p.project.responsibility, isEmpty);
  });

  testWidgets('the picture preview draws the matrix as the document', (
    tester,
  ) async {
    final p = withProject();
    final rooms = p.project.rooms.map((r) => r.id).toList();
    p.addResponsibilityItem('Ceiling speakers', (
      furnishedBy: 'Owner',
      installedBy: 'Contractor',
      work: '',
    ));
    p.updateResponsibilityItem(
      p.project.responsibility.single.withRoomQty(rooms.first, 12),
    );
    await pumpPane(tester, p);

    await tester.tap(
      find.byKey(const ValueKey('responsibility_export_image')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('responsibility_image_dialog')),
      findsOneWidget,
    );
    // The document, not the editor: what is INSIDE the preview is the sheet,
    // totals row and all, with none of the pane's per-row buttons on it. The
    // pane itself is still mounted underneath the dialog, so the check has to
    // be scoped to the preview rather than to the whole tree.
    final preview = find.byKey(const ValueKey('responsibility_image_dialog'));
    expect(
      find.descendant(of: preview, matching: find.text('Totals')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: preview, matching: find.text('Ceiling speakers')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: preview, matching: find.text('12')),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: preview,
        matching: find.byIcon(Icons.delete_outline),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('responsibility_save_png')),
      findsOneWidget,
    );
  });
}
