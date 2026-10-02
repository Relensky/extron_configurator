import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_snack.dart';
import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/collab/collab_controller.dart';
import 'package:extron_configurator/collab/collab_widgets.dart';
import 'package:extron_configurator/collab/presence.dart';
import 'package:extron_configurator/project_budget.dart';
import 'package:extron_configurator/project_room_picker.dart';

/// The Combine button on the bar, pressed for real; and the two small rules
/// beside it - where a picked room lands, and what a room save offers.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('combine_button_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<AppStateProvider> jobSavedByAColleague(WidgetTester tester) async {
    final p = AppStateProvider(
      autoLoadSettings: false,
      collabIdentity: const CollabIdentity(user: 'me', machine: 'MY-PC'),
    )..collab.enabled = true;
    final file = path.join(dir.path, 'Job_project.json');
    await tester.runAsync(() async {
      p.newProject(name: 'Job');
      await p.saveProject(to: file);
      await p.collab.tick();

      // Mine, unsaved.
      p.addBudgetLine(BudgetLine.create(item: 'Mine', amount: 10));

      // Theirs, saved from another machine.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final theirs = jsonDecode(File(file).readAsStringSync()) as Map;
      theirs['budgetLines'] = [
        BudgetLine.create(item: 'Theirs', amount: 20).toJson(),
      ];
      File(file).writeAsStringSync(jsonEncode(theirs));
      await p.collab.tick();
    });
    expect(p.collab.incomingOn(CollabDocKind.project), isNotNull);
    return p;
  }

  Future<void> pumpStrip(
    WidgetTester tester,
    AppStateProvider p,
    AppTab tab,
  ) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(body: Center(child: CollabPresenceStrip(tab: tab))),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('pressing Combine brings a colleague\'s save in, keeping mine',
      (tester) async {
    final p = await jobSavedByAColleague(tester);
    await pumpStrip(tester, p, AppTab.project);

    expect(
      find.byKey(const ValueKey('collab_incoming_badge_project')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('collab_incoming_project')));
    // The busy chip appears in front of the one pressed; the merge still runs.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    expect(
      p.project.budgetLines.map((l) => l.item).toSet(),
      {'Mine', 'Theirs'},
    );
    expect(p.collab.incomingOn(CollabDocKind.project), isNull);
    expect(find.byKey(const ValueKey('collab_incoming_project')), findsNothing);
    expect(find.textContaining('Combined with the saved project'),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    p.dispose();
  });

  testWidgets('a save to the project is flagged on a room tab too',
      (tester) async {
    final p = await jobSavedByAColleague(tester);
    await pumpStrip(tester, p, AppTab.deviceEditor);
    expect(
      find.byKey(const ValueKey('collab_incoming_badge_project')),
      findsOneWidget,
    );
    p.dispose();
  });

  test('a room picked on the Project tab opens on Cost; other tabs stay', () {
    final p = AppStateProvider(autoLoadSettings: false);
    p.selectTab(AppTab.project.index);
    showPickedRoom(p);
    expect(p.selectedTabIndex, AppTab.cost.index);

    p.selectTab(AppTab.racks.index);
    showPickedRoom(p);
    expect(p.selectedTabIndex, AppTab.racks.index);
    p.dispose();
  });

  testWidgets('a room save does not offer to open the room', (tester) async {
    final p = AppStateProvider(autoLoadSettings: false);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSavedFileSnack(
                  context,
                  p,
                  'Room',
                  path.join(dir.path, 'bss103_config.json'),
                  offerOpenFile: false,
                ),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('saved_open_folder')), findsOneWidget);
    expect(find.byKey(const ValueKey('saved_open_file')), findsNothing);
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    p.dispose();
  });
}
