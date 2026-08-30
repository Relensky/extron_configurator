import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'room_sidecar.dart' show AvUndoScope, kAvUndoScopeLabels;

/// ============================================================================
///  UNDO / REDO, PER TAB
/// ============================================================================
///  Four pages edit the room's document, and each keeps its own history — see
///  [AvUndoScope]. The buttons are built here rather than four times over,
///  because the four copies had already drifted apart in wording and in what
///  they said after the press, and a pair of buttons that behaves differently
///  depending on which tab you are standing on is worse than no pair at all.
///
///  The one thing worth knowing is why Undo is sometimes greyed with a history
///  behind it. A few edits genuinely span tabs — removing a location clears it
///  off the devices that named it, removing a device vacates its rack rail —
///  and one of those can only be undone while it is still the newest edit in
///  every tab it touched. Otherwise undoing it here would roll another tab
///  back over work done since. The tooltip says which tab to deal with first,
///  and undoing there frees this one.
/// ============================================================================

/// The Undo and Redo buttons for [scope]'s history.
///
/// [onDone] is handed what happened, for the page's own message — the tabs
/// report it differently enough (some through a helper, some inline) that
/// showing it here would mean passing a messenger around for no gain.
List<Widget> avUndoRedoButtons(
  AppStateProvider provider,
  AvUndoScope scope, {
  required void Function(String message) onDone,
}) {
  Widget button({
    required IconData icon,
    required String verb,
    required bool enabled,
    required String label,
    required String blockedBy,
    required VoidCallback onPressed,
  }) {
    final button = OutlinedButton.icon(
      icon: Icon(icon, size: 18),
      label: Text(enabled ? '$verb: $label' : verb),
      onPressed: enabled ? onPressed : null,
    );
    if (blockedBy.isEmpty) return button;
    return Tooltip(
      message:
          '$verb is waiting on a later edit on the $blockedBy tab, which this '
          'one would undo with it. Deal with that tab first.',
      child: button,
    );
  }

  return [
    button(
      icon: Icons.undo,
      verb: 'Undo',
      enabled: provider.canUndoAvFlow(scope),
      label: provider.avUndoLabel(scope),
      blockedBy: provider.avUndoBlockedBy(scope),
      onPressed: () {
        final undone = provider.undoAvFlow(scope);
        if (undone.isNotEmpty) onDone('Undid: $undone');
      },
    ),
    button(
      icon: Icons.redo,
      verb: 'Redo',
      enabled: provider.canRedoAvFlow(scope),
      label: provider.avRedoLabel(scope),
      blockedBy: provider.avRedoBlockedBy(scope),
      onPressed: () {
        final redone = provider.redoAvFlow(scope);
        if (redone.isNotEmpty) onDone('Redid: $redone');
      },
    ),
  ];
}

/// The same pair, as icons, for a row that has no width to spare.
///
/// The step's name moves into the tooltip rather than being dropped: it is the
/// whole reason the buttons are worth having — "Undo" alone asks somebody to
/// remember what they last did, which is what the person reaching for it has
/// just lost track of. The Lifecycle page uses these because its row already
/// carries two buttons, a sentence and a toggle, and a labelled pair pushed the
/// sentence off the screen.
List<Widget> avUndoRedoIconButtons(
  AppStateProvider provider,
  AvUndoScope scope, {
  required void Function(String message) onDone,
}) {
  Widget button({
    required IconData icon,
    required String verb,
    required bool enabled,
    required String label,
    required String blockedBy,
    required VoidCallback onPressed,
  }) =>
      IconButton(
        key: ValueKey('${scope.name}_${verb.toLowerCase()}_icon'),
        icon: Icon(icon, size: 18),
        onPressed: enabled ? onPressed : null,
        tooltip: blockedBy.isNotEmpty
            ? '$verb is waiting on a later edit on the $blockedBy tab, which '
                'this one would undo with it. Deal with that tab first.'
            : enabled
                ? '$verb: $label'
                : 'Nothing to ${verb.toLowerCase()}',
      );

  return [
    button(
      icon: Icons.undo,
      verb: 'Undo',
      enabled: provider.canUndoAvFlow(scope),
      label: provider.avUndoLabel(scope),
      blockedBy: provider.avUndoBlockedBy(scope),
      onPressed: () {
        final undone = provider.undoAvFlow(scope);
        if (undone.isNotEmpty) onDone('Undid: $undone');
      },
    ),
    button(
      icon: Icons.redo,
      verb: 'Redo',
      enabled: provider.canRedoAvFlow(scope),
      label: provider.avRedoLabel(scope),
      blockedBy: provider.avRedoBlockedBy(scope),
      onPressed: () {
        final redone = provider.redoAvFlow(scope);
        if (redone.isNotEmpty) onDone('Redid: $redone');
      },
    ),
  ];
}

/// What [scope]'s history is called on screen, for a message that has to name
/// another tab.
String avUndoScopeLabel(AvUndoScope scope) =>
    kAvUndoScopeLabels[scope] ?? scope.name;

// ---------------------------------------------------------------------------
//  THE PAIR IN THE TITLE BAR
// ---------------------------------------------------------------------------
//  The four drawing tabs carry their own Undo, because each of them has its
//  own history over its own slice of the room and the buttons belong beside the
//  thing they act on. The other pages do not: the wizard, the device forms,
//  system settings and the raw JSON are four views of ONE document, and the job
//  is a document with no canvas at all.
//
//  So those get their pair in the title bar, next to Save, driven by the same
//  question Save already answers — which document is this page editing. That
//  keeps the promise the toolbar already makes: the button acts on what you are
//  looking at, and says which document that is.
//
//  A PAGE THAT HAS ITS OWN BUTTONS DOES NOT GET THESE. Two Undo buttons on one
//  screen meaning two different things is worse than one of them being missing:
//  somebody presses the near one and the far one is what they meant.

/// Which document the title bar's Undo acts on for [tab], or null when the page
/// keeps its own.
ToolbarUndoTarget? toolbarUndoTarget(AppTab tab) => switch (tab) {
      AppTab.project => ToolbarUndoTarget.project,
      // The four views of the room's config file.
      AppTab.wizard ||
      AppTab.devices ||
      AppTab.system ||
      AppTab.rawJson =>
        ToolbarUndoTarget.roomConfig,
      // Everything else either draws its own pair (the four drawing tabs, the
      // schematic, the estimate) or edits a document with no history yet (the
      // catalog, the schema, the rule book, app settings).
      _ => null,
    };

/// The document the title bar's Undo would act on.
enum ToolbarUndoTarget { project, roomConfig }

/// Undo and Redo for whichever document the page on screen is editing.
///
/// Renders nothing at all on a page that keeps its own pair — see
/// [toolbarUndoTarget].
class ToolbarUndoButtons extends StatelessWidget {
  final AppTab tab;

  const ToolbarUndoButtons({super.key, required this.tab});

  @override
  Widget build(BuildContext context) {
    final target = toolbarUndoTarget(tab);
    if (target == null) return const SizedBox.shrink();
    final provider = context.watch<AppStateProvider>();

    final noun = target == ToolbarUndoTarget.project ? 'project' : 'room';
    final canUndo = target == ToolbarUndoTarget.project
        ? provider.canUndoProject
        : provider.canUndoRoomConfig;
    final canRedo = target == ToolbarUndoTarget.project
        ? provider.canRedoProject
        : provider.canRedoRoomConfig;
    final undoLabel = target == ToolbarUndoTarget.project
        ? provider.projectUndoLabel
        : provider.roomConfigUndoLabel;
    final redoLabel = target == ToolbarUndoTarget.project
        ? provider.projectRedoLabel
        : provider.roomConfigRedoLabel;

    void report(String message) {
      if (message.isEmpty) return;
      showTimedSnackBar(
        ScaffoldMessenger.of(context),
        SnackBar(content: Text(message)),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('toolbar_undo'),
          icon: const Icon(Icons.undo),
          // THE STEP IS NAMED. "Undo" alone asks somebody to remember what
          // they last did, which is precisely what the person reaching for it
          // has just lost track of.
          tooltip: canUndo
              ? undoLabel.isEmpty
                  ? 'Undo the last change to this $noun (Ctrl+Z)'
                  : 'Undo: $undoLabel (Ctrl+Z)'
              : 'Nothing to undo on this $noun',
          onPressed: canUndo
              ? () => report(
                    switch (target) {
                      ToolbarUndoTarget.project =>
                        _said('Undid', provider.undoProject()),
                      ToolbarUndoTarget.roomConfig =>
                        _said('Undid', provider.undoRoomConfig()),
                    },
                  )
              : null,
        ),
        IconButton(
          key: const ValueKey('toolbar_redo'),
          icon: const Icon(Icons.redo),
          tooltip: canRedo
              ? redoLabel.isEmpty
                  ? 'Redo the last undone change (Ctrl+Y)'
                  : 'Redo: $redoLabel (Ctrl+Y)'
              : 'Nothing to redo on this $noun',
          onPressed: canRedo
              ? () => report(
                    switch (target) {
                      ToolbarUndoTarget.project =>
                        _said('Redid', provider.redoProject()),
                      ToolbarUndoTarget.roomConfig =>
                        _said('Redid', provider.redoRoomConfig()),
                    },
                  )
              : null,
        ),
      ],
    );
  }

  /// 'Undid: DISPLAY_1', or nothing at all when the press found nothing to do
  /// — which happens when the button was lit for a change that turned out not
  /// to be one. Saying "Undid: " with an empty name would be worse than saying
  /// nothing.
  static String _said(String verb, String label) =>
      label.isEmpty ? '' : '$verb: $label';
}
