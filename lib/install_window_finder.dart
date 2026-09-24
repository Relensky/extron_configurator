import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'class_schedule.dart';
import 'install_windows.dart';
import 'project_schedule.dart' show formatScheduleDate;

/// ============================================================================
///  FINDING INSTALL WINDOWS - the job's rooms against the class schedule
/// ============================================================================
///  Pick the job's rooms, a date range and how long a window has to be; every
///  free stretch in each room is listed by day. Clicking one puts it on the
///  project's timeline, and clicking it again takes it off.
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

Future<void> showInstallWindowFinder(BuildContext context) async {
  final provider = context.read<AppStateProvider>();
  if (provider.classSchedule.isEmpty) await provider.loadClassSchedule();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => const Dialog.fullscreen(child: _InstallWindowFinder()),
  );
}

class _InstallWindowFinder extends StatefulWidget {
  const _InstallWindowFinder();

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

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, now.day);
    _to = _from.add(const Duration(days: 90));
    final provider = context.read<AppStateProvider>();
    // Every room the schedule knows about starts ticked.
    for (final r in projectInstallRooms(provider)) {
      if (provider.classSchedule.hasRoom(r.code)) _selected.add(r.id);
    }
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

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppStateProvider>();
    final theme = Theme.of(context);
    final schedule = provider.classSchedule;
    final rooms = projectInstallRooms(provider);
    final windows = provider.project.installWindows;

    InstallWindow? added(InstallRoom r, InstallGap g) {
      for (final w in windows) {
        if (w.sameSlot(r.id, g.day, g.startMinutes, g.endMinutes)) return w;
      }
      return null;
    }

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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Find install windows'),
        leading: IconButton(
          key: const ValueKey('install_finder_close'),
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => Navigator.pop(context),
        ),
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
          const Divider(height: 16),
          Expanded(
            child: rooms.isEmpty
                ? const Center(child: Text('This project has no rooms yet.'))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    children: [
                      for (final r in rooms)
                        if (_selected.contains(r.id))
                          _roomSection(r, schedule, added, provider),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _roomSection(
    InstallRoom r,
    ClassScheduleIndex schedule,
    InstallWindow? Function(InstallRoom, InstallGap) added,
    AppStateProvider provider,
  ) {
    final theme = Theme.of(context);
    var gaps = findInstallGaps(
      schedule.classesIn(r.code),
      from: _from,
      to: _to,
      dayStart: _dayStart,
      dayEnd: _dayEnd,
      minMinutes: _minMinutes,
      skipWeekends: !_weekends,
    );
    if (_wholeDaysOnly) gaps = gaps.where((g) => g.wholeDay).toList();

    final byDay = <DateTime, List<InstallGap>>{};
    for (final g in gaps) {
      (byDay[g.day] ??= []).add(g);
    }

    return Card(
      key: ValueKey('install_section_${r.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.label, style: theme.textTheme.titleMedium),
            Text(
              '${schedule.classesIn(r.code).length} class sections on the '
              'schedule · ${gaps.length} window${gaps.length == 1 ? '' : 's'} '
              'in range. Click a window to put it on the timeline.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (byDay.isEmpty)
              const Text('No free windows that long in this range.'),
            for (final e in byDay.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 150,
                      child: Text(
                        '${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][e.key.weekday - 1]} '
                        '${formatScheduleDate(e.key)}',
                      ),
                    ),
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final g in e.value)
                            Builder(builder: (context) {
                              final existing = added(r, g);
                              return FilterChip(
                                key: ValueKey(
                                  'install_gap_${r.id}_${g.day.toIso8601String()}_${g.startMinutes}',
                                ),
                                label: Text(g.timeLabel),
                                selected: existing != null,
                                showCheckmark: true,
                                tooltip: existing != null
                                    ? 'On the timeline - click to take it off'
                                    : 'Add this window to the timeline',
                                onSelected: (_) {
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
                                },
                              );
                            }),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
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
                  'and lists when each room on this job is free; click a '
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
                  subtitle: Text(
                    '${const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][w.day.weekday - 1]} '
                    '${formatScheduleDate(w.day)} · ${w.timeLabel}',
                  ),
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
