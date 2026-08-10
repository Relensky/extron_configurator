import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_report.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/report_tools.dart';

/// Power in, heat out, and the numbering on a wall plate — the three things
/// added after the catalog import, each of which feeds a figure somebody sizes
/// a circuit, a cabinet fan or a patch panel from.
void main() {
  AvNode device(
    String id,
    String label, {
    double watts = 0,
    double btu = 0,
    PowerSource source = PowerSource.wall,
  }) => AvNode(
    id: id,
    label: label,
    model: label,
    pos: Offset.zero,
    powerWatts: watts,
    btuPerHour: btu,
    powerSource: source,
    ports: const [],
  );

  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  ReportSection sectionNamed(List<ReportSection> all, String title) =>
      all.firstWhere((s) => s.title == title);

  Object? valueFor(ReportSection s, String item) =>
      s.rows.firstWhere((r) => r[0].toString().startsWith(item))[1];

  group('the power inlet', () {
    test('is added, relabeled and removed by the toggle', () {
      const signal = AvPort(
        id: 'in_hdmi_1',
        label: 'HDMI',
        signal: SignalType.hdmi,
        direction: PortDirection.input,
        side: PortSide.left,
      );

      final mains = withPowerInlet(const [signal], PowerInput.mains);
      expect(mains.length, 2);
      expect(mains.last.id, kPowerPortId);
      expect(mains.last.label, 'POWER');
      expect(mains.last.side, PortSide.bottom);

      final poe = withPowerInlet(mains, PowerInput.poe);
      expect(poe.length, 2, reason: 'the toggle relabels, it does not stack');
      expect(poe.last.label, 'POWER (PoE)');

      final passive = withPowerInlet(poe, PowerInput.none);
      expect(passive, [signal]);
    });

    test('sets the room power source it implies', () {
      expect(powerSourceForInput(PowerInput.poe), PowerSource.poe);
      expect(powerSourceForInput(PowerInput.none), PowerSource.none);
      // Mains stays open: the model cannot know whether THIS room puts it on
      // the controller or straight into the wall.
      expect(powerSourceForInput(PowerInput.mains), PowerSource.unspecified);
    });

    test('is not counted as a signal connector', () {
      final template = AvDeviceTemplate(
        model: 'Box',
        ports: withPowerInlet(const [
          AvPort(
            id: 'in_1',
            label: 'IN',
            signal: SignalType.hdmi,
            direction: PortDirection.input,
            side: PortSide.left,
          ),
          AvPort(
            id: 'out_1',
            label: 'OUT',
            signal: SignalType.hdmi,
            direction: PortDirection.output,
            side: PortSide.right,
          ),
        ], PowerInput.mains),
      );
      expect(template.ports.length, 3);
      expect(template.inputCount, 1);
      expect(template.outputCount, 1);
    });

    test('placing a PoE catalog device puts it on PoE, not the mains', () {
      final p = room();
      p.avDeviceLibrary = AvDeviceLibrary.empty()
        ..upsert(
          const AvDeviceTemplate(
            model: 'Ceiling Mic',
            powerInput: PowerInput.poe,
            powerWatts: 12,
            ports: [],
          ),
        );
      p.addAvNode(
        AvNode(
          id: 'MIC',
          label: 'Ceiling Mic',
          model: 'Ceiling Mic',
          pos: Offset.zero,
          powerWatts: 12,
          powerSource: powerSourceForInput(PowerInput.poe),
          ports: withPowerInlet(const [], PowerInput.poe),
        ),
      );

      final power = sectionNamed(
        avReportSections(p, buildAvFlowModel(p)),
        'Power Estimate',
      );
      expect(valueFor(power, 'Estimated total draw'), 12);
      expect(valueFor(power, 'Mains-fed draw'), 0);
    });
  });

  group('heat', () {
    test('comes from the watts unless a BTU figure was published', () {
      expect(device('A', 'A', watts: 100).effectiveBtu, closeTo(341.2, 0.01));
      // An amplifier's rated draw is not all heat — the published figure wins.
      expect(device('B', 'B', watts: 500, btu: 600).effectiveBtu, 600);
      expect(device('C', 'C').effectiveBtu, 0);
    });

    test('the estimate reports the load and the cooling it needs', () {
      final p = room();
      p.addAvNode(device('A', 'Switcher', watts: 100));
      p.addAvNode(device('B', 'Amp', watts: 500, btu: 600));

      final power = sectionNamed(
        avReportSections(p, buildAvFlowModel(p)),
        'Power Estimate',
      );
      expect(valueFor(power, 'Estimated total draw'), 600);
      // 341 from the switcher's watts + the amp's published 600.
      expect(valueFor(power, 'Heat load'), 941);
      expect(valueFor(power, 'Cooling required'), '0.08');
    });

    test('a rack reports the cooling it needs', () {
      final p = room();
      p.addAvNode(device('A', 'Switcher', watts: 100).copyWith(rackUnits: 2));
      p.addAvNode(device('B', 'Amp', watts: 500, btu: 600).copyWith(rackUnits: 2));
      final rack = p.addAvRack('Main rack', 12);
      p.setAvRackSlot('A', RackSlot(rackId: rack.id, startU: 1));
      p.setAvRackSlot('B', RackSlot(rackId: rack.id, startU: 4));

      final summary = sectionNamed(
        avReportSections(p, buildAvFlowModel(p)),
        'Rack Summary',
      );
      final row = summary.rows.single;
      expect(row[3], 2, reason: 'two devices');
      expect(row[4], '4 of 12U');
      expect(row[5], 600, reason: 'watts');
      expect(row[6], 941, reason: 'BTU/hr');
      expect(row[7], '0.08', reason: 'tons of cooling');
    });

    test('a device with no figure is counted, not assumed cold', () {
      final p = room();
      p.addAvNode(device('A', 'Switcher', watts: 100));
      p.addAvNode(device('B', 'Mystery'));
      // Passive gear is not a gap — it genuinely draws nothing.
      p.addAvNode(device('C', 'Speaker', source: PowerSource.none));

      final power = sectionNamed(
        avReportSections(p, buildAvFlowModel(p)),
        'Power Estimate',
      );
      expect(
        valueFor(power, 'Devices with no power figure').toString(),
        startsWith('1'),
      );
    });
  });

  group('devices without a control module', () {
    test('are listed, and the section drops out when there are none', () {
      final p = room();
      p.addAvNode(device('D', 'Wall display'));

      final sections = avReportSections(p, buildAvFlowModel(p));
      final gap = sectionNamed(sections, 'Devices Without a Control Module');
      expect(gap.rows.single[1], 'Wall display');
      expect(gap.rows.single[3], contains('No Python module'));

      // By header name rather than position: the pack list gains columns as
      // the sheet grows, and this test is about the module, not the layout.
      final pack = sectionNamed(sections, 'Pack List');
      expect(
        pack.rows.single[pack.header.indexOf('Control module')],
        'none',
        reason: 'the Control module column',
      );
      expect(
        pack.header,
        contains('Part number'),
        reason: 'what a purchase order is typed from',
      );
    });
  });

  group('the jack field dialog', () {
    Future<void> pumpTab(WidgetTester tester, AppStateProvider provider) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppStateProvider>.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: AvFlowView())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('defaults to the room-number prefix and zero-padded jacks', (
      tester,
    ) async {
      final provider = room();
      await pumpTab(tester, provider);

      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Add wall box / patch panel'),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, '1110'), findsOneWidget);
      expect(find.widgetWithText(TextField, '01'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();

      final box = provider.avNodes.single;
      expect(
        box.ports.map((p) => p.label).toList(),
        ['111001', '111002', '111003', '111004', '111005', '111006'],
      );
    });

    testWidgets('an unpadded first number still numbers plainly', (
      tester,
    ) async {
      final provider = room();
      await pumpTab(tester, provider);

      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Add wall box / patch panel'),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '1110'), 'J');
      await tester.enterText(find.widgetWithText(TextField, '01'), '1');
      await tester.enterText(find.widgetWithText(TextField, '6'), '3');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Add'));
      await tester.pumpAndSettle();

      expect(
        provider.avNodes.single.ports.map((p) => p.label).toList(),
        ['J1', 'J2', 'J3'],
      );
    });
  });
}
