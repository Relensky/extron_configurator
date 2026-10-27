import 'package:flutter_test/flutter_test.dart';

import 'package:extron_configurator/app_state.dart';
import 'package:extron_configurator/hover_fade.dart';

/// App Config's "Team chat in the top bar": the chat's button moves from the
/// corner to the top bar, as in the CTS Dashboard.
void main() {
  tearDown(() => teamChatInTopBar.value = false);

  test('off by default; switching it tells the hover button', () {
    final p = AppStateProvider(autoLoadSettings: false);
    expect(p.teamChatInTopBar, isFalse);
    p.setTeamChatInTopBar(true);
    expect(p.teamChatInTopBar, isTrue);
    expect(teamChatInTopBar.value, isTrue);
    p.setTeamChatInTopBar(false);
    expect(teamChatInTopBar.value, isFalse);
  });
}
