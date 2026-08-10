import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/device_recheck.dart';
import 'package:extron_configurator/labor_rates.dart';

/// A device that is bought, has a rack height, and still isn't in the rack
/// builder looks the same however it got that way. These are the three ways,
/// and the rule that keeps the fix from being worse than the fault: a figure
/// the catalog does not have never overwrites one somebody entered.
void main() {
  AvNode device(
    String id,
    String label,
    String model, {
    int rackUnits = 0,
    double watts = 0,
    double btu = 0,
  }) => AvNode(
    id: id,
    label: label,
    model: model,
    pos: Offset.zero,
    rackUnits: rackUnits,
    powerWatts: watts,
    btuPerHour: btu,
    ports: const [],
  );

  AvDeviceLibrary catalog() {
    final library = AvDeviceLibrary.empty();
    library.upsert(
      const AvDeviceTemplate(
        model: 'Switcher Y',
        category: 'Switcher',
        rackUnits: 2,
        powerWatts: 90,
        price: 2500,
        ports: [],
      ),
    );
    library.upsert(
      const AvDeviceTemplate(
        model: 'Vent Plate 1U',
        category: 'Vent plate',
        rackUnits: 1,
        price: 40,
        ports: [],
      ),
    );
    // Deliberately unpriced and unmeasured: nothing about it may be pushed
    // onto a room that already has figures.
    library.upsert(
      const AvDeviceTemplate(model: 'Mystery Box', ports: []),
    );
    return library;
  }

  DeviceRecheck check({
    List<AvNode> nodes = const [],
    RoomCostSettings? cost,
    List<RackFrame> racks = const [],
    Map<String, RackSlot> slots = const {},
    List<RackItem> rackItems = const [],
  }) => recheckDevices(
    nodes: nodes,
    library: catalog(),
    cost: cost ?? RoomCostSettings(),
    racks: racks,
    slots: slots,
    rackItems: rackItems,
  );

  group('figures that drifted from the catalog', () {
    test('a rack height filled in later reaches the device on the diagram', () {
      // The order that causes this: draw the room, then find the part number.
      final result = check(nodes: [device('S1', 'Switcher', 'Switcher Y')]);

      expect(result.specChanges.single.after.rackUnits, 2);
      expect(result.specChanges.single.after.powerWatts, 90);
      expect(
        result.specChanges.single.fields,
        contains('Rack height 0U → 2U'),
      );
      // Which is the whole point: 0U is what kept it out of the rack builder.
      expect(result.specChanges.single.before.rackUnits, 0);
    });

    test('a device already matching the catalog is left alone', () {
      final result = check(
        nodes: [
          device('S1', 'Switcher', 'Switcher Y', rackUnits: 2, watts: 90),
        ],
      );
      expect(result.isClean, isTrue);
      expect(result.rackableDevices, 1);
    });

    test('a figure the catalog does not have never overwrites one that was '
        'entered by hand', () {
      final result = check(
        nodes: [device('X1', 'Odd box', 'Mystery Box', rackUnits: 3, watts: 55)],
      );
      // A blank in the catalog means "nobody filled this in", not "this draws
      // nothing" — reverting a measured figure to 0 would be the worse bug.
      expect(result.specChanges, isEmpty);
    });

    test('a model the catalog has never heard of is not guessed at', () {
      final result = check(nodes: [device('X1', 'Box', 'Not In Catalog')]);
      expect(result.specChanges, isEmpty);
    });

    test('a wall box keeps the height its jack count gives it', () {
      final plate = AvNode(
        id: 'W1',
        label: 'Lectern plate',
        model: 'Switcher Y',
        pos: Offset.zero,
        kind: AvNodeKind.jackField,
        rackUnits: 1,
        ports: const [],
      );
      expect(check(nodes: [plate]).specChanges, isEmpty);
    });
  });

  group('quoted on the Cost tab but never drawn', () {
    test('a rack-mount equipment line is reported', () {
      final cost = RoomCostSettings()
        ..extraEquipment.add(
          const CostLineItem(
            id: 'EQP_1',
            description: 'Spare switcher',
            catalogModel: 'Switcher Y',
            qty: 2,
          ),
        );
      final found = check(cost: cost).quoted.single;
      expect(found.kind, QuotedKind.equipment);
      expect(found.rackUnits, 2);
      expect(found.qty, 2);
      expect(found.label, 'Spare switcher');
    });

    test('a rack hardware line is reported as hardware', () {
      final cost = RoomCostSettings()
        ..extraHardware.add(
          const CostLineItem(
            id: 'HW_1',
            description: 'Spare vent',
            catalogModel: 'Vent Plate 1U',
          ),
        );
      expect(check(cost: cost).quoted.single.kind, QuotedKind.hardware);
    });

    test('a line that is not rack-mount gear is not noise on the list', () {
      final cost = RoomCostSettings()
        // No catalog model at all, and a model with no rack height: neither is
        // ever going in a frame, so neither belongs in this report.
        ..extraEquipment.add(
          const CostLineItem(id: 'EQP_1', description: 'Owner-furnished TV'),
        )
        ..extraEquipment.add(
          const CostLineItem(
            id: 'EQP_2',
            description: 'Odd box',
            catalogModel: 'Mystery Box',
          ),
        );
      expect(check(cost: cost).quoted, isEmpty);
    });
  });

  group('racked into nothing', () {
    test('a placement in a deleted frame is found', () {
      final result = check(
        nodes: [device('S1', 'Switcher', 'Switcher Y', rackUnits: 2, watts: 90)],
        racks: const [],
        slots: const {'S1': RackSlot(rackId: 'RACK_1', startU: 3)},
      );
      final orphan = result.orphans.single;
      expect(orphan.occupantId, 'S1');
      expect(orphan.label, 'Switcher');
      expect(orphan.reason, contains('deleted'));
    });

    test('a placement whose occupant is gone is found', () {
      final result = check(
        racks: const [RackFrame(id: 'RACK_1', name: 'Rack 1', heightU: 12)],
        slots: const {'GONE_1': RackSlot(rackId: 'RACK_1', startU: 1)},
      );
      expect(result.orphans.single.occupantId, 'GONE_1');
    });

    test('a placement in a frame that exists is fine', () {
      final result = check(
        nodes: [device('S1', 'Switcher', 'Switcher Y', rackUnits: 2, watts: 90)],
        racks: const [RackFrame(id: 'RACK_1', name: 'Rack 1', heightU: 12)],
        slots: const {'S1': RackSlot(rackId: 'RACK_1', startU: 3)},
      );
      expect(result.isClean, isTrue);
    });
  });

  group('putting a quoted line onto the room', () {
    AppStateProvider room() {
      final p = AppStateProvider(autoLoadSettings: false)
        ..roomConfig = {
          'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
        };
      p.loadAvFlowForCurrentConfig();
      p.avDeviceLibrary = catalog();
      return p;
    }

    test('equipment becomes devices and stops being a cost line', () {
      final p = room();
      final line = p.addAvCostExtraEquipment(
        catalogModel: 'Switcher Y',
        description: 'Spare switcher',
        qty: 2,
      );
      p.setAvCostPrice(line.id, 1900);

      final added = p.promoteAvCostEquipmentToDiagram(
        line.id,
        at: const Offset(40, 60),
      );

      expect(added.length, 2);
      expect(added.first.rackUnits, 2, reason: 'so the rack builder lists it');
      expect(p.avCost.extraEquipment, isEmpty);
      // The room's negotiated price is about the gear, not about which list it
      // was on — it has to survive the move, under the diagram's line key.
      expect(p.avCost.priceOverrides['model:switcher y'], 1900);
      expect(p.avCost.priceOverrides.containsKey(line.id), isFalse);

      // And the money is counted once, not twice.
      final estimate = computeRoomCost(
        model: buildAvFlowModel(p),
        library: catalog(),
        settings: p.avCost,
      );
      expect(estimate.equipment.single.qty, 2);
      expect(estimate.equipmentTotal, 3800);
    });

    test('hardware becomes rack items waiting to be placed', () {
      final p = room();
      final line = p.addAvCostExtraHardware(
        catalogModel: 'Vent Plate 1U',
        description: 'Spare vent',
        qty: 3,
      );

      final added = p.promoteAvCostHardwareToRacks(line.id);

      expect(added.length, 3);
      expect(p.avCost.extraHardware, isEmpty);
      expect(p.avRackItems.length, 3);
      // Unplaced: they show up on the Racks tab as waiting, not silently
      // dropped into a frame the user did not choose.
      expect(p.avRackSlots, isEmpty);
    });

    test('un-racking an orphan puts the device back on the to-place list', () {
      final p = room();
      final node = p.addAvNode(
        device('', 'Switcher', 'Switcher Y', rackUnits: 2),
      );
      p.avRackSlots[node.id] = const RackSlot(rackId: 'GONE', startU: 3);

      p.clearAvRackPlacement(node.id);
      expect(p.avRackSlots.containsKey(node.id), isFalse);
    });
  });

  /// A published billing schedule is a list of formal job titles; people ask
  /// for them by the letters. Derived rather than stored, so it is right for a
  /// rate somebody types in this afternoon too.
  group('labor rate shorthand', () {
    test('reads the letters off the role, keeping the level', () {
      expect(
        laborRateInitialism('0482 Technology Support Specialist III — State'),
        'TSSIII',
      );
      expect(laborRateInitialism('6533 Electrician — External'), 'E');
      expect(
        laborRateInitialism('6699 Air Conditioning/Refrigeration Mechanic'),
        'ACRM',
      );
      expect(
        laborRateInitialism('1032 Administrative Support Assistant -12 Month'),
        'ASA12M',
      );
      // Nobody says "NACAII".
      expect(
        laborRateInitialism('0462 Network And Communications Analyst II'),
        'NCAII',
      );
      // A hand-added role with no class number in front of it.
      expect(laborRateInitialism('CTS IV'), 'CIV');
    });

    test('typing the shorthand finds the role', () {
      const rate = LaborRate(
        id: 'tss3ns',
        name: '0482 Technology Support Specialist III — Non-state',
        hourlyRate: 83.76,
        notes: 'Class 0482 · Non-state funded campus & auxiliary',
      );

      for (final query in ['tss', 'TSS', 'tssIII', 'tss iii', 'tssi']) {
        expect(rate.matches(query), isTrue, reason: query);
      }
      // Still findable the long ways round.
      expect(rate.matches('support specialist'), isTrue);
      expect(rate.matches('0482'), isTrue);
      expect(rate.matches('auxiliary'), isTrue);
      expect(rate.matches(''), isTrue);

      // And not confused with the level above it.
      expect(rate.matches('tssiv'), isFalse);
      expect(rate.matches('electrician'), isFalse);
    });
  });
}
