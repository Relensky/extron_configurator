import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/procurement_log.dart';
import 'package:extron_configurator/project_procurement_view.dart';
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
}
