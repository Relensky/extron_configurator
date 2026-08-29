import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_logger.dart';
import 'package:extron_configurator/error_reporting.dart';

/// ============================================================================
///  UNHANDLED ERRORS REACH THE LOG
/// ============================================================================
///  A release build of this app is a double-clicked .exe with no console, so
///  Flutter's default "print it and carry on" put every unhandled error exactly
///  nowhere. These handlers are the only thing standing between an error and
///  that, which makes them worth pinning down: a handler that stops chaining,
///  stops writing, or starts throwing on its own would fail silently and by
///  definition nobody would see it.
///
///  THE LOG IS REDIRECTED. These tests write real entries, so setUpAll points
///  AppLogger at a temp folder of its own: not the repository, and not the
///  folder a developer's own app writes to.
/// ============================================================================

/// The error log these tests read back, wherever AppLogger was pointed.
File get _errorLog => File(AppLogger.errorLogPath);

/// Everything in the log once every queued write has landed.
Future<String> _logContents() async {
  await pendingErrorWrites();
  return _errorLog.existsSync() ? _errorLog.readAsStringSync() : '';
}

void main() {
  // What the process had before this file touched anything.
  late final FlutterExceptionHandler? originalOnError;
  late final ui.ErrorCallback? originalPlatformOnError;
  late final ErrorWidgetBuilder originalErrorWidgetBuilder;
  late final Directory logDir;

  // Everything the chained-to handler was handed.
  final chained = <FlutterErrorDetails>[];

  setUpAll(() {
    originalOnError = FlutterError.onError;
    originalPlatformOnError = ui.PlatformDispatcher.instance.onError;
    originalErrorWidgetBuilder = ErrorWidget.builder;
    logDir = Directory.systemTemp.createTempSync('error_reporting_test_');
    // Before the install, so the panel picks up this location too.
    AppLogger.logFolderForTest = logDir.path;

    // Stood in front of the install so the chaining can be observed — and so
    // that the errors raised below never reach flutter_test's own handler,
    // which would fail the test that raised them on purpose.
    FlutterError.onError = chained.add;
    installGlobalErrorHandlers();
  });

  tearDownAll(() async {
    await pendingErrorWrites();
    FlutterError.onError = originalOnError;
    ui.PlatformDispatcher.instance.onError = originalPlatformOnError;
    ErrorWidget.builder = originalErrorWidgetBuilder;
    try {
      logDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    chained.clear();
    // Otherwise the first report of a test could be collapsed into the last
    // report of the one before it.
    resetErrorDeduplication();
  });

  group('installing them', () {
    test('all three handlers are in place', () {
      expect(FlutterError.onError, isNotNull);
      expect(ui.PlatformDispatcher.instance.onError, isNotNull);
      expect(ErrorWidget.builder, isNotNull);
    });

    test('a second call does not chain a second copy of the handler', () {
      installGlobalErrorHandlers();
      installGlobalErrorHandlers();

      FlutterError.reportError(FlutterErrorDetails(
        exception: Exception('only once'),
        library: 'error_reporting_test',
      ));

      // Twice would mean the install had wrapped itself around its own
      // previous handler — the shape that turns a hot restart into a hall of
      // mirrors.
      expect(chained, hasLength(1));
    });
  });

  group('a widget that threw', () {
    test('still reaches the handler that was there before', () {
      final boom = Exception('painting went wrong');
      FlutterError.reportError(FlutterErrorDetails(
        exception: boom,
        library: 'error_reporting_test',
      ));
      expect(chained.single.exception, same(boom));
    });

    test('is written to the error log, with where it came from', () async {
      FlutterError.reportError(FlutterErrorDetails(
        exception: Exception('a marker for the widget case'),
        library: 'error_reporting_test',
        context: ErrorDescription('while building a test widget'),
      ));
      final log = await _logContents();
      expect(log, contains('a marker for the widget case'));
      // The context is the useful half: "something threw" is not a bug report,
      // "something threw while building X" is.
      expect(log, contains('while building a test widget'));
    });

    test('an error Flutter marked silent is not filed', () async {
      FlutterError.reportError(FlutterErrorDetails(
        exception: Exception('a marker that should stay out of the log'),
        library: 'error_reporting_test',
        silent: true,
      ));
      // It still reaches the handler that presents it...
      expect(chained, hasLength(1));
      // ...but does not land in the file.
      expect(await _logContents(),
          isNot(contains('a marker that should stay out of the log')));
    });
  });

  group('an error on a Future nobody awaited', () {
    test('is written to the log, and does not take the app down', () async {
      final handler = ui.PlatformDispatcher.instance.onError!;

      final handled = handler(
        Exception('a marker for the async case'),
        StackTrace.current,
      );

      // True means "dealt with". Returning false would let it go on to the
      // default handler, which in a release build ends the process — losing
      // the unsaved room over a catalog file that failed to reload.
      expect(handled, isTrue);
      expect(await _logContents(), contains('a marker for the async case'));
    });

    test('an error thrown while reporting one does not loop', () {
      // The recursion guard is only reachable by re-entering the reporter from
      // inside itself, which is what a logger in trouble would do.
      expect(
        () => reportUncaughtError('outer', StateError('inner'), null),
        returnsNormally,
      );
    });
  });

  group('a widget that throws on every frame', () {
    /// The log as it grew across [times] reports of the same failure.
    Future<String> repeat(String marker, int times) async {
      final before = (await _logContents()).length;
      for (var i = 0; i < times; i++) {
        reportUncaughtError('Widget error in a loop', Exception(marker), null);
      }
      return (await _logContents()).substring(before);
    }

    test('is filed twice and then held quiet', () async {
      final added = await repeat('a marker that repeats', 60);
      // Once for the error, once to say it is now repeating — and then
      // nothing, rather than sixty identical pages of it.
      expect('a marker that repeats'.allMatches(added), hasLength(2));
      expect(added, contains('further identical copies suppressed'));
    });

    test('and the count is recorded once something else goes wrong', () async {
      await repeat('the first failure', 5);
      reportUncaughtError('Widget error elsewhere',
          Exception('a different failure'), null);

      final log = await _logContents();
      expect(log, contains('The previous error repeated 4 more times'));
      expect(log, contains('a different failure'));
    });

    test('a different error is never collapsed into the one before it',
        () async {
      final before = (await _logContents()).length;
      reportUncaughtError('Widget error', Exception('distinct one'), null);
      reportUncaughtError('Widget error', Exception('distinct two'), null);
      final added = (await _logContents()).substring(before);
      expect(added, contains('distinct one'));
      expect(added, contains('distinct two'));
    });
  });

  group('what stands in for the widget that could not be drawn', () {
    final details = FlutterErrorDetails(
      exception: Exception('undrawable'),
      library: 'error_reporting_test',
    );

    test('a debug build keeps the box with the message on it', () {
      final widget = errorReplacementWidget(details, debug: true);
      // ErrorWidget paints straight onto its own render box rather than
      // building a Text, so the message is read off the widget.
      expect(widget, isA<ErrorWidget>());
      expect((widget as ErrorWidget).message, contains('undrawable'));
    });

    testWidgets('a release build explains itself and names the log',
        (tester) async {
      await tester.pumpWidget(errorReplacementWidget(details, debug: false));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('could not be drawn'), findsOneWidget);
      // The full path, not just the filename: somebody asked to send the log
      // has then been told where it is.
      expect(find.textContaining(AppLogger.errorLogPath), findsOneWidget);
      expect(AppLogger.errorLogPath, contains(logDir.path));
      // The exception text is NOT on it: this is the panel a user reads, and a
      // Dart stack trace is not something to hand somebody mid-job.
      expect(find.textContaining('undrawable'), findsNothing);
    });

    testWidgets('the panel survives a slot with no bounds of its own',
        (tester) async {
      // The broken widget could have been anywhere, including inside a Row,
      // where an unconstrained child that does not defend itself throws a
      // SECOND exception on top of the first.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            children: [errorReplacementWidget(details, debug: false)],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
