import 'dart:io' show Platform;

import 'dart:ui' show PlatformDispatcher;

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
bool get isMobileDevice =>
    debugMobileDevice ?? (Platform.isIOS || Platform.isAndroid);

/// Tests only: lays the app out as on a phone or tablet ([true]) on a desktop
/// test runner, so a sweep at phone size checks the phone's own layout.
@visibleForTesting
bool? debugMobileDevice;

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

/// True on a tablet: a mobile device that is not a phone - see [isPhone].
bool isTablet(BuildContext context) =>
    isMobileDevice && !isPhone(context);

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

/// Which kind of screen this is, for settings kept apart per kind - the
/// Interface Size and Text Size: '' on the desktop, '_ipad' or '_iphone'.
/// Read off the device's own screen, so it is known before anything is
/// drawn.
String get deviceSettingSuffix {
  if (!isMobileDevice) return '';
  try {
    final view = PlatformDispatcher.instance.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    if (size.isEmpty) return '_ipad';
    return size.shortestSide < 600 ? '_iphone' : '_ipad';
  } catch (_) {
    return '_ipad';
  }
}

/// The three kinds of screen the size settings are kept for.
const List<String> kDeviceSettingSuffixes = ['', '_ipad', '_iphone'];

/// A phone turned on its side: about 400 points high, so the bars across the
/// top and the tab bar along the bottom shrink to give the page the height.
bool phoneLandscape(BuildContext context) =>
    isPhone(context) &&
    MediaQuery.orientationOf(context) == Orientation.landscape;
