import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

/// ============================================================================
///  WHO ELSE HAS THIS FILE OPEN
/// ============================================================================
///  A shared folder has no server to ask, so each copy of the app says so
///  itself: while a document is open it keeps a small "I am editing this" file
///  beside it, one per person, and touches it every few seconds. Everybody
///  else's copy reads the folder and shows the names it finds.
///
///      <folder>/.editing/<document file name>/<user>@<machine>.json
///
///  One file per person rather than one shared file, because two machines
///  writing one file on an SMB share or a synced folder is exactly the race
///  this whole feature exists to avoid. A copy of the app that crashed stops
///  touching its file, and after [kPresenceStaleAfter] nobody shows it.
/// ============================================================================

/// How often an open document's presence file is refreshed.
const kPresenceHeartbeat = Duration(seconds: 15);

/// A presence file older than this belongs to a copy of the app that is gone.
const kPresenceStaleAfter = Duration(seconds: 75);

/// The folder beside a document that holds its presence files.
const kPresenceFolderName = '.editing';

/// Who this copy of the app is: the Windows sign-in name, and the machine.
class CollabIdentity {
  final String user;
  final String machine;

  const CollabIdentity({required this.user, required this.machine});

  /// Read off the environment. `USERNAME` is the Windows sign-in; `USER` is
  /// the same thing on macOS and Linux.
  factory CollabIdentity.current() {
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
    return CollabIdentity(
      user: pick(const ['USERNAME', 'USER', 'LOGNAME'], 'unknown'),
      machine: pick(const ['COMPUTERNAME', 'HOSTNAME'], host.isEmpty ? 'pc' : host),
    );
  }

  /// The file name this identity's presence is written under.
  String get fileStem => '${_safe(user)}@${_safe(machine)}';

  static String _safe(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  @override
  bool operator ==(Object other) =>
      other is CollabIdentity &&
      other.user.toLowerCase() == user.toLowerCase() &&
      other.machine.toLowerCase() == machine.toLowerCase();

  @override
  int get hashCode => Object.hash(user.toLowerCase(), machine.toLowerCase());
}

/// One person's "I have this open" note.
class EditorPresence {
  final String user;
  final String machine;

  /// When they opened the document.
  final DateTime since;

  /// When their app last said it was still there.
  final DateTime heartbeat;

  /// Whether their copy has changes they have not saved yet.
  final bool unsaved;

  /// When they last saved this document, if they have this session.
  final DateTime? savedAt;

  const EditorPresence({
    required this.user,
    required this.machine,
    required this.since,
    required this.heartbeat,
    this.unsaved = false,
    this.savedAt,
  });

  CollabIdentity get identity => CollabIdentity(user: user, machine: machine);

  bool isStale(DateTime now) => now.difference(heartbeat) > kPresenceStaleAfter;

  Map<String, dynamic> toJson() => {
        'user': user,
        'machine': machine,
        'since': since.toUtc().toIso8601String(),
        'heartbeat': heartbeat.toUtc().toIso8601String(),
        'unsaved': unsaved,
        if (savedAt != null) 'savedAt': savedAt!.toUtc().toIso8601String(),
      };

  static EditorPresence? fromJson(Object? json) {
    if (json is! Map) return null;
    DateTime? time(String k) =>
        DateTime.tryParse(json[k]?.toString() ?? '')?.toLocal();
    final user = json['user']?.toString() ?? '';
    final heartbeat = time('heartbeat');
    if (user.isEmpty || heartbeat == null) return null;
    return EditorPresence(
      user: user,
      machine: json['machine']?.toString() ?? '',
      since: time('since') ?? heartbeat,
      heartbeat: heartbeat,
      unsaved: json['unsaved'] == true,
      savedAt: time('savedAt'),
    );
  }
}

/// Reads and writes the presence files beside one document.
class PresenceBoard {
  final String documentPath;

  const PresenceBoard(this.documentPath);

  String get folder => path.join(
        path.dirname(documentPath),
        kPresenceFolderName,
        path.basename(documentPath),
      );

  String fileFor(CollabIdentity me) => path.join(folder, '${me.fileStem}.json');

  /// Says this identity has the document open. Never throws: a read-only
  /// share or a sync client holding the folder must not stop anybody working.
  Future<bool> announce(EditorPresence me) async {
    if (documentPath.isEmpty) return false;
    try {
      await Directory(folder).create(recursive: true);
      final file = File(fileFor(me.identity));
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(me.toJson()), flush: true);
      await tmp.rename(file.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Takes this identity's note down, and the folders with it when empty.
  Future<void> withdraw(CollabIdentity me) async {
    if (documentPath.isEmpty) return;
    try {
      final file = File(fileFor(me));
      if (await file.exists()) await file.delete();
      final dir = Directory(folder);
      if (await dir.exists() && await dir.list().isEmpty) {
        await dir.delete();
        final parent = dir.parent;
        if (await parent.exists() && await parent.list().isEmpty) {
          await parent.delete();
        }
      }
    } catch (_) {
      // Somebody else's app may be writing into the folder right now - that
      // is them arriving, and not a problem.
    }
  }

  /// Everybody with a live note, other than [me]. Stale notes - a copy of
  /// the app that crashed or lost the network - are left out, and tidied away
  /// once they are well past it.
  Future<List<EditorPresence>> others(
    CollabIdentity me, {
    DateTime? now,
  }) async {
    if (documentPath.isEmpty) return const [];
    final at = now ?? DateTime.now();
    final out = <EditorPresence>[];
    try {
      final dir = Directory(folder);
      if (!await dir.exists()) return const [];
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        EditorPresence? p;
        try {
          p = EditorPresence.fromJson(jsonDecode(await entity.readAsString()));
        } catch (_) {
          continue; // half-written by its owner; read it next time round
        }
        if (p == null || p.identity == me) continue;
        if (p.isStale(at)) {
          if (at.difference(p.heartbeat) > const Duration(hours: 12)) {
            try {
              await entity.delete();
            } catch (_) {}
          }
          continue;
        }
        out.add(p);
      }
    } catch (_) {
      return const [];
    }
    out.sort((a, b) => a.since.compareTo(b.since));
    return out;
  }
}
