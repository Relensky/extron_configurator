import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Writes [contents] to [filePath] so the file is never left half written.
///
/// A plain write empties the file first; if the app stops before the new
/// contents land, the room is left as a 0-byte file that will not open. This
/// writes a temp file beside it, flushes it to disk, then swaps it into place,
/// so the old file stays whole until the new one is complete.
///
/// ON A SHARE, OTHER PEOPLE ARE SAVING TOO. The temp name is unique to this
/// save, so two people saving the same file at once never write into each
/// other's temp file, and a swap refused because someone else has the file
/// open for that moment is retried before falling back to a plain write.
Future<void> writeFileSafely(String filePath, String contents) async {
  final temp = File(_tempName(filePath));
  await _retry(() => temp.writeAsString(contents, flush: true));
  try {
    await _retry(() => temp.rename(filePath));
  } on FileSystemException {
    // The target is locked against a rename (a sync client, a scanner): fall
    // back to an ordinary write rather than fail the save.
    try {
      await _retry(() => File(filePath).writeAsString(contents, flush: true));
    } finally {
      try {
        await temp.delete();
      } catch (_) {}
    }
  }
}

/// [writeFileSafely] for the callers that cannot await.
void writeFileSafelySync(String filePath, String contents) {
  final temp = File(_tempName(filePath));
  _retrySync(() => temp.writeAsStringSync(contents, flush: true));
  try {
    _retrySync(() => temp.renameSync(filePath));
  } on FileSystemException {
    try {
      _retrySync(
        () => File(filePath).writeAsStringSync(contents, flush: true),
      );
    } finally {
      try {
        temp.deleteSync();
      } catch (_) {}
    }
  }
}

final Random _random = Random();

/// Replaces the temp file name, for a test that needs to know it.
@visibleForTesting
String Function(String filePath)? safeWriteTempNameForTest;

String _tempName(String filePath) =>
    safeWriteTempNameForTest?.call(filePath) ??
    '$filePath.$pid-${_random.nextInt(1 << 32).toRadixString(36)}.saving';

/// Waits between tries: a file held open by an antivirus scan or another
/// person's save is usually free again within a second.
const List<int> _retryDelaysMs = [100, 250, 500, 1000, 2000];

/// Windows' "in use" answers: access denied (what a rename over a file an
/// antivirus scan has open gets), sharing violation, lock violation. Anything
/// else - a missing folder, a full disk - will not clear by waiting.
bool _mayClear(FileSystemException e) {
  final code = e.osError?.errorCode;
  return code == 5 || code == 32 || code == 33;
}

Future<T> _retry<T>(Future<T> Function() action) async {
  for (var attempt = 0;; attempt++) {
    try {
      return await action();
    } on FileSystemException catch (e) {
      if (!_mayClear(e) || attempt >= _retryDelaysMs.length) rethrow;
      await Future<void>.delayed(
        Duration(milliseconds: _retryDelaysMs[attempt]),
      );
    }
  }
}

T _retrySync<T>(T Function() action) {
  for (var attempt = 0;; attempt++) {
    try {
      return action();
    } on FileSystemException catch (e) {
      if (!_mayClear(e) || attempt >= _retryDelaysMs.length) rethrow;
      sleep(Duration(milliseconds: _retryDelaysMs[attempt]));
    }
  }
}
