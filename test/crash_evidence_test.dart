import 'dart:io';

import 'package:extron_configurator/crash_evidence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads the pid from a session header', () {
    expect(
      CrashEvidence.pidFromLogHead('[t] [ACTION] --- Application Started '
          '--- (version 0.5.182, pid 38884)'),
      38884,
    );
    expect(CrashEvidence.pidFromLogHead('no header'), isNull);
  });

  test('picks this process out of Application Error events', () {
    const xml = "<Event xmlns='x'><System><Provider Name='Application Error'/>"
        "<EventID>1000</EventID><TimeCreated SystemTime='2026-11-03T19:34:51.1Z'/>"
        "</System><EventData><Data Name='AppName'>extron_configurator.exe</Data>"
        "<Data Name='ModuleName'>flutter_windows.dll</Data>"
        "<Data Name='ModuleVersion'>1.0.0.0</Data>"
        "<Data Name='ExceptionCode'>c0000005</Data>"
        "<Data Name='FaultingOffset'>0x00000000001a2b3c</Data>"
        "<Data Name='ProcessId'>0x97e4</Data>"
        "<Data Name='ModulePath'>C:\\x\\flutter_windows.dll</Data>"
        '</EventData></Event>'
        "<Event xmlns='x'><System><Provider Name='Application Error'/>"
        "</System><EventData><Data Name='AppName'>extron_configurator.exe</Data>"
        "<Data Name='ProcessId'>0x1</Data></EventData></Event>";
    final lines = CrashEvidence.parseApplicationEvents(
        xml, 0x97e4, 'extron_configurator.exe');
    expect(lines, hasLength(1));
    expect(lines.single, contains('flutter_windows.dll'));
    expect(lines.single, contains('access violation'));
  });

  test('names the system events that end every process', () {
    const xml = "<Event xmlns='x'><System><Provider Name='Kernel-Power'/>"
        "<EventID>41</EventID><TimeCreated SystemTime='2026-11-03T19:40:00Z'/>"
        '</System><RenderingInfo><Message>The system has rebooted '
        'without cleanly shutting down first.</Message></RenderingInfo>'
        '</Event>';
    final lines = CrashEvidence.parseSystemEvents(xml);
    expect(lines.single, contains('lost power'));
    expect(lines.single, contains('rebooted'));
  });

  test('copies recent native crash records only', () {
    final dir = Directory.systemTemp.createTempSync('crash_evidence');
    addTearDown(() => dir.deleteSync(recursive: true));
    final now = DateTime.now();
    String stamp(DateTime t) => t.toIso8601String().split('.').first;
    File('${dir.path}/${CrashEvidence.nativeLogName}').writeAsStringSync(
      '[${stamp(now.subtract(const Duration(days: 2)))}] ERROR: The app '
      'crashed: old one\n'
      '--------------------------------------------------\n'
      '[${stamp(now)}] ERROR: The app crashed: exception 0xC0000005 in '
      'pdfium.dll. Crash dump: crash_1.dmp\n'
      '--------------------------------------------------\n'
      '[${stamp(now)}] ERROR: The previous session did not close normally.\n',
    );

    final lines = CrashEvidence.nativeNotes(
        dir, now.subtract(const Duration(hours: 1)));
    expect(lines, hasLength(1));
    expect(lines.single, contains('pdfium.dll'));

    expect(
      CrashEvidence.nativeNotes(dir, now.add(const Duration(hours: 1))),
      isEmpty,
    );
  });
}
