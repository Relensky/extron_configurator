import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'av_device_library.dart';
import 'base_costs.dart';
import 'building_project.dart';
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
///  IT GOES ONE WAY ONLY. Nothing is read back. An edit made in Excel Online or
///  Google Sheets changes that copy and nothing else, and the next publish
///  overwrites it. That is a deliberate limit: a document that quietly took
///  changes back from a copy several people can edit is a document that loses
///  work without anybody being told. What goes out is a picture of the job, and
///  the job stays here.
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
  DateTime? at,
}) async {
  final stamp = at ?? DateTime.now();
  final project = estimate.project;
  final written = <String>[];
  final failed = <String>[];

  Future<void> write(String name, Future<void> Function(File) body) async {
    try {
      await body(File(path.join(folder, name)));
      written.add(name);
    } catch (e) {
      failed.add('$name - $e');
    }
  }

  await write(
    onlineWorkbookName(project),
    (file) => file.writeAsBytes(
      buildProjectWorkbookBytes(
        estimate: estimate,
        library: library,
        baseCosts: baseCosts,
        tier: tier,
        generated: stamp,
      ),
    ),
  );

  if (includeProjectFile) {
    // The job itself, so the folder is enough to OPEN the project on another
    // machine rather than only to read it. Written with the same indent the
    // app saves with, because somebody will look at it in a text editor.
    const encoder = JsonEncoder.withIndent('    ');
    await write(
      onlineProjectFileName(project),
      (file) => file.writeAsString(encoder.convert(project.toJson())),
    );
  }

  return (folder: folder, written: written, failed: failed, at: stamp);
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
