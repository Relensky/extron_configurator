import 'dart:io';

// The settings kit's own small values - the log time zone, for apps that do
// not keep it themselves - one file each in %LOCALAPPDATA%\<exe name>\settings,
// beside the updater's %LOCALAPPDATA%\<exe name>\updates.

Directory get _folder {
  final String local = Platform.environment['LOCALAPPDATA'] ?? '';
  final String base = local.isNotEmpty ? local : Directory.systemTemp.path;
  final String exe = Platform.resolvedExecutable
      .split(RegExp(r'[/\\]'))
      .last;
  final int dot = exe.lastIndexOf('.');
  final String name = dot > 0 ? exe.substring(0, dot) : exe;
  return Directory('$base${Platform.pathSeparator}$name'
      '${Platform.pathSeparator}settings');
}

File _file(String name) =>
    File('${_folder.path}${Platform.pathSeparator}$name.txt');

/// The value saved under [name], or null when there is none.
String? readKitValue(String name) {
  try {
    final File f = _file(name);
    if (!f.existsSync()) return null;
    final String v = f.readAsStringSync().trim();
    return v.isEmpty ? null : v;
  } catch (_) {
    return null;
  }
}

void writeKitValue(String name, String value) {
  try {
    final File f = _file(name);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(value);
  } catch (_) {
    // A setting that does not stick is not worth stopping anything for.
  }
}

/// Whether [path] is there. Asked in the background with a time limit: a
/// share that routes but never answers takes about 40 seconds to say so.
Future<bool> kitPathExists(String path, {bool folder = false}) async {
  final String p = path.trim();
  if (p.isEmpty) return false;
  try {
    final Future<bool> asked =
        folder ? Directory(p).exists() : FileSystemEntity.type(p).then(
            (t) => t != FileSystemEntityType.notFound);
    return await asked.timeout(const Duration(seconds: 6),
        onTimeout: () => false);
  } catch (_) {
    return false;
  }
}
