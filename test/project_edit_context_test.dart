import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';

void main() {
  tearDown(() => ProjectEdit.context = null);

  test('a change records who and where beside the login', () {
    ProjectEdit.context = () => (
          name: 'Derek Stanley',
          email: 'derek@example.edu',
          machine: 'CTS-PC7',
          room: 'BSS 103',
          tab: 'Cost',
        );
    final log = <ProjectEdit>[];
    appendEdit(log,
        itemKey: 'part:dtp', field: 'Lead time', summary: 'set to 6 weeks',
        user: 'dstanley');
    final e = ProjectEdit.fromJson(log.single.toJson());
    expect(e.user, 'dstanley');
    expect(e.name, 'Derek Stanley');
    expect(e.email, 'derek@example.edu');
    expect(e.machine, 'CTS-PC7');
    expect(e.room, 'BSS 103');
    expect(e.tab, 'Cost');
    expect(e.userLabel, 'Derek Stanley (dstanley)');
  });

  test('an older entry reads as the login alone', () {
    final e = ProjectEdit.fromJson({
      'itemKey': 'project',
      'field': 'Deadline',
      'summary': 'cleared',
      'user': 'jperez',
      'at': '2026-03-01T10:00:00',
    });
    expect(e.name, '');
    expect(e.userLabel, 'jperez');
    expect(e.toJson().containsKey('machine'), isFalse);
  });
}
