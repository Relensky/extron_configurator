import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';
import 'package:extron_configurator/nav_rail.dart';

/// Fifteen tabs down the side of a window that is not fifteen tabs tall, in a
/// pane that can be dragged down to 72 pixels wide, at a text size somebody can
/// push to 150%.
///
/// The rail's job is to FIT: every tab on screen at once, at any window size
/// anybody actually uses, with no label clipped. A rail you have to scroll to
/// reach App Config is a rail where App Config may as well not exist.
///
/// Scrolling is still here for the window so short that even the minimum
/// legible row cannot fit fifteen times — and the checks below say which case
/// is which, so a regression that quietly brings the scrollbar back on a
/// laptop fails rather than passing.
void main() {
  AppStateProvider room({double scale = 1.0}) =>
      AppStateProvider(autoLoadSettings: false)
        ..settingsLoaded = true
        ..firstRunSetupNeeded = false
        ..textScale = scale;

  Future<void> pumpApp(
    WidgetTester tester,
    AppStateProvider provider, {
    Size size = const Size(1200, 600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const RoomConfigApp(),
      ),
    );
    await tester.pump();
  }

  ScrollPosition railScroll(WidgetTester tester) => tester
      .state<ScrollableState>(find.ancestor(
        of: find.byType(NavRailRow).first,
        matching: find.byType(Scrollable),
      ).first)
      .position;

  /// One notch of a mouse wheel over the rail.
  Future<void> wheel(WidgetTester tester, double dy) async {
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    // The viewport, not a row: once the rail has scrolled, the first row is
    // off the top and the event would land on nothing.
    final over = tester.getCenter(find.byType(Scrollable).first);
    await tester.sendEventToBinding(pointer.hover(over));
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    await tester.pumpAndSettle();
  }

  /// True when the rail is showing words. On a window too short for fifteen
  /// labelled rows it falls back to icons with tooltips, and asking after the
  /// labels then is asking after something the rail deliberately does not have.
  bool railHasLabels(WidgetTester tester) =>
      tester.widget<NavRailRow>(find.byType(NavRailRow).first).fit.labels;

  /// The bottom of the last row, against the bottom of the window.
  void expectEveryTabOnScreen(WidgetTester tester, String where) {
    expect(find.byType(NavRailRow), findsNWidgets(kNavTabs.length));
    final rows = find.byType(NavRailRow);
    final last = tester.getRect(rows.last);
    final viewport = tester.getRect(find.byType(Scrollable).first);
    expect(
      last.bottom,
      lessThanOrEqualTo(viewport.bottom + 0.5),
      reason: 'the last tab is off the bottom $where',
    );
    expect(
      railScroll(tester).maxScrollExtent,
      // Not exactly zero: the rows are sized from measured text, so fifteen of
      // them land on the viewport height give or take a rounding error.
      lessThan(1),
      reason: 'the rail still needs scrolling $where',
    );
  }

  group('every tab fits, without scrolling', () {
    for (final size in [
      const Size(1200, 600), // the laptop that used to cut tabs off
      const Size(1600, 900),
      const Size(1920, 1080),
      const Size(1200, 500), // a short window somebody has dragged down
    ]) {
      testWidgets('${size.width.round()}x${size.height.round()}',
          (tester) async {
        await pumpApp(tester, room(), size: size);
        expectEveryTabOnScreen(tester, 'at ${size.height.round()} px tall');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('and at 150% text on a laptop', (tester) async {
      await pumpApp(tester, room(scale: 1.5));
      expectEveryTabOnScreen(tester, 'at 1.5 x text');
    });
  });

  testWidgets('the last tab can be tapped without scrolling to it',
      (tester) async {
    final p = room();
    await pumpApp(tester, p);
    // The row itself, not its label — the rail drops to icons on a window too
    // short for words, and the bottom tab has to stay reachable either way.
    await tester.tap(find.byType(NavRailRow).last);
    await tester.pumpAndSettle();
    expect(p.selectedTabIndex, AppTab.appConfig.index);
  });

  testWidgets('a window with no room for words keeps every tab, as icons',
      (tester) async {
    await pumpApp(tester, room(scale: 1.5), size: const Size(1200, 420));
    expect(railHasLabels(tester), isFalse);
    expectEveryTabOnScreen(tester, 'as icons at 1.5 x text');
    // The word is still reachable.
    expect(find.byType(Tooltip), findsWidgets);
  });

  testWidgets('rows are more generous when there is room for it',
      (tester) async {
    // The shrinking is supposed to be a response to a short window, not the
    // permanent state: a big screen should not get the cramped rail.
    await pumpApp(tester, room(), size: const Size(1200, 500));
    final tight = tester.getSize(find.byType(NavRailRow).first).height;

    await pumpApp(tester, room(), size: const Size(1200, 1400));
    final roomy = tester.getSize(find.byType(NavRailRow).first).height;

    expect(roomy, greaterThan(tight));
  });

  group('the window too short for even the minimum row', () {
    // 250 px of rail cannot hold fifteen legible tabs by any arithmetic, so
    // this is where scrolling still earns its place.
    const tiny = Size(1200, 250);

    testWidgets('scrolls, both ways', (tester) async {
      await pumpApp(tester, room(), size: tiny);
      final pos = railScroll(tester);
      expect(pos.maxScrollExtent, greaterThan(0));

      await wheel(tester, 200);
      expect(pos.pixels, greaterThan(0));
      final down = pos.pixels;

      await wheel(tester, -200);
      expect(pos.pixels, lessThan(down));
    });

    testWidgets('and brings a tab picked elsewhere into view', (tester) async {
      final p = room();
      await pumpApp(tester, p, size: tiny);
      final pos = railScroll(tester);
      expect(pos.pixels, 0);

      // Nothing to do with the rail: the wizard hands over to another tab, a
      // report jumps to Cabling. The rail still has to show where you are.
      p.selectTab(AppTab.appConfig.index);
      await tester.pumpAndSettle();
      expect(pos.pixels, greaterThan(0));

      p.selectTab(AppTab.project.index);
      await tester.pumpAndSettle();
      expect(pos.pixels, 0);
    });
  });

  /// A label that does not fit is not an exception and is not a wrong size —
  /// the box it is given is the box it reports. It is clipped, mid-word, and
  /// the only way to catch that is to ask the paragraph how narrow it could
  /// ever be: the minimum intrinsic width of wrapping text IS its longest
  /// word. Wider than the box it was given, and letters are being cut off.
  void expectNothingClipped(WidgetTester tester, String where) {
    if (!railHasLabels(tester)) {
      // Icon-only: every tab is still there and its word is a hover away.
      expect(find.byType(NavRailRow), findsNWidgets(kNavTabs.length));
      expect(find.byType(Tooltip), findsWidgets, reason: 'no tooltips $where');
      expect(tester.takeException(), isNull);
      return;
    }
    for (final tab in kNavTabs) {
      final label = find.text(tab.label);
      expect(label, findsWidgets, reason: '${tab.label} is missing');
      final para = tester.renderObject<RenderParagraph>(label.first);
      expect(
        para.getMinIntrinsicWidth(double.infinity),
        lessThanOrEqualTo(para.size.width + 0.5),
        reason: '${tab.label} is clipped $where',
      );
    }
    expect(tester.takeException(), isNull);
  }

  group('labels fit the pane at every text size', () {
    for (final scale in [1.0, 1.15, 1.3, 1.5]) {
      testWidgets('$scale x text', (tester) async {
        await pumpApp(tester, room(scale: scale));
        expectNothingClipped(tester, 'at $scale x text');
      });
    }
  });

  testWidgets('labels still fit when the pane is dragged to its narrowest',
      (tester) async {
    await pumpApp(tester, room(scale: 1.5));
    // The divider between the pane and the page is the resize handle; drag it
    // far enough left that the pane clamps to its minimum width.
    await tester.drag(
      find.byKey(const ValueKey('pane_grip_nav_rail')),
      const Offset(-400, 0),
    );
    await tester.pumpAndSettle();

    final railWidth = tester.getSize(find.byType(NavRailRow).first).width;
    expect(railWidth, lessThan(100), reason: 'the pane did not narrow');
    expectNothingClipped(tester, 'in the narrowed pane at 1.5 x text');
    // Narrow AND tall-text is the worst case for fitting, and it still must.
    expectEveryTabOnScreen(tester, 'in the narrowed pane at 1.5 x text');
  });
}
