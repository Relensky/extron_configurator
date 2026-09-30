import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/cost_estimate.dart';

/// Every estimate goes out with the standard terms on it.
void main() {
  test('blank notes become the terms', () {
    expect(withStandardEstimateNotes(''), kDefaultEstimateNotes);
    expect(withStandardEstimateNotes('  \n'), kDefaultEstimateNotes);
  });

  test('the terms carry the 60-day validity and the approval wording', () {
    expect(kDefaultEstimateNotes, contains('good for 60 days'));
    expect(kDefaultEstimateNotes, contains('arranged through FMS'));
    expect(kDefaultEstimateNotes, contains('separate TSRV request'));
  });

  test('the earlier wording is brought up to date, around what was added', () {
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
    final out = withStandardEstimateNotes('Lift needed.\n\n$older');
    expect(out, 'Lift needed.\n\n$kDefaultEstimateNotes');
  });

  test('notes somebody wrote are kept, with the terms after them', () {
    expect(
      withStandardEstimateNotes('Install over spring break.'),
      'Install over spring break.\n\n$kDefaultEstimateNotes',
    );
  });

  test('notes that already carry the terms are left alone', () {
    final notes = 'Intro.\n\n$kDefaultEstimateNotes';
    expect(withStandardEstimateNotes(notes), notes);
  });

  test('the exported notes section carries the terms', () {
    final sections = withEstimateSections(const [], RoomCostSettings());
    final notes = sections.firstWhere((s) => s.title == 'Notes');
    expect(notes.rows.expand((r) => r).join(' '), contains('60 days'));
  });
}
