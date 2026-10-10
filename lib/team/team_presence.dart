import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_activity.dart';

import 'team_host.dart';

// ============================================================================
// [TEAM - WHO IS ON WHAT]: who else has the dashboard open, which room they
// are looking at, and what they are editing.
//
// The team folder is a file share with no server to ask, so each dashboard
// says so itself, the same way the configurator's presence does: one small
// file per person that it rewrites every [kPresenceHeartbeat], which every
// other dashboard reads.
//
//     <team folder>/presence/<login>@<machine>.json
//
// One file per person, never a shared one, because two PCs writing one file
// on an SMB share is the race this avoids. A dashboard that crashed stops
// rewriting its file, and after [kPresenceStaleAfter] nobody shows it.
//
// Only the main window writes one: room and tab windows are the same person
// on the same PC, and say where they are through the main window's own
// presence (they would otherwise fight over the one file).
// ============================================================================

const Duration kPresenceHeartbeat = Duration(seconds: 15);
const Duration kPresenceStaleAfter = Duration(seconds: 75);

/// Who this copy of the app is: the Windows sign-in name and the machine.
class TeamIdentity {
  final String user;
  final String machine;

  const TeamIdentity({required this.user, required this.machine});

  factory TeamIdentity.current() {
    final env = Platform.environment;
    String pick(List<String> keys, String fallback) {
      for (final k in keys) {
        final v = env[k]?.trim() ?? '';
        if (v.isNotEmpty) return v;
      }
      return fallback;
    }

    String host;
    try {
      host = Platform.localHostname;
    } catch (_) {
      host = '';
    }
    return TeamIdentity(
      user: pick(const ['USERNAME', 'USER', 'LOGNAME'], 'unknown'),
      machine: pick(const ['COMPUTERNAME', 'HOSTNAME'],
          host.isEmpty ? 'pc' : host),
    );
  }

  /// The name of this copy's files in the team folder. The dashboard's are
  /// `<login>@<machine>`, as they always were; another app adds its id
  /// (`<login>@<machine>@configurator`), so the same person in two apps on
  /// one PC never writes one file from two programs.
  String get fileStem {
    final base = '${safeName(user)}@${safeName(machine)}';
    final app = TeamHost.appId;
    return app.isEmpty || app == 'dashboard' ? base : '$base@${safeName(app)}';
  }

  static String safeName(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  bool same(String otherUser, String otherMachine) =>
      otherUser.toLowerCase() == user.toLowerCase() &&
      otherMachine.toLowerCase() == machine.toLowerCase();
}

/// One thing someone has open to change: a room's settings, the vault...
class TeamEdit {
  /// What is being edited, the same for everyone: 'room:ARTS 209',
  /// 'vault', 'ipdirectory'.
  final String key;

  /// In words: 'ARTS 209 (room settings)'.
  final String label;
  final DateTime since;

  const TeamEdit({required this.key, required this.label, required this.since});

  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        'since': since.toUtc().toIso8601String(),
      };

  static TeamEdit? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = json['key']?.toString() ?? '';
    if (key.isEmpty) return null;
    return TeamEdit(
      key: key,
      label: json['label']?.toString() ?? key,
      since: DateTime.tryParse(json['since']?.toString() ?? '')?.toLocal() ??
          DateTime.now(),
    );
  }
}

/// One person's "I am here" note.
class TeamPresence {
  final String user;
  final String machine;

  /// The GVE login they signed in to the dashboard with, when they did.
  final String gveUser;
  final String version;

  /// When they started the dashboard, and when it last said it was there.
  final DateTime since;
  final DateTime heartbeat;

  /// The tab on screen, and the room the Room Hub shows ('' for none).
  final String tab;
  final String room;
  final List<TeamEdit> editing;

  /// [TEAM KIT]: the app this note is from ('' = the dashboard, before the
  /// kit), and that app in words.
  final String app;
  String get appName => teamAppName(app);

  const TeamPresence({
    required this.user,
    required this.machine,
    this.gveUser = '',
    this.version = '',
    required this.since,
    required this.heartbeat,
    this.tab = '',
    this.room = '',
    this.editing = const [],
    this.app = '',
  });

  /// 'jsmith' or 'jsmith (GVE: john.smith)'.
  String get label => gveUser.isEmpty || gveUser.toLowerCase() == user.toLowerCase()
      ? user
      : '$user ($gveUser)';

  /// 'ARTS 209, on Room Hub · CTS Dashboard'.
  String get whereText {
    final where = [
      if (room.isNotEmpty) room,
      if (tab.isNotEmpty) 'on $tab',
    ].join(', ');
    return where.isEmpty ? 'in $appName' : '$where · $appName';
  }

  bool isStale(DateTime now) => now.difference(heartbeat) > kPresenceStaleAfter;

  Map<String, dynamic> toJson() => {
        'user': user,
        'machine': machine,
        if (gveUser.isNotEmpty) 'gveUser': gveUser,
        if (version.isNotEmpty) 'version': version,
        'since': since.toUtc().toIso8601String(),
        'heartbeat': heartbeat.toUtc().toIso8601String(),
        if (tab.isNotEmpty) 'tab': tab,
        if (room.isNotEmpty) 'room': room,
        if (editing.isNotEmpty) 'editing': [for (final e in editing) e.toJson()],
        if (app.isNotEmpty) 'app': app,
      };

  static TeamPresence? fromJson(Object? json) {
    if (json is! Map) return null;
    DateTime? time(String k) =>
        DateTime.tryParse(json[k]?.toString() ?? '')?.toLocal();
    final user = json['user']?.toString() ?? '';
    final heartbeat = time('heartbeat');
    if (user.isEmpty || heartbeat == null) return null;
    return TeamPresence(
      user: user,
      machine: json['machine']?.toString() ?? '',
      gveUser: json['gveUser']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      since: time('since') ?? heartbeat,
      heartbeat: heartbeat,
      tab: json['tab']?.toString() ?? '',
      room: json['room']?.toString() ?? '',
      app: json['app']?.toString() ?? '',
      editing: [
        for (final e in (json['editing'] as List? ?? const []))
          if (TeamEdit.fromJson(e) case final edit?) edit,
      ],
    );
  }
}

/// Keeps this dashboard's note current and reads everyone else's.
class TeamPresenceBoard extends ChangeNotifier {
  TeamPresenceBoard({
    TeamIdentity? identity,
    required this.version,
    this.gveUser,
    this.readOnly = false,
    bool? watch,
  })  : me = identity ?? TeamIdentity.current(),
        watch = watch ?? !Platform.environment.containsKey('FLUTTER_TEST');

  final TeamIdentity me;
  final String version;

  /// Only reads the others, writing no note of its own: the chat's pop-out
  /// window, whose person already has one from the dashboard.
  final bool readOnly;

  /// Watches the folder, so a colleague moving to another room shows within
  /// a moment rather than on the next heartbeat. Off in tests.
  final bool watch;
  StreamSubscription<FileSystemEvent>? _watcher;
  Timer? _settle;

  /// The dashboard's GVE login, read on each heartbeat.
  final String Function()? gveUser;

  String _folder = '';
  Timer? _timer;
  final DateTime _since = DateTime.now();
  String _tab = '';
  String _room = '';
  final Map<String, TeamEdit> _editing = {};
  List<TeamPresence> _others = const [];
  bool _busy = false;

  /// The presence folder, '' while off.
  String get folder => _folder;
  bool get active => _folder.isNotEmpty;

  /// Everyone else with the dashboard open now.
  List<TeamPresence> get others => _others;

  /// [TEAM KIT]: this person's notes from the OTHER CTS apps on this PC -
  /// the same person, so never in [others], but where else they are.
  List<TeamPresence> get mineElsewhere => _mineElsewhere;
  List<TeamPresence> _mineElsewhere = const [];

  /// This app's own note, as the others read it.
  TeamPresence get mineHere => _mine;

  String get tab => _tab;
  String get room => _room;
  List<TeamEdit> get myEdits => _editing.values.toList();

  /// Starts (or moves) to [teamFolder]'s presence folder; '' stops.
  Future<void> attach(String teamFolder) async {
    final f = teamFolder.isEmpty
        ? ''
        : '$teamFolder${Platform.pathSeparator}presence';
    if (f == _folder) return;
    if (_folder.isNotEmpty) await _withdraw();
    _folder = f;
    _others = const [];
    _timer?.cancel();
    _timer = null;
    _stopWatching();
    if (f.isNotEmpty) {
      // Away: the heartbeat goes on, but nobody is reading the others.
      _timer = Timer.periodic(
          kPresenceHeartbeat, (_) => beat(readOthers: !AppActivity.away));
      await beat();
      _startWatching();
    }
    notifyListeners();
  }

  /// [TEAM]: re-reads the notes whenever one changes on the share. A share
  /// that cannot be watched keeps the heartbeat's 15 s reading; one whose
  /// watch drops is watched again on the next beat.
  void _startWatching() {
    if (!watch || _watcher != null || _folder.isEmpty) return;
    try {
      final dir = Directory(_folder);
      if (!dir.existsSync()) return;
      _watcher = dir.watch().listen((e) {
        if (!e.path.toLowerCase().endsWith('.json')) return;
        // A burst of events (write, rename) is one change.
        _settle?.cancel();
        _settle = Timer(const Duration(milliseconds: 300), () {
          unawaited(_readOthers());
        });
      }, onError: (_) => _stopWatching(), onDone: _stopWatching,
          cancelOnError: true);
    } catch (_) {
      _watcher = null;
    }
  }

  void _stopWatching() {
    _settle?.cancel();
    _settle = null;
    final w = _watcher;
    _watcher = null;
    if (w != null) unawaited(w.cancel());
  }

  /// Where this person is now. Written at once, not on the next beat, so
  /// others see a room change while it still matters.
  void setWhere({String? tab, String? room}) {
    final t = tab ?? _tab;
    final r = room ?? _room;
    if (t == _tab && r == _room) return;
    _tab = t;
    _room = r;
    unawaited(beat(readOthers: false));
  }

  /// Says this person has [key] open to change. Pair with [endEditing].
  void beginEditing(String key, String label) {
    _editing[key] = TeamEdit(key: key, label: label, since: DateTime.now());
    unawaited(beat(readOthers: false));
    notifyListeners();
  }

  void endEditing(String key) {
    if (_editing.remove(key) == null) return;
    unawaited(beat(readOthers: false));
    notifyListeners();
  }

  /// Others with [room] on screen.
  List<TeamPresence> viewingRoom(String room) {
    final r = room.trim().toLowerCase();
    if (r.isEmpty) return const [];
    return [
      for (final p in _others)
        if (p.room.trim().toLowerCase() == r) p
    ];
  }

  /// Others editing [key] right now.
  List<TeamPresence> editingKey(String key) => [
        for (final p in _others)
          if (p.editing.any((e) => e.key == key)) p
      ];

  String get _file =>
      '$_folder${Platform.pathSeparator}${me.fileStem}.json';

  TeamPresence get _mine => TeamPresence(
        user: me.user,
        machine: me.machine,
        gveUser: gveUser?.call() ?? '',
        version: version,
        since: _since,
        heartbeat: DateTime.now(),
        tab: _tab,
        room: _room,
        editing: _editing.values.toList(),
        app: TeamHost.appId,
      );

  /// Writes this note and (normally) reads the others. Never throws: a
  /// read-only share must not stop anybody working.
  Future<void> beat({bool readOthers = true}) async {
    if (_folder.isEmpty) return;
    if (!readOnly) {
      try {
        await Directory(_folder).create(recursive: true);
        final tmp = File('$_file.$pid.tmp');
        await tmp.writeAsString(jsonEncode(_mine.toJson()), flush: true);
        await tmp.rename(_file);
      } catch (_) {}
    }
    if (!readOthers) return;
    _startWatching();
    await _readOthers();
  }

  /// Reads everyone else's note; tells the screens when anything changed.
  Future<void> _readOthers() async {
    if (_folder.isEmpty || _busy) return;
    _busy = true;
    try {
      final now = DateTime.now();
      final found = <TeamPresence>[];
      final elsewhere = <TeamPresence>[];
      final dir = Directory(_folder);
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is! File || !entity.path.endsWith('.json')) continue;
          TeamPresence? p;
          try {
            p = TeamPresence.fromJson(jsonDecode(await entity.readAsString()));
          } catch (_) {
            continue; // half-written by its owner; next time round
          }
          if (p == null) continue;
          final mine = me.same(p.user, p.machine);
          if (mine && _sameApp(p.app, TeamHost.appId)) continue;
          if (p.isStale(now)) {
            if (now.difference(p.heartbeat) > const Duration(hours: 12)) {
              try {
                await entity.delete();
              } catch (_) {}
            }
            continue;
          }
          (mine ? elsewhere : found).add(p);
        }
      }
      found.sort((a, b) => a.user.toLowerCase().compareTo(b.user.toLowerCase()));
      final changed = !_samePeople(found, _others) ||
          !_samePeople(elsewhere, _mineElsewhere);
      if (changed) {
        _others = found;
        _mineElsewhere = elsewhere;
        notifyListeners();
      }
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  /// '' is the dashboard: notes from before the kit carry no app.
  static bool _sameApp(String a, String b) =>
      (a.isEmpty ? 'dashboard' : a) == (b.isEmpty ? 'dashboard' : b);

  static bool _samePeople(List<TeamPresence> a, List<TeamPresence> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (jsonEncode({...a[i].toJson(), 'heartbeat': ''}) !=
          jsonEncode({...b[i].toJson(), 'heartbeat': ''})) {
        return false;
      }
    }
    return true;
  }

  Future<void> _withdraw() async {
    if (readOnly) return;
    try {
      final f = File(_file);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Takes this note down (the app is closing).
  Future<void> withdraw() async {
    _timer?.cancel();
    _timer = null;
    _stopWatching();
    await _withdraw();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stopWatching();
    super.dispose();
  }
}
