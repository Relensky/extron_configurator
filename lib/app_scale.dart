import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app_logger.dart';

// ============================================================================
// THE APP'S SIZE COMES FROM THE SCREEN, NOT WINDOWS' DISPLAY SCALING.
//
// The app is laid out as if every monitor were [AppScale.referenceSize]
// (1920 x 1080) and then scaled to fit the monitor it is on:
//
//   * 1080p at any Windows scale: the reference layout, pixel for pixel.
//   * 1440p / 4K: the same layout, drawn with more pixels - only sharper.
//   * a 1366 x 768 laptop: the same layout, scaled down to fit.
//
// Interface Size (App Config) is the zoom on top of that; 0 there leaves
// Windows' scaling in charge. Same as the CTS Dashboard's AppScaleFrame -
// windows/runner/utils.cpp AppFitScale must match [AppScale.scaleFor].
// ============================================================================

class AppScale extends StatefulWidget {
  const AppScale({
    super.key,
    required this.scale,
    required this.child,
    this.fitToMonitor = true,
  });

  /// Interface Size: 1.0 is the reference layout. 0 or less follows Windows.
  final double scale;
  final Widget child;

  /// False draws at [scale] physical pixels per layout pixel, whatever the
  /// monitor (tests, and any platform that does not report its monitor).
  final bool fitToMonitor;

  static const Size referenceSize = Size(1920, 1080);

  /// Never fit the layout below this: past it text is too small to read and
  /// Interface Size is the better tool.
  static const double minFit = 0.75;

  /// True while the window is being dragged or resized (the runner's
  /// WM_ENTERSIZEMOVE .. WM_EXITSIZEMOVE). The fit is held from the start of
  /// the drag to its end, so crossing between monitors re-lays-out the app
  /// once, when it is let go, rather than at every crossing.
  static final ValueNotifier<bool> windowMoving = ValueNotifier(false);

  /// Physical pixels per layout pixel for a monitor of [screen] physical
  /// pixels at [zoom]; null when the monitor size is unknown.
  static double? scaleFor(Size screen, double zoom) {
    if (screen.isEmpty) return null;
    // Either way up: a portrait monitor is as big as a landscape one.
    final double long = math.max(screen.width, screen.height);
    final double short = math.min(screen.width, screen.height);
    final double fit = math.min(
        long / referenceSize.width, short / referenceSize.height);
    return math.max(fit, minFit) * zoom;
  }

  /// Hears the runner's drag start and end on the window channel. Call once.
  static void listenForWindowMoves() {
    const MethodChannel('rcb/window_chrome').setMethodCallHandler((call) async {
      if (call.method == 'moveStarted') windowMoving.value = true;
      if (call.method == 'moveEnded') windowMoving.value = false;
      return null;
    });
  }

  static String? _lastLogged;

  static void _logOnce(Size screen, double windowsScale, double target) {
    final String line = 'UI scale: monitor ${screen.width.round()}x'
        '${screen.height.round()}, Windows at '
        '${(windowsScale * 100).round()}% (ignored), app scale '
        '${(target * 100).round()}%';
    if (line == _lastLogged) return;
    _lastLogged = line;
    AppLogger.logUi(line);
  }

  @override
  State<AppScale> createState() => _AppScaleState();
}

class _AppScaleState extends State<AppScale> {
  /// The monitor the fit was last worked out for, held through a drag.
  Size? _heldScreen;

  @override
  void initState() {
    super.initState();
    AppScale.windowMoving.addListener(_onMoving);
  }

  @override
  void dispose() {
    AppScale.windowMoving.removeListener(_onMoving);
    super.dispose();
  }

  void _onMoving() {
    // Let go: rebuild once against the monitor the window ended up on.
    if (!AppScale.windowMoving.value && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final child = widget.child;
    if (widget.scale <= 0 || mq.devicePixelRatio <= 0) return child;

    double target = widget.scale;
    if (widget.fitToMonitor) {
      Size screen = Size.zero;
      try {
        screen = View.of(context).display.size;
      } catch (_) {}
      // Mid-drag, keep laying out for the monitor the drag started on.
      if (AppScale.windowMoving.value && _heldScreen != null) {
        screen = _heldScreen!;
      } else {
        _heldScreen = screen;
      }
      final fitted = AppScale.scaleFor(screen, widget.scale);
      if (fitted != null) {
        target = fitted;
        AppScale._logOnce(screen, mq.devicePixelRatio, target);
      }
    }

    // Flutter has already divided by Windows' scale; this undoes that and
    // applies ours instead.
    final factor = target / mq.devicePixelRatio;
    if ((factor - 1).abs() < 0.001) return child;
    final size = mq.size / factor;
    return MediaQuery(
      data: mq.copyWith(
        size: size,
        devicePixelRatio: target,
        padding: mq.padding / factor,
        viewPadding: mq.viewPadding / factor,
        viewInsets: mq.viewInsets / factor,
      ),
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: size.width,
          maxWidth: size.width,
          minHeight: size.height,
          maxHeight: size.height,
          child: Transform.scale(
            scale: factor,
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(size: size, child: child),
          ),
        ),
      ),
    );
  }
}
