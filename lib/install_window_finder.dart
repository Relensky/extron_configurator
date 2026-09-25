import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';

import 'app_snack.dart';
import 'app_state.dart';
import 'class_schedule.dart';
import 'install_windows.dart';
import 'project_schedule.dart' show formatScheduleDate;
import 'report_tools.dart';
import 'screenshot_tools.dart';
import 'xlsx_writer.dart';

/// ============================================================================
///  FINDING INSTALL WINDOWS - the job's rooms against the class schedule
/// ============================================================================
///  Pick the job's rooms, a date range and how long a window has to be. The
///  Timeline view draws each day as a row, classes as blocks and the free
///  stretches between them (the same picture as the debugger's Room
///  Timeline); the List view lists the free stretches by day. Clicking a
///  window puts it on the project's timeline, and clicking it again takes it
///  off.
/// ============================================================================

/// A room on the job, as the class schedule knows it.
class InstallRoom {
  final String id;
  final String label;

  /// Building code and room number - `BSS 103` - the key into the schedule.
  final String code;

  const InstallRoom({required this.id, required this.label, required this.code});
}

/// Every room on the open job, drawn ones first then line items.
List<InstallRoom> projectInstallRooms(AppStateProvider provider) {
  final out = <InstallRoom>[];
  final estimate = provider.priceProject();
  for (final r in estimate.rooms) {
    final code = r.room.roomCode.isNotEmpty ? r.room.roomCode : r.ref.label;
    final title = r.room.title.trim();
    out.add(InstallRoom(
      id: r.ref.id,
      code: code,
      label: title.isEmpty || title == code ? code : '$code - $title',
    ));
  }
  for (final m in provider.project.manualRooms) {
    out.add(InstallRoom(id: m.id, code: m.name, label: m.name));
  }
  return out;
}

/// Timeline or List, kept for the session.
bool _sessionTimeline = true;

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _dayLabel(DateTime d) =>
    '${_weekdays[d.weekday - 1]} ${formatScheduleDate(d)}';

/// `1 Feb` - the row labels, where the room header already gives the year.
String _shortDay(DateTime d) =>
    '${_weekdays[d.weekday - 1]} ${formatScheduleDate(d).replaceFirst(RegExp(r' \d{4}$'), '')}';

String _hm(int mins) {
  final h = mins ~/ 60, m = mins % 60;
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

String _clock(int mins) {
  final h = mins ~/ 60;
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12${h < 12 ? 'a' : 'p'}';
}

/// [from] starts the date range somewhere other than today.
Future<void> showInstallWindowFinder(BuildContext context,
    {DateTime? from}) async {
  final provider = context.read<AppStateProvider>();
  if (provider.classSchedule.isEmpty) await provider.loadClassSchedule();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => Dialog.fullscreen(child: _InstallWindowFinder(from: from)),
  );
}

class _InstallWindowFinder extends StatefulWidget {
  final DateTime? from;

  const _InstallWindowFinder({this.from});

  @override
  State<_InstallWindowFinder> createState() => _InstallWindowFinderState();
}

class _InstallWindowFinderState extends State<_InstallWindowFinder> {
  late DateTime _from;
  late DateTime _to;
  int _minMinutes = 120;
  int _dayStart = 7 * 60;
  int _dayEnd = 22 * 60;
  bool _weekends = false;
  bool _wholeDaysOnly = false;
  final Set<String> _selected = {};
  String _error = '';

  /// Each room's days, worked out once per set of choices rather than on
  /// every rebuild - adding a window rebuilds the whole finder.
  Object? _daysKey;
  final Map<String, List<RoomDay>> _days = {};

  @override
  void initState() {
    super.initState();
    final start = widget.from ?? DateTime.now();
    _from = DateTime(start.year, start.month, start.day);
    _to = _from.add(const Duration(days: 90));
    final provider = context.read<AppStateProvider>();
    // Every room the schedule knows about starts ticked.
    for (final r in projectInstallRooms(provider)) {
      if (provider.classSchedule.hasRoom(r.code)) _selected.add(r.id);
    }
  }

  List<RoomDay> _roomDays(InstallRoom r, ClassScheduleIndex schedule) {
    final key =
        (schedule, _from, _to, _dayStart, _dayEnd, _minMinutes, _weekends);
    if (key != _daysKey) {
      _days.clear();
      _daysKey = key;
    }
    return _days[r.id] ??= findRoomDays(
      schedule.classesIn(r.code),
      from: _from,
      to: _to,
      dayStart: _dayStart,
      dayEnd: _dayEnd,
      minMinutes: _minMinutes,
      skipWeekends: !_weekends,
    );
  }

  /// The days on screen for [r]: all of them, or only the free ones.
  List<RoomDay> _shownDays(InstallRoom r, ClassScheduleIndex schedule) {
    final days = _roomDays(r, schedule);
    return _wholeDaysOnly ? days.where((d) => d.free).toList() : days;
  }

  Future<void> _pickDate(bool start) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: start ? _from : _to,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      if (start) {
        _from = picked;
        if (_to.isBefore(_from)) _to = _from;
      } else {
        _to = picked.isBefore(_from) ? _from : picked;
      }
    });
  }

  Future<void> _chooseFile(AppStateProvider provider) async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Choose the class schedule export',
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    final file = picked?.files.single.path;
    if (file == null) return;
    await provider.updateSetting('classSchedulePath', file);
    final error = await provider.loadClassSchedule();
    if (!mounted) return;
    setState(() {
      _error = error;
      for (final r in projectInstallRooms(provider)) {
        if (provider.classSchedule.hasRoom(r.code)) _selected.add(r.id);
      }
    });
  }

  static String _slotKey(String roomId, DateTime d, int s, int e) =>
      '$roomId|${d.year}-${d.month}-${d.day}|$s|$e';

  void _toggle(AppStateProvider provider, InstallRoom r, InstallGap g,
      InstallWindow? existing) {
    if (existing != null) {
      provider.removeInstallWindow(existing.id);
    } else {
      provider.addInstallWindow(
        InstallWindow.create(
          roomId: r.id,
          roomLabel: r.label,
          day: g.day,
          startMinutes: g.startMinutes,
          endMinutes: g.endMinutes,
          wholeDay: g.wholeDay,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final schedule = provider.classSchedule;
    final rooms = projectInstallRooms(provider);

    // Picked windows by slot, so each gap is looked up once, not scanned for.
    final added = <String, InstallWindow>{
      for (final w in provider.project.installWindows)
        _slotKey(w.roomId, w.day, w.startMinutes, w.endMinutes): w,
    };
    InstallWindow? addedFor(InstallRoom r, InstallGap g) =>
        added[_slotKey(r.id, g.day, g.startMinutes, g.endMinutes)];

    Widget dropdown<T>(String label, T value, Map<T, String> options,
            ValueChanged<T> onChanged) =>
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$label ', style: theme.textTheme.bodyMedium),
            DropdownButton<T>(
              value: value,
              items: [
                for (final e in options.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) {
                if (v != null) setState(() => onChanged(v));
              },
            ),
          ],
        );

    final hours = {
      for (var h = 5; h <= 23; h++) h * 60: formatScheduleMinutes(h * 60),
    };

    final items = _items(rooms, schedule);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Find install windows'),
        leading: IconButton(
          key: const ValueKey('install_finder_close'),
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            key: const ValueKey('install_finder_screenshot'),
            icon: const Icon(Icons.photo_camera_outlined),
            tooltip: 'Screenshot the whole timeline (copy or annotate & save)',
            onPressed: _selected.isEmpty
                ? null
                : () => _showCapture(rooms, addedFor),
          ),
          PopupMenuButton<String>(
            key: const ValueKey('install_finder_export'),
            tooltip: 'Export',
            enabled: _selected.isNotEmpty,
            icon: const Icon(Icons.ios_share),
            onSelected: (v) => _export(v, rooms, provider),
            itemBuilder: (_) => const [
              PopupMenuItem(
                key: ValueKey('install_export_xlsx'),
                value: 'xlsx',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.grid_on),
                  title: Text('Save for Excel (.xlsx)'),
                ),
              ),
              PopupMenuItem(
                key: ValueKey('install_export_txt'),
                value: 'txt',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.description_outlined),
                  title: Text('Save as plain text (.txt)'),
                ),
              ),
              PopupMenuItem(
                key: ValueKey('install_export_copy'),
                value: 'copy',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.content_copy),
                  title: Text('Copy to the clipboard'),
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                      visualDensity: VisualDensity.compact),
                  segments: const [
                    ButtonSegment(
                      value: true,
                      icon: Icon(Icons.view_timeline_outlined, size: 18),
                      label: Text('Timeline',
                          key: ValueKey('install_view_timeline')),
                    ),
                    ButtonSegment(
                      value: false,
                      icon: Icon(Icons.view_list_outlined, size: 18),
                      label:
                          Text('List', key: ValueKey('install_view_list')),
                    ),
                  ],
                  selected: {_sessionTimeline},
                  onSelectionChanged: (v) =>
                      setState(() => _sessionTimeline = v.first),
                ),
                Text(
                  schedule.isEmpty
                      ? 'No class schedule loaded'
                      : 'Class schedule: ${schedule.roomCount} rooms, '
                          '${schedule.terms.isEmpty ? '' : '${schedule.terms.first} to ${schedule.terms.last}'}',
                  style: theme.textTheme.bodySmall,
                ),
                OutlinedButton.icon(
                  key: const ValueKey('install_finder_file'),
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: const Text('Class schedule file...'),
                  onPressed: () => _chooseFile(provider),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.event, size: 18),
                  label: Text('From ${formatScheduleDate(_from)}'),
                  onPressed: () => _pickDate(true),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.event, size: 18),
                  label: Text('To ${formatScheduleDate(_to)}'),
                  onPressed: () => _pickDate(false),
                ),
                dropdown<int>('At least', _minMinutes, const {
                  60: '1 hour',
                  120: '2 hours',
                  180: '3 hours',
                  240: '4 hours',
                  360: '6 hours',
                }, (v) => _minMinutes = v),
                dropdown<int>('Day from', _dayStart, hours, (v) {
                  _dayStart = v;
                  if (_dayEnd <= _dayStart) _dayEnd = _dayStart + 60;
                }),
                dropdown<int>('to', _dayEnd, hours, (v) {
                  _dayEnd = v <= _dayStart ? _dayStart + 60 : v;
                }),
                FilterChip(
                  label: const Text('Whole free days only'),
                  selected: _wholeDaysOnly,
                  onSelected: (v) => setState(() => _wholeDaysOnly = v),
                ),
                FilterChip(
                  label: const Text('Include weekends'),
                  selected: _weekends,
                  onSelected: (v) => setState(() => _weekends = v),
                ),
              ],
            ),
          ),
          if (_error.isNotEmpty || schedule.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error.isNotEmpty
                    ? _error
                    : 'Choose the Facilities export '
                        '(FacilitiesLinkClassScheduleDaily.csv) to see when '
                        'each room is free.',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final r in rooms)
                  FilterChip(
                    key: ValueKey('install_room_${r.id}'),
                    label: Text(r.label),
                    avatar: schedule.hasRoom(r.code)
                        ? null
                        : const Icon(Icons.help_outline, size: 16),
                    tooltip: schedule.hasRoom(r.code)
                        ? null
                        : '${r.code} is not in the class schedule - it '
                            'shows as free every day.',
                    selected: _selected.contains(r.id),
                    onSelected: (v) => setState(
                      () => v ? _selected.add(r.id) : _selected.remove(r.id),
                    ),
                  ),
              ],
            ),
          ),
          if (_sessionTimeline && rooms.isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: _Legend(),
            ),
          const Divider(height: 16),
          Expanded(
            child: rooms.isEmpty
                ? const Center(child: Text('This project has no rooms yet.'))
                : LayoutBuilder(builder: (context, c) {
                    // The timeline needs room for its hours; below that it
                    // scrolls sideways rather than squeezing the blocks.
                    const minW = 760.0;
                    final width = math.max(c.maxWidth, minW);
                    final list = ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: items.length,
                      itemBuilder: (context, i) => _buildItem(
                        items[i],
                        chartW: width - 32 - _labelW,
                        addedFor: addedFor,
                        provider: provider,
                      ),
                    );
                    if (!_sessionTimeline || c.maxWidth >= minW) return list;
                    return Scrollbar(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(width: width, child: list),
                      ),
                    );
                  }),
          ),
        ],
      ),
    );
  }

  /// The rows of the list, flattened across rooms so only what is on screen
  /// is built - three months of days for several rooms runs to hundreds.
  List<_Item> _items(List<InstallRoom> rooms, ClassScheduleIndex schedule) {
    final out = <_Item>[];
    for (final r in rooms) {
      if (!_selected.contains(r.id)) continue;
      final days = _shownDays(r, schedule);
      final windows = days.fold(0, (n, d) => n + d.gaps.length);
      final sections = {for (final d in days) ...d.classes}.length;
      out.add(_RoomHeader(r, sections, windows));

      if (!_sessionTimeline) {
        final withGaps = days.where((d) => d.gaps.isNotEmpty).toList();
        if (withGaps.isEmpty) {
          out.add(const _Note('No free windows that long in this range.'));
        }
        for (final d in withGaps) {
          out.add(_DayItem(r, d));
        }
        continue;
      }

      if (days.isEmpty) {
        out.add(const _Note('No days to show in this range.'));
        continue;
      }
      // Axis: the working day, widened to whole hours to fit any class
      // outside it.
      var from = _dayStart, to = _dayEnd;
      for (final d in days) {
        for (final c in d.classes) {
          from = math.min(from, c.startMinutes);
          to = math.max(to, c.endMinutes);
        }
      }
      final axis = _Axis((from ~/ 60) * 60, ((to + 59) ~/ 60) * 60);
      out.add(_AxisItem(axis));
      // Free days in a row - a break, the weeks between terms - share one
      // row rather than taking one each.
      for (var i = 0; i < days.length;) {
        if (!days[i].free) {
          out.add(_DayItem(r, days[i], axis));
          i++;
          continue;
        }
        var j = i;
        while (j < days.length && days[j].free) {
          j++;
        }
        out.add(j - i == 1
            ? _DayItem(r, days[i], axis)
            : _FreeRun(r, days.sublist(i, j)));
        i = j;
      }
    }
    return out;
  }

  static const double _labelW = 124, _laneH = 26, _rowPad = 5, _axisH = 22;

  Widget _buildItem(
    _Item item, {
    required double chartW,
    required InstallWindow? Function(InstallRoom, InstallGap) addedFor,
    required AppStateProvider provider,
    bool picture = false,
  }) {
    final theme = Theme.of(context);
    switch (item) {
      case _RoomHeader(:final room, :final sections, :final windows):
        return Padding(
          key: ValueKey('install_section_${room.id}'),
          padding: const EdgeInsets.only(top: 16, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(room.label, style: theme.textTheme.titleMedium),
              Text(
                '$sections class section${sections == 1 ? '' : 's'} meet '
                'here in this range · $windows window'
                '${windows == 1 ? '' : 's'}'
                // The picture is read outside the app.
                '${picture ? '' : '. Click a window to put it on the timeline'}.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        );
      case _Note(:final text):
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(text),
        );
      case _AxisItem(:final axis):
        return _axisRow(axis, chartW);
      case _DayItem(:final room, :final day, :final axis):
        return axis == null
            ? _listRow(room, day, addedFor, provider)
            : _timelineRow(room, day, axis, chartW, addedFor, provider);
      case _FreeRun(:final room, :final days):
        return _freeRunRow(room, days, addedFor, provider);
    }
  }

  // --- screenshot and export ------------------------------------------------

  String get _rangeLabel =>
      '${formatScheduleDate(_from)} to ${formatScheduleDate(_to)}';

  String _reportTitle(AppStateProvider provider) {
    final job = provider.project.name.trim();
    return 'Install windows${job.isEmpty ? '' : ' - $job'} - $_rangeLabel';
  }

  String _fileStem(AppStateProvider provider) {
    final job = provider.project.name.trim();
    return '${job.isEmpty ? 'project' : job}_install_windows_'
            '${_from.toIso8601String().split('T').first}'
        .replaceAll(RegExp(r'[^\w\-]+'), '_');
  }

  /// The picked windows first, then one section per room with every class
  /// and free window in time order.
  List<ReportSection> _reportSections(
      List<InstallRoom> rooms, AppStateProvider provider) {
    final schedule = provider.classSchedule;
    final picked = <String>{
      for (final w in provider.project.installWindows)
        _slotKey(w.roomId, w.day, w.startMinutes, w.endMinutes),
    };
    String day(DateTime d) => _weekdays[d.weekday - 1];
    final shown = [for (final r in rooms) if (_selected.contains(r.id)) r];
    final planned = [
      for (final w in provider.project.installWindows)
        if (shown.any((r) => r.id == w.roomId)) w,
    ]..sort((a, b) => a.start.compareTo(b.start));

    List<List<String>> roomRows(InstallRoom r) {
      final rows = <List<String>>[];
      for (final d in _shownDays(r, schedule)) {
        final date = formatScheduleDate(d.day);
        final events = <(int, List<String>)>[
          for (final c in d.classes)
            (
              c.startMinutes,
              [
                date,
                day(d.day),
                'Class',
                formatScheduleMinutes(c.startMinutes),
                formatScheduleMinutes(c.endMinutes),
                _hm(c.endMinutes - c.startMinutes),
                c.courseLabel,
                c.title,
                c.term,
              ],
            ),
          for (final g in d.gaps)
            (
              g.startMinutes,
              [
                date,
                day(d.day),
                picked.contains(
                        _slotKey(r.id, g.day, g.startMinutes, g.endMinutes))
                    ? 'Planned install window'
                    : g.wholeDay
                        ? 'Free all day'
                        : 'Free',
                formatScheduleMinutes(g.startMinutes),
                formatScheduleMinutes(g.endMinutes),
                _hm(g.minutes),
                '',
                '',
                '',
              ],
            ),
        ]..sort((a, b) => a.$1.compareTo(b.$1));
        rows.addAll([for (final e in events) e.$2]);
      }
      return rows;
    }

    return [
      if (planned.isNotEmpty)
        (
          title: 'Planned install windows',
          header: const ['Room', 'Date', 'Day', 'Start', 'End', 'Length'],
          rows: [
            for (final w in planned)
              [
                w.roomLabel,
                formatScheduleDate(w.day),
                day(w.day),
                w.wholeDay ? 'All day' : formatScheduleMinutes(w.startMinutes),
                w.wholeDay ? '' : formatScheduleMinutes(w.endMinutes),
                _hm(w.endMinutes - w.startMinutes),
              ],
          ],
        ),
      for (final r in shown)
        (
          title: r.label,
          header: const [
            'Date', 'Day', 'Type', 'Start', 'End', 'Length', 'Class', //
            'Title', 'Term',
          ],
          rows: roomRows(r),
        ),
    ];
  }

  Future<void> _export(
      String what, List<InstallRoom> rooms, AppStateProvider provider) async {
    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);
    final title = _reportTitle(provider);
    final sections = _reportSections(rooms, provider);
    if (what == 'copy') {
      await Clipboard.setData(
          ClipboardData(text: renderTextReport(title, sections)));
      messenger.showSnackBar(const SnackBar(
          content: Text('Install windows copied to the clipboard.')));
      return;
    }
    final ext = what == 'xlsx' ? 'xlsx' : 'txt';
    String? file = await FilePicker.saveFile(
      dialogTitle: 'Save install windows',
      fileName: '${_fileStem(provider)}.$ext',
      type: FileType.custom,
      allowedExtensions: [ext],
    );
    if (file == null) return;
    if (!file.toLowerCase().endsWith('.$ext')) file += '.$ext';
    try {
      if (ext == 'xlsx') {
        await File(file).writeAsBytes(buildXlsx([
          buildStackedReportSheet(
            sheetName: 'Install windows',
            title: title,
            sections: sections,
          ),
        ]));
      } else {
        await File(file).writeAsString(renderTextReport(title, sections));
      }
      showSavedSnackBar(
        messenger: messenger,
        theme: theme,
        provider: provider,
        message: 'Install windows saved as ${path.basename(file)}',
        savedPath: file,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Failed to save the install windows: $e'),
        backgroundColor: snackErrorFillOn(messenger),
      ));
    }
  }

  /// The whole timeline - every room and day, unscrolled - in a preview
  /// with Copy Image and Annotate & Save, like the app's other pictures.
  Future<void> _showCapture(List<InstallRoom> rooms,
      InstallWindow? Function(InstallRoom, InstallGap) addedFor) async {
    final provider = context.read<AppStateProvider>();
    final items = _items(rooms, provider.classSchedule);
    final boundaryKey = GlobalKey();
    const width = 1400.0;
    // A long range makes a tall picture: keep it inside what a GPU texture
    // can hold.
    final ratio = (16000 / (items.length * 46 + 200)).clamp(0.75, 2.0);
    final fileName = '${_fileStem(provider)}.png';
    final title = _reportTitle(provider);
    final subtitle = '$_rangeLabel · ${_selected.length} room'
        '${_selected.length == 1 ? '' : 's'} · generated ${reportTimestamp()}';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final isDark = theme.brightness == Brightness.dark;
        Future<void> copy() async {
          final bytes = await captureBoundary(boundaryKey, pixelRatio: ratio);
          if (!dialogContext.mounted) return;
          await copyPictureToClipboard(dialogContext, bytes,
              what: 'The timeline');
        }

        void annotate() => captureAndAnnotate(dialogContext, boundaryKey,
            defaultFileName: fileName, pixelRatio: ratio);

        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: isDark ? Colors.black26 : Colors.grey[200],
              // Narrow windows get icon-only buttons so they still fit.
              child: LayoutBuilder(builder: (context, c) {
                final compact = c.maxWidth < 700;
                return Row(children: [
                  const Icon(Icons.photo_camera_outlined, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Timeline screenshot',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  if (compact) ...[
                    IconButton(
                        icon: const Icon(Icons.copy),
                        tooltip: 'Copy Image',
                        onPressed: copy),
                    IconButton(
                        icon: const Icon(Icons.draw),
                        tooltip: 'Annotate & Save PNG',
                        onPressed: annotate),
                  ] else ...[
                    OutlinedButton.icon(
                      key: const ValueKey('install_capture_copy'),
                      onPressed: copy,
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy Image'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      key: const ValueKey('install_capture_annotate'),
                      onPressed: annotate,
                      icon: const Icon(Icons.draw, size: 16),
                      label: const Text('Annotate & Save PNG'),
                    ),
                  ],
                  IconButton(
                    key: const ValueKey('install_capture_close'),
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ]);
              }),
            ),
            Expanded(
              child: ZoomablePicturePreview(
                keyPrefix: 'install_capture',
                backdrop: isDark ? Colors.black45 : Colors.grey[350],
                child: RepaintBoundary(
                  key: boundaryKey,
                  // A picture: its windows are not buttons.
                  child: IgnorePointer(
                    child: Container(
                      width: width + 40,
                      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(title,
                              style: theme.textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold)),
                          Text(subtitle, style: theme.textTheme.bodySmall),
                          const SizedBox(height: 8),
                          if (_sessionTimeline) const _Legend(picture: true),
                          for (final item in items)
                            _buildItem(
                              item,
                              chartW: width - _labelW,
                              addedFor: addedFor,
                              provider: provider,
                              picture: true,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        );
      },
    );
  }

  // --- list view -------------------------------------------------------------

  Widget _listRow(
    InstallRoom r,
    RoomDay d,
    InstallWindow? Function(InstallRoom, InstallGap) addedFor,
    AppStateProvider provider,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(width: 150, child: Text(_dayLabel(d.day))),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final g in d.gaps)
                  _gapChip(r, g, g.timeLabel, addedFor(r, g), provider),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _gapChip(InstallRoom r, InstallGap g, String label,
      InstallWindow? existing, AppStateProvider provider) {
    return FilterChip(
      key: ValueKey(
        'install_gap_${r.id}_${g.day.toIso8601String()}_${g.startMinutes}',
      ),
      label: Text(label),
      selected: existing != null,
      showCheckmark: true,
      tooltip: existing != null
          ? 'On the timeline - click to take it off'
          : 'Add this window to the timeline',
      onSelected: (_) => _toggle(provider, r, g, existing),
    );
  }

  // --- timeline view ---------------------------------------------------------

  Widget _axisRow(_Axis a, double chartW) {
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    final px = chartW / (a.to - a.from);
    return SizedBox(
      height: _axisH,
      child: Stack(children: [
        for (var m = a.from; m <= a.to; m += 60)
          Positioned(
            left: _labelW + (m - a.from) * px - 14,
            top: 4,
            width: 28,
            child: Text(_clock(m),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: muted)),
          ),
      ]),
    );
  }

  Widget _timelineRow(
    InstallRoom r,
    RoomDay d,
    _Axis a,
    double chartW,
    InstallWindow? Function(InstallRoom, InstallGap) addedFor,
    AppStateProvider provider,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final grid = isDark ? Colors.white12 : Colors.black12;
    final muted = theme.textTheme.bodySmall?.color;
    final px = chartW / (a.to - a.from);
    double x(int m) => _labelW + (m - a.from) * px;

    // Overlapping sections (a half-term one sharing a slot, a cross-listed
    // course) stack in lanes rather than drawing over each other.
    final lanes = <int>[];
    final laneOf = <int>[];
    for (final c in d.classes) {
      var lane = lanes.indexWhere((end) => end <= c.startMinutes);
      if (lane == -1) {
        lane = lanes.length;
        lanes.add(c.endMinutes);
      } else {
        lanes[lane] = c.endMinutes;
      }
      laneOf.add(lane);
    }
    final h = math.max(40.0, math.max(1, lanes.length) * _laneH + _rowPad * 2);
    final classMins =
        d.classes.fold(0, (n, c) => n + c.endMinutes - c.startMinutes);
    final today = DateUtils.isSameDay(d.day, DateTime.now());
    final off = isDark ? Colors.white.withValues(alpha: 0.04) : Colors.black.withValues(alpha: 0.04);

    return Container(
      height: h,
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: grid))),
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: _labelW,
          child: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_shortDay(d.day),
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: today ? theme.colorScheme.error : null)),
                  Text(
                    d.free
                        ? 'free all day'
                        : '${d.classes.length} class'
                            '${d.classes.length == 1 ? '' : 'es'} · ${_hm(classMins)}',
                    style: TextStyle(fontSize: 10, color: muted),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Outside the working day: shaded, never a window.
        if (a.from < _dayStart)
          Positioned(
            left: x(a.from),
            width: (_dayStart - a.from) * px,
            top: 0,
            bottom: 0,
            child: ColoredBox(color: off),
          ),
        if (a.to > _dayEnd)
          Positioned(
            left: x(_dayEnd),
            width: (a.to - _dayEnd) * px,
            top: 0,
            bottom: 0,
            child: ColoredBox(color: off),
          ),
        for (var m = a.from; m <= a.to; m += 60)
          Positioned(
            left: x(m),
            top: 0,
            bottom: 0,
            child: Container(width: 1, color: grid),
          ),
        for (final g in d.gaps)
          Positioned(
            key: ValueKey(
              'install_gap_${r.id}_${g.day.toIso8601String()}_${g.startMinutes}',
            ),
            left: x(g.startMinutes) + 1,
            width: math.max(2.0, (g.endMinutes - g.startMinutes) * px - 2),
            top: _rowPad,
            bottom: _rowPad,
            child: _GapBlock(
              gap: g,
              added: addedFor(r, g) != null,
              wide: (g.endMinutes - g.startMinutes) * px,
              onTap: () => _toggle(provider, r, g, addedFor(r, g)),
            ),
          ),
        for (final (i, c) in d.classes.indexed)
          Positioned(
            left: x(c.startMinutes) + 1,
            width: math.max(2.0, (c.endMinutes - c.startMinutes) * px - 2),
            top: _rowPad + laneOf[i] * _laneH + 2,
            height: _laneH - 4,
            child: _ClassBlock(cls: c),
          ),
        if (today)
          Builder(builder: (context) {
            final now = DateTime.now();
            final m = now.hour * 60 + now.minute;
            if (m < a.from || m > a.to) return const SizedBox.shrink();
            return Positioned(
              left: x(m),
              top: 0,
              bottom: 0,
              child: Container(width: 2, color: theme.colorScheme.error),
            );
          }),
      ]),
    );
  }

  /// Several free days in a row: one row, a toggle for each day.
  Widget _freeRunRow(
    InstallRoom r,
    List<RoomDay> days,
    InstallWindow? Function(InstallRoom, InstallGap) addedFor,
    AppStateProvider provider,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final grid = isDark ? Colors.white12 : Colors.black12;
    final ink = _freeInk(isDark);
    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: grid))),
      padding: const EdgeInsets.symmetric(vertical: _rowPad),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _labelW,
            child: Padding(
              padding: const EdgeInsets.only(right: 6, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${_shortDay(days.first.day)} -',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(_shortDay(days.last.day),
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text('${days.length} free days',
                      style: TextStyle(
                          fontSize: 10,
                          color: theme.textTheme.bodySmall?.color)),
                ],
              ),
            ),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: _freeFill(isDark),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: ink.withValues(alpha: 0.45)),
              ),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final d in days)
                    for (final g in d.gaps)
                      _gapChip(r, g, _shortDay(d.day), addedFor(r, g),
                          provider),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Color _freeInk(bool isDark) => isDark ? Colors.greenAccent : Colors.green[800]!;

Color _freeFill(bool isDark) => isDark
    ? Colors.greenAccent.withValues(alpha: 0.12)
    : Colors.green.withValues(alpha: 0.10);

const List<MaterialColor> _palette = [
  Colors.blue,
  Colors.purple,
  Colors.teal,
  Colors.orange,
  Colors.indigo,
  Colors.pink,
  Colors.cyan,
  Colors.brown,
];

/// A subject keeps its color from row to row, so a course reads down the
/// weeks.
Color _subjectColor(String subject, bool isDark) {
  final c = _palette[subject.hashCode.abs() % _palette.length];
  return isDark ? c.shade300 : c.shade600;
}

class _Axis {
  final int from;
  final int to;
  const _Axis(this.from, this.to);
}

sealed class _Item {
  const _Item();
}

class _RoomHeader extends _Item {
  final InstallRoom room;
  final int sections;
  final int windows;
  const _RoomHeader(this.room, this.sections, this.windows);
}

class _Note extends _Item {
  final String text;
  const _Note(this.text);
}

class _AxisItem extends _Item {
  final _Axis axis;
  const _AxisItem(this.axis);
}

/// A day: a list row when [axis] is null, a timeline row otherwise.
class _DayItem extends _Item {
  final InstallRoom room;
  final RoomDay day;
  final _Axis? axis;
  const _DayItem(this.room, this.day, [this.axis]);
}

class _FreeRun extends _Item {
  final InstallRoom room;
  final List<RoomDay> days;
  const _FreeRun(this.room, this.days);
}

/// A class meeting in the room.
class _ClassBlock extends StatelessWidget {
  final ScheduledClass cls;

  const _ClassBlock({required this.cls});

  @override
  Widget build(BuildContext context) {
    final color = _subjectColor(
        cls.subject, Theme.of(context).brightness == Brightness.dark);
    final fg = ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    return Tooltip(
      message: '${cls.courseLabel}${cls.title.isEmpty ? '' : ' - ${cls.title}'}\n'
          '${formatScheduleMinutes(cls.startMinutes)} - '
          '${formatScheduleMinutes(cls.endMinutes)} · ${cls.days} · ${cls.term}',
      child: Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        alignment: Alignment.centerLeft,
        child: Text(
          cls.courseLabel,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
        ),
      ),
    );
  }
}

/// A free stretch: green while open, the theme's primary once it is on the
/// project's timeline.
class _GapBlock extends StatelessWidget {
  final InstallGap gap;
  final bool added;

  /// Its width in pixels, to decide whether a label fits.
  final double wide;
  final VoidCallback onTap;

  const _GapBlock({
    required this.gap,
    required this.added,
    required this.wide,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = added ? scheme.onPrimary : _freeInk(isDark);
    final label = gap.wholeDay ? 'All day' : _hm(gap.minutes);
    return Tooltip(
      message: '${gap.timeLabel} (${_hm(gap.minutes)})\n'
          '${added ? 'On the timeline - click to take it off' : 'Click to add it to the timeline'}',
      child: Material(
        color: added ? scheme.primary : _freeFill(isDark),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(
            color: added ? scheme.primary : _freeInk(isDark).withValues(alpha: 0.45),
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Center(
            child: wide < 36
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (added && wide > 64) ...[
                        Icon(Icons.check, size: 13, color: ink),
                        const SizedBox(width: 3),
                      ],
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.clip,
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: ink),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  /// Worded for a screenshot, which is read outside the app.
  final bool picture;

  const _Legend({this.picture = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Widget swatch(Color fill, Color border, String text) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16,
              height: 10,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(2),
                border: Border.all(color: border),
              ),
            ),
            const SizedBox(width: 6),
            Text(text, style: const TextStyle(fontSize: 12)),
          ],
        );
    final cls = _subjectColor('SOCI', isDark);
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        swatch(cls, cls, 'Class'),
        swatch(_freeFill(isDark), _freeInk(isDark).withValues(alpha: 0.45),
            picture ? 'Free' : 'Free - click to add'),
        swatch(scheme.primary, scheme.primary,
            picture ? 'Planned install window' : 'On the timeline'),
      ],
    );
  }
}

/// The picked windows, on the Timeline pane.
class InstallWindowsCard extends StatelessWidget {
  const InstallWindowsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final windows = [...provider.project.installWindows]
      ..sort((a, b) => a.start.compareTo(b.start));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Card(
        key: const ValueKey('install_windows_card'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A Wrap, so a narrow window drops the button under the title
              // rather than running it off the card.
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.event_available),
                      const SizedBox(width: 8),
                      Text('Install windows',
                          style: theme.textTheme.titleMedium),
                    ],
                  ),
                  FilledButton.tonalIcon(
                    key: const ValueKey('find_install_windows'),
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('Find install windows...'),
                    onPressed: () => showInstallWindowFinder(context),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (windows.isEmpty)
                Text(
                  'None yet. Find install windows reads the class schedule '
                  'and shows when each room on this job is free; click a '
                  'window to put it here.',
                  style: theme.textTheme.bodySmall,
                ),
              for (final w in windows)
                ListTile(
                  key: ValueKey('install_window_${w.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    w.wholeDay ? Icons.event_available : Icons.schedule,
                    size: 20,
                  ),
                  title: Text(w.roomLabel),
                  subtitle: Text('${_dayLabel(w.day)} · ${w.timeLabel}'),
                  trailing: IconButton(
                    tooltip: 'Take this window off the timeline',
                    icon: const Icon(Icons.close),
                    onPressed: () => provider.removeInstallWindow(w.id),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
