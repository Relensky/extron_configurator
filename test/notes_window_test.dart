import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/notes_window.dart';

/// The floating notes: whose notes they write to, the panel, and the link to
/// the popped-out window.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Room 1'},
      };
    p.loadAvFlowForCurrentConfig();
    p.selectedTabIndex = AppTab.cost.index;
    return p;
  }

  group('whose notes', () {
    test('the open room on its pages, the job on the Project tab', () {
      final p = room();
      expect(notesTargetOf(p)!.kind, NotesTargetKind.room);
      writeNotes(p, notesTargetOf(p)!, 'Paint the mounts white');
      expect(p.avCost.notes, 'Paint the mounts white');

      p.newProject(name: 'Refresh');
      p.selectedTabIndex = AppTab.project.index;
      final job = notesTargetOf(p)!;
      expect(job.kind, NotesTargetKind.project);
      writeNotes(p, job, 'Steph confirmed');
      expect(p.project.notes, 'Steph confirmed');
      expect(p.avCost.notes, 'Paint the mounts white', reason: 'left alone');
    });

    test('nothing open, nothing to write to', () {
      final p = AppStateProvider(autoLoadSettings: false);
      expect(notesTargetOf(p), isNull);
    });
  });

  testWidgets('the panel writes into the room notes as it is typed in',
      (tester) async {
    final p = room();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => NotesPanel.toggle(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notes_panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('notes_pop_out')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('notes_text')),
      'Hardware is black',
    );
    await tester.pump();
    expect(p.avCost.notes, 'Hardware is black');

    NotesPanel.close();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('notes_panel')), findsNothing);
  });

  testWidgets('the popped-out window and the app keep each other in step',
      (tester) async {
    final p = room();
    p.setAvCostNotes('First note');
    NotesClient? window;
    NotesHost.launchForTest = (args) async {
      window = NotesClient(NotesHost.instance.portForTest!);
      await window!.connect();
    };
    addTearDown(() async {
      NotesHost.launchForTest = null;
      window?.close();
      await NotesHost.instance.resetForTest();
    });

    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
    }

    await tester.runAsync(() => NotesHost.instance.popOut(p));
    await settle(() => window != null && window!.text == 'First note');
    expect(window!.text, 'First note');
    expect(window!.title, startsWith('Room notes'));

    // Typed in the window: into the room.
    window!.setText('Typed in the window');
    await settle(() => p.avCost.notes == 'Typed in the window');
    expect(p.avCost.notes, 'Typed in the window');

    // Changed in the app: out to the window.
    p.setAvCostNotes('Changed in the app');
    await settle(() => window!.text == 'Changed in the app');
    expect(window!.text, 'Changed in the app');
  });
}
