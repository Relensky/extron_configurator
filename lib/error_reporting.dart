import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app_logger.dart';

/// ============================================================================
///  WHERE A CRASH GOES
/// ============================================================================
///  Flutter reports an unhandled error by printing it to the console. A release
///  build of this app is a Windows executable somebody double-clicks, and it
///  has no console — so every error the app did not catch by hand went
///  precisely nowhere: not into deployment_app_error_log.txt, which is the file
///  this app asks people to send in, and not onto the screen, which showed a
///  gray rectangle where the page should have been.
///
///  That is the gap these three handlers close. They do not stop anything going
///  wrong; they make what went wrong land in the same log as everything the app
///  catches deliberately, so a report of "it went blank" arrives with the stack
///  trace attached instead of a description of a gray rectangle.
///
///  WHAT EACH ONE COVERS:
///
///    FlutterError.onError            a widget that threw while building,
///                                    laying out or painting.
///    PlatformDispatcher.onError      an error on a Future nobody awaited —
///                                    which this app has a lot of, deliberately
///                                    (see the `ignore: unawaited_futures`
///                                    block in app_state.dart's updateSetting).
///    ErrorWidget.builder             what stands in for the widget that could
///                                    not be drawn.
///
///  NOT runZonedGuarded. It used to be the only way to catch the second case,
///  and it means every line of main() runs inside a custom zone — which changes
///  where print, timers and the binding's own errors are delivered. Since
///  Flutter 3.3 PlatformDispatcher.onError catches root-zone errors directly,
///  which is the same coverage without the zone.
/// ============================================================================

/// True once [installGlobalErrorHandlers] has run, so a second call (a hot
/// restart, a test that installs them itself) does not chain a second copy of
/// every handler onto the first.
bool _installed = false;

/// Guards against a loop: an error raised while REPORTING an error would come
/// straight back through the same handler.
bool _reporting = false;

/// The log writes, chained one behind another.
///
/// [AppLogger] appends by opening the file, writing and closing it. Two of
/// those overlapping is a sharing violation on Windows, which AppLogger catches
/// and swallows — so the entry is simply lost, and the one thing a logger must
/// not do is lose an entry silently. A widget that throws throws on EVERY
/// frame, so overlapping writes are the normal case here rather than the
/// exotic one.
Future<void> _pending = Future<void>.value();

/// The last error filed, and how many identical ones have arrived since.
///
/// A broken build repeats at the frame rate. Sixty identical pages a second
/// is not a log anybody can read, and it is a lot of disk for one bug.
String? _lastSignature;
int _suppressed = 0;

/// Where the error log actually is, resolved once when the handlers go in.
///
/// Named on the panel below, so somebody asked to send the log has been told
/// where it is rather than left to guess. Resolved ONCE, and up front, because
/// the panel is built while the app is already failing and the last thing it
/// should do is call something that could fail again. The bare filename is the
/// fallback: it is still the right thing to search for.
String _errorLogLocation = 'deployment_app_error_log.txt';

/// Points every unhandled error at [AppLogger], and every undrawable widget at
/// a panel that says so.
///
/// Call from main() before runApp — an error thrown while the first frame is
/// being built is exactly the one worth having.
void installGlobalErrorHandlers() {
  if (_installed) return;
  _installed = true;

  try {
    _errorLogLocation = AppLogger.errorLogPath;
  } catch (_) {
    // Keep the filename-only fallback. Working out where a file is must never
    // be the reason error reporting failed to install.
  }

  // CHAINED, NOT REPLACED. The default handler is what prints the red
  // exception dump under `flutter run`, and a debug session that lost it in
  // exchange for a line in a text file would be a bad trade. Ours runs after
  // it, so the console keeps saying what it always said and the file gains
  // what it never had.
  final FlutterExceptionHandler? presentAsUsual = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    presentAsUsual?.call(details);
    // `silent` is Flutter's own marker for an error it has already accounted
    // for and does not want repeated. Honoring it here keeps the log readable
    // rather than filling it with duplicates of one failure.
    if (details.silent) return;
    reportUncaughtError(
      'Widget error in ${_where(details)}',
      details.exception,
      details.stack,
    );
  };

  ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    reportUncaughtError('Uncaught asynchronous error', error, stack);
    // Handled: the error is on the record, and taking the process down over a
    // catalog file that failed to reload would lose the unsaved room with it.
    return true;
  };

  ErrorWidget.builder = (FlutterErrorDetails details) =>
      errorReplacementWidget(details, debug: kDebugMode);
}

/// What is drawn in place of a widget that threw.
///
/// [debug] is [kDebugMode] in the app. Under `flutter run` that keeps the red
/// box with the exception printed on it, which is the thing a developer needs
/// and a user cannot read; a release build gets the panel instead.
///
/// Not reported from here — the framework calls FlutterError.onError before it
/// asks for a replacement widget, so anything logged here would be a duplicate.
/// [debug] is a parameter rather than a read of [kDebugMode] so that a test,
/// which always runs in debug, can still see the release panel.
@visibleForTesting
Widget errorReplacementWidget(
  FlutterErrorDetails details, {
  required bool debug,
}) =>
    debug ? ErrorWidget(details.exception) : _UndrawablePanel(_errorLogLocation);

/// Writes one unhandled error to the error log.
///
/// Public because it is also the honest thing for a `catch` that has nowhere
/// better to send what it caught.
void reportUncaughtError(String what, Object? error, StackTrace? stack) {
  if (_reporting) {
    // The logger itself is in trouble. debugPrint is the last resort it also
    // falls back to, and it cannot recurse.
    debugPrint('CRITICAL: error while reporting an error: $error');
    return;
  }
  _reporting = true;
  try {
    // The stack is left out of the signature on purpose: the same widget
    // failing on sixty consecutive frames throws from the same place with the
    // same message, and that is exactly the flood worth collapsing.
    final signature = '$what|$error';
    if (signature == _lastSignature) {
      _suppressed++;
      // Said once, so the log records that this is a loop rather than a
      // one-off, and then nothing more until something else goes wrong.
      if (_suppressed > 1) return;
      _write('$what (repeating; further identical copies suppressed)', error,
          stack);
      return;
    }
    if (_suppressed > 0) {
      _write('The previous error repeated $_suppressed more times', null, null);
    }
    _lastSignature = signature;
    _suppressed = 0;
    _write(what, error, stack);
  } finally {
    _reporting = false;
  }
}

/// Queues one entry behind whatever is already being written.
///
/// Not awaited by the caller: the handlers this runs from cannot be async, and
/// an entry still in flight is better than one dropped for want of somewhere to
/// await it. AppLogger swallows its own failures; the catchError is the belt to
/// that pair of braces, and keeps one failed write from breaking the chain for
/// every entry behind it.
void _write(String what, Object? error, StackTrace? stack) {
  _pending = _pending
      .then((_) => AppLogger.logError(what, error, stack))
      .catchError((Object _) {});
}

/// Waits for every queued entry to reach the file. For tests — nothing in the
/// app has anywhere to await this from, which is the whole reason for the
/// queue.
@visibleForTesting
Future<void> pendingErrorWrites() => _pending;

/// Forgets which error was last filed, so a test's first report is never
/// collapsed into a previous test's.
@visibleForTesting
void resetErrorDeduplication() {
  _lastSignature = null;
  _suppressed = 0;
}

/// The most specific description of where [details] came from that it carries:
/// the framework's own "while building X" phrase, else the library that
/// reported it.
String _where(FlutterErrorDetails details) {
  final context = details.context;
  if (context != null) {
    final described = context.toDescription().trim();
    if (described.isNotEmpty) return described;
  }
  final library = details.library?.trim();
  return (library == null || library.isEmpty) ? 'the widget tree' : library;
}

/// What stands where a widget could not be drawn, in a release build.
///
/// DELIBERATELY PRIMITIVE. This is built while the tree it belongs to is
/// already failing, in whatever slot the broken widget occupied, and it may
/// have no Material, no Theme and no Directionality above it — so it asks for
/// none of them, paints its own background, and states its own text style
/// rather than inheriting one. A clever panel here is a second exception on top
/// of the first.
class _UndrawablePanel extends StatelessWidget {
  const _UndrawablePanel(this.logPath);

  /// The error log's full path when it could be worked out, else its name.
  final String logPath;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      // The slot could be anything, including one with no bounds of its own.
      child: LimitedBox(
        maxWidth: 460,
        maxHeight: 220,
        child: Container(
          color: const Color(0xFF4A1D1A),
          padding: const EdgeInsets.all(16),
          alignment: Alignment.topLeft,
          child: Text(
            'This part of the page could not be drawn.\n\n'
            'What went wrong has been written to $logPath. Nothing has been '
            'saved over, and the rest of the app is still working. Switching '
            'tabs and coming back usually clears it.',
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFFFE2DE),
              fontSize: 13,
              height: 1.35,
              // Named explicitly because there is no DefaultTextStyle to
              // inherit from down here, and the fallback underlines text.
              decoration: TextDecoration.none,
              fontWeight: FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}
