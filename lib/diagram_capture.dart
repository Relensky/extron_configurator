import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'screenshot_tools.dart';

/// ============================================================================
///  CAPTURING THE DIAGRAMS
/// ============================================================================
///  Only a widget that is ON SCREEN can be rendered to an image, and each of
///  the three drawings lives on a tab of its own. A document that covers all
///  three — the room workbook, the Save All folder — therefore has to visit
///  each tab in turn, capture it, and put the user back where they were.
///
///  Each page registers its canvas here as it mounts, so a capture grabs
///  exactly the drawing rather than the tab around it: a rack elevation
///  embedded in a report with the page's toolbar across the top of it is a
///  picture somebody has to apologize for.
///
///  A page that is not registered simply yields no image — an AV-only room has
///  no control schematic to capture, and a workbook missing one illustration
///  is still the workbook.
/// ============================================================================

/// The canvas on each diagram tab, by the tab it belongs to.
final Map<AppTab, GlobalKey> _canvases = {};

/// Called by a diagram page as it mounts. The key must be on a
/// [RepaintBoundary] wrapped round the drawing itself.
void registerDiagramCanvas(AppTab tab, GlobalKey key) {
  _canvases[tab] = key;
}

/// Called as the page is disposed. The identity check matters: tabs are built
/// and torn down as the rail is clicked, and a page going away AFTER its
/// replacement registered must not unregister the live one.
void unregisterDiagramCanvas(AppTab tab, GlobalKey key) {
  if (identical(_canvases[tab], key)) _canvases.remove(tab);
}

/// What a capture run produced. Null means that drawing could not be had —
/// the tab does not exist in this room, or it had nothing on it.
typedef DiagramImages = ({
  Uint8List? schematic,
  Uint8List? avFlow,
  Uint8List? racks,
  Uint8List? floorPlan,
});

/// No drawings at all — for the callers that skip the capture entirely.
const DiagramImages kNoDiagramImages =
    (schematic: null, avFlow: null, racks: null, floorPlan: null);

/// Visits each diagram tab, captures its canvas, and returns to the tab the
/// user was on.
///
/// This is visible — the page flicks through three tabs and comes back — so
/// callers should say what is happening before starting it.
///
/// The caller must not assume it is still mounted afterwards: switching tabs
/// disposes the page the export was started from. Take a
/// [ScaffoldMessengerState] before calling, and report through that.
Future<DiagramImages> captureDiagramTabs(
  AppStateProvider provider, {
  double pixelRatio = 1.5,
}) async {
  final int startingTab = provider.selectedTabIndex;

  Future<Uint8List?> capture(AppTab tab) async {
    provider.selectTab(tab.index);
    // Two frames plus a beat: the tab has to be built, laid out and painted
    // before its RepaintBoundary has anything to hand over.
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 320));
    await WidgetsBinding.instance.endOfFrame;
    final key = _canvases[tab];
    if (key == null) return null;
    return captureBoundary(key, pixelRatio: pixelRatio);
  }

  final schematic = await capture(AppTab.schematic);
  final avFlow = await capture(AppTab.avFlow);
  // An empty Racks page is a sentence saying there are no racks. The sheet
  // already says that in words, and a picture of the sentence helps nobody.
  final racks = provider.avRacks.isEmpty ? null : await capture(AppTab.racks);
  // Same rule for the plan: with no image imported the page is an invitation
  // to import one, which is not an illustration of this room.
  final floorPlan = provider.primaryFloorPlan?.hasImage == true
      ? await capture(AppTab.floorPlan)
      : null;

  provider.selectTab(startingTab);
  await WidgetsBinding.instance.endOfFrame;

  return (
    schematic: schematic,
    avFlow: avFlow,
    racks: racks,
    floorPlan: floorPlan,
  );
}
