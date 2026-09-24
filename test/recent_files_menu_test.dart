import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart' show RoomConfigApp;
import 'package:extron_configurator/recent_files.dart';

/// ============================================================================
///  OPEN RECENT, ON SCREEN
/// ============================================================================
///  Two places show the list, and they answer two different people. The menu
///  in the title bar is for somebody mid-session who knows which document they
///  want; the panel on the start screen is for somebody who has just launched
///  the app and is deciding.
///
///  What is held here:
///
///    - THE KINDS ARE HEADED AND KEPT APART, in both places. One mixed list of
///      thirty is the thing this feature exists not to be.
///    - OPEN ITSELF IS STILL ONE PRESS. Making room for a list must never cost
///      everybody a click on the button they actually use.
///    - NOTHING IS SHOWN ON A COLD INSTALL, and the disabled button says why -
///      a grayed control with no explanation is one somebody keeps pressing.
/// ============================================================================
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('rcb_recent_ui'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// A real file, so the list does not draw it as gone.
  String file(String name) {
    final f = path.join(dir.path, name);
    File(f).writeAsStringSync(jsonEncode({'SYSTEM_SETUP': {}}));
    return f;
  }

  AppStateProvider fresh() => AppStateProvider(autoLoadSettings: false)
    ..settingsLoaded = true
    ..firstRunSetupNeeded = false;

  /// One of each kind on the list, which is the case both views are for.
  ///
  /// [midSession] stands a room up in the editor, which takes the start screen
  /// off - the title-bar menu and the start-screen panel draw the same names,
  /// and a finder that could match either would not be testing either.
  AppStateProvider withRecents({bool midSession = false}) {
    final p = fresh();
    if (midSession) p.roomConfig = {'SYSTEM_SETUP': {}};
    p.recentFiles
      ..remember(RecentKind.room, file('bss103.json'),
          name: 'Behavioral Science 103')
      ..remember(RecentKind.project, file('bessey_project.json'),
          name: 'Bessey Hall')
      ..remember(RecentKind.campus, file('chico_campus.json'),
          name: 'Chico campus');
    return p;
  }

  Future<void> pump(WidgetTester tester, AppStateProvider p) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: p,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pump();
  }

  /// Lets a "not there any more" bar run out.
  ///
  /// showTimedSnackBar arms a Timer a little past the bar's own duration, and
  /// a test that ends while it is still armed fails on a pending timer rather
  /// than on anything it was checking.
  Future<void> letTheSnackBarGo(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 8));
    await tester.pumpAndSettle();
  }

  group('the File menu', () {
    Future<void> openRecent(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('file_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('file_recent')));
      await tester.pumpAndSettle();
    }

    testWidgets('has New, Open and Open Recent, each opening to the side',
        (tester) async {
      await pump(tester, withRecents(midSession: true));
      await tester.tap(find.byKey(const ValueKey('file_menu')));
      await tester.pumpAndSettle();
      for (final key in ['file_new', 'file_open', 'file_recent',
          'file_download', 'file_upload']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      await tester.tap(find.byKey(const ValueKey('file_new')));
      await tester.pumpAndSettle();
      for (final key in ['file_new_room', 'file_new_project',
          'file_new_campus']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      for (final label in ['New Room', 'New Project', 'New Campus',
          'Download Config', 'Upload Config']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.byKey(const ValueKey('file_open')));
      await tester.pumpAndSettle();
      for (final key in ['file_open_room', 'file_open_project',
          'file_open_campus']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      for (final label in ['Open Room...', 'Open Project...',
          'Open Campus...']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('every line of the File menu is shown in full',
        (tester) async {
      final p = withRecents(midSession: true);
      // A long name, the case that used to be cut off at the menu's edge.
      p.recentFiles.remember(RecentKind.room, file('long.json'),
          name: 'Behavioral And Social Sciences Building Room 103 Lecture');
      await pump(tester, p);

      /// Every text line inside a menu item, against the item that holds it.
      void expectAllShownInFull(String where) {
        // The leaf items only: a submenu's own pop-out counts as its
        // descendant, so measuring its lines against it would be wrong.
        for (final button in tester.widgetList(find.byType(MenuItemButton))) {
          final item = find.byWidget(button);
          final itemRect = tester.getRect(item);
          for (final text in tester.widgetList<Text>(
              find.descendant(of: item, matching: find.byType(Text)))) {
            final render = tester.renderObject<RenderParagraph>(find
                .descendant(of: find.byWidget(text), matching: find.byType(RichText)));
            final full = render.getMaxIntrinsicWidth(double.infinity);
            final rect = tester.getRect(find.byWidget(text));
            expect(rect.width, greaterThanOrEqualTo(full - 0.5),
                reason: '"${text.data}" is squeezed ($where)');
            expect(rect.left + full, lessThanOrEqualTo(itemRect.right + 0.5),
                reason: '"${text.data}" runs past its item ($where)');
          }
        }
      }

      await tester.tap(find.byKey(const ValueKey('file_menu')));
      await tester.pumpAndSettle();
      expectAllShownInFull('File');
      for (final sub in ['file_new', 'file_open', 'file_recent']) {
        await tester.tap(find.byKey(ValueKey(sub)));
        await tester.pumpAndSettle();
        expectAllShownInFull(sub);
      }
    });

    testWidgets('Open Recent heads the three kinds and lists each under its '
        'own', (tester) async {
      await pump(tester, withRecents(midSession: true));
      await openRecent(tester);

      for (final heading in ['ROOMS', 'PROJECTS', 'CAMPUSES']) {
        expect(find.text(heading), findsOneWidget,
            reason: '$heading is what makes it three lists rather than one');
      }
      expect(find.text('Behavioral Science 103'), findsOneWidget);
      expect(find.text('Bessey Hall'), findsOneWidget);
      expect(find.text('Chico campus'), findsOneWidget);
      // ...each with its whole folder under it.
      expect(find.text(dir.path), findsNWidgets(3));
    });

    testWidgets('a kind nobody has opened is not an empty heading',
        (tester) async {
      final p = fresh()..roomConfig = {'SYSTEM_SETUP': {}};
      p.recentFiles.remember(RecentKind.room, file('a.json'), name: 'Room A');
      await pump(tester, p);
      await openRecent(tester);

      expect(find.text('ROOMS'), findsOneWidget);
      expect(find.text('PROJECTS'), findsNothing);
      expect(find.text('CAMPUSES'), findsNothing);
    });

    testWidgets('clearing the list empties it and touches no file',
        (tester) async {
      final p = withRecents(midSession: true);
      final room = p.recentFiles[RecentKind.room].single.file;
      await pump(tester, p);
      await openRecent(tester);
      await tester.tap(find.byKey(const ValueKey('file_recent_clear')));
      await tester.pumpAndSettle();

      expect(p.recentFiles.isEmpty, isTrue);
      expect(File(room).existsSync(), isTrue,
          reason: 'forgetting a document is not deleting it');
    });

    testWidgets('a cold install says there is nothing yet', (tester) async {
      await pump(tester, fresh()..roomConfig = {'SYSTEM_SETUP': {}});
      await openRecent(tester);
      expect(find.text('Nothing opened or saved yet'), findsOneWidget);
    });
  });

  group('the start screen', () {
    testWidgets('shows the three kinds in their own columns', (tester) async {
      await pump(tester, withRecents());

      expect(find.byKey(const ValueKey('start_recent')), findsOneWidget);
      for (final heading in ['Rooms', 'Projects', 'Campuses']) {
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('start_recent')),
            matching: find.text(heading),
          ),
          findsOneWidget,
        );
      }
      expect(find.text('Behavioral Science 103'), findsOneWidget);
    });

    testWidgets('a cold install shows nothing at all', (tester) async {
      // Three empty boxes on a first launch would be three questions about a
      // feature that has not had a chance to do anything yet.
      await pump(tester, fresh());
      expect(find.byKey(const ValueKey('start_recent')), findsNothing);
      // The two cards and the one Open button are still the whole screen.
      expect(find.byKey(const ValueKey('start_open_any')), findsOneWidget);
    });

    testWidgets('it sits under the Open button, not over the cards',
        (tester) async {
      await pump(tester, withRecents());
      final open = tester.getRect(find.byKey(const ValueKey('start_open_any')));
      final list = tester.getRect(find.byKey(const ValueKey('start_recent')));
      expect(list.top, greaterThan(open.bottom));
    });

    testWidgets('a file that has been moved is struck through, not dropped',
        (tester) async {
      // A SLOW SHARE MUST NOT EMPTY A HISTORY, and a line that silently did
      // nothing would be worse than one that says what happened.
      final p = withRecents();
      File(p.recentFiles[RecentKind.room].single.file).deleteSync();
      await pump(tester, p);

      expect(find.text('Behavioral Science 103'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('start_recent')),
          matching: find.text('Not there any more'),
        ),
        findsOneWidget,
      );
      expect(p.recentFiles[RecentKind.room], hasLength(1));
    });

    testWidgets('choosing a moved file offers to drop the line', (tester) async {
      final p = withRecents();
      final gone = p.recentFiles[RecentKind.room].single.file;
      File(gone).deleteSync();
      await pump(tester, p);

      await tester.tap(find.text('Behavioral Science 103'));
      // Settled, not merely pumped: the bar animates up from the bottom edge,
      // and its button is off the screen until it has finished arriving.
      await tester.pumpAndSettle();
      expect(find.textContaining('is not at'), findsOneWidget);
      // The line is still there until somebody says to drop it.
      expect(p.recentFiles[RecentKind.room], hasLength(1));

      await tester.tap(find.text('DROP IT'));
      await tester.pumpAndSettle();
      expect(p.recentFiles[RecentKind.room], isEmpty);
      expect(p.recentFiles[RecentKind.project], hasLength(1));
      await letTheSnackBarGo(tester);
    });

    testWidgets('choosing a room on the list opens it', (tester) async {
      // THE SAME PIPELINE AS OPEN. A room opened off this list has to be the
      // same room as one picked out of the file dialog.
      final p = withRecents();
      final room = p.recentFiles[RecentKind.room].single.file;
      await pump(tester, p);

      // runAsync because the load is REAL FILE I/O. A widget test runs in a
      // fake-async zone, where a Future waiting on the disk never completes -
      // so a plain tap here would sit forever on the read and report nothing
      // happening, which is not what the button does on a machine.
      await tester.runAsync(() async {
        await tester.tap(find.text('Behavioral Science 103'));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();

      expect(p.currentConfigPath, room);
      expect(p.roomConfig, isNotEmpty);
      // And the room it just opened is on the list once, at the top - the same
      // load as Open, so the same bookkeeping.
      expect(p.recentFiles[RecentKind.room], hasLength(1));
    });
  });
}
