import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

import 'app_state.dart';

/// ============================================================================
///  WHAT KIND OF SCREEN THIS IS
/// ============================================================================
///  The app is laid out for a desktop window. An iPad gets that layout a notch
///  tighter (see main.dart and cost_estimate_view.dart); an iPhone gets a
///  slimmer app: a bottom tab bar instead of the side rail, the tabs somebody
///  uses standing in a room rather than all sixteen, and pages laid out to the
///  phone's own width instead of scrolling sideways.
/// ============================================================================

/// iPad, iPhone or an Android device.
bool get isMobileDevice => Platform.isIOS || Platform.isAndroid;

/// True on a phone: a mobile device whose screen is under 600 points on its
/// short side, measured off the device itself rather than the app's scaled
/// layout, so it does not change with the Interface Size.
bool isPhone(BuildContext context) {
  if (!isMobileDevice) return false;
  final view = View.maybeOf(context);
  if (view == null) return false;
  final size = view.physicalSize / view.devicePixelRatio;
  return size.shortestSide < 600;
}

/// The tabs a phone shows, besides Project in the bar across the top. The
/// rest - the catalog, the schema, the drawings that need a pointer and a big
/// screen - stay on the desktop and the iPad.
const Set<AppTab> kPhoneTabs = {
  AppTab.cost,
  AppTab.lifecycle,
  AppTab.wizard,
  AppTab.floorPlan,
  AppTab.walls,
  AppTab.racks,
  AppTab.photos,
};
