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
///  browser window over the app instead of in the default browser, so the
///  page and the work it is about sit side by side.
///
///  ONE WINDOW, MANY TABS. A link opened while the browser is up becomes a
///  new tab in it; "+" opens an empty one; each tab closes on its own and the
///  window goes when the last one does. Tabs that are not in front keep their
///  pages loaded.
///
///  The window floats - dragged by its title bar, resized from its corner -
///  or is docked to a side of the app's window and made larger from its inner
///  edge. Which sides are offered is the app's choice ([allowedDocks]). A
///  docked window says how much of the window it takes ([reserved]) so the
///  app can shrink its own pages out of the way - see [InAppBrowserInset].
///
///  It sits in the app's own navigator layer, beside dialogs and menus, so
///  it is placed and scaled the same way they are when the app is zoomed. A
///  resize is drawn as an outline while the pointer moves and applied once
///  it is let go: resizing the page on every movement is what made it lag.
///
///  It is Microsoft Edge WebView2, which Windows 11 has built in. Sign-ins
///  are kept in [InAppBrowser.userDataFolder], so Google asks once. Turned
///  off in settings, or on a PC without WebView2, links open in the default
///  browser as before. Google's own sign-in for the app (OAuth) always uses
///  the real browser: Google refuses it inside an embedded one.
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

  /// The places this app offers. A setting outside them is read as Bottom.
  static Set<BrowserDock> allowedDocks = BrowserDock.values.toSet();

  /// [dock] when this app offers it, else the nearest it does.
  static BrowserDock allowed(BrowserDock dock) {
    if (allowedDocks.contains(dock)) return dock;
    if (allowedDocks.contains(BrowserDock.bottom)) return BrowserDock.bottom;
    return allowedDocks.isEmpty ? BrowserDock.floating : allowedDocks.first;
  }

  /// Where the browser sits - the app's setting. A window already open
  /// follows a change to it.
  static final ValueNotifier<BrowserDock> dockSetting =
      ValueNotifier(BrowserDock.floating);

  static BrowserDock get dock => dockSetting.value;
  static set dock(BrowserDock value) => dockSetting.value = allowed(value);

  /// How much of the window a docked browser takes - dragged larger or
  /// smaller from its inner edge, and kept for the next one this session.
  static double dockFraction = 0.45;

  /// The edge of the app's window a docked browser covers, so the app can
  /// lay its pages out in what is left. Zero while it floats or is shut.
  static final ValueNotifier<EdgeInsets> reserved =
      ValueNotifier(EdgeInsets.zero);

  /// Where cookies and sign-ins are kept. Set by the app at start-up.
  static String userDataFolder = '';

  static bool? _available;
  static bool _environmentReady = false;

  /// The window, while one is open - new links become tabs in it.
  static _BrowserPanelState? _window;

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

  /// Opens [url] in the browser over the app - a new tab when it is already
  /// open. False when it could not be, so the caller can fall back to the
  /// default browser.
  static Future<bool> open(BuildContext context, String url,
      {String? title}) async {
    if (!await available() || !context.mounted) return false;
    if (!_environmentReady && userDataFolder.isNotEmpty) {
      try {
        await Directory(userDataFolder).create(recursive: true);
        await WebviewController.initializeEnvironment(
            userDataPath: userDataFolder);
      } catch (_) {
        // Already set up, or the folder is read-only: WebView2 then uses its
        // default.
      }
      _environmentReady = true;
    }
    final open = _window;
    if (open != null && open.mounted) {
      open.addTab(url, title: title);
      return true;
    }
    if (!context.mounted) return false;
    // The navigator's layer - where dialogs and menus go - so the window is
    // inside whatever zoom the app is drawn at, and its menus line up.
    final overlay = Navigator.maybeOf(context, rootNavigator: true)?.overlay ??
        Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _BrowserPanel(
        url: url,
        title: title,
        onClose: () {
          entry.remove();
          reserved.value = EdgeInsets.zero;
        },
      ),
    );
    overlay.insert(entry);
    return true;
  }
}

/// Lays [child] out in the part of the window a docked browser leaves free,
/// so its scroll bars reach the last rows instead of ending under the
/// browser. Wrap an app's main page in it; dialogs stay full size.
class InAppBrowserInset extends StatelessWidget {
  final Widget child;

  const InAppBrowserInset({super.key, required this.child});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<EdgeInsets>(
        valueListenable: InAppBrowser.reserved,
        child: child,
        builder: (context, inset, child) => AnimatedPadding(
          duration: const Duration(milliseconds: 150),
          padding: inset,
          child: child,
        ),
      );
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

/// One page in the browser: its own WebView2 and what it is showing.
class _BrowserTab {
  final WebviewController web = WebviewController();
  final TextEditingController address = TextEditingController();
  final List<StreamSubscription> subs = [];
  final Key key = UniqueKey();
  String title;
  bool ready = false;
  bool loading = true;
  bool canBack = false;
  bool canForward = false;
  String error = '';

  _BrowserTab(String url, String? title) : title = title ?? '' {
    address.text = url;
  }

  String get label {
    if (title.trim().isNotEmpty) return title.trim();
    final host = Uri.tryParse(address.text)?.host ?? '';
    return host.isEmpty ? 'New tab' : host;
  }

  void dispose() {
    for (final s in subs) {
      s.cancel();
    }
    web.dispose();
    address.dispose();
  }
}

class _BrowserPanel extends StatefulWidget {
  final String url;
  final String? title;
  final VoidCallback onClose;

  const _BrowserPanel({
    required this.url,
    required this.title,
    required this.onClose,
  });

  @override
  State<_BrowserPanel> createState() => _BrowserPanelState();
}

class _BrowserPanelState extends State<_BrowserPanel> {
  final List<_BrowserTab> _tabs = [];
  int _current = 0;

  _BrowserTab get _tab => _tabs[_current];

  /// Where the floating window is and how big. A move changes only this, so
  /// the page inside is moved as it stands rather than rebuilt.
  final ValueNotifier<Rect> _frame =
      ValueNotifier(const Offset(60, 80) & const Size(1000, 700));

  /// This window's share of the app's window when docked.
  final ValueNotifier<double> _fraction =
      ValueNotifier(InAppBrowser.dockFraction);

  /// The outline drawn while a resize is under way; applied when let go.
  final ValueNotifier<Rect?> _preview = ValueNotifier(null);
  double? _previewFraction;

  bool _full = false;

  /// Where the window sits, starting on the app's setting.
  late BrowserDock _dock = InAppBrowser.allowed(InAppBrowser.dock);

  bool get _docked => _dock != BrowserDock.floating;

  /// The space the window has: the layer it is drawn in, measured.
  Size _area = Size.zero;

  @override
  void initState() {
    super.initState();
    InAppBrowser._window = this;
    InAppBrowser.dockSetting.addListener(_followSetting);
    _fraction.addListener(_publishReserved);
    addTab(widget.url, title: widget.title);
  }

  @override
  void dispose() {
    if (InAppBrowser._window == this) InAppBrowser._window = null;
    InAppBrowser.dockSetting.removeListener(_followSetting);
    for (final t in _tabs) {
      t.dispose();
    }
    _frame.dispose();
    _fraction.dispose();
    _preview.dispose();
    super.dispose();
  }

  /// Opens [url] in a new tab, in front.
  void addTab(String url, {String? title}) {
    final tab = _BrowserTab(url, title);
    setState(() {
      _tabs.add(tab);
      _current = _tabs.length - 1;
    });
    _startTab(tab, url);
  }

  Future<void> _startTab(_BrowserTab tab, String url) async {
    try {
      await tab.web.initialize();
      tab.subs
        ..add(tab.web.url.listen((u) {
          if (mounted) setState(() => tab.address.text = u);
        }))
        ..add(tab.web.title.listen((t) {
          if (mounted) setState(() => tab.title = t);
        }))
        ..add(tab.web.loadingState.listen((s) {
          if (mounted) setState(() => tab.loading = s == LoadingState.loading);
        }))
        ..add(tab.web.historyChanged.listen((h) {
          if (mounted) {
            setState(() {
              tab.canBack = h.canGoBack;
              tab.canForward = h.canGoForward;
            });
          }
        }));
      // A page's own pop-ups (a processor's control page, Google's menus)
      // open in this same tab rather than a stray window.
      await tab.web.setPopupWindowPolicy(WebviewPopupWindowPolicy.sameWindow);
      if (url.isNotEmpty) await tab.web.loadUrl(url);
      if (mounted) {
        setState(() {
          tab.ready = true;
          if (url.isEmpty) tab.loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => tab.error = '$e');
    }
  }

  void _closeTab(int i) {
    final tab = _tabs[i];
    if (_tabs.length == 1) {
      widget.onClose();
      return;
    }
    setState(() {
      _tabs.removeAt(i);
      if (_current >= _tabs.length) _current = _tabs.length - 1;
      if (i < _current) _current--;
    });
    tab.dispose();
  }

  void _go(String text) {
    var u = text.trim();
    if (u.isEmpty) return;
    if (!u.contains('://')) {
      // An address, or something to search for.
      u = u.contains('.') && !u.contains(' ')
          ? 'https://$u'
          : 'https://www.google.com/search?q=${Uri.encodeQueryComponent(u)}';
    }
    _tab.web.loadUrl(u);
  }

  // --- where the window sits --------------------------------------------

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

  /// Tells the app how much of the window this takes while docked.
  void _publishReserved() {
    if (!mounted) return;
    final r = _docked && !_full ? _rect() : null;
    final inset = r == null
        ? EdgeInsets.zero
        : switch (_dock) {
            BrowserDock.left => EdgeInsets.only(left: r.width),
            BrowserDock.right => EdgeInsets.only(right: r.width),
            BrowserDock.top => EdgeInsets.only(top: r.height),
            BrowserDock.bottom => EdgeInsets.only(bottom: r.height),
            BrowserDock.floating => EdgeInsets.zero,
          };
    if (InAppBrowser.reserved.value != inset) {
      InAppBrowser.reserved.value = inset;
    }
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
      _dock = InAppBrowser.allowed(d);
      _full = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _publishReserved());
  }

  void _setFull(bool value) {
    setState(() => _full = value);
    WidgetsBinding.instance.addPostFrameCallback((_) => _publishReserved());
  }

  void _followSetting() => _setDock(InAppBrowser.dockSetting.value);

  // --- the window ---------------------------------------------------------

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
            if (InAppBrowser.allowedDocks.contains(d))
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

  /// The row of tabs, with "+" for a new one. Also the handle the floating
  /// window is dragged by.
  Widget _tabStrip(ThemeData theme) {
    final scheme = theme.colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onPanUpdate: _full || _docked ? null : (d) => _move(d.delta),
      onDoubleTap: () => _setFull(!_full),
      child: MouseRegion(
        cursor: _full || _docked ? MouseCursor.defer : SystemMouseCursors.move,
        child: Container(
          color: scheme.surfaceContainerHighest,
          padding: const EdgeInsets.fromLTRB(6, 4, 4, 0),
          height: 38,
          child: Row(
            children: [
              Expanded(
                child: ListView(
                  key: const ValueKey('browser_tabs'),
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (var i = 0; i < _tabs.length; i++)
                      _TabChip(
                        key: ValueKey('browser_tab_$i'),
                        label: _tabs[i].label,
                        loading: _tabs[i].loading,
                        selected: i == _current,
                        onSelect: () => setState(() => _current = i),
                        onClose: () => _closeTab(i),
                      ),
                    IconButton(
                      key: const ValueKey('browser_new_tab'),
                      tooltip: 'New tab',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.add, size: 18),
                      onPressed: () => addTab(''),
                    ),
                  ],
                ),
              ),
              _dockMenu(),
              IconButton(
                tooltip: _full ? 'Restore' : 'Fill the window',
                visualDensity: VisualDensity.compact,
                icon: Icon(_full ? Icons.fullscreen_exit : Icons.fullscreen,
                    size: 18),
                onPressed: () => _setFull(!_full),
              ),
              IconButton(
                tooltip: 'Close the browser',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Back, forward, reload, the address of the tab in front.
  Widget _toolbar(ThemeData theme) {
    final tab = _tab;
    return Container(
      color: theme.colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_back, size: 18),
            onPressed: tab.canBack ? tab.web.goBack : null,
          ),
          IconButton(
            tooltip: 'Forward',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.arrow_forward, size: 18),
            onPressed: tab.canForward ? tab.web.goForward : null,
          ),
          IconButton(
            tooltip: 'Reload',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: tab.ready ? tab.web.reload : null,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SizedBox(
              height: 32,
              child: TextField(
                key: ValueKey('browser_address_${tab.key}'),
                controller: tab.address,
                autofocus: tab.address.text.isEmpty,
                style: theme.textTheme.bodySmall,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: 'Type an address, or something to search for',
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                ),
                onSubmitted: _go,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Open in your browser',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.open_in_browser, size: 18),
            onPressed: tab.address.text.trim().isEmpty
                ? null
                : () => launchUrl(Uri.parse(tab.address.text),
                    mode: LaunchMode.externalApplication),
          ),
        ],
      ),
    );
  }

  Widget _page(_BrowserTab tab) {
    if (tab.error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('The built-in browser could not start: ${tab.error}',
              textAlign: TextAlign.center),
        ),
      );
    }
    if (!tab.ready) return const Center(child: CircularProgressIndicator());
    return Webview(tab.web);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
                _tabStrip(theme),
                _toolbar(theme),
                // Every tab stays built; only the one in front shows.
                Expanded(
                  child: IndexedStack(
                    index: _current,
                    children: [
                      for (final t in _tabs)
                        KeyedSubtree(key: t.key, child: _page(t)),
                    ],
                  ),
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
          final changed = _area != constraints.biggest;
          _area = constraints.biggest;
          if (changed) {
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _publishReserved());
          }
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

/// One tab in the strip: its page title, a spinner while it loads, and its
/// own close button.
class _TabChip extends StatelessWidget {
  final String label;
  final bool loading;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  const _TabChip({
    super.key,
    required this.label,
    required this.loading,
    required this.selected,
    required this.onSelect,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Material(
        color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
        child: InkWell(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          onTap: onSelect,
          child: Container(
            constraints: const BoxConstraints(minWidth: 90, maxWidth: 220),
            padding: const EdgeInsets.only(left: 10, right: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading) ...[
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : null,
                      color: selected
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close this tab',
                  visualDensity: VisualDensity.compact,
                  iconSize: 14,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 24, minHeight: 24),
                  icon: const Icon(Icons.close),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
