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
    expect(sections.first.rows.first[4], 'Submitted to DPR');
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
    final ids = [
      for (final c in orderedProcurementColumns(['status', 'device'])) c.id,
    ];
    expect(ids.take(3), ['status', 'device', 'company']);
    expect(ids, hasLength(kProcurementColumnSpecs.length));

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
}
