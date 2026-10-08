import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'team_host.dart';
import 'team_presence.dart';

// ============================================================================
// [TEAM KIT - WORKING ON]: who is working on what - a ticket in the
// dashboard, a room in the Room Config Builder - so the team can see it at a
// glance, in every app. Anyone can tag themselves, or tag someone else, and
// any number of people can be on one thing.
//
//     <team folder>/claims/<login>@<machine>[@<app>].jsonl
//
// The chat's rule: each copy appends to its OWN file and reads everyone
// else's, so no two PCs ever write one file. A line is one change:
//
//     {"at": ..., "kind": "ticket", "id": "12345", "label": "#12345 ...",
//      "who": "jsmith", "whoName": "Jane Smith", "on": true,
//      "by": "dstanley", "byName": "Derek", "app": "dashboard"}
//
// For each (kind, id, who) the newest line from ANY file wins - so tagging
// someone and taking them off again can be done by different people, and a
// later line always says how things stand.
// ============================================================================

const Duration kClaimsPoll = Duration(seconds: 10);

/// One person on one thing.
class TeamClaim {
  /// 'ticket', 'room', ... - what sort of thing.
  final String kind;

  /// The thing's id within its kind: a ticket number, a room name.
  final String id;

  /// How to name it in words ('Ticket #12345 - Projector out').
  final String label;

  /// The login on it, and their name.
  final String who;
  final String whoName;

  /// Who tagged them (themselves, most often), and when.
  final String by;
  final String byName;
  final DateTime at;

  /// True: on it. False: taken off.
  final bool on;

  /// The app the change was made in.
  final String app;

  const TeamClaim({
    required this.kind,
    required this.id,
    required this.label,
    required this.who,
    required this.whoName,
    required this.by,
    required this.byName,
    required this.at,
    required this.on,
    this.app = '',
  });

  String get whoLabel => whoName.trim().isEmpty ? who : whoName.trim();
  String get byLabel => byName.trim().isEmpty ? by : byName.trim();
  bool get self => by.toLowerCase() == who.toLowerCase();

  String get key => '${kind.toLowerCase()}|${id.toLowerCase()}|'
      '${who.toLowerCase()}';

  Map<String, dynamic> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'kind': kind,
        'id': id,
        if (label.isNotEmpty) 'label': label,
        'who': who,
        if (whoName.isNotEmpty) 'whoName': whoName,
        'on': on,
        'by': by,
        if (byName.isNotEmpty) 'byName': byName,
        if (app.isNotEmpty) 'app': app,
      };

  static TeamClaim? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = DateTime.tryParse(json['at']?.toString() ?? '');
    final kind = json['kind']?.toString() ?? '';
    final id = json['id']?.toString() ?? '';
    final who = json['who']?.toString() ?? '';
    if (at == null || kind.isEmpty || id.isEmpty || who.isEmpty) return null;
    return TeamClaim(
      kind: kind,
      id: id,
      label: json['label']?.toString() ?? '',
      who: who,
      whoName: json['whoName']?.toString() ?? '',
      by: json['by']?.toString() ?? who,
      byName: json['byName']?.toString() ?? '',
      at: at.toLocal(),
      on: json['on'] != false,
      app: json['app']?.toString() ?? '',
    );
  }
}

/// Everyone's "working on" tags, kept current from the team folder.
class TeamClaims extends ChangeNotifier {
  TeamClaims({TeamIdentity? identity, String Function()? myName, bool? watch})
      : me = identity ?? TeamIdentity.current(),
        myName = myName ?? (() => ''),
        watch = watch ?? !Platform.environment.containsKey('FLUTTER_TEST');

  final TeamIdentity me;
  String Function() myName;
  final bool watch;

  String _folder = '';
  Timer? _timer;
  StreamSubscription<FileSystemEvent>? _watcher;
  Timer? _settle;
  bool _reading = false;

  /// Newest line per (kind, id, who).
  final Map<String, TeamClaim> _latest = {};

  /// Called for each change that arrives from someone else and puts THIS
  /// person on something - the app shows a notice.
  void Function(TeamClaim claim)? onTaggedByOthers;
  final Set<String> _announced = {};
  bool _firstRead = true;

  String get folder => _folder;
  bool get active => _folder.isNotEmpty;

  static String get _sep => Platform.pathSeparator;

  /// Joins [teamFolder] ('' leaves). Cheap when it has not moved.
  Future<void> attach(String teamFolder) async {
    final folder =
        teamFolder.trim().isEmpty ? '' : '${teamFolder.trim()}${_sep}claims';
    if (folder == _folder) return;
    _timer?.cancel();
    await _watcher?.cancel();
    _watcher = null;
    _folder = folder;
    _latest.clear();
    _firstRead = true;
    if (folder.isEmpty) {
      notifyListeners();
      return;
    }
    try {
      await Directory(folder).create(recursive: true);
    } catch (_) {}
    await refresh();
    _timer = Timer.periodic(kClaimsPoll, (_) => refresh());
    if (watch) {
      try {
        _watcher = Directory(folder).watch().listen((_) {
          _settle?.cancel();
          _settle = Timer(const Duration(milliseconds: 400), refresh);
        });
      } catch (_) {}
    }
  }

  /// Reads every file again. Never throws.
  Future<void> refresh() async {
    if (_folder.isEmpty || _reading) return;
    _reading = true;
    try {
      final next = <String, TeamClaim>{};
      final dir = Directory(_folder);
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          if (f is! File || !f.path.endsWith('.jsonl')) continue;
          List<String> lines;
          try {
            lines = await f.readAsLines();
          } catch (_) {
            continue;
          }
          for (final line in lines) {
            if (line.trim().isEmpty) continue;
            TeamClaim? c;
            try {
              c = TeamClaim.fromJson(jsonDecode(line));
            } catch (_) {}
            if (c == null) continue;
            final had = next[c.key];
            if (had == null || c.at.isAfter(had.at)) next[c.key] = c;
          }
        }
      }
      _notice(next);
      final changed = !mapEquals(
          {for (final e in _latest.entries) e.key: e.value.toJson().toString()},
          {for (final e in next.entries) e.key: e.value.toJson().toString()});
      _latest
        ..clear()
        ..addAll(next);
      if (changed) notifyListeners();
    } catch (_) {
    } finally {
      _reading = false;
    }
  }

  /// Tells [onTaggedByOthers] about tags on this person made elsewhere since
  /// the last look (not on the first read: those are old news).
  void _notice(Map<String, TeamClaim> next) {
    final mine = me.user.toLowerCase();
    for (final c in next.values) {
      if (!c.on || c.who.toLowerCase() != mine) continue;
      if (c.by.toLowerCase() == mine) continue;
      final id = '${c.key}|${c.at.microsecondsSinceEpoch}';
      if (_announced.add(id) && !_firstRead) onTaggedByOthers?.call(c);
    }
    _firstRead = false;
  }

  /// Who is on [kind] [id] now, oldest first.
  List<TeamClaim> on(String kind, String id) {
    final k = '${kind.toLowerCase()}|${id.toLowerCase()}|';
    return [
      for (final c in _latest.values)
        if (c.on && c.key.startsWith(k)) c,
    ]..sort((a, b) => a.at.compareTo(b.at));
  }

  /// Everything of [kind] someone is on, by id.
  Map<String, List<TeamClaim>> allOf(String kind) {
    final out = <String, List<TeamClaim>>{};
    for (final c in _latest.values) {
      if (!c.on || c.kind.toLowerCase() != kind.toLowerCase()) continue;
      out.putIfAbsent(c.id, () => []).add(c);
    }
    return out;
  }

  /// What [login] (this person, by default) is on.
  List<TeamClaim> forPerson([String? login]) {
    final who = (login ?? me.user).toLowerCase();
    return [
      for (final c in _latest.values)
        if (c.on && c.who.toLowerCase() == who) c,
    ]..sort((a, b) => b.at.compareTo(a.at));
  }

  bool isOn(String kind, String id, String login) =>
      on(kind, id).any((c) => c.who.toLowerCase() == login.toLowerCase());

  /// Puts [who] on (or, [on] false, takes them off) [kind] [id]. Returns what
  /// went wrong, or ''.
  Future<String> set({
    required String kind,
    required String id,
    required String label,
    required String who,
    String whoName = '',
    required bool on,
  }) async {
    if (_folder.isEmpty) return 'The team folder cannot be reached.';
    final c = TeamClaim(
      kind: kind,
      id: id,
      label: label,
      who: who,
      whoName: whoName,
      by: me.user,
      byName: myName(),
      at: DateTime.now(),
      on: on,
      app: TeamHost.appId,
    );
    try {
      final file = File('$_folder$_sep${me.fileStem}.jsonl');
      await file.writeAsString('${jsonEncode(c.toJson())}\n',
          mode: FileMode.append, flush: true);
    } catch (e) {
      return 'The tag could not be saved to the team folder: $e';
    }
    final had = _latest[c.key];
    if (had == null || c.at.isAfter(had.at)) _latest[c.key] = c;
    notifyListeners();
    return '';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _settle?.cancel();
    _watcher?.cancel();
    super.dispose();
  }
}
