import 'dart:io';

/// Writes [contents] to [filePath] so the file is never left half written.
///
/// A plain write empties the file first; if the app stops before the new
/// contents land, the room is left as a 0-byte file that will not open. This
/// writes a `.saving` file beside it, flushes it to disk, then swaps it into
/// place, so the old file stays whole until the new one is complete.
Future<void> writeFileSafely(String filePath, String contents) async {
  final temp = File('$filePath.saving');
  await temp.writeAsString(contents, flush: true);
  try {
    await temp.rename(filePath);
  } on FileSystemException {
    // The target is locked against a rename (a sync client, a scanner): fall
    // back to an ordinary write rather than fail the save.
    await File(filePath).writeAsString(contents, flush: true);
    try {
      await temp.delete();
    } catch (_) {}
  }
}

/// [writeFileSafely] for the callers that cannot await.
void writeFileSafelySync(String filePath, String contents) {
  final temp = File('$filePath.saving');
  temp.writeAsStringSync(contents, flush: true);
  try {
    temp.renameSync(filePath);
  } on FileSystemException {
    File(filePath).writeAsStringSync(contents, flush: true);
    try {
      temp.deleteSync();
    } catch (_) {}
  }
}
