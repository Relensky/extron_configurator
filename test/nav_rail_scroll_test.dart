import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/main.dart';
import 'package:extron_configurator/nav_rail.dart';

/// Fourteen tabs down the side of a window that is not fourteen tabs tall, in
/// a pane that can be dragged down to 72 pixels wide, at a text size somebody
/// can push to 150%. The rail has to stay reachable and readable through all
/// of that: the wheel scrolls it, the tab you land on comes into view, and no
/// label is ever painted wider than the pane it sits in.
void main() {
  AppStateProvider room({double scale = 1.0}) =>
      AppStateProvider(autoLoadSettings: false)
        ..settingsLoaded = true
        ..firstRunSetupNeeded = false
        ..textScale = scale;

  /// A window short enough that the rail cannot possibly fit — a laptop.
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
        of: find.byType(NavigationRail),
        matching: find.byType(Scrollable),
      ).first)
      .position;

  /// One notch of a mouse wheel over the middle of the rail.
  Future<void> wheel(WidgetTester tester, double dy) async {
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    final over = tester.getCenter(find.byType(NavigationRail));
    await tester.sendEventToBinding(pointer.hover(over));
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    await tester.pumpAndSettle();
  }

  testWidgets('the wheel scrolls the rail, both ways', (tester) async {
    await pumpApp(tester, room());
    final pos = railScroll(tester);
    // A rail taller than the window is the whole reason any of this exists.
    expect(pos.maxScrollExtent, greaterThan(0));
    expect(pos.pixels, 0);

    await wheel(tester, 200);
    expect(pos.pixels, greaterThan(0));
    final down = pos.pixels;

    await wheel(tester, -200);
    expect(pos.pixels, lessThan(down));
  });

  testWidgets('the last tab can be scrolled to and tapped', (tester) async {
    final p = room();
    await pumpApp(tester, p);
    // App Config is the bottom of the rail — the tab that used to be cut off.
    await wheel(tester, railScroll(tester).maxScrollExtent);
    await tester.tap(find.text('App Config'));
    await tester.pumpAndSettle();
    expect(p.selectedTabIndex, AppTab.appConfig.index);
  });

  testWidgets('a tab picked from elsewhere is scrolled into view',
      (tester) async {
    final p = room();
    await pumpApp(tester, p);
    final pos = railScroll(tester);
    expect(pos.pixels, 0);

    // Nothing to do with the rail: the wizard hands over to another tab, a
    // report jumps to Cabling. The rail still has to show where you are.
    p.selectTab(AppTab.appConfig.index);
    await tester.pumpAndSettle();
    expect(pos.pixels, greaterThan(0));

    // And back up again when the selection moves above the viewport.
    p.selectTab(AppTab.wizard.index);
    await tester.pumpAndSettle();
    expect(pos.pixels, 0);
  });

  /// A label that does not fit is not an exception and is not a wrong size —
  /// the box it is given is the box it reports. It is clipped, mid-word, and
  /// the only way to catch that is to ask the paragraph how narrow it could
  /// ever be: the minimum intrinsic width of wrapping text IS its longest
  /// word. Wider than the box it was given, and letters are being cut off.
  void expectNothingClipped(WidgetTester tester, String where) {
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

    final railWidth = tester.getSize(find.byType(NavigationRail)).width;
    expect(railWidth, lessThan(100), reason: 'the pane did not narrow');
    expectNothingClipped(tester, 'in the narrowed pane at 1.5 x text');
  });
}
