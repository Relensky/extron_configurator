// ============================================================================
// [OFFLINE SYNC]: the configurator's files and jobs, kept on the iPad and
// synced both ways with the CTS share.
//
// What is kept (each a folder on the share, everything under it):
//   * Projects\Configurator_Files - the catalog, costs, schema, presets;
//   * every job folder opened on this device (its project file, rooms and
//     drawings) - see [keepFolder];
//   * with "Keep every job offline" on, the whole Projects folder.
//
// The copy is laid out like the share from ATEC down, at IosShare.mirrorRoot.
// While the share answers the app works on the share itself; while it doesn't
// (off campus, the VPN down, the SMB connection asleep) every share path points
// at the copy - see IosShare.translate - and edits are saved there.
//
// A sync, whenever the share answers, is two passes:
//
//   1. UP: each file changed in the copy since it was last synced is sent to
//      the share - when the share's file is as the copy last saw it. When it
//      changed there too, nothing is combined on its own: the file is HELD,
//      both sides left as they are, until a person reviews it (the share
//      button, ios_share_button.dart). A JSON file is reviewed the way two
//      people's saves are - every place both changed decided by hand, every
//      change coming in from the share ticked - and only then combined three
//      ways against what both started from; any other file is kept as the
//      iPad's, the share's, or both side by side.
//   2. DOWN: each file on the share that is new or changed since the copy
//      took it comes down. A file gone from the share goes from the copy too,
//      unless it was changed here.
//
// Deleting a file on the iPad never deletes it from the share.
//
// What the copy last saw of each file is kept in <copy>/.sync/manifest.json,
// and the content of each JSON file as it was last synced in .sync/base/ -
// the "started from" of the merge.
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../app_logger.dart';
import '../device_manuals.dart' show kDashboardManualsFolder;
import '../shared_json.dart' show withFileLock;
import 'ios_share.dart';

/// Where a sync stands, for the share button.
@immutable
class ShareSyncStatus {
  const ShareSyncStatus({
    this.running = false,
    this.lastSync,
    this.pending = 0,
    this.message = '',
    this.held = const [],
  });

  /// A sync is going on now.
  final bool running;

  /// When the last full sync finished, or null.
  final DateTime? lastSync;

  /// Files changed on this device not yet on the share.
  final int pending;

  /// What the last sync did, in words ('' before the first).
  final String message;

  /// Files changed both here and on the share since they were last synced,
  /// held until a person reviews the combine: paths relative to the share's
  /// top, '/' between folders. Neither side is touched until then.
  final List<String> held;

  ShareSyncStatus copyWith({
    bool? running,
    DateTime? lastSync,
    int? pending,
    String? message,
    List<String>? held,
  }) => ShareSyncStatus(
    running: running ?? this.running,
    lastSync: lastSync ?? this.lastSync,
    pending: pending ?? this.pending,
    message: message ?? this.message,
    held: held ?? this.held,
  );
}

/// What one sync did.
class ShareSyncResult {
  int sent = 0;
  int received = 0;
  int removed = 0;

  /// Changed on both sides: held for review, see [ShareSync.loadReview].
  final List<String> held = [];
  final List<String> failed = [];

  String describe() {
    final parts = <String>[
      if (sent > 0) '$sent sent',
      if (received > 0) '$received updated',
      if (removed > 0) '$removed removed',
      if (held.isNotEmpty)
        '${held.length} waiting for you to review the combine',
      if (failed.isNotEmpty) '${failed.length} failed',
    ];
    return parts.isEmpty ? 'Up to date' : parts.join(', ');
  }
}

class ShareSync {
  ShareSync._();

  /// Runs the sync off iOS too - for a test.
  @visibleForTesting
  static bool runAnywhereForTest = false;

  static bool get _on => Platform.isIOS || runAnywhereForTest;

  static final ValueNotifier<ShareSyncStatus> status = ValueNotifier(
    const ShareSyncStatus(),
  );

  /// Told after each sync that changed files on this device, with the share
  /// paths of what came down - for a host that wants to say so.
  static void Function(ShareSyncResult result)? onSynced;

  /// The configurator's own shared folder, always kept.
  static const String configuratorUnc =
      '${IosShare.projectsUnc}\\Configurator_Files';

  /// How often the share is tried while offline, and the copy's changes sent
  /// while online.
  static const Duration _tick = Duration(minutes: 1);

  /// How often the share is walked for changes while online.
  static const Duration _pullEvery = Duration(minutes: 10);

  static Timer? _timer;
  static DateTime? _lastPull;
  static Future<ShareSyncResult>? _running;

  /// Never copied either way.
  static bool _skip(String name) {
    final n = name.toLowerCase();
    return n.endsWith('.lock') ||
        n.endsWith('.part') ||
        n.endsWith('.tmp') ||
        n.endsWith('.saving') ||
        n.startsWith('~\$') ||
        n == '.ds_store' ||
        n == 'thumbs.db' ||
        n == '.sync';
  }

  /// Folders never walked: a room's own backups stay on the share.
  static bool _skipDir(String name) {
    final n = name.toLowerCase();
    // Hidden folders are live state, not documents: .editing holds who has a
    // file open right now (collab/presence.dart) and .sync is this copy's own.
    return n.startsWith('.') || n == 'backups' || n == r'$recycle.bin';
  }

  // ---------------------------------------------------------------------
  //  What is kept
  // ---------------------------------------------------------------------

  static String get _settingsFile =>
      p.join(p.dirname(IosShare.mirrorRoot), 'share_sync.json');

  static Map<String, dynamic> _settings() {
    try {
      final f = File(_settingsFile);
      if (f.existsSync()) {
        final v = jsonDecode(f.readAsStringSync());
        if (v is Map) return Map<String, dynamic>.from(v);
      }
    } catch (_) {}
    return {};
  }

  static void _saveSettings(Map<String, dynamic> s) {
    try {
      final f = File(_settingsFile);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(s));
    } catch (e) {
      AppLogger.logError('Could not save the offline sync settings', e);
    }
  }

  /// True when the whole Projects folder is kept, not just the jobs opened.
  static bool get keepEveryJob => _settings()['allProjects'] == true;

  static set keepEveryJob(bool on) {
    final s = _settings()..['allProjects'] = on;
    _saveSettings(s);
    if (on) unawaited(syncNow());
  }

  /// Whether the Dashboard's device manuals are kept on this device, so a
  /// manual opens in a room with no network. On unless turned off: without
  /// them the Manuals buttons find nothing offline, though the room's own
  /// files open.
  static bool get keepManuals => _settings()['manuals'] != false;

  static set keepManuals(bool on) {
    final s = _settings()..['manuals'] = on;
    _saveSettings(s);
    if (on) unawaited(syncNow());
  }

  /// Folders brought down and never sent back: reference material nobody
  /// edits on the iPad. A file there changed here is not pushed.
  static List<String> get _readOnly =>
      keepManuals ? const [kDashboardManualsFolder] : const [];

  /// The job folders kept because they were opened here, as share paths.
  static List<String> get keptFolders =>
      ((_settings()['folders'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList();

  /// Keeps the folder holding [file] (a job opened on this device) offline
  /// from now on, and brings it down now when the share answers. A file not
  /// on the share is ignored.
  static void keepFolderOf(String file) {
    if (!_on || !IosShare.active || file.isEmpty) return;
    final String unc = uncPath(p.dirname(file));
    if (!unc.startsWith(r'\\')) return;
    // The Projects folder itself, or above it, is "every job" - not this.
    if (unc.length <= IosShare.projectsUnc.length) return;
    final s = _settings();
    final folders = ((s['folders'] as List?) ?? []).map((e) => '$e').toList();
    final key = unc.toLowerCase();
    if (folders.any(
      (f) => key == f.toLowerCase() || key.startsWith('${f.toLowerCase()}\\'),
    )) {
      return;
    }
    folders.add(unc);
    s['folders'] = folders;
    _saveSettings(s);
    AppLogger.logInfo('Offline copy: now keeping $unc.');
    if (!IosShare.offline) unawaited(syncNow());
  }

  /// Stops keeping [unc] (its files stay until the next sync removes them).
  static void forgetFolder(String unc) {
    final s = _settings();
    final folders = ((s['folders'] as List?) ?? [])
        .map((e) => '$e')
        .where((f) => f.toLowerCase() != unc.toLowerCase())
        .toList();
    s['folders'] = folders;
    _saveSettings(s);
  }

  /// The share folders kept, as share paths, none inside another.
  static List<String> get scope {
    if (keepEveryJob) return [IosShare.projectsUnc, ..._readOnly];
    return [configuratorUnc, ...keptFolders, ..._readOnly];
  }

  /// [scope] less the folders that are only ever brought down.
  static List<String> get _sendScope {
    final ro = {for (final r in _readOnly) r.toLowerCase()};
    return [for (final u in scope) if (!ro.contains(u.toLowerCase())) u];
  }

  // ---------------------------------------------------------------------
  //  The manifest: what the copy last saw of each file
  // ---------------------------------------------------------------------

  static String get _syncDir => p.join(IosShare.mirrorRoot, '.sync');
  static String get _manifestFile => p.join(_syncDir, 'manifest.json');
  static String _basePath(String rel) => p.join(_syncDir, 'base', rel);

  static Map<String, _Seen> _readManifest() {
    try {
      final f = File(_manifestFile);
      if (!f.existsSync()) return {};
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is! Map) return {};
      return raw.map((k, v) => MapEntry('$k', _Seen.fromJson(v)));
    } catch (e) {
      AppLogger.logError('Offline copy: manifest unreadable, starting over', e);
      return {};
    }
  }

  static Future<void> _writeManifest(Map<String, _Seen> m) async {
    final f = File(_manifestFile);
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.part');
    await tmp.writeAsString(
      jsonEncode(m.map((k, v) => MapEntry(k, v.toJson()))),
    );
    await tmp.rename(f.path);
  }

  // ---------------------------------------------------------------------
  //  Running
  // ---------------------------------------------------------------------

  /// Starts the background checks. Call once, after [IosShare.restore].
  static void start() {
    if (!_on || _timer != null) return;
    _timer = Timer.periodic(_tick, (_) => unawaited(_onTick()));
    unawaited(_onTick(firstRun: true));
  }

  /// The app came back to the front: the share may have answered meanwhile.
  static void resumed() {
    if (!_on) return;
    unawaited(_onTick());
  }

  static Future<void> _onTick({bool firstRun = false}) async {
    if (!IosShare.active || _running != null) return;
    final wasOffline = IosShare.offline;
    final ok = await IosShare.checkReachable();
    if (!ok) {
      await _countPending();
      return;
    }
    final due =
        firstRun ||
        wasOffline ||
        _lastPull == null ||
        DateTime.now().difference(_lastPull!) >= _pullEvery;
    await syncNow(pull: due);
  }

  /// Sends what changed here and, with [pull], brings down what changed on
  /// the share. One at a time; a call during a sync waits for it.
  static Future<ShareSyncResult> syncNow({bool pull = true}) {
    final running = _running;
    if (running != null) return running;
    final future = _sync(pull: pull);
    _running = future;
    return future.whenComplete(() => _running = null);
  }

  static Future<ShareSyncResult> _sync({required bool pull}) async {
    final result = ShareSyncResult();
    if (!_on || !IosShare.active) return result;
    if (!await IosShare.checkReachable()) {
      await _countPending();
      return result;
    }
    final top = IosShare.shareLocalRoot;
    if (top == null) return result;
    status.value = status.value.copyWith(running: true);
    try {
      final manifest = _readManifest();
      await _push(top, manifest, result);
      await _writeManifest(manifest);
      if (pull) {
        await _pull(top, manifest, result);
        await _writeManifest(manifest);
        _lastPull = DateTime.now();
      }
      final words = result.describe();
      if (result.sent + result.received + result.removed > 0 ||
          result.held.isNotEmpty ||
          result.failed.isNotEmpty) {
        AppLogger.logInfo('Offline copy synced with the share: $words.');
        onSynced?.call(result);
      }
      status.value = status.value.copyWith(
        running: false,
        lastSync: pull ? DateTime.now() : status.value.lastSync,
        message: words,
        held: [...result.held],
      );
    } catch (e, stack) {
      AppLogger.logError('Offline copy: sync stopped', e, stack);
      status.value = status.value.copyWith(
        running: false,
        message: 'Sync stopped: $e',
      );
    }
    await _countPending();
    return result;
  }

  /// Counts the files changed here that the share hasn't got yet.
  static Future<void> _countPending() async {
    if (!IosShare.active) return;
    try {
      final n = await _changedHere(_readManifest()).length;
      if (n != status.value.pending) {
        status.value = status.value.copyWith(pending: n);
      }
    } catch (_) {}
  }

  // ---------------------------------------------------------------------
  //  Up: the copy's changes to the share
  // ---------------------------------------------------------------------

  /// The files in the copy, inside [scope], changed since they were synced
  /// (or made here), relative to the share's top with '/'.
  static Stream<String> _changedHere(Map<String, _Seen> manifest) async* {
    final mirror = IosShare.mirrorRoot;
    for (final unc in _sendScope) {
      final dir = IosShare.mirrorPathFor(unc);
      if (dir == null || !await Directory(dir).exists()) continue;
      await for (final f in _walk(Directory(dir))) {
        final rel = p.relative(f.path, from: mirror).replaceAll('\\', '/');
        final seen = manifest[rel];
        if (seen == null) {
          yield rel;
          continue;
        }
        final st = await f.stat();
        if (st.size != seen.size || !_sameTime(st.modified, seen.mirrorTime)) {
          yield rel;
        }
      }
    }
  }

  static Future<void> _push(
    String top,
    Map<String, _Seen> manifest,
    ShareSyncResult result,
  ) async {
    final mirror = IosShare.mirrorRoot;
    final changed = await _changedHere(manifest).toList();
    for (final rel in changed) {
      final local = File(p.join(mirror, rel));
      final remote = File(p.join(top, rel));
      try {
        final seen = manifest[rel];
        final rs = await remote.stat().timeout(IosShare.answerWithin);
        final remoteThere = rs.type == FileSystemEntityType.file;
        final remoteUnchanged =
            remoteThere &&
            seen != null &&
            rs.size == seen.size &&
            _sameTime(rs.modified, seen.shareTime);

        if (!remoteThere || remoteUnchanged) {
          await _copy(local, remote);
          result.sent++;
        } else if (await _sameBytes(local, remote)) {
          // Both changed it the same way: nothing to combine.
        } else {
          // Changed on both sides: held for a person to review. Nothing is
          // written either way, and the pull leaves the copy's version alone.
          result.held.add(rel);
          continue;
        }
        await _record(manifest, rel, local, remote);
      } catch (e) {
        result.failed.add(rel);
        AppLogger.logError('Offline copy: could not send $rel', e);
      }
    }
  }

  static Future<bool> _sameBytes(File a, File b) async {
    final sa = await a.length(), sb = await b.length();
    if (sa != sb) return false;
    final ba = await a.readAsBytes(), bb = await b.readAsBytes();
    for (var i = 0; i < ba.length; i++) {
      if (ba[i] != bb[i]) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------
  //  Review: a file changed on both sides, decided by a person
  // ---------------------------------------------------------------------

  /// What a held file is now on both sides, for the review; null when it
  /// isn't held any more (or the share doesn't answer).
  static Future<ShareReview?> loadReview(String rel) async {
    final top = IosShare.shareLocalRoot;
    if (top == null || !await IosShare.checkReachable()) return null;
    final local = File(p.join(IosShare.mirrorRoot, rel));
    final remote = File(p.join(top, rel));
    if (!await local.exists()) return null;
    final rs = await remote.stat().timeout(IosShare.answerWithin);
    if (rs.type != FileSystemEntityType.file) return null;
    Object? base, mine, theirs;
    if (_isJson(rel)) {
      try {
        mine = jsonDecode(await local.readAsString());
        theirs = jsonDecode(await remote.readAsString());
        final b = File(_basePath(rel));
        if (await b.exists()) base = jsonDecode(await b.readAsString());
      } catch (_) {
        // Not readable as JSON: reviewed as a plain file.
        mine = theirs = base = null;
      }
    }
    return ShareReview._(
      rel: rel,
      unc: uncPath(remote.path),
      json: mine != null && theirs != null,
      base: base,
      mine: mine,
      theirs: theirs,
      shareSize: rs.size,
      shareTime: rs.modified,
    );
  }

  /// The person approved [combined] - the iPad's version and the share's,
  /// combined as they chose. Written to both sides. Throws
  /// [ShareChangedAgain] when the share's file changed again during the
  /// review: it has to be looked at again.
  static Future<void> applyCombined(ShareReview r, Object? combined) =>
      _resolve(r, (local, remote) async {
        final text = const JsonEncoder.withIndent('  ').convert(combined);
        await _writeVia(remote, text);
        await _writeVia(local, text);
        AppLogger.logInfo('Offline copy: combined ${r.unc} after review.');
      });

  /// The person kept the iPad's version: it replaces the share's.
  static Future<void> keepMine(ShareReview r) =>
      _resolve(r, (local, remote) async {
        await _copy(local, remote);
        AppLogger.logInfo('Offline copy: kept this device\'s ${r.unc}.');
      });

  /// The person kept the share's version: the iPad's edits are dropped.
  static Future<void> keepTheirs(ShareReview r) =>
      _resolve(r, (local, remote) async {
        await _copy(remote, local);
        AppLogger.logInfo('Offline copy: kept the share\'s ${r.unc}.');
      });

  /// The person kept both: the share's stays, the iPad's goes beside it as
  /// `<name> (iPad edits <date>).<ext>`. Returns that file's share path.
  static Future<String> keepBoth(ShareReview r) async {
    var kept = '';
    await _resolve(r, (local, remote) async {
      kept = _keptTwiceName(remote.path);
      await _copy(local, File(kept));
      await _copy(remote, local);
      AppLogger.logInfo('Offline copy: kept both copies of ${r.unc}.');
    });
    return uncPath(kept);
  }

  static Future<void> _resolve(
    ShareReview r,
    Future<void> Function(File local, File remote) act,
  ) async {
    final top = IosShare.shareLocalRoot;
    if (top == null) throw const ShareChangedAgain();
    final local = File(p.join(IosShare.mirrorRoot, r.rel));
    final remote = File(p.join(top, r.rel));
    await withFileLock(remote.path, () async {
      final rs = await remote.stat().timeout(IosShare.answerWithin);
      if (rs.size != r.shareSize || !_sameTime(rs.modified, r.shareTime)) {
        throw const ShareChangedAgain();
      }
      // Both versions as they were before the decision, kept on the device
      // (<copy>/.sync/reviewed/<when>/), so a wrong choice can be undone.
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-');
      final keep = p.join(_syncDir, 'reviewed', stamp);
      final ext = p.extension(r.rel);
      final stem = p.withoutExtension(r.rel);
      await _copy(local, File(p.join(keep, '$stem (this device)$ext')));
      await _copy(remote, File(p.join(keep, '$stem (share)$ext')));
      await act(local, remote);
      final manifest = _readManifest();
      await _record(manifest, r.rel, local, remote);
      await _writeManifest(manifest);
    });
    status.value = status.value.copyWith(
      held: [...status.value.held]..remove(r.rel),
    );
    await _countPending();
  }

  // ---------------------------------------------------------------------
  //  Down: the share's changes to the copy
  // ---------------------------------------------------------------------

  static Future<void> _pull(
    String top,
    Map<String, _Seen> manifest,
    ShareSyncResult result,
  ) async {
    final mirror = IosShare.mirrorRoot;
    for (final unc in scope) {
      final live = IosShare.livePathFor(unc);
      if (live == null) continue;
      final liveDir = Directory(live);
      if (await _exists(liveDir) != true) continue;
      final seenHere = <String>{};
      var listed = true;
      try {
        await for (final f in _walk(
          liveDir,
          timeout: const Duration(seconds: 60),
        )) {
          final rel = p.relative(f.path, from: top).replaceAll('\\', '/');
          seenHere.add(rel);
          final local = File(p.join(mirror, rel));
          final seen = manifest[rel];
          try {
            final rs = await f.stat().timeout(IosShare.answerWithin);
            if (seen != null && await local.exists()) {
              final ls = await local.stat();
              // Changed here and not sent (the send failed): left for the
              // next send rather than overwritten.
              if (ls.size != seen.size ||
                  !_sameTime(ls.modified, seen.mirrorTime)) {
                continue;
              }
              if (rs.size == seen.size &&
                  _sameTime(rs.modified, seen.shareTime)) {
                continue;
              }
            } else if (seen == null && await local.exists()) {
              // Made here and on the share both: the send pass handles it.
              continue;
            }
            await _copy(f, local);
            await _record(manifest, rel, local, f);
            result.received++;
          } catch (e) {
            result.failed.add(rel);
            AppLogger.logError('Offline copy: could not bring down $rel', e);
          }
        }
      } catch (e) {
        // Part of the folder couldn't be listed: nothing is taken as gone.
        listed = false;
        AppLogger.logError('Offline copy: could not list $unc', e);
      }
      if (!listed) continue;

      // Gone from the share and unchanged here: gone from the copy.
      final prefix = p
          .relative(live, from: top)
          .replaceAll('\\', '/')
          .replaceFirst(RegExp(r'/$'), '');
      final gone = manifest.keys
          .where(
            (rel) =>
                (rel == prefix || rel.startsWith('$prefix/')) &&
                !seenHere.contains(rel),
          )
          .toList();
      for (final rel in gone) {
        final local = File(p.join(mirror, rel));
        try {
          if (await local.exists()) {
            final ls = await local.stat();
            final was = manifest[rel]!;
            if (ls.size != was.size ||
                !_sameTime(ls.modified, was.mirrorTime)) {
              continue;
            }
            await local.delete();
          }
          final base = File(_basePath(rel));
          if (await base.exists()) await base.delete();
          manifest.remove(rel);
          result.removed++;
        } catch (_) {}
      }
    }
  }

  // ---------------------------------------------------------------------
  //  Files
  // ---------------------------------------------------------------------

  /// Every file under [dir], skipping what is never synced.
  static Stream<File> _walk(
    Directory dir, {
    Duration timeout = const Duration(seconds: 30),
  }) async* {
    final List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList().timeout(timeout);
    } on TimeoutException {
      throw FileSystemException('Listing took too long', dir.path);
    }
    for (final e in entries) {
      final name = p.basename(e.path);
      if (e is Directory) {
        if (_skipDir(name)) continue;
        yield* _walk(e, timeout: timeout);
      } else if (e is File) {
        if (_skip(name)) continue;
        yield e;
      }
    }
  }

  static Future<bool?> _exists(Directory d) async {
    try {
      return await d.exists().timeout(IosShare.answerWithin);
    } catch (_) {
      return null;
    }
  }

  /// Copies [from] over [to] through a .part file, keeping its time.
  static Future<void> _copy(File from, File to) async {
    await to.parent.create(recursive: true);
    final tmp = File('${to.path}.part');
    await from.copy(tmp.path).timeout(const Duration(minutes: 3));
    final modified = (await from.stat()).modified;
    await tmp.rename(to.path);
    try {
      await to.setLastModified(modified);
    } catch (_) {}
  }

  static Future<void> _writeVia(File to, String text) async {
    await to.parent.create(recursive: true);
    final tmp = File('${to.path}.part');
    await tmp.writeAsString(text);
    await tmp.rename(to.path);
  }

  /// Notes what the two sides look like now [rel] is the same on both, and
  /// keeps a JSON file's content as the base of the next merge.
  static Future<void> _record(
    Map<String, _Seen> manifest,
    String rel,
    File local,
    File remote,
  ) async {
    final rs = await remote.stat().timeout(IosShare.answerWithin);
    final ls = await local.stat();
    manifest[rel] = _Seen(
      size: rs.size,
      shareTime: rs.modified,
      mirrorTime: ls.modified,
    );
    if (_isJson(rel)) {
      final base = File(_basePath(rel));
      await base.parent.create(recursive: true);
      await local.copy(base.path);
    }
  }

  static bool _isJson(String rel) => rel.toLowerCase().endsWith('.json');

  /// "Room (iPad edits 2026-11-18 0942).pdf" beside [file].
  static String _keptTwiceName(String file) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}${two(now.minute)}';
    return p.join(
      p.dirname(file),
      '${p.basenameWithoutExtension(file)} (iPad edits $stamp)'
      '${p.extension(file)}',
    );
  }

  /// File times over SMB and on the device round differently: within two
  /// seconds is the same time.
  static bool _sameTime(DateTime a, DateTime b) =>
      a.difference(b).inMilliseconds.abs() < 2000;
}

/// What the copy last saw of one file.
class _Seen {
  _Seen({
    required this.size,
    required this.shareTime,
    required this.mirrorTime,
  });

  final int size;
  final DateTime shareTime;
  final DateTime mirrorTime;

  factory _Seen.fromJson(Object? v) {
    final m = v is Map ? v : const {};
    DateTime t(Object? x) =>
        DateTime.fromMillisecondsSinceEpoch((x as num?)?.toInt() ?? 0);
    return _Seen(
      size: (m['z'] as num?)?.toInt() ?? -1,
      shareTime: t(m['s']),
      mirrorTime: t(m['m']),
    );
  }

  Map<String, Object> toJson() => {
    'z': size,
    's': shareTime.millisecondsSinceEpoch,
    'm': mirrorTime.millisecondsSinceEpoch,
  };
}

/// A held file, as both sides are now - see [ShareSync.loadReview].
class ShareReview {
  ShareReview._({
    required this.rel,
    required this.unc,
    required this.json,
    required this.base,
    required this.mine,
    required this.theirs,
    required this.shareSize,
    required this.shareTime,
  });

  /// The file relative to the share's top, as [ShareSyncStatus.held] has it.
  final String rel;

  /// The file's \\doit-files path, for showing.
  final String unc;

  /// True when both sides read as JSON and can be combined field by field.
  final bool json;

  /// The file as both last had it, or null when there's no common version
  /// (made on both sides at once).
  final Object? base;

  /// This device's version and the share's (JSON only).
  final Object? mine;
  final Object? theirs;

  /// The share's file as reviewed: a combine is only written over this.
  final int shareSize;
  final DateTime shareTime;
}

/// The share's file changed again while it was being reviewed.
class ShareChangedAgain implements Exception {
  const ShareChangedAgain();

  @override
  String toString() =>
      'The file changed on the share again while you were reviewing it. '
      'Review it again to see the newest version.';
}
