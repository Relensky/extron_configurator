// ============================================================================
// [FEATURE - APP UPDATES]: the Windows half of folder_updater.dart - reading
// versions out of exes, reading release zips, and the helper that swaps the
// files while the app is closed. No packages: a zip reader and a version
// resource reader are a few dozen lines each, and not depending on `archive`
// is what lets this folder drop into every app unchanged.
//
// WHICH FILES AN UPDATE REPLACES. A release zip is a copy of someone's whole
// install folder, so besides the program it carries their config, caches and
// logs. The helper therefore:
//   * REPLACES the program: `*.exe` and `*.dll` beside the exe, and everything
//     under `data\` (app.so, icudtl.dat, flutter_assets).
//   * ADDS any other file only if this install does not have it yet - a new
//     reference file arrives, but the user's config.json, caches, logs,
//     quizzes and settings are never overwritten.
// Replaced files are moved to %LOCALAPPDATA%\<exe name>\updates\backup first,
// and put back if anything fails, so a half-applied update rolls back to the
// version that was running.
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'folder_updater.dart';

bool get updatesSupported => Platform.isWindows;

String? releaseFolderOverride() {
  final v = Platform.environment[FolderUpdater.folderEnvironmentVariable];
  return (v == null || v.trim().isEmpty) ? null : v.trim();
}

/// The running exe's version resource.
Future<AppBuildVersion?> readRunningVersion() async {
  final bytes = await File(Platform.resolvedExecutable).readAsBytes();
  return readExeVersion(bytes);
}

String get _exeName =>
    Platform.resolvedExecutable.split(RegExp(r'[\\/]')).last;

String get _exeBaseName {
  final name = _exeName;
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// %LOCALAPPDATA%\<exe name>\updates - where downloads, staging, backups and
/// the helper's log live.
Directory get _workDir {
  final local = Platform.environment['LOCALAPPDATA'];
  final base = (local != null && local.isNotEmpty)
      ? local
      : Directory.systemTemp.path;
  return Directory('$base\\$_exeBaseName\\updates');
}

// ---------------------------------------------------------------------------
// Finding a release
// ---------------------------------------------------------------------------

/// Zip inspections, keyed by path + size + timestamp, so a folder that has
/// not changed is not re-read every half hour.
final Map<String, ZipRelease?> _inspected = {};

/// Whether [fileName] looks like a release of the app with [prefix]:
/// `prefix.zip`, or the prefix followed by `_`, `-`, `.` or a space.
bool isReleaseFileName(String fileName, String prefix) {
  final name = fileName.toLowerCase();
  final p = prefix.toLowerCase();
  if (!name.endsWith('.zip') || !name.startsWith(p)) return false;
  if (name.length == p.length + 4) return true;
  return '_-. '.contains(name[p.length]);
}

/// The newest release zip in [folder] whose exe is newer than [newerThan].
Future<AvailableUpdate?> findNewestRelease({
  required String folder,
  required String prefix,
  required AppBuildVersion newerThan,
  void Function(String)? log,
}) async {
  final dir = Directory(folder);
  final List<File> zips = [];
  try {
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File &&
          isReleaseFileName(entity.uri.pathSegments.last, prefix)) {
        zips.add(entity);
      }
    }
  } on FileSystemException catch (e) {
    throw ReleaseFolderUnavailable(folder, e);
  }

  final exeName = _exeName;
  AvailableUpdate? best;
  for (final zip in zips) {
    final FileStat stat;
    try {
      stat = await zip.stat();
    } on FileSystemException {
      continue;
    }
    final key = '${zip.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    ZipRelease? release;
    if (_inspected.containsKey(key)) {
      release = _inspected[key];
    } else {
      final path = zip.path;
      try {
        release = await Isolate.run(() => inspectReleaseZip(path, exeName));
        _inspected[key] = release;
      } catch (e) {
        // Most often a zip still being copied into the folder. Not cached,
        // so the next check looks again.
        log?.call('[Updater] Skipping ${zip.path}: $e');
        continue;
      }
    }
    if (release == null || !(release.version > newerThan)) continue;
    if (best == null || release.version > best.version) {
      best = AvailableUpdate(
        version: release.version,
        zipPath: zip.path,
        sizeBytes: stat.size,
        modified: stat.modified,
        payloadRoot: release.payloadRoot,
      );
    }
  }
  return best;
}

class ZipRelease {
  final AppBuildVersion version;
  final String payloadRoot;
  const ZipRelease(this.version, this.payloadRoot);
}

/// The version of the [exeName] inside the zip at [zipPath], and the folder
/// it sits in. Null when the zip does not hold that exe (another app's
/// release that happens to share the prefix). Synchronous - run it in an
/// isolate.
ZipRelease? inspectReleaseZip(String zipPath, String exeName) {
  final raf = File(zipPath).openSync();
  try {
    final entries = readZipDirectory(raf);
    final exe = findPayloadExe(entries, exeName);
    if (exe == null) return null;
    final version = readExeVersion(readZipEntry(raf, exe));
    if (version == null) return null;
    final slash = exe.name.lastIndexOf('/');
    return ZipRelease(version, exe.name.substring(0, slash + 1));
  } finally {
    raf.closeSync();
  }
}

/// The entry for [exeName] at the zip's root or one folder down, preferring
/// the root.
ZipEntry? findPayloadExe(List<ZipEntry> entries, String exeName) {
  final lower = exeName.toLowerCase();
  ZipEntry? nested;
  for (final e in entries) {
    final parts = e.name.toLowerCase().split('/');
    if (parts.last != lower) continue;
    if (parts.length == 1) return e;
    if (parts.length == 2) nested ??= e;
  }
  return nested;
}

// ---------------------------------------------------------------------------
// Exe version resource
// ---------------------------------------------------------------------------

/// The FILEVERSION from a Windows exe's VS_VERSION_INFO resource, or null.
///
/// Finds the resource's UTF-16 key and reads the VS_FIXEDFILEINFO that follows
/// it, rather than walking the PE resource tree - the key-then-signature pair
/// does not turn up by accident in code.
AppBuildVersion? readExeVersion(Uint8List bytes) {
  final key = Uint8List.fromList([
    for (final c in 'VS_VERSION_INFO'.codeUnits) ...[c, 0],
  ]);
  final data = ByteData.sublistView(bytes);
  var from = 0;
  while (true) {
    final at = _indexOf(bytes, key, from);
    if (at < 0) return null;
    final end = (at + key.length + 64).clamp(0, bytes.length - 16);
    for (var i = at + key.length; i <= end; i++) {
      if (data.getUint32(i, Endian.little) == 0xFEEF04BD) {
        final ms = data.getUint32(i + 8, Endian.little);
        final ls = data.getUint32(i + 12, Endian.little);
        return AppBuildVersion(ms >> 16, ms & 0xFFFF, ls >> 16, ls & 0xFFFF);
      }
    }
    from = at + 1;
  }
}

int _indexOf(Uint8List haystack, Uint8List needle, int from) {
  final first = needle[0];
  final last = haystack.length - needle.length;
  outer:
  for (var i = from; i <= last; i++) {
    if (haystack[i] != first) continue;
    for (var j = 1; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

// ---------------------------------------------------------------------------
// Zip reading (stored and deflate, zip64 aware)
// ---------------------------------------------------------------------------

class ZipEntry {
  /// Forward-slash path inside the zip. Directories end in `/`.
  final String name;
  final int method;
  final int flags;
  final int compressedSize;
  final int size;
  final int localHeaderOffset;

  const ZipEntry({
    required this.name,
    required this.method,
    required this.flags,
    required this.compressedSize,
    required this.size,
    required this.localHeaderOffset,
  });

  bool get isDirectory => name.endsWith('/');
}

class ZipFormatException implements Exception {
  final String message;
  const ZipFormatException(this.message);
  @override
  String toString() => 'Not a readable zip: $message';
}

ByteData _read(RandomAccessFile raf, int offset, int length) {
  raf.setPositionSync(offset);
  final bytes = raf.readSync(length);
  if (bytes.length != length) {
    throw const ZipFormatException('the file ends early');
  }
  return ByteData.sublistView(bytes);
}

/// The central directory of the zip open in [raf].
List<ZipEntry> readZipDirectory(RandomAccessFile raf) {
  final fileLength = raf.lengthSync();
  if (fileLength < 22) throw const ZipFormatException('too small');

  // End of central directory: 22 bytes plus a comment of up to 65535.
  final tailLength = fileLength < 65557 ? fileLength : 65557;
  final tail = _read(raf, fileLength - tailLength, tailLength);
  var eocd = -1;
  for (var i = tailLength - 22; i >= 0; i--) {
    if (tail.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) {
    throw const ZipFormatException('no end-of-directory record');
  }
  int count = tail.getUint16(eocd + 10, Endian.little);
  int dirSize = tail.getUint32(eocd + 12, Endian.little);
  int dirOffset = tail.getUint32(eocd + 16, Endian.little);

  if (count == 0xFFFF || dirSize == 0xFFFFFFFF || dirOffset == 0xFFFFFFFF) {
    final locator = eocd - 20;
    if (locator >= 0 &&
        tail.getUint32(locator, Endian.little) == 0x07064b50) {
      final at = tail.getUint64(locator + 8, Endian.little);
      final z64 = _read(raf, at, 56);
      if (z64.getUint32(0, Endian.little) != 0x06064b50) {
        throw const ZipFormatException('bad zip64 record');
      }
      count = z64.getUint64(32, Endian.little);
      dirSize = z64.getUint64(40, Endian.little);
      dirOffset = z64.getUint64(48, Endian.little);
    }
  }
  if (dirOffset + dirSize > fileLength) {
    throw const ZipFormatException('the directory runs past the end');
  }

  final dir = _read(raf, dirOffset, dirSize);
  final raw = Uint8List.sublistView(dir);
  final entries = <ZipEntry>[];
  var p = 0;
  for (var n = 0; n < count; n++) {
    if (p + 46 > dirSize ||
        dir.getUint32(p, Endian.little) != 0x02014b50) {
      throw const ZipFormatException('bad directory entry');
    }
    final flags = dir.getUint16(p + 8, Endian.little);
    final method = dir.getUint16(p + 10, Endian.little);
    int compressed = dir.getUint32(p + 20, Endian.little);
    int size = dir.getUint32(p + 24, Endian.little);
    final nameLength = dir.getUint16(p + 28, Endian.little);
    final extraLength = dir.getUint16(p + 30, Endian.little);
    final commentLength = dir.getUint16(p + 32, Endian.little);
    int offset = dir.getUint32(p + 42, Endian.little);

    final nameBytes = raw.sublist(p + 46, p + 46 + nameLength);
    final String name = (flags & 0x800) != 0
        ? utf8.decode(nameBytes, allowMalformed: true)
        : _decodeLegacyName(nameBytes);

    // Zip64 sizes and offset live in extra field 0x0001, each present only
    // when its 32-bit slot is maxed out.
    var e = p + 46 + nameLength;
    final extraEnd = e + extraLength;
    while (e + 4 <= extraEnd) {
      final id = dir.getUint16(e, Endian.little);
      final len = dir.getUint16(e + 2, Endian.little);
      if (id == 0x0001) {
        var q = e + 4;
        if (size == 0xFFFFFFFF) {
          size = dir.getUint64(q, Endian.little);
          q += 8;
        }
        if (compressed == 0xFFFFFFFF) {
          compressed = dir.getUint64(q, Endian.little);
          q += 8;
        }
        if (offset == 0xFFFFFFFF) {
          offset = dir.getUint64(q, Endian.little);
        }
      }
      e += 4 + len;
    }

    entries.add(ZipEntry(
      name: name.replaceAll('\\', '/'),
      method: method,
      flags: flags,
      compressedSize: compressed,
      size: size,
      localHeaderOffset: offset,
    ));
    p += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

/// Names without the UTF-8 flag are nominally code page 437. Everything a
/// release carries is ASCII, so anything else is kept byte-for-byte.
String _decodeLegacyName(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// Where [entry]'s data starts, past its local header.
int _dataOffset(RandomAccessFile raf, ZipEntry entry) {
  final local = _read(raf, entry.localHeaderOffset, 30);
  if (local.getUint32(0, Endian.little) != 0x04034b50) {
    throw ZipFormatException('bad local header for ${entry.name}');
  }
  return entry.localHeaderOffset +
      30 +
      local.getUint16(26, Endian.little) +
      local.getUint16(28, Endian.little);
}

void _checkReadable(ZipEntry entry) {
  if ((entry.flags & 1) != 0) {
    throw ZipFormatException('${entry.name} is encrypted');
  }
  if (entry.method != 0 && entry.method != 8) {
    throw ZipFormatException(
        '${entry.name} uses compression method ${entry.method}; '
        're-create the zip with ordinary (deflate) compression');
  }
}

/// Streams [entry]'s uncompressed bytes to [sink] in chunks.
void _inflateEntry(RandomAccessFile raf, ZipEntry entry,
    void Function(List<int> chunk) sink) {
  _checkReadable(entry);
  var remaining = entry.compressedSize;
  raf.setPositionSync(_dataOffset(raf, entry));
  final filter =
      entry.method == 8 ? RawZLibFilter.inflateFilter(raw: true) : null;
  var written = 0;
  void drain() {
    while (true) {
      final out = filter!.processed(flush: false);
      if (out == null) break;
      written += out.length;
      sink(out);
    }
  }

  while (remaining > 0) {
    final chunk = raf.readSync(remaining < 1 << 16 ? remaining : 1 << 16);
    if (chunk.isEmpty) throw const ZipFormatException('the file ends early');
    remaining -= chunk.length;
    if (filter == null) {
      written += chunk.length;
      sink(chunk);
    } else {
      filter.process(chunk, 0, chunk.length);
      drain();
    }
  }
  if (filter != null) {
    while (true) {
      final out = filter.processed(flush: true, end: true);
      if (out == null) break;
      written += out.length;
      sink(out);
    }
  }
  if (written != entry.size) {
    throw ZipFormatException(
        '${entry.name} unpacked to $written bytes, expected ${entry.size}');
  }
}

/// [entry]'s uncompressed bytes, for small entries such as the exe.
Uint8List readZipEntry(RandomAccessFile raf, ZipEntry entry) {
  final out = BytesBuilder(copy: false);
  _inflateEntry(raf, entry, out.add);
  return out.takeBytes();
}

/// [entry]'s path with [root] removed, or null when it is outside [root] or
/// would escape the folder it is unpacked into.
String? payloadRelativePath(ZipEntry entry, String root) {
  final lowerName = entry.name.toLowerCase();
  if (!lowerName.startsWith(root.toLowerCase())) return null;
  final rel = entry.name.substring(root.length);
  if (rel.isEmpty) return null;
  final parts = rel.split('/');
  if (rel.startsWith('/') ||
      rel.contains(':') ||
      parts.any((s) => s == '..' || s == '.')) {
    return null;
  }
  return rel;
}

// ---------------------------------------------------------------------------
// Installing
// ---------------------------------------------------------------------------

class StagedUpdate {
  final AvailableUpdate update;
  final Directory stagedDir;
  const StagedUpdate(this.update, this.stagedDir);
}

/// Copies the release zip off the share and unpacks it into a staging folder.
Future<StagedUpdate> stageUpdate(
  AvailableUpdate update, {
  required void Function(UpdateProgress) onProgress,
}) async {
  final work = _workDir;
  await work.create(recursive: true);
  final download = File('${work.path}\\download.zip');
  final staged = Directory('${work.path}\\staged');

  // Copy first: unpacking thousands of entries straight off SMB is slow, and
  // a network blip mid-unpack is harder to report than one mid-copy.
  onProgress(const UpdateProgress('Downloading…', 0));
  final source = File(update.zipPath);
  final total = await source.length();
  final out = await download.open(mode: FileMode.write);
  var copied = 0;
  var lastReport = 0;
  try {
    await for (final chunk in source.openRead()) {
      await out.writeFrom(chunk);
      copied += chunk.length;
      if (copied - lastReport > total ~/ 200 || copied == total) {
        lastReport = copied;
        onProgress(UpdateProgress(
            'Downloading…', total == 0 ? null : copied / total));
      }
    }
  } finally {
    await out.close();
  }

  // The zip on the share may have been replaced between the check and now.
  final exeName = _exeName;
  final downloadPath = download.path;
  final release =
      await Isolate.run(() => inspectReleaseZip(downloadPath, exeName));
  if (release == null || release.version != update.version) {
    throw StateError('${update.fileName} changed while it was downloading. '
        'Check for updates again.');
  }

  onProgress(const UpdateProgress('Unpacking…', 0));
  if (await staged.exists()) await staged.delete(recursive: true);
  await staged.create(recursive: true);

  final port = ReceivePort();
  final stagedPath = staged.path;
  final root = release.payloadRoot;
  await Isolate.spawn(_unpackIsolate,
      [port.sendPort, downloadPath, root, stagedPath]);
  await for (final message in port) {
    if (message is double) {
      onProgress(UpdateProgress('Unpacking…', message));
    } else if (message == null) {
      break;
    } else {
      port.close();
      throw StateError('Could not unpack ${update.fileName}: $message');
    }
  }
  port.close();

  if (!await File('$stagedPath\\$exeName').exists()) {
    throw StateError('${update.fileName} did not unpack a $exeName.');
  }
  return StagedUpdate(update, staged);
}

/// Unpacks every entry under `args[2]` of zip `args[1]` into `args[3]`,
/// sending progress fractions, then null when done or an error string.
void _unpackIsolate(List<Object> args) {
  final port = args[0] as SendPort;
  try {
    unpackReleaseZip(args[1] as String, args[2] as String, args[3] as String,
        onProgress: port.send);
    port.send(null);
  } catch (e) {
    port.send('$e');
  }
}

/// Unpacks every entry of the zip at [zipPath] that is under [root] into
/// [dest], with [root] removed from the paths. Synchronous.
void unpackReleaseZip(String zipPath, String root, String dest,
    {void Function(double fraction)? onProgress}) {
  final raf = File(zipPath).openSync();
  try {
    final entries = readZipDirectory(raf);
    final wanted = <(ZipEntry, String)>[];
    var totalBytes = 0;
    for (final e in entries) {
      final rel = payloadRelativePath(e, root);
      if (rel == null) continue;
      if (!e.isDirectory) _checkReadable(e);
      wanted.add((e, rel));
      totalBytes += e.size;
    }
    var done = 0;
    var lastReport = 0;
    for (final (entry, rel) in wanted) {
      final target = '$dest\\${rel.replaceAll('/', '\\')}';
      if (entry.isDirectory) {
        Directory(target).createSync(recursive: true);
        continue;
      }
      File(target).parent.createSync(recursive: true);
      final out = File(target).openSync(mode: FileMode.write);
      try {
        _inflateEntry(raf, entry, (chunk) {
          out.writeFromSync(chunk);
          done += chunk.length;
          if (totalBytes > 0 && done - lastReport > totalBytes ~/ 100) {
            lastReport = done;
            onProgress?.call(done / totalBytes);
          }
        });
      } finally {
        out.closeSync();
      }
    }
  } finally {
    raf.closeSync();
  }
}

/// Starts the helper that waits for this process to exit, swaps the files and
/// starts the new version. Returns once the helper has confirmed it is
/// running; throws if it never does (blocked, or the user said no to the
/// administrator prompt).
Future<void> launchHelper(
  StagedUpdate staged, {
  required AppBuildVersion fromVersion,
  required List<String> arguments,
}) async {
  final work = _workDir;
  final installDir = File(Platform.resolvedExecutable).parent.path;
  final marker = File('${work.path}\\helper_started.txt');
  final script = File('${work.path}\\apply_update.ps1');
  if (await marker.exists()) await marker.delete();

  final elevate = !_canWrite(installDir);
  // UTF-8 with a BOM, or Windows PowerShell 5.1 reads non-ASCII paths as ANSI.
  await script.writeAsBytes([
    0xEF, 0xBB, 0xBF,
    ...utf8.encode(buildApplyScript(
      processId: pid,
      installDir: installDir,
      exeName: _exeName,
      stagedDir: staged.stagedDir.path,
      workDir: work.path,
      workingDirectory: Directory.current.path,
      arguments: arguments,
      fromVersion: fromVersion.toString(),
      toVersion: staged.update.version.toString(),
      elevated: elevate,
    )),
  ]);

  await startHiddenScript(script.path, elevate: elevate);

  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    if (await marker.exists()) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw StateError('The update helper did not start. PowerShell may be '
      'blocked on this computer. The update was not installed.');
}

/// Runs the PowerShell script at [scriptPath] hidden, as a process of its own
/// that outlives this one, elevated when [elevate] (Windows asks the user).
///
/// Not simply `Process.start(..., mode: detached)`: PowerShell started with no
/// console at all never runs its script. So a short-lived PowerShell asks
/// Windows to start the real one with Start-Process, which gives it a hidden
/// console and no ties to this app, and reports back whether that worked -
/// including the user saying no to the administrator prompt.
Future<void> startHiddenScript(String scriptPath, {bool elevate = false}) async {
  final helperArgs = [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-WindowStyle',
    'Hidden',
    '-File',
    scriptPath,
  ];
  // Start-Process joins -ArgumentList with spaces and quotes nothing, so each
  // argument is double-quoted here; the single quotes are PowerShell's.
  final argList =
      helperArgs.map((a) => "'${_psQuote('"$a"')}'").join(',');
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-WindowStyle',
    'Hidden',
    '-Command',
    "\$ErrorActionPreference = 'Stop'; "
        'Start-Process -FilePath powershell.exe${elevate ? ' -Verb RunAs' : ''} '
        '-WindowStyle Hidden -ArgumentList $argList',
  ]);
  if (result.exitCode != 0) {
    final detail = '${result.stderr}'.trim().split(RegExp(r'\r?\n')).first;
    throw StateError(elevate
        ? 'The update needs administrator permission to replace the files '
            'in this folder, and it was not given. ($detail)'
        : 'The update helper could not be started: $detail');
  }
}

bool _canWrite(String dir) {
  final probe = File('$dir\\.update_write_test_$pid');
  try {
    probe.writeAsStringSync('');
    probe.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
}

Never exitForUpdate() => exit(0);

/// The result the helper left behind, once. Also clears out the download and
/// staging folders it no longer needs.
Future<UpdateOutcome?> takeLastOutcome() async {
  final work = _workDir;
  final result = File('${work.path}\\last_update.json');
  UpdateOutcome? outcome;
  if (await result.exists()) {
    try {
      var text = await result.readAsString();
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      final json = jsonDecode(text) as Map<String, dynamic>;
      outcome = UpdateOutcome(
        succeeded: json['ok'] == true,
        message: '${json['message'] ?? ''}',
        fromVersion: '${json['from'] ?? ''}',
        toVersion: '${json['to'] ?? ''}',
      );
    } catch (_) {}
    try {
      await result.delete();
    } catch (_) {}
  }
  // Only tidy once the helper is finished with them - a result file means it
  // is; so does there being no helper marker at all.
  if (outcome != null ||
      !await File('${work.path}\\helper_started.txt').exists()) {
    for (final name in ['download.zip', 'staged', 'backup', 'helper_started.txt']) {
      final path = '${work.path}\\$name';
      try {
        if (await FileSystemEntity.isDirectory(path)) {
          await Directory(path).delete(recursive: true);
        } else if (await File(path).exists()) {
          await File(path).delete();
        }
      } catch (_) {}
    }
  }
  return outcome;
}

String _psQuote(String s) => s.replaceAll("'", "''");

/// The PowerShell (5.1) helper, with its inputs written in as literals.
String buildApplyScript({
  required int processId,
  required String installDir,
  required String exeName,
  required String stagedDir,
  required String workDir,
  required String workingDirectory,
  required List<String> arguments,
  required String fromVersion,
  required String toVersion,
  required bool elevated,
  bool startApp = true,
  int moveAttempts = 40,
}) {
  String q(String s) => "'${_psQuote(s)}'";
  final args = arguments.isEmpty
      ? '@()'
      : '@(${arguments.map((a) => q(a.contains(' ') ? '"$a"' : a)).join(', ')})';
  return '''
# Written by the app's updater. Waits for the app to close, swaps the program
# files for the staged release, and starts it again. Safe to delete.
\$ErrorActionPreference = 'Stop'
\$appPid      = $processId
\$installDir  = ${q(installDir)}
\$exeName     = ${q(exeName)}
\$stagedDir   = ${q(stagedDir)}
\$workDir     = ${q(workDir)}
\$startIn     = ${q(workingDirectory)}
\$appArgs     = $args
\$fromVersion = ${q(fromVersion)}
\$toVersion   = ${q(toVersion)}
\$elevated    = \$${elevated ? 'true' : 'false'}
\$startApp    = \$${startApp ? 'true' : 'false'}

\$logFile    = Join-Path \$workDir 'apply_update.log'
\$resultFile = Join-Path \$workDir 'last_update.json'
\$backupDir  = Join-Path \$workDir 'backup'
\$exePath    = Join-Path \$installDir \$exeName

function Log(\$text) {
  Add-Content -LiteralPath \$logFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), \$text)
}
function Save-Result(\$ok, \$message) {
  @{ ok = \$ok; message = \$message; from = \$fromVersion; to = \$toVersion } |
    ConvertTo-Json | Set-Content -LiteralPath \$resultFile -Encoding UTF8
}
function Start-App {
  if (\$elevated) {
    # Explorer starts it as the signed-in user, not as administrator.
    Start-Process -FilePath explorer.exe -ArgumentList ('"' + \$exePath + '"')
  } elseif (\$appArgs.Count -gt 0) {
    Start-Process -FilePath \$exePath -WorkingDirectory \$startIn -ArgumentList \$appArgs
  } else {
    Start-Process -FilePath \$exePath -WorkingDirectory \$startIn
  }
}
function Test-ProgramFile(\$rel) {
  if (\$rel -match '^data\\\\') { return \$true }
  return (\$rel -notmatch '\\\\') -and (\$rel -match '\\.(exe|dll)\$')
}
function Invoke-WithRetry([scriptblock]\$action) {
  for (\$i = 1; ; \$i++) {
    try { & \$action; return } catch { if (\$i -ge $moveAttempts) { throw } ; Start-Sleep -Milliseconds 500 }
  }
}

Set-Content -LiteralPath (Join-Path \$workDir 'helper_started.txt') -Value \$appPid
Log "Updating \$exePath from \$fromVersion to \$toVersion"

try { Wait-Process -Id \$appPid -Timeout 120 -ErrorAction SilentlyContinue } catch { }

# Pop-out windows and other copies run the same exe and lock the same files.
\$deadline = (Get-Date).AddMinutes(3)
while (\$true) {
  \$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    try { \$_.Path -eq \$exePath } catch { \$false } })
  if (\$running.Count -eq 0) { break }
  if ((Get-Date) -gt \$deadline) {
    Log "Gave up: \$(\$running.Count) copies of the app are still open."
    Save-Result \$false "Other \$exeName windows were still open, so nothing was changed. Close every window of the app and update again."
    exit 1
  }
  Start-Sleep -Seconds 1
}

\$moved = New-Object System.Collections.Generic.List[string]
\$added = New-Object System.Collections.Generic.List[string]
try {
  if (Test-Path -LiteralPath \$backupDir) { Remove-Item -LiteralPath \$backupDir -Recurse -Force }
  New-Item -ItemType Directory -Path \$backupDir -Force | Out-Null
  \$root = (Get-Item -LiteralPath \$stagedDir).FullName.TrimEnd('\\')
  # The exe last, so a failure part-way never leaves a new exe with old files.
  \$files = @(Get-ChildItem -LiteralPath \$root -Recurse -File -Force |
    Sort-Object { \$_.Name -eq \$exeName })
  foreach (\$f in \$files) {
    \$rel = \$f.FullName.Substring(\$root.Length).TrimStart('\\')
    \$target = Join-Path \$installDir \$rel
    \$exists = Test-Path -LiteralPath \$target
    if (\$exists -and -not (Test-ProgramFile \$rel)) { continue }
    \$parent = Split-Path -Parent \$target
    if (-not (Test-Path -LiteralPath \$parent)) { New-Item -ItemType Directory -Path \$parent -Force | Out-Null }
    if (\$exists) {
      \$bak = Join-Path \$backupDir \$rel
      New-Item -ItemType Directory -Path (Split-Path -Parent \$bak) -Force | Out-Null
      Invoke-WithRetry { Move-Item -LiteralPath \$target -Destination \$bak -Force }
      \$moved.Add(\$rel)
    } else {
      \$added.Add(\$rel)
    }
    Invoke-WithRetry { Copy-Item -LiteralPath \$f.FullName -Destination \$target -Force }
  }
  Log "Replaced \$(\$moved.Count) files and added \$(\$added.Count)."
  Save-Result \$true ''
} catch {
  \$err = \$_.Exception.Message
  Log "Failed: \$err. Rolling back."
  foreach (\$rel in \$added) {
    Remove-Item -LiteralPath (Join-Path \$installDir \$rel) -Force -ErrorAction SilentlyContinue
  }
  foreach (\$rel in \$moved) {
    try {
      Copy-Item -LiteralPath (Join-Path \$backupDir \$rel) -Destination (Join-Path \$installDir \$rel) -Force
    } catch { Log "Could not restore \${rel}: \$(\$_.Exception.Message)" }
  }
  Save-Result \$false "\$err (Details: \$logFile)"
}

if (\$startApp) {
  try { Start-App; Log 'Started the app.' } catch { Log "Could not start the app: \$(\$_.Exception.Message)" }
}
''';
}
