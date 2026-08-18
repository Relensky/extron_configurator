import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/control_prefill.dart';
import 'package:extron_configurator/ui_schema.dart';

/// ============================================================================
///  A LABEL IS NOT EVIDENCE OF WHAT A BOX IS
/// ============================================================================
///  When nothing else says what a device is, the prefill falls back to reading
///  its name as words. That fallback earns its place — somebody types
///  "Projector" into a room with no catalog entry for it and gets a projector
///  block — but it used to try EVERY word against EVERY family, and these
///  rooms are full of boxes whose honest description contains a word that
///  names one:
///
///    "DTP transmitter — camera 1"   -> a camera, with a driver slot
///    "DTP transmitter — station 3"  -> a share station
///    "Control network switch"       -> a screen, because the screen family
///                                      is labelled "Screens (Relays/Network)"
///
///  Each of those is a passive box nothing talks to, handed a config block, an
///  address field and a line on the control schematic.
/// ============================================================================
void main() {
  late UiSchema schema;
  late AvDeviceLibrary library;

  setUpAll(() async {
    schema = await UiSchema.load(explicitPath: 'ui_schema.json');
    library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
  });

  AppStateProvider room() => AppStateProvider(autoLoadSettings: false)
    ..uiSchema = schema
    ..avDeviceLibrary = library;

  AvNode box(String label, {String model = ''}) => AvNode(
        id: 'AVNODE_1',
        label: label,
        model: model,
        pos: Offset.zero,
        ports: const [],
      );

  String? family(String label, {String model = ''}) =>
      familyForNode(room(), box(label, model: model))?.prefix;

  group('a box whose model the catalog knows ignores its label', () {
    test('a transmitter called a camera is still a transmitter', () {
      expect(family('DTP transmitter — camera 1',
          model: 'DTP HDMI 4K 230 Tx'), isNull);
    });

    test('and one called a station is too', () {
      expect(family('DTP transmitter — station 3',
          model: 'DTP HDMI 4K 230 Tx'), isNull);
    });

    test('a receiver behind a panel is not the panel', () {
      expect(family('DTP receiver 3', model: 'DTP HDMI 4K 230 Rx'), isNull);
    });

    test('but the catalog still gets to say what something is', () {
      // The guard drops the LABEL, not the model or the catalog's own answer.
      // A real projector called something daft is still a projector.
      expect(family('front box', model: 'PowerLite L630U'),
          'PROJECTORDEVICE_');
      expect(family('the apc', model: 'AP7900B'), 'POWERDEVICE_');
    });
  });

  group('a box with no catalog entry is read on its last word', () {
    test('which is the noun', () {
      // The fallback doing the job it exists for.
      expect(family('Projector'), 'PROJECTORDEVICE_');
      expect(family('Power controller'), 'POWERDEVICE_');
    });

    test('a trailing number says which, not what', () {
      expect(family('Projector 2'), 'PROJECTORDEVICE_');
    });

    test('and a network switch is a switch, not a screen', () {
      // 'network' is a word in the screen family's own label, and it used to
      // be enough. A switch is not a switcher either, so this lands nowhere —
      // which is right: nothing talks to it.
      expect(family('Control network switch'), isNull);
    });
  });

  group('and a doc cam is still never a camera', () {
    test('by model or by label', () {
      expect(family('Document camera', model: 'Document Camera'), isNull);
      expect(family('Doc Cam'), isNull);
    });

    test('though a real camera still is one', () {
      expect(family('Camera 1 - Instructor TR211', model: 'TR211'),
          'CAMERADEVICE_');
    });
  });
}
