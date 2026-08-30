import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'av_device_library.dart';
import 'base_costs.dart';
import 'building_project.dart';
import 'online_index.dart';
import 'project_estimate.dart';
import 'project_workbook.dart';

/// ============================================================================
///  THE COPY SOMEBODY ELSE CAN READ
/// ============================================================================
///  This app runs on one machine. The people who ask about a job do not sit at
///  it: the stakeholder wants the number, the technician on site wants to know
///  whether the mounts landed, and up to now the answer to both was a workbook
///  emailed round — which is out of date the moment anything changes, and which
///  arrives as somebody's fourth copy of a file called project(3).xlsx.
///
///  SO THE JOB PUBLISHES ITSELF INTO A FOLDER THAT ALREADY SYNCS. OneDrive and
///  Google Drive both keep a folder on this machine in step with the cloud;
///  write the workbook into it and Excel Online opens it as a spreadsheet,
///  Google Drive opens it as a Sheet. No account to connect, no app to
///  register, nothing to renew — the sync client the machine already runs does
///  the part this app would otherwise need an OAuth stack for.
///
///  THE FILE NAME NEVER CHANGES, which is the whole trick. A share link points
///  at a FILE, so rewriting the same name means the link somebody sent in March
///  still opens the current figures in June. A name with a date in it would
///  mean a new link every time, which is the emailed-workbook problem again
///  wearing a different hat.
///
///  IT GOES ONE WAY BY DEFAULT. An edit made in Excel Online or Google Sheets
///  changes that copy and nothing else, and the next publish overwrites it.
///  That is a deliberate limit: a document that quietly took changes back from
///  a copy several people can edit is a document that loses work without
///  anybody being told. What goes out is a picture of the job, and the job
///  stays here.
///
///  TWO SHEETS ARE THE EXCEPTION, and they are read back only when somebody
///  asks and only after being shown what would change — see
///  online_roundtrip.dart. Because those two exist, a publish is no longer free
///  to overwrite: it checks first, and stands down rather than destroying what
///  somebody typed. See [onlineCopyMovedSince] at the foot of this file.
/// ============================================================================

/// What one publish wrote.
typedef OnlineCopyResult = ({
  /// The folder it went into.
  String folder,

  /// File names written, in the order they were written.
  List<String> written,

  /// 'name - what went wrong' for anything that could not be written. A
  /// publish that got the workbook out and failed on the project file is a
  /// partial success, and saying which half failed is the difference between
  /// a fixable problem and a mystery.
  List<String> failed,

  /// The moment stamped on the copy.
  DateTime at,
});

/// One file to put in the published folder: bytes for a workbook, text for a
/// .json.
typedef OnlineFile = ({String name, List<int>? bytes, String? text});

/// Writes [files] into [folder], overwriting what is there.
///
/// THE ONE PLACE ANY OF THIS TOUCHES THE DISK, so a campus, a job and a room
/// all publish by the same rules: the same names every time, nothing deleted,
/// nothing renamed, and a file that will not write reported rather than
/// thrown. A sync folder is a place another program has its hands on, and
/// "OneDrive had the file open" is an ordinary Tuesday rather than a crash.
Future<OnlineCopyResult> writeOnlineFiles({
  required String folder,
  required List<OnlineFile> files,
  /// What this publish knows about itself, for the folder's index — see
  /// online_index.dart. Merged into what is already there rather than
  /// replacing it, so the index describes everything ever published here.
  List<OnlineIndexEntry> index = const [],
  DateTime? at,
}) async {
  final stamp = at ?? DateTime.now();
  final written = <String>[];
  final failed = <String>[];
  for (final f in files) {
    try {
      final file = File(path.join(folder, f.name));
      if (f.bytes != null) {
        await file.writeAsBytes(f.bytes!);
      } else {
        await file.writeAsString(f.text ?? '');
      }
      written.add(f.name);
    } catch (e) {
      failed.add('${f.name} - $e');
    }
  }

  // THE INDEX IS NOT ONE OF THE DOCUMENTS. It is written after them, it is
  // never counted among them - "Bessey_Hall_project.xlsx and index.xlsx and
  // index.json written" reads as three documents when one was asked for - and
  // it is only written when something else was, so a publish that wrote
  // nothing does not leave an index claiming otherwise. A failure to write it
  // is still reported: an index nobody can see going stale is worse than none.
  if (index.isNotEmpty && written.isNotEmpty) {
    try {
      final merged = mergeOnlineIndex(readOnlineIndex(folder), index);
      await File(path.join(folder, kOnlineIndexJson))
          .writeAsString(onlineIndexJson(merged, at: stamp));
      await File(path.join(folder, kOnlineIndexWorkbook))
          .writeAsBytes(buildOnlineIndexWorkbook(merged, at: stamp));
    } catch (e) {
      failed.add('$kOnlineIndexWorkbook - $e');
    }
  }

  return (folder: folder, written: written, failed: failed, at: stamp);
}

/// The indented JSON this app writes everywhere, because somebody will open
/// the published copy in a text editor.
String onlineJsonText(Object document) =>
    const JsonEncoder.withIndent('    ').convert(document);

/// A campus sheet's two published files.
String onlineCampusWorkbookName(String stem) => '${_safe(stem)}_campus.xlsx';
String onlineCampusFileName(String stem) => '${_safe(stem)}_campus.json';

/// A room's two published files. [stem] is the room's own export stem —
/// `BSS_103` — so the folder sorts by building and room.
String onlineRoomWorkbookName(String stem) => '${_safe(stem)}_room.xlsx';
String onlineRoomFileName(String stem) => '${_safe(stem)}_room_config.json';

/// Anything that would not survive being a file name.
String _safe(String raw) {
  final clean = raw
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
      .replaceAll(RegExp(r'\s+'), '_');
  return clean.isEmpty ? 'untitled' : clean;
}

/// The workbook's file name in the published folder.
///
/// The same stem the Save dialog offers, so the file in the sync folder and
/// the file somebody saved by hand are recognisably the same document.
String onlineWorkbookName(BuildingProject project) =>
    '${onlineFileStem(project)}_project.xlsx';

/// The project file's name in the published folder.
String onlineProjectFileName(BuildingProject project) =>
    '${onlineFileStem(project)}_project.json';

/// `Bessey_Hall` — the job, as a file name.
///
/// A copy of the rule in workbook_export.dart, which cannot be imported here:
/// that file is a Flutter UI flow and this one is meant to be callable, and
/// testable, with no widgets anywhere near it.
String onlineFileStem(BuildingProject project) {
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

/// Writes the published copy into [folder].
///
/// The workbook always; the project file too when [includeProjectFile] is set,
/// which is what makes the folder enough to open the job somewhere else rather
/// than only enough to read it.
///
/// NOTHING IS DELETED AND NOTHING IS RENAMED. Both files are overwritten in
/// place, so a share link keeps working — see the note at the head of this
/// file. A file that cannot be written is reported rather than thrown: a sync
/// folder is a place another program has its hands on, and "OneDrive had the
/// file open" is an ordinary Tuesday rather than a crash.
Future<OnlineCopyResult> writeOnlineCopy({
  required ProjectEstimate estimate,
  required String folder,
  required AvDeviceLibrary library,
  required BaseCostBook baseCosts,
  PricingTier tier = PricingTier.msrp,
  bool includeProjectFile = true,
  /// The project file's own path — what the index joins this job to its campus
  /// and its rooms by. See online_index.dart.
  String source = '',
  /// The rooms' config paths, absolute, and the campus file this job is on.
  List<String> roomPaths = const [],
  String campusPath = '',
  DateTime? at,
}) async {
  final stamp = at ?? DateTime.now();
  final project = estimate.project;

  return writeOnlineFiles(
    folder: folder,
    at: stamp,
    index: source.trim().isEmpty
        ? const []
        : [
            (
              kind: 'project',
              name: project.name.trim().isEmpty
                  ? onlineFileStem(project)
                  : project.name.trim(),
              source: source.trim(),
              parent: campusPath.trim(),
              children: roomPaths,
              files: [
                onlineWorkbookName(project),
                if (includeProjectFile) onlineProjectFileName(project),
              ],
              note: [
                '${roomPaths.length} room${roomPaths.length == 1 ? '' : 's'}',
                if (project.projectNumber.trim().isNotEmpty)
                  'project number ${project.projectNumber.trim()}',
              ].join(', '),
              at: stamp,
            ),
          ],
    files: [
      (
        name: onlineWorkbookName(project),
        bytes: buildProjectWorkbookBytes(
          estimate: estimate,
          library: library,
          baseCosts: baseCosts,
          tier: tier,
          generated: stamp,
          // The published copy is the one that comes back: it carries the two
          // sheets somebody can type in. See online_roundtrip.dart.
          editable: true,
        ),
        text: null,
      ),
      // The job itself, so the folder is enough to OPEN the project on another
      // machine rather than only to read it.
      if (includeProjectFile)
        (
          name: onlineProjectFileName(project),
          bytes: null,
          text: onlineJsonText(project.toJson()),
        ),
    ],
  );
}

/// 'published 3 days ago' — how stale the copy somebody else is reading is.
///
/// SAID IN DAYS, not as a date. "Published 2026-04-02" makes the reader do the
/// arithmetic, and the arithmetic is the entire question: a copy from this
/// morning needs no thought and one from five weeks ago is the reason the
/// figure being quoted back at you is wrong.
String onlineFreshnessText(DateTime? published, {DateTime? asOf}) {
  if (published == null) return 'Not published yet.';
  final now = asOf ?? DateTime.now();
  final days = dateOnly(now).difference(dateOnly(published)).inDays;
  return switch (days) {
    <= 0 => 'Published today.',
    1 => 'Published yesterday.',
    < 14 => 'Published $days days ago.',
    _ => 'Published $days days ago - the copy people are reading is stale.',
  };
}

/// ============================================================================
///  WHAT SOMEBODY ELSE TYPED, THAT A PUBLISH WOULD WRITE OVER
/// ============================================================================
///  The note at the head of this file says the copy goes one way and the next
///  publish overwrites it. That was true when the copy was a report. It stopped
///  being acceptable the moment two of its sheets became a FORM — see
///  online_roundtrip.dart — because those sheets exist precisely so that a
///  technician on site types into them, and reading them back is a thing
///  somebody has to remember to do.
///
///  So publish-on-save had a hole in it the size of the feature: a delivery
///  logged in Excel Online this morning was gone the next time anybody pressed
///  Ctrl+S here, with no warning to the person who typed it and none to the
///  person who overwrote it.
///
///  THE FILE'S OWN TIMESTAMP IS THE GATE, not the answer. A sync client
///  rewrites a file it has only re-downloaded, so a moved timestamp means
///  "worth looking at" and nothing more. What makes it a conflict is reading
///  the sheets back and finding a row that differs from the job — which costs
///  a file read, and is why the timestamp is asked first.
/// ============================================================================

/// The published workbook, and when it was last written to.
typedef OnlineCopyStamp = ({String file, DateTime modified});

/// The workbook this job publishes into [folder], with the moment it was last
/// written — or null when it is not there.
///
/// Used two ways: recorded straight after a publish, so the app knows the
/// timestamp it is responsible for, and read again before the next one to see
/// whether anything moved it in between.
OnlineCopyStamp? onlineWorkbookStamp({
  required String folder,
  required String workbookName,
}) {
  if (folder.trim().isEmpty || workbookName.trim().isEmpty) return null;
  try {
    final file = File(path.join(folder.trim(), workbookName));
    if (!file.existsSync()) return null;
    return (file: file.path, modified: file.lastModifiedSync());
  } catch (_) {
    // A folder that cannot be read is not a folder with edits in it. Publishing
    // will report its own failure; this check does not get to raise one.
    return null;
  }
}

/// How far the file's timestamp may sit ahead of the moment a publish STARTED
/// before it counts as somebody else's writing.
///
/// Only used for a job published by a version that recorded no file stamp of
/// its own. [OnlineCopyResult.at] is taken before the bytes go down, so the
/// timestamp the filesystem ends up with is always a little later, and a
/// workbook of any size takes a moment to write.
const Duration kOnlinePublishGrace = Duration(minutes: 1);

/// Whether the published workbook has been written to since this app published
/// it.
///
/// [ourStamp] is the timestamp recorded when this app last published — the
/// exact answer. [publishedAt] is the fallback for a job saved before that was
/// recorded, and is deliberately generous: guessing WRONG here means either
/// nagging about a file nobody touched, or missing edits, and of those two the
/// nag is the one somebody can dismiss.
bool onlineCopyMovedSince(
  OnlineCopyStamp? now, {
  DateTime? ourStamp,
  DateTime? publishedAt,
}) {
  if (now == null) return false;
  if (ourStamp != null) {
    // Not `isAfter`: a sync client that restored an older copy moved the file
    // too, and that copy may hold the very rows this is meant to protect.
    return now.modified != ourStamp;
  }
  if (publishedAt == null) return false;
  return now.modified.isAfter(publishedAt.add(kOnlinePublishGrace));
}
