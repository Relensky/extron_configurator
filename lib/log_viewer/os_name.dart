// ============================================================================
// THE WINDOWS NAME, AS PEOPLE KNOW IT
//
// Dart's Platform.operatingSystemVersion reads the registry's ProductName,
// which Microsoft never changed for Windows 11: a Windows 11 Enterprise 25H2
// machine reports '"Windows 10 Enterprise" 10.0 (Build 26200)'. A log that
// says Windows 10 sends whoever reads it down the wrong road, so the name is
// corrected from the build number (Windows 11 starts at build 22000) and the
// release people actually quote (25H2) is added from DisplayVersion.
//
// Pure, so it can be tested without a registry. log_viewer_io.dart feeds it
// the real values; every app's logger calls describeOperatingSystem() from
// there. Part of lib/log_viewer/, shared unchanged by the five CTS apps.
// ============================================================================

/// The first build of Windows 11. Windows 10's last is 19045.
const int kFirstWindows11Build = 22000;

/// Describes Windows from Dart's [raw] `Platform.operatingSystemVersion` and
/// the values under `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion`:
/// "Windows 11 Enterprise 25H2 (build 26200.6899)".
///
/// [registry] may be empty, or missing any value: whatever is known is used,
/// and the build number alone is still enough to get 10 and 11 right.
String describeWindows(String raw, Map<String, String> registry) {
  final String? productName = registry['ProductName'];
  String name = productName ??
      RegExp(r'"([^"]+)"').firstMatch(raw)?.group(1) ??
      'Windows';

  final int? build = int.tryParse(registry['CurrentBuildNumber'] ??
      registry['CurrentBuild'] ??
      RegExp(r'Build (\d+)').firstMatch(raw)?.group(1) ??
      '');
  if (build != null && build >= kFirstWindows11Build) {
    name = name.replaceFirst('Windows 10', 'Windows 11');
  }

  // 25H2 since 20H2; ReleaseId (2009, 2004...) on anything older.
  final String? release = _nonEmpty(registry['DisplayVersion']) ??
      _nonEmpty(registry['ReleaseId']);

  final int? revision = _parseRegInt(registry['UBR']);
  final String buildText = build == null
      ? ''
      : ' (build $build${revision == null ? '' : '.$revision'})';

  return '$name${release == null ? '' : ' $release'}$buildText';
}

/// The values from `reg query` output, which lists one per line as
/// `    Name    REG_TYPE    data`.
Map<String, String> parseRegQuery(String output) {
  final Map<String, String> values = {};
  final RegExp line = RegExp(r'^\s+(\S+)\s+REG_\w+\s+(.*)$');
  for (final l in output.split(RegExp(r'\r?\n'))) {
    final RegExpMatch? m = line.firstMatch(l);
    if (m != null) values[m.group(1)!] = m.group(2)!.trim();
  }
  return values;
}

String? _nonEmpty(String? s) => s == null || s.trim().isEmpty ? null : s.trim();

/// A REG_DWORD as `reg query` prints it (0x1ae3), or a plain number.
int? _parseRegInt(String? s) {
  if (s == null) return null;
  final String t = s.trim().toLowerCase();
  return t.startsWith('0x') ? int.tryParse(t.substring(2), radix: 16) : int.tryParse(t);
}
