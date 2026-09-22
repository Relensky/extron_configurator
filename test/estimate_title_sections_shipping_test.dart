import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/cost_estimate.dart';
import 'package:extron_configurator/cost_estimate_view.dart';
import 'package:extron_configurator/device_editor_view.dart';
import 'package:extron_configurator/estimate_pdf.dart';
import 'package:extron_configurator/labor_rates.dart';
import 'package:extron_configurator/report_tools.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// The PDF title, the extra PDF sections, per-item shipping, the crew and
/// total hours on the reports, and the catalog search saying when a filter is
/// hiding what was searched for.
void main() {
  // Uncompressed Helvetica text is one `[(word)]TJ` per word.
  String words(List<int> bytes) => RegExp(r'\[\((.*?)\)\]TJ')
      .allMatches(latin1.decode(bytes))
      .map((m) => m.group(1)!.replaceAll(r'\(', '(').replaceAll(r'\)', ')'))
      .join(' ');

  AvNode display(String id) => AvNode(
    id: id,
    label: id,
    model: 'Display X',
    pos: Offset.zero,
    ports: const [],
  );

  AvFlowModel room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addAvNode(display('Display 1'));
    p.addAvNode(display('Display 2'));
    return buildAvFlowModel(p);
  }

  AvDeviceLibrary catalog() => AvDeviceLibrary.empty()
    ..upsert(const AvDeviceTemplate(model: 'Display X', price: 1000, ports: []));

  const displayKey = 'model:display x';

  CostEstimate price(RoomCostSettings settings) => computeRoomCost(
    model: room(),
    library: catalog(),
    settings: settings,
    rates: LaborRateBook.builtIn(),
  );

  group('shipping per item', () {
    test('is charged per unit, only while the column is on', () {
      final settings = RoomCostSettings(shippingEach: {displayKey: 150});
      expect(price(settings).shippingTotal, 0);
      expect(price(settings).subtotal, 2000);

      settings.showShipping = true;
      final shipped = price(settings);
      expect(shipped.shippingTotal, 300);
      expect(shipped.equipment.single.shippingTotal, 300);
      expect(shipped.subtotal, 2300);
      // The equipment total is still the goods.
      expect(shipped.equipmentTotal, 2000);
    });

    test('is taxed only when asked', () {
      final settings = RoomCostSettings(
        taxPercent: 10,
        showShipping: true,
        shippingEach: {displayKey: 100},
      );
      expect(price(settings).taxableBase, 2000);
      settings.shippingTaxable = true;
      expect(price(settings).taxableBase, 2200);
    });

    test('is not charged on a line somebody else furnishes', () {
      final settings = RoomCostSettings(
        showShipping: true,
        shippingEach: {displayKey: 100},
        furnishedLines: {displayKey: ''},
      );
      expect(price(settings).shippingTotal, 0);
    });

    test('shows up in the report sections', () {
      final settings = RoomCostSettings(
        showShipping: true,
        shippingEach: {displayKey: 100},
      );
      final sections = costReportSections(price(settings));
      final equipment = sections.firstWhere((s) => s.title == 'Equipment');
      expect(equipment.header, containsAll(['Shipping ea.', 'Shipping']));
      final totals = sections.firstWhere((s) => s.title == 'Totals');
      expect(totals.rows.any((r) => r.first == 'Shipping'), isTrue);
    });
  });

  test('title, sections and shipping survive a save', () {
    final settings = RoomCostSettings(
      documentTitle: 'CTS Estimate',
      showShipping: true,
      shippingTaxable: true,
      shippingEach: {displayKey: 75},
      sections: [
        const EstimateSection(
          id: 'S1',
          title: 'Deliverables',
          body: 'Drawings\nTraining',
          bulleted: true,
          place: EstimateSectionPlace.beforePricing,
        ),
      ],
    );
    final read = RoomCostSettings()
      ..readJson(
        jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
      );
    expect(read.pdfTitle, 'CTS Estimate');
    expect(read.showShipping, isTrue);
    expect(read.shippingTaxable, isTrue);
    expect(read.shippingEach, {displayKey: 75});
    expect(read.sections.single.title, 'Deliverables');
    expect(read.sections.single.bulleted, isTrue);
    expect(read.sections.single.place, EstimateSectionPlace.beforePricing);
    expect(RoomCostSettings().pdfTitle, kDefaultEstimateTitle);
  });

  test('labor reports crew hours and total hours', () {
    final settings = RoomCostSettings(
      labor: [LaborLine(id: 'L1', rateId: '', techs: 2, hours: 8)],
    );
    final estimate = price(settings);
    expect(estimate.laborCrewHours, 8);
    expect(estimate.laborHours, 16);
    final labor = costReportSections(estimate)
        .firstWhere((s) => s.title == 'Labor');
    expect(labor.header, containsAll(['Crew', 'Crew hours', 'Total hours']));
    expect(laborHoursLabel(estimate), '8 crew h, 16 total h');
  });

  test('the PDF carries the title, the sections, shipping and hours', () async {
    final settings = RoomCostSettings(
      showShipping: true,
      shippingEach: {displayKey: 150},
      labor: [LaborLine(id: 'L1', rateId: '', techs: 2, hours: 8)],
    );
    final bytes = await buildEstimatePdf(
      price(settings),
      EstimatePdfInfo(
        roomName: 'Room 101',
        date: DateTime(2026, 9, 22),
        title: 'Audio Visual Estimate',
        sections: const [
          EstimateSection(
            id: 'S1',
            title: 'Deliverables',
            body: 'Drawings\nTraining',
            bulleted: true,
          ),
          // Empty sections print nothing.
          EstimateSection(id: 'S2'),
        ],
      ),
      compress: false,
    );
    final text = words(bytes);
    expect(text, contains('AUDIO VISUAL ESTIMATE'));
    expect(text, isNot(contains('ESTIMATE ROOM')));
    expect(text, contains('DELIVERABLES'));
    expect(text, contains('Training'));
    expect(text, contains('Crew hours'));
    expect(text, contains('Total hours'));
    expect(text, contains('Shipping'));
    expect(text, contains(r'$300.00'));
  });

  testWidgets('the catalog says when a filter hides a match', (tester) async {
    tester.view.physicalSize = const Size(1800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final provider = AppStateProvider(autoLoadSettings: false);
    provider.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(
          model: 'Old Lectern',
          retired: true,
          ports: [],
        ),
      );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: DeviceEditorView())),
      ),
    );
    await tester.pumpAndSettle();

    final search = find.widgetWithText(
      TextField,
      'Search model, maker, part number',
    );
    await tester.enterText(search, 'lectern');
    await tester.pumpAndSettle();
    expect(find.text('Old Lectern'), findsNothing);
    expect(find.byKey(const ValueKey('catalog_clear_filters')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('catalog_clear_filters')));
    await tester.pumpAndSettle();
    expect(find.text('Old Lectern'), findsOneWidget);

    // The X empties the box.
    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
  });

  testWidgets('every table gets a shipping box when shipping is on', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    final hardware = p.addAvCostExtraHardware();
    final cable = p.addAvCostExtraCable();
    final item = p.addAvCostItem();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(home: Scaffold(body: CostEstimateView())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('ship_${item.id}')), findsNothing);

    p.setAvCostShowShipping(true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final id in [hardware.id, cable.id, item.id]) {
      expect(find.byKey(ValueKey('ship_$id')), findsOneWidget, reason: id);
    }

    await tester.enterText(
      find.descendant(
        of: find.byKey(ValueKey('ship_${item.id}')),
        matching: find.byType(TextField),
      ),
      '25',
    );
    await tester.pumpAndSettle();
    expect(p.roomCost.shippingTotal, 25 * item.qty);
  });

  test('custom sections go into the Excel and text exports, in PDF order', () {
    final priced = costReportSections(price(RoomCostSettings()));
    const sections = [
      EstimateSection(
        id: 'S1',
        title: 'Deliverables',
        body: 'Drawings\n\nTraining',
        bulleted: true,
        place: EstimateSectionPlace.beforePricing,
      ),
      EstimateSection(id: 'S2', title: 'Exclusions', body: 'Painting'),
      // Nothing typed, nothing exported.
      EstimateSection(id: 'S3'),
    ];
    final all = withEstimateSections(
      priced,
      RoomCostSettings(
        scopeOfWork: 'Replace the projector',
        notes: 'Valid 30 days',
        sections: List.of(sections),
      ),
    );
    // Scope, the sections above the pricing, the pricing, the notes, the
    // sections below the totals - the PDF's order.
    expect(all[0].title, 'Scope of Work');
    expect(all[0].rows, [
      ['', 'Replace the projector'],
    ]);
    expect(all[1].title, 'Deliverables');
    expect(all[1].rows, [
      ['1', 'Drawings'],
      ['2', 'Training'],
    ]);
    expect(all[all.length - 2].title, 'Notes');
    expect(all.last.title, 'Exclusions');
    expect(all.last.rows, [
      ['', 'Painting'],
    ]);
    expect(all.length, priced.length + 4);
    // Nothing typed in scope or notes, nothing exported for them.
    expect(withEstimateSections(priced, RoomCostSettings()), priced);

    final text = renderTextReport('Room 101', all);
    expect(text.indexOf('Deliverables'), lessThan(text.indexOf('Totals')));
    expect(text.indexOf('Exclusions'), greaterThan(text.indexOf('Totals')));
    expect(text, contains('Training'));

    final sheet = buildStackedReportSheet(
      sheetName: 'Cost Estimate',
      title: 'Room 101',
      sections: all,
    );
    final cells = sheet.rows.expand((r) => r).map((c) => '$c').toList();
    expect(cells, containsAll(['Deliverables', 'Training', 'Painting']));
  });

  test('the Excel bands take the accent color', () {
    String styles(String? accent) {
      final bytes = buildXlsx([
        buildStackedReportSheet(
          sheetName: 'S',
          title: 'T',
          sections: const [
            (title: 'A', header: ['x'], rows: [
              ['1'],
            ]),
          ],
        ),
      ], accentHex: accent);
      final archive = ZipDecoder().decodeBytes(bytes);
      return utf8.decode(archive.findFile('xl/styles.xml')!.content as List<int>);
    }

    // Blank keeps the built-in blue.
    expect(styles(''), contains('FF1F4E79'));
    expect(styles(''), contains('FFD9E2F3'));
    // A dark accent: its own fill, white ink, a light tint for headers.
    final dark = styles('880E4F');
    expect(dark, contains('FF880E4F'));
    expect(dark, isNot(contains('FF1F4E79')));
    expect(dark, contains('<color rgb="FFFFFFFF"/>'));
    expect(XlsxTheme.headerFill('880E4F'), 'E7CFDC');
    // A light accent gets dark ink.
    expect(XlsxTheme.titleInk('FFEB3B'), '1F1F1F');
  });
}
