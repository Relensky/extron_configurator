import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/cabling_schematic.dart';
import 'package:extron_configurator/cabling_view.dart';
import 'package:extron_configurator/room_sidecar.dart';

/// The cabling drawing is EDITED, and the three things that were awkward about
/// editing it were: you could not delete anything with the keyboard, you could
/// not pick one line out of six that ran thirteen pixels apart, and a colour
/// belonged to a line rather than to a cable. This covers all three, plus the
/// end labels a sheet is read at the wall for and the redo that makes Delete
/// safe to press.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  Future<void> pumpTab(WidgetTester tester, AppStateProvider provider) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: CablingView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Clicks the pad at the middle of the only edge on the drawing.
  Future<void> selectTheRun(
    WidgetTester tester,
    AppStateProvider provider,
  ) async {
    final drawing = provider.cablingSchematic(buildAvFlowModel(provider));
    final origin = tester.getTopLeft(find.byType(InteractiveViewer));
    final from = drawing.boxes.first.rect.center;
    final to = drawing.boxes.last.rect.center;
    await tester.tapAt(origin + (from + to) / 2 - const Offset(0, 8));
    await tester.pumpAndSettle();
  }

  group('undo and redo', () {
    test('redo puts back what undo took away', () {
      final p = room();
      final box = p.addCablingBox(kind: CablingBoxKind.pullBox, label: 'PB1');
      expect(p.avCabling.extraBoxes, hasLength(1));

      expect(p.undoAvFlow(AvUndoScope.cabling), isNotEmpty);
      expect(p.avCabling.extraBoxes, isEmpty);
      expect(p.canRedoAvFlow(AvUndoScope.cabling), isTrue);

      expect(p.redoAvFlow(AvUndoScope.cabling), isNotEmpty);
      expect(p.avCabling.extraBoxes.single.id, box.id);
      // And the pair still works from the other side, which is what makes a
      // history rather than one step of ping-pong.
      expect(p.canUndoAvFlow(AvUndoScope.cabling), isTrue);
      expect(p.undoAvFlow(AvUndoScope.cabling), isNotEmpty);
      expect(p.avCabling.extraBoxes, isEmpty);
    });

    test('a new edit drops the forward history', () {
      // Standard, and the only honest option: once the document has moved a
      // different way, replaying a stored "forward" state would silently throw
      // away the edit just made.
      final p = room();
      p.addCablingBox(kind: CablingBoxKind.pullBox, label: 'PB1');
      p.undoAvFlow(AvUndoScope.cabling);
      expect(p.canRedoAvFlow(AvUndoScope.cabling), isTrue);

      p.addCablingBox(kind: CablingBoxKind.note, label: 'Scope');
      expect(p.canRedoAvFlow(AvUndoScope.cabling), isFalse);
    });

    test('another room does not inherit this one\'s history', () {
      final p = room();
      p.addCablingBox(kind: CablingBoxKind.pullBox);
      p.undoAvFlow(AvUndoScope.cabling);
      expect(p.canRedoAvFlow(AvUndoScope.cabling), isTrue);

      p.loadAvFlowForCurrentConfig();
      expect(p.canRedoAvFlow(AvUndoScope.cabling), isFalse);
      expect(p.canUndoAvFlow(AvUndoScope.cabling), isFalse);
    });
  });

  group('one colour per cable', () {
    /// Two runs of the same cable between the same two places, plus one of a
    /// different cable — the shape that makes a per-line colour useless.
    (AppStateProvider, List<String>) threeRuns() {
      final p = room();
      final a = p.addCablingBox(kind: CablingBoxKind.pullBox);
      final b = p.addCablingBox(kind: CablingBoxKind.pathway);
      final ids = [
        p.addCablingBundle(
          fromBoxId: a.id,
          toBoxId: b.id,
          cableType: 'Cat 6a',
        )!.id,
        p.addCablingBundle(
          fromBoxId: a.id,
          toBoxId: b.id,
          cableType: 'Cat 6a',
        )!.id,
        p.addCablingBundle(
          fromBoxId: a.id,
          toBoxId: b.id,
          cableType: 'Cat 5e',
        )!.id,
      ];
      return (p, ids);
    }

    CablingBundle drawn(AppStateProvider p, String id) => p
        .cablingSchematic(buildAvFlowModel(p))
        .bundles
        .firstWhere((b) => b.id == id);

    test('recolouring a cable moves every run of it, and only those', () {
      final (p, ids) = threeRuns();
      final other = drawn(p, ids[2]).color;

      p.setCablingTypeColor([cablingColorKey(drawn(p, ids[0]))], 0xFF00FF00);

      expect(drawn(p, ids[0]).color, 0xFF00FF00);
      expect(drawn(p, ids[1]).color, 0xFF00FF00);
      // The Cat 5e is a different cable and is not swept up in it.
      expect(drawn(p, ids[2]).color, other);
    });

    test('a run painted by hand still wins over its cable\'s colour', () {
      // The drawing set's own convention overriding the app's is the one thing
      // a colour rule must never take away.
      final (p, ids) = threeRuns();
      p.setCablingBundleColor(ids[0], 0xFF123456);
      p.setCablingTypeColor([cablingColorKey(drawn(p, ids[1]))], 0xFF00FF00);

      expect(drawn(p, ids[0]).color, 0xFF123456);
      expect(drawn(p, ids[1]).color, 0xFF00FF00);
    });

    test('clearing it hands the cable back to the key', () {
      final (p, ids) = threeRuns();
      final key = cablingColorKey(drawn(p, ids[0]));
      final was = drawn(p, ids[0]).color;

      p.setCablingTypeColor([key], 0xFF00FF00);
      expect(p.hasCablingTypeColor([key]), isTrue);

      p.setCablingTypeColor([key], null);
      expect(p.hasCablingTypeColor([key]), isFalse);
      expect(drawn(p, ids[0]).color, was);
    });

    test('the choice survives a trip through the room file', () {
      final (p, ids) = threeRuns();
      p.setCablingTypeColor([cablingColorKey(drawn(p, ids[0]))], 0xFF00FF00);

      final reopened = room().._readBack(p.avFlowAsJson());
      expect(
        reopened
            .cablingSchematic(buildAvFlowModel(reopened))
            .bundles
            .where((b) => b.cableType == 'Cat 6a')
            .map((b) => b.color)
            .toSet(),
        {0xFF00FF00},
      );
    });
  });

  group('what a run lands on', () {
    test('the two end labels are stored, printed and cleared', () {
      final p = room();
      final a = p.addCablingBox(kind: CablingBoxKind.pullBox);
      final b = p.addCablingBox(kind: CablingBoxKind.pathway);
      final run = p.addCablingBundle(fromBoxId: a.id, toBoxId: b.id)!;

      p.setCablingBundleEndLabel(
        run.id,
        fromLabel: 'Wall plate 2',
        toLabel: 'Patch panel A, 13-18',
      );

      CablingBundle drawn() => p
          .cablingSchematic(buildAvFlowModel(p))
          .bundles
          .firstWhere((x) => x.id == run.id);

      expect(drawn().fromLabel, 'Wall plate 2');
      expect(drawn().toLabel, 'Patch panel A, 13-18');

      // Blank clears it, and prints nothing — an end label is an addition
      // somebody makes to the runs that need one.
      p.setCablingBundleEndLabel(run.id, fromLabel: '   ');
      expect(drawn().fromLabel, '');
      expect(drawn().toLabel, 'Patch panel A, 13-18');
    });

    testWidgets('they are typed in the selection bar', (tester) async {
      final provider = room();
      final a = provider.addCablingBox(kind: CablingBoxKind.pullBox);
      final b = provider.addCablingBox(kind: CablingBoxKind.pathway);
      final run =
          provider.addCablingBundle(fromBoxId: a.id, toBoxId: b.id)!;
      await pumpTab(tester, provider);
      await selectTheRun(tester, provider);

      final field = find.byKey(ValueKey('cabling_from_label_${run.id}'));
      expect(field, findsOneWidget);
      await tester.enterText(field, 'Wall plate 2');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(provider.avCabling.fromLabels[run.id], 'Wall plate 2');
    });
  });

  group('the keyboard on the drawing', () {
    testWidgets('Delete takes the selected run off', (tester) async {
      final provider = room();
      final a = provider.addCablingBox(kind: CablingBoxKind.pullBox);
      final b = provider.addCablingBox(kind: CablingBoxKind.pathway);
      provider.addCablingBundle(fromBoxId: a.id, toBoxId: b.id)!;
      await pumpTab(tester, provider);
      await selectTheRun(tester, provider);

      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        provider.cablingSchematic(buildAvFlowModel(provider)).bundles,
        isEmpty,
      );
      // And it is undoable, which is what makes a Delete key acceptable at all.
      expect(provider.canUndoAvFlow(AvUndoScope.cabling), isTrue);
      provider.undoAvFlow(AvUndoScope.cabling);
      expect(
        provider.cablingSchematic(buildAvFlowModel(provider)).bundles,
        hasLength(1),
      );
    });

    testWidgets('the arrows step through the runs on one edge', (tester) async {
      // Six lines thirteen pixels apart is not something a mouse can pick the
      // fourth of.
      final provider = room();
      final a = provider.addCablingBox(kind: CablingBoxKind.pullBox);
      final b = provider.addCablingBox(kind: CablingBoxKind.pathway);
      final ids = [
        for (int i = 0; i < 3; i++)
          provider.addCablingBundle(
            fromBoxId: a.id,
            toBoxId: b.id,
            cableType: 'Cat ${6 + i}',
          )!.id,
      ];
      await pumpTab(tester, provider);
      await selectTheRun(tester, provider);

      /// Which run the selection bar says is selected.
      String selected() {
        for (final id in ids) {
          if (find.byKey(ValueKey('cabling_count_$id')).evaluate().isNotEmpty) {
            return id;
          }
        }
        return '';
      }

      final first = selected();
      expect(first, isNotEmpty, reason: 'the click has to select something');
      final order = provider
          .cablingSchematic(buildAvFlowModel(provider))
          .bundlesBetween(a.id, b.id)
          .map((x) => x.id)
          .toList();
      final at = order.indexOf(first);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(selected(), order[(at + 1) % order.length]);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(selected(), first);

      // Wraps, so the stack can be walked round without knowing which end of
      // it you are at.
      for (int i = 0; i < order.length; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      expect(selected(), first);
    });
  });
}

/// Reads a saved document's cabling section back into a fresh provider, the
/// way opening the room would — the overrides ARE the only part of this
/// drawing that goes to disk, so this is the whole round trip for it.
extension on AppStateProvider {
  void _readBack(Map<String, dynamic> doc) {
    final cabling = doc['cablingSchematic'];
    expect(cabling, isA<Map>(), reason: 'the drawing has to be written at all');
    avCabling.readJson(Map<String, dynamic>.from(cabling as Map));
  }
}
