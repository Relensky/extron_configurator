import 'package:flutter/material.dart';

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

/// What [scope]'s history is called on screen, for a message that has to name
/// another tab.
String avUndoScopeLabel(AvUndoScope scope) =>
    kAvUndoScopeLabels[scope] ?? scope.name;
