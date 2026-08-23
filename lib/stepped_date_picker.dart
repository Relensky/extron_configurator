import 'package:flutter/material.dart';

import 'building_project.dart' show dateOnly, today;
import 'project_schedule.dart' show formatScheduleDate;

/// ============================================================================
///  PICKING A DATE BY NARROWING IT
/// ============================================================================
///  Every date in this app is months or years away from today. An order date is
///  worked back from a delivery six months out, a job note is chased next
///  quarter, a phase lands the summer after the one being planned. Almost none
///  of them are in the month the picker opens on.
///
///  The Material picker is built for the other case. It opens on a month grid
///  and offers exactly one shortcut out of it — a year list — which drops
///  straight back onto a DAY grid for the same month number in the new year. So
///  moving to March 2028 from August 2026 means picking the year, landing on
///  August 2028, and then pressing an arrow seven times. Nobody does that; they
///  press the arrow twenty times from where they started, or they mistype the
///  date into the field beside it.
///
///  So this picker narrows instead. YEAR, THEN MONTH, THEN DAY — three grids,
///  each one small enough to read at a glance, each one a single press:
///
///    * The day grid is still what it opens on, because a date inside the month
///      already on screen should still be one press away.
///    * Pressing the YEAR in the header goes up a level rather than sideways.
///      Up again from the month grid gets back to the years, so the header is a
///      route in both directions rather than a one-way trip into a year list.
///    * Picking a year hands over to the months, and picking a month to the
///      days. Nothing is committed until a DAY is pressed: a year on its own is
///      not a date, and a picker that closed on one would be inventing the rest
///      of it.
///
///  RANGE IS ENFORCED AT EVERY LEVEL, not only on the day cells. A year outside
///  the range is not offered, a month outside it is not offered, and the day
///  grid's arrows stop at the ends — so there is no path into a month whose
///  every day is refused, which is the state that makes a picker feel broken.
/// ============================================================================

/// Which grid is on screen.
enum DatePickerStep {
  /// The years in range, four to a row.
  year,

  /// The twelve months of the chosen year.
  month,

  /// The days of the chosen month — where a date is actually settled.
  day,
}

/// Month names as this app writes them everywhere else. Deliberately the same
/// three-letter forms [formatScheduleDate] uses: the grid and the answer it
/// produces have to read as the same date.
const List<String> _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// The full month name, for the header — 'March 2028' is a heading, 'Mar 2028'
/// is a cell.
const List<String> _monthFullNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Picks a date, starting on the day grid and narrowing from the year down when
/// the header is pressed.
///
/// Returns null when the user backed out. Never returns a date outside
/// [firstDate]..[lastDate], and never returns a partial one — see the file
/// header on why a year is not an answer.
Future<DateTime?> showSteppedDatePicker(
  BuildContext context, {
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  required String helpText,
  String confirmText = 'Set',
}) {
  final first = dateOnly(firstDate);
  final last = dateOnly(lastDate);
  final initial = _clampDate(dateOnly(initialDate), first, last);

  return showDialog<DateTime>(
    context: context,
    builder: (_) => _SteppedDatePickerDialog(
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      helpText: helpText,
      confirmText: confirmText,
    ),
  );
}

DateTime _clampDate(DateTime when, DateTime first, DateTime last) {
  if (when.isBefore(first)) return first;
  if (when.isAfter(last)) return last;
  return when;
}

/// Days in [month] of [year]. Day zero of the next month is the last day of
/// this one, which is the one arithmetic that gets February right without a
/// leap-year rule of its own.
int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

class _SteppedDatePickerDialog extends StatefulWidget {
  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final String helpText;
  final String confirmText;

  const _SteppedDatePickerDialog({
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
    required this.helpText,
    required this.confirmText,
  });

  @override
  State<_SteppedDatePickerDialog> createState() =>
      _SteppedDatePickerDialogState();
}

class _SteppedDatePickerDialogState extends State<_SteppedDatePickerDialog> {
  /// The date under the cursor. Always a real date in range — the day grid
  /// shows its month, the month grid its year, and Set commits it.
  late DateTime _selected = widget.initialDate;

  /// OPENS ON THE DAYS. A date inside the month already on screen has to stay
  /// one press away; the narrowing is for the other case and is one press
  /// further in.
  DatePickerStep _step = DatePickerStep.day;

  /// The year list's scroll position, held here rather than made in build:
  /// a controller built per frame is one nobody ever disposes, and it would
  /// throw the list back to its starting offset on every rebuild.
  ScrollController? _yearScroll;

  @override
  void dispose() {
    _yearScroll?.dispose();
    super.dispose();
  }

  int get _firstYear => widget.firstDate.year;
  int get _lastYear => widget.lastDate.year;

  bool _inRange(DateTime when) =>
      !when.isBefore(widget.firstDate) && !when.isAfter(widget.lastDate);

  /// True when any day of [month] in [year] can be chosen. A month with no
  /// selectable day is not offered at all — a grid that lets somebody in and
  /// then refuses every cell reads as a broken picker.
  bool _monthSelectable(int year, int month) {
    final start = DateTime(year, month, 1);
    final end = DateTime(year, month, daysInMonth(year, month));
    return !end.isBefore(widget.firstDate) && !start.isAfter(widget.lastDate);
  }

  /// Moves to [when], keeping it inside the range and inside its own month:
  /// stepping from 31 March to April has to land on the 30th rather than on
  /// 1 May, which is what DateTime's own arithmetic would do.
  void _moveTo(int year, int month, {int? day}) {
    final safeDay = (day ?? _selected.day).clamp(1, daysInMonth(year, month));
    setState(() {
      _selected = _clampDate(
        DateTime(year, month, safeDay),
        widget.firstDate,
        widget.lastDate,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      key: const ValueKey('stepped_date_picker'),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.helpText,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          // The date as it will be RECORDED, in the app's own format, so the
          // answer never has to be recognised in two different shapes.
          Text(
            formatScheduleDate(_selected),
            style: theme.textTheme.headlineSmall,
          ),
        ],
      ),
      content: SizedBox(
        width: 340,
        height: 350,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _navRow(theme),
            const SizedBox(height: 6),
            Expanded(child: _grid(theme)),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('stepped_date_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('stepped_date_confirm'),
          onPressed: () => Navigator.of(context).pop(_selected),
          child: Text(widget.confirmText),
        ),
      ],
    );
  }

  /// The header the narrowing is driven from: what is on screen, a way up a
  /// level, and — on the day grid only — the month arrows.
  Widget _navRow(ThemeData theme) {
    final label = switch (_step) {
      DatePickerStep.year => '$_firstYear - $_lastYear',
      DatePickerStep.month => '${_selected.year}',
      DatePickerStep.day =>
        '${_monthFullNames[_selected.month - 1]} ${_selected.year}',
    };

    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('stepped_date_step_up'),
              // UP A LEVEL, not into a year list and back out. The day grid
              // goes to the months, the months to the years, and the years
              // have nowhere further to go.
              onPressed: _step == DatePickerStep.year
                  ? null
                  : () => setState(() {
                      _step = _step == DatePickerStep.day
                          ? DatePickerStep.month
                          : DatePickerStep.year;
                    }),
              icon: Icon(
                _step == DatePickerStep.year
                    ? Icons.calendar_today
                    : Icons.arrow_drop_up,
                size: 18,
              ),
              label: Text(label),
            ),
          ),
        ),
        // The arrows only mean anything on the days: on a month or year grid
        // everything they could step to is already on screen.
        if (_step == DatePickerStep.day) ...[
          IconButton(
            key: const ValueKey('stepped_date_prev_month'),
            tooltip: 'Previous month',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.chevron_left),
            onPressed: _monthSelectable(
              DateTime(_selected.year, _selected.month - 1).year,
              DateTime(_selected.year, _selected.month - 1).month,
            )
                ? () {
                    final prev = DateTime(_selected.year, _selected.month - 1);
                    _moveTo(prev.year, prev.month);
                  }
                : null,
          ),
          IconButton(
            key: const ValueKey('stepped_date_next_month'),
            tooltip: 'Next month',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.chevron_right),
            onPressed: _monthSelectable(
              DateTime(_selected.year, _selected.month + 1).year,
              DateTime(_selected.year, _selected.month + 1).month,
            )
                ? () {
                    final next = DateTime(_selected.year, _selected.month + 1);
                    _moveTo(next.year, next.month);
                  }
                : null,
          ),
        ],
      ],
    );
  }

  Widget _grid(ThemeData theme) => switch (_step) {
    DatePickerStep.year => _yearGrid(theme),
    DatePickerStep.month => _monthGrid(theme),
    DatePickerStep.day => _dayGrid(theme),
  };

  /// One cell of any of the three grids, so a year, a month and a day are the
  /// same target at the same weight — the difference between them is what they
  /// narrow to, not how they look.
  Widget _cell({
    required Key key,
    required String label,
    required bool selected,
    required bool enabled,
    required bool outlined,
    required VoidCallback onTap,
    required ThemeData theme,
  }) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Material(
        color: selected ? scheme.primary : Colors.transparent,
        shape: outlined && !selected
            ? RoundedRectangleBorder(
                side: BorderSide(color: scheme.primary),
                borderRadius: BorderRadius.circular(18),
              )
            : const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: key,
          onTap: enabled ? onTap : null,
          child: Center(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: selected
                    ? scheme.onPrimary
                    : enabled
                    ? null
                    : scheme.onSurface.withValues(alpha: 0.38),
                fontWeight: selected ? FontWeight.w600 : null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _yearGrid(ThemeData theme) {
    final years = [for (var y = _firstYear; y <= _lastYear; y++) y];
    final thisYear = today().year;
    return GridView.count(
      crossAxisCount: 4,
      childAspectRatio: 2.1,
      // Opens on the chosen year rather than at the top of the list: on a range
      // of sixteen years the one somebody is working in is usually off screen.
      controller: _yearScroll ??= ScrollController(
        initialScrollOffset: _yearScrollOffset(years.length),
      ),
      children: [
        for (final year in years)
          _cell(
            theme: theme,
            key: ValueKey('stepped_date_year_$year'),
            label: '$year',
            selected: year == _selected.year,
            outlined: year == thisYear,
            enabled: true,
            onTap: () {
              // A year is not a date. Picking one narrows to its months and
              // waits — see the file header.
              final month = _monthSelectable(year, _selected.month)
                  ? _selected.month
                  : 1;
              _moveTo(year, month);
              setState(() => _step = DatePickerStep.month);
            },
          ),
      ],
    );
  }

  /// Roughly where the chosen year sits in the list, so it opens near it.
  double _yearScrollOffset(int count) {
    final row = ((_selected.year - _firstYear) / 4).floor();
    // Two rows of head-room, so the chosen year is in view rather than pinned
    // to the very top edge where it reads as the first year in the range.
    return ((row - 2) * 52).clamp(0, (count / 4).ceil() * 52).toDouble();
  }

  Widget _monthGrid(ThemeData theme) {
    final now = today();
    return GridView.count(
      crossAxisCount: 3,
      childAspectRatio: 2.1,
      children: [
        for (var month = 1; month <= 12; month++)
          _cell(
            theme: theme,
            key: ValueKey('stepped_date_month_$month'),
            label: _monthNames[month - 1],
            selected: month == _selected.month,
            outlined: month == now.month && _selected.year == now.year,
            enabled: _monthSelectable(_selected.year, month),
            onTap: () {
              _moveTo(_selected.year, month);
              setState(() => _step = DatePickerStep.day);
            },
          ),
      ],
    );
  }

  Widget _dayGrid(ThemeData theme) {
    final localizations = MaterialLocalizations.of(context);
    final year = _selected.year;
    final month = _selected.month;
    final days = daysInMonth(year, month);
    final now = today();

    // Which column the 1st lands in. DateTime.weekday is 1..7 for Mon..Sun;
    // the locale says which day starts the row, so a US week starting on Sunday
    // and a European one starting on Monday both line up without a flag.
    final firstWeekday = DateTime(year, month, 1).weekday % 7;
    final leading = (firstWeekday - localizations.firstDayOfWeekIndex + 7) % 7;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (var i = 0; i < 7; i++)
              Expanded(
                child: Center(
                  child: Text(
                    localizations.narrowWeekdays[
                        (localizations.firstDayOfWeekIndex + i) % 7],
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: GridView.count(
            crossAxisCount: 7,
            childAspectRatio: 1.05,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (var i = 0; i < leading; i++) const SizedBox(),
              for (var day = 1; day <= days; day++)
                _cell(
                  theme: theme,
                  key: ValueKey('stepped_date_day_$day'),
                  label: '$day',
                  selected: day == _selected.day,
                  outlined: DateTime(year, month, day) == now,
                  enabled: _inRange(DateTime(year, month, day)),
                  onTap: () => _moveTo(year, month, day: day),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
