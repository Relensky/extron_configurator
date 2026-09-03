import 'package:flutter/material.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/manual_room_survey_apply.dart';

/// ============================================================================
///  THE ROOM TYPE'S DRAWING, THE ROOM'S OWN MODELS
/// ============================================================================
///  Building a room from a line item stamps out the room TYPE the estate's
///  sheet priced it against. That is the right skeleton and the wrong bill of
///  materials: the models on it are the type's, and the room has whatever went
///  in in 2015. The survey knows which.
///
///  What is held here: that the two are matched by what a box DOES, that a
///  surveyed box with nowhere to go is REPORTED rather than dropped onto the
///  drawing unwired, and that a position the poll never saw keeps the type's
///  model instead of being blanked.
/// ============================================================================
void main() {
  AvNode node(String id, String label, String model) => AvNode(
    id: id,
    label: label,
    model: model,
    pos: Offset.zero,
    ports: const [],
  );

  AvFlowModel roomOf(List<AvNode> nodes) => AvFlowModel(
    nodes: nodes,
    cables: const [],
    racks: const [],
    rackSlots: const {},
    canvasSize: Size.zero,
    roomTitle: 'AGYM 129',
    unplaced: const [],
  );

  AvDeviceLibrary catalogWith(List<AvDeviceTemplate> entries) {
    final library = AvDeviceLibrary.empty();
    for (final entry in entries) {
      library.upsert(entry);
    }
    return library;
  }

  group('matched by what a box does', () {
    test('the surveyed model lands on the position of the same role', () {
      final plan = planSurveyOntoRoom(
        survey: const [
          ManualRoomItem(
            model: 'Casio XJ-UT310WN',
            category: 'Projector',
            quantity: 2,
          ),
          ManualRoomItem(
            model: 'DTP CrossPoint 84 IPCP SA',
            category: 'Switcher',
          ),
        ],
        model: roomOf([
          node('PROJECTORDEVICE_1', 'Projector 1', 'PT-VMZ62BU8'),
          node('PROJECTORDEVICE_2', 'Projector 2', 'PT-VMZ62BU8'),
          node('SWITCHERDEVICE_1', 'Switcher', 'DTP CrossPoint 84 4K IPCP Q SA'),
        ]),
      );

      expect(plan.placements, hasLength(3));
      expect(
        plan.placements.map((p) => p.onto.id),
        ['PROJECTORDEVICE_1', 'PROJECTORDEVICE_2', 'SWITCHERDEVICE_1'],
      );
      expect(plan.placements.first.item.model, 'Casio XJ-UT310WN');
      expect(plan.leftOver, isEmpty);
      expect(plan.untouched, isEmpty);
    });

    test('a position that already carries the surveyed model is not an edit', () {
      final plan = planSurveyOntoRoom(
        survey: const [
          ManualRoomItem(model: 'PT-VMZ62BU8', category: 'Projector'),
        ],
        model: roomOf([node('PROJECTORDEVICE_1', 'Projector 1', 'PT-VMZ62BU8')]),
      );

      expect(plan.placements, isEmpty, reason: 'the happy case is not a swap');
      expect(plan.leftOver, isEmpty);
      expect(plan.untouched, isEmpty, reason: 'it was matched, just unchanged');
    });

    test('the catalog entry rides along when the catalog has one', () {
      final plan = planSurveyOntoRoom(
        survey: const [
          ManualRoomItem(model: 'PT-VMZ62BU8', category: 'Projector'),
          ManualRoomItem(model: 'Casio XJ-UT310WN', category: 'Projector'),
        ],
        model: roomOf([
          node('PROJECTORDEVICE_1', 'Projector 1', 'old'),
          node('PROJECTORDEVICE_2', 'Projector 2', 'old'),
        ]),
        library: catalogWith([
          const AvDeviceTemplate(
            model: 'PT-VMZ62BU8',
            category: 'Projector',
            ports: [],
          ),
        ]),
      );

      expect(plan.placements.first.template, isNotNull);
      expect(
        plan.placements.last.template,
        isNull,
        reason: 'a nine-year-old Casio the catalog never carried is name only',
      );
    });
  });

  group('what does not fit is said out loud', () {
    test('a surveyed box with no position is left over, not added', () {
      final plan = planSurveyOntoRoom(
        survey: const [
          ManualRoomItem(
            model: 'Casio XJ-UT310WN',
            category: 'Projector',
            quantity: 3,
          ),
          ManualRoomItem(model: 'Epson DC11'),
        ],
        model: roomOf([node('PROJECTORDEVICE_1', 'Projector 1', 'old')]),
      );

      expect(plan.placements, hasLength(1));
      expect(plan.leftOver, [
        'Projector: Casio XJ-UT310WN',
        'Projector: Casio XJ-UT310WN',
        // A box the survey could give no role reports as itself.
        'Epson DC11',
      ]);
    });

    test('a position the poll never saw keeps the room type model', () {
      final plan = planSurveyOntoRoom(
        survey: const [
          ManualRoomItem(model: 'Casio XJ-UT310WN', category: 'Projector'),
        ],
        model: roomOf([
          node('PROJECTORDEVICE_1', 'Projector 1', 'old'),
          node('SCREENDEVICE_1', 'Screen', 'Da-Lite Tensioned'),
        ]),
      );

      expect(plan.placements, hasLength(1));
      expect(
        plan.untouched,
        ['Screen'],
        reason: 'a poll cannot see a screen, and blanking it would be a lie',
      );
    });

    test('a jack field is not a box and never takes a model', () {
      final jacks = AvNode(
        id: 'JACK_1',
        label: 'Wall plate',
        model: '',
        pos: Offset.zero,
        ports: const [],
        kind: AvNodeKind.jackField,
      );
      final plan = planSurveyOntoRoom(
        survey: const [
          ManualRoomItem(model: 'Casio XJ-UT310WN', category: 'Projector'),
        ],
        model: roomOf([jacks]),
      );

      expect(plan.placements, isEmpty);
      expect(plan.leftOver, ['Projector: Casio XJ-UT310WN']);
      expect(plan.untouched, isEmpty);
    });
  });

  test('the plan reads as a sentence somebody can answer', () {
    final plan = planSurveyOntoRoom(
      survey: const [
        ManualRoomItem(model: 'Casio XJ-UT310WN', category: 'Projector'),
        ManualRoomItem(model: 'Epson DC11'),
      ],
      model: roomOf([
        node('PROJECTORDEVICE_1', 'Projector 1', 'old'),
        node('SCREENDEVICE_1', 'Screen', 'Da-Lite'),
      ]),
    );

    final said = describeSurveyPlan(plan);
    expect(said, contains('1 position take'));
    expect(said, contains('no position on this room type'));
    expect(said, contains('keep the room type model'));
  });
}
