import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_history_view.dart';

/// The People tab counts everybody's changes - the job's and the rooms' -
/// and pressing a name shows their changes.
void main() {
  ProjectEdit edit(String user, String name, String summary, int minute) =>
      ProjectEdit(
        itemKey: 'k$minute',
        itemName: 'Arts 111',
        field: 'Price',
        summary: summary,
        user: user,
        name: name,
        at: DateTime(2026, 10, 15, 9, minute),
      );

  testWidgets('somebody who only worked in a room is there, and opens to '
      'their changes', (tester) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = AppStateProvider(autoLoadSettings: false)
      ..newProject(name: '600k refresh')
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Arts 111'},
      };
    provider.loadAvFlowForCurrentConfig();
    provider.project.history.add(
        edit('dstanley', 'Derek Stanley', 'Deadline set', 1));
    // Only in the room's log - which the People tab never read.
    provider.roomHistory.add(
        edit('ngeiger', 'Nicole Geiger', 'Projector price changed', 2));

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showHistoryDialog(context),
                  child: const Text('history'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('history'));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }

    await tester.tap(find.byKey(const ValueKey('history_tab_people')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('history_person_ngeiger')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('history_person_dstanley')),
        findsOneWidget);
    expect(find.text('Nicole Geiger (ngeiger)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('history_person_ngeiger')));
    await tester.pumpAndSettle();
    // Back on Changes, hers only.
    expect(
      find.textContaining('Projector price changed', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('Deadline set', findRichText: true),
        findsNothing);
  });
}
