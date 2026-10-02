import 'dart:io';

import 'package:file_picker/file_picker.dart' show FileType;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'file_dialogs.dart';
import 'project_estimate.dart';
import 'project_schedule.dart';
import 'project_todo_view.dart' show TodoReminderButton;
import 'screenshot_tools.dart';
import 'timeline_export.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  EXPORTING THE TIMELINE, AND THE JOB LIST ON IT
/// ============================================================================

/// The timeline's rows for the open job - see [timelineEntries].
List<TimelineEntry> timelineEntriesFor(
  AppStateProvider provider,
  ProjectEstimate estimate,
) => timelineEntries(
  buildProjectSchedule(estimate: estimate),
  provider.project,
  roomNames: {for (final r in estimate.rooms) r.ref.id: r.codeName},
);

String _stem(AppStateProvider provider) {
  final name = provider.project.name.trim();
  return name.isEmpty ? 'project' : name.replaceAll(RegExp(r'[^\w\-]+'), '_');
}

/// Spreadsheet, list and picture, along the top of the timeline.
class TimelineExportBar extends StatelessWidget {
  final ProjectEstimate estimate;

  const TimelineExportBar({super.key, required this.estimate});

  Future<void> _spreadsheet(BuildContext context) async {
    final provider = context.read<AppStateProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final picked = await saveFileCompat(
      dialogTitle: 'Save the timeline',
      fileName: '${_stem(provider)}_Timeline.xlsx',
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
    );
    if (picked == null) return;
    final target =
        picked.toLowerCase().endsWith('.xlsx') ? picked : '$picked.xlsx';
    try {
      await File(target).writeAsBytes(
        buildXlsx([
          timelineSheet(
            provider.project.name,
            timelineEntriesFor(provider, estimate),
          ),
        ]),
      );
      if (context.mounted) {
        showSavedFileSnack(context, provider, 'The timeline', target);
      }
    } catch (e) {
      showTimedSnackBar(
        messenger,
        SnackBar(content: Text('The timeline could not be written: $e')),
      );
    }
  }

  Future<void> _list(BuildContext context, {required bool save}) async {
    final provider = context.read<AppStateProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final text = timelineText(
      provider.project.name,
      timelineEntriesFor(provider, estimate),
    );
    if (!save) {
      await Clipboard.setData(ClipboardData(text: text));
      showTimedSnackBar(
        messenger,
        const SnackBar(content: Text('The timeline is on the clipboard.')),
      );
      return;
    }
    final picked = await saveFileCompat(
      dialogTitle: 'Save the timeline as a list',
      fileName: '${_stem(provider)}_Timeline.txt',
      type: FileType.custom,
      allowedExtensions: const ['txt'],
    );
    if (picked == null) return;
    final target =
        picked.toLowerCase().endsWith('.txt') ? picked : '$picked.txt';
    try {
      await File(target).writeAsString(text);
      if (context.mounted) {
        showSavedFileSnack(context, provider, 'The timeline', target);
      }
    } catch (e) {
      showTimedSnackBar(
        messenger,
        SnackBar(content: Text('The list could not be written: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
    child: Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'Export the timeline',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        OutlinedButton.icon(
          key: const ValueKey('timeline_export_xlsx'),
          icon: const Icon(Icons.table_view, size: 18),
          label: const Text('Spreadsheet'),
          onPressed: () => _spreadsheet(context),
        ),
        OutlinedButton.icon(
          key: const ValueKey('timeline_export_list_copy'),
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          label: const Text('Copy list'),
          onPressed: () => _list(context, save: false),
        ),
        OutlinedButton.icon(
          key: const ValueKey('timeline_export_list_save'),
          icon: const Icon(Icons.list_alt, size: 18),
          label: const Text('Save list'),
          onPressed: () => _list(context, save: true),
        ),
        OutlinedButton.icon(
          key: const ValueKey('timeline_export_image'),
          icon: const Icon(Icons.image_outlined, size: 18),
          label: const Text('Picture'),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => _TimelinePictureDialog(estimate: estimate),
          ),
        ),
      ],
    ),
  );
}

/// The timeline as a picture: previewed, then saved, copied or annotated.
class _TimelinePictureDialog extends StatefulWidget {
  final ProjectEstimate estimate;

  const _TimelinePictureDialog({required this.estimate});

  @override
  State<_TimelinePictureDialog> createState() => _TimelinePictureDialogState();
}

class _TimelinePictureDialogState extends State<_TimelinePictureDialog> {
  final GlobalKey _boundary = GlobalKey();
  bool _saving = false;

  Future<Uint8List?> _capture() async {
    setState(() => _saving = true);
    try {
      return await captureBoundary(_boundary, pixelRatio: 2.0);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _failed() => showTimedSnackBar(
    ScaffoldMessenger.of(context),
    const SnackBar(content: Text('The timeline could not be captured.')),
  );

  Future<void> _save() async {
    final provider = context.read<AppStateProvider>();
    final bytes = await _capture();
    if (!mounted) return;
    if (bytes == null) return _failed();
    final picked = await saveFileCompat(
      dialogTitle: 'Save the timeline',
      fileName: '${_stem(provider)}_Timeline.png',
      type: FileType.custom,
      allowedExtensions: const ['png'],
    );
    if (picked == null) return;
    final target =
        picked.toLowerCase().endsWith('.png') ? picked : '$picked.png';
    try {
      await File(target).writeAsBytes(bytes);
      if (mounted) {
        showSavedFileSnack(context, provider, 'The timeline', target);
      }
    } catch (e) {
      if (mounted) {
        showTimedSnackBar(
          ScaffoldMessenger.of(context),
          SnackBar(content: Text('The picture could not be written: $e')),
        );
      }
    }
  }

  Future<void> _copy() async {
    final bytes = await _capture();
    if (!mounted) return;
    await copyPictureToClipboard(context, bytes, what: 'The timeline');
  }

  Future<void> _annotate() async {
    final provider = context.read<AppStateProvider>();
    final bytes = await _capture();
    if (!mounted) return;
    if (bytes == null) return _failed();
    await showAnnotationEditor(
      context,
      bytes,
      defaultFileName: '${_stem(provider)}_Timeline.png',
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    return AlertDialog(
      key: const ValueKey('timeline_image_dialog'),
      title: const Text('The timeline as a picture'),
      content: SizedBox(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.7,
        child: ZoomablePicturePreview(
          keyPrefix: 'timeline_image',
          backdrop: Theme.of(context).brightness == Brightness.dark
              ? Colors.black45
              : Colors.grey[350],
          child: RepaintBoundary(
            key: _boundary,
            child: TimelinePicture(
              title: timelineTitle(provider.project.name),
              entries: timelineEntriesFor(provider, widget.estimate),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        OutlinedButton.icon(
          onPressed: _saving ? null : _annotate,
          icon: const Icon(Icons.draw_outlined, size: 18),
          label: const Text('Annotate'),
        ),
        OutlinedButton.icon(
          onPressed: _saving ? null : _copy,
          icon: const Icon(Icons.copy_all_outlined, size: 18),
          label: const Text('Copy to clipboard'),
        ),
        FilledButton.icon(
          key: const ValueKey('timeline_save_png'),
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.download, size: 18),
          label: Text(_saving ? 'Capturing...' : 'Save as PNG'),
        ),
      ],
    );
  }
}

/// The timeline drawn as a document, on white: the dates in order, then the
/// job-list notes with no date.
class TimelinePicture extends StatelessWidget {
  final String title;
  final List<TimelineEntry> entries;

  const TimelinePicture({
    super.key,
    required this.title,
    required this.entries,
  });

  static const List<double> _widths = [96, 96, 300, 230, 220];

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF1F2933);
    const cellStyle = TextStyle(fontSize: 11, color: ink);
    const line = BorderSide(color: Color(0xFFBDBDBD), width: 0.5);
    final total = _widths.fold<double>(0, (s, w) => s + w);

    Widget cell(String text, double width, {Color? fill, TextStyle? style}) =>
        Container(
          width: width,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            color: fill,
            border: const Border(right: line, bottom: line),
          ),
          child: Text(text, style: style ?? cellStyle),
        );

    Widget header() => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < kTimelineColumns.length; i++)
          cell(
            kTimelineColumns[i],
            _widths[i],
            fill: const Color(0xFFE8EAF6),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: ink,
            ),
          ),
      ],
    );

    Widget row(TimelineEntry e, int i) => Container(
      color: i.isOdd ? const Color(0xFFF5F5F5) : Colors.white,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          cell(e.date == null ? '' : formatScheduleDate(e.date!), _widths[0]),
          cell(e.what, _widths[1]),
          cell(e.item, _widths[2]),
          cell(e.detail, _widths[3]),
          cell(e.status, _widths[4]),
        ],
      ),
    );

    Widget section(String name, List<TimelineEntry> rows) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: total,
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          color: const Color(0xFFDDE3F0),
          child: Text(
            name,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: ink,
            ),
          ),
        ),
        header(),
        for (final (i, e) in rows.indexed) row(e, i),
      ],
    );

    final dated = [for (final e in entries) if (e.date != null) e];
    final undated = [for (final e in entries) if (e.date == null) e];
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: ink,
            ),
          ),
          if (dated.isNotEmpty) section('Dates', dated),
          if (undated.isNotEmpty) section('Job list - no date', undated),
          if (entries.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text('Nothing dated yet.', style: cellStyle),
            ),
        ],
      ),
    );
  }
}

/// Every note on the job list, on the timeline: dated ones by their date,
/// then the rest, with where each has got to.
class TimelineJobList extends StatelessWidget {
  final ProjectEstimate estimate;

  const TimelineJobList({super.key, required this.estimate});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final roomNames = {for (final r in estimate.rooms) r.ref.id: r.codeName};
    final asOf = buildProjectSchedule(estimate: estimate).asOf;
    // Dated first by date, then the rest in list order.
    final all = provider.project.todos;
    final order = [for (var i = 0; i < all.length; i++) i]
      ..sort((a, b) {
        final ad = all[a].due, bd = all[b].due;
        if (ad != null && bd != null && ad != bd) return ad.compareTo(bd);
        if (ad == null && bd != null) return 1;
        if (ad != null && bd == null) return -1;
        return a.compareTo(b);
      });
    final todos = [for (final i in order) all[i]];
    if (todos.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card(
        key: const ValueKey('timeline_job_list'),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'JOB LIST (${todos.length})',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: muted,
                ),
              ),
              const SizedBox(height: 6),
              for (final t in todos)
                Builder(
                  builder: (context) {
                    final about = t.roomId.isNotEmpty
                        ? (roomNames[t.roomId] ?? '')
                        : t.scopeLabel.trim();
                    final status = todoTimelineStatus(t, asOf);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 96,
                            child: Text(
                              t.due == null
                                  ? 'No date'
                                  : formatScheduleDate(t.due!),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: muted,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              about.isEmpty
                                  ? t.text.trim()
                                  : '${t.text.trim()}  ·  $about',
                              style: theme.textTheme.bodySmall?.copyWith(
                                decoration: t.isDone
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            status,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: status == 'Past its date'
                                  ? theme.colorScheme.error
                                  : muted,
                            ),
                          ),
                          if (!t.isDone) ...[
                            const SizedBox(width: 8),
                            TodoReminderButton(
                              key: ValueKey('timeline_remind_${t.id}'),
                              todo: t,
                              provider: provider,
                              scope: about,
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
