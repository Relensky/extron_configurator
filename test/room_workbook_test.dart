import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/room_workbook.dart';

/// One workbook for the whole job: a tab for the control system (with what
/// the room is estimated to draw), one for the AV signal path, one for the
/// racks, and one for the cost. Each is dealt from the same section builders
/// the single-sheet exports use, so the checks here are about the BOOK — that
/// every tab exists, in order, carrying the content its name promises.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {
          'gui_full_room_name': 'Bessey 103',
          'gve_bldg': 'BSS',
          'gve_room': '103',
          'dev_switchers': '1',
        },
        'SWITCHERDEVICE_1': {
          'name': 'Main Switcher',
          'model': 'Switcher Y',
          'com_type': 'Network',
          'ip_address': '10.0.0.5',
        },
      };
    p.loadAvFlowForCurrentConfig();

    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(
          model: 'Switcher Y',
          partNumber: '60-1234-01',
          rackUnits: 2,
          powerWatts: 90,
          price: 2500,
          ports: [],
        ),
      );

    p.addAvNode(
      const AvNode(
        id: 'SWITCHERDEVICE_1',
        label: 'Main Switcher',
        model: 'Switcher Y',
        pos: Offset(40, 60),
        fromConfig: true,
        rackUnits: 2,
        powerWatts: 90,
        ports: [],
      ),
    );
    final rack = p.addAvRack('Lectern rack', 12, kind: 'Lectern built-in rack');
    p.setAvRackSlot(
      'SWITCHERDEVICE_1',
      RackSlot(rackId: rack.id, startU: 3),
    );
    p.setAvCostTax(percent: 10);
    p.addAvCostFee(name: 'Freight', percent: 4);
    return p;
  }

  /// The workbook's sheet names, in the order Excel will show the tabs.
  List<String> tabNames(Archive archive) {
    final workbook = utf8.decode(
      archive.files.firstWhere((f) => f.name == 'xl/workbook.xml').content
          as List<int>,
    );
    return RegExp(r'<sheet name="([^"]+)"')
        .allMatches(workbook)
        .map((m) => m.group(1)!)
        .toList();
  }

  String sheetText(Archive archive, int oneBased) => utf8.decode(
    archive.files
            .firstWhere((f) => f.name == 'xl/worksheets/sheet$oneBased.xml')
            .content
        as List<int>,
  );

  /// A sheet by NAME. The book gains tabs — Locations landed between AV Flow
  /// and Racks — and every test pinned to sheet3.xml failed on that without
  /// anything being wrong with the sheet it meant.
  String sheetNamed(Archive archive, String name) =>
      sheetText(archive, kRoomWorkbookSheets.indexOf(name) + 1);

  test('the book has one tab per question, in order', () {
    final p = room();
    final archive = ZipDecoder().decodeBytes(
      buildRoomWorkbookBytes(provider: p, av: buildAvFlowModel(p)),
    );
    expect(tabNames(archive), kRoomWorkbookSheets);
    expect(kRoomWorkbookSheets, [
      'Control',
      'AV Flow',
      'Locations',
      'Racks',
      'Cost Estimate',
    ]);
  });

  test('the control tab carries the config AND the power estimate', () {
    final p = room();
    final archive = ZipDecoder().decodeBytes(
      buildRoomWorkbookBytes(provider: p, av: buildAvFlowModel(p)),
    );
    final control = sheetNamed(archive, 'Control');

    expect(control, contains('Bessey 103'));
    expect(control, contains('Main Switcher'));
    expect(control, contains('Power Estimate'));
    expect(control, contains('Power Schedule'));
    // 90 W at 120 V — the number an electrician is actually handed.
    expect(control, contains('Estimated current @ 120 V (A)'));
  });

  test('the AV tab carries the cable schedule and pack list', () {
    final p = room();
    final archive = ZipDecoder().decodeBytes(
      buildRoomWorkbookBytes(provider: p, av: buildAvFlowModel(p)),
    );
    final av = sheetNamed(archive, 'AV Flow');
    expect(av, contains('Cable Schedule'));
    expect(av, contains('Pack List'));
    expect(av, contains('Switcher Y'));
  });

  test('the rack tab says how full and how hot each frame is', () {
    final p = room();
    final archive = ZipDecoder().decodeBytes(
      buildRoomWorkbookBytes(provider: p, av: buildAvFlowModel(p)),
    );
    final racks = sheetNamed(archive, 'Racks');
    expect(racks, contains('Rack Summary'));
    expect(racks, contains('Lectern rack'));
    expect(racks, contains('Rack Inventory'));
    expect(racks, contains('U3-U4'));
  });

  test('the cost tab prices the room and shows the fee and the tax', () {
    final p = room();
    final archive = ZipDecoder().decodeBytes(
      buildRoomWorkbookBytes(provider: p, av: buildAvFlowModel(p)),
    );
    final cost = sheetNamed(archive, 'Cost Estimate');

    expect(cost, contains('Equipment'));
    expect(cost, contains('Freight (4% of subtotal)'));
    expect(cost, contains('Sales tax (10%)'));
    // 2500 + 100 freight + 260 tax on 2600
    expect(cost, contains('<v>2860.0</v>'));
  });

  test('money is a number Excel can sum, formatted as currency', () {
    final p = room();
    final archive = ZipDecoder().decodeBytes(
      buildRoomWorkbookBytes(provider: p, av: buildAvFlowModel(p)),
    );

    final styles = utf8.decode(
      archive.files.firstWhere((f) => f.name == 'xl/styles.xml').content
          as List<int>,
    );
    expect(styles, contains(r'formatCode="&quot;$&quot;#,##0.00"'));

    // The grand total: still <v>2860.0</v> — a figure that adds up — but
    // wearing one of the currency styles rather than reading as bare 2860.
    final total = RegExp(r'<c r="B\d+" s="(\d+)"><v>2860\.0</v></c>')
        .firstMatch(sheetNamed(archive, 'Cost Estimate'));
    expect(total, isNotNull, reason: 'the total is a numeric cell');
    expect(
      int.parse(total!.group(1)!),
      greaterThanOrEqualTo(5),
      reason: 'the currency styles start after the five row styles',
    );
  });

  test('every sheet says when it was produced', () {
    final p = room();
    final archive = ZipDecoder().decodeBytes(
      buildRoomWorkbookBytes(
        provider: p,
        av: buildAvFlowModel(p),
        generated: DateTime(2026, 8, 10, 14, 32),
      ),
    );
    for (int i = 1; i <= kRoomWorkbookSheets.length; i++) {
      expect(
        sheetText(archive, i),
        contains('Generated 2026-08-10 14:32'),
        reason: kRoomWorkbookSheets[i - 1],
      );
    }
  });

  test('the part number rides along with the model it belongs to', () {
    final p = room();
    final archive = ZipDecoder().decodeBytes(
      buildRoomWorkbookBytes(provider: p, av: buildAvFlowModel(p)),
    );
    expect(sheetNamed(archive, 'AV Flow'), contains('60-1234-01'));
    expect(sheetNamed(archive, 'Cost Estimate'), contains('60-1234-01'));
  });

  test('the rack elevation is embedded on the Racks sheet', () {
    // Only the IHDR is read (for the aspect ratio), so a header is enough to
    // stand in for a captured elevation here.
    Uint8List headerOnlyPng(int w, int h) {
      final bytes = BytesBuilder()
        ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..add(const [0, 0, 0, 13])
        ..add(utf8.encode('IHDR'))
        ..add((ByteData(8)..setUint32(0, w)..setUint32(4, h))
            .buffer
            .asUint8List())
        ..add(const [8, 6, 0, 0, 0]);
      return bytes.toBytes();
    }

    final p = room();
    final archive = ZipDecoder().decodeBytes(
      buildRoomWorkbookBytes(
        provider: p,
        av: buildAvFlowModel(p),
        rackPng: headerOnlyPng(1200, 800),
      ),
    );

    expect(
      archive.files.map((f) => f.name),
      contains('xl/media/image1.png'),
      reason: 'the elevation travels inside the book',
    );
    expect(
      sheetNamed(archive, 'Racks'),
      contains('<drawing'),
      reason: 'and hangs off the Racks sheet, under its tables',
    );
  });

  test('a room with no racks still gets a readable Racks tab', () {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Empty Room'},
      };
    p.loadAvFlowForCurrentConfig();

    final archive = ZipDecoder().decodeBytes(
      buildRoomWorkbookBytes(provider: p, av: buildAvFlowModel(p)),
    );
    expect(tabNames(archive), kRoomWorkbookSheets);
    expect(sheetNamed(archive, 'Racks'), contains('No rack frames'));
    expect(
      sheetNamed(archive, 'Cost Estimate'),
      contains('No devices on the diagram'),
    );
  });
}
