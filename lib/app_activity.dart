import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/widgets.dart';

/// ============================================================================
///  AWAY: THE WINDOW IS MINIMIZED OR HIDDEN, OR THE PC IS LOCKED
/// ============================================================================
///  Nobody is looking, so the background polling of the share (who else has
///  the room open, chat, "working on" tags) pauses and animations stop. The
///  presence heartbeat slows down rather than stopping, so colleagues still
///  see this copy as open. Coming back refreshes everything at once.
///
///  Windows does not tell a Flutter app about the lock screen, so it is
///  checked every few seconds: while the session is locked, the input
///  desktop cannot be opened.
/// ============================================================================
class AppActivity extends ChangeNotifier with WidgetsBindingObserver {
  AppActivity._();

  static final AppActivity instance = AppActivity._();

  /// True while nobody can be looking at the app.
  static bool get away => instance._hidden || instance._locked;

  /// How often the lock screen is checked for.
  static const Duration lockCheck = Duration(seconds: 5);

  bool _hidden = false;
  bool _locked = false;
  bool _started = false;
  Timer? _timer;

  bool get hidden => _hidden;
  bool get locked => _locked;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) {
      _timer = Timer.periodic(lockCheck, (_) => _setLocked(_sessionLocked()));
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _started = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setHidden(switch (state) {
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => true,
      _ => false,
    });
  }

  /// For tests and the lifecycle observer.
  void setHidden(bool value) {
    if (_hidden == value) return;
    final was = away;
    _hidden = value;
    if (away != was) notifyListeners();
  }

  /// For tests and the lock check.
  void setLocked(bool value) => _setLocked(value);

  void _setLocked(bool value) {
    if (_locked == value) return;
    final was = away;
    _locked = value;
    if (away != was) notifyListeners();
  }

  static final DynamicLibrary? _user32 = () {
    try {
      return Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;
    } catch (_) {
      return null;
    }
  }();

  static final int Function(int, int, int)? _openInputDesktop = () {
    try {
      return _user32?.lookupFunction<IntPtr Function(Uint32, Int32, Uint32),
          int Function(int, int, int)>('OpenInputDesktop');
    } catch (_) {
      return null;
    }
  }();

  static final int Function(int)? _closeDesktop = () {
    try {
      return _user32?.lookupFunction<Int32 Function(IntPtr),
          int Function(int)>('CloseDesktop');
    } catch (_) {
      return null;
    }
  }();

  /// True while Windows shows the lock screen (or the secure desktop).
  static bool _sessionLocked() {
    final open = _openInputDesktop;
    if (open == null) return false;
    // DESKTOP_SWITCHDESKTOP: refused while the session is locked.
    final desk = open(0, 0, 0x0100);
    if (desk == 0) return true;
    _closeDesktop?.call(desk);
    return false;
  }
}
