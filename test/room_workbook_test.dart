import 'dart:convert';

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
        },
        'SWITCHERDEVICE_1': {
          'name': 'Main Switcher',
          'model': 'Switcher Y',
          'com_type': 'Network',
          'ip_address': '10.0.0.5',
        },
        'dev_count': {'switcher': 1},
      };
    p.loadAvFlowForCurrentConfig();

    p.avDeviceLibrary = AvDeviceLibrary.empty()
      ..upsert(
        const AvDeviceTemplate(
          model: 'Switcher Y',
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

  test('the book has one tab per question, in order', () {
    final p = room();
    final archive = ZipDecoder().decodeBytes(
      buildRoomWorkbookBytes(provider: p, av: buildAvFlowModel(p)),
    );
    expect(tabNames(archive), kRoomWorkbookSheets);
    expect(kRoomWorkbookSheets, [
      'Control',
      'AV Flow',
      'Racks',
      'Cost Estimate',
    ]);
  });

  test('the control tab carries the config AND the power estimate', () {
    final p = room();
    final archive = ZipDecoder().decodeBytes(
      buildRoomWorkbookBytes(provider: p, av: buildAvFlowModel(p)),
    );
    final control = sheetText(archive, 1);

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
    final av = sheetText(archive, 2);
    expect(av, contains('Cable Schedule'));
    expect(av, contains('Pack List'));
    expect(av, contains('Switcher Y'));
  });

  test('the rack tab says how full and how hot each frame is', () {
    final p = room();
    final archive = ZipDecoder().decodeBytes(
      buildRoomWorkbookBytes(provider: p, av: buildAvFlowModel(p)),
    );
    final racks = sheetText(archive, 3);
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
    final cost = sheetText(archive, 4);

    expect(cost, contains('Equipment'));
    expect(cost, contains('Freight (4% of subtotal)'));
    expect(cost, contains('Sales tax (10%)'));
    // 2500 + 100 freight + 260 tax on 2600
    expect(cost, contains('<v>2860.0</v>'));
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
    expect(sheetText(archive, 3), contains('No rack frames'));
    expect(sheetText(archive, 4), contains('No devices on the diagram'));
  });
}
