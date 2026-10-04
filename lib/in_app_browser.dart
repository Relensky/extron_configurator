import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_windows/webview_windows.dart';

/// ============================================================================
///  A BROWSER INSIDE THE APP
/// ============================================================================
///  Web pages - a Google Sheet, a processor's touch panel page - open in a
///  window over the app instead of in the default browser, so the page and
///  the work it is about sit side by side. Several can be open at once. Each
///  floats - dragged by its title bar, resized from its corner - or is docked
///  to a side of the window and made larger from its inner edge; it can fill
///  the window or hand its page to the real browser.
///
///  It sits in the app's own navigator layer, beside dialogs and menus, so
///  it is placed and scaled the same way they are when the app is zoomed.
///
///  A resize is drawn as an outline while the pointer moves and applied once
///  it is let go: resizing the page itself on every movement is what made it
///  lag.
///
///  It is Microsoft Edge WebView2, which Windows 11 has built in. Sign-ins
///  are kept in [InAppBrowser.userDataFolder], so Google asks once. Turned off
///  in settings, or on a PC without WebView2, links open in the default
///  browser as before.
///
///  Google's own sign-in for the app (OAuth) always uses the real browser:
///  Google refuses it inside an embedded one.
/// ============================================================================

/// Where the browser sits: a floating window, or docked to one side of the
/// app's window, filling that side.
enum BrowserDock {
  floating('Floating window'),
  left('Left side'),
  right('Right side'),
  top('Top'),
  bottom('Bottom');

  final String label;
  const BrowserDock(this.label);

  static BrowserDock byName(Object? name) => BrowserDock.values
      .firstWhere((d) => d.name == name, orElse: () => BrowserDock.floating);

  IconData get icon => switch (this) {
        BrowserDock.floating => Icons.picture_in_picture_alt,
        BrowserDock.left => Icons.border_left,
        BrowserDock.right => Icons.border_right,
        BrowserDock.top => Icons.border_top,
        BrowserDock.bottom => Icons.border_bottom,
      };
}

class InAppBrowser {
  InAppBrowser._();

  /// Whether links open here. Set from the app's settings.
  static bool enabled = true;

  /// Where browsers sit - the app's setting. Windows already open follow a
  /// change to it.
  static final ValueNotifier<BrowserDock> dockSetting =
      ValueNotifier(BrowserDock.floating);

  static BrowserDock get dock => dockSetting.value;
  static set dock(BrowserDock value) => dockSetting.value = value;

  /// How much of the window a docked browser takes - dragged larger or
  /// smaller from its inner edge, and kept for the next one this session.
  static double dockFraction = 0.45;

  /// Where cookies and sign-ins are kept. Set by the app at start-up.
  static String userDataFolder = '';

  static bool? _available;
  static bool _environmentReady = false;
  static int _opened = 0;

  /// Whether WebView2 is on this PC. Never throws.
  static Future<bool> available() async {
    if (_available != null) return _available!;
    if (!Platform.isWindows) return _available = false;
    try {
      _available = (await WebviewController.getWebViewVersion()) != null;
    } catch (_) {
      _available = false;
    }
    return _available!;
  }

  /// Opens [url] in a browser over the app. False when it could not be, so
  /// the caller can fall back to the default browser.
  static Future<bool> open(BuildContext context, String url,
      {String? title}) async {
    if (!await available() || !context.mounted) return false;
    if (!_environmentReady && userDataFolder.isNotEmpty) {
      try {
        await Directory(userDataFolder).create(recursive: true);
        await WebviewController.initializeEnvironment(
            userDataPath: userDataFolder);
      } catch (_) {
        // Already set up by an earlier window, or the folder is read-only:
        // WebView2 then uses its default.
      }
      _environmentReady = true;
    }
    if (!context.mounted) return false;
    // The navigator's layer - where dialogs and menus go - so the window is
    // inside whatever zoom the app is drawn at, and its menus line up.
    final overlay = Navigator.maybeOf(context, rootNavigator: true)?.overlay ??
        Overlay.of(context);
    late OverlayEntry entry;
    final offset = Offset(60.0 + 28 * (_opened % 6), 80.0 + 28 * (_opened % 6));
    _opened++;
    entry = OverlayEntry(
      builder: (_) => _BrowserPanel(
        url: url,
        title: title,
        start: offset,
        onClose: () => entry.remove(),
      ),
    );
    overlay.insert(entry);
    return true;
  }
}

/// Opens a web link in the built-in browser when that is switched on and
/// works, and in the default browser otherwise. Anything that is not http(s)
/// - mailto:, tel:, a file - always goes to the system.
Future<bool> openWebLink(BuildContext context, String url,
    {String? title}) async {
  final u = url.trim();
  final web = u.startsWith('http://') || u.startsWith('https://');
  if (web && InAppBrowser.enabled) {
    if (await InAppBrowser.open(context, u, title: title)) return true;
  }
  try {
    return await launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

class _BrowserPanel extends StatefulWidget {
  final String url;
  final String? title;
  final Offset start;
  final VoidCallback onClose;

  const _BrowserPanel({
    required this.url,
    required this.title,
    required this.start,
    required this.onClose,
  });

  @override
  State<_BrowserPanel> createState() => _BrowserPanelState();
}

class _BrowserPanelState extends State<_BrowserPanel> {
  final WebviewController _web = WebviewController();
  final TextEditingController _address = TextEditingController();
  final List<StreamSubscription> _subs = [];

  /// Where the floating window is and how big. A move changes only this, so
  /// the page inside is moved as it stands rather than rebuilt.
  late final ValueNotifier<Rect> _frame =
      ValueNotifier(widget.start & const Size(1000, 700));

  /// This window's share of the app's window when docked.
  final ValueNotifier<double> _fraction =
      ValueNotifier(InAppBrowser.dockFraction);

  /// The outline drawn while a resize is under way; applied when let go.
  final ValueNotifier<Rect?> _preview = ValueNotifier(null);
  double? _previewFraction;

  bool _full = false;

  /// This window's side, starting on the app's setting.
  late BrowserDock _dock = InAppBrowser.dock;

  bool get _docked => _dock != BrowserDock.floating;

  /// The space the window has: the layer it is drawn in, measured.
  Size _area = Size.zero;

  bool _ready = false;
  bool _loading = true;
  bool _canBack = false;
  bool _canForward = false;
  String _title = '';
  String _error = '';

  /// Where the window is drawn, docked or not, at docked share [f].
  Rect _rect([double? f]) {
    final w = _area.width;
    final h = _area.height;
    if (_full) return Rect.fromLTWH(8, 8, w - 16, h - 16);
    final share = f ?? _fraction.value;
    return switch (_dock) {
      BrowserDock.floating => _frame.value,
      BrowserDock.left => Rect.fromLTWH(0, 0, w * share, h),
      BrowserDock.right => Rect.fromLTWH(w - w * share, 0, w * share, h),
      BrowserDock.top => Rect.fromLTWH(0, 0, w, h * share),
      BrowserDock.bottom => Rect.fromLTWH(0, h - h * share, w, h * share),
    };
  }

  void _move(Offset delta) {
    final r = _frame.value.shift(delta);
    _frame.value = Rect.fromLTWH(
      r.left.clamp(-r.width + 120, (_area.width - 120).clamp(0, 1e9)),
      r.top.clamp(0, (_area.height - 48).clamp(0, 1e9)),
      r.width,
      r.height,
    );
  }

  /// A docked window's inner edge, dragged: an outline until let go.
  void _dragDockEdge(Offset d) {
    if (_area.width <= 0 || _area.height <= 0) return;
    final change = switch (_dock) {
      BrowserDock.left => d.dx / _area.width,
      BrowserDock.right => -d.dx / _area.width,
      BrowserDock.top => d.dy / _area.height,
      BrowserDock.bottom => -d.dy / _area.height,
      BrowserDock.floating => 0.0,
    };
    final f = ((_previewFraction ?? _fraction.value) + change).clamp(0.2, 0.9);
    _previewFraction = f;
    _preview.value = _rect(f);
  }

  /// The floating window's corner, dragged: an outline until let go.
  void _dragCorner(Offset d) {
    final r = _preview.value ?? _frame.value;
    _preview.value = Rect.fromLTWH(
      r.left,
      r.top,
      (r.width + d.dx).clamp(360, _area.width),
      (r.height + d.dy).clamp(260, _area.height),
    );
  }

  /// The resize, applied.
  void _endResize() {
    final f = _previewFraction;
    if (f != null) {
      _fraction.value = f;
      InAppBrowser.dockFraction = f;
    } else if (_preview.value != null && !_docked) {
      _frame.value = _preview.value!;
    }
    _previewFraction = null;
    _preview.value = null;
  }

  void _setDock(BrowserDock d) {
    if (!mounted) return;
    setState(() {
      _dock = d;
      _full = false;
    });
  }

  void _followSetting() => _setDock(InAppBrowser.dockSetting.value);

  @override
  void initState() {
    super.initState();
    _address.text = widget.url;
    _title = widget.title ?? '';
    InAppBrowser.dockSetting.addListener(_followSetting);
    _start();
  }

  Future<void> _start() async {
    try {
      await _web.initialize();
      _subs
        ..add(_web.url.listen((u) {
          if (mounted) setState(() => _address.text = u);
        }))
        ..add(_web.title.listen((t) {
          if (mounted) setState(() => _title = t);
        }))
        ..add(_web.loadingState.listen((s) {
          if (mounted) setState(() => _loading = s == LoadingState.loading);
        }))
        ..add(_web.historyChanged.listen((h) {
          if (mounted) {
            setState(() {
              _canBack = h.canGoBack;
              _canForward = h.canGoForward;
            });
          }
        }));
      // A page's own pop-ups (a processor's control page, Google's menus)
      // open in this same window rather than a stray one.
      await _web.setPopupWindowPolicy(WebviewPopupWindowPolicy.sameWindow);
      await _web.loadUrl(widget.url);
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    InAppBrowser.dockSetting.removeListener(_followSetting);
    for (final s in _subs) {
      s.cancel();
    }
    _web.dispose();
    _address.dispose();
    _frame.dispose();
    _fraction.dispose();
    _preview.dispose();
    super.dispose();
  }

  void _go(String text) {
    var u = text.trim();
    if (u.isEmpty) return;
    if (!u.contains('://')) u = 'https://$u';
    _web.loadUrl(u);
  }

  Widget _dockMenu() => MenuAnchor(
        builder: (context, controller, _) => IconButton(
          key: const ValueKey('browser_dock'),
          tooltip: 'Where this window sits',
          visualDensity: VisualDensity.compact,
          icon: Icon(_dock.icon, size: 18),
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
        ),
        menuChildren: [
          for (final d in BrowserDock.values)
            MenuItemButton(
              key: ValueKey('browser_dock_${d.name}'),
              leadingIcon: Icon(d.icon, size: 18),
              trailingIcon:
                  d == _dock ? const Icon(Icons.check, size: 16) : null,
              onPressed: () => _setDock(d),
              child: Text(d.label),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final bar = GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Starts at once, not after the double-tap test has had its say.
      dragStartBehavior: DragStartBehavior.down,
      onPanUpdate: _full || _docked ? null : (d) => _move(d.delta),
      onDoubleTap: () => setState(() => _full = !_full),
      child: MouseRegion(
        cursor: _full || _docked ? MouseCursor.defer : SystemMouseCursors.move,
        child: Container(
          color: scheme.surfaceContainerHigh,
          padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_back, size: 18),
                onPressed: _canBack ? _web.goBack : null,
              ),
              IconButton(
                tooltip: 'Forward',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_forward, size: 18),
                onPressed: _canForward ? _web.goForward : null,
              ),
              IconButton(
                tooltip: 'Reload',
                visualDensity: VisualDensity.compact,
                icon: _loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                onPressed: _ready ? _web.reload : null,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    controller: _address,
                    style: theme.textTheme.bodySmall,
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      hintText: _title,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
                    ),
                    onSubmitted: _go,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Open in your browser',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.open_in_browser, size: 18),
                onPressed: () => launchUrl(Uri.parse(_address.text),
                    mode: LaunchMode.externalApplication),
              ),
              _dockMenu(),
              IconButton(
                tooltip: _full ? 'Restore' : 'Fill the window',
                visualDensity: VisualDensity.compact,
                icon: Icon(_full ? Icons.fullscreen_exit : Icons.fullscreen,
                    size: 18),
                onPressed: () => setState(() => _full = !_full),
              ),
              IconButton(
                tooltip: 'Close',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
      ),
    );

    final sideways = _dock == BrowserDock.left || _dock == BrowserDock.right;
    final window = RepaintBoundary(
      child: Material(
        elevation: 18,
        borderRadius: BorderRadius.circular(_docked && !_full ? 0 : 10),
        clipBehavior: Clip.antiAlias,
        color: scheme.surface,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_title.isNotEmpty)
                  Container(
                    color: scheme.surfaceContainerHigh,
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                    child: Text(_title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium),
                  ),
                bar,
                Expanded(
                  child: _error.isNotEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'The built-in browser could not start: $_error',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : !_ready
                          ? const Center(child: CircularProgressIndicator())
                          : Webview(_web),
                ),
              ],
            ),
            // Docked: made larger or smaller from the inner edge.
            if (_docked && !_full)
              Positioned(
                left: _dock == BrowserDock.left ? null : 0,
                right: _dock == BrowserDock.right ? null : 0,
                top: _dock == BrowserDock.top ? null : 0,
                bottom: _dock == BrowserDock.bottom ? null : 0,
                width: sideways ? 8 : null,
                height: sideways ? null : 8,
                child: MouseRegion(
                  cursor: sideways
                      ? SystemMouseCursors.resizeLeftRight
                      : SystemMouseCursors.resizeUpDown,
                  child: GestureDetector(
                    key: const ValueKey('browser_dock_resize'),
                    behavior: HitTestBehavior.opaque,
                    dragStartBehavior: DragStartBehavior.down,
                    onPanUpdate: (d) => _dragDockEdge(d.delta),
                    onPanEnd: (_) => _endResize(),
                    onPanCancel: _endResize,
                    child: Container(color: scheme.outlineVariant),
                  ),
                ),
              ),
            // Floating: resized from the lower-right corner.
            if (!_full && !_docked)
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  dragStartBehavior: DragStartBehavior.down,
                  onPanUpdate: (d) => _dragCorner(d.delta),
                  onPanEnd: (_) => _endResize(),
                  onPanCancel: _endResize,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeDownRight,
                    child: Container(
                      width: 18,
                      height: 18,
                      alignment: Alignment.bottomRight,
                      child: Icon(Icons.drag_handle,
                          size: 14, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    // The layer it is drawn in, measured - not the window, which the app's
    // zoom makes a different size.
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          _area = constraints.biggest;
          return ListenableBuilder(
            listenable: Listenable.merge([_frame, _fraction, _preview]),
            child: window,
            builder: (context, child) => Stack(
              children: [
                Positioned.fromRect(rect: _rect(), child: child!),
                if (_preview.value case final outline?)
                  Positioned.fromRect(
                    rect: outline,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.08),
                          border: Border.all(color: scheme.primary, width: 2),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
