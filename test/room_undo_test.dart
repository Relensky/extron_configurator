import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';

/// ONE UNDO FOR THE WHOLE ROOM.
///
/// A room used to answer "what does Undo do" six different ways: a pair on
/// each of the four drawing tabs, a fifth on the estimate, a sixth on the
/// control schematic, and a seventh in the title bar for the config. Every one
/// of them worked over its own slice, and between them they meant that taking
/// back the last thing you did required first remembering which tab you had
/// done it on — which is the one thing somebody reaching for Undo has lost
/// track of.
///
/// The histories underneath are unchanged, because they are three different
/// mechanisms for three good reasons and each names its own steps better than
/// a document-wide diff could. What is new is the ORDER: one press takes back
/// the newest edit in the room whichever of the three it is waiting in.
///
/// So the two things that have to hold are the two that are easy to get wrong.
/// The order has to be the order the edits actually happened in — which is not
/// free, because the config files late, on a settle, and could otherwise land
/// behind an edit that came after it. And a press has to TAKE YOU TO the
/// change, or a room-wide Undo that rolls back a floor plan while you stand on
/// the Cost tab is a button that appears to do nothing.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_room_undo_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A room open from a file — the config history is keyed on the file, so a
  /// room with no path is a different case entirely.
  AppStateProvider room({String stem = 'bss101'}) {
    final file = path.join(dir.path, '${stem}_config.json');
    File(file).writeAsStringSync(
      '{"SYSTEM_SETUP":{"gui_full_room_name":"Bessey 101"},'
      '"DISPLAY_1":{"model":"NEC C651Q"}}',
    );
    final p = AppStateProvider(autoLoadSettings: false);
    p.currentConfigPath = file;
    p.roomConfig = {
      'SYSTEM_SETUP': {'gui_full_room_name': 'Bessey 101'},
      'DISPLAY_1': {'model': 'NEC C651Q'},
    };
    p.loadAvFlowForCurrentConfig();
    // The first notification after the path changes is what baselines the
    // config history against this file.
    p.notifyListeners();
    return p;
  }

  /// An edit made the way a device form makes one: straight into the map, then
  /// a notification. Nothing about the config is instrumented, which is the
  /// whole point of how it records.
  void editConfig(AppStateProvider p, void Function() change) {
    change();
    p.notifyListeners();
    // Ends the step where a person would end it, rather than waiting out the
    // settle — the same thing leaving the page does.
    p.recordUndoPoint();
  }

  AvNode box(String id) => AvNode(
        id: id,
        label: id,
        model: '',
        pos: Offset.zero,
        ports: const [],
      );

  group('one press takes back the newest thing in the room', () {
    test('whichever of the three histories it is waiting in', () {
      final p = room();

      p.addAvNode(box('AV_1'));
      editConfig(p, () => p.roomConfig['DISPLAY_1']['input'] = 'HDMI 2');
      p.setAvCostPrice('model:nec c651q', 1499);
      p.setSchematicPosition('DISPLAY_1', const Offset(40, 40));

      // Newest first, and each one out of a different history.
      expect(p.undoRoom(), 'Move node');
      expect(p.schematicPositions['DISPLAY_1'], isNull);

      expect(p.undoRoom(), 'Price');
      expect(p.avCost.priceOverrides['model:nec c651q'], isNull);

      expect(p.undoRoom(), isNotEmpty, reason: 'the config edit');
      expect(p.roomConfig['DISPLAY_1']['input'], isNull);

      expect(p.undoRoom(), 'Add AV_1');
      expect(p.avNodes, isEmpty);

      expect(p.canUndoRoom, isFalse, reason: 'the room is back where it began');
      expect(p.undoRoom(), '', reason: 'and a press finds nothing');
    });

    test('a config edit still settling goes down where it happened', () {
      // THE ORDERING TRAP. The config files late, on a settle, so an edit typed
      // into a form a moment before a box was moved would land on the room's
      // spine AFTER the move — and one press would take back the wrong one.
      // Every synchronous push flushes the config first to stop that.
      final p = room();

      // Typed, and deliberately NOT settled: no recordUndoPoint here.
      p.roomConfig['DISPLAY_1']['input'] = 'HDMI 2';
      p.notifyListeners();

      // Now something on a drawing, which files immediately.
      p.addAvNode(box('AV_1'));

      // The drawing edit is the newer of the two and has to come back first.
      expect(p.undoRoom(), 'Add AV_1');
      expect(p.roomConfig['DISPLAY_1']['input'], 'HDMI 2',
          reason: 'the config edit is older and stays for the next press');

      expect(p.undoRoom(), isNotEmpty);
      expect(p.roomConfig['DISPLAY_1']['input'], isNull);
    });

    test('and Redo walks the same order back up', () {
      final p = room();

      p.addAvNode(box('AV_1'));
      p.setAvCostPrice('model:nec c651q', 1499);

      expect(p.undoRoom(), 'Price');
      expect(p.undoRoom(), 'Add AV_1');

      expect(p.redoRoom(), 'Add AV_1');
      expect(p.avNodes.single.id, 'AV_1');
      expect(p.redoRoom(), 'Price');
      expect(p.avCost.priceOverrides['model:nec c651q'], 1499);

      expect(p.canRedoRoom, isFalse);
    });

    test('a new edit ends the room\'s future, not just its own tab\'s', () {
      final p = room();

      p.addAvNode(box('AV_1'));
      p.setAvCostPrice('model:nec c651q', 1499);
      expect(p.undoRoom(), 'Price');
      expect(p.canRedoRoom, isTrue);

      // Something else entirely, on a different history.
      p.setSchematicPosition('DISPLAY_1', const Offset(40, 40));

      // The price was undone and then typed over, in the sense that matters:
      // the room has moved a different way since.
      expect(p.canRedoRoom, isFalse,
          reason: 'a room-level Redo would put back a branch nobody is on');
    });
  });

  group('the press takes you to the change', () {
    test('an edit made on another tab moves the view there', () {
      final p = room();

      // On the estimate, a price. Then off to the racks, and a frame.
      p.selectTab(AppTab.cost.index);
      p.setAvCostPrice('model:nec c651q', 1499);
      p.selectTab(AppTab.racks.index);
      p.addAvNode(box('AV_1'));

      // Standing on the Racks tab, the first press takes back the box that was
      // added here and leaves the view alone.
      expect(p.roomUndoTab, AppTab.avFlow,
          reason: 'a node belongs to the signal flow');
      expect(p.undoRoom(), 'Add AV_1');
      expect(p.selectedTabIndex, AppTab.avFlow.index);

      // The next press is about the price, which is two tabs away.
      expect(p.roomUndoTab, AppTab.cost);
      expect(p.undoRoom(), 'Price');
      expect(p.selectedTabIndex, AppTab.cost.index,
          reason: 'the estimate is where that change is');
    });

    test('and stays put when the change is already on screen', () {
      final p = room();
      p.selectTab(AppTab.cost.index);
      p.setAvCostPrice('model:nec c651q', 1499);

      expect(p.roomUndoTab, AppTab.cost);
      p.undoRoom();
      expect(p.selectedTabIndex, AppTab.cost.index);
    });

    test('a survey date undone leaves somebody on the Lifecycle page', () {
      // The replacement plan files under the AV Flow scope, because that is
      // where the boxes live. Being thrown onto the diagram after editing a
      // date would be a worse answer than staying where the dates are.
      final p = room();
      p.selectTab(AppTab.lifecycle.index);
      p.addAvNode(box('AV_1'));

      expect(p.roomUndoTab, AppTab.lifecycle);
      p.undoRoom();
      expect(p.selectedTabIndex, AppTab.lifecycle.index);
    });

    test('a config edit goes back to the form it was typed on', () {
      final p = room();
      p.selectTab(AppTab.devices.index);
      editConfig(p, () => p.roomConfig['DISPLAY_1']['input'] = 'HDMI 2');
      p.selectTab(AppTab.cost.index);

      expect(p.roomUndoTab, AppTab.devices);
      expect(p.undoRoom(), isNotEmpty);
      expect(p.selectedTabIndex, AppTab.devices.index);
    });
  });

  group('the buttons and the press agree', () {
    test('nothing to undo on a room nobody has touched', () {
      final p = room();
      expect(p.canUndoRoom, isFalse);
      expect(p.canRedoRoom, isFalse);
      expect(p.roomUndoLabel, '');
      expect(p.undoRoom(), '');
    });

    test('lit means a press does something, on every step of the way down', () {
      // AN UNDO THAT IS LIT AND DOES NOTHING WHEN PRESSED is the exact failure
      // people report as "the button does not work", and the risk a spine over
      // three independent histories introduces.
      final p = room();
      p.addAvNode(box('AV_1'));
      editConfig(p, () => p.roomConfig['DISPLAY_1']['input'] = 'HDMI 2');
      p.setAvCostPrice('model:nec c651q', 1499);
      p.setSchematicPosition('DISPLAY_1', const Offset(40, 40));

      var pressed = 0;
      while (p.canUndoRoom) {
        expect(p.undoRoom(), isNotEmpty,
            reason: 'press $pressed was offered and did nothing');
        pressed++;
        expect(pressed, lessThan(20), reason: 'undo is not terminating');
      }
      expect(pressed, 4);
    });

    test('the label names the step that is actually next', () {
      final p = room();
      p.addAvNode(box('AV_1'));
      expect(p.roomUndoLabel, 'Add AV_1');
      p.setAvCostPrice('model:nec c651q', 1499);
      expect(p.roomUndoLabel, 'Price');

      p.undoRoom();
      expect(p.roomRedoLabel, 'Price');
      expect(p.roomUndoLabel, 'Add AV_1');
    });
  });

  test('another room\'s edits are not this room\'s to undo', () {
    final p = room();
    p.addAvNode(box('AV_1'));
    p.setAvCostPrice('model:nec c651q', 1499);
    expect(p.canUndoRoom, isTrue);

    // A different file is a different document, and a history that carried
    // across would let Undo paste the last room into this one.
    final other = path.join(dir.path, 'other_config.json');
    File(other).writeAsStringSync('{"SYSTEM_SETUP":{}}');
    p.currentConfigPath = other;
    p.roomConfig = {'SYSTEM_SETUP': {}};
    p.loadAvFlowForCurrentConfig();
    p.notifyListeners();

    expect(p.canUndoRoom, isFalse);
    expect(p.canRedoRoom, isFalse);
    expect(p.undoRoom(), '');
  });
}
