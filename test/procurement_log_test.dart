import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/procurement_log.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// The AV procurement log issued to the contractor.
void main() {
  final entry = ProcurementEntry(
    id: 'proc1',
    company: 'OFCI',
    room: 'HIL 101',
    device: 'Shure MXA920',
    manufacturer: 'Shure',
    model: 'MXA920-S',
    partNumber: 'MXA920W-S',
    description: 'Ceiling microphone array',
    status: ProcurementStatus.submitted,
    statusTo: 'DPR',
    installPhase: 'After paint',
    leadTime: '3',
    p6Start: DateTime(2027, 3, 10),
    notes: 'Confirm color',
  );

  test('the status names who it went to', () {
    expect(entry.statusText, 'Submitted to DPR');
    expect(
      entry.copyWith(status: ProcurementStatus.approved).statusText,
      'Approved by DPR',
    );
    expect(
      entry.copyWith(status: ProcurementStatus.none, statusTo: '').statusText,
      '',
    );
  });

  test('on site four days before the P6 start', () {
    expect(entry.requiredOnSite, DateTime(2027, 3, 6));
    expect(entry.copyWith(clearP6Start: true).requiredOnSite, isNull);
  });

  test('survives the project file', () {
    final project = BuildingProject(procurement: [entry]);
    final back = BuildingProject.fromJson(project.toJson()).procurement.single;
    expect(back.toJson(), entry.toJson());
    expect([back.manufacturer, back.model, back.partNumber],
        ['Shure', 'MXA920-S', 'MXA920W-S']);
    expect(BuildingProject.fromJson(project.toJson()).nextProcurementId(),
        'proc2');
  });

  test('the spreadsheet has a section per room and the contractor\'s columns',
      () {
    final sections = procurementLogSections([
      entry,
      entry.copyWith(room: 'HIL 208'),
      entry.copyWith(device: 'Extron SF 228T Plus'),
    ]);
    expect(sections.map((s) => s.title), ['HIL 101', 'HIL 208']);
    expect(sections.first.header, kProcurementColumns);
    expect(sections.first.rows, hasLength(2));
    expect(
      sections.first.rows.first[kProcurementColumns.indexOf('Status')],
      'Submitted to DPR',
    );
    expect(buildXlsx([procurementLogSheet('HIL', [entry])]), isNotEmpty);
  });

  test('a date can be typed several ways', () {
    for (final typed in [
      '2027-03-10', '3/10/2027', '3/10/27', '10 Mar 2027', 'March 10, 2027',
    ]) {
      expect(parseTypedDate(typed), DateTime(2027, 3, 10), reason: typed);
    }
    expect(parseTypedDate('2/30/2027'), isNull);
    expect(parseTypedDate('soon'), isNull);
  });

  test('column colors are kept with the project and reach the spreadsheet', () {
    final project = BuildingProject(
      procurement: [entry],
      procurementColors: {'status': 0xFF123456},
    );
    final back = BuildingProject.fromJson(project.toJson());
    expect(back.procurementColors, {'status': 0xFF123456});

    final status = kProcurementColumnSpecs.firstWhere((c) => c.id == 'status');
    expect(procurementColumnColor(status, back.procurementColors), 0xFF123456);
    final company =
        kProcurementColumnSpecs.firstWhere((c) => c.id == 'company');
    expect(
      procurementColumnColor(company, back.procurementColors),
      ProcurementGroup.item.color,
    );
    // White on a dark color, dark on a light one.
    expect(procurementInkFor(0xFF123456), 0xFFFFFFFF);
    expect(procurementInkFor(0xFFFFE0B2), 0xFF1F2933);

    final archive = ZipDecoder().decodeBytes(
      buildXlsx([
        procurementLogSheet('HIL', [entry], colors: back.procurementColors),
      ]),
    );
    final styles = utf8.decode(
      archive.files.firstWhere((f) => f.name == 'xl/styles.xml').content
          as List<int>,
    );
    expect(styles, contains('FF123456'));
  });

  test('the columns go in the order the job keeps them', () {
    final ids = [for (final c in orderedProcurementColumns([])) c.id];
    expect(ids.take(6), [
      'device',
      'manufacturer',
      'model',
      'partNumber',
      'company',
      'room',
    ]);
    expect(ids, hasLength(kProcurementColumnSpecs.length));

    // A job ordered before these were built in gets them by the frozen
    // device column, ahead of the rest as the page and sheet show them.
    final saved = [
      'status',
      'company',
      'room',
      'device',
      for (final c in kProcurementColumnSpecs)
        if (!{'status', 'company', 'room', 'device', 'manufacturer', 'model',
            'partNumber'}.contains(c.id))
          c.id,
    ];
    final placed = [
      for (final c in orderedProcurementColumns(saved))
        if (c.id != kProcurementFixedColumn) c.id,
    ];
    expect(placed.take(5),
        ['manufacturer', 'model', 'partNumber', 'status', 'company']);
    expect(placed, hasLength(kProcurementColumnSpecs.length - 1));

    final sections = procurementLogSections([entry], order: ['status']);
    expect(sections.single.header.first, 'Status');
    expect(sections.single.rows.single.first, 'Submitted to DPR');

    final project = BuildingProject(procurementColumnOrder: ['notes']);
    expect(
      BuildingProject.fromJson(project.toJson()).procurementColumnOrder,
      ['notes'],
    );
  });

  test('a renamed column keeps its name in the project and the export', () {
    final project = BuildingProject(
      procurementColumnLabels: {'status': 'Submittal status'},
    );
    final back = BuildingProject.fromJson(project.toJson());
    expect(back.procurementColumnLabels, {'status': 'Submittal status'});

    final sections = procurementLogSections(
      [entry],
      labels: back.procurementColumnLabels,
    );
    expect(sections.single.header, contains('Submittal status'));
    expect(sections.single.header, isNot(contains('Status')));
    expect(sections.single.header, contains('Company'));
  });

  group('deleted and added columns', () {
    test('a deleted column leaves the sheet, the device column never does',
        () {
      final project = BuildingProject(
        procurement: [entry],
        procurementHiddenColumns: ['status', 'device'],
      );
      final ids = [for (final c in project.procurementColumns) c.id];
      expect(ids, isNot(contains('status')));
      expect(ids, contains('device'));

      final sections = procurementLogSections(
        [entry],
        columns: project.procurementColumns,
      );
      expect(sections.single.header, isNot(contains('Status')));
      expect(sections.single.rows.single, isNot(contains('Submitted to DPR')));
    });

    test('an added column comes after the others, with each line\'s value',
        () {
      final line = entry.copyWith(custom: {'custom1': 'Q-1042'});
      final project = BuildingProject(
        procurement: [line],
        procurementCustomColumns: [(id: 'custom1', label: 'Quote #')],
      );
      final columns = project.procurementColumns;
      expect(columns.last.id, 'custom1');
      expect(columns.last.label, 'Quote #');

      final sections = procurementLogSections([line], columns: columns);
      expect(sections.single.header.last, 'Quote #');
      expect(sections.single.rows.single.last, 'Q-1042');
      expect(
        buildXlsx([procurementLogSheet('HIL', [line], columns: columns)]),
        isNotEmpty,
      );
      expect(project.nextProcurementColumnId(), 'custom2');
    });

    test('both are kept with the project', () {
      final project = BuildingProject(
        procurement: [entry.copyWith(custom: {'custom1': 'Q-1042'})],
        procurementHiddenColumns: ['review'],
        procurementCustomColumns: [(id: 'custom1', label: 'Quote #')],
      );
      final back = BuildingProject.fromJson(project.toJson());
      expect(back.procurementHiddenColumns, ['review']);
      expect(back.procurementCustomColumns.single.label, 'Quote #');
      expect(back.procurement.single.custom, {'custom1': 'Q-1042'});
      expect(back.clone().procurementCustomColumns, hasLength(1));
    });

    test('an added column can be moved among the built-in ones', () {
      final project = BuildingProject(
        // Moving a column saves every column's place.
        procurementColumnOrder: [
          'custom1',
          for (final c in kProcurementColumnSpecs) c.id,
        ],
        procurementCustomColumns: [(id: 'custom1', label: 'Quote #')],
      );
      expect(
        [for (final c in project.procurementColumns) c.id].take(2),
        ['custom1', 'device'],
      );
    });
  });
  group('sorting', () {
    const a = ProcurementEntry(id: 'a', room: 'Rm 10', device: 'Switcher');
    const b = ProcurementEntry(
      id: 'b',
      room: 'Rm 9',
      device: 'Switcher',
      status: ProcurementStatus.released,
    );
    const c = ProcurementEntry(
      id: 'c',
      room: 'Rm 9',
      device: 'Display',
      status: ProcurementStatus.submitted,
    );
    const d = ProcurementEntry(id: 'd', room: 'Rm 10', device: '');

    test('by room runs A-Z, however late a room first appears', () {
      const e = ProcurementEntry(id: 'e', room: 'Rm 9A', device: 'Mic');
      expect(
        [
          for (final g
              in procurementGrouped([e, a, b, c, d], ProcurementSort.room))
            g.room,
        ],
        ['Rm 9', 'Rm 9A', 'Rm 10'],
      );
    });

    test('by device runs A-Z, blanks last, rooms in number order', () {
      final g = procurementGrouped([a, b, c, d], ProcurementSort.device);
      expect([for (final x in g) x.room], ['Display', 'Switcher', '']);
      expect([for (final e in g[1].entries) e.id], ['b', 'a']);
    });

    test('by status goes in workflow order', () {
      final g = procurementGrouped([a, b, c], ProcurementSort.status);
      expect([for (final x in g) x.room], ['Submitted', 'Released', '']);
    });
  });
}
