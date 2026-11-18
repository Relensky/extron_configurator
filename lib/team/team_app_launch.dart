import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'team_host.dart';
import 'team_widgets.dart' show TeamAppStyle;
import 'team_win32.dart';
import '../services/platform_support.dart';

// ============================================================================
// [TEAM KIT - APPS]: the other CTS programs, opened from this one.
//
// The CTS Dashboard, the Room Config Builder and Instructor Contact stay
// programs of their own (each installed by its own setup, updated by its own
// updater). TeamAppLaunch finds the installed copy under Program Files,
// starts it - or brings it to the front when it is already open - and can
// hand it a REQUEST: something to do once it is up.
//
//   teamOpenInApp(context, 'dashboard', action: 'openRoom',
//       args: {'room': 'BSS 110'});
//
// A request travels one of two ways:
//
//   * the program is not running: it is started with
//         <exe> [TeamHost.launchArgs] --request <base64 JSON>
//     and reads it at start-up (TeamAppLaunch.listen(startupArgs: args));
//   * it is running: the request is written - whole, through a temporary
//     file - to %LOCALAPPDATA%\cts_app_requests\<appId>.json, which every
//     running copy looks for four times a second (TeamAppLaunch.listen) and takes
//     once. A copy too old to look is given a few seconds, then a new copy
//     is started with the request on its command line instead.
//
// Either way the app's TeamHost.onAppRequest gets (action, args):
//
//   dashboard     openRoom {room}            the room in the Room Hub
//   configurator  openProject {file, room}   the project file (and room)
//   instructor    notifyRoom {room}          a room-issue message for it
//
// Where each program is can be picked by hand (Browse...) when it is not in
// Program Files; the path is kept in the kit's settings
// (TeamHost.writeSetting 'teamApp.<id>.exe').
// ============================================================================

/// Where an app's setup installs it: the folder under Program Files and the
/// program's file name.
class TeamAppInstall {
  const TeamAppInstall(this.folder, this.exe);
  final String folder;
  final String exe;
}

/// Every CTS app by its team app id (kTeamApps).
const Map<String, TeamAppInstall> kTeamAppInstalls = {
  'dashboard': TeamAppInstall('CTS Dashboard', 'cts_dashboard.exe'),
  'configurator':
      TeamAppInstall('Room Config Builder', 'room_config_builder.exe'),
  'instructor': TeamAppInstall(
      'Instructor Contact System', 'instructor_contact_system.exe'),
};

/// How long a request waits to be taken before it no longer counts - an app
/// started much later must not act on an old click.
const Duration kTeamRequestLife = Duration(seconds: 60);

/// [TEAM KIT - APP REQUESTS]: something one CTS app asks another to do.
class TeamAppRequest {
  const TeamAppRequest({
    required this.action,
    this.args = const {},
    required this.id,
    required this.at,
    this.from = '',
  });

  /// A new request from this app.
  factory TeamAppRequest.create(String action,
          [Map<String, String> args = const {}]) =>
      TeamAppRequest(
        action: action,
        args: Map.unmodifiable(args),
        id: '${TeamHost.appId}-$pid-${DateTime.now().microsecondsSinceEpoch}',
        at: DateTime.now(),
        from: TeamHost.appId,
      );

  /// 'openRoom', 'openProject', 'notifyRoom'...
  final String action;
  final Map<String, String> args;

  /// Unique, so the sender can tell its own request was taken.
  final String id;
  final DateTime at;

  /// The app that asked.
  final String from;

  /// The command-line switch a request travels behind.
  static const String flag = '--request';

  bool get stale => DateTime.now().difference(at).abs() > kTeamRequestLife;

  Map<String, dynamic> toJson() => {
        'action': action,
        'args': args,
        'id': id,
        'at': at.toUtc().toIso8601String(),
        if (from.isNotEmpty) 'from': from,
      };

  static TeamAppRequest? fromJson(Object? json) {
    if (json is! Map) return null;
    final action = json['action']?.toString() ?? '';
    final at = DateTime.tryParse(json['at']?.toString() ?? '');
    if (action.isEmpty || at == null) return null;
    final args = json['args'];
    return TeamAppRequest(
      action: action,
      args: {
        if (args is Map)
          for (final e in args.entries)
            if (e.value != null) '${e.key}': '${e.value}',
      },
      id: json['id']?.toString() ?? '',
      at: at.toLocal(),
      from: json['from']?.toString() ?? '',
    );
  }

  /// The JSON, base64 - quotes and backslashes in paths survive the Windows
  /// command line untouched.
  String encode() => base64Encode(utf8.encode(jsonEncode(toJson())));

  static TeamAppRequest? decode(String text) {
    try {
      return fromJson(jsonDecode(utf8.decode(base64Decode(text.trim()))));
    } catch (_) {
      return null;
    }
  }

  /// `--request <base64>`, to start a program with.
  List<String> get commandLine => [flag, encode()];

  /// The request a program was started with ([commandLine]), or null.
  static TeamAppRequest? fromArgs(List<String> args) {
    final i = args.indexOf(flag);
    if (i < 0 || i + 1 >= args.length) return null;
    return decode(args[i + 1]);
  }

  @override
  String toString() => '$action $args';
}

/// [TEAM KIT - APP REQUESTS]: asks the app [appId] to do [action] - started
/// or brought to the front, and handed the request (see the top of this
/// file). [action] '' only opens it. This app's own id runs the request here
/// (TeamHost.onAppRequest). Returns whether it was started or reached.
Future<bool> teamOpenInApp(
  BuildContext? context,
  String appId, {
  String action = '',
  Map<String, String> args = const {},
}) async {
  if (appId == TeamHost.appId) {
    if (action.isNotEmpty) {
      TeamAppLaunch.handle(TeamAppRequest.create(action, args));
    }
    return true;
  }
  return TeamAppLaunch.open(context, appId,
      request: action.isEmpty ? null : TeamAppRequest.create(action, args));
}

class TeamAppLaunch {
  TeamAppLaunch._();

  /// Tests: replaces starting / reaching another program - gets the app id
  /// and the request (null: only open it).
  static Future<bool> Function(String appId, TeamAppRequest? request)?
      debugOpen;

  /// Tests: where the hand-off files go instead of %LOCALAPPDATA%.
  static String? folderOverride;

  static String get _sep => Platform.pathSeparator;

  /// The per-user folder of hand-off files.
  static String get requestFolder {
    final override = folderOverride;
    if (override != null) return override;
    final local = Platform.environment['LOCALAPPDATA'];
    final base = (local == null || local.isEmpty)
        ? Directory.systemTemp.path
        : local;
    return '$base${_sep}cts_app_requests';
  }

  static File requestFile(String appId) =>
      File('$requestFolder$_sep$appId.json');

  // --- handing a request to a running copy --------------------------------

  /// Writes [request] for the running [appId] to take - whole, through a
  /// temporary file, so it is never read half-written.
  static Future<bool> deliver(String appId, TeamAppRequest request) async {
    try {
      final file = requestFile(appId);
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.$pid.saving');
      await temp.writeAsString(jsonEncode(request.toJson()), flush: true);
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
      return true;
    } catch (e) {
      TeamHost.log('[TEAM] could not hand $request to $appId: $e');
      return false;
    }
  }

  /// Waits up to [wait] for [appId] to take the request [id]; true when it
  /// did. One still waiting at the end is taken back.
  static Future<bool> delivered(String appId, String id,
      {Duration wait = const Duration(seconds: 6)}) async {
    final file = requestFile(appId);
    final until = DateTime.now().add(wait);
    while (DateTime.now().isBefore(until)) {
      if (!await _waiting(file, id)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!await _waiting(file, id)) return true;
    try {
      await file.delete();
    } catch (_) {}
    return false;
  }

  static Future<bool> _waiting(File file, String id) async {
    try {
      if (!await file.exists()) return false;
      final r = TeamAppRequest.fromJson(jsonDecode(await file.readAsString()));
      return r?.id == id;
    } catch (_) {
      return false;
    }
  }

  /// Takes the request waiting for [appId] (this app by default), if any and
  /// not stale - read once: the file goes.
  static TeamAppRequest? take([String? appId]) {
    final file = requestFile(appId ?? TeamHost.appId);
    try {
      if (!file.existsSync()) return null;
      final text = file.readAsStringSync();
      file.deleteSync();
      final r = TeamAppRequest.fromJson(jsonDecode(text));
      if (r == null || r.stale) return null;
      return r;
    } catch (_) {
      return null;
    }
  }

  // --- this app taking requests -------------------------------------------

  static Timer? _poll;

  /// Runs [request] here: TeamHost.onAppRequest.
  static void handle(TeamAppRequest request) {
    TeamHost.log('[TEAM] request from ${teamAppName(request.from)}: '
        '$request');
    final on = TeamHost.onAppRequest;
    if (on == null) return;
    try {
      on(request.action, request.args);
    } catch (e) {
      TeamHost.log('[TEAM] request $request failed: $e');
    }
  }

  /// Takes requests from the other apps: the one this copy was started with
  /// ([startupArgs], `--request`), then - while it runs - any written for it,
  /// looked for every 250 ms (not under tests). Set TeamHost.onAppRequest
  /// first.
  static void listen({List<String> startupArgs = const []}) {
    final first = TeamAppRequest.fromArgs(startupArgs);
    if (first != null) handle(first);
    if (_poll != null || Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    // One waiting already (asked while this copy was starting) is taken on
    // the first tick; take() drops any too old to count.
    // Four times a second: a request is acted on as the window comes forward
    // rather than up to a second later. The check is one exists() on a
    // local file.
    _poll = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final r = take();
      if (r != null) handle(r);
    });
  }

  static void stopListening() {
    _poll?.cancel();
    _poll = null;
  }

  // --- finding, starting and focusing a program ----------------------------

  static String _settingKey(String appId) => 'teamApp.$appId.exe';

  /// The installed program for [appId], or null when it cannot be found.
  static String? find(String appId) {
    final install = kTeamAppInstalls[appId];
    if (install == null) return null;
    final picked = TeamHost.readSetting(_settingKey(appId));
    if (picked is String && picked.isNotEmpty && File(picked).existsSync()) {
      return picked;
    }
    final env = Platform.environment;
    final roots = <String?>[
      env['ProgramFiles'],
      env['ProgramW6432'],
      env['ProgramFiles(x86)'],
      if (env['LOCALAPPDATA'] != null) '${env['LOCALAPPDATA']}\\Programs',
    ];
    for (final root in roots) {
      if (root == null || root.isEmpty) continue;
      final path = '$root\\${install.folder}\\${install.exe}';
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// Process ids of running copies of [exe], this process left out.
  static Future<List<int>> runningPids(String exe) async {
    // Straight from Windows (a few ms); tasklist (~350 ms) only when that
    // cannot answer.
    final fast = TeamWin32.pidsOf(exe);
    if (fast != null) return [for (final id in fast) if (id != pid) id];
    try {
      final r = await Process.run('tasklist', [
        '/FI',
        'IMAGENAME eq $exe',
        '/FO',
        'CSV',
        '/NH',
      ]);
      final pids = <int>[];
      for (final line in const LineSplitter().convert('${r.stdout}')) {
        final cells = line.split('","');
        if (cells.length < 2) continue;
        final id = int.tryParse(cells[1].replaceAll('"', ''));
        if (id != null && id != pid) pids.add(id);
      }
      return pids;
    } catch (_) {
      return const [];
    }
  }

  /// Brings the running copy [processId]'s window to the front.
  static Future<void> focus(int processId) async {
    // Straight through Windows; starting PowerShell for AppActivate took
    // ~800 ms and is only the fallback now.
    if (TeamWin32.focusProcess(processId)) return;
    try {
      await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '\$s = New-Object -ComObject WScript.Shell; '
            '[void]\$s.AppActivate($processId)',
      ]);
    } catch (_) {}
  }

  /// Opens [appId]: to the front when it is running (handed [request]),
  /// else started (with TeamHost.launchArgs and [request]). Asks where it is
  /// when it cannot be found. Returns whether it was started or reached.
  static Future<bool> open(BuildContext? context, String appId,
      {TeamAppRequest? request}) async {
    final test = debugOpen;
    if (test != null) return test(appId, request);
    final install = kTeamAppInstalls[appId];
    final name = teamAppName(appId);
    if (install == null) {
      TeamHost.log('[TEAM] no program known for $appId');
      return false;
    }
    final running = await runningPids(install.exe);
    if (running.isNotEmpty) {
      if (request == null) {
        TeamHost.log('[TEAM] $name already open (pid ${running.first}) - '
            'brought to the front');
        await focus(running.first);
        return true;
      }
      if (await deliver(appId, request)) {
        await focus(running.first);
        if (await delivered(appId, request.id)) {
          TeamHost.log('[TEAM] $name (pid ${running.first}) took $request');
          return true;
        }
      }
      // Too old to look for requests: a copy of its own takes it.
      TeamHost.log('[TEAM] $name did not take $request - starting a copy '
          'with it');
    }
    var path = find(appId);
    if (path == null) {
      if (context == null || !context.mounted) {
        TeamHost.log('[TEAM] $name is not installed here');
        return false;
      }
      path = await _askWhere(context, appId, name, install.exe);
      if (path == null) return false;
    }
    final extra = await TeamHost.launchArgs?.call(appId) ?? const <String>[];
    try {
      await Process.start(
        path,
        [...extra, ...?request?.commandLine],
        workingDirectory: File(path).parent.path,
        mode: ProcessStartMode.detached,
      );
      TeamHost.log('[TEAM] started $name: $path'
          '${request == null ? '' : ' for $request'}');
      return true;
    } catch (e) {
      TeamHost.log('[TEAM] could not start $name ($path): $e');
      if (context != null && context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Could not start $name: $e')),
        );
      }
      return false;
    }
  }

  static Future<String?> _askWhere(
      BuildContext context, String appId, String name, String exe) async {
    final browse = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        title: Text('$name is not installed here'),
        content: Text(
          'It was not found in Program Files. Install it from the CTS '
          'releases folder, or point to $exe if it is somewhere else.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Browse...'),
          ),
        ],
      ),
    );
    if (browse != true) return null;
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Where is $exe?',
      type: FileType.custom,
      allowedExtensions: const ['exe'],
    );
    final path = picked?.path;
    if (path == null || path.isEmpty) return null;
    await TeamHost.writeSetting(_settingKey(appId), path);
    return path;
  }
}

/// [TEAM KIT - APPS]: a button for each OTHER CTS app - its icon and name in
/// its colour - that starts it or brings it to the front. On the team page.
class TeamAppLinks extends StatelessWidget {
  const TeamAppLinks({super.key});

  @override
  Widget build(BuildContext context) {
    // [iOS STREAMLINED]: the other CTS apps are Windows programs.
    if (!kCanRunProcesses) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Wrap(
      key: const ValueKey('team_app_links'),
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Open', style: theme.textTheme.labelMedium),
        for (final app in TeamAppStyle.order)
          if (app != TeamHost.appId && kTeamAppInstalls.containsKey(app))
            Builder(builder: (context) {
              final colour = TeamAppStyle.color(app, theme.brightness);
              return Tooltip(
                message: 'Start ${teamAppName(app)}, or bring it to the '
                    'front when it is open',
                child: OutlinedButton.icon(
                  key: ValueKey('team_app_link_$app'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colour,
                    side: BorderSide(color: colour.withValues(alpha: 0.6)),
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: Icon(TeamAppStyle.icon(app), size: 16),
                  label: Text(teamAppName(app)),
                  onPressed: () => teamOpenInApp(
                      Navigator.maybeOf(context, rootNavigator: true)
                              ?.context ??
                          context,
                      app),
                ),
              );
            }),
      ],
    );
  }
}
