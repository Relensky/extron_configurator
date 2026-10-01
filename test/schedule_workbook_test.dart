import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/class_schedule.dart';
import 'package:extron_configurator/install_windows.dart';
import 'package:extron_configurator/report_tools.dart';
import 'package:extron_configurator/schedule_workbook.dart';
import 'package:extron_configurator/xlsx_writer.dart';

/// The Class Schedule tab: the install windows as a Gantt chart, each room's
/// week in half hours, and the classes behind them.
void main() {
  // ART 101 meets Mon/Wed 9-10:15 in ARTS 105 for fall 2026.
  final schedule = ClassScheduleIndex.parse(
    'TERM,CLASS_SUBJECT,CLASS_NUMBER,CLASS_TITLE,START_TIME1,END_TIME1,'
    'DAYS1,BUILDING,ROOM,CLASS_START_DATE,CLASS_END_DATE\n'
    '2268,ART,101,Drawing,09:00,10:15,MW,ARTS,105,24-AUG-26,11-DEC-26\n',
  );

  BuildingProject withWindows(List<InstallWindow> windows) =>
      BuildingProject(name: 'Test', installWindows: windows);

  InstallWindow window(DateTime day, int start, int end,
          {bool wholeDay = false}) =>
      InstallWindow(
        id: 'w$day$start',
        roomId: 'r1',
        roomLabel: 'ARTS 105 - Studio',
        day: day,
        startMinutes: start,
        endMinutes: end,
        wholeDay: wholeDay,
      );

  test('no maintenance windows, no tab', () {
    expect(classScheduleSections(withWindows([]), schedule), isEmpty);
  });

  test('the windows run day by day across the job', () {
    final sections = classScheduleSections(
      withWindows([
        window(DateTime(2026, 10, 5), 11 * 60, 13 * 60), // Mon
        window(DateTime(2026, 10, 10), 0, 24 * 60, wholeDay: true), // Sat
      ]),
      schedule,
    );
    final gantt = sections.first;
    expect(gantt.header.first, 'Room');
    expect(gantt.header.length, 1 + 6, reason: 'Oct 5 to Oct 10');
    expect(gantt.header[1], 'Mon 10/5');

    final row = gantt.rows.single;
    expect((row[1] as XlsxTint).text, '11a-1p');
    // Wednesday has a class and no window.
    expect(row[3], isA<XlsxTint>());
    expect((row[3] as XlsxTint).text, '');
    expect((row[6] as XlsxTint).text, 'All day');
    // Thursday has neither.
    expect(row[4], '');
  });

  test('the week shows the class and the window in their slots', () {
    final sections = classScheduleSections(
      withWindows([window(DateTime(2026, 10, 5), 11 * 60, 13 * 60)]),
      schedule,
    );
    final week = sections.firstWhere((s) => s.title == 'ARTS 105 - the week');
    expect(week.header[1], '7a');
    final monday = week.rows.first;
    expect(monday.first, 'Mon');
    int col(int minutes) => 1 + (minutes - 7 * 60) ~/ 30;
    expect((monday[col(9 * 60)] as XlsxTint).text, 'ART 101');
    expect(monday[col(10 * 60)], isA<XlsxTint>(), reason: 'still in class');
    expect(monday[col(10 * 60 + 30)], '');
    expect((monday[col(11 * 60)] as XlsxTint).text, 'Maint. 10/5');
    // Tuesday has neither.
    expect(week.rows[1].skip(1).every((c) => c == ''), isTrue);
  });

  test('the class list covers the terms the windows fall in', () {
    final sections = classScheduleSections(
      withWindows([window(DateTime(2026, 10, 5), 11 * 60, 13 * 60)]),
      schedule,
    );
    final classes = sections.last;
    expect(classes.rows.single.take(4), ['ARTS 105', 'ART 101', 'Drawing', 'MW']);

    // A window after the term ends lists nothing.
    final later = classScheduleSections(
      withWindows([window(DateTime(2027, 1, 4), 9 * 60, 12 * 60)]),
      schedule,
    ).last;
    expect(later.rows.single.single, contains('No classes meet'));
  });

  test('it writes as a sheet', () {
    final sheet = buildStackedReportSheet(
      sheetName: kClassScheduleSheet,
      title: 'Test - class schedule',
      sections: classScheduleSections(
        withWindows([window(DateTime(2026, 10, 5), 11 * 60, 13 * 60)]),
        schedule,
      ),
    );
    expect(buildXlsx([sheet]), isNotEmpty);
  });
}
