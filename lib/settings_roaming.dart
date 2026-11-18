// ============================================================================
// [SETTINGS ROAMING]: your settings follow your Windows login from PC to PC.
//
// Each app names the local JSON files whose settings should roam (the
// dashboard: Config.json and the 'settings' section of window_memory.json).
// Their keys are copied into ONE file per person on the share:
//
//   <team folder>\users\<Windows login>\<app>_settings.json
//
//   { "version": 1, "app": "cts_dashboard", "login": "dstanley",
//     "files": { "config": { "isDarkMode": {"v": true, "at": "...Z",
//                                            "by": "PC-NAME"}, ... } } }
//
// SECRETS: a value the app keeps encrypted with classic DPAPI (readable only
// by this user on THIS PC) is decrypted and re-encrypted with DPAPI-NG to
// "SID=<your own user SID>" before it goes to the share - so the file on the
// share is readable by the team, but the passwords and tokens in it open only
// for your account, on any domain PC. On the way back each one is encrypted
// again with the local DPAPI. If DPAPI-NG is not available that key is left
// out of the share (logged), never written in the clear.
//
// FILES: a value that is the path of a small file (the Google service account
// key) can be carried too: its contents go to the share encrypted the same
// way, and on another PC they are written into [fileStoreDir] and the setting
// points there.
//
// HOW CHANGES MEET: every key on the share carries the time it was written.
// A small local state file remembers, per key, a fingerprint of the local
// value and the share's time at the last sync. So at start-up:
//   * changed here only        -> pushed
//   * changed on the share only -> pulled into the local file
//   * changed in both           -> the newer wins (local = file's mtime)
// While the app runs, syncs only PUSH (the app holds its settings in memory
// and would write a pulled value straight back); what another PC changed
// arrives at the next start.
//
// FIRST TIME on a PC (or for a new login / moved folder) with settings
// already on the share, nothing is pushed or pulled until the app asks and
// calls [sync] with a [RoamingChoice].
//
// Self-contained (Flutter, crypto, ffi and dpapi_ng.dart beside it) so the
// same file serves the dashboard, the Room Config Builder and the instructor
// app. Keep the copies identical.
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;

import 'dpapi_ng.dart';
import 'team/team_presence.dart' show TeamIdentity;

/// One local JSON file whose settings roam.
class RoamingFile {
  /// Name of this file's block in the share file ('config').
  final String id;

  /// The local file.
  final String path;

  /// When set, only the entries of this top-level map roam (window_memory's
  /// 'settings'); otherwise every top-level key does.
  final String? section;

  /// Whether [key] (with its current local value) may roam. Machine-only
  /// settings answer false: they are neither pushed nor pulled.
  final bool Function(String key, Object? value) roams;

  /// JSON paths, starting with the top-level key, whose string value is the
  /// path of a file whose CONTENTS should roam:
  /// `[['OnlineSources', 'GoogleServiceAccountKey']]`.
  final List<List<String>> filePaths;

  /// How to change the local file safely, when the app has its own writer
  /// (the dashboard's Config.json edit queue). Null: read, change, and write
  /// through a temporary file.
  final Future<void> Function(void Function(Map<String, dynamic> data) edit)?
      editor;

  /// Top-level keys whose value is a password kept in PLAIN text locally
  /// (the configurator's app_config.json, a keystore entry): sealed on the
  /// share all the same, and written back plain.
  final Set<String> plainSecretKeys;

  /// For settings that are not a JSON file (SharedPreferences, a keystore):
  /// [load] returns them as a map and [store] sets and removes keys. With
  /// these, [path] is only a label.
  final Future<Map<String, dynamic>> Function()? load;
  final Future<void> Function(Map<String, Object?> set, Set<String> remove)?
      store;

  const RoamingFile({
    required this.id,
    required this.path,
    this.section,
    this.roams = _always,
    this.filePaths = const [],
    this.editor,
    this.plainSecretKeys = const {},
    this.load,
    this.store,
  });

  bool get isVirtual => load != null;
}

bool _always(String key, Object? value) => true;

/// The answer to "settings for you are already on the share".
enum RoamingChoice {
  /// Take the share's settings here (the share wins where both differ).
  useShared,

  /// Keep this PC's settings and put them on the share (this PC wins).
  keepThisPc,

  /// Do not sync on this PC.
  off,
}

class RoamingResult {
  /// Ids of the local files that took values from the share.
  final Set<String> pulledFiles;
  final int pushed;
  final int pulled;

  /// Settings for this login are on the share and this PC has never synced
  /// with them: ask, then call [SettingsRoaming.sync] with the choice.
  final bool needsChoice;

  /// What went wrong, '' when nothing did.
  final String problem;

  const RoamingResult({
    this.pulledFiles = const {},
    this.pushed = 0,
    this.pulled = 0,
    this.needsChoice = false,
    this.problem = '',
  });
}

class _Skip implements Exception {
  final String why;
  const _Skip(this.why);
}

const String _kNgMarker = 'ngsid:v1:'; // back to the app's local encryption
const String _kNgPlainMarker = 'ngsid:p1:'; // back to plain text
const String _kFileMarker = 'roamedFile';

/// Files bigger than this are not carried (a key file is a few KB).
const int _kMaxRoamedFile = 256 * 1024;

class SettingsRoaming {
  SettingsRoaming({
    required this.app,
    required this.files,
    required this.statePath,
    required this.fileStoreDir,
    required this.protectLocal,
    required this.unprotectLocal,
    required this.isLocalSecret,
    String? login,
    String? machine,
    this.log,
    Uint8List Function(Uint8List data, String sid)? ngProtect,
    Uint8List Function(Uint8List blob)? ngUnprotect,
    Future<String> Function()? userSid,
  })  : login = login ??
            _nonEmpty(TeamIdentity.userOverride) ??
            _env(const ['USERNAME', 'USER'], 'unknown'),
        machine = machine ??
            _nonEmpty(TeamIdentity.machineOverride) ??
            _env(const ['COMPUTERNAME', 'HOSTNAME'], 'pc'),
        _ngProtect = ngProtect ?? DpapiNg.protect,
        _ngUnprotect = ngUnprotect ?? DpapiNg.unprotect,
        _userSid = userSid ?? currentUserSid;

  /// Names the share file: `<app>_settings.json`.
  final String app;
  final List<RoamingFile> files;

  /// This PC's memory of the last sync (beside the app's own files).
  final String statePath;

  /// Where roamed files ([RoamingFile.filePaths]) are written on this PC.
  final String fileStoreDir;

  /// The app's own local encryption (SecretStore.protect / unprotect) and how
  /// to tell a value it encrypted.
  final String Function(String plain) protectLocal;
  final String Function(String stored) unprotectLocal;
  final bool Function(String value) isLocalSecret;

  final String login;
  final String machine;

  /// Where to note what happened (settable, for an app whose log starts
  /// after the first sync).
  void Function(String message)? log;

  final Uint8List Function(Uint8List data, String sid) _ngProtect;
  final Uint8List Function(Uint8List blob) _ngUnprotect;
  final Future<String> Function() _userSid;

  /// The team folder the per-person folders go in. '' = no syncing.
  String folder = '';

  /// What happened last, for Settings to show.
  final ValueNotifier<String> status = ValueNotifier<String>('');

  Timer? _debounce;
  Timer? _periodic;
  Future<RoamingResult>? _running;
  String? _sid;

  /// [v] trimmed, or null when there is nothing in it - for the iPhone /
  /// iPad sign-in (TeamIdentity, mobile_sign_in.dart), which stands in for
  /// the Windows one there.
  static String? _nonEmpty(String? v) {
    final t = v?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  static String _env(List<String> keys, String fallback) {
    for (final k in keys) {
      final v = Platform.environment[k]?.trim() ?? '';
      if (v.isNotEmpty) return v;
    }
    return fallback;
  }

  /// This person's folder on the share, '' when there is no team folder.
  String get userFolder => folder.trim().isEmpty
      ? ''
      : [folder.trim(), 'users', login].join(Platform.pathSeparator);

  /// The share file, '' when there is no team folder.
  String get shareFile => userFolder.isEmpty
      ? ''
      : '$userFolder${Platform.pathSeparator}${app}_settings.json';

  // --------------------------------------------------------------------------
  // On / off on this PC
  // --------------------------------------------------------------------------

  /// False when this PC was set not to sync.
  Future<bool> isEnabled() async => (await _readState())['choice'] != 'off';

  /// Switches syncing on or off on this PC. Switching on starts afresh: the
  /// next sync with settings on the share asks again.
  Future<void> setEnabled(bool on) async {
    final state = await _readState();
    if (on) {
      state.remove('choice');
      state.remove('share');
      state.remove('files');
    } else {
      state['choice'] = 'off';
    }
    await _writeJson(statePath, state);
    status.value = on ? 'On' : 'Off on this PC';
  }

  // --------------------------------------------------------------------------
  // Pushing while the app runs
  // --------------------------------------------------------------------------

  /// A local setting changed: push in a few seconds (changes made together
  /// go in one write).
  void schedulePush([Duration delay = const Duration(seconds: 3)]) {
    _debounce?.cancel();
    _debounce = Timer(delay, () => unawaited(sync()));
  }

  /// Also pushes now and then, for changes other processes (pop-out windows)
  /// made to the files.
  void startPeriodic([Duration every = const Duration(minutes: 5)]) {
    _periodic?.cancel();
    _periodic = Timer.periodic(every, (_) => unawaited(sync()));
  }

  void dispose() {
    _debounce?.cancel();
    _periodic?.cancel();
  }

  // --------------------------------------------------------------------------
  // The sync
  // --------------------------------------------------------------------------

  /// Syncs the local files with the share. [startup] true pulls as well as
  /// pushes (call it before the app reads the files); false only pushes.
  /// [choice] answers [RoamingResult.needsChoice].
  Future<RoamingResult> sync({bool startup = false, RoamingChoice? choice}) {
    // One at a time; a push asked for during a sync waits for it.
    final previous = _running;
    final Future<RoamingResult> run = (previous == null
            ? Future<void>.value()
            : previous.then((_) {}, onError: (_) {}))
        .then((_) => _sync(startup: startup, choice: choice));
    _running = run;
    return run;
  }

  Future<RoamingResult> _sync(
      {required bool startup, RoamingChoice? choice}) async {
    final share = shareFile;
    if (share.isEmpty) {
      status.value = 'No team folder, so nothing is kept on the share';
      return const RoamingResult();
    }
    try {
      final state = await _readState();
      if (choice == RoamingChoice.off) {
        state['choice'] = 'off';
        await _writeJson(statePath, state);
        status.value = 'Off on this PC';
        return const RoamingResult();
      }
      if (state['choice'] == 'off' && choice == null) {
        status.value = 'Off on this PC';
        return const RoamingResult();
      }

      final File shareF = File(share);
      Map<String, dynamic>? doc;
      if (await shareF.exists()) {
        final Object? decoded = jsonDecode(await shareF.readAsString());
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('the share file is not a JSON object');
        }
        doc = decoded;
      }
      final Map<String, dynamic> shareFiles =
          _map(doc?['files']) ?? <String, dynamic>{};
      final bool fresh =
          state['share'] != share || _map(state['files']) == null;
      final bool shareHasAny = shareFiles.values.any((f) =>
          f is Map && f.values.any((e) => e is Map && e['deleted'] != true));

      RoamingChoice? firstChoice = choice;
      if (fresh && firstChoice == null) {
        if (shareHasAny) {
          status.value =
              'Your settings are on the share - waiting for a choice';
          return const RoamingResult(needsChoice: true);
        }
        firstChoice = RoamingChoice.keepThisPc;
      }
      if (fresh) state['files'] = <String, dynamic>{};
      state['share'] = share;
      state['login'] = login;
      state['choice'] = 'on';
      final Map<String, dynamic> snaps = _map(state['files'])!;

      final String now = DateTime.now().toUtc().toIso8601String();
      final Map<String, Map<String, dynamic>> toPush = {};
      final Set<String> pulledFiles = {};
      int pulled = 0;

      for (final RoamingFile f in files) {
        final Map<String, dynamic> whole =
            f.isVirtual ? await f.load!() : await _readLocal(f.path);
        final Map<String, dynamic> local =
            f.section == null ? whole : (_map(whole[f.section]) ?? {});
        final Map<String, dynamic> shareBlock =
            _map(shareFiles[f.id]) ?? <String, dynamic>{};
        final Map<String, dynamic> fileSnaps =
            _map(snaps[f.id]) ?? (snaps[f.id] = <String, dynamic>{});
        // No time for a virtual file: in a both-changed clash at start-up
        // the share wins.
        DateTime? localTime;
        if (!f.isVirtual) {
          try {
            localTime = (await File(f.path).lastModified()).toUtc();
          } catch (_) {}
        }

        final Map<String, Object?> setLocal = {};
        final Set<String> removeLocal = {};
        final keys = <String>{...local.keys, ...shareBlock.keys};
        for (final String key in keys) {
          final bool hasLocal = local.containsKey(key);
          final Object? localV = local[key];
          if (!f.roams(key, hasLocal ? localV : null)) continue;
          final Map<String, dynamic>? entry = _map(shareBlock[key]);
          if (entry != null &&
              entry['deleted'] != true &&
              !f.roams(key, entry['v'])) {
            continue;
          }
          final Map<String, dynamic>? snap = _map(fileSnaps[key]);
          final String? lf = hasLocal ? _fingerprint(localV) : null;

          bool push = false;
          bool pull = false;
          if (fresh) {
            if (entry == null) {
              push = hasLocal;
            } else if (!hasLocal) {
              pull = entry['deleted'] != true;
            } else {
              push = firstChoice == RoamingChoice.keepThisPc;
              pull = !push;
            }
          } else {
            final bool shareChanged =
                entry != null && entry['at'] != snap?['at'];
            final bool localChanged = lf != snap?['fp'];
            if (localChanged && shareChanged) {
              if (!startup) {
                push = true;
              } else {
                final DateTime? shareTime = DateTime.tryParse('${entry['at']}');
                pull = shareTime != null &&
                    (localTime == null || shareTime.isAfter(localTime));
                push = !pull;
              }
            } else if (localChanged) {
              push = true;
            } else if (shareChanged) {
              pull = startup;
            }
          }

          if (push) {
            if (!hasLocal) {
              if (entry != null && entry['deleted'] != true) {
                (toPush[f.id] ??= {})[key] = {
                  'deleted': true,
                  'at': now,
                  'by': machine,
                };
              }
              fileSnaps.remove(key);
              continue;
            }
            try {
              final Object? shared = await _toShare(localV, [key], f);
              (toPush[f.id] ??= {})[key] = {
                'v': shared,
                'at': now,
                'by': machine
              };
              fileSnaps[key] = {'fp': lf, 'at': now};
            } on _Skip catch (e) {
              log?.call('[SETTINGS SYNC] $key left off the share: ${e.why}');
            }
          } else if (pull && entry != null) {
            if (entry['deleted'] == true) {
              if (hasLocal) {
                removeLocal.add(key);
                pulled++;
              }
              fileSnaps[key] = {'fp': null, 'at': entry['at']};
              continue;
            }
            try {
              final Object? value = await _toLocal(entry['v']);
              if (lf != _fingerprint(value)) {
                setLocal[key] = value;
                pulled++;
              }
              fileSnaps[key] = {'fp': _fingerprint(value), 'at': entry['at']};
            } on _Skip catch (e) {
              log?.call(
                  '[SETTINGS SYNC] $key not taken from the share: ${e.why}');
            }
          }
        }

        if (setLocal.isNotEmpty || removeLocal.isNotEmpty) {
          void apply(Map<String, dynamic> data) {
            final Map<String, dynamic> target;
            if (f.section == null) {
              target = data;
            } else {
              target = _map(data[f.section]) ?? <String, dynamic>{};
              data[f.section!] = target;
            }
            target.addAll(setLocal);
            removeLocal.forEach(target.remove);
          }

          if (f.store != null) {
            await f.store!(setLocal, removeLocal);
          } else if (f.editor != null) {
            await f.editor!(apply);
          } else {
            final Map<String, dynamic> latest = await _readLocal(f.path);
            apply(latest);
            await _writeJson(f.path, latest, pretty: f.section == null);
          }
          pulledFiles.add(f.id);
        }
      }

      int pushed = 0;
      if (toPush.isNotEmpty) {
        pushed = toPush.values.fold(0, (n, m) => n + m.length);
        await Directory(userFolder).create(recursive: true);
        // Re-read just before writing, so a write from another PC since the
        // read above keeps its other keys.
        Map<String, dynamic> latest = <String, dynamic>{};
        if (await shareF.exists()) {
          try {
            final Object? d = jsonDecode(await shareF.readAsString());
            if (d is Map<String, dynamic>) latest = d;
          } catch (_) {
            latest = doc ?? <String, dynamic>{};
          }
        }
        final Map<String, dynamic> latestFiles =
            _map(latest['files']) ?? <String, dynamic>{};
        toPush.forEach((id, entries) {
          final Map<String, dynamic> block =
              _map(latestFiles[id]) ?? <String, dynamic>{};
          block.addAll(entries);
          latestFiles[id] = block;
        });
        latest
          ..['version'] = 1
          ..['app'] = app
          ..['login'] = login
          ..['savedBy'] = machine
          ..['savedAt'] = now
          ..['files'] = latestFiles;
        await _writeJson(share, latest, pretty: true);
      }

      await _writeJson(statePath, state);
      final String when = _clock(DateTime.now());
      status.value = pushed == 0 && pulled == 0
          ? 'Up to date ($when)'
          : 'Synced at $when: $pushed saved to the share, $pulled taken from it';
      if (pushed > 0 || pulled > 0) {
        log?.call('[SETTINGS SYNC] $share: pushed $pushed, pulled $pulled'
            '${pulledFiles.isEmpty ? '' : ' into ${pulledFiles.join(', ')}'}');
      }
      return RoamingResult(
          pulledFiles: pulledFiles, pushed: pushed, pulled: pulled);
    } catch (e) {
      final String problem = 'Could not sync settings with $share: $e';
      status.value = problem;
      log?.call('[SETTINGS SYNC] $problem');
      return RoamingResult(problem: problem);
    }
  }

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // --------------------------------------------------------------------------
  // Values to and from the share
  // --------------------------------------------------------------------------

  Future<String> _sid0() async {
    final cached = _sid;
    if (cached != null && cached.isNotEmpty) return cached;
    final sid = await _userSid();
    if (sid.isEmpty) throw const _Skip('could not read your Windows SID');
    return _sid = sid;
  }

  Future<String> _seal(Uint8List bytes, [String marker = _kNgMarker]) async {
    final sid = await _sid0();
    try {
      return '$marker${base64Encode(_ngProtect(bytes, sid))}';
    } catch (e) {
      throw _Skip('DPAPI-NG would not encrypt it ($e)');
    }
  }

  Uint8List _open(String sealed) {
    try {
      // Both markers are the same length.
      return _ngUnprotect(base64Decode(sealed.substring(_kNgMarker.length)));
    } catch (e) {
      throw _Skip('this account/PC could not decrypt it ($e)');
    }
  }

  bool _isFilePath(List<String> at, RoamingFile f) => f.filePaths.any((p) =>
      p.length == at.length &&
      Iterable<int>.generate(p.length).every((i) => p[i] == at[i]));

  Future<Object?> _toShare(Object? v, List<String> at, RoamingFile f) async {
    if (v is String &&
        at.length == 1 &&
        f.plainSecretKeys.contains(at.first) &&
        v.isNotEmpty) {
      return _seal(utf8.encode(v), _kNgPlainMarker);
    }
    if (v is String) {
      if (_isFilePath(at, f) && v.trim().isNotEmpty) {
        final file = File(v.trim());
        if (await file.exists() && await file.length() <= _kMaxRoamedFile) {
          final name = file.uri.pathSegments.isEmpty
              ? 'file'
              : file.uri.pathSegments.last;
          return {
            _kFileMarker: name,
            'data': await _seal(await file.readAsBytes())
          };
        }
        return v;
      }
      if (isLocalSecret(v)) {
        final plain = unprotectLocal(v);
        if (plain.isEmpty) {
          throw const _Skip('a stored secret could not be decrypted here');
        }
        return _seal(utf8.encode(plain));
      }
      return v;
    }
    if (v is Map) {
      final out = <String, Object?>{};
      for (final e in v.entries) {
        out['${e.key}'] = await _toShare(e.value, [...at, '${e.key}'], f);
      }
      return out;
    }
    if (v is List) {
      return [for (final x in v) await _toShare(x, at, f)];
    }
    return v;
  }

  Future<Object?> _toLocal(Object? v) async {
    if (v is String) {
      if (v.startsWith(_kNgMarker)) {
        return protectLocal(utf8.decode(_open(v)));
      }
      if (v.startsWith(_kNgPlainMarker)) return utf8.decode(_open(v));
      return v;
    }
    if (v is Map) {
      if (v[_kFileMarker] is String && v['data'] is String) {
        final String name = (v[_kFileMarker] as String)
            .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        final bytes = _open(v['data'] as String);
        await Directory(fileStoreDir).create(recursive: true);
        final file = File('$fileStoreDir${Platform.pathSeparator}$name');
        bool same = false;
        if (await file.exists()) {
          final old = await file.readAsBytes();
          same = old.length == bytes.length &&
              Iterable<int>.generate(old.length)
                  .every((i) => old[i] == bytes[i]);
        }
        if (!same) await file.writeAsBytes(bytes, flush: true);
        return file.absolute.path;
      }
      final out = <String, Object?>{};
      for (final e in v.entries) {
        out['${e.key}'] = await _toLocal(e.value);
      }
      return out;
    }
    if (v is List) {
      return [for (final x in v) await _toLocal(x)];
    }
    return v;
  }

  /// A stable digest of a local value. Secrets count by their plain text, so
  /// re-encrypting the same password (DPAPI output differs every time) is not
  /// a change.
  String _fingerprint(Object? v) {
    Object? canon(Object? x) {
      if (x is String && isLocalSecret(x)) {
        return 'secret:${sha256.convert(utf8.encode(unprotectLocal(x)))}';
      }
      if (x is Map) {
        final keys = x.keys.map((k) => '$k').toList()..sort();
        return {for (final k in keys) k: canon(x[k])};
      }
      if (x is List) return [for (final y in x) canon(y)];
      return x;
    }

    return sha256.convert(utf8.encode(jsonEncode(canon(v)))).toString();
  }

  // --------------------------------------------------------------------------
  // Files
  // --------------------------------------------------------------------------

  static Map<String, dynamic>? _map(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return {for (final e in v.entries) '${e.key}': e.value};
    return null;
  }

  Future<Map<String, dynamic>> _readState() async {
    try {
      final f = File(statePath);
      if (!await f.exists()) return {};
      final d = jsonDecode(await f.readAsString());
      return _map(d) ?? {};
    } catch (_) {
      return {};
    }
  }

  static Future<Map<String, dynamic>> _readLocal(String path) async {
    final f = File(path);
    if (!await f.exists()) return {};
    final Object? d = jsonDecode(await f.readAsString());
    final m = _map(d);
    if (m == null) throw FormatException('$path is not a JSON object');
    return m;
  }

  static Future<void> _writeJson(String path, Map<String, dynamic> data,
      {bool pretty = false}) async {
    final text = pretty
        ? const JsonEncoder.withIndent('  ').convert(data)
        : jsonEncode(data);
    final temp = File('$path.roaming');
    await temp.writeAsString(text, flush: true);
    await temp.rename(path);
  }

  // --------------------------------------------------------------------------
  // Helpers for the apps
  // --------------------------------------------------------------------------

  /// The signed-in user's SID ("S-1-5-21-..."), '' when it cannot be read.
  static Future<String> currentUserSid() async {
    if (!Platform.isWindows) return '';
    try {
      final r =
          await Process.run('whoami', const ['/user', '/fo', 'csv', '/nh'])
              .timeout(const Duration(seconds: 10));
      final m = RegExp(r'"(S-1-[0-9-]+)"').firstMatch('${r.stdout}');
      return m?.group(1) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// True for a path on one of this PC's own drives (C:\...), which means
  /// nothing on another PC. Mapped network drives and \\server paths are not
  /// local.
  static bool isLocalDrivePath(Object? value) {
    if (value is! String) return false;
    final v = value.trim();
    if (!RegExp(r'^[A-Za-z]:([\\/]|$)').hasMatch(v)) return false;
    if (!Platform.isWindows) return true;
    try {
      final getDriveType = DynamicLibrary.open('kernel32.dll').lookupFunction<
          Uint32 Function(Pointer<Utf16>),
          int Function(Pointer<Utf16>)>('GetDriveTypeW');
      final root = '${v.substring(0, 2)}\\'.toNativeUtf16();
      try {
        return getDriveType(root) != 4; // DRIVE_REMOTE
      } finally {
        calloc.free(root);
      }
    } catch (_) {
      return true;
    }
  }
}
