import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/cabling_schematic.dart';
import 'package:extron_configurator/room_locations.dart';
import 'package:extron_configurator/room_sidecar.dart';

/// The room is ONE document edited on four pages, and a single shared history
/// made those pages interfere: press Undo on the Cabling tab and back came a
/// device you had just moved on the AV Flow tab. So each tab keeps its own
/// history, over its own slice of the document.
///
/// The two things that have to hold: undoing in one scope must not disturb
/// another, and an edit that genuinely spans scopes must go back as one piece
/// or not at all.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  AvNode node(String id) => AvNode(
    id: id,
    label: id,
    model: '',
    pos: const Offset(10, 10),
    ports: const [],
  );

  group('the scopes are the document\'s own division', () {
    test('every scope owns keys, and no key twice', () {
      final seen = <String>{};
      for (final scope in AvUndoScope.values) {
        final keys = avUndoScopeKeys(scope);
        expect(keys, isNotEmpty, reason: '${scope.name} must own something');
        for (final key in keys) {
          expect(seen.add(key), isTrue, reason: '"$key" is claimed twice');
        }
      }
    });
  });

  group('one tab does not disturb another', () {
    test('undoing on the cabling tab leaves the signal flow alone', () {
      final p = room();
      p.addAvNode(node('SW1'));
      p.addCablingBox(kind: CablingBoxKind.pullBox, label: 'PB1');
      // The edit that used to be lost: made AFTER the cabling one, so a single
      // shared history would roll it back too.
      p.setAvNodePosition('SW1', const Offset(500, 400));

      p.undoAvFlow(AvUndoScope.cabling);

      expect(p.avCabling.extraBoxes, isEmpty, reason: 'the box went back');
      expect(p.avNodeById('SW1')!.pos, const Offset(500, 400),
          reason: 'the device stayed where it was dragged');
    });

    test('and the reverse: the flow tab leaves the drawing alone', () {
      final p = room();
      p.addAvNode(node('SW1'));
      p.addCablingBox(kind: CablingBoxKind.pullBox, label: 'PB1');

      p.undoAvFlow(AvUndoScope.flow);

      expect(p.avNodes, isEmpty);
      expect(p.avCabling.extraBoxes, hasLength(1));
    });

    test('each tab reports only its own history', () {
      final p = room();
      p.addAvRack('Rack 1', 12);

      expect(p.canUndoAvFlow(AvUndoScope.racks), isTrue);
      expect(p.avUndoLabel(AvUndoScope.racks), 'Add rack Rack 1');
      for (final other in [
        AvUndoScope.flow,
        AvUndoScope.floorPlans,
        AvUndoScope.cabling,
      ]) {
        expect(p.canUndoAvFlow(other), isFalse, reason: other.name);
        expect(p.avUndoLabel(other), '');
      }
    });

    test('a redo waiting on one tab survives an edit on another', () {
      final p = room();
      p.addAvRack('Rack 1', 12);
      p.undoAvFlow(AvUndoScope.racks);
      expect(p.canRedoAvFlow(AvUndoScope.racks), isTrue);

      // A cabling edit is not a branch of the racks history.
      p.addCablingBox(kind: CablingBoxKind.pullBox);
      expect(p.canRedoAvFlow(AvUndoScope.racks), isTrue);

      // A racks edit is.
      p.addAvRack('Rack 2', 12);
      expect(p.canRedoAvFlow(AvUndoScope.racks), isFalse);
    });

    test('four tabs can each be undone independently, in any order', () {
      final p = room();
      p.addAvNode(node('SW1'));
      p.addAvRack('Rack 1', 12);
      p.addAvLocation(const RoomLocation(id: '', name: 'Lectern'));
      p.addCablingBox(kind: CablingBoxKind.pullBox);

      // Newest first would be the cabling one; take them out of order.
      p.undoAvFlow(AvUndoScope.racks);
      p.undoAvFlow(AvUndoScope.flow);

      expect(p.avRacks, isEmpty);
      expect(p.avNodes, isEmpty);
      expect(p.avLocations, hasLength(1), reason: 'the place is untouched');
      expect(p.avCabling.extraBoxes, hasLength(1), reason: 'so is the drawing');
    });
  });

  group('an edit that spans tabs', () {
    /// Removing a place also clears it off the devices that named it and off
    /// the control runs — three scopes in one edit.
    AppStateProvider withLocatedDevice() {
      final p = room();
      final loc = p.addAvLocation(const RoomLocation(id: '', name: 'Lectern'));
      p.addAvNode(node('SW1'));
      p.setAvNodeLocation('SW1', loc.id);
      return p;
    }

    test('goes back as one piece, from any of its tabs', () {
      final p = withLocatedDevice();
      final loc = p.avLocations.single.id;
      p.removeAvLocation(loc);
      expect(p.avLocations, isEmpty);
      expect(p.avNodeById('SW1')!.locationId, kNoLocationId);

      // Undone from the Floor Plan tab, but the device gets its place back
      // too — a half-restored room is worse than either state.
      expect(p.undoAvFlow(AvUndoScope.floorPlans), 'Remove Lectern');
      expect(p.avLocations.single.id, loc);
      expect(p.avNodeById('SW1')!.locationId, loc);
    });

    test('is offered on every tab it touched', () {
      final p = withLocatedDevice();
      p.removeAvLocation(p.avLocations.single.id);
      for (final scope in [
        AvUndoScope.floorPlans,
        AvUndoScope.flow,
        AvUndoScope.cabling,
      ]) {
        expect(p.canUndoAvFlow(scope), isTrue, reason: scope.name);
        expect(p.avUndoLabel(scope), 'Remove Lectern');
      }
      expect(p.canUndoAvFlow(AvUndoScope.racks), isFalse);
    });

    test('waits rather than rolling a later edit back with it', () {
      final p = withLocatedDevice();
      p.removeAvLocation(p.avLocations.single.id);
      // A later edit in ONE of the scopes that entry covers. Undoing the
      // removal now would take this with it.
      p.addCablingBox(kind: CablingBoxKind.pullBox, label: 'PB1');

      expect(p.canUndoAvFlow(AvUndoScope.floorPlans), isFalse);
      expect(p.avUndoBlockedBy(AvUndoScope.floorPlans), 'Cabling');
      expect(p.undoAvFlow(AvUndoScope.floorPlans), '');
      expect(p.avCabling.extraBoxes, hasLength(1), reason: 'nothing was lost');

      // Dealing with the blocking tab frees it, which is the way out.
      p.undoAvFlow(AvUndoScope.cabling);
      expect(p.avUndoBlockedBy(AvUndoScope.floorPlans), '');
      expect(p.canUndoAvFlow(AvUndoScope.floorPlans), isTrue);
      expect(p.undoAvFlow(AvUndoScope.floorPlans), 'Remove Lectern');
      expect(p.avLocations, hasLength(1));
    });

    test('removing a device puts its rack rail back with it', () {
      final p = room();
      p.addAvNode(node('SW1'));
      final rack = p.addAvRack('Rack 1', 12);
      p.setAvRackSlot('SW1', RackSlot(rackId: rack.id, startU: 1));
      expect(p.avRackSlots['SW1'], isNotNull);

      p.removeAvNode('SW1');
      expect(p.avRackSlots['SW1'], isNull);

      expect(p.undoAvFlow(AvUndoScope.racks), 'Remove SW1');
      expect(p.avNodeById('SW1'), isNotNull);
      expect(p.avRackSlots['SW1'], isNotNull, reason: 'back on its rail');
    });
  });

  group('what the slices carry', () {
    test('a key that was absent goes back to being absent', () {
      // The backdrop is only written when there IS one, so restoring a slice
      // has to be able to take a key away, not just overwrite it.
      final p = room();
      expect(p.avFlowBackground.hasImage, isFalse);
      p.setAvFlowBackgroundImage('bg.png', const Size(800, 600));
      expect(p.avFlowAsJson().containsKey('flowBackground'), isTrue);

      p.undoAvFlow(AvUndoScope.flow);
      expect(p.avFlowBackground.hasImage, isFalse);
      expect(p.avFlowAsJson().containsKey('flowBackground'), isFalse);
    });

    test('the estimate is its own scope, and no other one reaches it', () {
      // The Cost tab had no history at all for a long time. It has one now,
      // and it is a scope like the others: a slice only ever carries the keys
      // its own scope owns, so undoing a drawing cannot move a price and
      // undoing a price cannot move the drawing.
      final p = room();
      p.addCablingBox(kind: CablingBoxKind.pullBox);
      p.setAvCostTax(percent: 8.25, label: 'State tax');

      p.undoAvFlow(AvUndoScope.cabling);
      expect(p.avCost.taxPercent, 8.25);
      expect(p.avCost.taxLabel, 'State tax');

      // And back the other way. A fresh box, so what is being asserted is
      // that the cost undo left it alone rather than that the cabling undo
      // above had already taken it.
      final box = p.addCablingBox(kind: CablingBoxKind.pullBox);
      p.undoAvFlow(AvUndoScope.cost);
      expect(p.avCost.taxPercent, 0, reason: 'the tax went back');
      expect(p.avCabling.extraBoxes.map((b) => b.id), contains(box.id),
          reason: 'and the drawing did not move');
    });

    test('a snapshot is detached from the live document', () {
      // The bug this guards: a snapshot that held the overrides' LIVE maps was
      // emptied along with them by the restore that was about to read it, so
      // undoing a typed count, a renamed box or a recolored run put back
      // nothing at all. Every map a toJson hands out has to be a copy.
      final p = room();
      final box = p.addCablingBox(kind: CablingBoxKind.pullBox);
      p.setCablingBoxLabel(box.id, 'Ceiling junction');

      final snapshot = p.avFlowAsJson();
      p.avCabling.clear();

      expect(
        (snapshot['cablingSchematic'] as Map)['labels'],
        {box.id: 'Ceiling junction'},
        reason: 'clearing the room must not reach into a snapshot of it',
      );
    });

    test('a run of typing into one box goes back in one press', () {
      // A NAME IS ONE THING SOMEBODY DID, not one per letter. The box calls
      // its provider on every keystroke, so this used to file an entry per
      // character: undoing a rename meant pressing the button eleven times,
      // and the first press took the label back to 'Second nam' — which reads
      // as a button that does not work. Consecutive keystrokes into the same
      // field now keep the FIRST snapshot.
      final p = room();
      final box = p.addCablingBox(kind: CablingBoxKind.pullBox);
      for (final typed in ['S', 'Se', 'Second', 'Second name']) {
        p.setCablingBoxLabel(box.id, typed);
      }

      p.undoAvFlow(AvUndoScope.cabling);
      expect(p.avCabling.labels.containsKey(box.id), isFalse,
          reason: 'the whole name went, not its last letter');

      // And the box itself is still its own step behind that.
      p.undoAvFlow(AvUndoScope.cabling);
      expect(p.avCabling.extraBoxes, isEmpty);
    });

    test('two boxes are two steps, however fast they are typed', () {
      // The run is keyed on the FIELD. Coalescing on the kind of edit would
      // make two boxes renamed one after another impossible to separate.
      final p = room();
      final a = p.addCablingBox(kind: CablingBoxKind.pullBox);
      final b = p.addCablingBox(kind: CablingBoxKind.pathway);
      p.setCablingBoxLabel(a.id, 'Ceiling junction');
      p.setCablingBoxLabel(b.id, 'Wall pathway');

      p.undoAvFlow(AvUndoScope.cabling);
      expect(p.avCabling.labels.containsKey(b.id), isFalse);
      expect(p.avCabling.labels[a.id], 'Ceiling junction',
          reason: 'the box before it is its own step');
    });

    test('a press ends the run, so the next keystroke is a new step', () {
      // Without this the keystroke after an Undo is folded into the step that
      // was just undone, and the second press appears to do nothing.
      final p = room();
      final box = p.addCablingBox(kind: CablingBoxKind.pullBox);
      p.setCablingBoxLabel(box.id, 'First name');
      p.undoAvFlow(AvUndoScope.cabling);

      p.setCablingBoxLabel(box.id, 'Second name');
      p.undoAvFlow(AvUndoScope.cabling);
      expect(p.avCabling.labels.containsKey(box.id), isFalse);
    });

    test('the drawing still reads correctly after a restore', () {
      // The round trip goes through the room file's own reader, so a restore
      // that produced a document the app cannot rebuild would show up here.
      final p = room();
      final a = p.addCablingBox(kind: CablingBoxKind.pullBox);
      final b = p.addCablingBox(kind: CablingBoxKind.pathway);
      final run = p.addCablingBundle(
        fromBoxId: a.id,
        toBoxId: b.id,
        count: 6,
        cableType: 'Cat 6a',
      )!;
      p.setCablingBundleEndLabel(run.id, fromLabel: 'Wall plate 2');
      p.setCablingBundleCount(run.id, 9);

      p.undoAvFlow(AvUndoScope.cabling);

      final drawn = p
          .cablingSchematic(buildAvFlowModel(p))
          .bundles
          .firstWhere((x) => x.id == run.id);
      expect(drawn.count, 6, reason: 'the typed count went back');
      expect(drawn.fromLabel, 'Wall plate 2', reason: 'the label stayed');
    });
  });
}
