import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/team/team_clipboard_image.dart';

/// Ctrl+V on the floor plan: the picture on the clipboard becomes the
/// sheet's drawing, as if it had been imported.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('plan_paste_'));
  tearDown(() {
    FloorPlanView.clipboardHasPicture = () => ClipboardImage.hasPicture;
    FloorPlanView.readClipboard = ClipboardImage.read;
    tmp.deleteSync(recursive: true);
  });

  Future<List<int>> png(int w, int h) async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xFF336699),
    );
    final image = await recorder.endRecording().toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  testWidgets('Ctrl+V pastes a drawing, and asks before replacing one', (
    tester,
  ) async {
    final config = path.join(tmp.path, 'TEST101', 'config.json');
    File(config).createSync(recursive: true);
    final p = AppStateProvider(autoLoadSettings: false)
      ..currentConfigPath = config
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();

    var size = (400, 300);
    FloorPlanView.clipboardHasPicture = () => true;
    FloorPlanView.readClipboard = () async {
      final bytes = await png(size.$1, size.$2);
      return [
        ClipboardPicture(
          Uint8List.fromList(bytes), 'png', size.$1, size.$2),
      ];
    };

    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: FloorPlanView())),
      ),
    );
    await tester.pumpAndSettle();
    expect(p.activeFloorPlan, isNull);

    Future<void> ctrlV() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }

    /// Lets the file work and image decoding run on real time.
    Future<void> work(bool Function() done) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
    }

    // No sheet yet: one is made with the picture on it.
    await ctrlV();
    await work(() => p.activeFloorPlan != null);
    final plan = p.activeFloorPlan!;
    expect(plan.imageSize, const Size(400, 300));
    // Copied into the room's folder, like an import.
    expect(path.isAbsolute(plan.imageFile), isFalse);
    expect(plan.imageFile, contains('floorplan'));

    // A drawing already there: asked first. Cancel leaves it.
    size = (640, 480);
    await ctrlV();
    await work(() => find
        .byKey(const ValueKey('plan_paste_confirm'))
        .evaluate()
        .isNotEmpty);
    expect(find.byKey(const ValueKey('plan_paste_confirm')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(p.activeFloorPlan!.imageSize, const Size(400, 300));

    // Replace takes it, and the Paste image button does the same as the key.
    await tester.tap(find.byKey(const ValueKey('plan_paste_image')));
    await work(() => find
        .byKey(const ValueKey('plan_paste_confirm'))
        .evaluate()
        .isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('plan_paste_replace')));
    await work(() => p.activeFloorPlan!.imageSize == const Size(640, 480));
    expect(p.activeFloorPlan!.imageSize, const Size(640, 480));
    expect(p.activeFloorPlan!.imageFile, isNot(plan.imageFile));

    // No picture on the clipboard: the key is left for anything else.
    FloorPlanView.clipboardHasPicture = () => false;
    await ctrlV();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan_paste_confirm')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
