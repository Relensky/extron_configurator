import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/av_flow_model.dart';
import 'package:extron_configurator/av_flow_view.dart';
import 'package:extron_configurator/screenshot_tools.dart';

/// Which way the signal goes on the run that is selected.
///
/// A selected cable was already drawn thicker and haloed, which says "this
/// one" and nothing else. The question that actually follows a click on a
/// crowded canvas is the other one - which end is this feeding? - so the
/// selected run's chevrons travel along it towards the destination.
///
/// Two failures this guards, and the second is the expensive one:
///
///   * The animation not running when a run is picked, which is the feature.
///   * The animation still running when nothing is picked. This page is left
///     open all afternoon, and a ticker nobody can see is a laptop fan.
void main() {
  AvNode switcher() => const AvNode(
    id: 'SWITCHERDEVICE_1',
    label: 'Switcher',
    model: 'SW4 HD 4K PLUS',
    pos: Offset(40, 60),
    fromConfig: true,
    rackUnits: 1,
    ports: [
      AvPort(
        id: 'out_hdmi_1',
        label: 'HDMI OUT',
        signal: SignalType.hdmi,
        direction: PortDirection.output,
        side: PortSide.right,
      ),
    ],
  );

  AvNode projector() => const AvNode(
    id: 'PROJECTORDEVICE_1',
    label: 'Projector',
    model: 'PowerLite L610U',
    pos: Offset(500, 60),
    fromConfig: true,
    ports: [
      AvPort(
        id: 'in_hdmi_1',
        label: 'HDMI IN',
        signal: SignalType.hdmi,
        direction: PortDirection.input,
        side: PortSide.left,
      ),
    ],
  );

  /// A room with one run on it, from a switcher on the left to a projector on
  /// the right.
  AppStateProvider seeded() {
    final p = AppStateProvider(autoLoadSettings: false)
      ..roomConfig = {
        'SYSTEM_SETUP': {'gui_full_room_name': 'Test Room'},
      };
    p.loadAvFlowForCurrentConfig();
    p.addAvNode(switcher());
    p.addAvNode(projector());
    p.addAvCable(
      fromNodeId: 'SWITCHERDEVICE_1',
      fromPortId: 'out_hdmi_1',
      toNodeId: 'PROJECTORDEVICE_1',
      toPortId: 'in_hdmi_1',
      signal: SignalType.hdmi,
    );
    return p;
  }

  Future<void> pumpTab(WidgetTester tester, AppStateProvider provider) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: provider,
        child: const MaterialApp(home: Scaffold(body: AvFlowView())),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// True while something on screen is driving frames.
  ///
  /// The chevrons are the only animation on a settled AV canvas, so this IS
  /// the question every test here asks. It is also how the second failure
  /// shows up: a ticker left running with nothing selected.
  bool animating(WidgetTester tester) =>
      tester.binding.transientCallbackCount > 0;

  /// Where canvas coordinates land on screen.
  ///
  /// The drawing sits under a toolbar and inside a pan-and-zoom viewport, so a
  /// point on the diagram is not a point on the window. A cable LABEL is the
  /// one widget whose canvas position is readable (its Positioned) alongside
  /// its screen position (its rect), and the difference between the two is the
  /// offset every other canvas point needs.
  Offset canvasOrigin(WidgetTester tester, String cableId) {
    final finder = find.byKey(ValueKey('av_cable_label_$cableId'));
    final placed = tester.widget<Positioned>(finder);
    return tester.getRect(finder).topLeft -
        Offset(placed.left ?? 0, placed.top ?? 0);
  }

  /// Clicks the run, wherever the router put it.
  ///
  /// A cable is PAINT rather than a widget, so there is nothing to find it by
  /// and no fixed point to press: the route is worked out per build, around
  /// whatever else is on the page. Walking the gap between the two boxes finds
  /// the line without this test having to know how the router thinks.
  Future<void> tapTheRun(
    WidgetTester tester,
    AppStateProvider provider,
  ) async {
    final origin = canvasOrigin(tester, provider.avCables.single.id);
    for (var y = 60.0; y <= 220.0; y += 4) {
      for (var x = 200.0; x <= 480.0; x += 20) {
        await tester.tapAt(origin + Offset(x, y));
        await tester.pump();
        if (animating(tester)) return;
      }
    }
    fail('never landed on the run between the two boxes');
  }

  /// Clicks bare canvas, which is how a selection is dropped.
  Future<void> tapEmptyCanvas(
    WidgetTester tester,
    AppStateProvider provider,
  ) async {
    final origin = canvasOrigin(tester, provider.avCables.single.id);
    await tester.tapAt(origin + const Offset(300, 400));
    await tester.pump();
  }

  testWidgets('a canvas with nothing picked animates nothing', (tester) async {
    await pumpTab(tester, seeded());
    // pumpTab settled, which it could not have done with a ticker running.
    // Said out loud because it is the contract rather than a side effect.
    expect(animating(tester), isFalse);
  });

  testWidgets('picking a run starts it travelling', (tester) async {
    final provider = seeded();
    await pumpTab(tester, provider);
    await tapTheRun(tester, provider);

    expect(animating(tester), isTrue,
        reason: 'the selected run has to move to be found');

    // It repeats rather than playing once: a run picked and looked at ten
    // seconds later is still the run that is picked.
    await tester.pump(const Duration(seconds: 3));
    expect(animating(tester), isTrue);
  });

  testWidgets('clicking bare canvas stops it again', (tester) async {
    final provider = seeded();
    await pumpTab(tester, provider);
    await tapTheRun(tester, provider);
    expect(animating(tester), isTrue);

    await tapEmptyCanvas(tester, provider);

    expect(animating(tester), isFalse,
        reason: 'nothing is selected, so nothing should be driving frames');
    // The same statement made the way a build that forgot it would be found:
    // a page that never settles.
    await tester.pumpAndSettle();
  });

  testWidgets('leaving edit mode stops it', (tester) async {
    final provider = seeded();
    await pumpTab(tester, provider);
    await tapTheRun(tester, provider);
    expect(animating(tester), isTrue);

    // Edit mode drops the selection with it, and the ticker has to go too.
    //
    // Settled rather than pumped once: pressing a chip starts a ripple and a
    // selection animation of its own, so a frame after the tap something IS
    // driving frames and it is not this. That the page settles at all is the
    // assertion - a run still travelling would never let it.
    await tester.tap(find.widgetWithText(FilterChip, 'Edit'));
    await tester.pumpAndSettle();
    expect(animating(tester), isFalse);
  });

  testWidgets('it stands down while the diagram is being photographed',
      (tester) async {
    // The chevrons are a selection affordance with no still frame that means
    // anything, and their phase at the instant of a capture is arbitrary. A
    // printed sheet carries direction in the arrowhead instead.
    final provider = seeded();
    await pumpTab(tester, provider);
    await tapTheRun(tester, provider);
    expect(animating(tester), isTrue);

    capturingDiagram.value = true;
    addTearDown(() => capturingDiagram.value = false);
    await tester.pump();
    expect(animating(tester), isFalse,
        reason: 'the layer is off, so nothing is asking for frames');

    capturingDiagram.value = false;
    await tester.pump();
    expect(animating(tester), isTrue, reason: 'and it comes back afterwards');
    // Long enough for the double-tap trackers the scan above left behind to
    // time out. They are gesture bookkeeping, not part of what is being
    // tested, and a test that walks away mid-countdown fails on a pending
    // timer rather than on anything real.
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('deleting the picked run stops it', (tester) async {
    final provider = seeded();
    await pumpTab(tester, provider);
    await tapTheRun(tester, provider);
    expect(animating(tester), isTrue);

    // A run deleted while it was selected leaves its id behind. The waypoint
    // handles and the flow layer both tolerate that and draw nothing, but a
    // ticker spinning for a line that is no longer on the canvas is the worse
    // of the two failures this file guards.
    provider.removeAvCable(provider.avCables.first.id);
    await tester.pump();
    await tester.pump();

    expect(animating(tester), isFalse);
    await tester.pumpAndSettle();
  });
}
