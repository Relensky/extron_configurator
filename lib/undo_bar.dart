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
      // Keyed by scope and verb, so a test can press the pair belonging to one
      // page rather than whichever undo arrow it happened to find first — the
      // app has several, and they mean different things.
      key: ValueKey('${scope.name}_${verb.toLowerCase()}'),
      icon: Icon(icon, size: 18),
      label: Text(enabled ? '$verb: $label' : verb),
      onPressed: enabled ? onPressed : null,
    );
    if (blockedBy.isNotEmpty) {
      return Tooltip(
        message:
            '$verb is waiting on a later edit on the $blockedBy tab, which '
            'this one would undo with it. Deal with that tab first.',
        child: button,
      );
    }
    // A GREYED BUTTON HAS TO SAY WHY. Enabled, the label already carries the
    // whole message — "Undo: Rack DMP 64" — and a tooltip repeating it would
    // be noise. Greyed, the label collapses to the bare verb, and a control
    // that has gone dead without saying so just looks broken.
    if (enabled) return button;
    return Tooltip(
      message: 'Nothing to ${verb.toLowerCase()} on '
          '${avUndoScopeLabel(scope)}. This page keeps its own history, '
          'separate from the other tabs.',
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
        // THE ONLY THING THIS BUTTON SAYS. With no label beside it the
        // tooltip carries the whole message: which history, and what is about
        // to move in it.
        tooltip: blockedBy.isNotEmpty
            ? '$verb is waiting on a later edit on the $blockedBy tab, which '
                'this one would undo with it. Deal with that tab first.'
            : enabled
                ? '$verb on ${avUndoScopeLabel(scope)}: $label'
                : 'Nothing to ${verb.toLowerCase()} on '
                    '${avUndoScopeLabel(scope)}',
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
      // The three documents about the app rather than about a room: one file
      // each, one tab each, and no canvas to hang a pair of buttons off.
      AppTab.deviceEditor => ToolbarUndoTarget.catalog,
      AppTab.schemaEditor => ToolbarUndoTarget.schema,
      AppTab.flowRules => ToolbarUndoTarget.flowRules,
      // Everything left draws its own pair — the four drawing tabs, the
      // schematic, the estimate and the replacement plan — or is App Config,
      // which is settings rather than a document.
      _ => null,
    };

/// The document the title bar's Undo would act on.
enum ToolbarUndoTarget { project, roomConfig, catalog, schema, flowRules }

/// The [AppDataDocument] behind a target, or null for the two that are not one.
AppDataDocument? _appDataFor(ToolbarUndoTarget target) => switch (target) {
      ToolbarUndoTarget.catalog => AppDataDocument.catalog,
      ToolbarUndoTarget.schema => AppDataDocument.schema,
      ToolbarUndoTarget.flowRules => AppDataDocument.flowRules,
      _ => null,
    };

/// What the tooltip calls the document it would step back.
///
/// SAID OUT LOUD, always. The title bar sits over every tab and the button in
/// it acts on whichever document the page belongs to, so "Undo" alone leaves
/// somebody guessing which of five things is about to move — and this app has
/// had exactly that confusion once already, between this pair and the button
/// that reverts a file backup beside it.
String toolbarUndoNoun(ToolbarUndoTarget target) => switch (target) {
      ToolbarUndoTarget.project => 'project',
      ToolbarUndoTarget.roomConfig => 'room',
      ToolbarUndoTarget.catalog => 'catalog',
      ToolbarUndoTarget.schema => 'field schema',
      ToolbarUndoTarget.flowRules => 'flow rules',
    };

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

    final noun = toolbarUndoNoun(target);
    final appData = _appDataFor(target);
    final canUndo = switch (target) {
      ToolbarUndoTarget.project => provider.canUndoProject,
      ToolbarUndoTarget.roomConfig => provider.canUndoRoomConfig,
      _ => provider.canUndoAppData(appData!),
    };
    final canRedo = switch (target) {
      ToolbarUndoTarget.project => provider.canRedoProject,
      ToolbarUndoTarget.roomConfig => provider.canRedoRoomConfig,
      _ => provider.canRedoAppData(appData!),
    };
    final undoLabel = switch (target) {
      ToolbarUndoTarget.project => provider.projectUndoLabel,
      ToolbarUndoTarget.roomConfig => provider.roomConfigUndoLabel,
      _ => provider.appDataUndoLabel(appData!),
    };
    final redoLabel = switch (target) {
      ToolbarUndoTarget.project => provider.projectRedoLabel,
      ToolbarUndoTarget.roomConfig => provider.roomConfigRedoLabel,
      _ => provider.appDataRedoLabel(appData!),
    };

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
          // THE STEP AND THE DOCUMENT, both. "Undo" alone asks somebody to
          // remember what they last did, which is precisely what the person
          // reaching for it has lost track of — and this button sits in a
          // title bar over five different documents, so which one is about to
          // move is the other half of the question. Getting that wrong is not
          // hypothetical here: an arrow in this bar that reverted a file
          // backup was pressed for years by people meaning this.
          tooltip: canUndo
              ? undoLabel.isEmpty
                  ? 'Undo the last change to the $noun (Ctrl+Z)'
                  : 'Undo on the $noun: $undoLabel (Ctrl+Z)'
              : 'Nothing to undo on the $noun',
          onPressed: canUndo
              ? () => report(
                    switch (target) {
                      ToolbarUndoTarget.project =>
                        _said('Undid', provider.undoProject()),
                      ToolbarUndoTarget.roomConfig =>
                        _said('Undid', provider.undoRoomConfig()),
                      _ => _said('Undid', provider.undoAppData(appData!)),
                    },
                  )
              : null,
        ),
        IconButton(
          key: const ValueKey('toolbar_redo'),
          icon: const Icon(Icons.redo),
          tooltip: canRedo
              ? redoLabel.isEmpty
                  ? 'Redo the last undone change to the $noun (Ctrl+Y)'
                  : 'Redo on the $noun: $redoLabel (Ctrl+Y)'
              : 'Nothing to redo on the $noun',
          onPressed: canRedo
              ? () => report(
                    switch (target) {
                      ToolbarUndoTarget.project =>
                        _said('Redid', provider.redoProject()),
                      ToolbarUndoTarget.roomConfig =>
                        _said('Redid', provider.redoRoomConfig()),
                      _ => _said('Redid', provider.redoAppData(appData!)),
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
