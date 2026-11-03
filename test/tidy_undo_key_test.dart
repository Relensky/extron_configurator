import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/main.dart';

/// Ctrl+Z right after Tidy layout. A toolbar button does not take the
/// keyboard focus, so the key used to go nowhere: the Undo button worked
/// and the key did not.
void main() {
  testWidgets('Ctrl+Z and Ctrl+Y after Tidy layout on the AV Flow', (
    tester,
  ) async {
    final library = await tester.runAsync(
      () => AvDeviceLibrary.load(explicitPath: 'av_devices.json'),
    );
    final p = AppStateProvider(autoLoadSettings: false)
      ..avDeviceLibrary = library!
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    AvNode box(String id, Offset pos) =>
        AvNode(id: id, label: id, model: '', pos: pos, ports: const []);
    p.addAvNode(box('AVSOURCE_INPUT_2', const Offset(900, 900)),
        recordUndo: false);
    p.addAvNode(box('AVSOURCE_INPUT_1', const Offset(905, 100)),
        recordUndo: false);
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    p.settingsLoaded = true;
    p.firstRunSetupNeeded = false;
    p.selectTab(AppTab.avFlow.index);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pumpAndSettle();

    /// Takes down the message a step shows before the next: the tidy's
    /// plain bar and the undo's timed one trip each other's asserts in a
    /// test's fake time.
    Future<void> settle() async {
      await tester.pump();
      for (final m in tester.stateList<ScaffoldMessengerState>(
        find.byType(ScaffoldMessenger),
      )) {
        m.removeCurrentSnackBar();
      }
      await tester.pumpAndSettle(const Duration(seconds: 6));
    }

    Offset at() => p.avNodeById('AVSOURCE_INPUT_1')!.pos;
    final before = at();
    await tester.tap(find.byKey(const ValueKey('av_tidy_layout')));
    await settle();
    final tidied = at();
    expect(tidied, isNot(before));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle();
    expect(at(), before);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle();
    expect(at(), tidied);
    expect(tester.takeException(), isNull);
  });
}
