import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// ============================================================================
///  FIND ON PAGE (Ctrl+F)
/// ============================================================================
///  A browser-style find bar over the whole app. It reads the page's text -
///  labels, table cells, text boxes - straight from the render tree, so every
///  page is searchable without the page knowing.
///
///  A long list only builds the rows near the screen. To search the rest,
///  each such list is swept: scrolled through a screen at a time and laid out
///  on the spot, between frames, then put back where it was. Nothing is
///  painted while that happens, so the page does not move. A hit in a row
///  that is not built remembers the scroll offset that shows it.
///
///  A tab that is not showing is not searched.
/// ============================================================================

/// One hit: [length] characters from [start] in [box]'s text.
class FindMatch {
  /// The text it is in. Re-pointed when its row is rebuilt.
  RenderBox box;
  final int start;
  final int length;

  /// [box]'s text when the hit was found.
  final String text;

  /// The long list it was swept from, or null for text that is always built.
  final RenderViewportBase? viewport;

  /// [viewport]'s scroll offset that shows the hit.
  final double revealOffset;

  FindMatch(
    this.box,
    this.start,
    this.length, {
    this.text = '',
    this.viewport,
    this.revealOffset = 0,
  });

  TextSelection get selection =>
      TextSelection(baseOffset: start, extentOffset: start + length);

  /// The text boxes the hit covers, in [box]'s coordinates.
  List<TextBox> get textBoxes {
    final box = this.box;
    if (!box.attached || !box.hasSize) return const [];
    if (box is RenderParagraph) return box.getBoxesForSelection(selection);
    if (box is RenderEditable) return box.getBoxesForSelection(selection);
    return const [];
  }

  /// The hit's bounds in [box]'s coordinates, or null.
  Rect? get bounds {
    Rect? r;
    for (final t in textBoxes) {
      final rect = t.toRect();
      r = r == null ? rect : r.expandToInclude(rect);
    }
    return r;
  }

  bool sameHit(FindMatch other) =>
      start == other.start &&
      (identical(box, other.box) ||
          (viewport != null &&
              identical(viewport, other.viewport) &&
              text == other.text &&
              (revealOffset - other.revealOffset).abs() < 1));
}

String? _textOf(RenderObject node) {
  if (node is RenderParagraph) {
    return node.text.toPlainText(includeSemanticsLabels: false);
  }
  if (node is RenderEditable && !node.obscureText) return node.plainText;
  return null;
}

/// The hits under [root] in paragraphs and text boxes that are built and
/// showing, in paint order. Hidden tabs, offstage routes and invisible
/// children are skipped the way the screen reader skips them. A viewport in
/// [swept] stands for its swept hits instead of what it has built.
List<FindMatch> findMatches(
  RenderObject root,
  String query, {
  Map<RenderObject, List<FindMatch>> swept = const {},
}) {
  final q = query.toLowerCase();
  if (q.isEmpty) return const [];
  final out = <FindMatch>[];
  void visit(RenderObject node) {
    final sweptHits = swept[node];
    if (sweptHits != null) {
      out.addAll(sweptHits);
      return;
    }
    final text = _textOf(node);
    if (text != null) {
      final lower = text.toLowerCase();
      // Lower-casing can change the length of a few letters; skip those.
      if (lower.length == text.length) {
        var at = lower.indexOf(q);
        while (at >= 0) {
          out.add(FindMatch(node as RenderBox, at, q.length, text: text));
          at = lower.indexOf(q, at + q.length);
        }
      }
    }
    node.visitChildrenForSemantics(visit);
  }

  visit(root);
  return out;
}

/// The scrolling lists under [root] that build their rows as they scroll
/// in. Lists inside them are left to the outer list's sweep.
List<RenderViewportBase> lazyLists(RenderObject root) {
  final out = <RenderViewportBase>[];
  void visit(RenderObject node) {
    if (node is RenderViewportBase && _isLazy(node)) {
      out.add(node);
      return;
    }
    node.visitChildrenForSemantics(visit);
  }

  visit(root);
  return out;
}

bool _isLazy(RenderViewportBase v) {
  final p = v.offset;
  if (p is! ScrollPosition ||
      !p.hasPixels ||
      !p.hasContentDimensions ||
      p.maxScrollExtent <= p.minScrollExtent) {
    return false;
  }
  var lazy = false;
  void look(RenderObject o) {
    if (lazy) return;
    if (o is RenderSliverMultiBoxAdaptor) {
      lazy = true;
    } else if (o is RenderSliver) {
      o.visitChildren(look);
    }
  }

  v.visitChildren(look);
  return lazy;
}

/// Lays [v] out at scroll offset [pixels] now, without telling anybody it
/// scrolled.
void _layoutAt(RenderViewportBase v, double pixels) {
  (v.offset as ScrollPosition).correctPixels(pixels);
  v.markNeedsLayout();
  _flushLayout(v);
}

/// Lays out what is waiting, outside a frame. Widgets waiting to rebuild go
/// first: a list building its rows may only build inside itself.
void _flushLayout(RenderObject v) {
  final binding = WidgetsBinding.instance;
  final root = binding.rootElement;
  if (root != null) binding.buildOwner?.buildScope(root);
  v.owner?.flushLayout();
}

double _offsetToReveal(RenderViewportBase v, FindMatch m) {
  final p = v.offset as ScrollPosition;
  final rect = m.bounds ?? Offset.zero & m.box.size;
  return v
      .getOffsetToReveal(m.box, 0.5, rect: rect)
      .offset
      .clamp(p.minScrollExtent, p.maxScrollExtent);
}

/// Every hit in the long list [v], built or not, top to bottom. The list
/// is scrolled through a screen at a time, then put back.
List<FindMatch> sweepLazyList(RenderViewportBase v, String query) {
  final p = v.offset as ScrollPosition;
  final saved = p.pixels;
  final step = math.max(p.viewportDimension, 1.0);
  final seen = <(RenderBox, int)>{};
  final out = <FindMatch>[];
  var at = p.minScrollExtent;
  // A cap, should a list keep growing as it is swept.
  for (var i = 0; i < 20000; i++) {
    _layoutAt(v, at);
    for (final m in findMatches(v, query)) {
      if (!seen.add((m.box, m.start))) continue;
      out.add(FindMatch(m.box, m.start, m.length,
          text: m.text, viewport: v, revealOffset: _offsetToReveal(v, m)));
    }
    if (at >= p.maxScrollExtent) break;
    at = math.min(at + step, p.maxScrollExtent);
  }
  _layoutAt(v, saved);
  relink(v, out, query);
  return out;
}

/// Points [v]'s hits in [matches] at the rows it has built now, which are
/// new objects whenever a row scrolled out and back.
void relink(RenderViewportBase v, List<FindMatch> matches, String query) {
  final byText = <(String, int), List<FindMatch>>{};
  for (final m in matches) {
    if (identical(m.viewport, v)) {
      (byText[(m.text, m.start)] ??= []).add(m);
    }
  }
  if (byText.isEmpty) return;
  final p = v.offset as ScrollPosition;
  final near = math.max(p.viewportDimension / 2, 1.0);
  for (final live in findMatches(v, query)) {
    final candidates = byText[(live.text, live.start)];
    if (candidates == null) continue;
    final off = _offsetToReveal(v, live);
    FindMatch? best;
    var gap = double.infinity;
    for (final m in candidates) {
      final g = (m.revealOffset - off).abs();
      if (g < gap) {
        gap = g;
        best = m;
      }
    }
    if (best != null && gap < near) best.box = live.box;
  }
}

/// [local] in [box]'s coordinates, carried up to [ancestor] and cut down by
/// every clip on the way (a scrolled list, a card). Null when nothing of it
/// is left.
Rect? visibleRectIn(RenderObject box, Rect local, RenderObject ancestor) {
  var r = local;
  RenderObject node = box;
  while (node != ancestor) {
    final parent = node.parent;
    if (parent == null) return null;
    final m = Matrix4.identity();
    parent.applyPaintTransform(node, m);
    r = MatrixUtils.transformRect(m, r);
    final clip = parent.describeApproximatePaintClip(node);
    if (clip != null) r = r.intersect(clip);
    if (r.width <= 0 || r.height <= 0) return null;
    node = parent;
  }
  return r;
}

/// Hosts the find bar over [child]. Open it with [FindInPageState.open].
class FindInPage extends StatefulWidget {
  final Widget child;

  const FindInPage({super.key, required this.child});

  @override
  State<FindInPage> createState() => FindInPageState();
}

class FindInPageState extends State<FindInPage> {
  final _stackKey = GlobalKey();
  final _text = TextEditingController();
  final _focus = FocusNode(debugLabel: 'Find on page');
  /// Ticks on every scroll, so the highlights follow the text.
  final _repaint = ValueNotifier(0);

  bool _open = false;
  List<FindMatch> _matches = const [];
  int _current = -1;
  FocusNode? _returnFocus;
  Timer? _refresh;
  Timer? _typing;

  bool get isOpen => _open;
  List<FindMatch> get matches => _matches;
  int get current => _current;

  /// Shows the bar with its box focused and selected; again while open just
  /// takes the focus back.
  void open() {
    if (!_open) {
      _returnFocus = FocusManager.instance.primaryFocus;
      setState(() => _open = true);
    }
    _text.selection =
        TextSelection(baseOffset: 0, extentOffset: _text.text.length);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_open) return;
      _focus.requestFocus();
      _search(keepPlace: true);
    });
  }

  void close() {
    if (!_open) return;
    _refresh?.cancel();
    _typing?.cancel();
    _typing = null;
    setState(() {
      _open = false;
      _matches = const [];
      _current = -1;
    });
    final back = _returnFocus;
    _returnFocus = null;
    if (back != null && back.context != null) back.requestFocus();
  }

  /// Steps to the next hit (or back with [forward] false) and scrolls to it.
  void next({bool forward = true}) {
    // Enter before the pause is over searches now, landing on the first.
    if (_typing != null) return _searchNow();
    if (_matches.isEmpty) _search();
    if (_matches.isEmpty) return;
    setState(() {
      _current = _current < 0
          ? (forward ? 0 : _matches.length - 1)
          : (_current + (forward ? 1 : -1)) % _matches.length;
    });
    _reveal();
  }

  RenderObject? get _root {
    final stack = _stackKey.currentContext?.findRenderObject();
    return stack is RenderStack ? stack.firstChild : null;
  }

  /// Reads the whole page again, long lists included. [keepPlace] stays on
  /// the same hit when it is still there, so a refresh does not jump.
  void _search({bool keepPlace = false}) {
    final root = _root;
    if (!_open || root == null) return;
    final query = _text.text;
    final was = _current >= 0 && _current < _matches.length
        ? _matches[_current]
        : null;
    final swept = <RenderObject, List<FindMatch>>{
      if (query.isNotEmpty)
        for (final v in lazyLists(root)) v: sweepLazyList(v, query),
    };
    final found = findMatches(root, query, swept: swept);
    var current = -1;
    if (keepPlace && was != null) current = found.indexWhere(was.sameHit);
    if (current < 0 && found.isNotEmpty) current = 0;
    setState(() {
      _matches = found;
      _current = current;
    });
  }

  /// Searching a page with long lists takes a moment, so it waits until
  /// typing pauses - the CTS Dashboard's log search wait.
  static const typingPause = Duration(milliseconds: 200);

  void _onChanged(String _) {
    _typing?.cancel();
    _typing = Timer(typingPause, _searchNow);
    setState(() {}); // the count shows it is waiting
  }

  void _searchNow() {
    _typing?.cancel();
    _typing = null;
    if (!mounted) return;
    _search();
    _reveal();
  }

  void _reveal() {
    if (_current < 0 || _current >= _matches.length) return;
    final m = _matches[_current];
    final v = m.viewport;
    if (!m.box.attached && v != null && v.attached) {
      // Its row is not built: scroll the list to it, build it now, and find
      // the new row.
      (v.offset as ScrollPosition).jumpTo(m.revealOffset);
      _flushLayout(v);
      relink(v, _matches, _text.text);
    }
    final rect = m.bounds;
    if (rect == null) return;
    m.box.showOnScreen(
      rect: rect.inflate(24),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  /// After a scroll, rows have been rebuilt: point the hits at the new ones.
  void _relinkAll() {
    final query = _text.text;
    final lists = {for (final m in _matches) ?m.viewport};
    for (final v in lists) {
      if (v.attached) relink(v, _matches, query);
    }
    _repaint.value++;
  }

  /// After a click the page may have changed; read it again once things
  /// settle. After a scroll only the rows changed.
  void _scheduleRefresh({required bool full}) {
    if (!_open) return;
    _refresh?.cancel();
    _refresh = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      full ? _search(keepPlace: true) : _relinkAll();
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _typing?.cancel();
    _text.dispose();
    _focus.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (_open) {
          _repaint.value++;
          if (n is ScrollEndNotification && !(_refresh?.isActive ?? false)) {
            _scheduleRefresh(full: false);
          }
        }
        return false;
      },
      child: Listener(
        onPointerUp: (_) => _scheduleRefresh(full: true),
        child: CallbackShortcuts(
          bindings: {
            if (_open) ...{
              const SingleActivator(LogicalKeyboardKey.f3): next,
              const SingleActivator(LogicalKeyboardKey.f3, shift: true): () =>
                  next(forward: false),
            },
          },
          child: Stack(
            key: _stackKey,
            children: [
              widget.child,
              if (_open) ...[
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _HighlightPainter(this),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 16,
                  // Its own overlay, for the text box and the tooltips;
                  // unclipped so a tooltip can hang below the bar.
                  child: Overlay.wrap(
                    alwaysSizeToContent: true,
                    clipBehavior: Clip.none,
                    child: _bar(context),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _bar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = _text.text.isEmpty
        ? ''
        : _typing != null
            ? '...'
            : _matches.isEmpty
                ? 'No results'
                : '${_current + 1} of ${_matches.length}';
    return Material(
      elevation: 6,
      // Outlined so it stands off the page in dark mode, where the shadow
      // barely shows.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outline, width: 1.5),
      ),
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Beside the box rather than in it, so the Row centers the two
            // on one line.
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.search, size: 18),
            ),
            SizedBox(
              width: 220,
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape): close,
                  const SingleActivator(LogicalKeyboardKey.enter): next,
                  const SingleActivator(LogicalKeyboardKey.numpadEnter): next,
                  const SingleActivator(LogicalKeyboardKey.enter, shift: true):
                      () => next(forward: false),
                },
                child: TextField(
                  controller: _text,
                  focusNode: _focus,
                  onChanged: _onChanged,
                  decoration: const InputDecoration.collapsed(
                    hintText: 'Find on page',
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 76,
              child: Text(
                count,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            IconButton(
              tooltip: 'Previous (Shift+Enter)',
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: _matches.isEmpty ? null : () => next(forward: false),
            ),
            IconButton(
              tooltip: 'Next (Enter)',
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: _matches.isEmpty ? null : next,
            ),
            IconButton(
              tooltip: 'Close (Esc)',
              icon: const Icon(Icons.close),
              onPressed: close,
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints a band over every hit; the current one stronger.
class _HighlightPainter extends CustomPainter {
  final FindInPageState state;

  _HighlightPainter(this.state) : super(repaint: state._repaint);

  static const _hit = Color(0x66FFEB3B);
  static const _currentHit = Color(0x99FF9800);

  @override
  void paint(Canvas canvas, Size size) {
    final host = state._stackKey.currentContext?.findRenderObject();
    if (host == null) return;
    final matches = state._matches;
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      if (!m.box.attached) continue;
      final paint = Paint()..color = i == state._current ? _currentHit : _hit;
      for (final t in m.textBoxes) {
        final r = visibleRectIn(m.box, t.toRect(), host);
        if (r != null) {
          canvas.drawRRect(
              RRect.fromRectAndRadius(r, const Radius.circular(2)), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_HighlightPainter old) => true;
}
