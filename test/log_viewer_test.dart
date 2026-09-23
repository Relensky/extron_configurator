import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/log_viewer/log_viewer.dart';
import 'package:extron_configurator/log_viewer/log_viewer_platform.dart';

/// lib/log_viewer/ is shared by the five CTS apps; this test is too, with only
/// the package name above changed. See log_viewer_types.dart.
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('log_viewer_test'));
  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File write(String name, String text, {DateTime? modified}) {
    final f = File('${temp.path}${Platform.pathSeparator}$name')
      ..writeAsStringSync(text);
    if (modified != null) f.setLastModifiedSync(modified);
    return f;
  }

  LogViewerConfig config({ChooseSavePath? choose, String? current}) =>
      LogViewerConfig(
        appName: 'Test App',
        version: '9.9.9+9',
        sources: [
          LogSource.folder(temp.path,
              label: 'Debug log', include: (n) => n.endsWith('.log')),
        ],
        currentLogPath: current == null ? null : () => current,
        chooseSavePath: choose,
      );

  group('filtering', () {
    const lines = [
      '09:00 [app] session started',
      '09:01 [data] Loaded 12 rooms',
      '09:02 [crash] StateError: boom',
      '09:03 WARN the share is slow',
    ];

    test('search ignores spacing and case', () {
      expect(filterLogLines(lines, 'loaded12'), [1]);
      expect(filterLogLines(lines, 'LOADED 12 ROOMS'), [1]);
    });

    test('Problems only keeps errors, crashes and warnings', () {
      expect(filterLogLines(lines, '', problemsOnly: true), [2, 3]);
      expect(filterLogLines(lines, 'share', problemsOnly: true), [3]);
    });

    test('nothing typed shows everything', () {
      expect(filterLogLines(lines, ''), [0, 1, 2, 3]);
    });
  });

  test('export names say which app and when', () {
    final now = DateTime(2026, 9, 23, 14, 5);
    expect(suggestedLogExportName('CTS Dashboard', now: now),
        'CTS_Dashboard_logs_2026-09-23_1405.txt');
    expect(
        suggestedLogExportName('Quizzer',
            fileName: 'quizzer-2026-09-23.log', now: now),
        'Quizzer_quizzer_2026_09_23_2026-09-23_1405.txt');
  });

  group('finding and reading files', () {
    test('only included files, the current one first, then newest first', () {
      write('old.log', 'a', modified: DateTime(2026, 1, 1));
      write('new.log', 'b', modified: DateTime(2026, 9, 1));
      final current =
          write('current.log', 'c', modified: DateTime(2025, 1, 1));
      write('crash.dmp', 'binary');

      final files = listLogFiles(config().sources, currentPath: current.path);
      expect([for (final f in files) f.name],
          ['current.log', 'new.log', 'old.log']);
      expect(files.first.isCurrent, isTrue);
      expect(files.first.label, 'Debug log');
    });

    test('a single-file source, and one that does not exist', () {
      final f = write('debug_log.txt', 'x');
      final files = listLogFiles([
        LogSource.file(f.path, label: 'Debug log'),
        LogSource.file('${temp.path}/missing.txt', label: 'Gone'),
        const LogSource.folder('Z:/no/such/folder', label: 'Nowhere'),
      ]);
      expect(files, hasLength(1));
    });

    test('a long file is read from its end, starting on a whole line', () {
      final f = write('big.log',
          [for (var i = 0; i < 2000; i++) 'line $i'].join('\n'));
      final text = readLogText(f.path, maxBytes: 100);
      expect(text.truncated, isTrue);
      expect(text.text, endsWith('line 1999'));
      expect(text.text.split('\n').first, startsWith('line '));
      expect(text.totalBytes, f.lengthSync());
    });
  });

  test('an export starts with the app, version and computer', () {
    write('a.log', 'first file line\n', modified: DateTime(2026, 9, 1));
    write('b.log', 'second file line\n', modified: DateTime(2026, 9, 2));
    final c = config();
    final bundle = buildLogBundle(c, listLogFiles(c.sources));
    expect(bundle, contains('Test App 9.9.9+9'));
    expect(bundle, contains('Computer: '));
    expect(bundle, contains('----- b.log (Debug log) -----'));
    expect(bundle, contains('first file line'));
    expect(bundle, contains('second file line'));
    expect(bundle.indexOf('b.log (Debug'), lessThan(bundle.indexOf('a.log (Debug')),
        reason: 'newest first');
  });

  group('the dialog', () {
    Future<void> open(WidgetTester tester, LogViewerConfig c) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: LogViewerDialog(config: c)),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the newest file, and searching narrows it',
        (tester) async {
      write('old.log', 'old stuff\n', modified: DateTime(2026, 1, 1));
      write('new.log', 'alpha one\nbeta two\nERROR gamma\n',
          modified: DateTime(2026, 9, 1));
      await open(tester, config());

      expect(find.text('new.log'), findsOneWidget);
      expect(find.text('old.log'), findsOneWidget);
      expect(find.text('beta two'), findsOneWidget);
      expect(find.text('3 lines'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'betatwo');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('beta two'), findsOneWidget);
      expect(find.text('alpha one'), findsNothing);
      expect(find.text('1 of 3 lines'), findsOneWidget);

      await tester.tap(find.text('old.log'));
      await tester.pumpAndSettle();
      expect(find.text('No lines match.'), findsOneWidget);
    });

    testWidgets('Copy this file puts it, with its header, on the clipboard',
        (tester) async {
      write('new.log', 'something to send\n');
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await open(tester, config());
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy this file'));
      await tester.pumpAndSettle();

      expect(copied, contains('Test App 9.9.9+9'));
      expect(copied, contains('something to send'));
      expect(find.textContaining('Copied'), findsOneWidget);
    });

    testWidgets('Export writes where the Save dialog said', (tester) async {
      write('new.log', 'exported line\n');
      final target = '${temp.path}${Platform.pathSeparator}out';
      String? suggested;
      await open(
          tester,
          config(choose: (name) async {
            suggested = name;
            return target; // no .txt: the viewer adds it
          }));

      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export all recent logs…'));
      await tester.pumpAndSettle();

      expect(suggested, startsWith('Test_App_logs_'));
      final out = File('$target.txt');
      expect(out.existsSync(), isTrue);
      expect(out.readAsStringSync(), contains('exported line'));
      expect(find.textContaining('Saved to'), findsOneWidget);
    });

    testWidgets('a cancelled Save dialog writes nothing', (tester) async {
      write('new.log', 'x\n');
      await open(tester, config(choose: (_) async => null));
      await tester.tap(find.text('Export'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export this file…'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Saved to'), findsNothing);
    });

    testWidgets('with no logs it says where it looked', (tester) async {
      await open(tester, config());
      expect(find.text('No log files found.'), findsOneWidget);
      expect(find.textContaining(temp.path), findsOneWidget);
    });

    testWidgets('it expands to fill the window', (tester) async {
      write('new.log', 'x\n');
      addTearDown(() => LogViewerDialog.expanded = false);
      await open(tester, config());
      await tester.tap(find.byTooltip('Expand to fill the window'));
      await tester.pumpAndSettle();
      final card = tester.getRect(find
          .descendant(of: find.byType(Dialog), matching: find.byType(Column))
          .first);
      expect(card.width, closeTo(1400 - 16, 0.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a narrow window swaps the list for a dropdown',
        (tester) async {
      write('new.log', 'x\n');
      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: LogViewerDialog(config: config())),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(DropdownButtonFormField<int>), findsOneWidget);
    });
  });
}
