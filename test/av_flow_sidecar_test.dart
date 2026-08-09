import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';

/// The AV signal flow belongs to the config file it was drawn for: it saves as
/// `<config>_av_flow.json` beside it and comes back from that folder when the
/// config is opened. Unlike the control schematic — where the diagram is
/// derived and only the overrides persist — this file IS the document, so a
/// round trip has to bring back devices, their connectors, every cable, and
/// the rack placement.
void main() {
  late Directory dir;
  late String configPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('av_flow_sidecar_test_');
    configPath = path.join(dir.path, 'BSS103_config.json');
    File(configPath).writeAsStringSync('{}');
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppStateProvider openedOn(String configFile) =>
      AppStateProvider(autoLoadSettings: false)..currentConfigPath = configFile;

  AvNode switcher() => const AvNode(
        id: 'SWITCHERDEVICE_1',
        label: 'Switcher',
        model: 'SW4 HD 4K PLUS',
        pos: Offset(40, 60),
        fromConfig: true,
        rackUnits: 1,
        ports: [
          AvPort(
              id: 'in_hdmi_1',
              label: 'HDMI IN 1',
              signal: SignalType.hdmi,
              direction: PortDirection.input,
              side: PortSide.left),
          AvPort(
              id: 'out_hdmi_1',
              label: 'HDMI OUT',
              signal: SignalType.hdmi,
              direction: PortDirection.output,
              side: PortSide.right),
        ],
      );

  AvNode projector() => const AvNode(
        id: 'PROJECTORDEVICE_1',
        label: 'Projector',
        model: 'PowerLite L610U',
        pos: Offset(400, 60),
        fromConfig: true,
        ports: [
          AvPort(
              id: 'in_hdmi_1',
              label: 'HDMI 1',
              signal: SignalType.hdmi,
              direction: PortDirection.input,
              side: PortSide.left),
          AvPort(
              id: 'in_aud_1',
              label: 'AUDIO IN',
              signal: SignalType.analogAudio,
              direction: PortDirection.input,
              side: PortSide.left),
        ],
      );

  test('the sidecar path sits next to the working config', () {
    expect(openedOn(configPath).avFlowSidecarPath,
        path.join(dir.path, 'BSS103_config_av_flow.json'));
  });

  test('a round trip preserves devices, connectors, cables and racks',
      () async {
    final p = openedOn(configPath);
    p.addAvNode(switcher());
    p.addAvNode(projector());
    p.addAvCable(
      fromNodeId: 'SWITCHERDEVICE_1',
      fromPortId: 'out_hdmi_1',
      toNodeId: 'PROJECTORDEVICE_1',
      toPortId: 'in_hdmi_1',
      signal: SignalType.hdmi,
      label: 'HDMI-01',
    );
    final rack = p.addAvRack('Main Rack', 42);
    p.setAvRackSlot('SWITCHERDEVICE_1',
        RackSlot(rackId: rack.id, startU: 12, face: RackFace.rear));

    expect(await p.saveAvFlow(), isNotEmpty);

    final reopened = openedOn(configPath)..loadAvFlowForCurrentConfig();

    expect(reopened.avNodes.length, 2);
    final restored = reopened.avNodeById('SWITCHERDEVICE_1')!;
    expect(restored.label, 'Switcher');
    expect(restored.rackUnits, 1);
    expect(restored.ports.map((e) => e.id), ['in_hdmi_1', 'out_hdmi_1']);
    expect(restored.portById('out_hdmi_1')!.direction, PortDirection.output);

    final cable = reopened.avCables.single;
    expect(cable.label, 'HDMI-01');
    expect(cable.signal, SignalType.hdmi);
    expect(cable.toPortId, 'in_hdmi_1');

    final slot = reopened.avRackSlots['SWITCHERDEVICE_1']!;
    expect(slot.startU, 12);
    expect(slot.face, RackFace.rear);
    expect(reopened.avRacks.single.name, 'Main Rack');
  });

  test('restored ids do not collide with newly created ones', () async {
    final p = openedOn(configPath);
    p.addAvNode(switcher());
    p.addAvNode(projector());
    p.addAvCable(
      fromNodeId: 'SWITCHERDEVICE_1',
      fromPortId: 'out_hdmi_1',
      toNodeId: 'PROJECTORDEVICE_1',
      toPortId: 'in_hdmi_1',
      signal: SignalType.hdmi,
    );
    await p.saveAvFlow();

    final reopened = openedOn(configPath)..loadAvFlowForCurrentConfig();
    final added = reopened.addAvCable(
      fromNodeId: 'SWITCHERDEVICE_1',
      fromPortId: 'out_hdmi_1',
      toNodeId: 'PROJECTORDEVICE_1',
      toPortId: 'in_aud_1',
      signal: SignalType.hdmi,
    );

    expect(added, isNotNull);
    expect(added!.id, isNot(reopened.avCables.first.id));
  });

  test('a corrupt sidecar leaves a blank diagram instead of throwing', () {
    File(path.join(dir.path, 'BSS103_config_av_flow.json'))
        .writeAsStringSync('not json at all');
    final p = openedOn(configPath)..loadAvFlowForCurrentConfig();
    expect(p.hasAvFlow, isFalse);
  });

  group('choosing between a drawn diagram and the saved one', () {
    Future<void> writeSidecar() async {
      final seed = openedOn(configPath)..addAvNode(switcher());
      await seed.saveAvFlow();
    }

    test('no prompt when the session has drawn nothing', () async {
      await writeSidecar();
      expect(openedOn(configPath).avFlowNeedsChoice, isFalse);
    });

    test('no prompt when the opened config has nothing saved', () {
      final p = openedOn(configPath)..addAvNode(switcher());
      expect(p.avFlowNeedsChoice, isFalse);
    });

    test('prompts when both exist, and keeping mine survives the tab visit',
        () async {
      await writeSidecar();
      final p = openedOn(configPath)..addAvNode(projector());
      expect(p.avFlowNeedsChoice, isTrue);

      p.keepAvFlowForCurrentConfig();
      p.ensureAvFlowForCurrentConfig(); // visiting the tab must not undo it
      expect(p.avNodes.single.id, 'PROJECTORDEVICE_1');
      expect(p.avFlowNeedsChoice, isFalse);
    });
  });

  group('removing devices', () {
    test('takes its cables and rack slot with it, and stays off on re-seed',
        () {
      final p = openedOn(configPath);
      p.addAvNode(switcher());
      p.addAvNode(projector());
      p.addAvCable(
        fromNodeId: 'SWITCHERDEVICE_1',
        fromPortId: 'out_hdmi_1',
        toNodeId: 'PROJECTORDEVICE_1',
        toPortId: 'in_hdmi_1',
        signal: SignalType.hdmi,
      );
      final rack = p.addAvRack('Main Rack', 42);
      p.setAvRackSlot(
          'SWITCHERDEVICE_1', RackSlot(rackId: rack.id, startU: 1));

      p.removeAvNode('SWITCHERDEVICE_1');

      expect(p.avCables, isEmpty);
      expect(p.avRackSlots, isEmpty);
      // Config-seeded, so it is remembered as dismissed rather than re-added.
      expect(p.avDismissedDevices, contains('SWITCHERDEVICE_1'));
    });

    test('removing a rack un-racks its devices but keeps them on the canvas',
        () {
      final p = openedOn(configPath);
      p.addAvNode(switcher());
      final rack = p.addAvRack('Main Rack', 12);
      p.setAvRackSlot(
          'SWITCHERDEVICE_1', RackSlot(rackId: rack.id, startU: 3));

      p.removeAvRack(rack.id);

      expect(p.avRackSlots, isEmpty);
      expect(p.avNodes.single.id, 'SWITCHERDEVICE_1');
    });
  });

  test('the same pair of ports cannot be cabled twice', () {
    final p = openedOn(configPath);
    p.addAvNode(switcher());
    p.addAvNode(projector());

    expect(
      p.addAvCable(
        fromNodeId: 'SWITCHERDEVICE_1',
        fromPortId: 'out_hdmi_1',
        toNodeId: 'PROJECTORDEVICE_1',
        toPortId: 'in_hdmi_1',
        signal: SignalType.hdmi,
      ),
      isNotNull,
    );
    // Same run drawn the other way round is still the same run.
    expect(
      p.addAvCable(
        fromNodeId: 'PROJECTORDEVICE_1',
        fromPortId: 'in_hdmi_1',
        toNodeId: 'SWITCHERDEVICE_1',
        toPortId: 'out_hdmi_1',
        signal: SignalType.hdmi,
      ),
      isNull,
    );
    expect(p.avCables.length, 1);
  });

  group('rack span occupancy', () {
    test('refuses an overlap, an overhang, and allows the other face', () {
      final p = openedOn(configPath);
      p.addAvNode(switcher()); // 1U
      p.addAvNode(projector().copyWith(rackUnits: 2));
      final rack = p.addAvRack('Main Rack', 12);
      p.setAvRackSlot(
          'SWITCHERDEVICE_1', RackSlot(rackId: rack.id, startU: 5));

      // The 1U switcher already holds U5.
      expect(
        p.avRackSpanIsFree(
            rackId: rack.id,
            face: RackFace.front,
            startU: 4,
            heightU: 2,
            ignoreNodeId: 'PROJECTORDEVICE_1'),
        isFalse,
      );
      // A 2U device starting at U12 would run off the top of a 12U frame.
      expect(
        p.avRackSpanIsFree(
            rackId: rack.id, face: RackFace.front, startU: 12, heightU: 2),
        isFalse,
      );
      // The rear face is a separate set of rails.
      expect(
        p.avRackSpanIsFree(
            rackId: rack.id, face: RackFace.rear, startU: 5, heightU: 2),
        isTrue,
      );
      // Moving the device that is in the way is not a collision with itself.
      expect(
        p.avRackSpanIsFree(
            rackId: rack.id,
            face: RackFace.front,
            startU: 5,
            heightU: 1,
            ignoreNodeId: 'SWITCHERDEVICE_1'),
        isTrue,
      );
    });
  });

  group('the rename from <config>_avflow.json', () {
    String legacyPath() => path.join(dir.path, 'BSS103_config_avflow.json');
    String currentPath() => path.join(dir.path, 'BSS103_config_av_flow.json');

    Future<void> writeLegacy() async {
      final seed = openedOn(configPath)..addAvNode(switcher());
      await seed.saveAvFlow();
      // saveAvFlow writes the CURRENT name, so move it back to simulate a
      // diagram saved by an older build.
      File(currentPath()).renameSync(legacyPath());
    }

    test('a pre-rename file is still found and read', () async {
      await writeLegacy();
      final p = openedOn(configPath);

      expect(p.hasSavedAvFlow, isTrue);
      p.loadAvFlowForCurrentConfig();
      expect(p.avNodeById('SWITCHERDEVICE_1')!.label, 'Switcher');
    });

    test('loading one does NOT move it', () async {
      await writeLegacy();
      openedOn(configPath).loadAvFlowForCurrentConfig();

      expect(File(legacyPath()).existsSync(), isTrue);
      expect(File(currentPath()).existsSync(), isFalse);
    });

    test('saving moves it: new file written, old one retired', () async {
      await writeLegacy();
      final p = openedOn(configPath)..loadAvFlowForCurrentConfig();

      final saved = await p.saveAvFlow();

      expect(saved, currentPath());
      expect(File(currentPath()).existsSync(), isTrue);
      expect(File(legacyPath()).existsSync(), isFalse);

      final reopened = openedOn(configPath)..loadAvFlowForCurrentConfig();
      expect(reopened.avNodeById('SWITCHERDEVICE_1')!.label, 'Switcher');
    });

    test('the current name wins when both are present', () async {
      // Save under the current name first, then plant a legacy file beside
      // it by hand — saving would have retired it, which is the whole point.
      final other = openedOn(configPath)..addAvNode(projector());
      await other.saveAvFlow();
      File(legacyPath()).writeAsStringSync(
        '{"nodes":[{"id":"SWITCHERDEVICE_1","label":"Switcher","model":"",'
        '"x":0,"y":0,"rackUnits":1,"ports":[]}],"cables":[],"racks":[],'
        '"rackSlots":{}}',
      );

      final p = openedOn(configPath)..loadAvFlowForCurrentConfig();
      expect(p.avNodeById('PROJECTORDEVICE_1'), isNotNull);
      expect(p.avNodeById('SWITCHERDEVICE_1'), isNull);
    });
  });
}
