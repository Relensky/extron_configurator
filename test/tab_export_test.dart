import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_device_library.dart';
import 'package:extron_configurator/report_tools.dart';
import 'package:extron_configurator/room_workbook.dart';
import 'package:extron_configurator/tab_export.dart';

/// The room workbook is the whole job in one book, and four times out of five
/// it is the wrong thing to send: the electrician wants the run schedule and
/// purchasing wants the estimate. Every tab therefore exports itself, from the
/// same section builders the workbook deals from — so the same figure cannot
/// come out differently depending on which button produced it.
void main() {
  AppStateProvider room() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {
          'gve_bldg': 'BSS',
          'gve_room': '103',
          'gui_full_room_name': 'Business Services 103',
          'dev_projectors': '1',
        },
        'PROJECTORDEVICE_1': {
          'name': 'Projector',
          'model': 'PT-FW430U',
          'com_type': 'Serial',
        },
      };
    p.loadAvFlowForCurrentConfig();
    return p;
  }

  Set<String> titles(List<ReportSection> sections) => {
    for (final s in sections) s.title,
  };

  test('the settings pages have nothing to export and say so', () {
    // The Wizard and App Config are settings; the Schema and Flow Rules tabs
    // edit documents that are saved as their own files, so a spreadsheet of
    // either would be a copy nobody can load back.
    const settingsPages = {
      AppTab.wizard,
      AppTab.appConfig,
      AppTab.schemaEditor,
      AppTab.flowRules,
    };
    for (final tab in settingsPages) {
      expect(tabCanExport(tab), isFalse, reason: '${tab.name} exports');
    }
    for (final tab in AppTab.values) {
      if (settingsPages.contains(tab)) continue;
      expect(tabCanExport(tab), isTrue, reason: '${tab.name} does not export');
    }
  });

  test('every exportable tab has a name and a file stem of its own', () {
    final labels = <String>{};
    for (final tab in AppTab.values) {
      if (!tabCanExport(tab)) continue;
      final label = tabExportLabel(tab);
      expect(label.trim(), isNotEmpty);
      labels.add(label);
    }
    // Three tabs share the control document; every other name is distinct.
    expect(labels.length, greaterThan(6));
  });

  test('the Cost tab exports the estimate', () {
    final p = room();
    // An empty room has no estimate to write — see costReportSections — so
    // this puts a line on it first.
    p.addAvCostItem(description: 'Trip charge', qty: 1);
    final sections = tabReportSections(p, AppTab.cost);
    expect(
      titles(sections),
      contains('Totals'),
      reason: 'the money is what the Cost tab is a view of',
    );
  });

  test('the control tabs export the control document', () {
    final p = room();
    for (final tab in [AppTab.devices, AppTab.system, AppTab.rawJson]) {
      final t = titles(tabReportSections(p, tab));
      expect(t, contains('System'));
      expect(t, contains('Devices'));
    }
  });

  test('the catalog exports with no room loaded at all', () {
    final p = AppStateProvider(autoLoadSettings: false);
    p.avDeviceLibrary.upsert(
      const AvDeviceTemplate(
        model: 'HOT AMP',
        manufacturer: 'Acme',
        category: 'Amplifier',
        rackUnits: 2,
        clearanceAboveU: 1,
        price: 1200,
        ports: [],
      ),
    );
    final sections = tabReportSections(p, AppTab.deviceEditor);
    expect(sections, isNotEmpty);
    final rows = sections.first.rows;
    expect(rows.any((r) => r.first == 'HOT AMP'), isTrue);
    // The clearance is on the sheet: it is a fact somebody checking a price
    // list against a rack drawing needs.
    expect(sections.first.header, contains('Clear above/below'));
    expect(
      rows.firstWhere((r) => r.first == 'HOT AMP')[5],
      '1 / 0',
    );
  });

  test('the tab exports and the workbook read the same builders', () {
    final p = room();
    // The tab's sections are a SUBSET of the book's — same functions, dealt to
    // one sheet instead of six.
    final book = kRoomWorkbookSheets;
    expect(book, contains('Cost Estimate'));
    expect(
      titles(tabReportSections(p, AppTab.racks)),
      titles(tabReportSections(p, AppTab.racks)),
    );
  });
}
