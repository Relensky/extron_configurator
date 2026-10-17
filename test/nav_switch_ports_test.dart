import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_routing.dart';

/// NAV endpoints and a NAVigator land on the network switch in order:
/// encoders first, then decoders, then the NAVigator.
void main() {
  late AvDeviceLibrary library;

  setUpAll(() async {
    library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
  });

  AvNode fromCatalog(String id, String model, String label) => AvNode(
        id: id,
        label: label,
        model: model,
        pos: Offset.zero,
        ports: library.templateForModel(model)!.ports,
      );

  AvNode lanSwitch() => AvNode(
        id: 'AVNODE_90',
        label: 'Network switch',
        model: '',
        pos: Offset.zero,
        ports: [
          const AvPort(
            id: 'uplink',
            label: 'UPLINK',
            signal: SignalType.network,
            direction: PortDirection.bidirectional,
            side: PortSide.left,
          ),
          for (var i = 1; i <= 8; i++)
            AvPort(
              id: 'lan_$i',
              label: 'PORT $i',
              signal: SignalType.network,
              direction: PortDirection.bidirectional,
              side: PortSide.right,
            ),
        ],
      );

  AppStateProvider room({bool navigator = true}) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..avDeviceLibrary = library;
    // Added out of order on purpose: the order comes from the role.
    p.avNodes.addAll([
      fromCatalog('AVNODE_1', 'NAV SD 101', 'Decoder 1'),
      fromCatalog('AVNODE_2', 'NAV E 101', 'Encoder 2'),
      if (navigator) fromCatalog('AVNODE_3', 'NAVigator', 'NAVigator'),
      fromCatalog('AVNODE_4', 'NAV E 101', 'Encoder 1'),
      fromCatalog('AVNODE_5', 'NAV SD 101', 'Decoder 2'),
      lanSwitch(),
    ]);
    return p;
  }

  test('reads the NAV role off the model', () {
    expect(navRole(fromCatalog('a', 'NAV E 101', 'x')), NavRole.encoder);
    expect(navRole(fromCatalog('a', 'NAV 10E 501 MM', 'x')), NavRole.encoder);
    expect(navRole(fromCatalog('a', 'NAV SD 501', 'x')), NavRole.decoder);
    expect(navRole(fromCatalog('a', 'NAV D 121', 'x')), NavRole.decoder);
    expect(navRole(fromCatalog('a', 'NAVigator', 'x')), NavRole.navigator);
    expect(navRole(fromCatalog('a', 'EBP NAV D', 'x')), isNull);
  });

  test('encoders, then decoders, then the NAVigator, on ports 1 up', () {
    final runs = planNavNetworkRuns(room());
    String endpoint(RoutedCable c) =>
        c.fromNodeId == 'AVNODE_90' ? c.toLabel : c.fromLabel;
    String switchPort(RoutedCable c) =>
        c.fromNodeId == 'AVNODE_90' ? c.fromPortLabel : c.toPortLabel;

    expect(runs.map(endpoint), [
      'Encoder 1',
      'Encoder 2',
      'Decoder 1',
      'Decoder 2',
      'NAVigator',
    ]);
    expect(runs.map(switchPort),
        ['PORT 1', 'PORT 2', 'PORT 3', 'PORT 4', 'PORT 5']);
    // Encoders feed the switch, decoders are fed from it.
    expect(runs.first.toNodeId, 'AVNODE_90');
    expect(runs[2].fromNodeId, 'AVNODE_90');
  });

  test('nothing without a NAVigator', () {
    expect(planNavNetworkRuns(room(navigator: false)), isEmpty);
  });

  test('a new endpoint takes the next free port, and drawing is idempotent',
      () {
    final p = room();
    expect(drawNavNetworkRuns(p), 5);
    expect(drawNavNetworkRuns(p), 0);

    p.avNodes.add(fromCatalog('AVNODE_6', 'NAV E 101', 'Encoder 3'));
    final runs = planNavNetworkRuns(p);
    expect(runs, hasLength(1));
    expect(runs.single.fromLabel, 'Encoder 3');
    expect(runs.single.toPortLabel, 'PORT 6');
  });

  test('the routing pass draws them even with no config', () {
    final plan = planRoutingFromConfig(room());
    expect(plan.cables.where((c) => c.configKey == 'nav_lan'), hasLength(5));
  });
}
