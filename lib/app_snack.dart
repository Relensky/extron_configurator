import 'dart:async';

import 'package:flutter/material.dart';

/// ============================================================================
///  SNACK BARS THAT ACTUALLY GO AWAY
/// ============================================================================
///  A [SnackBar]'s own `duration` is not a timeout. The messenger starts that
///  clock when the entrance animation reports completed, and drops the bar when
///  the exit animation reports dismissed — so a bar shown at the same moment a
///  dialog is pushed, or one sitting behind a modal barrier while the user
///  reads it, can miss the transition that would have started or finished the
///  countdown and simply stay on screen. That is what the conversion notice
///  did: open a file that needs migrating, press CONVERT, and the notice was
///  still there afterwards, sitting over the bottom of the page for the rest of
///  the session.
///
///  The fix is not to fight the animation. It is to keep a timer of our own,
///  outside the widget tree, that closes the bar whether or not the animations
///  ever ran. Belt and braces: whichever fires first wins, and the second is a
///  no-op.
///
///  Use this for any message shown next to a dialog, a route push, or a file
///  picker. A plain `showSnackBar` is fine for a message shown from a button
///  press with nothing else happening.
/// ============================================================================

/// Shows [snackBar] and guarantees it disappears.
///
/// Anything already queued is cleared first: a notice that matters is not
/// worth showing after three others have had their turn, and a queue is how a
/// message ends up appearing half a minute after the thing it describes.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showTimedSnackBar(
  ScaffoldMessengerState messenger,
  SnackBar snackBar,
) {
  messenger.clearSnackBars();
  final controller = messenger.showSnackBar(snackBar);

  // Closed by the user, by its own animation, or by another bar replacing it.
  bool closed = false;
  controller.closed.then((_) => closed = true);

  // A moment past the bar's own duration, so the normal path gets to run first
  // and this only steps in when it didn't.
  Timer(snackBar.duration + const Duration(milliseconds: 400), () {
    if (!closed) controller.close();
  });
  return controller;
}
