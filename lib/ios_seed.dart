import 'dart:io';

import 'package:path/path.dart' as path;

import 'app_paths.dart';

/// ============================================================================
///  iOS: FILL THE APP'S OWN FOLDER ON FIRST LAUNCH
/// ============================================================================
///  On the desktop the shipped data files (config.json, av_devices.json, the
///  schema, costs and room presets) sit beside the executable or on the file
///  server. Neither exists on an iPad or iPhone: the app bundle is read-only and
///  there is no SMB share. So the iOS build carries a copy of them in
///  `Runner.app/seed_data/` (ios/copy_seed_data.sh puts them there), and this
///  copies each one into the app's Documents folder - the Root Folder on iOS -
///  when it is not already there.
///
///  A file already in Documents is never overwritten: once someone has edited
///  the catalog or dropped in a newer one through the Files app, that copy is
///  theirs. Delete a file there to get the shipped copy back on next launch.
/// ============================================================================

/// Copies missing seed files into Documents. Does nothing off iOS, and never
/// throws: a launch without the seed is the same as a desktop launch without
/// the data files, which First-Time Setup already explains.
void seedIosDocuments() {
  final docs = iosDocumentsDirOrNull();
  if (docs == null) return;
  try {
    final seed = Directory(
      path.join(File(Platform.resolvedExecutable).parent.path, 'seed_data'),
    );
    if (!seed.existsSync()) return;
    Directory(docs).createSync(recursive: true);
    for (final entity in seed.listSync(recursive: true)) {
      if (entity is! File) continue;
      final rel = path.relative(entity.path, from: seed.path);
      final target = File(path.join(docs, rel));
      if (target.existsSync()) continue;
      target.parent.createSync(recursive: true);
      entity.copySync(target.path);
    }
  } catch (_) {
    // See the doc comment: First-Time Setup shows what is missing.
  }
}
