import 'dart:io';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/project_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

/// A drawn room's row on a phone: the name keeps a readable width, with the
/// buttons on their own line under it rather than squeezing it to a letter a
/// line.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('room_row_'));
  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('a room name stays readable on a phone-width page',
      (tester) async {
    final p = AppStateProvider(autoLoadSettings: false);
    p.newProject(name: 'Arts');
    final file = '${dir.path}/arts111_config.json';
    File(file).writeAsStringSync(
      '{"SYSTEM_SETUP":{"gve_bldg":"ARTS","gve_room":"111",'
      '"gui_full_room_name":"Arts and Humanities 111"}}',
    );
    p.addRoomToProject(file);
    p.setProjectRoomsByPriority(false);

    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: ProjectView())),
      ),
    );
    await tester.pumpAndSettle();

    final name = find.textContaining('111');
    expect(name, findsWidgets);
    await tester.ensureVisible(name.first);
    await tester.pumpAndSettle();
    // Not one letter a line: the name sits on a line or two at most.
    for (final e in name.evaluate()) {
      final size = tester.getSize(find.byWidget(e.widget).first);
      expect(size.height, lessThan(60),
          reason: 'a name stacked a letter a line is hundreds tall');
    }
    expect(tester.takeException(), isNull);
  });
}
