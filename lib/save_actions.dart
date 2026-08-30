import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_logger.dart';
import 'app_snack.dart';
import 'app_state.dart';
import 'contrast.dart';
import 'control_prefill.dart' show buildControlSideForPreset;
import 'new_room_dialog.dart';
import 'undo_bar.dart' show ToolbarUndoButtons;
import 'online_copy_dialog.dart' show offerHeldOnlineEdits;
import 'project_room_picker.dart' show confirmLeavingRoom;
import 'building_project.dart';
import 'diagram_capture.dart';
import 'export_tools.dart';
import 'project_briefing_dialog.dart';
import 'project_setup_dialog.dart';

/// ============================================================================
///  ONE SAVE BUTTON THAT KNOWS WHAT YOU ARE LOOKING AT
/// ============================================================================
///  The toolbar used to carry three separate save controls — a floppy for the
///  room's working file, a folder-up arrow for "Save All", and a Save As that
///  was called Export Config Locally — and none of them changed when you moved
///  between tabs. So somebody on the Project tab pressing the only button that
///  looks like Save saved the ROOM, and the job they had just spent ten minutes
///  tagging was still only in memory.
///
///  Every editor in this app is really one of five documents, and Save means a
///  different file for each. [SaveScope] names them, [saveScopeForTab] says
///  which one a tab belongs to, and everything else in this file is written
///  against the scope rather than against the tab — so a tab added later only
///  has to answer the one question.
/// ============================================================================

/// The documents this app can save, one per kind of editor.
enum SaveScope {
  /// The room: its config file and every sidecar beside it (the drawings, the
  /// racks, the floor plans, the cabling, the estimate).
  room,

  /// The building project: the room list, the vendor split and the tags.
  project,

  /// The equipment catalog — av_devices.json. Application data, not a room.
  catalog,

  /// The field schema — ui_schema.json.
  schema,

  /// The AV flow rule book — av_flow_rules.json.
  flowRules,
}

/// Which document the tab on screen belongs to.
///
/// Everything not named here edits the room: the wizard, the device forms, the
/// four drawings, the racks, the estimate and the raw JSON are all views of the
/// same room document, and Save on any of them means the same file.
SaveScope saveScopeForTab(AppTab tab) => switch (tab) {
      AppTab.project => SaveScope.project,
      AppTab.deviceEditor => SaveScope.catalog,
      AppTab.schemaEditor => SaveScope.schema,
      AppTab.flowRules => SaveScope.flowRules,
      _ => SaveScope.room,
    };

/// What to call the document in a button label — 'Save Room', 'Save Project'.
String saveScopeNoun(SaveScope scope) => switch (scope) {
      SaveScope.room => 'Room',
      SaveScope.project => 'Project',
      SaveScope.catalog => 'Catalog',
      SaveScope.schema => 'Schema',
      SaveScope.flowRules => 'Flow Rules',
    };

/// The one-line explanation under the label: what actually gets written.
String saveScopeDescription(SaveScope scope) => switch (scope) {
      SaveScope.room =>
        'the config file and the drawings, racks, plans and estimate beside it',
      SaveScope.project => 'the room list, the vendors and the tags',
      SaveScope.catalog => 'av_devices.json - the equipment catalog',
      SaveScope.schema => 'ui_schema.json - the field definitions',
      SaveScope.flowRules => 'av_flow_rules.json - the drawing rule book',
    };

/// Only the two documents that belong to a job can be written somewhere else.
/// The catalog, the schema and the rule book are application data with one
/// configured home each (App Config says where) — offering "Save As" for them
/// would produce a second copy nothing ever reads again.
bool saveScopeSupportsSaveAs(SaveScope scope) =>
    scope == SaveScope.room || scope == SaveScope.project;

/// Whether Save can do anything right now, and why not when it cannot.
///
/// Returns '' when the save is available. Anything else is the sentence the
/// disabled button's tooltip shows — a disabled control that does not say what
/// would enable it is just a control that looks broken.
String saveBlockedReason(AppStateProvider provider, SaveScope scope) {
  switch (scope) {
    case SaveScope.room:
      // Deliberately NOT blocked by the room having no file yet. A Save button
      // that goes dead on a brand new room — and sends you hunting for the
      // command that used to be called "Export Config Locally" — is the thing
      // this rewrite exists to get rid of; [runSave] asks where to put it.
      return provider.roomConfig.isEmpty ? 'No room is open.' : '';
    case SaveScope.project:
      if (provider.project.rooms.isEmpty &&
          provider.currentProjectPath.isEmpty &&
          provider.project.name.trim().isEmpty) {
        return 'No project has been started yet.';
      }
      return '';
    case SaveScope.catalog:
    case SaveScope.schema:
    case SaveScope.flowRules:
      return '';
  }
}

/// True when Save would have to ask where to put it, because this document has
/// never had a file. The button still works — it just opens a dialog — and the
/// tooltip says so rather than letting the click be a surprise.
bool saveScopeNeedsFile(AppStateProvider provider, SaveScope scope) =>
    switch (scope) {
      SaveScope.room =>
        provider.roomConfig.isNotEmpty && provider.currentConfigPath.isEmpty,
      SaveScope.project => provider.currentProjectPath.isEmpty,
      _ => false,
    };

/// True when this document is behind its file. Drives the dot on the Save
/// button — the app's answer to "did I save that?" without pressing anything.
///
/// The three application documents are deliberately always false: they are
/// edited through their own tabs, which write as they go, so a permanent dot
/// on the Catalog tab would be a dot that means nothing.
bool saveScopeIsDirty(AppStateProvider provider, SaveScope scope) =>
    switch (scope) {
      SaveScope.room =>
        provider.roomNeverSaved || provider.roomHasUnsavedChanges,
      SaveScope.project => provider.projectDirty,
      _ => false,
    };

// ---------------------------------------------------------------------------
//  DOING IT
// ---------------------------------------------------------------------------

/// Saves [scope]. [saveAs] asks where first (room and project only).
///
/// Returns true when something reached disk. Every path reports through a
/// snack bar, so callers only need the boolean to decide whether to carry on
/// with whatever they were doing (closing the app, switching rooms).
Future<bool> runSave(
  BuildContext context,
  AppStateProvider provider,
  SaveScope scope, {
  bool saveAs = false,
}) async {
  final messenger = ScaffoldMessenger.of(context);

  // A SAVE IS A BOUNDARY. Whatever has been typed since the last step becomes
  // its own step here, so "back to how it was when I saved" is one press
  // rather than a guess about where the last pause fell.
  provider.recordUndoPoint();

  switch (scope) {
    case SaveScope.room:
      if (provider.roomConfig.isEmpty) {
        showTimedSnackBar(
          messenger,
          const SnackBar(content: Text('There is no room open to save.')),
        );
        return false;
      }
      // A room with no file has only one honest answer to "Save", and it is
      // the same dialog Save As opens.
      if (saveAs || provider.currentConfigPath.isEmpty) {
        final ok = await provider.exportRoomConfig();
        if (!context.mounted) return ok;
        if (ok) {
          showSavedFileSnack(
            context,
            provider,
            'Room',
            provider.currentConfigPath,
          );
        }
        return ok;
      }
      final result = await provider.saveRoomInPlace();
      final failed = result.startsWith('Error');
      if (failed) {
        showTimedSnackBar(
          messenger,
          SnackBar(
            duration: const Duration(seconds: 6),
            content: Text(result),
            backgroundColor: snackErrorFillOn(messenger),
          ),
        );
        return false;
      }
      if (!context.mounted) return true;
      showSavedFileSnack(context, provider, 'Room', result);
      return true;

    case SaveScope.project:
      var target = provider.currentProjectPath;
      if (saveAs || target.isEmpty) {
        final picked = await FilePicker.saveFile(
          dialogTitle: 'Save the project',
          fileName: '${_projectFileStem(provider.project)}$kProjectFileSuffix',
          type: FileType.custom,
          allowedExtensions: const ['json'],
        );
        if (picked == null) return false;
        // The dialog hands back exactly what was typed, so a name entered
        // without an extension would land as a file nothing can open.
        target =
            picked.toLowerCase().endsWith('.json') ? picked : '$picked.json';
      }
      final error = await provider.saveProject(to: target);
      if (error.isNotEmpty) {
        showTimedSnackBar(
          messenger,
          SnackBar(
            duration: const Duration(seconds: 6),
            content: Text(error),
            backgroundColor: snackErrorFillOn(messenger),
          ),
        );
        return false;
      }
      if (!context.mounted) return true;
      showSavedFileSnack(context, provider, 'The project', target);
      // A JOB THAT PUBLISHES ON SAVE MAY HAVE STOOD ITS PUBLISH DOWN, because
      // somebody had typed into the copy in the sync folder since we last
      // wrote it. The save itself is done and reported above; this offers
      // their changes back and then lets the copy go out. Does nothing when
      // there was no hold, which is nearly always.
      await offerHeldOnlineEdits(context, provider);
      return true;

    case SaveScope.catalog:
      final written = await provider.saveAvDeviceLibrary();
      if (!context.mounted) return written.isNotEmpty;
      return _reportAppDataSave(context, provider, 'The catalog', written);

    case SaveScope.schema:
      final written = await provider.saveUiSchema();
      if (!context.mounted) return written.isNotEmpty;
      return _reportAppDataSave(context, provider, 'The field schema', written);

    case SaveScope.flowRules:
      final written = await provider.saveFlowRules();
      if (!context.mounted) return written.isNotEmpty;
      return _reportAppDataSave(context, provider, 'The flow rules', written);
  }
}

/// The three application documents all report the same way: they return the
/// file they wrote, or '' when the write failed.
bool _reportAppDataSave(
  BuildContext context,
  AppStateProvider provider,
  String what,
  String written,
) {
  if (!context.mounted) return written.isNotEmpty;
  if (written.isEmpty) {
    final messenger = ScaffoldMessenger.of(context);
    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text('$what could not be written - see the log.'),
        backgroundColor: snackErrorFillOn(messenger),
      ),
    );
    return false;
  }
  showSavedFileSnack(context, provider, what, written);
  return true;
}

String _projectFileStem(BuildingProject project) {
  final raw = project.name.trim().isNotEmpty
      ? project.name
      : project.building.trim().isNotEmpty
          ? project.building
          : 'project';
  return raw
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
      .replaceAll(RegExp(r'\s+'), '_');
}

/// SAVE EVERYTHING — every open document that is behind its file, in one go.
///
/// Only the room and the project: the application documents write as they are
/// edited, so including them would mean rewriting three shared files every
/// time somebody pressed Save on a room.
///
/// Returns true when nothing was left unsaved. A room that has never been
/// saved opens its Save As dialog, because there is no other way to save it —
/// and if that is cancelled, this honestly reports that work is still loose.
Future<bool> saveEverything(
  BuildContext context,
  AppStateProvider provider,
) async {
  bool allDone = true;
  final saved = <String>[];

  if (provider.roomNeverSaved || provider.roomHasUnsavedChanges) {
    final ok = await runSave(context, provider, SaveScope.room);
    allDone &= ok;
    if (ok) saved.add('room');
    if (!context.mounted) return allDone;
  }
  if (provider.projectDirty) {
    final ok = await runSave(context, provider, SaveScope.project);
    allDone &= ok;
    if (ok) saved.add('project');
    if (!context.mounted) return allDone;
  }

  if (saved.isEmpty && allDone) {
    showTimedSnackBar(
      ScaffoldMessenger.of(context),
      const SnackBar(
        content: Text('Everything is already saved.'),
      ),
    );
  }
  return allDone;
}

/// ---------------------------------------------------------------------------
//  STARTING AND OPENING A JOB
// ---------------------------------------------------------------------------
//  These three live here rather than on the Project tab because the start
//  screen offers them too, and a session that begins with "New Project" should
//  go through exactly the same prompt about unsaved work as one that presses
//  the same button on the tab an hour later.
// ---------------------------------------------------------------------------

/// Offers to save a project with unsaved edits before it is replaced.
/// Returns false when the user backs out entirely.
Future<bool> confirmLeavingProject(
  BuildContext context,
  AppStateProvider provider,
) async {
  if (!provider.projectDirty) return true;
  final answer = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('This project has unsaved changes'),
      content: Text(
        '"${provider.projectDisplayName}" has edits that are not on disk. '
        'The rooms themselves are untouched either way - only the room list, '
        'the vendors and the tags are at stake.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'cancel'),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'discard'),
          child: const Text('Discard'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, 'save'),
          child: const Text('Save first'),
        ),
      ],
    ),
  );
  if (answer == 'save') {
    if (!context.mounted) return false;
    return runSave(context, provider, SaveScope.project);
  }
  return answer == 'discard';
}

/// Starts a fresh job, pre-filled with the open room's building when there is
/// one — the commonest new project is the building you are already standing in.
///
/// Then asks the questions a job is set up with: which rooms, when it is due,
/// what it holds spare, and what has to happen first — see
/// project_setup_dialog.dart. Every route to a new project comes through here
/// (the start screen, the toolbar and the Project tab all call it), so the
/// setup screen cannot be something that only appears on one of them.
///
/// Skipping the setup leaves exactly the empty project this used to give.
///
/// Returns true when a new project was actually started.
Future<bool> startNewProject(
  BuildContext context,
  AppStateProvider provider,
) async {
  if (!await confirmLeavingProject(context, provider)) return false;
  if (!context.mounted) return false;
  final roomSetup = provider.roomConfig['SYSTEM_SETUP'];
  final building =
      (roomSetup is Map ? roomSetup['gve_bldg']?.toString() : '') ?? '';

  // THE QUESTIONS COME FIRST, AND BACKING OUT OF THEM CHANGES NOTHING.
  //
  // The job used to be created and the app switched into project mode before
  // the setup screen opened, so cancelling out of it left somebody who had
  // been working on a room standing in an empty project they never started.
  // Room mode and project mode are the two states this app is ever in, and
  // nothing may move between them except a decision somebody actually made.
  final answers = await showProjectSetupDialog(
    context,
    building: building,
    // How far down the share to look for room configs — set once in App
    // Config, because it is a fact about how a site lays its files out and
    // not a decision anybody wants to make again on every new job.
    scanDepth: provider.roomScanDepth,
  );
  if (answers == null || !context.mounted) return false;

  provider.newProject(building: building);
  provider.selectTab(AppTab.project.index);

  showTimedSnackBar(
    ScaffoldMessenger.of(context),
    SnackBar(
      duration: const Duration(seconds: 6),
      content: Text(applyProjectSetup(provider, answers)),
    ),
  );
  return true;
}

/// Creates a room from the template and applies what the new-room dialog was
/// told — the room mode, and the room type's preset with the control side
/// built from it.
///
/// Shared rather than written twice: a room is started from the toolbar AND
/// from the project's room picker, and the two must produce the SAME room. The
/// caller keeps whatever is particular to its own route — which tab to land
/// on, whether to run the estimator wizard, where to save the file — and this
/// holds the part that is the room itself.
///
/// Returns false when no template could be found, having said so.
Future<bool> createRoomFromChoice(
  BuildContext context,
  AppStateProvider provider,
  NewRoomChoice choice, {
  bool announce = true,
}) async {
  // The template path always resolves (explicit file, else config.json in the
  // Root Folder / working directory), so attempt the create and report the
  // resolved location on failure.
  final created = await provider.createNewConfig();
  if (!context.mounted) return created;
  if (!created) {
    showTimedSnackBar(
      ScaffoldMessenger.of(context),
      SnackBar(
        content: Text(
          'No template found at ${provider.effectiveTemplateFilePath}. '
          'Place config.json there or set a Template file in App Config.',
        ),
        backgroundColor: snackErrorFill(context),
      ),
    );
    return false;
  }

  // Set after the create: createNewConfig resets the AV document, and the room
  // mode lives in it.
  provider.setRoomMode(choice.mode);

  // The room type goes in before anything else, so what it draws lands on a
  // canvas that already has the room's usual gear rather than colliding with
  // it afterwards.
  final preset = choice.preset;
  if (preset == null) return true;

  final summary = provider.applyRoomPreset(
    preset,
    // Renumbered into this room's own scheme when it has a number. A new room
    // usually does not yet, and then the preset's numbering stands until
    // somebody renumbers the boxes.
    jackPrefix: roomJackPrefix(provider),
  );

  // The control side, built from what the preset just drew. Skipped for an
  // AV-only room, which by definition has no control system yet.
  final control = choice.mode == RoomMode.avOnly
      ? null
      : buildControlSideForPreset(provider, preset);

  if (!announce || !context.mounted) return true;
  showTimedSnackBar(
    ScaffoldMessenger.of(context),
    SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(
        '${preset.name}: ${summary.devices} devices, ${summary.jacks} '
        'jacks, ${summary.cables} runs and ${summary.racks} rack'
        '${summary.racks == 1 ? '' : 's'} added.'
        '${control == null ? '' : ' ${control.blocks} control block'
              '${control.blocks == 1 ? '' : 's'} and ${control.settings} '
              'system setting${control.settings == 1 ? '' : 's'} filled in'
              '${control.withoutModule == 0 ? '' : ', ${control.withoutModule} '
                  'device${control.withoutModule == 1 ? '' : 's'} still '
                  'needing a python module'}.'}'
        ' Set the room number on the Wizard tab, then check the jack '
        'numbering.',
      ),
    ),
  );
  return true;
}

/// This room's jack prefix — its number, digits only. '' when the room has no
/// number yet, which tells [AppStateProvider.applyRoomPreset] to leave a
/// preset's own numbering alone rather than renumbering it to nothing.
String roomJackPrefix(AppStateProvider provider) {
  final setup = provider.roomConfig['SYSTEM_SETUP'];
  final room = (setup is Map ? setup['gve_room']?.toString() : null) ?? '';
  return room.replaceAll(RegExp(r'[^0-9]'), '');
}

/// Starts a new room and puts it straight onto the open project.
///
/// A project points at FILES, so a room that has never been saved has nothing
/// to point at — which is why this asks where to put it before adding it,
/// rather than creating a room that cannot join the job it was started for.
///
/// Returns true when a room was created, saved and added.
Future<bool> createProjectRoom(
  BuildContext context,
  AppStateProvider provider,
) async {
  if (!await confirmLeavingRoom(context, provider)) return false;
  if (!context.mounted) return false;

  final choice = await showNewRoomDialog(context);
  if (choice == null || !context.mounted) return false;

  if (!await createRoomFromChoice(context, provider, choice)) return false;
  if (!context.mounted) return false;

  final messenger = ScaffoldMessenger.of(context);

  // Where it goes. Asked here rather than left for later: a new room that is
  // never saved is not on the project, and finding that out afterwards means
  // redoing the room.
  if (!await provider.exportRoomConfig()) {
    showTimedSnackBar(
      messenger,
      const SnackBar(
        content: Text(
          'The room was created but not saved, so it is not on the project '
          'yet. Save it and use "Add rooms" on the Project tab.',
        ),
      ),
    );
    return false;
  }

  final error = provider.addCurrentRoomToProject();
  if (error.isNotEmpty) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text(error),
        backgroundColor: snackErrorFillOn(messenger),
      ),
    );
    return false;
  }

  // Nothing to mark: the picker resolves the open room from the config path
  // (see AppStateProvider.openProjectRoom), so saving it and adding it is
  // already enough for the picker that started this to read as this room.
  showTimedSnackBar(
    messenger,
    SnackBar(
      content: Text(
        'Added to ${provider.projectDisplayName}. Set the building and room '
        'number on the Wizard tab.',
      ),
    ),
  );
  return true;
}

// ---------------------------------------------------------------------------
//  FROM AN ESTIMATE TO A ROOM
// ---------------------------------------------------------------------------
//  A building arrives on the refresh plan as a list of estimates: a room name,
//  a date, a life and a figure off a master spreadsheet, with no config file
//  anywhere under it. That is enough to budget with and not enough to build
//  with, and the moment somebody is actually doing one of those rooms they
//  need the other thing - a real room file, with the equipment that room type
//  is priced on already in it.
//
//  This is that step, as ONE action. Done by hand it is: read the note to find
//  which room type the estimate used, start a new room, find that type in a
//  list of twenty-seven, apply it, type the building and the room number in,
//  save it somewhere sensible, add it to the job, then remember to delete the
//  estimate - and the last of those is the one that gets forgotten, which puts
//  the room on its own building's plan twice.

/// The building code and room number in a line item's name.
///
/// 'AGYM 129' is a building and a room; 'Ground floor teaching lab' is neither,
/// and the honest answer there is the job's own building code and no number,
/// which leaves the Wizard's fields blank rather than filled with a guess.
({String building, String room}) splitLineItemName(
  String name, {
  String fallbackBuilding = '',
}) {
  final trimmed = name.trim();
  final match = RegExp(r'^([A-Za-z]{2,6})[\s-]+([\w.-]+)$').firstMatch(trimmed);
  if (match != null) {
    return (building: match.group(1)!.toUpperCase(), room: match.group(2)!);
  }
  // A bare number with the building implied by the job it is on.
  final number = RegExp(r'^([\w.-]+)$').firstMatch(trimmed);
  if (number != null && fallbackBuilding.trim().isNotEmpty) {
    return (building: fallbackBuilding.trim().toUpperCase(), room: number.group(1)!);
  }
  return (building: fallbackBuilding.trim().toUpperCase(), room: '');
}

/// Builds a real room file from one line item, and takes the estimate off the
/// plan once the room is on the job.
///
/// THE ESTIMATE IS ONLY DROPPED IF THE ROOM WENT ON. Every way this can stop -
/// the reader cancels, the template is missing, they close the save dialog,
/// the config will not join the job - leaves the plan exactly as it was. The
/// estimate is the only record of that room, and losing it to a half-finished
/// conversion would take the room off the budget altogether.
///
/// Returns true when the room was created, saved and added.
Future<bool> buildRoomFromLineItem(
  BuildContext context,
  AppStateProvider provider,
  ManualRoom line,
) async {
  if (!await confirmLeavingRoom(context, provider)) return false;
  if (!context.mounted) return false;

  // The room type this estimate was priced against, so the dialog opens on it
  // rather than on a list of twenty-seven - see [ManualRoom.sourceType].
  final suggested = provider.presetForSourceName(line.sourceType);
  final choice = await showNewRoomDialog(context, initialPreset: suggested);
  if (choice == null || !context.mounted) return false;

  if (!await createRoomFromChoice(context, provider, choice, announce: false)) {
    return false;
  }
  if (!context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);

  // The code on the door, off the line item's own name. Written before the
  // save so the file picker's suggested name is the room's.
  final where = splitLineItemName(
    line.name,
    fallbackBuilding: provider.project.building,
  );
  provider.setRoomIdentity(building: where.building, room: where.room);

  if (!await provider.exportRoomConfig()) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text(
          'The room was built but not saved, so ${line.name} is still an '
          'estimate on the plan. Save the room and use Swap on the line to '
          'put the two together.',
        ),
      ),
    );
    return false;
  }

  final error = provider.swapManualRoomForConfig(
    line.id,
    provider.currentConfigPath,
  );
  if (error.isNotEmpty) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        content: Text(error),
        backgroundColor: snackErrorFillOn(messenger),
      ),
    );
    return false;
  }

  showTimedSnackBar(
    messenger,
    SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(
        '${line.name} is a room now'
        '${choice.preset == null ? '' : ', built from ${choice.preset!.name}'}'
        '. Its estimate is off the plan and it is priced from its own parts.',
      ),
    ),
  );
  return true;
}

/// Puts the job away. Returns true when it was actually closed.
///
/// Asks about unsaved work first, through the same prompt New and Open use, so
/// "close" cannot be the one route that loses a room list somebody spent ten
/// minutes tagging. The OPEN ROOM is left exactly where it is — a room is its
/// own document, and closing the job it belongs to is not a reason to shut it.
Future<bool> closeProjectFile(
  BuildContext context,
  AppStateProvider provider,
) async {
  if (!await confirmLeavingProject(context, provider)) return false;
  if (!context.mounted) return false;

  final was = provider.projectDisplayName;
  final hadRoom = provider.currentConfigPath.isNotEmpty;
  provider.closeProject();

  // AND OUT OF PROJECT MODE. Closing a job while standing on the Project tab
  // used to leave the user looking at the empty room list of the job they had
  // just put away, which reads as a close that did not work. The session goes
  // back to where the room work was - see [AppStateProvider.lastRoomTabIndex]
  // - or, with no room open, to the start screen that offers both documents.
  provider.selectTab(provider.lastRoomTabIndex);

  showTimedSnackBar(
    ScaffoldMessenger.of(context),
    SnackBar(
      content: Text(
        hadRoom
            // Said out loud, because the room staying open is the part that
            // would otherwise look like the close only half worked.
            ? 'Closed $was. Back to the room, which is still open.'
            : 'Closed $was.',
      ),
    ),
  );
  return true;
}

/// Puts the open room away, asking about unsaved work first.
///
/// WHERE IT LEAVES YOU. With no job open, nothing at all is open afterwards -
/// which is the start screen, because that is what this app shows when there
/// is no config and the tab needs one. That was the missing half: a job could
/// be closed and a room could only be swapped, so the empty session somebody
/// starts the day on could not be got back to without restarting.
///
/// With a job still open the job stays open, exactly as closing a job leaves
/// the room alone. Closing means the room, not everything on screen.
Future<bool> closeRoomFile(
  BuildContext context,
  AppStateProvider provider,
) async {
  if (!await confirmLeavingRoom(context, provider)) return false;
  if (!context.mounted) return false;

  final was = provider.currentConfigPath.isEmpty
      ? 'the room'
      : path.basename(provider.currentConfigPath);
  final hasProject = provider.hasOpenProject;
  provider.closeRoom();

  showTimedSnackBar(
    ScaffoldMessenger.of(context),
    SnackBar(
      content: Text(
        hasProject
            // Said out loud, for the same reason closing a job says the room
            // is still open: the half that stayed is the half that otherwise
            // looks like a close that did not work.
            ? 'Closed $was. ${provider.projectDisplayName} is still open.'
            : 'Closed $was.',
      ),
    ),
  );
  return true;
}

/// Opens a project file. Returns true when one was opened.
Future<bool> openProjectFromFile(
  BuildContext context,
  AppStateProvider provider,
) async {
  if (!await confirmLeavingProject(context, provider)) return false;
  final picked = await FilePicker.pickFiles(
    dialogTitle: 'Open a project',
    type: FileType.custom,
    allowedExtensions: const ['json'],
  );
  final file = picked?.files.single.path;
  if (file == null || !context.mounted) return false;
  return openProjectAtPath(context, provider, file);
}

/// True when [file] is a JOB rather than a room.
///
/// Two checks, cheapest first. The suffix this app writes projects under
/// answers it without touching the disk; a file that has been renamed is
/// settled by looking for the one key a project cannot be without and a room
/// never has. Anything unreadable is NOT a project — the room loader gives a
/// better message about a broken file than the project loader would.
bool isProjectFile(String file) {
  if (file.toLowerCase().endsWith(kProjectFileSuffix.toLowerCase())) {
    return true;
  }
  try {
    final doc = jsonDecode(File(file).readAsStringSync());
    return doc is Map && doc['rooms'] is List;
  } catch (_) {
    return false;
  }
}

/// Opens the project at [file] — everything [openProjectFromFile] does once
/// the picker has closed.
///
/// Its own function because opening a job is no longer always the Open Project
/// button: Open File takes whichever of the two documents it is handed, and a
/// project opened that way has to be a project opened exactly like the other —
/// same prompt about unsaved edits, same briefing, same message afterwards.
Future<bool> openProjectAtPath(
  BuildContext context,
  AppStateProvider provider,
  String file,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final error = await provider.openProject(file);
  if (error.isNotEmpty) {
    showTimedSnackBar(
      messenger,
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(error),
        backgroundColor: snackErrorFillOn(messenger),
      ),
    );
    return false;
  }
  provider.selectTab(AppTab.project.index);
  showTimedSnackBar(
    messenger,
    SnackBar(content: Text('Opened ${provider.projectDisplayName}.')),
  );
  // Where the job stands, once, on the way in — see project_briefing.dart. It
  // puts nothing on screen unless something is actually time-critical, so a
  // healthy project still opens straight onto the tab.
  if (context.mounted) {
    await showProjectBriefing(context, provider);
  }
  return true;
}

// SAVE ALL — everything the JOB has produced, a folder per room.
///
/// IT WALKS THE WHOLE PROJECT. A building is quoted, issued and handed over as
/// a set of rooms, and a "Save All" that wrote the one room that happened to be
/// open meant doing this nine times by hand: switch room, wait for the
/// diagrams, pick the same parent folder again, and hope nobody lost count.
/// The room in the editor is not a document boundary - the JOB is.
///
/// One folder per room, side by side under the parent folder that is picked
/// once. Each is exactly the folder this used to write, named after its own
/// room, so nothing downstream of it changes.
///
/// THE ROOM HAS TO BE ON SCREEN TO BE PHOTOGRAPHED. The diagram images can
/// only be rendered from a widget that is mounted, so this opens each room in
/// turn and lets [captureDiagramTabs] walk its drawing tabs - which is a
/// visible flick through the tabs, once per room, and the reason it says which
/// room it is on as it goes. The room that was open when it started is put
/// back at the end, on the tab it was on.
///
/// Anything that could not be read, captured or written is reported beside the
/// room it belongs to rather than quietly missing from the folder.
Future<void> saveAllToRoomFolder(
  BuildContext context,
  AppStateProvider provider,
) async {
  final rooms = provider.project.rooms;

  // SWITCHING ROOMS READS THE NEXT ONE OFF DISK, so anything unsaved in the
  // room being left goes with it. Asked once, before the folder is picked -
  // the same question every other way of leaving a room asks, because two
  // doors into one consequence must not have two different answers.
  if (rooms.isNotEmpty) {
    if (!await confirmLeavingRoom(context, provider)) return;
    if (!context.mounted) return;
  }

  final parent = await FilePicker.getDirectoryPath(
    dialogTitle: rooms.isEmpty
        ? 'Where should the room folder go?'
        : 'Where should the room folders go?',
  );
  if (parent == null || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  // Held from before the walk: switching rooms and tabs rebuilds the page this
  // was started from, and the summary still has to be able to open.
  final navigator = Navigator.of(context, rootNavigator: true);

  // What each room is called, worked out once and from the job rather than
  // from whichever room happens to be loaded at the time.
  final names = {
    for (final r in provider.priceProject().rooms) r.ref.id: r.name,
  };

  // Where to put the session back when it is done.
  final startingRoom = provider.openProjectRoom;
  final startingTab = provider.selectedTabIndex;

  // A job with no rooms on it is still a room in the editor, and Save All has
  // always worked on one. The list of one keeps the loop below honest.
  final targets = rooms.isEmpty
      ? <ProjectRoomRef?>[null]
      : <ProjectRoomRef?>[...rooms];

  final done = <RoomFolderResult>[];

  for (final (i, ref) in targets.indexed) {
    final label = ref == null
        ? 'This room'
        : (names[ref.id] ??
            (ref.label.trim().isEmpty ? ref.fallbackName : ref.label.trim()));

    // REPLACED, NOT QUEUED. A ScaffoldMessenger holds snack bars in a line and
    // shows them one after the other, so nine of these at thirty seconds each
    // is four and a half minutes of stale progress messages after the run has
    // finished - which reads as an application that has hung.
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 30),
      content: Text(
        targets.length == 1
            ? 'Capturing the diagrams...'
            : 'Capturing $label - ${i + 1} of ${targets.length}...',
      ),
    ));

    // ONE BAD ROOM IS ONE BAD ROW, NOT THE END OF THE RUN.
    //
    // This is the whole difference between walking one room and walking nine.
    // Opening a room reads a config and three sidecars off disk; capturing it
    // then forces five drawing tabs to build, lay out, paint and rasterise -
    // for a room nobody may have opened in months. A floor plan whose image
    // has moved, a sidecar hand-edited into invalid JSON, a canvas that has
    // not painted yet: any of them throws, and unguarded that took down the
    // entire export half way through, leaving the session parked on some other
    // room's Schematic tab with a progress bar still up. It looked exactly
    // like a crash, and from the user's side it was one.
    //
    // Guarded per room, the same failure is a named row on the summary saying
    // which building could not be photographed and why, and the other eight
    // still land in their folders.
    try {
      if (ref != null) {
        final error = await provider.openProjectRoomRef(ref);
        if (error.isNotEmpty) {
          done.add((room: label, export: null, error: error));
          continue;
        }
        // Let the room actually mount before its tabs are photographed. The
        // capture drives the tabs itself, but it starts by selecting one - and
        // selecting a tab on a room that has been swapped in memory but not
        // yet built is how a stale index from the room before it ends up being
        // read.
        await WidgetsBinding.instance.endOfFrame;
      }

      final shots = await captureDiagramTabs(provider, pixelRatio: 2.0);

      done.add((
        room: label,
        export: await saveProjectFolder(
          provider: provider,
          parentFolder: parent,
          schematicPng: shots.schematic,
          avFlowPng: shots.avFlow,
          rackPng: shots.racks,
          floorPlanSheets: shots.floorPlanSheets,
          cablingPng: shots.cabling,
        ),
        error: '',
      ));
    } catch (e, stack) {
      done.add((room: label, export: null, error: '$e'));
      AppLogger.logError('Save All could not write the folder for $label', e, stack);
    }
  }

  // BACK WHERE IT STARTED. Somebody who ran this from the middle of cabling a
  // room is standing in that room's cabling when it finishes.
  //
  // Guarded for the same reason the walk is: the room somebody started from
  // can have been renamed or moved by something else while nine rooms were
  // being written, and failing to get back to it must not lose the summary
  // that says what the run actually did.
  try {
    if (startingRoom != null &&
        provider.openProjectRoom?.id != startingRoom.id) {
      await provider.openProjectRoomRef(startingRoom);
    }
  } catch (e, stack) {
    AppLogger.logError('Save All could not reopen the room it started on', e, stack);
  }
  provider.selectTab(startingTab);
  messenger.hideCurrentSnackBar();

  // The navigator rather than the page: the page this was started from has
  // been rebuilt several times over by now, and the summary is the only record
  // of what happened.
  if (!navigator.mounted) return;
  await showDialog<void>(
    context: navigator.context,
    builder: (_) => _SaveAllSummary(parent: parent, done: done),
  );
}

/// One room's folder, or the reason there is not one.
typedef RoomFolderResult = ({
  String room,
  ProjectExport? export,
  String error,
});

/// What Save All wrote, room by room.
///
/// A ROOM AT A TIME, NAMED. On a job of nine rooms the one thing somebody
/// needs from this dialog is "did they all go" - so every room is a line
/// whether it worked or not, and the ones that did not are the only ones that
/// have to be read.
class _SaveAllSummary extends StatelessWidget {
  final String parent;
  final List<RoomFolderResult> done;

  const _SaveAllSummary({required this.parent, required this.done});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = [for (final d in done) if (d.error.isNotEmpty) d];
    final files = done.fold<int>(
      0,
      (sum, d) => sum + (d.export?.written.length ?? 0),
    );
    final alarm = errorTextOn(
      theme.colorScheme,
      theme.dialogTheme.backgroundColor ??
          theme.colorScheme.surfaceContainerHigh,
    );

    const mono = TextStyle(fontFamily: 'monospace', fontSize: 12);

    return AlertDialog(
      key: const ValueKey('save_all_summary'),
      title: Text(
        failed.isEmpty
            ? (done.length == 1 ? 'Room saved' : '${done.length} rooms saved')
            : '${done.length - failed.length} of ${done.length} rooms saved',
      ),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              parent,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text('$files files written', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final d in done) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 2),
                        child: Text(
                          d.room,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: d.error.isEmpty ? null : alarm,
                          ),
                        ),
                      ),
                      if (d.error.isNotEmpty)
                        Text('  ${d.error}', style: mono)
                      else ...[
                        Text(
                          '  ${path.basename(d.export!.folder)}',
                          style: mono,
                        ),
                        Text(
                          '  ${d.export!.written.length} files',
                          style: mono.copyWith(color: theme.disabledColor),
                        ),
                        for (final note in d.export!.skipped)
                          Text(
                            '  not included: $note',
                            style: mono.copyWith(color: theme.disabledColor),
                          ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            final error = await context
                .read<AppStateProvider>()
                .revealInFileManager(parent);
            if (error != null) {
              messenger.showSnackBar(SnackBar(content: Text(error)));
            }
          },
          child: const Text('OPEN FOLDER'),
        ),
        ElevatedButton(
          key: const ValueKey('save_all_done'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
//  CLOSING THE APP
// ---------------------------------------------------------------------------

/// Asks before work goes out of the window with the window.
///
/// Returns true when the app may close. Three answers rather than two: Save
/// and close is what most people mean, Close without saving is a real choice
/// people are entitled to make deliberately, and Cancel is what the X on the
/// title bar means when it was a mis-click.
///
/// The last autosave is named in the dialog on purpose. Somebody who is about
/// to discard an afternoon should be able to see, in the same breath, that a
/// copy of it exists and where.
Future<bool> confirmCloseWithUnsavedWork(
  BuildContext context,
  AppStateProvider provider,
) async {
  final lines = provider.unsavedWorkSummary;
  if (lines.isEmpty) return true;

  final answer = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('exit_unsaved_dialog'),
      title: Row(children: [
        const Icon(Icons.warning_amber, color: Colors.orange),
        const SizedBox(width: 10),
        Expanded(
          child: Text('Close without saving?',
              style: Theme.of(ctx).textTheme.titleLarge),
        ),
      ]),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('•  '),
                    Expanded(child: Text(line)),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Text(
              autosaveStatusLine(provider),
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('exit_cancel'),
          onPressed: () => Navigator.pop(ctx, 'cancel'),
          child: const Text('Keep working'),
        ),
        TextButton(
          key: const ValueKey('exit_discard'),
          onPressed: () => Navigator.pop(ctx, 'discard'),
          child: const Text('Close without saving'),
        ),
        FilledButton(
          key: const ValueKey('exit_save'),
          onPressed: () => Navigator.pop(ctx, 'save'),
          child: const Text('Save and close'),
        ),
      ],
    ),
  );

  if (answer == 'save') {
    if (!context.mounted) return false;
    // A save that fails — or a Save As that was cancelled — must not close the
    // app: that would lose exactly the work the user just asked to keep.
    return saveEverything(context, provider);
  }
  if (answer == 'discard') {
    // Said deliberately, so the recovery copy goes with it. Leaving it behind
    // would mean being asked about this same work on Monday, which is
    // second-guessing an answer the user has already given — and the recovery
    // prompt would then be a thing people learn to dismiss, which is how the
    // one that mattered gets dismissed too.
    provider.clearAllRecovery();
    return true;
  }
  return false;
}

/// One sentence about the recovery copy, for the exit dialog, the start screen
/// and App Config.
String autosaveStatusLine(AppStateProvider provider) {
  if (!provider.autosaveEnabled) {
    return 'Autosave is off - there is no recovery copy of this work.';
  }
  if (provider.lastAutosaveError.isNotEmpty) {
    return 'The last recovery copy failed: ${provider.lastAutosaveError}';
  }
  final at = provider.lastAutosaveAt;
  final folder = provider.lastAutosaveFolder;
  if (at == null || folder.isEmpty) {
    return 'A recovery copy is kept every ${provider.autosaveMinutes} minute'
        '${provider.autosaveMinutes == 1 ? '' : 's'} while there is unsaved '
        'work. Nothing is waiting to be recovered right now.';
  }
  return 'Unsaved work copied ${_clock(at)} to $folder.';
}

String _clock(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'at ${two(t.hour)}:${two(t.minute)}';
}

// ---------------------------------------------------------------------------
//  THE TOOLBAR CONTROL
// ---------------------------------------------------------------------------

/// The toolbar's save control: a button that saves whatever tab you are on,
/// and a menu beside it holding every other way to save.
///
/// Two widgets rather than a single split button because they answer different
/// questions. The button is the one somebody presses forty times an afternoon
/// without reading it, so it has to mean the obvious thing for the page they
/// are on. The menu is where the deliberate saves live — Save As, the other
/// document, the whole room folder — and those are read before they are
/// pressed.
class SaveToolbar extends StatelessWidget {
  const SaveToolbar({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final tabIndex = provider.selectedTabIndex;
    final tab = (tabIndex >= 0 && tabIndex < AppTab.values.length)
        ? AppTab.values[tabIndex]
        : AppTab.wizard;
    final scope = saveScopeForTab(tab);
    final noun = saveScopeNoun(scope);
    final blocked = saveBlockedReason(provider, scope);
    final dirty = saveScopeIsDirty(provider, scope);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // BACK ONE STEP ON WHATEVER THIS PAGE EDITS, driven by the same
        // question the save button answers. Nothing at all on the pages that
        // carry their own pair - see [toolbarUndoTarget].
        ToolbarUndoButtons(tab: tab),
        IconButton(
          key: const ValueKey('save_context'),
          icon: Badge(
            // A dot, not a count: "this page is behind its file" is the whole
            // message, and a number would invite somebody to work out what it
            // was counting.
            isLabelVisible: dirty,
            smallSize: 8,
            child: const Icon(Icons.save),
          ),
          tooltip: blocked.isNotEmpty
              ? 'Save $noun - $blocked'
              : saveScopeNeedsFile(provider, scope)
                  ? 'Save $noun (Ctrl+S) - this ${noun.toLowerCase()} has no '
                      'file yet, so this asks where to put it'
                  : 'Save $noun (Ctrl+S) - ${saveScopeDescription(scope)}'
                  '${dirty ? '\nThis $noun has unsaved changes.' : ''}',
          onPressed: blocked.isNotEmpty
              ? null
              : () => runSave(context, provider, scope),
        ),
        PopupMenuButton<String>(
          key: const ValueKey('save_menu'),
          // Deliberately NOT Icons.save: the button beside it is the save, and
          // two floppies in a row is two buttons nobody can tell apart.
          icon: const Icon(Icons.arrow_drop_down),
          tooltip: 'More ways to save',
          onSelected: (value) => _onSelected(context, provider, scope, value),
          itemBuilder: (ctx) => [
            PopupMenuItem(
              value: 'save',
              enabled: blocked.isEmpty,
              child: _MenuLine(
                icon: Icons.save,
                label: 'Save $noun',
                hint: blocked.isNotEmpty
                    ? blocked
                    : saveScopeNeedsFile(provider, scope)
                        ? 'No file yet - this asks where to put it'
                        : saveScopeDescription(scope),
                shortcut: 'Ctrl+S',
              ),
            ),
            if (saveScopeSupportsSaveAs(scope))
              PopupMenuItem(
                value: 'save_as',
                child: _MenuLine(
                  icon: Icons.save_as,
                  label: 'Save $noun As…',
                  hint: 'Write it to a new file and work from that one',
                  shortcut: 'Ctrl+Shift+S',
                ),
              ),
            const PopupMenuDivider(),
            // The other document, so it is never more than one menu away from
            // wherever somebody happens to be standing.
            if (scope != SaveScope.room)
              PopupMenuItem(
                value: 'save_room',
                enabled: provider.roomConfig.isNotEmpty,
                child: _MenuLine(
                  icon: Icons.meeting_room_outlined,
                  label: 'Save Room',
                  hint: saveScopeDescription(SaveScope.room),
                ),
              ),
            if (scope != SaveScope.project)
              PopupMenuItem(
                value: 'save_project',
                child: _MenuLine(
                  icon: Icons.account_tree_outlined,
                  label: 'Save Project',
                  hint: saveScopeDescription(SaveScope.project),
                ),
              ),
            PopupMenuItem(
              value: 'save_everything',
              child: _MenuLine(
                icon: Icons.done_all,
                label: 'Save Everything',
                hint: 'Every open document that is behind its file',
                shortcut: 'Ctrl+Alt+S',
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'save_all_folder',
              enabled: provider.roomConfig.isNotEmpty,
              child: _MenuLine(
                icon: Icons.drive_folder_upload,
                label: 'Save All to a room folder…',
                hint: 'Config, diagrams, reports, workbook and images - one '
                    'folder per room, for every room on the job',
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'backup_now',
              child: _MenuLine(
                icon: Icons.backup_outlined,
                label: 'Copy unsaved work now',
                hint: autosaveStatusLine(provider),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _onSelected(
    BuildContext context,
    AppStateProvider provider,
    SaveScope scope,
    String value,
  ) async {
    switch (value) {
      case 'save':
        await runSave(context, provider, scope);
      case 'save_as':
        await runSave(context, provider, scope, saveAs: true);
      case 'save_room':
        await runSave(context, provider, SaveScope.room);
      case 'save_project':
        await runSave(context, provider, SaveScope.project);
      case 'save_everything':
        await saveEverything(context, provider);
      case 'save_all_folder':
        await saveAllToRoomFolder(context, provider);
      case 'backup_now':
        final messenger = ScaffoldMessenger.of(context);
        final folder = await provider.writeAutosaveSnapshot(force: true);
        showTimedSnackBar(
          messenger,
          SnackBar(
            duration: const Duration(seconds: 6),
            content: Text(folder.isEmpty
                ? (provider.lastAutosaveError.isEmpty
                    ? 'Everything is saved - there is nothing a recovery copy '
                        'would hold.'
                    : 'The recovery copy failed: ${provider.lastAutosaveError}')
                : 'Recovery copy written to $folder'),
            backgroundColor:
                folder.isEmpty && provider.lastAutosaveError.isNotEmpty
                    ? snackErrorFillOn(messenger)
                    : null,
          ),
        );
    }
  }
}

/// One row of the save menu: what it does, what it writes, and the key that
/// does it without opening the menu at all.
class _MenuLine extends StatelessWidget {
  final IconData icon;
  final String label;
  final String hint;
  final String shortcut;

  const _MenuLine({
    required this.icon,
    required this.label,
    required this.hint,
    this.shortcut = '',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      // Wide enough for the hint to read as a sentence rather than as three
      // words a line. The menu is only opened deliberately, so it can afford
      // the room.
      width: 380,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 12),
            child: Icon(icon, size: 18),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(label)),
                    if (shortcut.isNotEmpty)
                      Text(shortcut,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.disabledColor)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(hint,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.disabledColor)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
