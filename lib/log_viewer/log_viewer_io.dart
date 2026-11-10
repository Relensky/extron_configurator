// The log viewer's file work, for builds with a filesystem. See
// log_viewer_types.dart. Nothing here throws: a log viewer that crashes is no
// help to somebody who opened it because something else already had.
import 'dart:convert';
import 'dart:ffi';
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
/// Windows 11 machine. See os_name.dart. Read once and kept: the answer does
/// not change while the app runs.
///
/// The values come straight from the registry API. This used to run
/// `reg query` with Process.runSync, and every logger asks for it while
/// writing its session header - before the first frame. Starting reg.exe
/// and waiting for it was ~0.45 s on a fast PC and seconds on a slow one;
/// RegGetValueW takes microseconds. `reg query` is still the fallback.
String describeOperatingSystem() => _osDescription ??= _describeOs();

const List<String> _kCurrentVersionValues = [
  'ProductName',
  'CurrentBuildNumber',
  'CurrentBuild',
  'DisplayVersion',
  'ReleaseId',
  'UBR',
];

String _describeOs() {
  if (!Platform.isWindows) {
    return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
  }
  Map<String, String> registry = const {};
  try {
    registry = _readCurrentVersion();
  } catch (_) {
    // No usable advapi32 (should not happen on Windows): fall back below.
  }
  // Dart's own answer only when the registry gave nothing: on Windows it
  // takes ~0.25 s the first time, and the registry holds all it would add.
  if (registry.containsKey('ProductName') &&
      registry.containsKey('CurrentBuildNumber')) {
    return describeWindows('', registry);
  }
  final String raw = Platform.operatingSystemVersion;
  if (registry.isEmpty) {
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
  }
  return describeWindows(raw, registry);
}

typedef _RegGetValueNative = Int32 Function(
    IntPtr key,
    Pointer<Uint16> subKey,
    Pointer<Uint16> value,
    Uint32 flags,
    Pointer<Uint32> type,
    Pointer<Uint8> data,
    Pointer<Uint32> size);
typedef _RegGetValueDart = int Function(int key, Pointer<Uint16> subKey,
    Pointer<Uint16> value, int flags, Pointer<Uint32> type,
    Pointer<Uint8> data, Pointer<Uint32> size);
typedef _GetProcessHeapNative = IntPtr Function();
typedef _GetProcessHeapDart = int Function();
typedef _HeapAllocNative = Pointer<Uint8> Function(
    IntPtr heap, Uint32 flags, IntPtr bytes);
typedef _HeapAllocDart = Pointer<Uint8> Function(
    int heap, int flags, int bytes);
typedef _HeapFreeNative = Int32 Function(
    IntPtr heap, Uint32 flags, Pointer<Uint8> block);
typedef _HeapFreeDart = int Function(int heap, int flags, Pointer<Uint8> block);

/// The values of [_kCurrentVersionValues] that exist, in the form
/// `reg query` prints them (a DWORD as 0x1ae3), for [describeWindows].
/// Plain dart:ffi with the process heap, so no app needs package:ffi.
Map<String, String> _readCurrentVersion() {
  final advapi = DynamicLibrary.open('advapi32.dll');
  final kernel = DynamicLibrary.open('kernel32.dll');
  final regGetValue =
      advapi.lookupFunction<_RegGetValueNative, _RegGetValueDart>(
          'RegGetValueW');
  final int heap = kernel
      .lookupFunction<_GetProcessHeapNative, _GetProcessHeapDart>(
          'GetProcessHeap')();
  final heapAlloc =
      kernel.lookupFunction<_HeapAllocNative, _HeapAllocDart>('HeapAlloc');
  final heapFree =
      kernel.lookupFunction<_HeapFreeNative, _HeapFreeDart>('HeapFree');

  // HKEY_LOCAL_MACHINE is ((HKEY)(LONG)0x80000002): sign-extended to 64 bits.
  const int hkeyLocalMachine = 0x80000002 - 0x100000000;
  const int rrfRtRegSz = 0x00000002;
  const int rrfRtRegDword = 0x00000010;
  const int regDword = 4;
  const int dataBytes = 1024;
  const String subKey = r'SOFTWARE\Microsoft\Windows NT\CurrentVersion';

  // One block: sub-key name, value name, type, size, then the data.
  const int nameBytes = 256;
  final Pointer<Uint8> block = heapAlloc(
      heap, 0x00000008 /* HEAP_ZERO_MEMORY */, nameBytes * 2 + 8 + dataBytes);
  if (block.address == 0) return const {};
  try {
    final Pointer<Uint16> subKeyText = block.cast<Uint16>();
    final Pointer<Uint16> valueText = (block + nameBytes).cast<Uint16>();
    final Pointer<Uint32> type = (block + nameBytes * 2).cast<Uint32>();
    final Pointer<Uint32> size = (block + nameBytes * 2 + 4).cast<Uint32>();
    final Pointer<Uint8> data = block + nameBytes * 2 + 8;

    void put(Pointer<Uint16> at, String s) {
      final units = s.codeUnits;
      for (int i = 0; i < units.length; i++) {
        at[i] = units[i];
      }
      at[units.length] = 0;
    }

    put(subKeyText, subKey);
    final Map<String, String> values = {};
    for (final String name in _kCurrentVersionValues) {
      put(valueText, name);
      size.value = dataBytes;
      final int status = regGetValue(hkeyLocalMachine, subKeyText, valueText,
          rrfRtRegSz | rrfRtRegDword, type, data, size);
      if (status != 0) continue;
      if (type.value == regDword) {
        values[name] = '0x${data.cast<Uint32>().value.toRadixString(16)}';
      } else {
        final Pointer<Uint16> text = data.cast<Uint16>();
        final int length = size.value ~/ 2;
        final units = <int>[];
        for (int i = 0; i < length && text[i] != 0; i++) {
          units.add(text[i]);
        }
        values[name] = String.fromCharCodes(units);
      }
    }
    return values;
  } finally {
    heapFree(heap, 0, block);
  }
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

/// Where the export Save dialog starts: the user's Desktop, where Windows
/// says it is (OneDrive can move it), else [defaultExportFolder].
String desktopFolder() {
  if (Platform.isWindows) {
    try {
      final r = Process.runSync('reg', [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',
        '/v',
        'Desktop',
      ]);
      final m = RegExp(r'Desktop\s+REG_\w+\s+(.+)')
          .firstMatch(r.stdout.toString());
      if (m != null) {
        final String dir = m.group(1)!.trim().replaceAllMapped(
            RegExp('%([^%]+)%'),
            (v) => Platform.environment[v.group(1)!] ?? v.group(0)!);
        if (Directory(dir).existsSync()) return dir;
      }
    } catch (_) {}
  }
  final String? home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home != null) {
    final String candidate = '$home${Platform.pathSeparator}Desktop';
    if (Directory(candidate).existsSync()) return candidate;
  }
  return defaultExportFolder();
}

/// [fileName] inside [folder].
String exportPathIn(String folder, String fileName) =>
    '$folder${Platform.pathSeparator}$fileName';

/// Opens the file manager with [path] selected (or its folder, if it is gone).
Future<void> revealInFileManager(String path) async {
  try {
    final File file = File(path);
    if (Platform.isWindows) {
      // A folder opens as itself; a file opens its folder with it selected.
      await Process.start('explorer.exe', [
        Directory(path).existsSync()
            ? Directory(path).absolute.path
            : file.existsSync()
                ? '/select,${file.absolute.path}'
                : file.parent.path,
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
