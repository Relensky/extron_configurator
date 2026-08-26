import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_logger.dart';
import 'app_state.dart';
import 'av_flow_view.dart' show buildAvFlowModel;
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

/// The drawing on [tab] as it is on screen RIGHT NOW, or null when that tab
/// has no canvas registered (it is not the tab being looked at, or it is not a
/// drawing tab at all).
///
/// What the per-tab exports use: the tab exporting itself is by definition the
/// one on screen, so there is nothing to visit and nothing to put back.
Future<Uint8List?> captureCurrentDiagram(
  AppTab tab, {
  double pixelRatio = 1.5,
}) async {
  final key = _canvases[tab];
  if (key == null) return null;
  return captureBoundary(key, pixelRatio: pixelRatio);
}

/// ---------------------------------------------------------------------------
///  THE PLAN TAB'S SHEETS
/// ---------------------------------------------------------------------------
///  Every other drawing tab holds exactly one drawing, so one canvas key is
///  enough to fetch it. The plan tab does not: a room has a sheet per storey,
///  a reflected ceiling plan beside the furniture plan, a demolition sheet
///  beside the new work, and only the one being looked at is mounted.
///
///  So the page registers HOW TO WALK THEM rather than just where its canvas
///  is, and every export asks for the set. Before this each exporter captured
///  whichever sheet happened to be open, which is how a set gets issued with
///  the ceiling plan missing.

/// One drawing captured off the plan tab.
///
/// [name] is short enough and clean enough for an Excel tab; [caption] is what
/// it is called in prose and what a file is named after; [bytes] is the PNG.
typedef PlanDrawing = ({String name, String caption, Uint8List bytes});

/// How the plan page renders every sheet in the room.
///
/// [perLayer] adds one drawing per cable type on each sheet, after that
/// sheet's "all runs" drawing — a set issued a trade at a time. [monochrome]
/// renders them the way they should print.
typedef PlanSheetCapture =
    Future<List<PlanDrawing>> Function({bool perLayer, bool monochrome});

PlanSheetCapture? _planSheets;

/// Called by the plan page as it mounts.
void registerPlanSheetCapture(PlanSheetCapture capture) {
  _planSheets = capture;
}

/// Called as the plan page is disposed. Checked for the same reason
/// [unregisterDiagramCanvas] is: a page going away AFTER its replacement
/// registered must not unregister the live one.
///
/// `==` rather than `identical`, because two tear-offs of the same method on
/// the same object are equal but need not be the same object — while two
/// pages' tear-offs are never equal, which is the distinction being made here.
void unregisterPlanSheetCapture(PlanSheetCapture capture) {
  if (_planSheets == capture) _planSheets = null;
}

/// Every plan sheet in the room, drawn and captured one at a time.
///
/// Empty when the plan page is not on screen — the caller must be standing on
/// it, or must have visited it first ([captureDiagramTabs] does). An empty
/// list is the same answer a room with no plan gives, and every caller already
/// has to survive that.
Future<List<PlanDrawing>> capturePlanSheets({
  bool perLayer = false,
  bool monochrome = false,
}) async {
  final capture = _planSheets;
  if (capture == null) return const [];
  return capture(perLayer: perLayer, monochrome: monochrome);
}

/// What a capture run produced. Null means that drawing could not be had —
/// the tab does not exist in this room, or it had nothing on it.
///
/// The plan is a LIST because the tab holds a sheet per storey. A single
/// `floorPlan` field is how documents ended up carrying whichever sheet
/// happened to be open, so there is no longer one to reach for: a caller with
/// room for only one picture takes the first and says so.
typedef DiagramImages = ({
  Uint8List? schematic,
  Uint8List? avFlow,
  Uint8List? racks,
  List<PlanDrawing> floorPlanSheets,
  Uint8List? cabling,
});

/// No drawings at all — for the callers that skip the capture entirely.
const DiagramImages kNoDiagramImages = (
  schematic: null,
  avFlow: null,
  racks: null,
  floorPlanSheets: <PlanDrawing>[],
  cabling: null,
);

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

  // EVERY DRAWING IS INDEPENDENTLY OPTIONAL.
  //
  // [captureBoundary] already survives anything the rasteriser throws, but the
  // decisions AROUND it did not: whether a room has racks, whether it has plan
  // sheets, and what its cabling schematic comes to are all worked out from
  // the room's own data, and a room with a plan whose image file has moved or
  // a run pointing at a device that has since been deleted throws while that
  // question is being asked - before any picture is taken.
  //
  // Unguarded, one such room took the whole capture with it. That is survivable
  // when somebody presses the button on a room they are looking at; it is not
  // when the Save All walk photographs nine rooms nobody has opened in months,
  // because the run died half way through and left the session parked on
  // another room's Schematic tab. A drawing that cannot be had is already a
  // null in this record - that is what the type is for - so a failure here is
  // reported as the missing picture it actually is, and the other four still
  // come back.
  Future<T> attempt<T>(String what, Future<T> Function() body, T fallback) async {
    try {
      return await body();
    } catch (e, stack) {
      AppLogger.logError('Could not capture the $what for this room', e, stack);
      return fallback;
    }
  }

  final schematic = await attempt('control schematic',
      () => capture(AppTab.schematic), null);
  final avFlow = await attempt('signal flow',
      () => capture(AppTab.avFlow), null);
  // An empty Racks page is a sentence saying there are no racks. The sheet
  // already says that in words, and a picture of the sentence helps nobody.
  final racks = await attempt(
    'rack elevation',
    () async => provider.avRacks.isEmpty ? null : await capture(AppTab.racks),
    null,
  );
  // Same rule for the plan: with no image imported the page is an invitation
  // to import one, which is not an illustration of this room.
  //
  // EVERY sheet, not just the one that was open. A room with a furniture plan
  // and a reflected ceiling plan is a room whose documents need both, and the
  // page has to be visited for any of them — so it is walked here, once, and
  // every document downstream is dealt from the same set.
  final planSheets = await attempt<List<PlanDrawing>>(
    'floor plans',
    () async {
      if (provider.floorPlanSheetsWithImages.isEmpty) return const [];
      provider.selectTab(AppTab.floorPlan.index);
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 320));
      await WidgetsBinding.instance.endOfFrame;
      return capturePlanSheets();
    },
    const [],
  );
  // Same rule again: with nowhere for the drawing to come from, the Cabling
  // page is an invitation to name some locations, and a picture of an
  // invitation illustrates nothing.
  final cabling = await attempt(
    'cabling drawing',
    () async =>
        provider.cablingSchematic(buildAvFlowModel(provider)).boxes.isEmpty
            ? null
            : await capture(AppTab.cabling),
    null,
  );

  // BACK TO THE TAB THE READER WAS ON, whatever happened above. Everything in
  // this function has moved the session somewhere it did not ask to be, and
  // leaving it there is the part that reads as a crash.
  provider.selectTab(startingTab);
  await WidgetsBinding.instance.endOfFrame;

  return (
    schematic: schematic,
    avFlow: avFlow,
    racks: racks,
    floorPlanSheets: planSheets,
    cabling: cabling,
  );
}
