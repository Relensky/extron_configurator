import 'dart:collection';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'theme_polish.dart' show kMotionCurve;

/// ============================================================================
///  KEEPING VISITED TABS ALIVE
/// ============================================================================
///  Switching tabs used to throw the page away and build the next from
///  scratch - the AV Flow, the Cost page and the Project page each redo a lot
///  of work to draw. So the last few pages visited stay mounted, hidden:
///
///    * not painted, no animations (TickerMode off), no focus;
///    * FROZEN: the app's notifications are held back from a hidden page, so
///      typing on one tab does not rebuild five others. The page catches up
///      with one rebuild when it is shown again.
///
///  A page shown again fades in, the same as a new one.
/// ============================================================================

/// The tabs kept mounted once visited. The editors that commit on the way
/// out (Raw JSON, the catalog, the schema) are rebuilt each visit, as before.
const Set<AppTab> kCachedTabs = {
  AppTab.avFlow,
  AppTab.floorPlan,
  AppTab.cabling,
  AppTab.racks,
  AppTab.cost,
  AppTab.schematic,
  AppTab.lifecycle,
  AppTab.project,
  AppTab.wizard,
  AppTab.devices,
  AppTab.system,
};

/// Cached tabs whose fields read their value once, when built. Shown again
/// after the room changed underneath them, they are built afresh - see
/// [PageCache.stamp].
const Set<AppTab> kRefreshedTabs = {
  AppTab.wizard,
  AppTab.devices,
  AppTab.system,
};

/// How many pages stay mounted, the visible one included.
const int kCachedPages = 6;

/// How long a page takes to fade in.
const Duration kPageFade = Duration(milliseconds: 160);

/// One page the cache can hold.
typedef CachedPage = ({
  /// Same key, same page: its state is kept while it is cached.
  String key,

  /// False for a page that belongs to the open room, dropped when another
  /// room is opened ([PageCache.epoch] moves on).
  bool keepAcrossEpochs,
});

class PageCache extends StatefulWidget {
  const PageCache({
    super.key,
    required this.page,
    required this.epoch,
    required this.builder,
    this.cacheable = true,
    this.maxPages = kCachedPages,
    this.stamp,
  });

  /// What the page shows, summed up. A page shown again whose stamp moved
  /// while it was hidden is built afresh rather than shown as it was.
  final String Function()? stamp;

  final CachedPage page;

  /// Moves on when a different room is opened.
  final int epoch;

  /// Builds the visible page.
  final WidgetBuilder builder;

  /// False: the page is dropped as soon as it is left, as before - for pages
  /// that do their work on the way out.
  final bool cacheable;
  final int maxPages;

  @override
  State<PageCache> createState() => _PageCacheState();
}

class _Entry {
  Widget child;
  final int epoch;
  final bool keep;
  final bool cacheable;

  /// Bumped to remount the page.
  int generation = 0;
  String Function()? stamp;

  /// [stamp] as it was when the page was hidden; null while it is shown.
  String? hiddenAt;
  _Entry(this.child, this.epoch, this.keep, this.cacheable);
}

class _PageCacheState extends State<PageCache> {
  /// Oldest visit first.
  final LinkedHashMap<String, _Entry> _pages = LinkedHashMap();
  String _shown = '';

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    // Leaving a page that does not stay, or a room's page from another room.
    _pages.removeWhere((k, e) =>
        k != page.key &&
        (!e.cacheable || (!e.keep && e.epoch != widget.epoch)));
    // The page being left: what it showed, for when it comes back.
    if (_shown != page.key) {
      final left = _pages[_shown];
      if (left != null) left.hiddenAt = left.stamp?.call();
      _shown = page.key;
    }
    // Moved to the end: the most recent visit.
    final had = _pages.remove(page.key);
    final entry = _pages[page.key] = _Entry(
      widget.builder(context),
      widget.epoch,
      page.keepAcrossEpochs,
      widget.cacheable,
    )..stamp = widget.stamp;
    if (had != null) {
      entry.generation = had.generation;
      final was = had.hiddenAt;
      if (was != null && widget.stamp != null && widget.stamp!() != was) {
        entry.generation++;
      }
    }
    while (_pages.length > widget.maxPages) {
      _pages.remove(_pages.keys.first);
    }
    final provider = context.read<AppStateProvider>();
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final e in _pages.entries)
          KeyedSubtree(
            key: ValueKey('cached_page_${e.key}_${e.value.generation}'),
            child: _CachedPage(
              active: e.key == page.key,
              provider: provider,
              child: e.value.child,
            ),
          ),
      ],
    );
  }
}

class _CachedPage extends StatelessWidget {
  const _CachedPage({
    required this.active,
    required this.provider,
    required this.child,
  });

  final bool active;
  final AppStateProvider provider;
  final Widget child;

  @override
  Widget build(BuildContext context) => Offstage(
        offstage: !active,
        child: TickerMode(
          enabled: active,
          child: ExcludeFocus(
            excluding: !active,
            child: GatedProvider(
              open: active,
              provider: provider,
              child: _PageFade(active: active, child: child),
            ),
          ),
        ),
      );
}

/// Holds [provider]'s notifications back from [child] while [open] is false,
/// and passes one on when it opens again if any were held.
class GatedProvider extends StatefulWidget {
  const GatedProvider({
    super.key,
    required this.open,
    required this.provider,
    required this.child,
  });

  final bool open;
  final AppStateProvider provider;
  final Widget child;

  @override
  State<GatedProvider> createState() => _GatedProviderState();
}

class _Gate extends ChangeNotifier {
  bool open = true;
  bool missed = false;

  void ping() {
    if (open) {
      notifyListeners();
    } else {
      missed = true;
    }
  }

  void setOpen(bool value) {
    open = value;
    if (value && missed) {
      missed = false;
      notifyListeners();
    }
  }
}

class _GatedProviderState extends State<GatedProvider> {
  final _Gate _gate = _Gate();

  @override
  void initState() {
    super.initState();
    _gate.open = widget.open;
    widget.provider.addListener(_gate.ping);
  }

  @override
  void didUpdateWidget(GatedProvider old) {
    super.didUpdateWidget(old);
    if (!identical(old.provider, widget.provider)) {
      old.provider.removeListener(_gate.ping);
      widget.provider.addListener(_gate.ping);
      _gate.missed = true;
    }
    _gate.setOpen(widget.open);
  }

  @override
  void dispose() {
    widget.provider.removeListener(_gate.ping);
    _gate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      InheritedProvider<AppStateProvider>.value(
        value: widget.provider,
        startListening: (element, _) {
          _gate.addListener(element.markNeedsNotifyDependents);
          return () => _gate.removeListener(element.markNeedsNotifyDependents);
        },
        child: widget.child,
      );
}

/// Fades the page in each time it is shown.
class _PageFade extends StatefulWidget {
  const _PageFade({required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  State<_PageFade> createState() => _PageFadeState();
}

class _PageFadeState extends State<_PageFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: kPageFade);
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: kMotionCurve);

  void _show() {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _c.value = 1;
    } else {
      _c.forward(from: 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.active && _c.status == AnimationStatus.dismissed) _show();
  }

  @override
  void didUpdateWidget(_PageFade old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _show();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _fade, child: widget.child);
}
