// The log viewer's file work, for builds with a filesystem. See
// log_viewer_types.dart. Nothing here throws: a log viewer that crashes is no
// help to somebody who opened it because something else already had.
import 'dart:convert';
import 'dart:io';

import 'log_viewer_types.dart';
import 'os_name.dart';

export 'os_name.dart';

const bool logViewerSupported = true;

/// Every log file the [sources] name, newest first, at most [limit] of them.
/// [currentPath] marks the file this session is writing.
List<LogFileInfo> listLogFiles(
  List<LogSource> sources, {
  String? currentPath,
  int limit = 40,
}) {
  final String? current =
      currentPath == null ? null : _key(File(currentPath).absolute.path);
  final Map<String, LogFileInfo> found = {};

  void add(File f, String label) {
    try {
      if (!f.existsSync()) return;
      final String path = f.absolute.path;
      final String key = _key(path);
      if (found.containsKey(key)) return;
      final FileStat stat = f.statSync();
      found[key] = LogFileInfo(
        path: path,
        name: _nameOf(path),
        label: label,
        modified: stat.modified,
        bytes: stat.size,
        isCurrent: key == current,
      );
    } catch (_) {
      // Unreadable: leave it out rather than fail the whole list.
    }
  }

  for (final source in sources) {
    final String? file = source.file;
    if (file != null && file.trim().isNotEmpty) {
      add(File(file), source.label);
      continue;
    }
    final String? folder = source.folder;
    if (folder == null || folder.trim().isEmpty) continue;
    try {
      final Directory dir = Directory(folder);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final String name = _nameOf(entity.path);
        if (source.include != null && !source.include!(name)) continue;
        add(entity, source.label);
      }
    } catch (_) {
      // A folder that cannot be listed just contributes nothing.
    }
  }

  final List<LogFileInfo> files = found.values.toList()
    ..sort((a, b) {
      // The file being written first, then newest first.
      if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
      return b.modified.compareTo(a.modified);
    });
  return files.length > limit ? files.sublist(0, limit) : files;
}

/// Reads [path] as text. With [maxBytes], only the end of a bigger file is
/// read, starting on a whole line — the end is where the answer usually is.
LogText readLogText(String path, {int? maxBytes}) {
  try {
    final File file = File(path);
    final int length = file.lengthSync();
    final bool truncated = maxBytes != null && length > maxBytes;
    final int start = truncated ? length - maxBytes : 0;
    final RandomAccessFile raf = file.openSync();
    String text;
    try {
      raf.setPositionSync(start);
      // allowMalformed: a log another process is writing, or a window that
      // lands mid-character, must still read.
      text = utf8.decode(raf.readSync(length - start), allowMalformed: true);
    } finally {
      raf.closeSync();
    }
    if (truncated) {
      final int firstBreak = text.indexOf('\n');
      if (firstBreak >= 0) text = text.substring(firstBreak + 1);
    }
    return LogText(text: text, totalBytes: length, truncated: truncated);
  } catch (e) {
    return LogText(text: '', totalBytes: 0, error: '$e');
  }
}

/// A line naming the machine and person, for the top of a copied or exported
/// log: the first thing anybody reading it asks is "from where?".
String machineSummary() {
  String host = 'unknown';
  try {
    host = Platform.localHostname;
  } catch (_) {}
  final String user = Platform.environment['USERNAME'] ??
      Platform.environment['USER'] ??
      'unknown';
  return 'Computer: $host · User: $user · ${describeOperatingSystem()}';
}

String? _osDescription;

/// The operating system as people know it: "Windows 11 Enterprise 25H2
/// (build 26200.6899)", not the "Windows 10 Enterprise" Dart reports for every
/// Windows 11 machine. See os_name.dart. Read once and kept: the registry is
/// asked with one short `reg query`, and the answer does not change while the
/// app runs.
String describeOperatingSystem() => _osDescription ??= _describeOs();

String _describeOs() {
  final String raw = Platform.operatingSystemVersion;
  if (!Platform.isWindows) return '${Platform.operatingSystem} $raw';
  Map<String, String> registry = const {};
  try {
    final ProcessResult r = Process.runSync('reg', [
      'query',
      r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion',
    ]);
    if (r.exitCode == 0) registry = parseRegQuery('${r.stdout}');
  } catch (_) {
    // No reg.exe, or not allowed to run it: the build number still decides
    // between 10 and 11.
  }
  return describeWindows(raw, registry);
}

/// Writes [text] to [path]. Returns why it failed, or null.
String? writeLogExport(String path, String text) {
  try {
    final File file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text, flush: true);
    return null;
  } catch (e) {
    return '$e';
  }
}

/// Where an export goes when the app has no Save dialog to ask with: the
/// Downloads folder, else the Desktop, else the temp folder.
String defaultExportFolder() {
  final String? home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home != null) {
    for (final name in ['Downloads', 'Desktop']) {
      final String candidate = '$home${Platform.pathSeparator}$name';
      if (Directory(candidate).existsSync()) return candidate;
    }
  }
  return Directory.systemTemp.path;
}

/// [fileName] inside [folder].
String exportPathIn(String folder, String fileName) =>
    '$folder${Platform.pathSeparator}$fileName';

/// Opens the file manager with [path] selected (or its folder, if it is gone).
Future<void> revealInFileManager(String path) async {
  try {
    final File file = File(path);
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [
        file.existsSync() ? '/select,${file.absolute.path}' : file.parent.path,
      ]);
    } else if (Platform.isMacOS) {
      await Process.start('open', ['-R', path]);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [file.parent.path]);
    }
  } catch (_) {
    // The path is on screen beside the button; nothing else to fall back to.
  }
}

String _nameOf(String path) => path.split(RegExp(r'[/\\]')).last;

/// Paths compared the way Windows does: case and separators do not matter.
String _key(String path) => path.replaceAll('\\', '/').toLowerCase();
