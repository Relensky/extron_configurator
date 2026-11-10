// ============================================================================
//  CRASH EVIDENCE: why a session with no clean-exit marker ended.
// ============================================================================
//  The audit in app_logger.dart can only say the marker is missing. Two other
//  places know more, and this file reads both (same as the CTS Dashboard's
//  lib/debug/crash_evidence.dart):
//
//   1. The runner's own record (windows/runner/crash_log.cpp): a native
//      fault appends "The app crashed: exception ... in <module>" to
//      deployment_app_error_log.txt in the default log folder, next to a
//      crash_<time>.dmp. Read with the audit.
//
//   2. The Windows event log, which also catches what the runner cannot:
//      fail-fast aborts (0xc0000409, how out-of-memory ends), hangs Windows
//      gave up on, unexpected power-offs and low-memory warnings. wevtutil
//      is a separate process and runs only after an unclean exit, some
//      seconds after start, so it never touches start-up or the UI thread.
// ============================================================================
import 'dart:io';

import 'package:path/path.dart' as path;

class CrashEvidence {
  CrashEvidence._();

  /// What the native crash logger appends to (crash_log.cpp).
  static const String nativeLogName = 'deployment_app_error_log.txt';

  /// The first `pid N` in a session log's opening lines.
  static int? pidFromLogHead(String head) {
    final m = RegExp(r'pid (\d+)').firstMatch(head);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// Native crash entries in [dir]'s [nativeLogName] stamped at or after
  /// [since] (less a minute of slack), as log lines.
  static List<String> nativeNotes(Directory dir, DateTime since) {
    final DateTime cutoff = since.subtract(const Duration(minutes: 1));
    final File f = File(path.join(dir.path, nativeLogName));
    try {
      if (!f.existsSync() || f.lastModifiedSync().isBefore(cutoff)) {
        return const [];
      }
      final List<String> out = [];
      final entry = RegExp(r'^\[([^\]]+)\] ERROR: (The app crashed.*)$');
      for (final line in f.readAsLinesSync()) {
        final m = entry.firstMatch(line.trim());
        if (m == null) continue;
        final DateTime? at = DateTime.tryParse(m.group(1)!);
        if (at == null || at.isBefore(cutoff)) continue;
        out.add('Native crash record ($nativeLogName, ${m.group(1)}): '
            '${m.group(2)}');
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  // --------------------------------------------------------------------------
  // Windows event log
  // --------------------------------------------------------------------------

  static String _utc(DateTime t) =>
      '${t.toUtc().toIso8601String().split('.').first}.000Z';

  static String _timeFilter(DateTime from, DateTime to) =>
      "TimeCreated[@SystemTime>='${_utc(from)}' and "
      "@SystemTime<='${_utc(to)}']";

  /// What the event log holds about process [pid] of [exeName] between
  /// [from] and [to], plus system events in that span that would end any
  /// process (power loss, shutdown, low memory). Empty when there is
  /// nothing, or wevtutil is not there.
  static Future<List<String>> windowsEvents({
    required int pid,
    required String exeName,
    required DateTime from,
    required DateTime to,
  }) async {
    final String time = _timeFilter(from, to);
    final String appQuery = "*[System[Provider[@Name='Application Error' or "
        "@Name='Application Hang' or @Name='Windows Error Reporting'] and "
        '$time]]';
    // 41 power lost / reset, 6008 unexpected shutdown, 1074 shutdown or
    // restart someone started, 6006 clean shutdown, 7002 sign-out,
    // 2004 Windows ran low on memory.
    final String systemQuery = '*[System[(EventID=41 or EventID=6008 or '
        'EventID=1074 or EventID=6006 or EventID=7002 or EventID=2004) and '
        '$time]]';
    try {
      final results = await Future.wait([
        _query('Application', appQuery),
        _query('System', systemQuery),
      ]);
      return [
        ...parseApplicationEvents(results[0], pid, exeName),
        ...parseSystemEvents(results[1]),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<String> _query(String log, String xpath) async {
    final r = await Process.run(
      'wevtutil',
      ['qe', log, '/q:$xpath', '/f:RenderedXml', '/c:40'],
    ).timeout(const Duration(seconds: 20));
    return r.exitCode == 0 ? r.stdout as String : '';
  }

  static Iterable<String> _events(String xml) => RegExp(
        r'<Event[ >].*?</Event>',
        dotAll: true,
      ).allMatches(xml).map((m) => m.group(0)!);

  static String? _data(String event, String name) {
    final m = RegExp("<Data Name='$name'>(.*?)</Data>", dotAll: true)
        .firstMatch(event);
    return m == null ? null : _unescape(m.group(1)!.trim());
  }

  static String? _system(String event, String pattern) =>
      RegExp(pattern).firstMatch(event)?.group(1);

  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  static String _when(String event) {
    final st = _system(event, r"SystemTime='([^']+)'");
    final DateTime? t = st == null ? null : DateTime.tryParse(st);
    return t == null ? '?' : _local(t);
  }

  static String _local(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  static bool _samePid(String? field, int pid) {
    if (field == null) return false;
    final f = field.trim().toLowerCase();
    final int? v = f.startsWith('0x')
        ? int.tryParse(f.substring(2), radix: 16)
        : int.tryParse(f);
    return v == pid;
  }

  /// Meaning of the exception codes a crashed process shows up with.
  static String describeCode(String code) {
    final c = code.toLowerCase().replaceFirst('0x', '');
    switch (c) {
      case 'c0000005':
        return 'access violation';
      case 'c0000409':
        return 'fail-fast abort - how out-of-memory and failed internal '
            'checks end';
      case 'c00000fd':
        return 'stack overflow';
      case 'c0000374':
        return 'heap corruption';
      case 'c0000017':
        return 'out of memory';
      case '80000003':
        return 'breakpoint - usually a deliberate abort';
      case 'e06d7363':
        return 'unhandled C++ exception';
      case 'c000041d':
        return 'fault inside a window callback';
      case 'c0000006':
        return 'in-page error - a file or the page file could not be read';
      default:
        return 'see the exception code';
    }
  }

  static List<String> parseApplicationEvents(
    String xml,
    int pid,
    String exeName,
  ) {
    final String exe = exeName.toLowerCase();
    final List<String> out = [];
    for (final e in _events(xml)) {
      final String? provider = _system(e, r"Provider Name='([^']+)'");
      if (provider == 'Application Error') {
        if ((_data(e, 'AppName') ?? '').toLowerCase() != exe ||
            !_samePid(_data(e, 'ProcessId'), pid)) {
          continue;
        }
        final code = _data(e, 'ExceptionCode') ?? '?';
        final String offset = _data(e, 'FaultingOffset') ?? '?';
        out.add('Windows recorded a crash at ${_when(e)}: exception 0x$code '
            '(${describeCode(code)}) in ${_data(e, 'ModuleName') ?? '?'} '
            '${_data(e, 'ModuleVersion') ?? ''} at offset '
            '${offset.startsWith('0x') ? offset : '0x$offset'}. Module path: '
            '${_data(e, 'ModulePath') ?? '?'}');
      } else if (provider == 'Application Hang') {
        // Older builds leave the fields unnamed; the rendered message has
        // the name and pid either way.
        final String text = e.toLowerCase();
        if (!text.contains(exe)) continue;
        final String hex = pid.toRadixString(16);
        if (!text.contains('$pid') && !text.contains(hex)) continue;
        out.add('Windows recorded the app as not responding and closed it at '
            '${_when(e)} (Application Hang).');
      } else if (provider == 'Windows Error Reporting') {
        if ((_data(e, 'P1') ?? '').toLowerCase() != exe) continue;
        final String store =
            (_data(e, 'StorePath') ?? '').replaceFirst(r'\\?\', '');
        out.add('Windows Error Reporting at ${_when(e)}: '
            '${_data(e, 'EventName') ?? '?'}'
            '${store.isEmpty || store == 'NULL' ? '' : ', report kept in $store'}');
      }
    }
    return out;
  }

  static List<String> parseSystemEvents(String xml) {
    final List<String> out = [];
    for (final e in _events(xml)) {
      final id = _system(e, r'<EventID[^>]*>(\d+)</EventID>');
      final message = RegExp(r'<Message>(.*?)</Message>', dotAll: true)
          .firstMatch(e)
          ?.group(1);
      String text = message == null
          ? ''
          : _unescape(message).replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.length > 300) text = '${text.substring(0, 300)}...';
      final String what = switch (id) {
        '41' => 'the PC lost power or was reset without shutting down',
        '6008' => 'the previous shutdown was unexpected',
        '1074' => 'a shutdown or restart was started',
        '6006' => 'Windows shut down',
        '7002' => 'a user signed out',
        '2004' => 'Windows was low on memory',
        _ => 'system event $id',
      };
      out.add('System at ${_when(e)}: $what'
          '${text.isEmpty ? '' : ' - $text'}');
    }
    return out;
  }
}
