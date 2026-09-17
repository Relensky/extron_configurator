import 'package:provider/provider.dart';

import 'app_logger.dart';
import 'app_state.dart';
import 'crash_session.dart';
import 'main.dart' show RoomConfigApp;
import 'save_actions.dart';
import 'updater/folder_updater.dart';

/// Watches the release folder on the file share for a newer Room Config
/// Builder and offers it in the corner of the window. Nothing installs unless
/// the user asks - see lib/updater/folder_updater.dart for how releases are
/// found and installed.
///
/// Checks once just after launch, then every half hour - but a half-hourly
/// check waits while the user is busy: typing or clicking in the last two
/// minutes (a UserActivityWatcher, started in `main`), or holding unsaved work
/// (MainDashboard). Check Now in settings is never held back.
///
/// Started from `main`, so tests never touch the share.
final FolderUpdater appUpdater = FolderUpdater(
  appName: 'Room Config Builder',
  releasePrefix: 'room_config_builder',
  // Soon after launch, before anyone is far into an edit. The check is all
  // background I/O, so it costs the first frame nothing.
  firstCheckDelay: const Duration(seconds: 3),
  // Installing closes the app, so it goes through the same "you have unsaved
  // work" question as the window's X button. Asked after the download, right
  // before closing, so nothing can be left unsaved in between.
  confirmClose: () async {
    final context = RoomConfigApp.navigatorKey.currentContext;
    if (context == null || !context.mounted) return true;
    final provider = context.read<AppStateProvider>();
    if (!provider.hasUnsavedWork) return true;
    return confirmCloseWithUnsavedWork(context, provider);
  },
  // exit(0) skips the runner's normal close; without this the next start
  // would log the update as a crash.
  beforeExit: () async => endCrashSession(),
  log: (message) => AppLogger.logInfo(message),
);
