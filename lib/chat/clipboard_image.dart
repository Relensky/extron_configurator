import 'dart:io';

import 'package:path/path.dart' as path;

/// ============================================================================
///  A SCREENSHOT ON THE CLIPBOARD
/// ============================================================================
///  Flutter's clipboard only carries text. Windows' own clipboard holds the
///  picture a Print Screen or Win+Shift+S puts there, so this asks Windows
///  for it through PowerShell and saves it as a PNG for the chat to send. A
///  copied picture FILE is handed back as that file.
/// ============================================================================

/// The script: the clipboard's picture saved to the path in `$args[0]`, or a
/// copied image file's path printed; nothing printed when there is neither.
const String _script = r'''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if ([Windows.Forms.Clipboard]::ContainsImage()) {
  $img = [Windows.Forms.Clipboard]::GetImage()
  $img.Save($args[0], [Drawing.Imaging.ImageFormat]::Png)
  Write-Output $args[0]
} elseif ([Windows.Forms.Clipboard]::ContainsFileDropList()) {
  foreach ($f in [Windows.Forms.Clipboard]::GetFileDropList()) {
    if ($f -match '\.(png|jpe?g|gif|bmp|webp)$') { Write-Output $f; break }
  }
}
''';

/// The picture on the clipboard as a file, or null when there is none. Never
/// throws; always null off Windows.
Future<String?> clipboardImageFile() async {
  if (!Platform.isWindows) return null;
  try {
    final dir = await Directory.systemTemp.createTemp('chat_paste_');
    final target = path.join(
      dir.path,
      'screenshot-${DateTime.now().millisecondsSinceEpoch}.png',
    );
    final script = File(path.join(dir.path, 'paste.ps1'));
    await script.writeAsString(_script);
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-STA',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      target,
    ]).timeout(const Duration(seconds: 10));
    final out = '${result.stdout}'.trim();
    if (out.isEmpty || !File(out).existsSync()) return null;
    return out;
  } catch (_) {
    return null;
  }
}
