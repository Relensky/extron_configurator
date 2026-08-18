import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart' show buildAvFlowModel;
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/cost_estimate_view.dart';

/// A room does not buy "HDMI cable". It buys a 3 ft one and a 25 ft one at
/// different prices, and quoting every run at one figure is wrong in both
/// directions at once. The catalog holds an entry per length, and the estimate
/// puts each drawn run on the shortest one that reaches it.
void main() {
  AvDeviceTemplate lead(String model, double ft, double price) =>
      AvDeviceTemplate(
        model: model,
        category: kCategoryCable,
        cableSignal: SignalType.hdmi,
        cableLengthFt: ft,
        price: price,
        ports: const [],
      );

  AvNode device(String id) => AvNode(
    id: id,
    label: id,
    model: '',
    pos: Offset.zero,
    ports: [
      AvPort(
        id: 'p_$id',
        label: 'HDMI',
        signal: SignalType.hdmi,
        direction: PortDirection.bidirectional,
        side: PortSide.right,
      ),
    ],
  );

  /// A room with [lengths] worth of HDMI runs drawn between two boxes.
  AppStateProvider room(List<double> lengths, List<AvDeviceTemplate> stock) {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.avDeviceLibrary = AvDeviceLibrary.empty();
    for (final t in stock) {
      p.avDeviceLibrary.upsert(t);
    }
    p.addAvNode(device('A'));
    p.addAvNode(device('B'));
    // One cable per length. They share a pair of ports, which addAvCable
    // refuses as a duplicate, so they go into the list directly — this is
    // about what the ESTIMATE does with lengths, not about drawing them.
    for (var i = 0; i < lengths.length; i++) {
      p.avCables.add(
        AvCable(
          id: 'C${i + 1}',
          fromNodeId: 'A',
          fromPortId: 'p_A',
          toNodeId: 'B',
          toPortId: 'p_B',
          signal: SignalType.hdmi,
          lengthFt: lengths[i],
        ),
      );
    }
    return p;
  }

  CostEstimate cost(AppStateProvider p) => computeRoomCost(
        model: buildAvFlowModel(p),
        library: p.avDeviceLibrary,
        settings: p.avCost,
        tier: p.pricingTier,
      );

  group('picking the lead', () {
    test('the shortest one that reaches', () {
      final library = AvDeviceLibrary.empty()
        ..upsert(lead('HDMI 3', 3, 12))
        ..upsert(lead('HDMI 6', 6, 18))
        ..upsert(lead('HDMI 25', 25, 40));

      expect(library.cableForRun(SignalType.hdmi, 2)?.model, 'HDMI 3');
      expect(library.cableForRun(SignalType.hdmi, 3)?.model, 'HDMI 3');
      expect(library.cableForRun(SignalType.hdmi, 4)?.model, 'HDMI 6');
      expect(library.cableForRun(SignalType.hdmi, 20)?.model, 'HDMI 25');
    });

    test('a run longer than anything stocked takes the longest', () {
      final library = AvDeviceLibrary.empty()
        ..upsert(lead('HDMI 3', 3, 12))
        ..upsert(lead('HDMI 25', 25, 40));
      expect(library.cableForRun(SignalType.hdmi, 60)?.model, 'HDMI 25');
    });

    test('a run with no length recorded takes the first entry', () {
      final library = AvDeviceLibrary.empty()
        ..upsert(lead('HDMI 3', 3, 12))
        ..upsert(lead('HDMI 25', 25, 40));
      expect(library.cableForRun(SignalType.hdmi, 0)?.model, 'HDMI 3');
    });

    test('bulk cable sorts last, so it is only reached as a fallback', () {
      final library = AvDeviceLibrary.empty()
        ..upsert(lead('HDMI bulk', 0, 2))
        ..upsert(lead('HDMI 6', 6, 18));
      expect(
        library.cablesForSignal(SignalType.hdmi).map((t) => t.model),
        ['HDMI 6', 'HDMI bulk'],
      );
    });

    test('the length survives a save and a reload of the catalog', () {
      final back = AvDeviceTemplate.fromJson(lead('HDMI 6', 6, 18).toJson());
      expect(back.cableLengthFt, 6);
      // A cable nobody has measured writes nothing.
      expect(lead('HDMI bulk', 0, 2).toJson().containsKey('cableLengthFt'),
          isFalse);
    });
  });

  group('on the estimate', () {
    test('one line per stock length, each at its own price', () {
      final p = room(
        [3, 3, 5, 20],
        [lead('HDMI 3', 3, 12), lead('HDMI 6', 6, 18), lead('HDMI 25', 25, 40)],
      );
      final lines = cost(p).cabling;

      final byModel = {for (final l in lines) l.model: l};
      expect(byModel.keys, containsAll(['HDMI 3', 'HDMI 6', 'HDMI 25']));
      expect(byModel['HDMI 3']!.qty, 2, reason: 'the two 3 ft runs');
      expect(byModel['HDMI 3']!.unitPrice, 12);
      expect(byModel['HDMI 6']!.qty, 1, reason: 'the 5 ft run needs a 6');
      expect(byModel['HDMI 6']!.unitPrice, 18);
      expect(byModel['HDMI 25']!.qty, 1);
      expect(byModel['HDMI 25']!.unitPrice, 40);
      // 2×12 + 1×18 + 1×40
      expect(
        lines.fold<double>(0, (sum, l) => sum + l.total),
        24 + 18 + 40,
      );
    });

    test('one entry, two lengths drawn, is still two lines', () {
      // The lengths on the DRAWING split the order even when the catalog has
      // a single entry for the type — which is the usual case, since the
      // shipped catalog prices cable by the made-up lead rather than by the
      // signal. A 3 ft patch and a 20 ft run are two prices, and collapsing
      // them onto one row leaves nowhere to type the second.
      final p = room([3, 20], [lead('HDMI patch', 0, 15)]);
      final lines = cost(p).cabling;
      expect(lines, hasLength(2));
      expect(lines.map((l) => l.qty), [1, 1]);
      // The shorter one keeps the key the type has always had, so a price
      // typed against 'HDMI' before anybody measured a run still lands.
      expect(lines.map((l) => l.key), ['cable:hdmi', 'cable:hdmi@20ft']);
      expect(lines.every((l) => l.model == 'HDMI patch'), isTrue);
    });

    test('a room with no lengths measured is the single line it always was',
        () {
      final p = room([0, 0], [lead('HDMI patch', 0, 15)]);
      final lines = cost(p).cabling;
      expect(lines, hasLength(1));
      expect(lines.single.qty, 2);
      expect(lines.single.key, 'cable:hdmi');
    });

    test('an uncatalogued type splits by length too, and says which', () {
      // No catalog entry at all: the line is named for the signal, and the
      // length is the only thing telling the two rows apart — so it has to be
      // in the description as well as in the key.
      final p = room([25, 25, 50], []);
      final lines = cost(p).cabling;
      expect(lines, hasLength(2));
      expect(lines.first.qty, 2);
      expect(lines.first.description, contains('25ft'));
      expect(lines.last.qty, 1);
      expect(lines.last.description, contains('50ft'));
      expect(lines.last.key, 'cable:hdmi@50ft');
    });

    test('each length carries its own price', () {
      final p = room([25, 50], []);
      p.setAvCostPrice('cable:hdmi', 40);
      p.setAvCostPrice('cable:hdmi@50ft', 75);
      final lines = cost(p).cabling;
      expect(lines.map((l) => l.unitPrice), [40, 75]);
      expect(lines.fold<double>(0, (sum, l) => sum + l.total), 115);
    });

    test('the spares sit on the type, not on one of its lengths', () {
      final p = room([3, 20], [lead('HDMI 3', 3, 12), lead('HDMI 25', 25, 40)]);
      p.setAvCableSpares(SignalType.hdmi, 2);
      final lines = cost(p).cabling;

      final main = lines.firstWhere((l) => l.key == 'cable:hdmi');
      expect(main.qty, 3, reason: 'its own run plus the two spares');
      expect(main.description, contains('spare'));
      expect(
        lines.where((l) => l.key != 'cable:hdmi').single.qty,
        1,
        reason: 'the other length carries no spares',
      );
    });

    test('a price typed on the type keeps its key when lengths appear', () {
      // The room priced its HDMI by hand before anybody broke the type down.
      final p = room([3], [lead('HDMI 3', 3, 12)]);
      p.setAvCostPrice('cable:hdmi', 9);
      expect(cost(p).cabling.single.unitPrice, 9);

      // Adding a second length must not orphan that price.
      p.avDeviceLibrary.upsert(lead('HDMI 25', 25, 40));
      final main = cost(p)
          .cabling
          .firstWhere((l) => l.key == 'cable:hdmi');
      expect(main.unitPrice, 9);
      expect(main.source, PriceSource.override);
    });

    test('the line says what to order', () {
      final p = room([3, 3], [lead('HDMI 3', 3, 12), lead('HDMI 25', 25, 40)]);
      final line = cost(p).cabling.firstWhere((l) => l.model == 'HDMI 3');
      // The entry's own length, then the runs behind the figure.
      expect(line.description, contains('3ft'));
      expect(line.description, contains('2×'));
    });
  });

  testWidgets('the cabling card lists a row per lead, headed correctly',
      (tester) async {
    final p = room(
      [3, 20],
      [lead('HDMI 3', 3, 12), lead('HDMI 25', 25, 40)],
    );
    tester.view.physicalSize = const Size(1900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('HDMI 3'), findsWidgets);
    expect(find.textContaining('HDMI 25'), findsWidgets);

    // THE HEADERS SIT OVER THE FIGURES THEY NAME. Every numeric caption is
    // right-aligned like the cell under it and carries the same gap in front,
    // so its right edge lands on the column's — which is exactly what was
    // wrong: they were a gap-and-a-bit to the left, reading as if they
    // belonged to the column before.
    // Scoped to the cabling table: 'Extended' captions three other tables on
    // this page.
    final headerRow = find
        .ancestor(of: find.text('Cable type'), matching: find.byType(Row))
        .first;
    // The figures under these are right-aligned, so their captions are too —
    // a left-aligned caption over a right-aligned column sits a gap-and-a-bit
    // to the left of it and reads as belonging to the column before.
    for (final caption in const ['Drawn', 'Total', 'Extended']) {
      final header =
          find.descendant(of: headerRow, matching: find.text(caption));
      expect(header, findsOneWidget, reason: caption);
      expect(
        tester.widget<Text>(header).textAlign,
        TextAlign.right,
        reason: '$caption is over right-aligned figures',
      );
    }
    // The two that sit over INPUT BOXES are right-aligned as well, which this
    // used to have backwards: a numeric LiveTextField right-aligns its figure,
    // so a caption left in the box's cell is a caption at the far end of the
    // column from the number. See cost_header_alignment_test.dart, which
    // measures where each one actually lands.
    for (final caption in const ['Spares', 'Unit price']) {
      final header =
          find.descendant(of: headerRow, matching: find.text(caption));
      expect(header, findsOneWidget, reason: caption);
      expect(tester.widget<Text>(header).textAlign, TextAlign.right,
          reason: '$caption is over a right-aligned figure in a box');
    }
    // Prose reads from the left, and it is a plain cell rather than a box.
    final cableType =
        find.descendant(of: headerRow, matching: find.text('Cable type'));
    expect(tester.widget<Text>(cableType).textAlign, TextAlign.left);

    // The captions and the cells are laid out from the same gaps and widths,
    // so a column's caption box ends where the column does. 'Extended' is the
    // last one before the buttons, so its right edge is the table's.
    final extended = find.descendant(
      of: headerRow,
      matching: find.text('Extended'),
    );
    // The row for the 3 ft lead, and the last money cell on it: what the
    // 'Extended' caption is supposed to be sitting over.
    final row = find
        .ancestor(
          of: find.textContaining('HDMI 3 —'),
          matching: find.byType(Row),
        )
        .last;
    final money = find.descendant(
      of: row,
      matching: find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').contains('12'),
      ),
    );
    expect(money, findsWidgets);

    expect(
      (tester.getBottomRight(extended).dx -
              tester.getBottomRight(money.last).dx)
          .abs(),
      lessThan(1),
      reason: 'the Extended caption ends where the money column does',
    );
    expect(tester.takeException(), isNull);
  });
}
