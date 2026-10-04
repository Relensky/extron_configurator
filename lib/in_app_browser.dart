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
///  floating window over the app instead of in the default browser, so the
///  page and the work it is about sit side by side. Several can be open at
///  once; each is dragged by its title bar, resized from its corner, and can
///  fill the window or hand its page to the real browser.
///
///  It is Microsoft Edge WebView2, which Windows 11 has built in. Sign-ins
///  are kept in [userDataFolder], so Google asks once. Turned off in settings,
///  or on a PC without WebView2, links open in the default browser as before.
///
///  Google's own sign-in for the app (OAuth) always uses the real browser:
///  Google refuses it inside an embedded one.
/// ============================================================================
class InAppBrowser {
  InAppBrowser._();

  /// Whether links open here. Set from the app's settings.
  static bool enabled = true;

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

  /// Opens [url] in a floating browser over the app. False when it could not
  /// be, so the caller can fall back to the default browser.
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
    final overlay = Overlay.of(context, rootOverlay: true);
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
  /// Where the window is and how big. A drag changes only this, so the
  /// page inside is moved as it stands rather than rebuilt on every tick.
  late final ValueNotifier<Rect> _frame =
      ValueNotifier(widget.start & const Size(1000, 700));

  /// Where it was before it filled the screen.
  Rect? _restore;
  bool _full = false;

  Size _screen = Size.zero;

  void _move(Offset delta) {
    final r = _frame.value.shift(delta);
    _frame.value = Rect.fromLTWH(
      r.left.clamp(-r.width + 120, (_screen.width - 120).clamp(0, 1e9)),
      r.top.clamp(0, (_screen.height - 48).clamp(0, 1e9)),
      r.width,
      r.height,
    );
  }

  void _resize(Offset delta) {
    final r = _frame.value;
    _frame.value = Rect.fromLTWH(
      r.left,
      r.top,
      (r.width + delta.dx).clamp(360, _screen.width),
      (r.height + delta.dy).clamp(260, _screen.height),
    );
  }

  void _toggleFull() {
    setState(() {
      _full = !_full;
      if (_full) {
        _restore = _frame.value;
        _frame.value = Rect.fromLTWH(
            8, 8, _screen.width - 16, _screen.height - 16);
      } else {
        _frame.value = _restore ?? (widget.start & const Size(1000, 700));
      }
    });
  }
  bool _ready = false;
  bool _loading = true;
  bool _canBack = false;
  bool _canForward = false;
  String _title = '';
  String _error = '';

  @override
  void initState() {
    super.initState();
    _address.text = widget.url;
    _title = widget.title ?? '';
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
    for (final s in _subs) {
      s.cancel();
    }
    _web.dispose();
    _address.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _go(String text) {
    var u = text.trim();
    if (u.isEmpty) return;
    if (!u.contains('://')) u = 'https://$u';
    _web.loadUrl(u);
  }

  @override
  Widget build(BuildContext context) {
    _screen = MediaQuery.of(context).size;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final bar = GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Starts at once, not after the double-tap test has had its say.
      dragStartBehavior: DragStartBehavior.down,
      onPanUpdate: _full ? null : (d) => _move(d.delta),
      onDoubleTap: _toggleFull,
      child: MouseRegion(
        cursor: _full ? MouseCursor.defer : SystemMouseCursors.move,
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
              IconButton(
                tooltip: _full ? 'Restore' : 'Fill the window',
                visualDensity: VisualDensity.compact,
                icon: Icon(_full ? Icons.fullscreen_exit : Icons.fullscreen,
                    size: 18),
                onPressed: _toggleFull,
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

    final window = RepaintBoundary(
      child: Material(
        elevation: 18,
        borderRadius: BorderRadius.circular(10),
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
            // Resized from the lower-right corner.
            if (!_full)
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  dragStartBehavior: DragStartBehavior.down,
                  onPanUpdate: (d) => _resize(d.delta),
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
    return ValueListenableBuilder<Rect>(
      valueListenable: _frame,
      child: window,
      builder: (context, r, child) => Positioned.fromRect(rect: r, child: child!),
    );
  }
}
