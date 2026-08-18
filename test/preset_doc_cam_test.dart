import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/room_presets.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  THE DOC CAM IS A SOURCE, NOT A DEVICE
/// ============================================================================
///  A document camera is plugged in and pointed at a page. Nothing talks to
///  it, so it has no driver, no address and no line on the control schematic —
///  it belongs with input_pc and input_hdmi, which are sources the room has
///  and nothing more.
///
///  It still has to be on the AV Flow drawing, because a lead runs from it,
///  and therefore on the estimate, because somebody buys it. The two are the
///  same fact: the estimate counts the boxes on the drawing.
///
///  This is already how the presets are built. Pinned here so it stays that
///  way — a doc cam that acquires a config block acquires a Devices page entry
///  and a control line with it, and neither is true of the thing on the desk.
/// ============================================================================
void main() {
  late UiSchema schema;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
  });

  /// The device-family prefixes a config block can have. A node whose id
  /// starts with one of these IS a controlled device: it gets a Devices page
  /// entry, a module and a line on the control schematic.
  Set<String> controlPrefixes() => schema.deviceCountMap.values.toSet();

  for (final name in const ['Basic classroom', 'Hyflex', 'Active learning']) {
    group(name, () {
      final preset =
          builtInRoomPresets().firstWhere((p) => p.name == name);

      test('has a doc cam on the drawing', () {
        final cam = preset.nodes
            .where((n) => n.model.toLowerCase() == 'document camera');
        expect(cam, hasLength(1),
            reason: 'it is a box on the diagram and a line on the estimate');
        expect(cam.single.excludeFromCost, isFalse,
            reason: 'somebody buys it');
      });

      test('and it is not a controlled device', () {
        final cam = preset.nodes
            .firstWhere((n) => n.model.toLowerCase() == 'document camera');
        for (final prefix in controlPrefixes()) {
          expect(cam.id.startsWith(prefix), isFalse,
              reason: '${cam.id} would become a $prefix block, with a module '
                  'and a control line');
        }
      });

      test('but the room still says which input it is on', () {
        // The System side keeps it, exactly as it keeps input_pc: the panel
        // needs a button for it and the switcher needs a number.
        expect(preset.systemSetup['input_doc_cam'], isNotNull);
        expect(preset.systemSetup['input_doc_cam'], isNotEmpty);
      });
    });
  }
}
