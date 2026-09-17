// ============================================================================
// [FEATURE - APP UPDATES]: Watches the release folder on the file share for a
// newer build of this app and, when the user asks, installs it and restarts.
//
// The same lib/updater/ folder is copied, unchanged, into every CTS Flutter
// app (CTS Dashboard, Room Config Builder, Instructor Contact, Geo Guess,
// Quizzer). Fix it in one and copy the folder to the others.
//
// How a release is found:
//   * The folder is listed for zips whose name starts with the app's release
//     prefix, e.g. `cts_dashboard_9_11_2026.zip` for the prefix
//     `cts_dashboard`. It is [FolderUpdater.defaultReleaseFolder] unless
//     Settings -> App Updates -> Release folder points somewhere else, which
//     is remembered per app and survives an update.
//   * The zip must hold this app's exe - at its root or inside one top-level
//     folder. The VERSION STAMPED INTO THAT EXE is the release's version (it
//     is pubspec.yaml's `version:`, which Flutter writes into the exe), so the
//     date in the file name is only for people. A release that does not bump
//     `version:` (the build number after `+` counts) is not an update.
//
// Nothing is ever installed without the user asking: a check only raises a
// notice. Installing copies the zip to %LOCALAPPDATA%, unpacks it, and hands
// over to a small PowerShell helper that waits for the app to close, swaps the
// program files, and starts the new version. See update_platform_io.dart for
// which files are replaced and which are left alone.
// ============================================================================

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'update_platform_stub.dart'
    if (dart.library.io) 'update_platform_io.dart' as platform;

/// A four-part build version: `major.minor.patch+build`, the shape of
/// pubspec.yaml's `version:` and of the version resource in a Windows exe.
@immutable
class AppBuildVersion implements Comparable<AppBuildVersion> {
  final int major;
  final int minor;
  final int patch;
  final int build;

  const AppBuildVersion(this.major, this.minor, this.patch, [this.build = 0]);

  /// Accepts `1.2.3`, `1.2.3+4`, `1.2.3.4` and `v1.2`. Null when [text] is not
  /// a version.
  static AppBuildVersion? tryParse(String text) {
    final m = RegExp(r'^\s*v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:[+.](\d+))?\s*$')
        .firstMatch(text);
    if (m == null) return null;
    int part(int i) => int.parse(m.group(i) ?? '0');
    return AppBuildVersion(part(1), part(2), part(3), part(4));
  }

  @override
  int compareTo(AppBuildVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    return build.compareTo(other.build);
  }

  bool operator >(AppBuildVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppBuildVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, build);

  /// `1.2.3`, or `1.2.3+4` when there is a build number.
  @override
  String toString() =>
      build == 0 ? '$major.$minor.$patch' : '$major.$minor.$patch+$build';
}

/// A release zip in the release folder that is newer than the running app.
@immutable
class AvailableUpdate {
  final AppBuildVersion version;
  final String zipPath;
  final int sizeBytes;
  final DateTime modified;

  /// The folder inside the zip that holds the exe: `''` for the zip's root,
  /// otherwise the top-level folder name with a trailing `/`.
  final String payloadRoot;

  const AvailableUpdate({
    required this.version,
    required this.zipPath,
    required this.sizeBytes,
    required this.modified,
    required this.payloadRoot,
  });

  String get fileName => zipPath.split(RegExp(r'[\\/]')).last;
}

/// What the most recent install attempt did, reported by the helper that ran
/// while the app was closed and read back when the app starts again.
@immutable
class UpdateOutcome {
  final bool succeeded;
  final String message;
  final String fromVersion;
  final String toVersion;

  const UpdateOutcome({
    required this.succeeded,
    required this.message,
    required this.fromVersion,
    required this.toVersion,
  });
}

/// One step of an install, for the progress bar.
@immutable
class UpdateProgress {
  final String stage;

  /// 0..1, or null for a step with no measurable progress.
  final double? fraction;

  const UpdateProgress(this.stage, [this.fraction]);
}

/// Thrown by a check when the release folder cannot be listed.
class ReleaseFolderUnavailable implements Exception {
  final String folder;
  final Object? cause;

  const ReleaseFolderUnavailable(this.folder, [this.cause]);

  @override
  String toString() => "Can't reach the release folder $folder";
}

enum UpdateStatus {
  /// Not started, or this platform/build cannot update itself.
  idle,
  checking,
  upToDate,
  available,

  /// The release folder could not be listed - off the network, no VPN, or no
  /// access. Not an error worth interrupting anyone for.
  folderUnavailable,
  error,
  installing,
}

/// Owns the update check timer and everything the update UI shows.
class FolderUpdater extends ChangeNotifier {
  static const String defaultReleaseFolder =
      r'\\doit-files\ATEC\CTS\StaffFiles\Program_Releases';

  /// Set this environment variable to watch a different folder - for trying
  /// a release out before it is copied to the share. It wins over the folder
  /// chosen in Settings, which is why that field locks while it is set.
  static const String folderEnvironmentVariable = 'CTS_UPDATE_FOLDER';

  /// The name people know the app by, for the notice text.
  final String appName;

  /// Release zips must start with this, e.g. `cts_dashboard`.
  final String releasePrefix;

  final Duration checkInterval;
  final Duration firstCheckDelay;

  /// Asked just before the app closes to install - the place to offer to
  /// save unsaved work. Returning false cancels the install.
  final Future<bool> Function()? confirmClose;

  /// Runs after the helper has started and just before the process exits -
  /// the place to flush logs.
  final Future<void> Function()? beforeExit;

  /// Command-line arguments to start the new version with.
  final List<String> relaunchArguments;

  final void Function(String message)? log;

  FolderUpdater({
    required this.appName,
    required this.releasePrefix,
    String releaseFolder = defaultReleaseFolder,
    this.checkInterval = const Duration(minutes: 30),
    this.firstCheckDelay = const Duration(seconds: 20),
    this.confirmClose,
    this.beforeExit,
    this.relaunchArguments = const [],
    this.log,
  })  : _builtInReleaseFolder = releaseFolder,
        _releaseFolder = platform.releaseFolderOverride() ??
            platform.readSavedReleaseFolder() ??
            releaseFolder;

  /// The folder this app was built to watch, before anything the user chose
  /// in Settings. [resetReleaseFolder] goes back to it.
  final String _builtInReleaseFolder;
  String get builtInReleaseFolder => _builtInReleaseFolder;

  String _releaseFolder;

  /// The folder being watched: the [folderEnvironmentVariable] if it is set,
  /// otherwise the one chosen in Settings, otherwise the built-in default.
  String get releaseFolder => _releaseFolder;

  /// Points the app at another folder and remembers it for the next launch.
  /// Blank, or the folder already in use, does nothing. A new folder is
  /// checked straight away, so Settings shows what is there without waiting
  /// for the next half-hourly check.
  set releaseFolder(String value) {
    final v = value.trim();
    if (v.isEmpty || v == _releaseFolder) return;
    _releaseFolder = v;
    platform.writeSavedReleaseFolder(v);
    _available = null;
    _dismissedVersion = null;
    notifyListeners();
    unawaited(checkNow());
  }

  /// True when [folderEnvironmentVariable] is set. It wins over Settings, so
  /// the Settings field is shown but not editable while it is.
  bool get releaseFolderIsLocked => platform.releaseFolderOverride() != null;

  /// True when the app chose this folder rather than being built with it.
  bool get releaseFolderIsCustom => _releaseFolder != _builtInReleaseFolder;

  /// Whether the folder can be seen from this computer right now. False off
  /// the VPN, or when the path is wrong.
  bool get releaseFolderReachable => platform.folderExists(_releaseFolder);

  /// Forgets the folder chosen in Settings and goes back to the built-in one.
  void resetReleaseFolder() {
    platform.writeSavedReleaseFolder(null);
    if (releaseFolderIsLocked || _releaseFolder == _builtInReleaseFolder) {
      notifyListeners();
      return;
    }
    _releaseFolder = _builtInReleaseFolder;
    _available = null;
    _dismissedVersion = null;
    notifyListeners();
    unawaited(checkNow());
  }

  UpdateStatus _status = UpdateStatus.idle;
  UpdateStatus get status => _status;

  AppBuildVersion? _currentVersion;

  /// The running exe's version; null until [start] has read it.
  AppBuildVersion? get currentVersion => _currentVersion;

  AvailableUpdate? _available;
  AvailableUpdate? get available => _available;

  String? _errorMessage;

  /// Why the last check or install failed.
  String? get errorMessage => _errorMessage;

  bool _installFailed = false;

  /// True when [errorMessage] came from an install rather than a check, so the
  /// notice keeps showing it.
  bool get installFailed => _installFailed;

  DateTime? _lastChecked;
  DateTime? get lastChecked => _lastChecked;

  UpdateProgress? _progress;
  UpdateProgress? get progress => _progress;

  UpdateOutcome? _lastOutcome;

  /// The result of an install that finished while the app was closed. Shown
  /// once, then cleared with [clearOutcome].
  UpdateOutcome? get lastOutcome => _lastOutcome;

  AppBuildVersion? _dismissedVersion;
  bool _confirming = false;

  /// True while the notice is asking "close and update now?".
  bool get confirming => _confirming;

  /// Whether this platform can check for updates at all (Windows desktop).
  bool get isSupported => platform.updatesSupported;

  /// Whether this build may install one. Debug and profile builds run out of
  /// build/, and replacing those with a release build helps nobody.
  bool get canInstall => platform.updatesSupported && kReleaseMode;

  /// Whether the corner notice should be showing.
  bool get showNotice =>
      _lastOutcome != null ||
      _status == UpdateStatus.installing ||
      _installFailed ||
      _confirming ||
      (_status == UpdateStatus.available &&
          _available != null &&
          _available!.version != _dismissedVersion);

  Timer? _timer;
  Future<void>? _checking;
  bool _disposed = false;

  final Set<Object> _busyReasons = {};
  bool _checkDue = false;

  /// True while the user is in the middle of something the app should not
  /// interrupt - a game, typing, unsaved edits. The half-hourly checks wait
  /// (one that comes due runs as soon as the user is free) and
  /// [UpdateNoticeHost] keeps the offer out of sight. The check just after
  /// [start], [checkNow], and an install already asked for are not held back.
  bool get userBusy => _busyReasons.isNotEmpty;

  /// Marks the user busy, or no longer busy, for [reason] - any object, so
  /// separate parts of an app (a game screen, a UserActivityWatcher, an
  /// unsaved-work flag) can each hold the updater back without undoing each
  /// other. The user is busy while any reason is.
  void setBusy(Object reason, bool busy) {
    final wasBusy = userBusy;
    if (busy) {
      _busyReasons.add(reason);
    } else {
      _busyReasons.remove(reason);
    }
    if (userBusy == wasBusy) return;
    if (!userBusy && _checkDue) {
      _checkDue = false;
      unawaited(checkNow());
    }
    _notify();
  }

  /// Reads the running version, picks up the result of an install that just
  /// happened, and starts checking the folder on a timer.
  Future<void> start() async {
    if (!platform.updatesSupported || _timer != null) return;
    try {
      _currentVersion = await platform.readRunningVersion();
      _lastOutcome = await platform.takeLastOutcome();
      if (_lastOutcome != null) {
        _log(_lastOutcome!.succeeded
            ? 'Updated ${_lastOutcome!.fromVersion} -> ${_lastOutcome!.toVersion}.'
            : 'Update to ${_lastOutcome!.toVersion} failed: '
                '${_lastOutcome!.message}');
      }
    } catch (e) {
      _log('Could not read the running version: $e');
    }
    _notify();
    _timer = Timer.periodic(checkInterval, (_) => _timedCheck());
    // The launch check always runs: it is background I/O, and a card it
    // raises still waits for the user to be free.
    Future.delayed(firstCheckDelay, () {
      if (!_disposed) unawaited(checkNow());
    });
  }

  /// A check the timer asked for: held until the user is not [userBusy].
  void _timedCheck() {
    if (_disposed) return;
    if (userBusy) {
      _checkDue = true;
      return;
    }
    unawaited(checkNow());
  }

  /// Looks in the release folder now. Safe to call while a check is running;
  /// the calls share it.
  Future<void> checkNow() {
    if (!platform.updatesSupported || _status == UpdateStatus.installing) {
      return Future.value();
    }
    return _checking ??= _check().whenComplete(() => _checking = null);
  }

  Future<void> _check() async {
    final previous = _status;
    _status = UpdateStatus.checking;
    _notify();
    try {
      _currentVersion ??= await platform.readRunningVersion();
      final current = _currentVersion;
      if (current == null) {
        throw StateError('This build has no version resource to compare.');
      }
      final found = await platform.findNewestRelease(
        folder: _releaseFolder,
        prefix: releasePrefix,
        newerThan: current,
        log: _log,
      );
      _available = found;
      _errorMessage = null;
      _status = found == null ? UpdateStatus.upToDate : UpdateStatus.available;
      if (found != null && previous != UpdateStatus.available) {
        _log('Version ${found.version} is available: ${found.zipPath}');
      }
    } on ReleaseFolderUnavailable catch (e) {
      _status = UpdateStatus.folderUnavailable;
      _errorMessage = e.toString();
    } catch (e) {
      _status = UpdateStatus.error;
      _errorMessage = '$e';
      _log('Update check failed: $e');
    }
    _lastChecked = DateTime.now();
    _notify();
  }

  /// Hides the notice for the version it is offering. A newer release shows
  /// it again; the settings panel can still install this one.
  void dismissNotice() {
    _dismissedVersion = _available?.version;
    _confirming = false;
    _installFailed = false;
    _notify();
  }

  /// Puts the updater in the "update available" state without a folder.
  @visibleForTesting
  void debugSetAvailable(AvailableUpdate update, AppBuildVersion current) {
    _currentVersion = current;
    _available = update;
    _status = UpdateStatus.available;
    _notify();
  }

  void clearOutcome() {
    _lastOutcome = null;
    _notify();
  }

  /// Opens the notice at its "close and update now?" step.
  void requestInstall() {
    if (_available == null || _status == UpdateStatus.installing) return;
    _dismissedVersion = null;
    _installFailed = false;
    _confirming = true;
    _notify();
  }

  void cancelInstall() {
    _confirming = false;
    _notify();
  }

  /// Downloads and unpacks the available update, starts the helper that
  /// swaps the files, and closes the app. Only returns if something stopped
  /// the install; [errorMessage] says what.
  Future<void> install() async {
    final update = _available;
    final current = _currentVersion;
    if (update == null || current == null) return;
    _confirming = false;
    if (!canInstall) {
      _fail('Updates can only be installed from a release build.');
      return;
    }
    await _checking;
    _status = UpdateStatus.installing;
    _installFailed = false;
    _errorMessage = null;
    _progress = const UpdateProgress('Preparing…');
    _notify();
    _log('Installing ${update.version} from ${update.zipPath}');
    try {
      final staged = await platform.stageUpdate(
        update,
        onProgress: (p) {
          _progress = p;
          _notify();
        },
      );
      if (confirmClose != null) {
        _progress = const UpdateProgress('Waiting to close…');
        _notify();
        if (!await confirmClose!()) {
          _status = UpdateStatus.available;
          _progress = null;
          _log('Install cancelled before closing.');
          _notify();
          return;
        }
      }
      _progress = const UpdateProgress('Closing to finish the update…');
      _notify();
      await platform.launchHelper(
        staged,
        fromVersion: current,
        arguments: relaunchArguments,
      );
      _log('Update helper started; closing so it can replace the files.');
      if (beforeExit != null) {
        try {
          await beforeExit!();
        } catch (_) {}
      }
      platform.exitForUpdate();
    } catch (e) {
      _fail('$e');
    }
  }

  void _fail(String message) {
    _status = _available == null ? UpdateStatus.error : UpdateStatus.available;
    _installFailed = true;
    _errorMessage = message;
    _progress = null;
    _log('Update install failed: $message');
    _notify();
  }

  void _log(String message) => log?.call('[Updater] $message');

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
