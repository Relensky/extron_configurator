import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app_state.dart';
import 'contrast.dart';

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

/// The fill for a snack bar that reports a failure.
///
/// `Colors.red` was doing this job, and it does not read: a snack bar's text
/// color comes from the theme (near-white on a light theme, near-black on a
/// dark one), and plain red measures between 3.1:1 and 5.4:1 against those
/// across this app's four themes — under the 4.5:1 that body text needs on
/// three of them.
///
/// So the FILL is chosen against the ink rather than fixed. Contrast is
/// symmetric, so this asks the same question the text colors ask, the other
/// way round: which of the theme's error tones can this text be read on. The
/// last resort is one of two Material error tones, because a snack bar that
/// has given up on being red has given up on saying "this failed".
Color snackErrorFillFor(ThemeData theme) {
  final ink = theme.snackBarTheme.contentTextStyle?.color ??
      theme.colorScheme.onInverseSurface;
  return readableOn(
    ink,
    prefer: [
      theme.colorScheme.error,
      theme.colorScheme.errorContainer,
      // M3's error tones, dark and light. One of the two clears 4.5:1 against
      // any ink there is.
      const Color(0xFF8C1D18),
      const Color(0xFFF9DEDC),
    ],
  );
}

/// [snackErrorFillFor], for the common case of having a context to hand.
Color snackErrorFill(BuildContext context) =>
    snackErrorFillFor(Theme.of(context));

/// [snackErrorFillFor] from the messenger the bar is going to.
///
/// Nearly every failure message in this app is reported after an await — a
/// file was written, a dialog closed, an export ran — and by then the widget's
/// own BuildContext may be gone. The messenger was captured before the gap
/// precisely because it outlives that, so it is also the right thing to read
/// the theme from.
Color snackErrorFillOn(ScaffoldMessengerState messenger) =>
    snackErrorFillFor(Theme.of(messenger.context));

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

/// ============================================================================
///  "SAVED" — AND WHERE IT WENT
/// ============================================================================
///  Every export ends the same way: a file dialog closes, the bytes go down,
///  and a bar says so. On its own that message is close to useless — the user
///  has just picked a folder and is now being told a name, with no way back to
///  either. So the bar carries the two buttons that answer the question it
///  raises: open the thing, or open the folder it landed in.
///
///  One helper rather than a copy per tab, because the copies drifted: two
///  pages offered the buttons, half a dozen offered a bare sentence, and which
///  you got depended on which tab you happened to press Export on.
/// ============================================================================

/// Says [what] was saved to [savedPath], with OPEN FILE and OPEN FOLDER on it.
///
/// [savedPath] may be a FOLDER — a layer export writes several files into one
/// — in which case pass [isFolder] and the single button opens it.
///
/// Held for ten seconds rather than the usual four: a file dialog has just
/// closed over the top of everything, and the buttons are no use to somebody
/// who is still looking at where the dialog was.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSavedSnackBar({
  required ScaffoldMessengerState messenger,
  required ThemeData theme,
  required AppStateProvider provider,
  required String message,
  required String savedPath,
  bool isFolder = false,
}) {
  Future<void> run(Future<String?> Function() action) async {
    final error = await action();
    if (error == null) return;
    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 5),
        content: Text(error),
        backgroundColor: Colors.red,
      ),
    );
  }

  final ButtonStyle actionStyle = TextButton.styleFrom(
    foregroundColor: theme.snackBarTheme.actionTextColor ??
        theme.colorScheme.onInverseSurface,
    textStyle: const TextStyle(fontWeight: FontWeight.bold),
  );

  return showTimedSnackBar(
    messenger,
    SnackBar(
      duration: const Duration(seconds: 10),
      content: Row(
        children: [
          Expanded(child: Text(message, overflow: TextOverflow.ellipsis)),
          if (!isFolder)
            TextButton(
              key: const ValueKey('saved_open_file'),
              style: actionStyle,
              onPressed: () => run(() => provider.openInDesktop(savedPath)),
              child: const Text('OPEN FILE'),
            ),
          TextButton(
            key: const ValueKey('saved_open_folder'),
            style: actionStyle,
            onPressed: () => run(
              () => isFolder
                  ? provider.openInDesktop(savedPath)
                  : provider.revealInFileManager(savedPath),
            ),
            child: const Text('OPEN FOLDER'),
          ),
        ],
      ),
    ),
  );
}

/// The same bar, phrased for the common case: `<what> saved as <file name>`.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSavedFileSnack(
  BuildContext context,
  AppStateProvider provider,
  String what,
  String savedPath,
) => showSavedSnackBar(
  messenger: ScaffoldMessenger.of(context),
  theme: Theme.of(context),
  provider: provider,
  message: '$what saved as ${p.basename(savedPath)}',
  savedPath: savedPath,
);

/// And for an export that wrote several files into one folder.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showSavedFolderSnack(
  BuildContext context,
  AppStateProvider provider,
  String message,
  String folder,
) => showSavedSnackBar(
  messenger: ScaffoldMessenger.of(context),
  theme: Theme.of(context),
  provider: provider,
  message: message,
  savedPath: folder,
  isFolder: true,
);
