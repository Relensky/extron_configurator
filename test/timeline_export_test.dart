import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/project_schedule.dart';
import 'package:extron_configurator/timeline_export.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// The timeline written out: every date, and every note on the job list.
void main() {
  BuildingProject job() {
    final p = BuildingProject(name: 'HIL refresh');
    p.addTodo('chase Extron', due: DateTime(2026, 11, 3));
    p.addTodo('ring the dean');
    p.addTodo('order mounts', due: DateTime(2026, 10, 20));
    p.addTodo('confirm scope');
    p.setTodoState('todo2', ProjectTodoState.done, by: 'jsmith');
    p.setTodoState('todo4', ProjectTodoState.blocked);
    p.setTodoWaitingNote('todo4', 'the dean');
    p.deliveryDeadline = DateTime(2026, 12, 1);
    return p;
  }

  ProjectSchedule schedule(BuildingProject p) => ProjectSchedule(
    deadline: p.deliveryDeadline,
    asOf: DateTime(2026, 10, 1),
    lines: const [],
  );

  test('every note is on it, dated ones in date order, the rest after', () {
    final p = job();
    final entries = timelineEntries(schedule(p), p);
    final notes = [for (final e in entries) if (e.what == 'To do') e];
    expect(notes.map((e) => e.item), [
      'order mounts',
      'chase Extron',
      'ring the dean',
      'confirm scope',
    ]);
    expect(notes[2].status, startsWith('Done'));
    expect(notes[2].status, contains('jsmith'));
    expect(notes[3].status, 'Waiting on: the dean');
    expect(entries.any((e) => e.item == 'Delivery deadline'), isTrue);
    // The deadline sits among the dates, after the notes due before it.
    expect(
      entries.indexWhere((e) => e.item == 'Delivery deadline'),
      greaterThan(entries.indexWhere((e) => e.item == 'chase Extron')),
    );
  });

  test('the sheet and the list carry the dated and the undated', () {
    final p = job();
    final entries = timelineEntries(schedule(p), p);
    final sections = timelineSections(entries);
    expect(sections.map((s) => s.title), ['Dates', 'Job list - no date']);
    expect(sections.first.header, kTimelineColumns);
    expect(sections.last.rows, hasLength(2));

    expect(buildXlsx([timelineSheet(p.name, entries)]), isNotEmpty);
    final text = timelineText(p.name, entries);
    expect(text, startsWith('HIL refresh - Timeline'));
    for (final item in ['chase Extron', 'ring the dean', 'confirm scope']) {
      expect(text, contains(item));
    }
  });
}
