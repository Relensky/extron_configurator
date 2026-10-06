import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_logger.dart';

/// Writes down what the screen was doing, for the hangs nothing else catches.
///
/// Somebody reported the window freezing, going black, and being closed — and
/// the log showed only a tidy "window closed", because the app's own code was
/// still running fine; it was the drawing that had stopped. Flutter on Windows
/// can lose its GPU surface (sleep, a monitor change, a driver hiccup) and go
/// black while everything underneath carries on. This notes:
///
///  * a stall: a frame asked for and none drawn for [stallAfter], and when
///    drawing comes back;
///  * frames that took over a second to build or draw;
///  * the window being hidden, shown, or moved to a screen with a different
///    size or scale — the usual triggers;
///  * the last key pressed, so a close can be told apart: Alt+F4 shows up as
///    a key a moment before "window closed", the X button doesn't.
///
/// Brought over from the campus geo-guesser game, where it was written.
class DisplayWatch with WidgetsBindingObserver {
  DisplayWatch._();

  static final DisplayWatch instance = DisplayWatch._();

  static const stallAfter = Duration(seconds: 5);

  DateTime _lastFrame = DateTime.now();
  bool _stalled = false;
  Timer? _timer;
  String _lastMetrics = '';
  ({String key, DateTime at})? _lastKey;

  /// One line in the app log, unwaited: the watch must never hold up a
  /// frame to write it.
  static void _note(String text) => unawaited(AppLogger.logInfo(text));

  void start() {
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    HardwareKeyboard.instance.addHandler(_onKey);
    _lastMetrics = _describeMetrics();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _check());
  }

  void _onTimings(List<ui.FrameTiming> timings) {
    _lastFrame = DateTime.now();
    if (_stalled) {
      _stalled = false;
      _note('display: drawing again');
    }
    for (final t in timings) {
      final build = t.buildDuration, raster = t.rasterDuration;
      if (build > const Duration(seconds: 1) ||
          raster > const Duration(seconds: 1)) {
        _note(
          'display: slow frame, build ${build.inMilliseconds} ms, '
          'draw ${raster.inMilliseconds} ms',
        );
      }
    }
  }

  /// Once a second: a frame has been waiting longer than [stallAfter] and
  /// nothing has been drawn. Only while a frame is actually wanted — a still
  /// screen draws nothing and is not stalled.
  void _check() {
    final scheduler = SchedulerBinding.instance;
    final waiting =
        scheduler.hasScheduledFrame ||
        scheduler.schedulerPhase != SchedulerPhase.idle;
    // A minimised or hidden window draws nothing however many frames are
    // asked for; that is not a stall.
    // (Inactive is still on screen: just not the focused window.)
    final showing = switch (WidgetsBinding.instance.lifecycleState) {
      AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      _ => false,
    };
    if (!waiting || !showing) {
      _lastFrame = DateTime.now();
      return;
    }
    final since = DateTime.now().difference(_lastFrame);
    if (!_stalled && since > stallAfter) {
      _stalled = true;
      _note(
        'display: STALLED - no frame drawn for ${since.inSeconds} s while '
        'the app is running (${_describeMetrics()}, '
        'state ${WidgetsBinding.instance.lifecycleState?.name})',
      );
    }
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent) {
      final held = HardwareKeyboard.instance;
      final name = [
        if (held.isControlPressed) 'Ctrl',
        if (held.isAltPressed) 'Alt',
        if (held.isShiftPressed) 'Shift',
        if (held.isMetaPressed) 'Win',
        event.logicalKey.keyLabel,
      ].join('+');
      _lastKey = (key: name, at: DateTime.now());
    }
    return false; // only watching
  }

  /// For the "window closed" line: the last key, if it was pressed within
  /// the few seconds before. Empty otherwise.
  String lastKeyNote() {
    final k = _lastKey;
    if (k == null) return '';
    final ago = DateTime.now().difference(k.at);
    if (ago > const Duration(seconds: 3)) return '';
    return ' (last key ${k.key}, ${ago.inMilliseconds} ms before)';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _note('display: app ${state.name}');
  }

  @override
  void didChangeMetrics() {
    final now = _describeMetrics();
    if (now != _lastMetrics) {
      _note('display: window now $now (was $_lastMetrics)');
      _lastMetrics = now;
    }
  }

  String _describeMetrics() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return 'no window';
    final v = views.first;
    final size = v.physicalSize;
    String display;
    try {
      final d = v.display;
      display = '${d.size.width.round()}x${d.size.height.round()} '
          '@${d.refreshRate.round()} Hz';
    } on Object {
      display = 'no display';
    }
    return '${size.width.round()}x${size.height.round()} '
        'scale ${v.devicePixelRatio}, on $display';
  }

  void stop() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    HardwareKeyboard.instance.removeHandler(_onKey);
  }
}
