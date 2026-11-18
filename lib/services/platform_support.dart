// ============================================================================
// [iOS STREAMLINED]: what this device can do, for hiding what it can't.
//
// Same file as the CTS Dashboard's lib/services/platform_support.dart, which
// lib/team/ imports in both apps. The Room Config Builder is a Windows app
// first: on an iPhone or iPad there are no other programs to start (Explorer,
// the other CTS apps, Python), no second app windows and no Windows sign-in,
// so features built on those are hidden there rather than left as buttons
// that do nothing.
// ============================================================================

import 'dart:io';

import 'package:flutter/widgets.dart';

/// True on iPhone and iPad.
bool get kIsIOS => Platform.isIOS;

/// Whether this device can start other programs (Process.run / start).
/// False on iOS and Android.
bool get kCanRunProcesses => !Platform.isIOS && !Platform.isAndroid;

/// Whether the app can open more app windows of its own (pop-outs, room and
/// tab windows), which start a second copy of the program. On iOS those
/// panels open inside the app instead.
bool get kCanOpenAppWindows => kCanRunProcesses;

/// [PHONE]: an iPhone-sized screen (either way up). Desktop-sized forms and
/// side-by-side layouts give way to simpler ones there.
bool isPhoneSized(BuildContext context) =>
    (Platform.isIOS || Platform.isAndroid) &&
    MediaQuery.sizeOf(context).shortestSide < 600;

/// [TOUCH GRIPS]: how thick a drag handle (a divider, a size bar) is: room
/// for a finger on an iPhone / iPad, the slim bar a mouse needs elsewhere.
double get kGripThickness => kIsIOS || Platform.isAndroid ? 28 : 14;
