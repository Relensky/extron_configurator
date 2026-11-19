// ============================================================================
// [iOS SHARED FOLDER]: the \\doit-files share on an iPhone or iPad.
//
// iOS apps can't open \\server\share paths. The share is connected once in
// the Files app (Browse > ... > Connect to Server > smb://doit-files.csuchico.edu,
// on campus Wi-Fi or the VPN) and a folder of it is picked in this app; iOS
// then lets the app into that folder, and SharedFolderPlugin
// (ios/Runner/AppDelegate.swift) remembers it across restarts.
//
// The rest of the app still holds \\doit-files\ATEC\... paths - the Root
// Folder, the team folder, room paths inside projects. [translate] turns them
// into paths under the picked folder, so nothing downstream changes. On the
// desktop it returns every path as it was given.
//
// Any level from the ATEC share down to the Projects folder can be picked.
// Classroom Technology is the one to pick: it holds Projects (the configurator's
// files and jobs), Dashboard\team (chat and presence) and Calendar, and iOS
// only lets the app into the folder that was picked.
//
// [OFFLINE COPY]: share_sync.dart keeps a copy of the configurator's files
// and the jobs people open, laid out like the share from ATEC down. While the
// share doesn't answer, [offline] is set and every share path points at the
// copy instead; edits made there are sent back when the share answers again.
//
// Same approach as the CTS Dashboard's lib/services/ios_shared_folder.dart,
// with the copy synced both ways.
// ============================================================================

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../app_paths.dart';

/// [path] as this device reaches it: a \\doit-files path under the picked
/// share folder (or its offline copy) on iOS; anything else as it was.
String sharePath(String path) =>
    IosShare.translate(rehomeIosContainerPath(path));

/// The reverse of [sharePath]: a path under the picked folder or the offline
/// copy as the \\doit-files path the Windows apps use, so what is written into
/// a shared file still opens on a desktop. Anything else as it was.
String uncPath(String path) => IosShare.toUnc(path);

class IosShare {
  IosShare._();

  static const MethodChannel _channel = MethodChannel('rcb/shared_folder');

  /// The share's top: every path the apps use starts here.
  static const String shareUnc = r'\\doit-files\ATEC';

  /// The folder this app needs; the picked one must be it or above it.
  static const String projectsUnc =
      r'\\doit-files\ATEC\CTS\StaffFiles\Classroom Technology\Projects';

  /// What a Projects folder holds, used to recognise it.
  static const String _marker = 'Configurator_Files';

  /// Where the picked folder is on this device, or null when none is in use.
  static String? localRoot;

  /// The share path [localRoot] stands for, e.g. \\doit-files\ATEC.
  static String? uncRoot;

  /// True on iOS with a folder picked (live or offline).
  static bool get active => localRoot != null && uncRoot != null;

  /// The share didn't answer: share paths point at [mirrorRoot].
  static bool offline = false;

  /// Why the share isn't in use right now, for the user; null when it is,
  /// or when none was picked.
  static String? problem;

  /// Told when [offline] or the picked folder changes.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static void _changed() => changes.value++;

  /// How long the share may take to answer before it counts as unreachable.
  /// iOS's SMB connection can stall for minutes after the app restarts or the
  /// VPN drops, and nothing may wait on it that long (a frozen screen).
  static const Duration answerWithin = Duration(seconds: 5);

  /// The app's own folder for what it keeps about the share (Library, which
  /// the Files app doesn't show and iOS doesn't clear).
  static String get _dataDir =>
      dataDirForTest ?? userDataDirOrNull() ?? Directory.systemTemp.path;

  /// For a test: where the copy and what is remembered about the share go.
  @visibleForTesting
  static String? dataDirForTest;

  /// Where the offline copy lives, laid out like the share from [shareUnc].
  static String get mirrorRoot => p.join(_dataDir, 'share_copy');

  /// Remembers the picked folder's place on this device between runs.
  static String get _rootFile => p.join(_dataDir, 'ios_share.txt');

  /// Where the folder was on the last run, when iOS has since moved it (an
  /// SMB mount's path can change between runs).
  static String? _previousRoot;

  // ---------------------------------------------------------------------
  //  Picking and reopening
  // ---------------------------------------------------------------------

  /// Re-opens the folder picked on an earlier run. Call once at startup.
  /// Never waits more than about [answerWithin]: a share that doesn't answer
  /// leaves the app on the offline copy, with [problem] saying why.
  static Future<void> restore() async {
    if (!Platform.isIOS) return;
    problem = null;
    try {
      final String? path = await _channel
          .invokeMethod<String>('restore')
          .timeout(answerWithin);
      if (path == null) {
        // The bookmark is gone but a copy may be kept: work from that.
        if (_goOffline()) problem = _offlineProblem();
        return;
      }
      if (await _use(path) == _Match.unreachable) {
        problem = _goOffline() ? _offlineProblem() : _unreachableProblem;
      }
    } catch (_) {
      problem = _goOffline()
          ? _offlineProblem()
          : 'The CTS share could not be reopened. Choose Connect to the CTS '
                'Share to pick it again.';
    }
    _changed();
  }

  /// Shows the Files folder picker. Returns null when a usable folder was
  /// picked, else a message for the user ('' when cancelled).
  static Future<String?> pick() async {
    if (!Platform.isIOS) return 'Only used on iPhone and iPad.';
    final String? path;
    try {
      path = await _channel.invokeMethod<String>('pick');
    } on PlatformException catch (e) {
      return e.message ?? 'The folder could not be opened.';
    }
    if (path == null) return '';
    switch (await _use(path)) {
      case _Match.found:
        problem = null;
        _changed();
        return null;
      case _Match.unreachable:
        return 'The share did not answer. Check you are on campus Wi-Fi or '
            'the VPN, open it once in the Files app, then try again.';
      case _Match.notShare:
        await clear();
        return 'That folder is not the CTS share. Pick Classroom Technology '
            '(ATEC > CTS > StaffFiles > Classroom Technology) on doit-files.';
    }
  }

  /// Forgets the picked folder. The offline copy is kept.
  static Future<void> clear() async {
    localRoot = null;
    uncRoot = null;
    offline = false;
    try {
      final f = File(_rootFile);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    _changed();
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('clear');
    } catch (_) {}
  }

  /// "iPad-1A2B": a name for this device in team presence, where iOS's own
  /// host name is just "localhost". Null off iOS.
  static Future<String?> deviceName() async {
    if (!Platform.isIOS) return null;
    try {
      return await _channel
          .invokeMethod<String>('deviceName')
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  /// Shows [file] in iOS Quick Look - the iPad's and iPhone's stand-in for
  /// "open with the default program". Null when it opened, else a message
  /// for the person.
  static Future<String?> preview(String file) async {
    if (!Platform.isIOS) return 'Not on iOS';
    try {
      return await _channel.invokeMethod<String>('preview', {'path': file});
    } catch (e) {
      return 'Could not open ${p.basename(file)}';
    }
  }

  /// Whether the share answers right now, within [timeout]. Answering ends
  /// offline use: paths point at the share again.
  static Future<bool> checkReachable({Duration timeout = answerWithin}) async {
    if (!active) return false;
    final String dir = p.join(_translateOnline(projectsUnc), _marker);
    final bool ok = await _dirExists(dir, timeout) ?? false;
    if (ok != !offline) {
      offline = !ok;
      problem = ok ? null : _offlineProblem();
      _changed();
    }
    return ok;
  }

  /// Matches [path] to a level of the share and starts using it.
  static Future<_Match> _use(String path) async {
    final String root = path.replaceFirst(RegExp(r'/+$'), '');
    final List<String> parts = projectsUnc.substring(2).split(r'\');
    // parts[0] is the server; the shallowest folder that can be picked is
    // the share (parts[1]), the deepest the Projects folder.
    for (int level = 1; level < parts.length; level++) {
      final String below = parts.sublist(level + 1).join('/');
      final String projects = below.isEmpty ? root : '$root/$below';
      final bool? found = await _dirExists('$projects/$_marker', answerWithin);
      if (found == null) return _Match.unreachable;
      if (found) {
        localRoot = root;
        uncRoot = r'\\' + parts.sublist(0, level + 1).join(r'\');
        offline = false;
        _remember(root);
        return _Match.found;
      }
    }
    return _Match.notShare;
  }

  /// Keeps [root] and its share path for the next run.
  static void _remember(String root) {
    try {
      final File f = File(_rootFile);
      final String last = f.existsSync()
          ? (f.readAsLinesSync().firstOrNull ?? '').trim()
          : '';
      _previousRoot = last.isNotEmpty && last != root ? last : null;
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('$root\n${uncRoot ?? ''}');
    } catch (_) {}
  }

  /// Goes offline on the folder remembered from an earlier run, so share
  /// paths point at the copy. False when nothing is remembered.
  static bool _goOffline() {
    try {
      final File f = File(_rootFile);
      if (!f.existsSync()) return false;
      final List<String> lines = f.readAsLinesSync();
      if (lines.length < 2 || lines[0].trim().isEmpty) return false;
      localRoot = lines[0].trim();
      uncRoot = lines[1].trim();
      offline = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  static const String _unreachableProblem =
      'The CTS share did not answer. On campus Wi-Fi or the VPN, open the '
      'Files app and tap the doit-files server to reconnect.';

  static String _offlineProblem() =>
      'Working offline: the CTS share did not answer, so files come from the '
      'copy kept on this device. Changes are kept and sent to the share when '
      'it answers again (campus Wi-Fi or the VPN, and the doit-files server '
      'opened once in the Files app).';

  static Future<bool?> _dirExists(String path, Duration timeout) async {
    try {
      return await Directory(path).exists().timeout(timeout);
    } on TimeoutException {
      return null;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------
  //  Paths
  // ---------------------------------------------------------------------

  /// The share's top (\\doit-files\ATEC) on this device, worked out from the
  /// picked folder and how deep it is.
  static String? get shareLocalRoot {
    final String? local = localRoot, unc = uncRoot;
    if (local == null || unc == null) return null;
    final int below = unc.substring(2).split('\\').length - 2;
    // The host's own separator: / on the iPad, \ in a test on Windows.
    final List<String> parts = p.split(local);
    if (below < 0 || below >= parts.length) return null;
    return p.joinAll(parts.sublist(0, parts.length - below));
  }

  /// True when [path] is [base] or inside it.
  static bool _under(String base, String path) =>
      path == base || p.isWithin(base, path);

  /// [base] with a share-relative '/a/b' [rest] under it, in the host's
  /// separators.
  static String _joinRest(String base, String rest) {
    final List<String> segs = [
      for (final String s in rest.split(RegExp(r'[\\/]')))
        if (s.isNotEmpty) s,
    ];
    return segs.isEmpty ? base : p.joinAll([base, ...segs]);
  }

  /// True when the picked folder holds the team folder (Dashboard\team) as
  /// well as Projects - Classroom Technology or above. iOS only lets the app
  /// into the folder that was picked, so a Projects pick has no chat.
  static bool get coversClassroomTechnology {
    final String? unc = uncRoot;
    if (unc == null) return false;
    final String want = _normalizeUnc(
      r'\\doit-files\ATEC\CTS\StaffFiles\Classroom Technology',
    );
    final String have = _normalizeUnc(unc);
    return want == have || want.startsWith('$have\\');
  }

  /// [path] with a \\doit-files\ATEC\... prefix replaced by its place on this
  /// device: under the picked folder while the share answers, in the offline
  /// copy while it doesn't. A path already in one of the two moves to the
  /// other when that changes. Anything else comes back as it is.
  static String translate(String path) {
    if (!active || path.isEmpty) return path;
    final String online = _translateOnline(path);
    final String? top = shareLocalRoot;
    if (top == null) return online;
    final String mirror = mirrorRoot;
    if (offline && _under(top, online)) {
      return _joinRest(mirror, p.relative(online, from: top));
    }
    if (!offline && _under(mirror, online)) {
      return _joinRest(top, p.relative(online, from: mirror));
    }
    return online;
  }

  static String _translateOnline(String path) {
    final String? local = localRoot;
    final String? top = shareLocalRoot;
    if (local == null || top == null) return path;
    final String? old = _previousRoot;
    if (old != null && _under(old, path)) {
      return _joinRest(local, p.relative(path, from: old));
    }
    if (!path.startsWith(r'\\') && !path.startsWith('//')) return path;
    final String norm = _normalizeUnc(path);
    final String share = _normalizeUnc(shareUnc);
    if (norm != share && !norm.startsWith('$share\\')) return path;
    return _joinRest(top, path.substring(_prefixLength(path, shareUnc)));
  }

  /// [path] under the picked folder or the offline copy as its \\doit-files
  /// path; anything else as it was.
  static String toUnc(String path) {
    if (!active || path.isEmpty) return path;
    for (final String? base in [shareLocalRoot, mirrorRoot]) {
      if (base == null) continue;
      if (_under(base, path)) {
        final String rest =
            path.substring(base.length).replaceAll('/', '\\');
        return '$shareUnc$rest';
      }
    }
    return path;
  }

  /// Where [path] (a share path, or a path under the picked folder or in the
  /// copy) is kept in the offline copy; null for anything else.
  static String? mirrorPathFor(String path) {
    final String? rest = _restOf(path);
    return rest == null ? null : _joinRest(mirrorRoot, rest);
  }

  /// Where [path] (a share path, or a path under the picked folder or in the
  /// copy) is on the live share; null for anything else.
  static String? livePathFor(String path) {
    final String? top = shareLocalRoot;
    final String? rest = _restOf(path);
    return top == null || rest == null ? null : _joinRest(top, rest);
  }

  /// [path] below \\doit-files\ATEC as '/a/b', '' for the share's top; null
  /// when it isn't on the share.
  static String? _restOf(String path) {
    if (!active) return null;
    final String unc = path.startsWith(r'\\') || path.startsWith('//')
        ? path
        : toUnc(path);
    final String norm = _normalizeUnc(unc);
    final String share = _normalizeUnc(shareUnc);
    if (norm != share && !norm.startsWith('$share\\')) return null;
    final String rest = unc
        .substring(_prefixLength(unc, shareUnc))
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    return rest.isEmpty || rest.startsWith('/') ? rest : '/$rest';
  }

  /// Lower case, the server's domain dropped (doit-files.csuchico.edu is
  /// doit-files), / as \.
  static String _normalizeUnc(String path) {
    final String s = path.replaceAll('/', '\\').toLowerCase();
    return s.replaceFirstMapped(
        RegExp(r'^(\\\\[^\\.]+)\.[^\\]*'), (m) => m[1]!);
  }

  /// How many characters of [path] the share prefix [unc] covers, allowing
  /// for the server written with its domain.
  static int _prefixLength(String path, String unc) {
    final List<String> want = unc.substring(2).split('\\');
    final List<String> got = path.substring(2).split(RegExp(r'[\\/]'));
    int len = 2;
    for (int i = 0; i < want.length && i < got.length; i++) {
      len += got[i].length + (i == 0 ? 0 : 1);
    }
    return len;
  }

  /// For a test: points the share at [local] for [unc] without the picker.
  static void useForTest(String? local, {String unc = shareUnc}) {
    localRoot = local;
    uncRoot = local == null ? null : unc;
    offline = false;
    _previousRoot = null;
  }
}

enum _Match { found, notShare, unreachable }
