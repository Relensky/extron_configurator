// A build with no filesystem (the web) has no log files to show. Kept in step
// with log_viewer_io.dart so both halves of the conditional export match.
import 'log_viewer_types.dart';

const bool logViewerSupported = false;

List<LogFileInfo> listLogFiles(
  List<LogSource> sources, {
  String? currentPath,
  int limit = 40,
}) =>
    const [];

LogText readLogText(String path, {int? maxBytes}) =>
    const LogText(text: '', totalBytes: 0, error: 'No log files here.');

String machineSummary() => 'web';

String? writeLogExport(String path, String text) =>
    'Saving files is not available here.';

String defaultExportFolder() => '';

String exportPathIn(String folder, String fileName) => fileName;

Future<void> revealInFileManager(String path) async {}
