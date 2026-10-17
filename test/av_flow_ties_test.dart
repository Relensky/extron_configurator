import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_ties.dart';
import 'package:extron_configurator/av_flow_view.dart';

/// Tie in sequence and the power outlet editor.
void main() {
  AvPort port(String id, String label, SignalType s, PortDirection d) =>
      AvPort(id: id, label: label, signal: s, direction: d,
          side: d == PortDirection.input ? PortSide.left : PortSide.right);

  AvNode decoder(int n) => AvNode(
        id: 'DEC_$n',
        label: 'NAV Decoder Station $n',
        model: '',
        pos: Offset.zero,
        ports: [
          port('hdmi', 'HDMI', SignalType.hdmi, PortDirection.output),
          port('pwr', 'POWER', SignalType.power, PortDirection.input),
        ],
      );
  AvNode display(int n) => AvNode(
        id: 'DSP_$n',
        label: 'Station $n',
        model: '',
        pos: Offset.zero,
        ports: [
          port('h1', 'HDMI 1', SignalType.hdmi, PortDirection.input),
          port('h2', 'HDMI 2', SignalType.hdmi, PortDirection.input),
          port('pwr', 'POWER', SignalType.power, PortDirection.input),
        ],
      );
  AvNode strip() => AvNode(
        id: 'PDU',
        label: 'Power strip',
        model: '',
        pos: Offset.zero,
        ports: [
          for (var i = 1; i <= 8; i++)
            port('o$i', 'OUTLET $i', SignalType.power, PortDirection.output),
        ],
      );

  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false);
    // Out of order on purpose: pairing goes by the number in the name.
    for (final n in [3, 1, 2]) {
      p.avNodes.add(decoder(n));
      p.avNodes.add(display(n));
    }
    p.avNodes.add(strip());
    return p;
  }

  TieSide sideOf(AppStateProvider p, String key) =>
      tieSides(p).firstWhere((s) => s.key == key);

  test('a set named in sequence is a side, and so is every box', () {
    final p = room();
    final sides = tieSides(p);
    expect(sides.where((s) => !s.isSingle).map((s) => s.label),
        containsAll(['NAV Decoder Station (3)', 'Station (3)']));
    expect(sides.where((s) => s.isSingle), hasLength(7));
    expect(nameStem('NAV Decoder Station 12'), 'NAV Decoder Station');
  });

  test('decoders to displays pair by number, on the input picked', () {
    final p = room();
    final from = sideOf(p, 'group:nav decoder station');
    final to = sideOf(p, 'group:station');
    final hdmi2 = tieConnectors(to, sending: false)
        .firstWhere((c) => c.label == 'HDMI 2');
    final ties = planTies(p,
        from: from,
        fromConnector: tieConnectors(from, sending: true)
            .firstWhere((c) => c.label == 'HDMI'),
        to: to,
        toConnector: hdmi2);
    expect([for (final t in ties) '${t.from.id}>${t.to.id}.${t.toPort.id}'],
        ['DEC_1>DSP_1.h2', 'DEC_2>DSP_2.h2', 'DEC_3>DSP_3.h2']);

    final drawn = p.applyAvTies([
      for (final t in ties)
        (
          fromNode: t.from.id,
          fromPort: t.fromPort.id,
          toNode: t.to.id,
          toPort: t.toPort.id,
          signal: SignalType.hdmi,
        ),
    ]);
    expect(drawn, 3);
    // Planned again, every one is already tied.
    expect(
        planTies(p,
                from: from,
                fromConnector: tieConnectors(from, sending: true).first,
                to: to,
                toConnector: hdmi2)
            .every((t) => t.alreadyTied),
        isTrue);
  });

  test('a strip feeds a set in order, from the outlet picked, and says what '
      'it replaces', () {
    final p = room();
    p.addAvCable(
        fromNodeId: 'PDU',
        fromPortId: 'o3',
        toNodeId: 'DEC_1',
        toPortId: 'pwr',
        signal: SignalType.power);
    final from = sideOf(p, 'box:PDU');
    final to = sideOf(p, 'group:station');
    final ties = planTies(p,
        from: from,
        fromConnector: tieConnectors(from, sending: true).single,
        to: to,
        toConnector: tieConnectors(to, sending: false)
            .firstWhere((c) => c.signal == SignalType.power),
        fromStart: 2);
    expect([for (final t in ties) '${t.fromPort.id}>${t.to.id}'],
        ['o3>DSP_1', 'o4>DSP_2', 'o5>DSP_3']);
    expect(ties.first.replaces, ['NAV Decoder Station 1 (POWER)']);
  });

  test('the outlet editor moves a box and clears an outlet in one Undo', () {
    final p = room();
    final s = p.avNodeById('PDU')!;
    p.addAvCable(
        fromNodeId: 'PDU',
        fromPortId: 'o1',
        toNodeId: 'DSP_1',
        toPortId: 'pwr',
        signal: SignalType.power);
    expect(outletTarget(p, s, stripOutlets(s).first), 'DSP_1');

    p.setAvStripOutlets('PDU', {'o1': null, 'o2': 'DSP_1', 'o3': 'DSP_2'});
    expect(outletTarget(p, s, stripOutlets(s)[0]), isNull);
    expect(outletTarget(p, s, stripOutlets(s)[1]), 'DSP_1');
    expect(outletTarget(p, s, stripOutlets(s)[2]), 'DSP_2');
    expect(p.avCables, hasLength(2));
    expect(powerStrips(p).single.id, 'PDU');
  });

  Future<AppStateProvider> pumpRoom(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1800, 1300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    for (final n in [1, 2, 3]) {
      p.addAvNode(decoder(n));
      p.addAvNode(display(n));
    }
    p.addAvNode(strip());
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: AvFlowView())),
      ),
    );
    await tester.pumpAndSettle();
    return p;
  }

  testWidgets('Tie in sequence opens on the two sets and ties them', (
    tester,
  ) async {
    final p = await pumpRoom(tester);
    await tester.tap(find.byKey(const ValueKey('av_tie_sequence')));
    await tester.pumpAndSettle();
    expect(find.text('Tie in sequence'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('tie_go')));
    await tester.pumpAndSettle();
    expect(
        p.avCables.where((c) =>
            c.fromNodeId.startsWith('DEC_') && c.toNodeId.startsWith('DSP_')),
        hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Power outlets fills a set in order and saves', (tester) async {
    final p = await pumpRoom(tester);
    await tester.tap(find.byKey(const ValueKey('av_power_outlets')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('power_fill_go')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('power_save')));
    await tester.pumpAndSettle();
    final s = p.avNodeById('PDU')!;
    expect([for (final o in stripOutlets(s).take(3)) outletTarget(p, s, o)],
        everyElement(isNotNull));
    expect(tester.takeException(), isNull);
  });
}
