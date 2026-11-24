import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Windows sign-out and shutdown, which skip the window's X button and its
/// save prompt.
///
/// The runner refuses to end the session while [unsaved] is true (Windows
/// names the app on its "apps are preventing sign-out" screen) and calls
/// [onSessionEnding] so the app can write a recovery copy and ask to save.
class SessionEndGuard {
  SessionEndGuard({
    required this.listenable,
    required this.unsaved,
    required this.onSessionEnding,
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('rcb/session_end');

  /// Fires when [unsaved] may have changed.
  final Listenable listenable;
  final bool Function() unsaved;
  final Future<void> Function() onSessionEnding;
  final MethodChannel _channel;

  bool? _sent;

  /// Windows only; elsewhere there is no runner to hold the session.
  static bool get supported => !kIsWeb && Platform.isWindows;

  void start() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sessionEnding') await onSessionEnding();
      return null;
    });
    listenable.addListener(_update);
    _update();
  }

  void dispose() {
    listenable.removeListener(_update);
    _channel.setMethodCallHandler(null);
  }

  /// Tells the runner only when the answer changes.
  void _update() {
    final now = unsaved();
    if (now == _sent) return;
    _sent = now;
    unawaited(
      _channel.invokeMethod<void>('setUnsaved', now).catchError((_) {}),
    );
  }
}
