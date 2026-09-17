// ============================================================================
// [FEATURE - APP UPDATES]: stand-in for update_platform_io.dart on platforms
// without dart:io (web). Updates are simply not offered there.
// ============================================================================

import 'folder_updater.dart';

bool get updatesSupported => false;

String? releaseFolderOverride() => null;

String? readSavedReleaseFolder() => null;

void writeSavedReleaseFolder(String? folder) {}

bool folderExists(String path) => false;

Future<AppBuildVersion?> readRunningVersion() async => null;

Future<AvailableUpdate?> findNewestRelease({
  required String folder,
  required String prefix,
  required AppBuildVersion newerThan,
  void Function(String)? log,
}) async =>
    null;

class StagedUpdate {
  const StagedUpdate();
}

Future<StagedUpdate> stageUpdate(
  AvailableUpdate update, {
  required void Function(UpdateProgress) onProgress,
}) =>
    throw UnsupportedError('Updates are not supported on this platform.');

Future<void> launchHelper(
  StagedUpdate staged, {
  required AppBuildVersion fromVersion,
  required List<String> arguments,
}) =>
    throw UnsupportedError('Updates are not supported on this platform.');

Never exitForUpdate() =>
    throw UnsupportedError('Updates are not supported on this platform.');

Future<UpdateOutcome?> takeLastOutcome() async => null;
