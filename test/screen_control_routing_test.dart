import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_routing.dart';
import 'package:extron_configurator/flow_rules.dart';

/// A projection screen's motor control runs to a screen controller, a relay
/// on the processor, or a wall switch, in the order the rule book gives.
void main() {
  late AvDeviceLibrary library;

  setUpAll(() async {
    library = await AvDeviceLibrary.load(explicitPath: 'av_devices.json');
  });

  AppStateProvider room({bool controller = false}) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..avDeviceLibrary = library;
    p.roomConfig['SYSTEM_SETUP'] = <String, dynamic>{'dev_switchers': '1'};
    p.roomConfig['SWITCHERDEVICE_1'] = <String, dynamic>{
      'name': 'Switcher',
      'model': 'DTP CrossPoint 84 4K IPCP SA',
    };
    AvNode fromCatalog(String id, String model, Offset at) {
      final t = library.resolve(configKey: id, model: model);
      return AvNode(
        id: id,
        label: model,
        model: model,
        pos: at,
        ports: withPowerInlet(t.ports, t.powerInput),
        fromConfig: true,
      );
    }

    p.addAvNode(fromCatalog(
      'SWITCHERDEVICE_1',
      'DTP CrossPoint 84 4K IPCP SA',
      Offset.zero,
    ));
    p.addAvNode(fromCatalog(
      'AVNODE_SCREEN',
      'Advantage Electrol Motorized Screen 58" x 104"',
      const Offset(600, 0),
    ));
    if (controller) {
      p.roomConfig['SCREENDEVICE_1'] = <String, dynamic>{'model': 'SCB-100'};
      p.addAvNode(fromCatalog('SCREENDEVICE_1', 'SCB-100', const Offset(600, 300)));
    }
    return p;
  }

  RoutedCable screenRun(RoutingPlan plan) =>
      plan.cables.singleWhere((c) => c.toNodeId == 'AVNODE_SCREEN');

  test('a motorized screen from the catalog is a screen; its controller is '
      'not', () {
    final p = room(controller: true);
    expect(isProjectionScreen(p.avNodeById('AVNODE_SCREEN')!, library), isTrue);
    expect(isProjectionScreen(p.avNodeById('SCREENDEVICE_1')!, library), isFalse);
    expect(
      isProjectionScreen(p.avNodeById('SWITCHERDEVICE_1')!, library),
      isFalse,
    );
  });

  test('a screen controller is used first', () {
    final p = room(controller: true);
    final plan = planRoutingFromConfig(p);
    final run = screenRun(plan);
    expect(run.fromNodeId, 'SCREENDEVICE_1');
    expect(run.fromPortLabel, 'SCREEN MOTOR');
    expect(run.signal, SignalType.other);
    // The screen gains a connector to land it on.
    expect(plan.addedPorts.single.nodeId, 'AVNODE_SCREEN');
  });

  test('without one, a relay on the switcher\'s processor', () {
    final p = room();
    final run = screenRun(planRoutingFromConfig(p));
    expect(run.fromNodeId, 'SWITCHERDEVICE_1');
    expect(run.fromPortLabel, startsWith('RELAY'));
  });

  test('a wall switch when the rule book says so, placed and wired', () {
    final p = room();
    p.applyFlowRules(p.flowRules.copyWith(screenControl: ['wallSwitch']));
    final plan = planRoutingFromConfig(p);
    final run = screenRun(plan);
    final box = plan.newNodes.singleWhere((n) => n.id == run.fromNodeId);
    expect(box.label, 'Screen switch');

    applyRoutingFromConfig(p, plan);
    final screen = p.avNodeById('AVNODE_SCREEN')!;
    expect(screenControlPort(screen), isNotNull);
    expect(
      p.avCables.where((c) => c.toNodeId == 'AVNODE_SCREEN'),
      hasLength(1),
    );
    // Run again: it is already wired, so nothing new.
    final again = planRoutingFromConfig(p);
    expect(again.cables.where((c) => c.toNodeId == 'AVNODE_SCREEN'), isEmpty);
    expect(again.newNodes, isEmpty);
  });

  test('switched off entirely, screens are left alone', () {
    final p = room(controller: true);
    p.applyFlowRules(p.flowRules.copyWith(screenControl: const []));
    final plan = planRoutingFromConfig(p);
    expect(plan.cables.where((c) => c.toNodeId == 'AVNODE_SCREEN'), isEmpty);
  });

  test('the order survives the rule file', () {
    final rules = FlowRules.builtIn().copyWith(
      screenControl: ['processor', 'wallSwitch'],
    );
    final back = FlowRules.fromJson(rules.toJson());
    expect(back.screenControl, ['processor', 'wallSwitch']);
    expect(FlowRules.fromJson({}).screenControl, kDefaultScreenControl);
    expect(
      FlowRules.fromJson({'screenControl': ['nonsense', 'controller']})
          .screenControl,
      ['controller'],
    );
  });
}
