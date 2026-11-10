import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

// ============================================================================
// [TEAM KIT]: lib/team/ is one folder kept byte-identical in every CTS app
// that takes part - CTS Dashboard (extron_debugger), Room Config Builder
// (extron_configurator) and Instructor Contact (instructor_contact_flutter) -
// the same way lib/updater/ is. Change it in one repo, copy the whole folder
// to the others, and run each one's tests.
//
// Everything the kit needs from the app it runs in comes through here, set
// once at start-up by that app's own adapter (lib/team_setup.dart or similar,
// never inside this folder):
//
//   appId / appName     which app wrote a message, a presence note or a tag
//   readSetting /       where the chat remembers its mode, sizes and the
//   writeSetting        panel's place (useSettingsFile gives a JSON file)
//   log                 a line in the app's own log
//   openLink            how a link in the chat opens (the app's in-app
//                       browser); null opens the system browser
//   openClaim /         opens what a "working on" tag is on (a room in
//   canOpenClaim        the Room Hub, a ticket, a project); null leaves
//                       the tags as plain text
//   launchArgs          extra command-line arguments when this app starts
//                       another CTS app (the dashboard hands Instructor
//                       Contact its profile and data files) - see
//                       team_app_launch.dart
//   onAppRequest        what another CTS app asks this one to do (open a
//                       room, a project, a room-issue message)
//   reservedEdges       room taken at the window's top/bottom by something
//                       docked there (the dashboard's browser), which a
//                       slid-out or docked chat keeps clear of
//
// THE TEAM FOLDER - one folder on the share that every app points at, so
// the people, the chat and the "working on" tags are the same whichever app
// someone has open:
//
//     <team folder>/presence/   who is on what (team_presence.dart)
//     <team folder>/chat/       the chat (team_chat.dart)
//     <team folder>/claims/     who is working on what (team_claims.dart)
//
// Each app chooses its folder in its own settings; see kDefaultTeamFolder.
// ============================================================================

/// The shared team folder every app uses unless its settings say otherwise:
/// the dashboard's, beside the shared processors.json.
const String kDefaultTeamFolder =
    r'\\doit-files\ATEC\CTS\StaffFiles\Classroom Technology\Dashboard\team';

/// Where everyone's avatar picture is kept (`<login>.png` / `.jpg`): the
/// Room Config Builder's shared `assets\avatars`, which every app reads and
/// writes, so a picture set in one shows in all of them.
const String kDefaultAvatarsFolder =
    r'\\doit-files\ATEC\CTS\StaffFiles\Classroom Technology\Projects'
    r'\Configurator_Files\assets\avatars';

/// Which apps write to the team folder, for labels: app id -> name.
const Map<String, String> kTeamApps = {
  'dashboard': 'CTS Dashboard',
  'configurator': 'Room Config Builder',
  'instructor': 'Instructor Contact',
};

/// The app id in words, the id itself for one this kit does not know.
String teamAppName(String appId) =>
    kTeamApps[appId] ?? (appId.isEmpty ? 'CTS Dashboard' : appId);

class TeamHost {
  TeamHost._();

  /// 'dashboard', 'configurator' or 'instructor'.
  static String appId = 'dashboard';

  static String get appName => teamAppName(appId);

  static Object? Function(String key) readSetting = _memoryRead;
  static Future<void> Function(String key, Object value) writeSetting =
      _memoryWrite;

  static void Function(String message) log = _noLog;

  /// Opens a link from the chat. Null: the system browser.
  static Future<void> Function(String url)? openLink;

  /// [TEAM KIT - WORKING ON]: opens what a tag is on - [kind] 'room' a room
  /// (the dashboard's Room Hub), 'ticket' a ticket, anything else whatever
  /// the app makes of it. Null: tags are plain text, not links.
  static void Function(String kind, String id, String label)? openClaim;

  /// Which kinds [openClaim] can open; null: every kind.
  static bool Function(String kind)? canOpenClaim;

  /// [TEAM KIT - APPS]: extra arguments for starting the app [appId] from
  /// this one (TeamAppLaunch.open) - the dashboard hands Instructor Contact
  /// its profile, look and data files. Null or empty: none.
  static Future<List<String>> Function(String appId)? launchArgs;

  /// [TEAM KIT - APP REQUESTS]: what another CTS app asked this one to do
  /// (teamOpenInApp) - 'openRoom' {room} in the dashboard, 'openProject'
  /// {file, room} in the Room Config Builder, 'notifyRoom' {room} in
  /// Instructor Contact. Called for a request handed to this running copy
  /// and for one this copy was started with (`--request`, see
  /// TeamAppRequest.fromArgs). Null: requests are ignored.
  static void Function(String action, Map<String, String> args)? onAppRequest;

  /// Window edges something else has docked to.
  static ValueListenable<EdgeInsets> reservedEdges =
      ValueNotifier(EdgeInsets.zero);

  static void _noLog(String _) {}

  // --- settings: in memory until an app gives a home for them --------------

  static final Map<String, Object> _memory = {};
  static Object? _memoryRead(String key) => _memory[key];
  static Future<void> _memoryWrite(String key, Object value) async {
    _memory[key] = value;
  }

  /// Keeps the kit's settings in a JSON file of its own at [path] - for an
  /// app with no settings store of its own to lend. Written whole, through a
  /// temporary file, each time a setting changes.
  static void useSettingsFile(String path) {
    final file = File(path);
    try {
      if (file.existsSync()) {
        final data = jsonDecode(file.readAsStringSync());
        if (data is Map) {
          data.forEach((k, v) {
            if (v != null) _memory['$k'] = v as Object;
          });
        }
      }
    } catch (_) {}
    readSetting = _memoryRead;
    writeSetting = (key, value) async {
      _memory[key] = value;
      try {
        await file.parent.create(recursive: true);
        final temp = File('$path.saving');
        await temp.writeAsString(
            const JsonEncoder.withIndent('  ').convert(_memory),
            flush: true);
        await temp.rename(path);
      } catch (e) {
        log('[TEAM] settings not saved to $path: $e');
      }
    };
  }
}

/// [TEAM KIT - OPTIONAL]: whether this app joins the team folder at all -
/// chat, who is online and the working-on tags. Off for a copy used on its
/// own, away from the file share; each app's startTeam checks it, and with it
/// off the team buttons are not shown (Team.presence / Team.chat stay null).
bool get teamFeaturesOn => TeamHost.readSetting('teamEnabled') != false;

Future<void> setTeamFeaturesOn(bool on) =>
    TeamHost.writeSetting('teamEnabled', on);

/// Opens [url] the host's way (its in-app browser), else the system's.
Future<void> teamOpenLink(String url) async {
  final open = TeamHost.openLink;
  if (open != null) return open(url);
  try {
    await launchUrl(Uri.parse(url));
  } catch (e) {
    TeamHost.log('[TEAM] could not open $url: $e');
  }
}
