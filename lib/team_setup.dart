import 'package:path/path.dart' as path;

import 'app_logger.dart';
import 'app_paths.dart';
import 'in_app_browser.dart';
import 'team/team_host.dart';

// ============================================================================
// [TEAM KIT - ROOM CONFIG BUILDER ADAPTER]: what lib/team/ (shared with the
// CTS Dashboard and Instructor Contact - see team/team_host.dart) needs from
// this app. Kept OUTSIDE lib/team so that folder stays byte-identical.
// ============================================================================

void setUpTeamKit() {
  TeamHost.appId = 'configurator';
  // The chat's own settings (its mode, sizes and where its panel was left)
  // in a small file of their own beside app_config.json.
  final dir = userDataDirOrNull();
  if (dir != null) {
    TeamHost.useSettingsFile(path.join(dir, 'team_chat_settings.json'));
  }
  TeamHost.log = (m) => AppLogger.logData(m);
  TeamHost.reservedEdges = InAppBrowser.reserved;
}
