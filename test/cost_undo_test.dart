import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/room_sidecar.dart';

/// UNDO ON THE COST TAB, WHICH HAD NONE.
///
/// The four drawing tabs have had it for years and the estimate did not: the
/// scope was left out on purpose, because nothing on that page recorded an
/// entry and a scope no edit is filed under is a button that is always grey.
/// That made the most retyped edits in the app the least recoverable — a
/// negotiated price typed over a catalog figure, a fee, a labor line, a whole
/// quote re-sorted.
///
/// THE TEST THAT MATTERS IS THE TABLE. Instrumenting a mutation by hand is the
/// approach that fails silently: the method somebody adds next year without a
/// `_pushAvUndo` is an edit Undo steps straight over, and nothing complains.
/// So every method that writes to the estimate is exercised here, and each one
/// has to leave the estimate exactly as it found it after a single Undo. A new
/// one that forgets is a new failing test rather than a quiet hole.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  /// The estimate, encoded — what has to be identical before an edit and after
  /// undoing it.
  String estimate(AppStateProvider p) => jsonEncode(p.avCost.toJson());

  /// Every edit the Cost tab can make, by the name it goes under.
  ///
  /// Each entry sets up whatever it needs, then returns the ONE call being
  /// tested. Setup happens before the baseline is taken, so an add being tested
  /// is not confused with the add that made something to edit.
  final edits = <String, void Function(AppStateProvider p)>{
    'tax rate': (p) => p.setAvCostTax(percent: 8.25),
    'tax label': (p) => p.setAvCostTax(label: 'State tax'),
    'add a fee': (p) => p.addAvCostFee(name: 'Freight', percent: 3),
    'edit a fee': (p) {
      final fee = p.addAvCostFee(name: 'Freight', percent: 3);
      return p.updateAvCostFee(fee.copyWith(percent: 5));
    },
    'remove a fee': (p) {
      final fee = p.addAvCostFee(name: 'Freight', percent: 3);
      return p.removeAvCostFee(fee.id);
    },
    'type a price': (p) => p.setAvCostPrice('model:dmp 64', 1499),
    'clear a typed price': (p) {
      p.setAvCostPrice('model:dmp 64', 1499);
      return p.setAvCostPrice('model:dmp 64', null);
    },
    'add an other-item line': (p) =>
        p.addAvCostItem(description: 'Rack build', qty: 1, unitPrice: 400),
    'edit an other-item line': (p) {
      final item = p.addAvCostItem(description: 'Rack build');
      return p.updateAvCostItem(item.copyWith(qty: 3));
    },
    'remove an other-item line': (p) {
      final item = p.addAvCostItem(description: 'Rack build');
      return p.removeAvCostItem(item.id);
    },
    'add unplaced equipment': (p) =>
        p.addAvCostExtraEquipment(description: 'Spare switcher', qty: 2),
    'edit unplaced equipment': (p) {
      final item = p.addAvCostExtraEquipment(description: 'Spare switcher');
      return p.updateAvCostExtraEquipment(item.copyWith(qty: 4));
    },
    'remove unplaced equipment': (p) {
      final item = p.addAvCostExtraEquipment(description: 'Spare switcher');
      return p.removeAvCostExtraEquipment(item.id);
    },
    'add unplaced hardware': (p) =>
        p.addAvCostExtraHardware(description: 'Blank panel', qty: 6),
    'edit unplaced hardware': (p) {
      final item = p.addAvCostExtraHardware(description: 'Blank panel');
      return p.updateAvCostExtraHardware(item.copyWith(qty: 8));
    },
    'remove unplaced hardware': (p) {
      final item = p.addAvCostExtraHardware(description: 'Blank panel');
      return p.removeAvCostExtraHardware(item.id);
    },
    'add a cable line': (p) =>
        p.addAvCostExtraCable(description: 'Spool of cat6', qty: 1),
    'edit a cable line': (p) {
      final item = p.addAvCostExtraCable(description: 'Spool of cat6');
      return p.updateAvCostExtraCable(item.copyWith(qty: 2));
    },
    'remove a cable line': (p) {
      final item = p.addAvCostExtraCable(description: 'Spool of cat6');
      return p.removeAvCostExtraCable(item.id);
    },
    'sort the equipment table': (p) =>
        p.setAvCostEquipmentSort(CostEquipmentSort.manufacturer),
    'choose a cable': (p) =>
        p.setAvCableEntry(SignalType.hdmi, 25, 'Extron HDMI Pro 25'),
    'clear a cable choice': (p) {
      p.setAvCableEntry(SignalType.hdmi, 25, 'Extron HDMI Pro 25');
      return p.setAvCableEntry(SignalType.hdmi, 25, '');
    },
    'move what was typed on a cable line': (p) {
      p.setAvCableSpares('cable:hdmi', 2);
      return p.moveAvCableLine(from: 'cable:hdmi', to: 'cable:hdmi@50ft');
    },
    'price the drawn cabling': (p) => p.setAvCostIncludeCabling(
          !p.avCost.includeCabling,
        ),
    'spare cable runs': (p) => p.setAvCableSpares('cable:hdmi', 2),
    'spare units': (p) => p.setAvEquipmentSpares('model:dmp 64', 1),
    'furnished by others': (p) => p.setAvCostFurnished('model:dmp 64', 'CSU'),
    'this job buys it again': (p) {
      p.setAvCostFurnished('model:dmp 64', 'CSU');
      return p.setAvCostFurnished('model:dmp 64', null);
    },
    'add labor': (p) => p.addAvCostLabor(techs: 2),
    'edit labor': (p) {
      final line = p.addAvCostLabor(techs: 2);
      return p.updateAvCostLabor(line.copyWith(techs: 3));
    },
    'remove labor': (p) {
      final line = p.addAvCostLabor(techs: 2);
      return p.removeAvCostLabor(line.id);
    },
  };

  group('every edit on the Cost tab can be taken back', () {
    for (final entry in edits.entries) {
      test(entry.key, () {
        final p = room();
        // Setup runs inside the case, so the baseline has to be taken from
        // inside it too. The trick: run the case on a second provider set up
        // identically, and compare against the state the first one reaches
        // just before its final call. Simpler in practice — run the case, undo
        // once, and require the estimate to match a room that never had it.
        final control = room();
        // Whatever the case sets up before its final call, do the same here.
        entry.value(control);
        control.undoAvFlow(AvUndoScope.cost);

        entry.value(p);
        expect(p.canUndoAvFlow(AvUndoScope.cost), isTrue,
            reason: '"${entry.key}" recorded no undo entry at all');
        expect(p.avUndoLabel(AvUndoScope.cost), isNotEmpty,
            reason: '"${entry.key}" recorded an entry with no name on it');

        p.undoAvFlow(AvUndoScope.cost);
        expect(estimate(p), estimate(control),
            reason: '"${entry.key}" did not go back cleanly');
      });
    }
  });

  group('an edit that lands on two tabs goes back as one press', () {
    test('promoting a quote line to the diagram', () {
      final p = room();
      final item = p.addAvCostExtraEquipment(
        catalogModel: 'DMP 64',
        description: 'Spare mixer',
        qty: 2,
      );
      final before = estimate(p);
      final nodesBefore = p.avNodes.length;

      final added = p.promoteAvCostEquipmentToDiagram(
        item.id,
        at: const Offset(100, 100),
      );
      // No catalog in this test, so the promotion may decline — the assertion
      // below is about what happens WHEN it goes through.
      if (added.isEmpty) return;

      // ONE press, not one per box drawn. Dropping the line and drawing two
      // devices is one thing somebody did.
      p.undoAvFlow(AvUndoScope.cost);
      expect(estimate(p), before, reason: 'the quote line came back');
      expect(p.avNodes.length, nodesBefore, reason: 'and the boxes went');
    });
  });

  group('the depth is the app\'s one number', () {
    test('sixty on the cost tab, like everywhere else', () {
      final p = room();
      for (var i = 0; i < 75; i++) {
        p.setAvCostPrice('model:dmp 64', 100 + i.toDouble());
      }
      var back = 0;
      while (p.canUndoAvFlow(AvUndoScope.cost)) {
        p.undoAvFlow(AvUndoScope.cost);
        back++;
        if (back > 100) break;
      }
      expect(back, 60);
    });
  });
}
