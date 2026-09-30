import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/cost_estimate.dart';

/// The standard terms print as the estimate's Notice, not in its notes.
void main() {
  test('the terms carry the 60-day validity and the approval wording', () {
    expect(kDefaultEstimateNotes, contains('good for 60 days'));
    expect(kDefaultEstimateNotes, contains('arranged through FMS'));
    expect(kDefaultEstimateNotes, contains('separate TSRV request'));
  });

  test('the terms are taken out of a room\'s notes, around what was typed', () {
    expect(stripStandardEstimateNotes(kDefaultEstimateNotes), '');
    expect(
      stripStandardEstimateNotes(
        'Install over spring break.\n\n$kDefaultEstimateNotes',
      ),
      'Install over spring break.',
    );
    expect(stripStandardEstimateNotes('Lift needed.'), 'Lift needed.');
  });

  test('the earlier wording comes out too', () {
    const older =
        'Equipment costs are preliminary estimates and may vary depending on '
        'final product selection, availability, shipping costs, and applicable '
        'taxes. The miscellaneous materials allowance is intended to cover '
        'cables, surge protection, and other minor installation materials that '
        'may be required.\n'
        '\n'
        'This estimate does not include electrical, construction, or finish '
        'work, such as adding or relocating power outlets, installing conduit or '
        'surface raceway (Wiremold), patching, or painting. Where that work is '
        'needed it must be arranged through Facilities Management Services '
        '(FMS) and will be billed separately.\n'
        '\n'
        'This estimate assumes that existing network jacks and building cabling '
        'are active, correctly labeled, and in good working order. Jacks that '
        'need to be added, repaired, relocated, or activated will require a '
        'separate Telecommunications Services (TSRV) request at additional '
        'cost.\n'
        '\n'
        'Any additional work or materials beyond the scope described above, or '
        'site conditions discovered during installation, may result in '
        'additional costs.';
    expect(stripStandardEstimateNotes('Lift needed.\n\n$older'), 'Lift needed.');
  });

  test('a notice set in Settings comes out of the notes as well', () {
    expect(
      stripStandardEstimateNotes('Mine.\n\nOur terms.', notice: 'Our terms.'),
      'Mine.',
    );
  });

  test('room exports print the notice under its own heading', () {
    final sections = withEstimateSections(
      const [],
      RoomCostSettings(notes: 'Night work.\n\n$kDefaultEstimateNotes'),
      notice: kDefaultEstimateNotes,
    );
    final notes = sections.firstWhere((s) => s.title == 'Notes');
    expect(notes.rows.expand((r) => r).join(' ').trim(), 'Night work.');
    final notice = sections.firstWhere((s) => s.title == 'Notice');
    expect(notice.rows.expand((r) => r).join(' '), contains('60 days'));
  });

  test('the project workbook leaves the notice off', () {
    final sections = withEstimateSections(
      const [],
      RoomCostSettings(notes: kDefaultEstimateNotes),
    );
    expect(sections.where((s) => s.title == 'Notice'), isEmpty);
    expect(sections.where((s) => s.title == 'Notes'), isEmpty);
  });
}
