import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/building_project.dart';
import 'package:extron_configurator/class_schedule.dart';
import 'package:extron_configurator/install_window_finder.dart';
import 'package:extron_configurator/install_windows.dart';
import 'package:extron_configurator/screenshot_tools.dart';

/// Install windows: when each room on the job is free, read off the
/// Facilities class schedule (the CTS-Dashboard's export), and the ones
/// picked put on the project's timeline.
void main() {
  // The export's own header and quoting, three rooms' worth of rows.
  const csv = '"TERM","COURSE_ID","CLASS_SUBJECT","CLASS_NUMBER",'
      '"CLASS_SECTION","ASSOCIATED_CLASS_NUMBER","CLASS_TITLE",'
      '"UNITS_COURSE_MAXIMUM","COMPONENT","CLASS_START_DATE","CLASS_END_DATE",'
      '"START_TIME1","END_TIME1","DAYS1","INSTRUCTOR1_EMPLID","ENROLLED_TOTAL",'
      '"ENROLLMENT_MAX","BUILDING","ROOM","COLLEGE_ID","COLLEGE",'
      '"DEPARTMENT_ID","DEPARTMENT_SDESC"\n'
      // BSS 103: MW 9:00-10:15 and MW 14:00-15:15, Jan 25 - May 21 2027.
      '"2272","1","SOCI"," 101","01","1","Intro Sociology","3.00","LEC",'
      '"25-JAN-27","21-MAY-27","09:00","10:15","MW","1","30","35","BSS","103",'
      '"31","BSS","1","SOCI"\n'
      '"2272","2","SOCI"," 202","01","1","Theory ""Classic""","3.00","LEC",'
      '"25-JAN-27","21-MAY-27","14:00","15:15","MW","1","30","35","BSS","103",'
      '"31","BSS","1","SOCI"\n'
      // An online section - never occupies a room.
      '"2272","3","AAST"," 152","01","1","Online","3.00","LEC","25-JAN-27",'
      '"21-MAY-27","","","TBA","1","30","35","WWW","ONLINE","31","BSS","1","X"\n'
      // CLSA 100A: one Tuesday, all day.
      '"2272","4","CHEM"," 999","01","1","Lab day","0.00","LAB","09-FEB-27",'
      '"09-FEB-27","07:30","16:30","T","1","1","1","CLSA","100A","1","X","1",'
      '"X"\n';

  group('reading the schedule', () {
    test('keeps in-person classes by room, drops online ones', () {
      final idx = ClassScheduleIndex.parse(csv);
      expect(idx.roomCount, 2);
      expect(idx.classesIn('BSS 103'), hasLength(2));
      expect(idx.classesIn('bss-103'), hasLength(2), reason: 'any spelling');
      expect(idx.classesIn('CLSA 100A'), hasLength(1));
      expect(idx.hasRoom('WWW ONLINE'), isFalse);
      expect(idx.terms, ['Spring 2027']);
      final c = idx.classesIn('BSS 103').last;
      expect(c.title, 'Theory "Classic"');
      expect(c.startMinutes, 14 * 60);
      expect(c.startDate, DateTime(2027, 1, 25));
    });

    test('CSU term codes and dates read like the dashboard reads them', () {
      expect(formatCsuTerm('2248'), 'Fall 2024');
      expect(formatCsuTerm('2226'), 'Summer 2022');
      expect(parseScheduleDate('23-JAN-23'), DateTime(2023, 1, 23));
      expect(parseScheduleDate('24-JAN-2022'), DateTime(2022, 1, 24));
      expect(parseScheduleMinutes('14:30'), 870);
      expect(formatScheduleMinutes(870), '2:30 pm');
    });
  });

  group('finding the gaps', () {
    final idx = ClassScheduleIndex.parse(csv);

    test('a teaching day has the stretches between classes', () {
      // Monday 1 Feb 2027: classes 9:00-10:15 and 14:00-15:15.
      final gaps = findInstallGaps(
        idx.classesIn('BSS 103'),
        from: DateTime(2027, 2, 1),
        to: DateTime(2027, 2, 1),
        minMinutes: 120,
      );
      expect(
        [for (final g in gaps) (g.startMinutes, g.endMinutes)],
        [(7 * 60, 9 * 60), (10 * 60 + 15, 14 * 60), (15 * 60 + 15, 22 * 60)],
      );
    });

    test('a day with nothing booked is one whole-day window', () {
      // Tuesday 2 Feb 2027 - BSS 103 only meets MW.
      final gaps = findInstallGaps(
        idx.classesIn('BSS 103'),
        from: DateTime(2027, 2, 2),
        to: DateTime(2027, 2, 2),
      );
      expect(gaps.single.wholeDay, isTrue);
    });

    test('weekends are left out unless asked for', () {
      // Sat 6 - Sun 7 Feb 2027.
      final off = findInstallGaps(
        idx.classesIn('BSS 103'),
        from: DateTime(2027, 2, 6),
        to: DateTime(2027, 2, 7),
      );
      expect(off, isEmpty);
      final on = findInstallGaps(
        idx.classesIn('BSS 103'),
        from: DateTime(2027, 2, 6),
        to: DateTime(2027, 2, 7),
        skipWeekends: false,
      );
      expect(on, hasLength(2));
    });

    test('shorter than the minimum is not a window', () {
      final gaps = findInstallGaps(
        idx.classesIn('CLSA 100A'),
        from: DateTime(2027, 2, 9),
        to: DateTime(2027, 2, 9),
        minMinutes: 60,
      );
      // 7:00-7:30 is too short; 16:30-22:00 is kept.
      expect([for (final g in gaps) g.startMinutes], [16 * 60 + 30]);
    });
  });

  test('each day carries its classes as well as its windows', () {
    final idx = ClassScheduleIndex.parse(csv);
    // Mon 1 - Tue 2 Feb 2027, with a section from another range ignored.
    final days = findRoomDays(
      idx.classesIn('BSS 103'),
      from: DateTime(2027, 2, 1),
      to: DateTime(2027, 2, 2),
    );
    expect(days, hasLength(2));
    expect([for (final c in days.first.classes) c.courseLabel],
        ['SOCI 101', 'SOCI 202']);
    expect(days.first.gaps, hasLength(3));
    expect(days.last.free, isTrue);
    expect(days.last.gaps.single.wholeDay, isTrue);
    // Before the term starts nothing meets.
    final before = findRoomDays(
      idx.classesIn('BSS 103'),
      from: DateTime(2027, 1, 18),
      to: DateTime(2027, 1, 22),
    );
    expect(before.every((d) => d.free), isTrue);
  });

  test('install windows survive the project file', () {
    final p = BuildingProject(name: 'Job');
    p.installWindows.add(InstallWindow.create(
      roomId: 'manual1',
      roomLabel: 'BSS 103',
      day: DateTime(2027, 2, 2),
      startMinutes: 7 * 60,
      endMinutes: 22 * 60,
      wholeDay: true,
    ));
    final back = BuildingProject.fromJson(p.toJson());
    expect(back.installWindows.single.roomLabel, 'BSS 103');
    expect(back.installWindows.single.day, DateTime(2027, 2, 2));
    expect(back.installWindows.single.wholeDay, isTrue);
  });

  testWidgets('clicking a gap puts it on the timeline, again takes it off',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('install_windows_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = path.join(dir.path, 'schedule.csv');
    File(file).writeAsStringSync(csv);

    final p = AppStateProvider(autoLoadSettings: false)
      ..classSchedulePath = file
      ..classSchedule = ClassScheduleIndex.parse(csv, source: file);
    p.newProject(name: 'Job');
    final room = p.addProjectManualRoom(name: 'BSS 103');

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: InstallWindowsCard())),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('find_install_windows')));
    await tester.pumpAndSettle();

    // The room the schedule knows about is ticked and has windows listed.
    expect(find.byKey(ValueKey('install_section_${room.id}')), findsOneWidget);
    final gap = find.byWidgetPredicate((w) =>
        w is FilterChip &&
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('install_gap_${room.id}_'));
    expect(gap, findsWidgets);

    await tester.tap(gap.first);
    await tester.pumpAndSettle();
    expect(p.project.installWindows, hasLength(1));
    expect(p.project.installWindows.single.roomLabel, 'BSS 103');
    expect(p.projectDirty, isTrue);

    await tester.tap(gap.first);
    await tester.pumpAndSettle();
    expect(p.project.installWindows, isEmpty);

    // Back on the timeline card, a picked window is listed.
    await tester.tap(gap.first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('install_finder_close')));
    await tester.pumpAndSettle();
    final w = p.project.installWindows.single;
    expect(find.byKey(ValueKey('install_window_${w.id}')), findsOneWidget);
  });

  testWidgets('the timeline draws classes as blocks and adds a free one',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final p = AppStateProvider(autoLoadSettings: false)
      ..classSchedule = ClassScheduleIndex.parse(csv);
    p.newProject(name: 'Job');
    final room = p.addProjectManualRoom(name: 'BSS 103');

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showInstallWindowFinder(context,
                    from: DateTime(2027, 2, 1)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('install_view_timeline')));
    await tester.pumpAndSettle();

    // Monday 1 Feb: both classes drawn, and the 10:15 - 2:00 gap clickable.
    expect(find.text('SOCI 101'), findsWidgets);
    expect(find.text('SOCI 202'), findsWidgets);
    final gap = find.byKey(ValueKey(
        'install_gap_${room.id}_${DateTime(2027, 2, 1).toIso8601String()}_${10 * 60 + 15}'));
    expect(gap, findsOneWidget);
    await tester.tap(gap);
    await tester.pumpAndSettle();
    final w = p.project.installWindows.single;
    expect((w.startMinutes, w.endMinutes), (10 * 60 + 15, 14 * 60));

    await tester.tap(gap);
    await tester.pumpAndSettle();
    expect(p.project.installWindows, isEmpty);

    // The List view lists the same gap as a chip.
    await tester.tap(find.byKey(const ValueKey('install_view_list')));
    await tester.pumpAndSettle();
    expect(find.text('10:15 am - 2:00 pm'), findsWidgets);
  });

  testWidgets('the timeline exports and screenshots', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    final p = AppStateProvider(autoLoadSettings: false)
      ..classSchedule = ClassScheduleIndex.parse(csv);
    p.newProject(name: 'Job');
    final room = p.addProjectManualRoom(name: 'BSS 103');
    // Monday 1 Feb 2027, 10:15 - 2:00, picked.
    p.addInstallWindow(InstallWindow.create(
      roomId: room.id,
      roomLabel: 'BSS 103',
      day: DateTime(2027, 2, 1),
      startMinutes: 10 * 60 + 15,
      endMinutes: 14 * 60,
    ));

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showInstallWindowFinder(context,
                    from: DateTime(2027, 2, 1)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('install_finder_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('install_export_copy')));
    await tester.pumpAndSettle();
    expect(copied, isNotNull);
    expect(copied, contains('Install windows - Job'));
    expect(copied, contains('Planned install windows'));
    expect(copied, contains('SOCI 101'));
    expect(copied, contains('Intro Sociology'));
    expect(copied, contains('Planned install window'));
    expect(copied, contains('Free all day'), reason: 'Tue 2 Feb is free');

    // The view is remembered for the session; the picture is of the timeline.
    await tester.tap(find.byKey(const ValueKey('install_view_timeline')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('install_finder_screenshot')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('install_capture_annotate')),
        findsOneWidget);
    expect(find.text('Timeline screenshot'), findsOneWidget);
    // The picture carries no how-to text: it goes to people outside the app.
    final picture = find.byType(ZoomablePicturePreview);
    expect(
      find.descendant(
          of: picture.first, matching: find.textContaining('Click')),
      findsNothing,
    );
    expect(
      find.descendant(of: picture.first, matching: find.text('SOCI 101')),
      findsWidgets,
    );
    await tester.tap(find.byKey(const ValueKey('install_capture_close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('install_capture_annotate')),
        findsNothing);
  });
}
