import 'dart:async';

import 'package:extron_configurator/app_state.dart';

/// Runs before every test file. Most tests open rooms saved the older way
/// and check their paths, so opening a room does not move it into its own
/// folder unless a test turns that on (room_folder_layout_test.dart does).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AppStateProvider.moveRoomsIntoFolders = false;
  await testMain();
}
