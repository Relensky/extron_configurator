import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'nav_rail.dart' show navTabLabel;

// ---------------------------------------------------------------------------
//  THE PAIR IN THE TITLE BAR
// ---------------------------------------------------------------------------
//  ONE UNDO PER DOCUMENT, NOT ONE PER PAGE. The room used to answer "what does
//  Undo do" six different ways: a pair on each of the four drawing tabs, a
//  fifth on the estimate, a sixth on the control schematic, and a seventh up
//  here for the config. Every one of them worked over its own slice, and
//  between them they meant that taking back the last thing you did required
//  first remembering which tab you had done it on — which is the one thing
//  somebody reaching for Undo has already lost track of.
//
//  So the room has ONE pair now, here, and it steps back through everything in
//  the room in the order it happened: a price typed over a catalog figure, a
//  box moved on the diagram, a device renamed on the wizard, a line drawn on
//  the schematic. See [AppStateProvider.undoRoom] for how three different
//  histories are kept in one order.
//
//  AND IT TAKES YOU TO THE CHANGE. A room-wide Undo that rolled back a floor
//  plan while you stood on the Cost tab would look like a button that does
//  nothing, which is the whole objection to a single history. So a press moves
//  the view to the tab the change is on, and the tooltip says so before it is
//  pressed.
//
//  THE OTHER DOCUMENTS KEEP THEIR OWN. The job, the catalog, the field schema
//  and the flow rule book are not the room, and the button acts on whichever
//  one the page in front of you belongs to — the same question Save already
//  answers, so the two controls beside each other never mean different things.

/// Which document the title bar's Undo acts on for [tab], or null on a page
/// that edits no document at all.
ToolbarUndoTarget? toolbarUndoTarget(AppTab tab) => switch (tab) {
      AppTab.project => ToolbarUndoTarget.project,
      // EVERY PAGE THAT EDITS THE ROOM, which is every room page there is: the
      // four views of the config file, the four drawings, the schematic, the
      // estimate and the replacement plan. They are one room and they get one
      // history — see the note above.
      AppTab.wizard ||
      AppTab.devices ||
      AppTab.system ||
      AppTab.rawJson ||
      AppTab.schematic ||
      AppTab.avFlow ||
      AppTab.floorPlan ||
      AppTab.cabling ||
      AppTab.racks ||
      AppTab.cost ||
      AppTab.lifecycle =>
        ToolbarUndoTarget.room,
      // The three documents about the app rather than about a room: one file
      // each, one tab each.
      AppTab.deviceEditor => ToolbarUndoTarget.catalog,
      AppTab.schemaEditor => ToolbarUndoTarget.schema,
      AppTab.flowRules => ToolbarUndoTarget.flowRules,
      // App Config is settings rather than a document.
      AppTab.appConfig => null,
    };

/// The document the title bar's Undo would act on.
enum ToolbarUndoTarget { project, room, catalog, schema, flowRules }

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
      ToolbarUndoTarget.room => 'room',
      ToolbarUndoTarget.catalog => 'catalog',
      ToolbarUndoTarget.schema => 'field schema',
      ToolbarUndoTarget.flowRules => 'flow rules',
    };

/// What the Undo (or Redo) on a room page would move to, for the tooltip to
/// say before it is pressed — '' when it would leave the view where it is.
String roomUndoDestination(
  AppStateProvider provider, {
  required bool redo,
}) {
  final tab = redo ? provider.roomRedoTab : provider.roomUndoTab;
  if (tab == null || tab.index == provider.selectedTabIndex) return '';
  return navTabLabel(tab);
}

/// Undo and Redo for whichever document the page on screen is editing.
///
/// Renders nothing at all on a page that edits no document.
class ToolbarUndoButtons extends StatelessWidget {
  final AppTab tab;

  const ToolbarUndoButtons({super.key, required this.tab});

  @override
  Widget build(BuildContext context) {
    final target = toolbarUndoTarget(tab);
    if (target == null) return const SizedBox.shrink();

    final noun = toolbarUndoNoun(target);
    final appData = _appDataFor(target);

    // WHAT THIS BAR ACTUALLY SHOWS: two enabled flags, two step names and,
    // for the room, where each press would land. Six small values.
    //
    // Watched one at a time rather than watching the whole provider, because
    // this bar is app chrome — it is on screen on every tab, for the whole
    // session — and a plain watch rebuilt it on every one of the two hundred
    // and thirty-odd things the provider announces. Ninety-nine of every
    // hundred of those left all six of these exactly as they were. A record
    // compares by value in Dart, so [select] does the comparison itself and
    // this rebuilds when the undo stacks move and not otherwise.
    //
    // The presses below read the provider instead of watching it: a callback
    // fires long after the build that made it, and wants the state as it is
    // when the button is hit.
    final ({
      bool canUndo,
      bool canRedo,
      String undoLabel,
      String redoLabel,
      String undoTo,
      String redoTo,
    }) view = context.select((AppStateProvider p) => (
          canUndo: switch (target) {
            ToolbarUndoTarget.project => p.canUndoProject,
            ToolbarUndoTarget.room => p.canUndoRoom,
            _ => p.canUndoAppData(appData!),
          },
          canRedo: switch (target) {
            ToolbarUndoTarget.project => p.canRedoProject,
            ToolbarUndoTarget.room => p.canRedoRoom,
            _ => p.canRedoAppData(appData!),
          },
          undoLabel: switch (target) {
            ToolbarUndoTarget.project => p.projectUndoLabel,
            ToolbarUndoTarget.room => p.roomUndoLabel,
            _ => p.appDataUndoLabel(appData!),
          },
          redoLabel: switch (target) {
            ToolbarUndoTarget.project => p.projectRedoLabel,
            ToolbarUndoTarget.room => p.roomRedoLabel,
            _ => p.appDataRedoLabel(appData!),
          },
          // WHERE THE PRESS WOULD TAKE YOU, said before it is pressed. Only
          // the room moves the view — it is the only document spread across
          // pages — and only when the change is somewhere other than where
          // you already are.
          undoTo: target == ToolbarUndoTarget.room
              ? roomUndoDestination(p, redo: false)
              : '',
          redoTo: target == ToolbarUndoTarget.room
              ? roomUndoDestination(p, redo: true)
              : '',
        ));

    final provider = context.read<AppStateProvider>();
    final canUndo = view.canUndo;
    final canRedo = view.canRedo;
    final undoLabel = view.undoLabel;
    final redoLabel = view.redoLabel;
    String goingTo(bool redo) => redo ? view.redoTo : view.undoTo;

    void report(String message) {
      if (message.isEmpty) return;
      showTimedSnackBar(
        ScaffoldMessenger.of(context),
        SnackBar(content: Text(message)),
      );
    }

    /// 'Undo on the room: Price (Ctrl+Z)', plus where it lands when that is
    /// somewhere else.
    String tip({
      required String verb,
      required bool enabled,
      required String label,
      required String keys,
      required String destination,
    }) {
      if (!enabled) {
        return 'Nothing to ${verb.toLowerCase()} on the $noun';
      }
      final head = label.isEmpty
          ? '$verb the last change to the $noun ($keys)'
          : '$verb on the $noun: $label ($keys)';
      return destination.isEmpty
          ? head
          : '$head\nThis goes to the $destination tab, where that change is.';
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
          tooltip: tip(
            verb: 'Undo',
            enabled: canUndo,
            label: undoLabel,
            keys: 'Ctrl+Z',
            destination: goingTo(false),
          ),
          onPressed: canUndo
              ? () => report(
                    switch (target) {
                      ToolbarUndoTarget.project =>
                        _said('Undid', provider.undoProject()),
                      ToolbarUndoTarget.room =>
                        _said('Undid', provider.undoRoom()),
                      _ => _said('Undid', provider.undoAppData(appData!)),
                    },
                  )
              : null,
        ),
        IconButton(
          key: const ValueKey('toolbar_redo'),
          icon: const Icon(Icons.redo),
          tooltip: tip(
            verb: 'Redo',
            enabled: canRedo,
            label: redoLabel,
            keys: 'Ctrl+Y',
            destination: goingTo(true),
          ),
          onPressed: canRedo
              ? () => report(
                    switch (target) {
                      ToolbarUndoTarget.project =>
                        _said('Redid', provider.redoProject()),
                      ToolbarUndoTarget.room =>
                        _said('Redid', provider.redoRoom()),
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
