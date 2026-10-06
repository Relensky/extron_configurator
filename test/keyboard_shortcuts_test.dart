import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/floor_plan_view.dart';
import 'package:extron_configurator/keyboard_shortcuts.dart';
import 'package:extron_configurator/keyboard_shortcuts_settings.dart';
import 'package:extron_configurator/placed_devices.dart';

void main() {
  group('the shortcut list', () {
    test('every action has an id of its own and starts with keys', () {
      final ids = kShortcutActions.map((a) => a.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final a in kShortcutActions) {
        expect(a.defaults, isNotEmpty, reason: a.id);
      }
    });

    test('a changed key is kept, and going back to the default forgets it',
        () {
      const keys = KeyboardShortcuts();
      expect(keys.labelFor(Shortcut.redo), 'Ctrl+Y or Ctrl+Shift+Z');
      final changed = keys.withBindings(
        Shortcut.delete,
        const [KeyBinding(LogicalKeyboardKey.keyX, control: true)],
      );
      expect(changed.labelFor(Shortcut.delete), 'Ctrl+X');
      expect(changed.isChanged(Shortcut.delete), isTrue);

      final back = KeyboardShortcuts.fromJson(changed.toJson());
      expect(back.bindingsFor(Shortcut.delete), changed.bindingsFor(
        Shortcut.delete,
      ));
      expect(back.reset(Shortcut.delete).overrides, isEmpty);

      // Off entirely is allowed, and kept.
      final off = keys.withBindings(Shortcut.toggleCone, const []);
      expect(off.labelFor(Shortcut.toggleCone), 'none');
      expect(
        KeyboardShortcuts.fromJson(off.toJson()).bindingsFor(
          Shortcut.toggleCone,
        ),
        isEmpty,
      );
      // Junk in the settings file is ignored.
      expect(
        KeyboardShortcuts.fromJson({'nope': ['1:000'], 'sel.delete': 5})
            .overrides,
        isEmpty,
      );
    });

    test('a key on two actions is reported', () {
      const keys = KeyboardShortcuts();
      expect(
        keys.clashWith(Shortcut.toggleCone, const KeyBinding(
          LogicalKeyboardKey.delete,
        ))?.id,
        Shortcut.delete,
      );
      expect(
        keys.clashWith(Shortcut.toggleCone, const KeyBinding(
          LogicalKeyboardKey.keyQ,
        )),
        isNull,
      );
    });
  });

  group('on the floor plan', () {
    Future<(AppStateProvider, PlanDevice)> pumpWithCamera(
      WidgetTester tester,
    ) async {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      p.loadAvFlowForCurrentConfig();
      p.addFloorPlanSheet(name: 'Level 1');
      p.addAvCostExtraEquipment(description: 'PTZ Camera');
      final placed = p.addAvPlanDevice(
        p.activeFloorPlan!.id,
        const PlanDevice(
          id: '',
          deviceKey: 'ptz camera',
          label: 'PTZ Camera',
          shape: 'camera',
          pos: Offset(300, 300),
        ),
      )!;
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
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is Tooltip && (w.message ?? '').startsWith('PTZ Camera\n'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      return (p, placed);
    }

    PlanDevice device(AppStateProvider p) =>
        p.activeFloorPlan!.devices.single;

    testWidgets('arrows move, brackets turn, and the cone keys size it', (
      tester,
    ) async {
      final (p, placed) = await pumpWithCamera(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(device(p).pos.dx, greaterThan(placed.pos.dx));

      await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      await tester.pump();
      expect(device(p).rotation, 15);

      final fov = device(p).fov;
      await tester.sendKeyEvent(LogicalKeyboardKey.period);
      await tester.pump();
      expect(device(p).fov, fov + 5);
      expect(device(p).showFov, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.pump();
      expect(device(p).showFov, isFalse);

      // Five arrow presses are one undo step.
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      }
      await tester.pump();
      expect(device(p).pos.dy, greaterThan(placed.pos.dy));

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(p.activeFloorPlan!.devices, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a key changed in settings is the one that works', (
      tester,
    ) async {
      final (p, _) = await pumpWithCamera(tester);
      p.setShortcuts(p.shortcuts.withBindings(
        Shortcut.delete,
        const [KeyBinding(LogicalKeyboardKey.keyX)],
      ));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(p.activeFloorPlan!.devices, hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.pump();
      expect(p.activeFloorPlan!.devices, isEmpty);
    });
  });

  testWidgets('the settings section changes a shortcut by pressing it', (
    tester,
  ) async {
    final p = AppStateProvider(autoLoadSettings: false);
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: KeyboardShortcutsSettings()),
          ),
        ),
      ),
    );
    // Drawn as keycaps.
    expect(find.text('Backspace'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('shortcut_sel.delete')));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.text('Ctrl+D'), findsOneWidget);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();

    expect(p.shortcuts.labelFor(Shortcut.delete), 'Ctrl+D');
    expect(find.byKey(const ValueKey('shortcuts_reset_all')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shortcuts_reset_all')));
    await tester.pumpAndSettle();
    expect(p.shortcuts.overrides, isEmpty);
  });
}
