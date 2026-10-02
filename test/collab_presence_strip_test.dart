import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/collab/collab_controller.dart';
import 'package:extron_configurator/collab/collab_widgets.dart';
import 'package:extron_configurator/collab/presence.dart';

/// Who else is editing, on the top bar: a few chips, the rest in a list, and
/// where each of them is.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('presence_strip_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('five editors: three chips and the rest in a list, with where',
      (tester) async {
    final p = AppStateProvider(
      autoLoadSettings: false,
      collabIdentity: const CollabIdentity(user: 'me', machine: 'MY-PC'),
    )..collab.enabled = true;
    final file = path.join(dir.path, 'Job_project.json');
    await tester.runAsync(() async {
      p.newProject(name: 'Job');
      await p.saveProject(to: file);
      final now = DateTime.now();
      for (final (i, user) in ['ann', 'ben', 'cat', 'dee', 'eve'].indexed) {
        await PresenceBoard(file).announce(EditorPresence(
          user: user,
          machine: '$user-PC',
          since: now,
          heartbeat: now,
          unsaved: true,
          room: 'BSS 10$i',
          tab: 'Cost',
        ));
      }
      await p.collab.tick();
    });
    expect(p.collab.othersOn(CollabDocKind.project), hasLength(5));

    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(child: CollabPresenceStrip(tab: AppTab.project)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CollabEditorAvatar), findsNWidgets(kCollabChipsShown));
    // The room each is in, on the chip.
    expect(find.text('ann · BSS 100'), findsOneWidget);
    expect(find.text('+2'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('collab_more_editors')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('collab_more_dee')), findsOneWidget);
    expect(find.byKey(const ValueKey('collab_more_eve')), findsOneWidget);
    expect(find.textContaining('BSS 104, on Cost'), findsOneWidget);
    p.dispose();
  });

  test('this copy says which room and tab it is on', () async {
    final p = AppStateProvider(
      autoLoadSettings: false,
      collabIdentity: const CollabIdentity(user: 'me', machine: 'MY-PC'),
    )..collab.enabled = true;
    final config = path.join(dir.path, 'BSS_103', 'config.json');
    Directory(path.dirname(config)).createSync(recursive: true);
    File(config).writeAsStringSync(jsonEncode({
      'SYSTEM_SETUP': {'gve_bldg': 'BSS', 'gve_room': '103'},
    }));
    await p.openConfigAtPath(config);
    p.selectTab(AppTab.cost.index);
    await p.collab.tick();

    final mine = File(PresenceBoard(config).fileFor(p.collab.me));
    final note = EditorPresence.fromJson(jsonDecode(mine.readAsStringSync()))!;
    expect(note.room, 'BSS 103');
    expect(note.tab, isNotEmpty);
    p.dispose();
  });
}
